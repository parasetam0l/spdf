import CryptoKit
import Foundation
import PDFCore

/// EXP-07: a batch conversion job center with reusable, validated profiles.
///
/// Each selected input is converted independently with the EXP-06 export
/// engine. Outputs use an explicit naming template and overwrite policy, files
/// are written atomically only after conversion succeeds, progress and
/// cancellation are cooperative, and the per-file report keeps every
/// conversion's fidelity losses. One failed conversion never invalidates or
/// hides already completed outputs, and inputs are never overwritten.
public enum ConversionOverwritePolicy: String, Codable, Sendable, Equatable {
  case uniqueSuffix
  case fail
  case replaceExistingOutputs

  public var displayName: String {
    switch self {
    case .uniqueSuffix: return "Keep existing, use a unique name"
    case .fail: return "Fail when the output exists"
    case .replaceExistingOutputs: return "Replace existing output files"
    }
  }
}

public enum ConversionScopeMode: String, Codable, Sendable, Equatable {
  case document
  case pageRange
}

public enum ConversionTextEncoding: String, Codable, Sendable, Equatable {
  case utf8
  case utf16
}

public enum ConversionLineEnding: String, Codable, Sendable, Equatable {
  case lf
  case crlf
}

public enum ConversionPageSeparator: String, Codable, Sendable, Equatable {
  case formFeed
  case blankLine
  case none
}

/// A reusable conversion profile. Settings only: importing one never runs code.
public struct ConversionProfile: Codable, Sendable, Equatable {
  public static let schemaVersion = 1
  public static let maximumNameLength = 120

  public var schemaVersion: Int
  public var name: String
  public var format: SelectionExportFormat
  public var fidelity: ExportFidelity
  public var scope: ConversionScopeMode
  public var pageRangeStart: Int?
  public var pageRangeEnd: Int?
  public var namingTemplate: String
  public var overwrite: ConversionOverwritePolicy
  public var imageDPI: Double
  public var textEncoding: ConversionTextEncoding
  public var lineEnding: ConversionLineEnding
  public var pageSeparator: ConversionPageSeparator
  public var acknowledgeAppearanceIsRendered: Bool
  public var documentTitle: String?

  public init(
    name: String = "Editable text",
    format: SelectionExportFormat = .text,
    fidelity: ExportFidelity = .editable,
    scope: ConversionScopeMode = .document,
    pageRangeStart: Int? = nil, pageRangeEnd: Int? = nil,
    namingTemplate: String = "{name}-{profile}",
    overwrite: ConversionOverwritePolicy = .uniqueSuffix,
    imageDPI: Double = 144,
    textEncoding: ConversionTextEncoding = .utf8,
    lineEnding: ConversionLineEnding = .lf,
    pageSeparator: ConversionPageSeparator = .blankLine,
    acknowledgeAppearanceIsRendered: Bool = false,
    documentTitle: String? = nil
  ) {
    self.schemaVersion = ConversionProfile.schemaVersion
    self.name = name
    self.format = format
    self.fidelity = fidelity
    self.scope = scope
    self.pageRangeStart = pageRangeStart
    self.pageRangeEnd = pageRangeEnd
    self.namingTemplate = namingTemplate
    self.overwrite = overwrite
    self.imageDPI = imageDPI
    self.textEncoding = textEncoding
    self.lineEnding = lineEnding
    self.pageSeparator = pageSeparator
    self.acknowledgeAppearanceIsRendered = acknowledgeAppearanceIsRendered
    self.documentTitle = documentTitle
  }

