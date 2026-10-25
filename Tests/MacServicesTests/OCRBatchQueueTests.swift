import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

private final class RecognitionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0
  var failAtCall: Int?
  var cancelAtCall: Int?
  var texts: [String] = ["Invoice 42", "Total 7"]
  var confidence: Double = 0.35

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  func recognize() throws -> [OCRObservation] {
    lock.lock()
    callCount += 1
    let call = callCount
    let fail = failAtCall
    let cancel = cancelAtCall
    let texts = self.texts
    let confidence = self.confidence
    lock.unlock()
    if let cancel, call == cancel { throw CancellationError() }
    if let fail, call == fail {
      throw PDFError(.unsupported, "Injected recognition failure \(call)")
    }
    return texts.enumerated().map { index, text in
      OCRObservation(
        text: text, confidence: confidence,
        boundingBox: CGRect(
          x: 0.1, y: 0.8 - Double(index) * 0.12, width: 0.6, height: 0.08))
    }
  }
}

private struct ProbeRecognizer: TextRecognizing {
  let probe: RecognitionProbe
  func recognize(
    image: CGImage, languages: [String], level: OCRRecognitionLevel
  ) throws -> [OCRObservation] {
    try probe.recognize()
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [OCRBatchProgress] = []
  func append(_ progress: OCRBatchProgress) {
    lock.lock()
    stored.append(progress)
    lock.unlock()
  }
  var events: [OCRBatchProgress] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

/// OCR-07: the multi-file OCR queue — output naming, cancellation, resume,
/// changed-source refusal and failure reporting. A failed page/file never
/// corrupts an already completed output.
@Suite("OCR batch queue")
struct OCRBatchQueueTests {
  private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spdf-ocr-batch-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeInputs(
    in directory: URL, names: [String], data: Data
  ) throws -> [URL] {
    try names.map { name in
      let url = directory.appendingPathComponent(name)
      try data.write(to: url)
      return url
    }
  }

  private func settings(
    output: URL, template: String = "{index}-{name}-ocr",
    overwrite: Bool = false
  ) -> OCRBatchSettings {
    OCRBatchSettings(
      outputDirectory: output, nameTemplate: template, languages: ["en-US"],
      level: .accurate, minimumConfidence: 0.6, overwriteExisting: overwrite)
  }

  private func outputs(of run: OCRBatchRun) -> [Data] {
    run.items.compactMap { try? Data(contentsOf: $0.outputURL) }
  }

  @Test func runsQueueWithNamingVerifiedOutputsAndReport() async throws {
    let inputDir = try temporaryDirectory("inputs")
    let outputDir = try temporaryDirectory("outputs")
    defer { try? FileManager.default.removeItem(at: inputDir) }
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let inputs = try writeInputs(
      in: inputDir, names: ["scan-a.pdf", "scan-b.pdf", "scan-c.pdf"],
      data: try PDFFixtures.imagePages())
    let probe = RecognitionProbe()
    let log = ProgressLog()
    let run = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: probe),
      onProgress: { progress in log.append(progress) })

    #expect(!run.cancelled)
    #expect(run.completedCount == 3)
    #expect(run.failedCount == 0)
    #expect(probe.calls == 6)  // 3 files x 2 candidate pages
    #expect(run.items.map(\.status) == [.completed, .completed, .completed])
    #expect(
      run.items.map(\.outputURL.lastPathComponent)
        == ["001-scan-a-ocr.pdf", "002-scan-b-ocr.pdf", "003-scan-c-ocr.pdf"])
    for item in run.items {
      #expect(item.pagesRecognized == 2)
      let data = try Data(contentsOf: item.outputURL)
      #expect(FontImportDigest.sha256Hex(data) == item.outputDigest)
      let parsed = try PDFParser.parse(data)
      let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
      for pageID in pageIDs {
        #expect(OCRLayer.hasGeneratedLayer(in: parsed.graph, pageID: pageID))
        #expect(
          TextProvenance.recognizedLayerText(pageID: pageID, in: parsed.graph)
            == "Invoice 42\nTotal 7")
        // OCR-03 review metadata is present, so a batch output is reviewable.
        let record = try #require(OCRReviewStore.read(pageID: pageID, in: parsed.graph))
        #expect(record.threshold == 0.6)
        #expect(record.quality == "accurate")
        #expect(record.suspectWords.count == 4)  // two low-confidence lines, two words each
      }
    }
    // Report is durable and round-trips exactly.
    let reportURL = try #require(run.reportURL)
    let report = try #require(OCRBatchQueue.readReport(in: outputDir))
    #expect(report == run.report)
    #expect(report.items.count == 3)
    #expect(FileManager.default.fileExists(atPath: reportURL.path))
    // Progress covers reading, per-page recognition, writing and finish.
    let events = log.events
    #expect(events.filter { $0.stage == .reading }.count == 3)
    #expect(events.filter { $0.stage == .recognizing }.count == 6)
    #expect(events.contains { $0.stage == .recognizing && $0.totalPages == 2 })
    #expect(events.filter { $0.stage == .writing }.count == 3)
    #expect(events.filter { $0.stage == .finished }.count == 3)
  }

  @Test func resumeSkipsVerifiedOutputsOnly() async throws {
    let inputDir = try temporaryDirectory("resume-inputs")
    let outputDir = try temporaryDirectory("resume-outputs")
    defer { try? FileManager.default.removeItem(at: inputDir) }
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let inputs = try writeInputs(
      in: inputDir, names: ["scan-a.pdf", "scan-b.pdf", "scan-c.pdf"],
      data: try PDFFixtures.imagePages())
    let firstProbe = RecognitionProbe()
    let first = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: firstProbe))
    #expect(first.completedCount == 3)
    let originalDigests = first.items.compactMap(\.outputDigest)

    // A completed, still-valid output is not recognized again.
    let resumeProbe = RecognitionProbe()
    resumeProbe.failAtCall = 1
    let resumed = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: resumeProbe))
    #expect(resumeProbe.calls == 0)
    #expect(resumed.items.map(\.status) == [.resumed, .resumed, .resumed])
    #expect(resumed.items.compactMap(\.outputDigest) == originalDigests)

    // A changed input invalidates the completed entry. With overwrite off, the
    // existing output is left untouched and reported instead of being replaced.
    try PDFFixtures.scannedPages().write(to: inputs[1])
    let collisionProbe = RecognitionProbe()
    let conflicted = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: collisionProbe))
    #expect(conflicted.items.map(\.status) == [.resumed, .failed, .resumed])
    #expect(conflicted.failureSummary.contains("already exists"))
    #expect(collisionProbe.calls == 0)
    #expect(try Data(contentsOf: first.items[1].outputURL) == outputs(of: first)[1])

    // Overwrite explicitly replaces only that output atomically.
    let overwriteProbe = RecognitionProbe()
    let overwritten = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir, overwrite: true),
      recognizer: ProbeRecognizer(probe: overwriteProbe))
    #expect(overwritten.items.map(\.status) == [.resumed, .completed, .resumed])
    #expect(overwriteProbe.calls > 0)
    let overwrittenData = try Data(contentsOf: overwritten.items[1].outputURL)
    #expect(try PDFParser.parse(overwrittenData).pageCount > 0)
    #expect(try Data(contentsOf: first.items[0].outputURL) == outputs(of: first)[0])
  }

  @Test func failureDoesNotCorruptCompletedOutputs() async throws {
    let inputDir = try temporaryDirectory("failure-inputs")
    let outputDir = try temporaryDirectory("failure-outputs")
    defer { try? FileManager.default.removeItem(at: inputDir) }
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let inputs = try writeInputs(
      in: inputDir, names: ["scan-a.pdf", "scan-b.pdf", "scan-c.pdf"],
      data: try PDFFixtures.imagePages())
    let probe = RecognitionProbe()
    probe.failAtCall = 3  // second file, first page
    let run = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: probe))
    #expect(run.items.map(\.status) == [.completed, .failed, .completed])
    #expect(run.failedCount == 1)
    #expect(run.failureSummary.contains("Injected recognition failure"))
    #expect(FileManager.default.fileExists(atPath: run.items[0].outputURL.path))
    #expect(!FileManager.default.fileExists(atPath: run.items[1].outputURL.path))
    #expect(FileManager.default.fileExists(atPath: run.items[2].outputURL.path))
    for index in [0, 2] {
      let data = try Data(contentsOf: run.items[index].outputURL)
      let parsed = try PDFParser.parse(data)
      #expect(try PDFPageTree.pageIDs(in: parsed.graph).allSatisfy {
        OCRLayer.hasGeneratedLayer(in: parsed.graph, pageID: $0)
      })
    }
    let report = try #require(OCRBatchQueue.readReport(in: outputDir))
    #expect(report.failureSummary.contains("scan-b.pdf"))
  }

  @Test func cancellationKeepsCompletedOutputsAndResumes() async throws {
    let inputDir = try temporaryDirectory("cancel-inputs")
    let outputDir = try temporaryDirectory("cancel-outputs")
    defer { try? FileManager.default.removeItem(at: inputDir) }
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let inputs = try writeInputs(
      in: inputDir, names: ["scan-a.pdf", "scan-b.pdf", "scan-c.pdf"],
      data: try PDFFixtures.imagePages())
    let cancelProbe = RecognitionProbe()
    cancelProbe.cancelAtCall = 3  // second file
    let cancelled = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: cancelProbe))
    #expect(cancelled.cancelled)
    #expect(
      cancelled.items.map(\.status) == [.completed, .cancelled, .cancelled])
    #expect(FileManager.default.fileExists(atPath: cancelled.items[0].outputURL.path))
    #expect(!FileManager.default.fileExists(atPath: cancelled.items[1].outputURL.path))
    #expect(!FileManager.default.fileExists(atPath: cancelled.items[2].outputURL.path))
    let report = try #require(OCRBatchQueue.readReport(in: outputDir))
    #expect(report.cancelled)
    let firstDigest = cancelled.items[0].outputDigest

    let resumeProbe = RecognitionProbe()
    let resumed = try await OCRBatchQueue.run(
      inputs: inputs, settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: resumeProbe))
    #expect(!resumed.cancelled)
    #expect(resumed.items.map(\.status) == [.resumed, .completed, .completed])
    #expect(resumeProbe.calls == 4)  // the two unfinished files, two pages each
    #expect(resumed.items[0].outputDigest == firstDigest)
  }

  @Test func changedSourceDuringRecognitionIsRefused() async throws {
    let inputDir = try temporaryDirectory("changed-inputs")
    let outputDir = try temporaryDirectory("changed-outputs")
    defer { try? FileManager.default.removeItem(at: inputDir) }
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let input = inputDir.appendingPathComponent("scan-a.pdf")
    try PDFFixtures.imagePages().write(to: input)
    let replacement = try PDFFixtures.onePage()
    let probe = RecognitionProbe()
    let run = try await OCRBatchQueue.run(
      inputs: [input], settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: probe),
      onProgress: { progress in
        // The source changes after recognition but before the output is
        // installed; the queue must refuse to attach the results.
        if progress.stage == .writing {
          try? replacement.write(to: input)
        }
      })
    #expect(run.items.map(\.status) == [.failed])
    #expect(run.failureSummary.localizedCaseInsensitiveContains("changed"))
    #expect(!FileManager.default.fileExists(atPath: run.items[0].outputURL.path))
    #expect(probe.calls == 2)
  }

  @Test func configurationAndCandidateRefusals() async throws {
    let inputDir = try temporaryDirectory("config-inputs")
    let outputDir = try temporaryDirectory("config-outputs")
    defer { try? FileManager.default.removeItem(at: inputDir) }
    defer { try? FileManager.default.removeItem(at: outputDir) }

    // Settings validation refuses before any work starts.
    #expect(throws: PDFError.self) {
      _ = try OCRBatchSettings(
        outputDirectory: outputDir, nameTemplate: "fixed", languages: ["en-US"]
      ).validated(supportedLanguages: ["en-US"])
    }
    #expect(throws: PDFError.self) {
      _ = try OCRBatchSettings(
        outputDirectory: outputDir, nameTemplate: "../{name}", languages: ["en-US"]
      ).validated(supportedLanguages: ["en-US"])
    }
    #expect(throws: PDFError.self) {
      _ = try OCRBatchSettings(
        outputDirectory: outputDir, nameTemplate: "{name}",
        languages: ["xx-YY"]
      ).validated(supportedLanguages: ["en-US"])
    }
    #expect(throws: PDFError.self) {
      _ = try OCRBatchSettings(
        outputDirectory: outputDir, nameTemplate: "{name}", languages: [],
        minimumConfidence: 2
      ).validated(supportedLanguages: [])
    }
    var refusedEmptyInputs = false
    do {
      _ = try await OCRBatchQueue.run(
        inputs: [], settings: settings(output: outputDir),
        recognizer: ProbeRecognizer(probe: RecognitionProbe()))
    } catch is PDFError {
      refusedEmptyInputs = true
    }
    #expect(refusedEmptyInputs)

    // A file with ordinary text has no OCR candidate page.
    let textInput = inputDir.appendingPathComponent("text.pdf")
    try PDFFixtures.textEditPages().write(to: textInput)
    let textRun = try await OCRBatchQueue.run(
      inputs: [textInput], settings: settings(output: outputDir),
      recognizer: ProbeRecognizer(probe: RecognitionProbe()))
    #expect(textRun.items.map(\.status) == [.failed])
    #expect(textRun.failureSummary.contains("No page needs OCR"))

    // Two inputs that resolve to the same output name are refused explicitly.
    let firstDir = try temporaryDirectory("dup-a")
    let secondDir = try temporaryDirectory("dup-b")
    defer { try? FileManager.default.removeItem(at: firstDir) }
    defer { try? FileManager.default.removeItem(at: secondDir) }
    let first = firstDir.appendingPathComponent("same.pdf")
    let second = secondDir.appendingPathComponent("same.pdf")
    try PDFFixtures.imagePages().write(to: first)
    try PDFFixtures.imagePages().write(to: second)
    let duplicateRun = try await OCRBatchQueue.run(
      inputs: [first, second],
      settings: settings(output: outputDir, template: "{name}"),
      recognizer: ProbeRecognizer(probe: RecognitionProbe()))
    #expect(duplicateRun.items.map(\.status) == [.completed, .failed])
    #expect(duplicateRun.failureSummary.contains("output name"))

    // An output name that would overwrite the input is refused.
    let overwriteDir = try temporaryDirectory("overwrite-self")
    defer { try? FileManager.default.removeItem(at: overwriteDir) }
    let selfInput = overwriteDir.appendingPathComponent("scan.pdf")
    try PDFFixtures.imagePages().write(to: selfInput)
    let collisionSettings = OCRBatchSettings(
      outputDirectory: overwriteDir, nameTemplate: "{name}.pdf", languages: ["en-US"])
    let collisionRun = try await OCRBatchQueue.run(
      inputs: [selfInput], settings: collisionSettings,
      recognizer: ProbeRecognizer(probe: RecognitionProbe()))
    #expect(collisionRun.items.map(\.status) == [.failed])
    #expect(collisionRun.failureSummary.contains("overwrite the input"))

    // Missing reports are absent, not fabricated.
    #expect(OCRBatchQueue.readReport(in: outputDir, fileName: "missing.json") == nil)
  }
}
