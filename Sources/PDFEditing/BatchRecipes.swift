import CryptoKit
import Foundation
import PDFCore

/// AUT-03/AUT-04: reusable batch action recipes and a resilient runner.
///
/// AUT-03 (recipe): compose existing safe operations into an ordered, typed
/// recipe that can be previewed against selected inputs, saved/shared as
/// validated JSON, and mapped to a per-file outcome report.
///
/// AUT-04 (resilience): the runner writes a per-file checkpoint journal,
/// supports stop/resume and safe retry, applies explicit destination policies,
/// writes every output atomically only after all steps succeed, and reports
/// partial success honestly. An interrupted or failed file is never reported
/// as a success, and a destination that would overwrite an input is always
/// refused.
///
/// Boundary: this module composes operations; it does not implement OCR
/// recognition or DOCX/Office export itself. Those steps require a
/// service performer registered by the app layer, and the preview names the
/// missing service instead of silently skipping the step. The supported
/// operation set is declared by BatchActionKind; no arbitrary code or script
/// runs from a recipe.
public enum BatchLimits {
  public static let maxRecipeBytes = 1_048_576
  public static let maxCheckpointBytes = 4_194_304
  public static let maxSteps = 20
  public static let maxFiles = 200
  public static let maxInputBytes = 256 * 1_024 * 1_024
  public static let maxTotalInputBytes = 2 * 1_024 * 1_024 * 1_024
  public static let maxOutputNameBytes = 200
}

/// The supported safe operations a recipe can compose.
public enum BatchActionKind: String, Codable, Sendable, Equatable, CaseIterable {
  case ocr
  case batesNumbering
  case optimize
  case preflight
  case exportText
  case exportDOCX

  public var displayName: String {
    switch self {
    case .ocr: return "OCR (searchable text)"
    case .batesNumbering: return "Bates numbering"
    case .optimize: return "Lossless optimize"
    case .preflight: return "Preflight check"
    case .exportText: return "Export text"
    case .exportDOCX: return "Export DOCX"
    }
  }

  /// Steps whose work is supplied by the app/MacServices layer rather than by
  /// the owned PDFEditing implementation.
  public var requiresService: Bool {
    switch self {
    case .ocr, .exportDOCX: return true
    default: return false
    }
  }

  /// A terminal step converts/writes the final representation. At most one is
  /// allowed and it must be the last enabled step.
  public var isTerminalExport: Bool {
    switch self {
    case .exportText, .exportDOCX: return true
    default: return false
    }
  }

  public var outputExtension: String {
    switch self {
    case .exportText: return "txt"
    case .exportDOCX: return "docx"
    default: return "pdf"
    }
  }

  public var declaredProfile: String {
    switch self {
    case .ocr:
      return "Local OCR service step; recognized text is added as an untagged searchable layer by the existing OCR pipeline."
    case .batesNumbering:
      return "Existing Bates planner and AddRepeatedMarkCommand; one continuous or per-file restarting sequence across the ordered inputs."
    case .optimize:
      return "Existing lossless PDFOptimizer preset; no lossy image conversion and no signed/encrypted input support."
    case .preflight:
      return "Existing read-only print preflight checks; records findings and can fail the file when configured."
    case .exportText:
      return "Existing PDFTextExport plain text in layout reading order."
    case .exportDOCX:
      return "Existing DOCX reconstruction/export service; limitations are recorded in the step notes."
    }
  }
}

public enum BatchBatesPlacement: String, Codable, Sendable, Equatable, CaseIterable {
  case topCenter
  case bottomCenter
  case bottomRight

  var repeatedMarkPlacement: RepeatedMarkPlacement {
    switch self {
    case .topCenter: return .topCenter
    case .bottomCenter: return .bottomCenter
    case .bottomRight: return .bottomRight
    }
  }

  public var displayName: String {
    switch self {
    case .topCenter: return "Top center"
    case .bottomCenter: return "Bottom center"
    case .bottomRight: return "Bottom right"
    }
  }
}

public struct BatchOCRSettings: Codable, Sendable, Equatable {
  public var languages: [String]
  public var replacesExistingLayer: Bool

  public init(languages: [String] = ["en-US"], replacesExistingLayer: Bool = false) {
    self.languages = languages
    self.replacesExistingLayer = replacesExistingLayer
  }

  func validate() throws {
    guard !languages.isEmpty, languages.count <= 8 else {
      throw PDFError(.malformed, "OCR needs 1 to 8 languages")
    }
    for language in languages {
      guard language.count <= 35,
        language.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" })
      else {
        throw PDFError(.malformed, "OCR language identifiers must be plain language tags")
      }
    }
  }

  public var summary: String {
    "OCR " + languages.joined(separator: "+")
      + (replacesExistingLayer ? ", replacing an existing generated layer" : "")
  }
}

public struct BatchBatesSettings: Codable, Sendable, Equatable {
  public var prefix: String
  public var suffix: String
  public var startNumber: Int
  public var digits: Int
  public var continuesAcrossFiles: Bool
  public var excludedPages: [Int]
  public var leadingExcludedPages: Int
  public var placement: BatchBatesPlacement
  public var fontSize: Double

  public init(
    prefix: String = "", suffix: String = "", startNumber: Int = 1, digits: Int = 6,
    continuesAcrossFiles: Bool = true, excludedPages: [Int] = [],
    leadingExcludedPages: Int = 0, placement: BatchBatesPlacement = .bottomCenter,
    fontSize: Double = 9
  ) {
    self.prefix = prefix
    self.suffix = suffix
    self.startNumber = startNumber
    self.digits = digits
    self.continuesAcrossFiles = continuesAcrossFiles
    self.excludedPages = excludedPages
    self.leadingExcludedPages = leadingExcludedPages
    self.placement = placement
    self.fontSize = fontSize
  }

  func validate() throws {
    guard startNumber >= 0, startNumber <= 9_999_999_999 else {
      throw PDFError(.limitExceeded, "The Bates start number is outside the supported range")
    }
    guard (1...12).contains(digits) else {
      throw PDFError(.malformed, "Bates digits must be between 1 and 12")
    }
    guard prefix.utf8.count <= 200, suffix.utf8.count <= 200 else {
      throw PDFError(.limitExceeded, "The Bates prefix or suffix exceeds the size limit")
    }
    guard leadingExcludedPages >= 0, excludedPages.allSatisfy({ $0 >= 1 }) else {
      throw PDFError(.malformed, "Excluded Bates pages are 1-based and must be positive")
    }
    guard fontSize.isFinite, fontSize >= 2, fontSize <= 400 else {
      throw PDFError(.malformed, "The Bates font size is outside the supported range")
    }
  }