  public func validate() throws {
    guard schemaVersion == ConversionProfile.schemaVersion else {
      throw PDFError(
        .unsupported,
        "This conversion profile uses schema version \(schemaVersion); this build supports version \(ConversionProfile.schemaVersion)")
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= ConversionProfile.maximumNameLength else {
      throw PDFError(.malformed, "The profile name must be 1 to \(ConversionProfile.maximumNameLength) characters")
    }
    guard namingTemplate.contains("{name}") else {
      throw PDFError(.malformed, "The output name template needs a {name} token")
    }
    guard namingTemplate.count <= 120,
      !namingTemplate.contains("/"), !namingTemplate.contains("\\")
    else {
      throw PDFError(.malformed, "The output name template must be a plain file name")
    }
    guard imageDPI.isFinite, imageDPI >= 72, imageDPI <= 600 else {
      throw PDFError(.malformed, "The image DPI must be within 72...600")
    }
    if scope == .pageRange {
      guard let start = pageRangeStart, let end = pageRangeEnd, start >= 1, end >= start else {
        throw PDFError(.malformed, "A page-range profile needs an ordered 1-based start and end")
      }
    }
    if fidelity == .appearance {
      guard format.supportsAppearance else {
        throw PDFError(.unsupported, "The chosen format does not support an appearance export")
      }
      guard acknowledgeAppearanceIsRendered else {
        throw PDFError(
          .unsupported,
          "An appearance profile needs an explicit acknowledgement that the output is rendered, not editable")
      }
    }
  }

  public var scopeDescription: String {
    switch scope {
    case .document: return "whole document"
    case .pageRange:
      return "pages " + String(pageRangeStart ?? 1) + "-" + String(pageRangeEnd ?? 1)
    }
  }

  public func selectionExportOptions() -> SelectionExportOptions {
    let encoding: PDFTextExportOptions.Encoding = textEncoding == .utf16 ? .utf16 : .utf8
    let ending: PDFTextExportOptions.LineEnding = lineEnding == .crlf ? .crlf : .lf
    let separator: PDFTextExportOptions.PageSeparator
    switch pageSeparator {
    case .formFeed: separator = .formFeed
    case .blankLine: separator = .blankLine
    case .none: separator = .none
    }
    return SelectionExportOptions(
      textEncoding: encoding, lineEnding: ending, pageSeparator: separator,
      documentTitle: documentTitle, imageDPI: imageDPI,
      csvOptions: CSVExportOptions(encoding: .utf8),
      acknowledgeAppearanceIsRendered: acknowledgeAppearanceIsRendered)
  }

  public func exportScope() throws -> ExportScope {
    try validate()
    switch scope {
    case .document:
      return .document
    case .pageRange:
      guard let start = pageRangeStart, let end = pageRangeEnd else {
        throw PDFError(.malformed, "The page range is missing")
      }
      return .pageRange(start...end)
    }
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(self)
    guard data.count <= 1_048_576 else {
      throw PDFError(.limitExceeded, "The profile file exceeds the size limit")
    }
    return data
  }

  public static func decode(from data: Data) throws -> ConversionProfile {
    guard data.count <= 1_048_576 else {
      throw PDFError(.limitExceeded, "The profile file exceeds the size limit")
    }
    struct Probe: Decodable { let schemaVersion: Int }
    guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
      throw PDFError(.malformed, "The profile file is not a readable conversion profile")
    }
    guard probe.schemaVersion == ConversionProfile.schemaVersion else {
      throw PDFError(
        .unsupported,
        "This conversion profile uses schema version \(probe.schemaVersion); this build supports version \(ConversionProfile.schemaVersion)")
    }
    let profile: ConversionProfile
    do {
      profile = try JSONDecoder().decode(ConversionProfile.self, from: data)
    } catch {
      throw PDFError(.malformed, "The profile file could not be decoded: \(error.localizedDescription)")
    }
    try profile.validate()
    return profile
  }
}

public struct ConversionDestination: Sendable, Equatable {
  /// nil writes beside each input.
  public var folderURL: URL?

  public init(folderURL: URL? = nil) {
    self.folderURL = folderURL
  }

  public static var besideInput: ConversionDestination { ConversionDestination() }

  public var summary: String {
    if let folderURL { return "into " + folderURL.standardizedFileURL.path }
    return "beside each input"
  }
}

public final class ConversionCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public func requestCancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

public struct ConversionProgress: Sendable, Equatable {
  public enum Stage: String, Sendable, Equatable {
    case reading
    case converting
    case writing
    case finished
    case cancelled
    case failed
  }

  public let stage: Stage
  public let fileIndex: Int
  public let fileCount: Int
  public let fileName: String
}

public enum ConversionOutcomeStatus: String, Codable, Sendable, Equatable {
  case succeeded
  case failed
  case cancelled
  case notStarted

