import Foundation
import PDFCore
import PDFEditing
import PDFKit

/// OCR-07: the multi-file OCR job settings. Output naming is explicit and
/// bounded, cancellation is cooperative, and a completed output is only ever
/// produced by an atomic verified write.
public struct OCRBatchSettings: Sendable, Equatable {
  public var outputDirectory: URL
  /// Tokens: {name} (input file base name) and {index} (1-based input order).
  public var nameTemplate: String
  public var languages: [String]
  public var level: OCRRecognitionLevel
  public var minimumConfidence: Double
  public var overwriteExisting: Bool
  public var reportFileName: String

  public static let defaultNameTemplate = "{name}-OCR.pdf"
  public static let defaultReportFileName = "spdf-ocr-batch-report.json"
  public static let maximumInputBytes = 256 * 1_024 * 1_024

  public init(
    outputDirectory: URL, nameTemplate: String = OCRBatchSettings.defaultNameTemplate,
    languages: [String], level: OCRRecognitionLevel = .accurate,
    minimumConfidence: Double = 0.6, overwriteExisting: Bool = false,
    reportFileName: String = OCRBatchSettings.defaultReportFileName
  ) {
    self.outputDirectory = outputDirectory
    self.nameTemplate = nameTemplate
    self.languages = languages
    self.level = level
    self.minimumConfidence = minimumConfidence
    self.overwriteExisting = overwriteExisting
    self.reportFileName = reportFileName
  }

  /// OCR-02: unavailable languages are identified before any work starts.
  public func validated(supportedLanguages: [String]) throws -> OCRBatchSettings {
    guard nameTemplate.contains("{name}") || nameTemplate.contains("{index}") else {
      throw PDFError(.malformed, "The OCR output name needs a {name} or {index} token")
    }
    guard !nameTemplate.contains("/"), !nameTemplate.contains("\\") else {
      throw PDFError(.malformed, "The OCR output name template cannot contain path separators")
    }
    guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
      throw PDFError(.malformed, "The OCR confidence threshold must be within 0...1")
    }
    guard !reportFileName.isEmpty,
      URL(fileURLWithPath: reportFileName).lastPathComponent == reportFileName,
      reportFileName.hasSuffix(".json")
    else {
      throw PDFError(.malformed, "The OCR batch report name is invalid")
    }
    for language in languages {
      guard supportedLanguages.contains(language) else {
        throw PDFError(.unsupported, "OCR language \(language) is not supported on this system")
      }
    }
    return self
  }

  public var languageChoice: OCRLanguageChoice {
    OCRLanguageChoice(
      languages: languages,
      quality: level == .accurate ? .accurate : .fast,
      minimumConfidence: minimumConfidence)
  }
}

public enum OCRBatchItemStatus: String, Codable, Sendable, Equatable {
  case completed
  case resumed
  case failed
  case cancelled
  case pending
}

/// One progress tick from the multi-file queue. The app relays this into the
/// existing JobProgressCenter (per-file units plus current-file page detail).
public struct OCRBatchProgress: Sendable, Equatable {
  public enum Stage: String, Sendable, Equatable {
    case reading
    case recognizing
    case writing
    case finished
  }

  public let stage: Stage
  public let itemIndex: Int
  public let itemCount: Int
  public let fileName: String
  public let completedPages: Int
  public let totalPages: Int

  public init(
    stage: Stage, itemIndex: Int, itemCount: Int, fileName: String,
    completedPages: Int, totalPages: Int
  ) {
    self.stage = stage
    self.itemIndex = itemIndex
    self.itemCount = itemCount
    self.fileName = fileName
    self.completedPages = completedPages
    self.totalPages = totalPages
  }
}

public struct OCRBatchItemResult: Sendable, Equatable {
  public let inputURL: URL
  public let outputURL: URL
  public let sourceDigest: String
  public let outputDigest: String?
  public let status: OCRBatchItemStatus
  public let pagesRecognized: Int
  public let completedPages: [Int]
  public let failure: String?