  public var summary: String {
    "Bates " + prefix + "{n}" + suffix + " from " + String(startNumber) + " ("
      + String(digits) + " digits, "
      + (continuesAcrossFiles ? "continuous across files" : "restarts per file") + ")"
  }
}

public struct BatchOptimizeSettings: Codable, Sendable, Equatable {
  public var removeMetadata: Bool

  public init(removeMetadata: Bool = false) {
    self.removeMetadata = removeMetadata
  }

  public var summary: String {
    "Lossless optimize" + (removeMetadata ? " (metadata removed)" : "")
  }
}

public struct BatchPreflightSettings: Codable, Sendable, Equatable {
  public var failOnErrors: Bool

  public init(failOnErrors: Bool = false) {
    self.failOnErrors = failOnErrors
  }

  public var summary: String {
    "Preflight print checks" + (failOnErrors ? " (fail the file on errors)" : "")
  }
}

/// One ordered recipe step. Exactly the settings field matching the kind is
/// present; the JSON stays readable for sharing and never carries code.
public struct BatchRecipeStep: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var kind: BatchActionKind
  public var enabled: Bool
  public var ocr: BatchOCRSettings?
  public var bates: BatchBatesSettings?
  public var optimize: BatchOptimizeSettings?
  public var preflight: BatchPreflightSettings?

  public init(
    kind: BatchActionKind, enabled: Bool = true, ocr: BatchOCRSettings? = nil,
    bates: BatchBatesSettings? = nil, optimize: BatchOptimizeSettings? = nil,
    preflight: BatchPreflightSettings? = nil, id: UUID = UUID()
  ) {
    self.id = id
    self.kind = kind
    self.enabled = enabled
    self.ocr = ocr ?? (kind == .ocr ? BatchOCRSettings() : nil)
    self.bates = bates ?? (kind == .batesNumbering ? BatchBatesSettings() : nil)
    self.optimize = optimize ?? (kind == .optimize ? BatchOptimizeSettings() : nil)
    self.preflight = preflight ?? (kind == .preflight ? BatchPreflightSettings() : nil)
  }

  public var settingsSummary: String {
    switch kind {
    case .ocr: return ocr?.summary ?? "OCR settings missing"
    case .batesNumbering: return bates?.summary ?? "Bates settings missing"
    case .optimize: return optimize?.summary ?? "Optimize settings missing"
    case .preflight: return preflight?.summary ?? "Preflight settings missing"
    case .exportText, .exportDOCX: return kind.declaredProfile
    }
  }

  func validate() throws {
    switch kind {
    case .ocr:
      guard let ocr else { throw PDFError(.malformed, "The OCR step has no settings") }
      try ocr.validate()
    case .batesNumbering:
      guard let bates else { throw PDFError(.malformed, "The Bates step has no settings") }
      try bates.validate()
    case .optimize:
      guard optimize != nil else { throw PDFError(.malformed, "The optimize step has no settings") }
    case .preflight:
      guard preflight != nil else { throw PDFError(.malformed, "The preflight step has no settings") }
    case .exportText, .exportDOCX:
      break
    }
  }
}

public struct BatchRecipe: Codable, Sendable, Equatable {
  public static let schemaVersion = 1
  public static let maximumNameLength = 120
  public static let maximumNotesLength = 2_000

  public var schemaVersion: Int
  public var name: String
  public var notes: String
  public var steps: [BatchRecipeStep]
  public var createdAt: Date?

  public init(
    name: String, notes: String = "", steps: [BatchRecipeStep], createdAt: Date? = nil
  ) {
    self.schemaVersion = BatchRecipe.schemaVersion
    self.name = name
    self.notes = notes
    self.steps = steps
    self.createdAt = createdAt
  }

  public var enabledSteps: [BatchRecipeStep] { steps.filter(\.enabled) }

  public var terminalExport: BatchActionKind? {
    enabledSteps.last(where: \.kind.isTerminalExport)?.kind
  }

  public var outputExtension: String {
    terminalExport?.outputExtension ?? "pdf"
  }

  public func validate() throws {
    guard schemaVersion == BatchRecipe.schemaVersion else {
      throw PDFError(
        .unsupported,
        "This recipe uses schema version \(schemaVersion); this build supports version \(BatchRecipe.schemaVersion)")
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, trimmedName.count <= BatchRecipe.maximumNameLength else {
      throw PDFError(.malformed, "The recipe name must be 1 to \(BatchRecipe.maximumNameLength) characters")
    }
    guard notes.count <= BatchRecipe.maximumNotesLength else {
      throw PDFError(.limitExceeded, "The recipe notes exceed the size limit")
    }
    guard !steps.isEmpty, steps.count <= BatchLimits.maxSteps else {
      throw PDFError(.malformed, "A recipe needs 1 to \(BatchLimits.maxSteps) steps")
    }
    guard Set(steps.map(\.id)).count == steps.count else {
      throw PDFError(.malformed, "The recipe contains duplicate step identities")
    }
    let enabled = enabledSteps
    guard !enabled.isEmpty else {
      throw PDFError(.malformed, "A recipe needs at least one enabled step")
    }
    for (index, step) in steps.enumerated() {
      if step.enabled { try step.validate() }
      if step.kind.isTerminalExport, step.enabled, index != steps.count - 1 {
        throw PDFError(.malformed, "The export step must be the last step in the recipe")
      }
    }
    let terminals = enabled.filter { $0.kind.isTerminalExport }
    guard terminals.count <= 1 else {
      throw PDFError(.malformed, "A recipe can contain at most one export step")
    }
  }

  /// Canonical UTF-8 JSON used for sharing and for checkpoint identity.
  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    guard data.count <= BatchLimits.maxRecipeBytes else {
      throw PDFError(.limitExceeded, "The recipe file exceeds the size limit")
    }
    return data
  }