  public var displayName: String {
    switch self {
    case .succeeded: return "Succeeded"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    case .notStarted: return "Not started"
    }
  }
}

public struct ConversionFileResult: Codable, Sendable, Equatable {
  public var order: Int
  public var inputName: String
  public var inputPath: String
  public var status: ConversionOutcomeStatus
  public var outputPath: String?
  public var outputDigest: String?
  public var format: SelectionExportFormat
  public var fidelity: ExportFidelity
  public var scopeDescription: String
  /// Every conversion states its relevant fidelity losses.
  public var fidelityLosses: [String]
  public var failure: String?
}

public struct ConversionJobReport: Codable, Sendable, Equatable {
  public static let version = 1

  public var version: Int
  public var profileName: String
  public var startedAt: Date
  public var finishedAt: Date
  public var destinationSummary: String
  public var cancelled: Bool
  public var files: [ConversionFileResult]

  public init(
    profileName: String, startedAt: Date, finishedAt: Date,
    destinationSummary: String, cancelled: Bool, files: [ConversionFileResult]
  ) {
    self.version = ConversionJobReport.version
    self.profileName = profileName
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.destinationSummary = destinationSummary
    self.cancelled = cancelled
    self.files = files
  }

  public var succeededCount: Int { files.filter { $0.status == .succeeded }.count }
  public var failedCount: Int { files.filter { $0.status == .failed }.count }
  public var cancelledCount: Int { files.filter { $0.status == .cancelled }.count }
  public var notStartedCount: Int { files.filter { $0.status == .notStarted }.count }
  public var hasPartialSuccess: Bool {
    succeededCount > 0 && (failedCount + cancelledCount + notStartedCount) > 0
  }

  public var summary: String {
    var text = "\(succeededCount)/\(files.count) conversion\(files.count == 1 ? "" : "s") succeeded"
    if failedCount > 0 { text += ", \(failedCount) failed" }
    if cancelledCount > 0 { text += ", \(cancelledCount) cancelled" }
    if notStartedCount > 0 { text += ", \(notStartedCount) not started" }
    if hasPartialSuccess { text += " (partial success)" }
    if cancelled { text += " — cancelled" }
    return text
  }

  public var successInvariantHolds: Bool {
    files.allSatisfy { file in
      file.status != .succeeded || (file.outputPath != nil && file.outputDigest != nil)
    }
  }

  public func markdown() -> String {
    var lines = [
      "# Conversion job: \(profileName)",
      "",
      summary + ".",
      "Destination: " + destinationSummary,
      "",
      "| File | Status | Output | Fidelity losses |",
      "| --- | --- | --- | --- |",
    ]
    for file in files {
      let output = file.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
      var note = "—"
      if let failure = file.failure { note = "FAILED: " + failure }
      else if file.status == .cancelled { note = "cancelled before completion" }
      else if file.status == .notStarted { note = "not started" }
      else { note = file.fidelityLosses.joined(separator: " ") }
      lines.append(
        "| \(file.inputName) | \(file.status.displayName) | \(output) | \(note) |")
    }
    lines.append("")
    lines.append(
      "Every succeeded conversion states its fidelity losses; a failed or cancelled file has no output and does not invalidate completed outputs.")
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}

public struct ConversionPreviewFile: Sendable, Equatable {
  public let inputURL: URL
  public let outputURL: URL?
  public let fileName: String
  public let refusal: String?
}

public enum ConversionJobCenter {
  public static let maxFiles = 200
  public static let maxInputBytes = 256 * 1_024 * 1_024

  public static func preview(
    inputs: [URL], profile: ConversionProfile, destination: ConversionDestination
  ) throws -> [ConversionPreviewFile] {
    try profile.validate()
    try validateInputs(inputs)
    var used = Set<String>()
    let inputPaths = Set(inputs.map { $0.standardizedFileURL.path })
    return inputs.map { input in
      do {
        let output = try resolveOutput(
          input: input, profile: profile, destination: destination,
          taken: used, inputPaths: inputPaths)
        used.insert(output.path)
        return ConversionPreviewFile(
          inputURL: input, outputURL: output, fileName: input.lastPathComponent,
          refusal: nil)
      } catch {
        return ConversionPreviewFile(
          inputURL: input, outputURL: nil, fileName: input.lastPathComponent,
          refusal: error.localizedDescription)
      }
    }
  }