  public init(
    inputURL: URL, outputURL: URL, sourceDigest: String, outputDigest: String?,
    status: OCRBatchItemStatus, pagesRecognized: Int, completedPages: [Int],
    failure: String?
  ) {
    self.inputURL = inputURL
    self.outputURL = outputURL
    self.sourceDigest = sourceDigest
    self.outputDigest = outputDigest
    self.status = status
    self.pagesRecognized = pagesRecognized
    self.completedPages = completedPages
    self.failure = failure
  }
}

/// OCR-07: the durable per-batch report written beside the outputs. Resume and
/// failure reporting both read this file, so a cancelled or partly failed run
/// never needs to guess what completed.
public struct OCRBatchReport: Sendable, Equatable, Codable {
  public struct Item: Sendable, Equatable, Codable {
    public let inputName: String
    public let outputName: String
    public let sourceDigest: String
    public let outputDigest: String?
    public let status: OCRBatchItemStatus
    public let pagesRecognized: Int
    public let completedPages: [Int]
    public let failure: String?

    public init(
      inputName: String, outputName: String, sourceDigest: String,
      outputDigest: String?, status: OCRBatchItemStatus, pagesRecognized: Int,
      completedPages: [Int], failure: String?
    ) {
      self.inputName = inputName
      self.outputName = outputName
      self.sourceDigest = sourceDigest
      self.outputDigest = outputDigest
      self.status = status
      self.pagesRecognized = pagesRecognized
      self.completedPages = completedPages
      self.failure = failure
    }
  }

  public static let version = 1
  public let version: Int
  public let createdAt: String
  public let outputDirectory: String
  public let nameTemplate: String
  public let cancelled: Bool
  public let items: [Item]

  public init(
    createdAt: String, outputDirectory: String, nameTemplate: String,
    cancelled: Bool, items: [Item]
  ) {
    self.version = Self.version
    self.createdAt = createdAt
    self.outputDirectory = outputDirectory
    self.nameTemplate = nameTemplate
    self.cancelled = cancelled
    self.items = items
  }

  /// Human-readable failure report for the UI; empty when nothing failed.
  public var failureSummary: String {
    items.compactMap { item in
      guard item.status == .failed, let failure = item.failure else { return nil }
      return "\(item.inputName): \(failure)"
    }.joined(separator: "\n")
  }
}

public struct OCRBatchRun: Sendable, Equatable {
  public let items: [OCRBatchItemResult]
  public let report: OCRBatchReport
  public let reportURL: URL?
  public let cancelled: Bool

  public var completedCount: Int {
    items.filter { $0.status == .completed || $0.status == .resumed }.count
  }
  public var failedCount: Int { items.filter { $0.status == .failed }.count }
  public var failureSummary: String {
    items.compactMap { item in
      guard item.status == .failed, let failure = item.failure else { return nil }
      return "\(item.inputURL.lastPathComponent): \(failure)"
    }.joined(separator: "\n")
  }
}

public enum OCRBatchQueue {
  public static let maximumReportBytes = 2 * 1_024 * 1_024