  public var digest: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(self)) ?? Data()
    return BatchDigest.hex(data)
  }

  /// Import a shared recipe with explicit versioning and validation. Unknown
  /// versions and malformed settings are refused before any file is touched.
  public static func decode(from data: Data) throws -> BatchRecipe {
    guard data.count <= BatchLimits.maxRecipeBytes else {
      throw PDFError(.limitExceeded, "The recipe file exceeds the size limit")
    }
    struct VersionProbe: Decodable { let schemaVersion: Int }
    let probe = try? JSONDecoder().decode(VersionProbe.self, from: data)
    guard let probe else {
      throw PDFError(.malformed, "The recipe file is not a readable recipe")
    }
    guard probe.schemaVersion == BatchRecipe.schemaVersion else {
      throw PDFError(
        .unsupported,
        "This recipe uses schema version \(probe.schemaVersion); this build supports version \(BatchRecipe.schemaVersion)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recipe: BatchRecipe
    do {
      recipe = try decoder.decode(BatchRecipe.self, from: data)
    } catch {
      throw PDFError(.malformed, "The recipe file could not be decoded: \(error.localizedDescription)")
    }
    try recipe.validate()
    return recipe
  }
}

/// Destination policy for batch outputs. Inputs are never replaced: the
/// in-place mode is deliberately not offered, and any resolved output that
/// equals an input path is refused even when overwriting outputs is enabled.
public struct BatchDestinationPolicy: Codable, Sendable, Equatable {
  public enum Mode: String, Codable, Sendable, Equatable {
    case besideInput
    case folder
  }

  public enum Collision: String, Codable, Sendable, Equatable {
    case uniqueSuffix
    case fail
  }

  public var mode: Mode
  public var folderPath: String?
  public var collision: Collision
  public var overwriteExistingOutputs: Bool
  /// Tokens: {name} (input file stem) and {recipe} (recipe name, sanitized).
  public var nameTemplate: String

  public init(
    mode: Mode = .besideInput, folderPath: String? = nil,
    collision: Collision = .uniqueSuffix, overwriteExistingOutputs: Bool = false,
    nameTemplate: String = "{name}-{recipe}"
  ) {
    self.mode = mode
    self.folderPath = folderPath
    self.collision = collision
    self.overwriteExistingOutputs = overwriteExistingOutputs
    self.nameTemplate = nameTemplate
  }

  public static var besideInput: BatchDestinationPolicy { BatchDestinationPolicy() }

  public static func folder(_ url: URL, nameTemplate: String = "{name}-{recipe}") -> BatchDestinationPolicy {
    BatchDestinationPolicy(
      mode: .folder, folderPath: url.standardizedFileURL.path,
      nameTemplate: nameTemplate)
  }

  public func validate() throws {
    guard nameTemplate.contains("{name}") else {
      throw PDFError(.malformed, "The output name template needs a {name} token")
    }
    guard nameTemplate.count <= 120,
      !nameTemplate.contains("/"), !nameTemplate.contains("\\")
    else {
      throw PDFError(.malformed, "The output name template must be a plain file name")
    }
    switch mode {
    case .besideInput:
      guard folderPath == nil else {
        throw PDFError(.malformed, "A beside-input policy cannot also carry a folder path")
      }
    case .folder:
      guard let folderPath, !folderPath.isEmpty else {
        throw PDFError(.malformed, "A folder destination needs a folder path")
      }
      let url = URL(fileURLWithPath: folderPath)
      guard url.path.hasPrefix("/"), url.pathComponents.contains("/") else {
        throw PDFError(.malformed, "The destination folder must be an absolute path")
      }
      guard url.standardizedFileURL.path == url.path || folderPath.hasSuffix("/") else {
        throw PDFError(.malformed, "The destination folder path is not normalized")
      }
    }
  }

  public var summary: String {
    let whereText: String
    switch mode {
    case .besideInput: whereText = "beside each input"
    case .folder: whereText = "into " + (folderPath ?? "the chosen folder")
    }
    let collisionText: String
    switch collision {
    case .uniqueSuffix: collisionText = "unique names on collision"
    case .fail: collisionText = "fail on name collision"
    }
    return whereText + ", " + collisionText
      + (overwriteExistingOutputs ? ", existing outputs may be replaced" : ", existing files are kept")
  }
}

/// Checkpoint journal entry state.
public enum BatchFileStatus: String, Codable, Sendable, Equatable {
  case notStarted
  case running
  case succeeded
  case failed
  case interrupted
}

public struct BatchCheckpointFile: Codable, Sendable, Equatable {
  public var order: Int
  public var inputPath: String
  public var fileName: String
  public var inputDigest: String
  public var status: BatchFileStatus
  public var outputPath: String?
  public var outputDigest: String?
  public var completedSteps: Int
  public var stepStates: [String: String]
  public var error: String?
  public var resumed: Bool
}

public struct BatchCheckpoint: Codable, Sendable, Equatable {
  public static let version = 1
  public var version: Int
  public var runID: UUID
  public var recipeName: String
  public var recipeDigest: String
  public var destinationDirectory: String
  public var inputs: [String]
  public var files: [BatchCheckpointFile]
  public var crossFileStates: [String: String]
  public var updatedAt: Date
}

/// The plan preview for one input file.
public struct BatchPreviewFile: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    case ready
    case refused
  }

  public let inputURL: URL
  public let outputURL: URL?
  public let fileName: String
  public let pageCount: Int?
  public let status: Status
  public let stepSummaries: [String]
  public let serviceSteps: [BatchActionKind]
  public let warnings: [String]
  public let refusals: [String]
}

public struct BatchPreview: Sendable, Equatable {
  public let recipeName: String
  public let destinationSummary: String
  public let files: [BatchPreviewFile]
  public let warnings: [String]

  public var readyCount: Int { files.filter { $0.status == .ready }.count }
  public var refusedCount: Int { files.filter { $0.status == .refused }.count }
  public var canRun: Bool { !files.isEmpty && refusedCount == 0 }

  public var summary: String {
    "\(readyCount) file\(readyCount == 1 ? "" : "s") ready"
      + (refusedCount > 0 ? ", \(refusedCount) refused" : "")
  }
}

public enum BatchDigest {
  public static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Step performers

/// One step invocation for one file. The previous step's data is supplied as
/// source bytes; state is the opaque per-step cross-file state (for example the
/// next Bates number), so independent performers stay stateless.
public struct BatchStepRequest: Sendable {
  public let step: BatchRecipeStep
  public let inputURL: URL
  public let sourceBytes: Data
  public let fileIndex: Int
  public let fileName: String
  public let priorState: Data?

  public init(
    step: BatchRecipeStep, inputURL: URL, sourceBytes: Data, fileIndex: Int,
    fileName: String, priorState: Data?
  ) {
    self.step = step
    self.inputURL = inputURL
    self.sourceBytes = sourceBytes
    self.fileIndex = fileIndex
    self.fileName = fileName
    self.priorState = priorState
  }
}

public struct BatchStepOutcome: Sendable, Equatable {
  public let data: Data
  public let note: String
  public let state: Data?
  public let warnings: [String]

  public init(data: Data, note: String, state: Data? = nil, warnings: [String] = []) {
    self.data = data
    self.note = note
    self.state = state
    self.warnings = warnings
  }
}

/// Implemented by the owned core for pure PDF operations and by the app layer
/// for OCR and DOCX export. Performers are synchronous; the app runs the whole
/// batch off the main actor.
public protocol BatchStepPerformer: Sendable {
  var kind: BatchActionKind { get }
  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome
}

/// Type-erased performer so the registry stays Sendable without storing
/// arbitrary existential state.
public struct BatchPerformerBox: Sendable {
  public let kind: BatchActionKind
  private let body: @Sendable (BatchStepRequest) throws -> BatchStepOutcome