  /// Run one conversion per input. A failure is recorded per file and does not
  /// stop later files or invalidate completed outputs.
  public static func run(
    inputs: [URL], profile: ConversionProfile, destination: ConversionDestination,
    cancellation: ConversionCancellation? = nil,
    appearanceRenderer: AppearanceRenderer? = nil,
    progress: (@Sendable (ConversionProgress) -> Void)? = nil
  ) throws -> ConversionJobReport {
    try profile.validate()
    try validateInputs(inputs)
    let startedAt = Date()
    let inputPaths = Set(inputs.map { $0.standardizedFileURL.path })
    let exportScope = try profile.exportScope()
    let options = profile.selectionExportOptions()
    var used = Set<String>()
    var results: [ConversionFileResult] = []
    var wasCancelled = false

    for (index, input) in inputs.enumerated() {
      let fileName = input.lastPathComponent
      if cancellation?.isCancelled == true {
        wasCancelled = true
        results.append(
          ConversionFileResult(
            order: index, inputName: fileName,
            inputPath: input.standardizedFileURL.path, status: .cancelled,
            outputPath: nil, outputDigest: nil, format: profile.format,
            fidelity: profile.fidelity, scopeDescription: exportScope.summary,
            fidelityLosses: [], failure: nil))
        continue
      }
      progress?(ConversionProgress(
        stage: .reading, fileIndex: index, fileCount: inputs.count, fileName: fileName))
      let result: ConversionFileResult
      do {
        let values = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
          throw PDFError(.malformed, "The input is not a readable file")
        }
        guard size <= maxInputBytes else {
          throw PDFError(.limitExceeded, "The input exceeds the conversion size limit")
        }
        let data = try Data(contentsOf: input)
        let parsed = try PDFParser.parse(data)
        if profile.fidelity == .appearance, appearanceRenderer == nil {
          throw PDFError(.unsupported, "No appearance renderer is registered")
        }
        let outputURL = try resolveOutput(
          input: input, profile: profile, destination: destination,
          taken: used, inputPaths: inputPaths)
        used.insert(outputURL.path)
        progress?(ConversionProgress(
          stage: .converting, fileIndex: index, fileCount: inputs.count, fileName: fileName))
        if cancellation?.isCancelled == true {
          wasCancelled = true
          results.append(
            ConversionFileResult(
              order: index, inputName: fileName,
              inputPath: input.standardizedFileURL.path, status: .cancelled,
              outputPath: nil, outputDigest: nil, format: profile.format,
              fidelity: profile.fidelity, scopeDescription: exportScope.summary,
              fidelityLosses: [], failure: nil))
          continue
        }
        let payload = try SelectionExport.export(
          format: profile.format, scope: exportScope, fidelity: profile.fidelity,
          options: options, in: parsed.graph, pageIDs: parsed.pageIDs,
          appearanceRenderer: appearanceRenderer)
        if cancellation?.isCancelled == true {
          wasCancelled = true
          results.append(
            ConversionFileResult(
              order: index, inputName: fileName,
              inputPath: input.standardizedFileURL.path, status: .cancelled,
              outputPath: nil, outputDigest: nil, format: profile.format,
              fidelity: profile.fidelity, scopeDescription: exportScope.summary,
              fidelityLosses: payload.limitations, failure: nil))
          continue
        }
        progress?(ConversionProgress(
          stage: .writing, fileIndex: index, fileCount: inputs.count, fileName: fileName))
        try atomicWrite(
          payload.data, to: outputURL,
          overwrite: profile.overwrite == .replaceExistingOutputs)
        result = ConversionFileResult(
          order: index, inputName: fileName, inputPath: input.standardizedFileURL.path,
          status: .succeeded, outputPath: outputURL.path,
          outputDigest: digest(payload.data), format: profile.format,
          fidelity: profile.fidelity, scopeDescription: payload.scopeDescription,
          fidelityLosses: payload.limitations, failure: nil)
      } catch {
        result = ConversionFileResult(
          order: index, inputName: fileName, inputPath: input.standardizedFileURL.path,
          status: .failed, outputPath: nil, outputDigest: nil, format: profile.format,
          fidelity: profile.fidelity, scopeDescription: exportScope.summary,
          fidelityLosses: [], failure: error.localizedDescription)
      }
      results.append(result)
    }
    progress?(ConversionProgress(
      stage: wasCancelled ? .cancelled : .finished,
      fileIndex: 0, fileCount: inputs.count, fileName: ""))
    let report = ConversionJobReport(
      profileName: profile.name, startedAt: startedAt, finishedAt: Date(),
      destinationSummary: destination.summary, cancelled: wasCancelled, files: results)
    guard report.successInvariantHolds else {
      throw PDFError(.malformed, "Internal error: a converted file is missing its output identity")
    }
    return report
  }