  /// Resolve the output file for one input. Invalid or colliding names are
  /// refused before any recognition work starts.
  public static func outputURL(
    for input: URL, index: Int, settings: OCRBatchSettings
  ) throws -> URL {
    let base = input.deletingPathExtension().lastPathComponent
    var name = settings.nameTemplate
      .replacingOccurrences(of: "{name}", with: base)
      .replacingOccurrences(of: "{index}", with: String(format: "%03d", index + 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw PDFError(.malformed, "The OCR output name resolved to an empty name")
    }
    if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
    guard URL(fileURLWithPath: name).lastPathComponent == name,
      !name.contains("/"), !name.contains("\\")
    else {
      throw PDFError(.malformed, "The OCR output name is not a plain file name")
    }
    let output = settings.outputDirectory.standardizedFileURL
      .appendingPathComponent(name).standardizedFileURL
    guard output != input.standardizedFileURL else {
      throw PDFError(.malformed, "The OCR output would overwrite the input file")
    }
    return output
  }

  /// Read a previous batch report, bounded. Nil when absent or unreadable.
  public static func readReport(
    in directory: URL, fileName: String = OCRBatchSettings.defaultReportFileName
  ) -> OCRBatchReport? {
    let url = directory.standardizedFileURL.appendingPathComponent(fileName)
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize, size >= 0, size <= maximumReportBytes,
      let data = try? Data(contentsOf: url),
      let report = try? JSONDecoder().decode(OCRBatchReport.self, from: data),
      report.version == OCRBatchReport.version
    else { return nil }
    return report
  }

  /// OCR-07: run OCR over several files in order. Per-file failures are
  /// reported, never thrown away: completed outputs are written atomically and
  /// a resumed run skips a completed file only when its input digest and output
  /// digest both still match the report. Cancellation returns the partial report
  /// with completed outputs intact.
  public static func run(
    inputs: [URL], settings: OCRBatchSettings,
    recognizer: TextRecognizing = VisionTextRecognizer(),
    onProgress: (@Sendable (OCRBatchProgress) -> Void)? = nil
  ) async throws -> OCRBatchRun {
    guard !inputs.isEmpty else {
      throw PDFError(.malformed, "Choose at least one PDF to OCR")
    }
    let manager = FileManager.default
    let directory = settings.outputDirectory.standardizedFileURL
    if manager.fileExists(atPath: directory.path) {
      guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true
      else {
        throw PDFError(.malformed, "The OCR output location is not a directory")
      }
    } else {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let priorReport = readReport(in: directory, fileName: settings.reportFileName)
    var priorByOutput: [String: OCRBatchReport.Item] = [:]
    for item in priorReport?.items ?? [] {
      priorByOutput[item.inputName + "|" + item.outputName] = item
    }
    var results: [OCRBatchItemResult] = []
    var usedOutputNames = Set<String>()
    var cancelled = false

    for (index, input) in inputs.enumerated() {
      let fileName = input.lastPathComponent
      if cancelled || Task.isCancelled {
        cancelled = true
        if let output = try? outputURL(for: input, index: index, settings: settings) {
          results.append(
            OCRBatchItemResult(
              inputURL: input, outputURL: output, sourceDigest: "", outputDigest: nil,
              status: .cancelled, pagesRecognized: 0, completedPages: [], failure: nil))
        }
        continue
      }
      let output: URL
      do {
        output = try outputURL(for: input, index: index, settings: settings)
      } catch {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: directory.appendingPathComponent(fileName),
            sourceDigest: "", outputDigest: nil, status: .failed,
            pagesRecognized: 0, completedPages: [],
            failure: error.localizedDescription))
        continue
      }
      let outputName = output.lastPathComponent
      guard usedOutputNames.insert(outputName).inserted else {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: "", outputDigest: nil,
            status: .failed, pagesRecognized: 0, completedPages: [],
            failure: "Another input already uses the output name \(outputName)."))
        continue
      }