  public init<P: BatchStepPerformer>(_ performer: P) {
    self.kind = performer.kind
    self.body = { request in try performer.perform(request) }
  }

  public func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    try body(request)
  }
}

public struct BatchPerformerRegistry: Sendable {
  private var boxes: [BatchActionKind: BatchPerformerBox]

  public init(_ performers: [any BatchStepPerformer] = []) {
    var boxes: [BatchActionKind: BatchPerformerBox] = [:]
    for performer in performers { boxes[performer.kind] = BatchPerformerBox(performer) }
    self.boxes = boxes
  }

  public func performer(for kind: BatchActionKind) -> BatchPerformerBox? {
    boxes[kind]
  }

  public var availableKinds: [BatchActionKind] {
    BatchActionKind.allCases.filter { boxes[$0] != nil }
  }

  public func registering(_ performers: [any BatchStepPerformer]) -> BatchPerformerRegistry {
    var boxes = self.boxes
    for performer in performers { boxes[performer.kind] = BatchPerformerBox(performer) }
    var registry = self
    registry.boxes = boxes
    return registry
  }

  /// Enabled recipe kinds that have no registered performer, in recipe order.
  public func missingKinds(for recipe: BatchRecipe) -> [BatchActionKind] {
    var missing: [BatchActionKind] = []
    for step in recipe.enabledSteps where boxes[step.kind] == nil {
      if !missing.contains(step.kind) { missing.append(step.kind) }
    }
    return missing
  }
}

// MARK: - Run control and progress

/// Cooperative stop flag shared with the app's Stop button. The runner checks
/// it between steps and immediately before writing an output, so a stop never
/// produces or reports a partial file.
public final class BatchRunControl: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false

  public init() {}

  public func requestStop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  public var isStopRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

public struct BatchProgress: Sendable, Equatable {
  public enum Stage: String, Sendable, Equatable {
    case preparing
    case processing
    case writing
    case finished
    case stopped
    case failed
  }

  public let stage: Stage
  public let fileIndex: Int
  public let fileCount: Int
  public let fileName: String
  public let completedSteps: Int
  public let stepCount: Int

  public init(
    stage: Stage, fileIndex: Int, fileCount: Int, fileName: String,
    completedSteps: Int, stepCount: Int
  ) {
    self.stage = stage
    self.fileIndex = fileIndex
    self.fileCount = fileCount
    self.fileName = fileName
    self.completedSteps = completedSteps
    self.stepCount = stepCount
  }
}

// MARK: - Options, report, result

public struct BatchRunOptions: Sendable {
  public var destination: BatchDestinationPolicy
  /// Explicit checkpoint path; nil derives one in the destination directory.
  public var checkpointURL: URL?
  public var resume: Bool
  public var continueOnError: Bool
  public var maxFiles: Int
  public var maxTotalInputBytes: Int

  public init(
    destination: BatchDestinationPolicy = .besideInput, checkpointURL: URL? = nil,
    resume: Bool = false, continueOnError: Bool = true, maxFiles: Int = BatchLimits.maxFiles,
    maxTotalInputBytes: Int = BatchLimits.maxTotalInputBytes
  ) {
    self.destination = destination
    self.checkpointURL = checkpointURL
    self.resume = resume
    self.continueOnError = continueOnError
    self.maxFiles = maxFiles
    self.maxTotalInputBytes = maxTotalInputBytes
  }
}

public enum BatchOutcomeStatus: String, Codable, Sendable, Equatable {
  case succeeded
  case failed
  case interrupted
  case notStarted

  public var displayName: String {
    switch self {
    case .succeeded: return "Succeeded"
    case .failed: return "Failed"
    case .interrupted: return "Interrupted"
    case .notStarted: return "Not started"
    }
  }

  public var isSuccess: Bool { self == .succeeded }
}

public struct BatchFileOutcome: Codable, Sendable, Equatable {
  public var order: Int
  public var fileName: String
  public var inputPath: String
  public var status: BatchOutcomeStatus
  public var outputPath: String?
  public var outputDigest: String?
  public var completedSteps: [String]
  public var warnings: [String]
  public var failure: String?
  public var resumed: Bool
}

public struct BatchRunReport: Codable, Sendable, Equatable {
  public static let version = 1

  public var version: Int
  public var runID: UUID
  public var recipeName: String
  public var recipeDigest: String
  public var startedAt: Date
  public var finishedAt: Date
  public var destinationSummary: String
  public var checkpointPath: String?
  public var stopped: Bool
  public var abortedByError: Bool
  public var files: [BatchFileOutcome]

  public init(
    runID: UUID, recipeName: String, recipeDigest: String, startedAt: Date,
    finishedAt: Date, destinationSummary: String, checkpointPath: String?,
    stopped: Bool, abortedByError: Bool, files: [BatchFileOutcome]
  ) {
    self.version = BatchRunReport.version
    self.runID = runID
    self.recipeName = recipeName
    self.recipeDigest = recipeDigest
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.destinationSummary = destinationSummary
    self.checkpointPath = checkpointPath
    self.stopped = stopped
    self.abortedByError = abortedByError
    self.files = files
  }

  public var succeededCount: Int { files.filter { $0.status == .succeeded }.count }
  public var failedCount: Int { files.filter { $0.status == .failed }.count }
  public var interruptedCount: Int { files.filter { $0.status == .interrupted }.count }
  public var notStartedCount: Int { files.filter { $0.status == .notStarted }.count }
  public var hasPartialSuccess: Bool {
    succeededCount > 0 && (failedCount + interruptedCount + notStartedCount) > 0
  }

  public var summary: String {
    var text = "\(succeededCount)/\(files.count) file\(files.count == 1 ? "" : "s") succeeded"
    if failedCount > 0 { text += ", \(failedCount) failed" }
    if interruptedCount > 0 { text += ", \(interruptedCount) interrupted" }
    if notStartedCount > 0 { text += ", \(notStartedCount) not started" }
    if hasPartialSuccess { text += " (partial success)" }
    if stopped { text += " — stopped by user" }
    if abortedByError { text += " — stopped after an error" }
    return text
  }

  public var failureSummary: String {
    files.compactMap { file in
      guard let failure = file.failure else { return nil }
      return "\(file.fileName): \(failure)"
    }.joined(separator: "\n")
  }

  /// Every reported success has an output path and digest; the runner maintains
  /// this invariant, and the report validates it before it can be shared.
  public var successInvariantHolds: Bool {
    files.allSatisfy { file in
      if file.status == .succeeded {
        return file.outputPath != nil && file.outputDigest != nil
      }
      return file.outputPath == nil || file.status == .succeeded
    }
  }