  // MARK: - Helpers

  static func validateInputs(_ inputs: [URL]) throws {
    guard !inputs.isEmpty else {
      throw PDFError(.malformed, "Choose at least one input file")
    }
    guard inputs.count <= maxFiles else {
      throw PDFError(.limitExceeded, "A conversion job supports at most \(maxFiles) files")
    }
    guard Set(inputs.map { $0.standardizedFileURL.path }).count == inputs.count else {
      throw PDFError(.malformed, "The input list contains the same file more than once")
    }
  }

  static func resolveOutput(
    input: URL, profile: ConversionProfile, destination: ConversionDestination,
    taken: Set<String>, inputPaths: Set<String>
  ) throws -> URL {
    let stem = input.deletingPathExtension().lastPathComponent
    var token = profile.name.lowercased().replacingOccurrences(
      of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    token = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if token.isEmpty { token = "profile" }
    var base = profile.namingTemplate
      .replacingOccurrences(of: "{name}", with: stem)
      .replacingOccurrences(of: "{profile}", with: token)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty, URL(fileURLWithPath: base).lastPathComponent == base,
      !base.contains("/"), !base.contains("\\"), base.utf8.count <= 200
    else {
      throw PDFError(.malformed, "The output name resolved to an invalid file name")
    }
    let extensionText = profile.format.fileExtension
    if !base.lowercased().hasSuffix("." + extensionText) {
      base += "." + extensionText
    }
    let directory: URL
    if let folder = destination.folderURL {
      directory = folder.standardizedFileURL
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        throw PDFError(.malformed, "The destination is not a folder")
      }
    } else {
      directory = input.deletingLastPathComponent().standardizedFileURL
    }
    var candidate = directory.appendingPathComponent(base).standardizedFileURL
    var counter = 2
    while true {
      if inputPaths.contains(candidate.path) {
        throw PDFError(
          .malformed,
          "The output would overwrite an input file; choose another destination or name template")
      }
      let exists = FileManager.default.fileExists(atPath: candidate.path)
      let reserved = taken.contains(candidate.path)
      if !exists && !reserved { break }
      if exists && profile.overwrite == .replaceExistingOutputs { break }
      switch profile.overwrite {
      case .fail:
        throw PDFError(
          .unsupported, "The output " + candidate.lastPathComponent + " already exists")
      case .uniqueSuffix, .replaceExistingOutputs:
        guard counter <= 9_999 else {
          throw PDFError(.limitExceeded, "No unique output name could be resolved")
        }
        let root = (base as NSString).deletingPathExtension
        candidate = directory
          .appendingPathComponent(root + "-" + String(counter) + "." + extensionText)
          .standardizedFileURL
        counter += 1
      }
    }
    return candidate
  }

  static func atomicWrite(_ data: Data, to url: URL, overwrite: Bool) throws {
    let manager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(
      "." + url.lastPathComponent + ".partial-" + UUID().uuidString)
    defer { try? manager.removeItem(at: temporary) }
    try data.write(to: temporary, options: [])
    if manager.fileExists(atPath: url.path) {
      guard overwrite else {
        throw PDFError(.unsupported, "The output file already exists: " + url.lastPathComponent)
      }
      _ = try manager.replaceItemAt(url, withItemAt: temporary)
    } else {
      try manager.moveItem(at: temporary, to: url)
    }
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