      onProgress?(
        OCRBatchProgress(
          stage: .reading, itemIndex: index, itemCount: inputs.count, fileName: fileName,
          completedPages: 0, totalPages: 0))
      let sourceData: Data
      do {
        sourceData = try Data(contentsOf: input)
      } catch {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: "", outputDigest: nil,
            status: .failed, pagesRecognized: 0, completedPages: [],
            failure: "The input file could not be read."))
        continue
      }
      guard sourceData.count <= OCRBatchSettings.maximumInputBytes else {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: "", outputDigest: nil,
            status: .failed, pagesRecognized: 0, completedPages: [],
            failure: "The input file exceeds the 256 MB OCR batch bound."))
        continue
      }
      let sourceDigest = FontImportDigest.sha256Hex(sourceData)

      // Resume: a prior completed entry is only reused when both the input and
      // the existing output still match their recorded digests.
      if let prior = priorByOutput[fileName + "|" + outputName],
        prior.sourceDigest == sourceDigest,
        prior.status == .completed || prior.status == .resumed,
        let priorOutputDigest = prior.outputDigest,
        let existing = try? Data(contentsOf: output),
        FontImportDigest.sha256Hex(existing) == priorOutputDigest
      {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: sourceDigest,
            outputDigest: priorOutputDigest, status: .resumed,
            pagesRecognized: prior.pagesRecognized,
            completedPages: prior.completedPages, failure: nil))
        onProgress?(
          OCRBatchProgress(
            stage: .finished, itemIndex: index, itemCount: inputs.count, fileName: fileName,
            completedPages: prior.pagesRecognized, totalPages: prior.pagesRecognized))
        continue
      }
      if manager.fileExists(atPath: output.path), !settings.overwriteExisting {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: sourceDigest,
            outputDigest: nil, status: .failed, pagesRecognized: 0, completedPages: [],
            failure:
              "An output file already exists and overwrite is off. Remove it or enable overwrite."))
        continue
      }

      // Recognize candidate pages with the existing page-batch helpers.
      do {
        let parsed = try PDFParser.parse(sourceData)
        let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
        let candidates = pageIDs.indices.filter { pageIndex in
          let pageID = pageIDs[pageIndex]
          return !OCRLayer.hasGeneratedLayer(in: parsed.graph, pageID: pageID)
            && !OCRLayer.pageShowsText(pageID, in: parsed.graph)
        }
        guard !candidates.isEmpty else {
          throw PDFError(
            .unsupported,
            "No page needs OCR (the file already has text or a generated layer).")
        }
        guard let document = PDFDocument(data: sourceData), !document.isLocked else {
          throw PDFError(.unsupported, "OCR requires an unlocked document")
        }
        var pageResults: [Int: OCRPageResult] = [:]
        var state = OCRBatchState(pages: candidates)
        do {
          try OCRBatchRunner.run(
            state: &state,
            onProgress: { done, total in
              onProgress?(
                OCRBatchProgress(
                  stage: .recognizing, itemIndex: index, itemCount: inputs.count,
                  fileName: fileName, completedPages: done, totalPages: total))
            }
          ) { pageIndex in
            let pageOutcome = try OCRJob.run(
              document: document, pageIndexes: [pageIndex], languages: settings.languages,
              level: settings.level, recognizer: recognizer)
            guard let first = pageOutcome.first else {
              throw PDFError(.malformed, "The OCR job returned no result for a page")
            }
            pageResults[pageIndex] = first
          }
        } catch is CancellationError {
          cancelled = true
          results.append(
            OCRBatchItemResult(
              inputURL: input, outputURL: output, sourceDigest: sourceDigest,
              outputDigest: nil, status: .cancelled,
              pagesRecognized: state.completed.count, completedPages: state.completed.sorted(),
              failure: nil))
          continue
        }
        try Task.checkCancellation()
        let orderedIndexes = pageResults.keys.sorted()
        let recognized = orderedIndexes.compactMap { pageResults[$0] }.filter {
          !$0.lines.isEmpty
        }
        guard !recognized.isEmpty else {
          throw PDFError(.unsupported, "No text was recognized on the OCR candidate pages")
        }
        let quality = OCRReviewBuilder.quality(
          level: settings.level, results: orderedIndexes.compactMap { pageResults[$0] })
        var commands: [PDFEditCommand] = []
        var expectedText: [PDFObjectID: String] = [:]
        var completedPages: [Int] = []
        for result in recognized {
          guard pageIDs.indices.contains(result.pageIndex) else { continue }
          let pageID = pageIDs[result.pageIndex]
          let lines = result.lines.map {
            SearchableTextLine(text: $0.text, rect: $0.rect, confidence: $0.confidence)
          }
          commands.append(
            AddSearchableTextLayerCommand(
              pageID: pageID, lines: lines, replacingExistingLayer: false))
          let seed = OCRReviewPageSeed(
            pageID: pageID, pageIndex: result.pageIndex, lines: lines,
            wordBoxes: result.lines.map { line -> [[Double]] in
              let tokens = OCRReviewTokenizer.words(line.text)
              guard line.words.count == tokens.count else { return [] }
              return line.words.map(\.rect)
            },
            usedFastFallback: result.usedFastFallback)
          let record = OCRReviewBuilder.record(
            for: seed, threshold: settings.minimumConfidence, quality: quality)
          commands.append(RecordOCRReviewCommand(pageID: pageID, record: record))
          expectedText[pageID] = lines.map(\.text).joined(separator: "\n")
          completedPages.append(result.pageIndex)
        }
        guard !commands.isEmpty else {
          throw PDFError(.unsupported, "No recognized page produced a searchable layer")
        }
        onProgress?(
          OCRBatchProgress(
            stage: .writing, itemIndex: index, itemCount: inputs.count, fileName: fileName,
            completedPages: completedPages.count, totalPages: candidates.count))
        let edited = try PDFEditingEngine.commit(PDFTransaction(commands), to: parsed.graph)
        let outputData = try PDFWriter.write(edited)
        // Independent verification of the bytes we are about to install.
        let verified = try PDFParser.parse(outputData)
        for (pageID, text) in expectedText {
          guard OCRLayer.hasGeneratedLayer(in: verified.graph, pageID: pageID),
            TextProvenance.recognizedLayerText(pageID: pageID, in: verified.graph) == text
          else {
            throw PDFError(
              .malformed, "The written OCR layer did not verify before installation")
          }
        }
        // OCR-07: never attach results to a changed source revision.
        let latestData = try Data(contentsOf: input)
        guard FontImportDigest.sha256Hex(latestData) == sourceDigest else {
          throw PDFError(
            .unsupported,
            "The source file changed while it was being recognized. Nothing was written.")
        }
        let outputDigest = FontImportDigest.sha256Hex(outputData)
        let temporary = directory.appendingPathComponent(
          ".spdf-ocr-\(UUID().uuidString).tmp")
        do {
          try outputData.write(to: temporary, options: .atomic)
          if manager.fileExists(atPath: output.path) {
            _ = try manager.replaceItemAt(output, withItemAt: temporary)
          } else {
            try manager.moveItem(at: temporary, to: output)
          }
        } catch {
          try? manager.removeItem(at: temporary)
          throw PDFError(.unsupported, "The OCR output could not be written.")
        }
        guard let written = try? Data(contentsOf: output),
          FontImportDigest.sha256Hex(written) == outputDigest
        else {
          try? manager.removeItem(at: output)
          throw PDFError(.unsupported, "The written OCR output did not verify.")
        }
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: sourceDigest,
            outputDigest: outputDigest, status: .completed,
            pagesRecognized: completedPages.count,
            completedPages: completedPages.sorted(), failure: nil))
        onProgress?(
          OCRBatchProgress(
            stage: .finished, itemIndex: index, itemCount: inputs.count, fileName: fileName,
            completedPages: completedPages.count, totalPages: candidates.count))
      } catch is CancellationError {
        cancelled = true
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: sourceDigest,
            outputDigest: nil, status: .cancelled, pagesRecognized: 0,
            completedPages: [], failure: nil))
      } catch {
        results.append(
          OCRBatchItemResult(
            inputURL: input, outputURL: output, sourceDigest: sourceDigest,
            outputDigest: nil, status: .failed, pagesRecognized: 0, completedPages: [],
            failure: error.localizedDescription))
      }
    }

    let report = OCRBatchReport(
      createdAt: ISO8601DateFormatter().string(from: Date()),
      outputDirectory: directory.path, nameTemplate: settings.nameTemplate,
      cancelled: cancelled,
      items: results.map { result in
        OCRBatchReport.Item(
          inputName: result.inputURL.lastPathComponent,
          outputName: result.outputURL.lastPathComponent,
          sourceDigest: result.sourceDigest,
          outputDigest: result.outputDigest,
          status: result.status,
          pagesRecognized: result.pagesRecognized,
          completedPages: result.completedPages,
          failure: result.failure)
      })
    let reportURL = directory.appendingPathComponent(settings.reportFileName)
    var writtenReportURL: URL?
    if let data = try? JSONEncoder().encode(report),
      data.count <= maximumReportBytes
    {
      do {
        try data.write(to: reportURL, options: .atomic)
        writtenReportURL = reportURL
      } catch {
        writtenReportURL = nil
      }
    }
    return OCRBatchRun(
      items: results, report: report, reportURL: writtenReportURL, cancelled: cancelled)
  }
}