  public func markdown() -> String {
    var lines = [
      "# Batch run: \(recipeName)",
      "",
      summary + ".",
      "Checkpoint: " + (checkpointPath ?? "none"),
      "",
      "| File | Status | Output | Notes |",
      "| --- | --- | --- | --- |",
    ]
    for file in files {
      let output = file.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
      var note = file.completedSteps.joined(separator: "; ")
      if let failure = file.failure {
        note = "FAILED: " + failure
      }
      if file.status == .interrupted { note = "interrupted; resume or retry to finish" }
      if file.status == .notStarted { note = "not started" }
      lines.append("| \(file.fileName) | \(file.status.displayName) | \(output) | \(note) |")
    }
    if !failureSummary.isEmpty {
      lines.append("")
      lines.append("## Failures")
      for line in failureSummary.components(separatedBy: "\n") { lines.append("- " + line) }
    }
    lines.append("")
    lines.append(
      "Boundary: outcomes describe this recipe's supported operations on these inputs; a success means the final output was written atomically after every step succeeded. Partial success is never reported as complete.")
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}

public struct BatchRunResult: Sendable, Equatable {
  public let report: BatchRunReport
  public let checkpointURL: URL

  public init(report: BatchRunReport, checkpointURL: URL) {
    self.report = report
    self.checkpointURL = checkpointURL
  }
}

// MARK: - File IO helpers

enum BatchFileIO {
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
        throw PDFError(.unsupported, "The output file already exists: \(url.lastPathComponent)")
      }
      _ = try manager.replaceItemAt(url, withItemAt: temporary)
    } else {
      do {
        try manager.moveItem(at: temporary, to: url)
      } catch {
        if manager.fileExists(atPath: url.path) {
          throw PDFError(.unsupported, "The output file appeared during the write: \(url.lastPathComponent)")
        }
        throw error
      }
    }
  }

  static func writeCheckpoint(_ checkpoint: BatchCheckpoint, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(checkpoint)
    guard data.count <= BatchLimits.maxCheckpointBytes else {
      throw PDFError(.limitExceeded, "The batch checkpoint exceeds the size limit")
    }
    let manager = FileManager.default
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
  }

  static func readCheckpoint(_ url: URL) throws -> BatchCheckpoint {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values?.isRegularFile == true, let size = values?.fileSize,
      size >= 0, size <= BatchLimits.maxCheckpointBytes
    else {
      throw PDFError(.malformed, "The batch checkpoint is missing or unreadable")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let checkpoint: BatchCheckpoint
    do {
      checkpoint = try decoder.decode(BatchCheckpoint.self, from: Data(contentsOf: url))
    } catch {
      throw PDFError(.malformed, "The batch checkpoint could not be decoded: \(error.localizedDescription)")
    }
    guard checkpoint.version == BatchCheckpoint.version else {
      throw PDFError(
        .unsupported,
        "The batch checkpoint uses version \(checkpoint.version); this build supports version \(BatchCheckpoint.version)")
    }
    return checkpoint
  }

  static func sanitizedRecipeToken(_ name: String) -> String {
    var token = name.lowercased()
    token = token.replacingOccurrences(
      of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    token = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return token.isEmpty ? "recipe" : String(token.prefix(40))
  }
}

// MARK: - Planner

public enum BatchPlanner {
  /// AUT-03: preview the ordered plan for these inputs without touching files.
  /// Per-file refusals (missing service performer, destination conflict) are
  /// visible before the run starts.
  public static func preview(
    recipe: BatchRecipe, inputs: [URL], destination: BatchDestinationPolicy,
    performers: BatchPerformerRegistry = BatchStandardPerformers.registry()
  ) throws -> BatchPreview {
    try recipe.validate()
    try destination.validate()
    try validateInputs(inputs, maxFiles: BatchLimits.maxFiles)
    let outputs = try resolveOutputs(
      recipe: recipe, inputs: inputs, destination: destination)
    let missing = performers.missingKinds(for: recipe)
    var warnings: [String] = []
    if !missing.isEmpty {
      warnings.append(
        "Service steps without a registered performer: "
          + missing.map(\.displayName).joined(separator: ", "))
    }
    if recipe.enabledSteps.contains(where: { $0.kind == .preflight }) {
      warnings.append("Preflight is read-only: it reports findings and does not change the output.")
    }
    if destination.overwriteExistingOutputs {
      warnings.append("Existing output files may be replaced; input files are never replaced.")
    }
    var files: [BatchPreviewFile] = []
    var totalBytes = 0
    for (index, input) in inputs.enumerated() {
      let outputURL = outputs[index]
      var messages: [String] = []
      var refusals: [String] = []
      var pageCount: Int?
      let values = try? input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile != true {
        refusals.append("The input is not a regular file.")
      }
      let size = values?.fileSize ?? 0
      if size <= 0 {
        refusals.append("The input file is empty.")
      }
      totalBytes += size
      if totalBytes > BatchLimits.maxTotalInputBytes {
        refusals.append("The selected inputs exceed the batch size limit.")
      }
      if size > 0, size <= 64 * 1_024 * 1_024, let data = try? Data(contentsOf: input) {
        pageCount = (try? PDFParser.parse(data))?.pageIDs.count
        if pageCount == nil && !recipe.outputExtension.isEmpty
          && recipe.terminalExport == nil
        {
          refusals.append("The input is not a readable PDF for this recipe.")
        }
      }
      if !missing.isEmpty {
        let missingText = missing.map(\.displayName).joined(separator: ", ")
        messages.append("Requires a service performer for: " + missingText)
        refusals.append(
          "The app layer has not registered a service performer for: " + missingText)
      }
      if let extensionExpected = recipe.terminalExport {
        messages.append("Final step writes ." + extensionExpected.outputExtension + " output.")
      }
      let steplines = recipe.enabledSteps.map { step in
        step.kind.displayName + ": " + step.settingsSummary
      }
      files.append(
        BatchPreviewFile(
          inputURL: input, outputURL: outputURL, fileName: input.lastPathComponent,
          pageCount: pageCount,
          status: refusals.isEmpty ? .ready : .refused,
          stepSummaries: steplines, serviceSteps: missing,
          warnings: messages, refusals: refusals))
    }
    return BatchPreview(
      recipeName: recipe.name, destinationSummary: destination.summary,
      files: files, warnings: warnings)
  }

  static func validateInputs(_ inputs: [URL], maxFiles: Int) throws {
    guard !inputs.isEmpty else {
      throw PDFError(.malformed, "Choose at least one input file")
    }
    guard inputs.count <= maxFiles, inputs.count <= BatchLimits.maxFiles else {
      throw PDFError(.limitExceeded, "A batch supports at most \(BatchLimits.maxFiles) files")
    }
    let standardized = inputs.map(\.standardizedFileURL)
    guard Set(standardized.map(\.path)).count == inputs.count else {
      throw PDFError(.malformed, "The input list contains the same file more than once")
    }
  }

  /// Resolve one output path per input. Existing outputs and already-resolved
  /// names follow the collision policy; an output equal to any input is always
  /// refused.
  static func resolveOutputs(
    recipe: BatchRecipe, inputs: [URL], destination: BatchDestinationPolicy,
    taken: Set<String> = []
  ) throws -> [URL] {
    let inputPaths = Set(inputs.map { $0.standardizedFileURL.path })
    let extensionText = recipe.outputExtension
    let recipeToken = BatchFileIO.sanitizedRecipeToken(recipe.name)
    var used = taken
    var outputs: [URL] = []
    for input in inputs {
      let stem = input.deletingPathExtension().lastPathComponent
      var base = destination.nameTemplate
        .replacingOccurrences(of: "{name}", with: stem)
        .replacingOccurrences(of: "{recipe}", with: recipeToken)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !base.isEmpty, base.utf8.count <= BatchLimits.maxOutputNameBytes,
        URL(fileURLWithPath: base).lastPathComponent == base,
        !base.contains("/"), !base.contains("\\")
      else {
        throw PDFError(.malformed, "The output name resolved to an invalid file name: \(base)")
      }
      if !base.lowercased().hasSuffix("." + extensionText) {
        base += "." + extensionText
      }
      let directory: URL
      switch destination.mode {
      case .besideInput:
        directory = input.deletingLastPathComponent().standardizedFileURL
      case .folder:
        guard let folderPath = destination.folderPath else {
          throw PDFError(.malformed, "The destination folder is missing")
        }
        directory = URL(fileURLWithPath: folderPath).standardizedFileURL
      }
      var candidate = directory.appendingPathComponent(base).standardizedFileURL
      var counter = 2
      while true {
        if inputPaths.contains(candidate.path) {
          throw PDFError(
            .malformed,
            "The output " + candidate.lastPathComponent
              + " would overwrite an input file; choose another destination or name template")
        }
        let existsOnDisk = FileManager.default.fileExists(atPath: candidate.path)
        let reserved = used.contains(candidate.path)
        if !existsOnDisk && !reserved {
          break
        }
        if existsOnDisk && destination.overwriteExistingOutputs {
          break
        }
        switch destination.collision {
        case .fail:
          throw PDFError(
            .unsupported,
            "The output " + candidate.lastPathComponent
              + " already exists and the collision policy is to fail")
        case .uniqueSuffix:
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
      used.insert(candidate.path)
      outputs.append(candidate)
    }
    return outputs
  }
}

// MARK: - Runner

public enum BatchRunner {
  /// AUT-04: run a recipe over ordered inputs with a per-file checkpoint,
  /// cooperative stop, stop/resume, safe retry and explicit destination policy.
  @discardableResult
  public static func run(
    recipe: BatchRecipe, inputs: [URL], options: BatchRunOptions = BatchRunOptions(),
    performers: BatchPerformerRegistry = BatchStandardPerformers.registry(),
    control: BatchRunControl? = nil,
    progress: (@Sendable (BatchProgress) -> Void)? = nil
  ) throws -> BatchRunResult {
    try recipe.validate()
    try options.destination.validate()
    try BatchPlanner.validateInputs(inputs, maxFiles: options.maxFiles)
    let enabledSteps = recipe.enabledSteps
    let missing = performers.missingKinds(for: recipe)
    guard missing.isEmpty else {
      throw PDFError(
        .unsupported,
        "This recipe needs a service performer for: "
          + missing.map(\.displayName).joined(separator: ", "))
    }

    let startedAt = Date()
    let baseDirectory: URL
    switch options.destination.mode {
    case .besideInput:
      baseDirectory = inputs[0].deletingLastPathComponent().standardizedFileURL
    case .folder:
      guard let folderPath = options.destination.folderPath else {
        throw PDFError(.malformed, "The destination folder is missing")
      }
      baseDirectory = URL(fileURLWithPath: folderPath).standardizedFileURL
    }
    let checkpointURL =
      options.checkpointURL
      ?? baseDirectory.appendingPathComponent("spdf-batch-checkpoint.json").standardizedFileURL

    let inputValues = try inputs.map { input -> (URL, Int, String) in
      let values = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
        throw PDFError(.malformed, "The input is not a readable file: \(input.lastPathComponent)")
      }
      guard size <= BatchLimits.maxInputBytes else {
        throw PDFError(.limitExceeded, "The input exceeds the batch file size limit: \(input.lastPathComponent)")
      }
      let data = try Data(contentsOf: input)
      return (input, size, BatchDigest.hex(data))
    }
    let totalBytes = inputValues.reduce(0) { $0 + $1.1 }
    guard totalBytes <= options.maxTotalInputBytes else {
      throw PDFError(.limitExceeded, "The selected inputs exceed the batch size limit")
    }

    var checkpoint: BatchCheckpoint
    var outcomes: [Int: BatchFileOutcome] = [:]
    var resumed = false
    if options.resume {
      checkpoint = try BatchFileIO.readCheckpoint(checkpointURL)
      let stored = checkpoint.files.map { $0.inputPath }
      let current = inputValues.map { $0.0.standardizedFileURL.path }
      guard stored == current else {
        throw PDFError(.malformed, "The checkpoint lists different inputs; start a new run")
      }
      for (index, entry) in checkpoint.files.enumerated() {
        guard entry.inputDigest == inputValues[index].2 else {
          throw PDFError(.malformed, "An input changed since the checkpoint; start a new run")
        }
      }
      guard checkpoint.recipeDigest == recipe.digest else {
        throw PDFError(.malformed, "The checkpoint belongs to a different recipe; start a new run")
      }
      guard checkpoint.destinationDirectory == baseDirectory.path else {
        throw PDFError(.malformed, "The checkpoint belongs to a different destination; start a new run")
      }
      resumed = true
    } else {
      checkpoint = BatchCheckpoint(
        version: BatchCheckpoint.version, runID: UUID(),
        recipeName: recipe.name, recipeDigest: recipe.digest,
        destinationDirectory: baseDirectory.path,
        inputs: inputValues.map { $0.0.standardizedFileURL.path },
        files: inputValues.enumerated().map { index, value in
          BatchCheckpointFile(
            order: index, inputPath: value.0.standardizedFileURL.path,
            fileName: value.0.lastPathComponent, inputDigest: value.2,
            status: .notStarted, outputPath: nil, outputDigest: nil,
            completedSteps: 0, stepStates: [:], error: nil, resumed: false)
        },
        crossFileStates: [:], updatedAt: startedAt)
    }

    // Completed files from a previous run are skipped only when the output is
    // still present with the recorded digest. A missing or changed output is
    // reported as failed (never success) so a user edit is not overwritten.
    var priorSucceededPaths: Set<String> = []
    for entry in checkpoint.files where entry.status == .succeeded {
      guard let outputPath = entry.outputPath,
        let outputDigest = entry.outputDigest,
        let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
        BatchDigest.hex(data) == outputDigest
      else {
        continue
      }
      priorSucceededPaths.insert(outputPath)
    }
    let outputs = try BatchPlanner.resolveOutputs(
      recipe: recipe, inputs: inputs, destination: options.destination,
      taken: priorSucceededPaths)

    let reportProgress: (BatchProgress.Stage, Int, Int, String, Int) -> Void = { stage, fileIndex, fileCount, fileName, completed in
      progress?(
        BatchProgress(
          stage: stage, fileIndex: fileIndex, fileCount: fileCount, fileName: fileName,
          completedSteps: completed, stepCount: enabledSteps.count))
    }
    reportProgress(.preparing, 0, inputs.count, "", 0)

    var stopped = false
    var abortedByError = false
    var crossStates = checkpoint.crossFileStates

    for (index, entryTemplate) in checkpoint.files.enumerated() {
      let input = inputs[index]
      var entry = entryTemplate
      // A previous success is verified and skipped.
      if entry.status == .succeeded, options.resume {
        if let outputPath = entry.outputPath, let outputDigest = entry.outputDigest,
          let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
          BatchDigest.hex(data) == outputDigest
        {
          outcomes[index] = BatchFileOutcome(
            order: index, fileName: entry.fileName, inputPath: entry.inputPath,
            status: .succeeded, outputPath: outputPath, outputDigest: outputDigest,
            completedSteps: ["already completed in the checkpoint"],
            warnings: [], failure: nil, resumed: true)
          continue
        }
        entry.status = .failed
        entry.error = "The recorded output is missing or changed; start a new run to regenerate it"
        entry.outputPath = nil
        entry.outputDigest = nil
        checkpoint.files[index] = entry
        outcomes[index] = BatchFileOutcome(
          order: index, fileName: entry.fileName, inputPath: entry.inputPath,
          status: .failed, outputPath: nil, outputDigest: nil,
          completedSteps: [], warnings: [],
          failure: entry.error, resumed: true)
        try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
        continue
      }
      if control?.isStopRequested == true || Task.isCancelled {
        stopped = true
        break
      }
      entry.status = .running
      entry.completedSteps = 0
      entry.error = nil
      checkpoint.files[index] = entry
      try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
      reportProgress(.processing, index, inputs.count, entry.fileName, 0)

      var data = try Data(contentsOf: inputValues[index].0.standardizedFileURL)
      guard BatchDigest.hex(data) == entry.inputDigest else {
        entry.status = .failed
        entry.error = "The input changed while the batch was running"
        checkpoint.files[index] = entry
        outcomes[index] = BatchFileOutcome(
          order: index, fileName: entry.fileName, inputPath: entry.inputPath,
          status: .failed, outputPath: nil, outputDigest: nil,
          completedSteps: [], warnings: [], failure: entry.error, resumed: false)
        try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
        if !options.continueOnError { abortedByError = true; break }
        continue
      }
      var completed: [String] = []
      var warnings: [String] = []
      var localStates = crossStates
      var failure: String?
      var fileStopped = false

      for step in enabledSteps {
        if control?.isStopRequested == true || Task.isCancelled {
          fileStopped = true
          stopped = true
          break
        }
        guard let performer = performers.performer(for: step.kind) else {
          failure = "No performer is registered for " + step.kind.displayName
          break
        }
        let priorState = localStates[step.id.uuidString].flatMap { Data(base64Encoded: $0) }
        do {
          let outcome = try performer.perform(
            BatchStepRequest(
              step: step, inputURL: input, sourceBytes: data, fileIndex: index,
              fileName: entry.fileName, priorState: priorState))
          data = outcome.data
          completed.append(step.kind.displayName + ": " + outcome.note)
          warnings.append(contentsOf: outcome.warnings)
          if let state = outcome.state {
            localStates[step.id.uuidString] = state.base64EncodedString()
          }
          entry.completedSteps = completed.count
          checkpoint.files[index] = entry
          try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
          reportProgress(.processing, index, inputs.count, entry.fileName, completed.count)
        } catch {
          failure = error.localizedDescription
          break
        }
      }

      if fileStopped {
        entry.status = .interrupted
        entry.completedSteps = completed.count
        entry.error = "Stopped before the output was written"
        checkpoint.files[index] = entry
        outcomes[index] = BatchFileOutcome(
          order: index, fileName: entry.fileName, inputPath: entry.inputPath,
          status: .interrupted, outputPath: nil, outputDigest: nil,
          completedSteps: completed, warnings: warnings,
          failure: entry.error, resumed: false)
        try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
        break
      }
      if let failure {
        entry.status = .failed
        entry.error = failure
        entry.completedSteps = completed.count
        checkpoint.files[index] = entry
        outcomes[index] = BatchFileOutcome(
          order: index, fileName: entry.fileName, inputPath: entry.inputPath,
          status: .failed, outputPath: nil, outputDigest: nil,
          completedSteps: completed, warnings: warnings,
          failure: failure, resumed: false)
        try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
        if !options.continueOnError { abortedByError = true; break }
        continue
      }
      // Last chance to stop: no output has been written yet.
      if control?.isStopRequested == true || Task.isCancelled {
        entry.status = .interrupted
        entry.completedSteps = completed.count
        entry.error = "Stopped before the output was written"
        checkpoint.files[index] = entry
        outcomes[index] = BatchFileOutcome(
          order: index, fileName: entry.fileName, inputPath: entry.inputPath,
          status: .interrupted, outputPath: nil, outputDigest: nil,
          completedSteps: completed, warnings: warnings,
          failure: entry.error, resumed: false)
        try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
        stopped = true
        break
      }
      let outputURL = outputs[index]
      reportProgress(.writing, index, inputs.count, entry.fileName, completed.count)
      do {
        try BatchFileIO.atomicWrite(
          data, to: outputURL,
          overwrite: options.destination.overwriteExistingOutputs)
      } catch {
        entry.status = .failed
        entry.error = "The output could not be written: " + error.localizedDescription
        entry.completedSteps = completed.count
        checkpoint.files[index] = entry
        outcomes[index] = BatchFileOutcome(
          order: index, fileName: entry.fileName, inputPath: entry.inputPath,
          status: .failed, outputPath: nil, outputDigest: nil,
          completedSteps: completed, warnings: warnings,
          failure: entry.error, resumed: false)
        try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
        if !options.continueOnError { abortedByError = true; break }
        continue
      }
      let outputDigest = BatchDigest.hex(data)
      entry.status = .succeeded
      entry.outputPath = outputURL.path
      entry.outputDigest = outputDigest
      entry.error = nil
      entry.completedSteps = completed.count
      entry.stepStates = localStates
      entry.resumed = resumed
      crossStates = localStates
      checkpoint.files[index] = entry
      checkpoint.crossFileStates = crossStates
      checkpoint.updatedAt = Date()
      try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
      outcomes[index] = BatchFileOutcome(
        order: index, fileName: entry.fileName, inputPath: entry.inputPath,
        status: .succeeded, outputPath: outputURL.path, outputDigest: outputDigest,
        completedSteps: completed, warnings: warnings, failure: nil, resumed: false)
    }

    // Fill files that were never reached, then persist the final checkpoint.
    var fileOutcomes: [BatchFileOutcome] = []
    for (index, entry) in checkpoint.files.enumerated() {
      if let outcome = outcomes[index] {
        fileOutcomes.append(outcome)
      } else {
        fileOutcomes.append(
          BatchFileOutcome(
            order: index, fileName: entry.fileName, inputPath: entry.inputPath,
            status: .notStarted, outputPath: nil, outputDigest: nil,
            completedSteps: [], warnings: [], failure: nil, resumed: false))
      }
    }
    checkpoint.updatedAt = Date()
    try BatchFileIO.writeCheckpoint(checkpoint, to: checkpointURL)
    reportProgress(
      stopped ? .stopped : (abortedByError ? .failed : .finished),
      0, inputs.count, "", 0)
    let report = BatchRunReport(
      runID: checkpoint.runID, recipeName: recipe.name, recipeDigest: recipe.digest,
      startedAt: startedAt, finishedAt: Date(),
      destinationSummary: options.destination.summary, checkpointPath: checkpointURL.path,
      stopped: stopped, abortedByError: abortedByError, files: fileOutcomes)
    guard report.successInvariantHolds else {
      throw PDFError(
        .malformed, "Internal error: a reported success is missing its output identity")
    }
    return BatchRunResult(report: report, checkpointURL: checkpointURL)
  }
}

// MARK: - Built-in owned performers

public enum BatchStandardPerformers {
  public static func registry() -> BatchPerformerRegistry {
    BatchPerformerRegistry([
      BatesNumberingBatchPerformer(), OptimizeBatchPerformer(),
      PreflightBatchPerformer(), TextExportBatchPerformer(),
    ])
  }
}

private struct BatesNumberingBatchPerformer: BatchStepPerformer {
  let kind = BatchActionKind.batesNumbering

  private struct State: Codable { var nextNumber: Int }

  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    guard let settings = request.step.bates else {
      throw PDFError(.malformed, "The Bates step has no settings")
    }
    let parsed = try PDFParser.parse(request.sourceBytes)
    let pageIDs = parsed.pageIDs
    let decoder = JSONDecoder()
    let prior = request.priorState.flatMap { try? decoder.decode(State.self, from: $0) }
    let start =
      settings.continuesAcrossFiles ? (prior?.nextNumber ?? settings.startNumber) : settings.startNumber
    let fileSettings = BatesBatchSettings(
      prefix: settings.prefix, suffix: settings.suffix, startNumber: start,
      digits: settings.digits, style: AddedTextStyle(size: settings.fontSize, alignment: .center),
      placement: settings.placement.repeatedMarkPlacement, margin: 36,
      continuesAcrossFiles: settings.continuesAcrossFiles,
      excludedPages: settings.excludedPages,
      leadingExcludedPages: settings.leadingExcludedPages)
    let plan = try BatesBatchPlanner.plan(
      files: [BatesBatchFile(name: request.fileName, pageCount: pageIDs.count)],
      settings: fileSettings)
    guard let assignment = plan.files.first else {
      throw PDFError(.malformed, "The Bates plan produced no assignment")
    }
    var graph = parsed.graph
    if let command = assignment.command(
      pageIDs: pageIDs, groupID: "spdf-batch-" + request.step.id.uuidString)
    {
      try command.validate(in: graph)
      graph = try command.apply(to: graph)
    }
    let nextNumber: Int
    if settings.continuesAcrossFiles {
      nextNumber = plan.sequenceEnd.map { $0 + 1 } ?? start
    } else {
      nextNumber = settings.startNumber
    }
    let state = try JSONEncoder().encode(State(nextNumber: nextNumber))
    let note: String
    if let first = assignment.firstNumber, let last = assignment.lastNumber {
      note = "numbered \(assignment.pages.count) page(s), \(first)-\(last)"
    } else {
      note = "no pages were numbered"
    }
    return BatchStepOutcome(
      data: try PDFWriter.write(graph), note: note, state: state, warnings: plan.issues)
  }
}

private struct OptimizeBatchPerformer: BatchStepPerformer {
  let kind = BatchActionKind.optimize

  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    guard let settings = request.step.optimize else {
      throw PDFError(.malformed, "The optimize step has no settings")
    }
    let parsed = try PDFParser.parse(request.sourceBytes)
    let result = try PDFOptimizer.lossless(
      parsed.graph,
      options: PDFOptimizationOptions(removeMetadata: settings.removeMetadata),
      sourceBytes: request.sourceBytes.count)
    return BatchStepOutcome(data: result.data, note: result.report.summary)
  }
}

private struct PreflightBatchPerformer: BatchStepPerformer {
  let kind = BatchActionKind.preflight

  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    guard let settings = request.step.preflight else {
      throw PDFError(.malformed, "The preflight step has no settings")
    }
    let parsed = try PDFParser.parse(request.sourceBytes)
    let report = try PreflightCheckReport.run(parsed.graph, pageIDs: parsed.pageIDs)
    if settings.failOnErrors, report.errorCount > 0 {
      throw PDFError(
        .unsupported,
        "Preflight found \(report.errorCount) error(s); this recipe fails the file on errors")
    }
    let note =
      "\(report.errorCount) error(s), \(report.warningCount) warning(s); read-only"
    return BatchStepOutcome(data: request.sourceBytes, note: note)
  }
}

private struct TextExportBatchPerformer: BatchStepPerformer {
  let kind = BatchActionKind.exportText

  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    let parsed = try PDFParser.parse(request.sourceBytes)
    let data = try PDFTextExport.plainText(
      pageIDs: parsed.pageIDs, in: parsed.graph,
      options: PDFTextExportOptions(pageSeparator: .blankLine))
    return BatchStepOutcome(
      data: data, note: "exported plain text for \(parsed.pageIDs.count) page(s)")
  }
}
