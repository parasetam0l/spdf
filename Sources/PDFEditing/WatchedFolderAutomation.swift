import Foundation
import PDFCore

// AUT-06: explicit watched-folder automation. Folders and the recipe are
// user-selected; there is no default watch location. Arrival detection waits
// for a stable size/modification-time sample, each stable input is processed
// once (state is persisted and survives relaunch), outputs are published into a
// separate output folder that may not live inside a watched folder, and every
// failure is kept visible in the report and in the state store.

public struct AutomationRecipeStep: Codable, Sendable, Equatable {
  public let operation: String
  public let options: [String: String]
  public init(operation: String, options: [String: String] = [:]) {
    self.operation = operation
    self.options = options
  }
}

public struct AutomationRecipe: Codable, Sendable, Equatable, Identifiable {
  public static let schemaVersion = 1
  public var name: String
  public var steps: [AutomationRecipeStep]
  public var id: String { name }

  public init(name: String, steps: [AutomationRecipeStep]) {
    self.name = name
    self.steps = steps
  }

  /// Validate against the declared automation profile: every step must be a
  /// known writing operation with only that operation's declared options. The
  /// engine supplies the input and output paths itself.
  public func validated() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AutomationWatchError.invalidRecipe("The recipe needs a name.")
    }
    guard !steps.isEmpty else {
      throw AutomationWatchError.invalidRecipe("The recipe has no steps.")
    }
    for step in steps {
      guard let operation = AutomationProfile.operation(named: step.operation) else {
        throw AutomationWatchError.invalidRecipe(
          "Unknown operation '" + step.operation + "' is not part of the automation profile.")
      }
      guard operation.kind == .write, operation.producesFile else {
        throw AutomationWatchError.invalidRecipe(
          "Operation '" + step.operation + "' does not produce a PDF file and cannot be a "
            + "watched-folder step.")
      }
      let declared = Set(operation.options.map(\.name))
      for option in step.options.keys {
        guard declared.contains(option), option != "--output" else {
          throw AutomationWatchError.invalidRecipe(
            "Option " + option + " is not allowed in a watched-folder step; the engine owns "
              + "paths and output options.")
        }
      }
    }
  }
}

public struct WatchedFolderConfiguration: Sendable, Equatable {
  public let name: String
  public let watchedFolders: [URL]
  public let outputFolder: URL
  public let recipe: AutomationRecipe
  /// Time an input must stay unchanged before it is considered settled.
  public let settleInterval: TimeInterval
  public let allowedExtensions: Set<String>

  public init(
    name: String, watchedFolders: [URL], outputFolder: URL, recipe: AutomationRecipe,
    settleInterval: TimeInterval = 30, allowedExtensions: Set<String> = ["pdf"]
  ) throws {
    guard !watchedFolders.isEmpty else {
      throw AutomationWatchError.invalidConfiguration(
        "Select at least one watched folder; there is no default folder.")
    }
    let standardizedOutput = outputFolder.standardizedFileURL.resolvingSymlinksInPath()
    for folder in watchedFolders {
      let standardized = folder.standardizedFileURL.resolvingSymlinksInPath()
      if standardized.path == standardizedOutput.path
        || standardizedOutput.path.hasPrefix(standardized.path)
      {
        throw AutomationWatchError.invalidConfiguration(
          "The output folder must not be inside a watched folder (" + folder.path
            + "); otherwise its outputs would recursively retrigger the job.")
      }
    }
    guard settleInterval > 0, settleInterval <= 3600 else {
      throw AutomationWatchError.invalidConfiguration(
        "The settle interval must be between 0 and 3600 seconds.")
    }
    guard !allowedExtensions.isEmpty else {
      throw AutomationWatchError.invalidConfiguration("At least one file extension is required.")
    }
    try recipe.validated()
    self.name = name
    self.watchedFolders = watchedFolders.map { $0.standardizedFileURL }
    self.outputFolder = outputFolder.standardizedFileURL
    self.recipe = recipe
    self.settleInterval = settleInterval
    self.allowedExtensions = Set(allowedExtensions.map { $0.lowercased() })
  }
}

public enum AutomationWatchError: Error, Equatable, LocalizedError {
  case invalidConfiguration(String)
  case invalidRecipe(String)
  case stateUnreadable(String)
  case executionFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message), .invalidRecipe(let message),
      .stateUnreadable(let message), .executionFailed(let message):
      return message
    }
  }
}

/// One observed file. Providers can be injected so arrival timing is tested
/// deterministically without sleeping.
public struct WatchedFileSnapshot: Sendable, Equatable {
  public let url: URL
  public let size: Int64
  public let modificationDate: Date
  public init(url: URL, size: Int64, modificationDate: Date) {
    self.url = url
    self.size = size
    self.modificationDate = modificationDate
  }
}

public struct AutomationWatchState: Codable, Sendable, Equatable {
  public static let schemaVersion = 1
  public enum Status: String, Codable, Sendable, Equatable {
    case pending
    case processed
    case failed
  }

  public struct InputRecord: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var modificationDate: Date
    public var firstSeen: Date
    public var lastSeen: Date
    public var status: Status
    public var output: String?
    public var error: String?
    public init(
      path: String, size: Int64, modificationDate: Date, firstSeen: Date, lastSeen: Date,
      status: Status, output: String? = nil, error: String? = nil
    ) {
      self.path = path
      self.size = size
      self.modificationDate = modificationDate
      self.firstSeen = firstSeen
      self.lastSeen = lastSeen
      self.status = status
      self.output = output
      self.error = error
    }
  }

  public var schemaVersion: Int = AutomationWatchState.schemaVersion
  public var inputs: [String: InputRecord] = [:]
  public var outputs: [String: String] = [:]
  public init() {}
}

public struct AutomationWatchItem: Sendable, Equatable {
  public let path: String
  public let output: String?
  public init(path: String, output: String?) {
    self.path = path
    self.output = output
  }
}

public struct AutomationWatchFailure: Sendable, Equatable {
  public let path: String
  public let message: String
  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

public struct AutomationWatchReport: Sendable, Equatable {
  public static let schemaVersion = 1
  public let timestamp: Date
  public let watchedFolderCount: Int
  public let scannedFileCount: Int
  public let pendingCount: Int
  public let processed: [AutomationWatchItem]
  public let failed: [AutomationWatchFailure]
  public let alreadyProcessedCount: Int
  public let skippedCount: Int

  public var summary: String {
    var text = String(processed.count) + " processed, " + String(pendingCount) + " pending, "
      + String(failed.count) + " failed, " + String(alreadyProcessedCount)
      + " already processed, " + String(skippedCount) + " skipped"
    if !failed.isEmpty { text += " (failures are visible below)" }
    return text + "."
  }

  public func jsonObject() -> [String: Any] {
    [
      "schemaVersion": Self.schemaVersion,
      "timestamp": ISO8601DateFormatter().string(from: timestamp),
      "watchedFolderCount": watchedFolderCount,
      "scannedFileCount": scannedFileCount,
      "pendingCount": pendingCount,
      "alreadyProcessedCount": alreadyProcessedCount,
      "skippedCount": skippedCount,
      "processed": processed.map { item -> [String: Any] in
        ["path": item.path, "output": item.output as Any? ?? NSNull()]
      },
      "failed": failed.map { failure -> [String: Any] in
        ["path": failure.path, "message": failure.message]
      },
    ]
  }

  public func jsonData() -> Data? {
    try? JSONSerialization.data(
      withJSONObject: jsonObject(), options: [.prettyPrinted, .sortedKeys])
  }
}

/// Executes a recipe for one watched input through the shared CLI profile. The
/// final output is published atomically to a unique name in the output folder.
public enum AutomationRecipeExecutor {
  public static func execute(
    input: URL, recipe: AutomationRecipe, configuration: WatchedFolderConfiguration,
    workDirectory: URL? = nil
  ) throws -> URL {
    try recipe.validated()
    let fileManager = FileManager.default
    let temporary = workDirectory ?? fileManager.temporaryDirectory
    let work = temporary.appendingPathComponent(
      "spdf-automation-" + UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: work) }

    var currentInput = input
    var stepIndex = 0
    for step in recipe.steps {
      stepIndex += 1
      let temporaryOutput = work.appendingPathComponent("step-\(stepIndex).pdf")
      var arguments = [step.operation, currentInput.path, "--output", temporaryOutput.path]
      for (name, value) in step.options.sorted(by: { $0.key < $1.key }) {
        arguments.append(name)
        arguments.append(value)
      }
      let result = AutomationCLI.perform(arguments: arguments)
      guard result.exitCode == 0 else {
        let errorObject = result.envelope?["error"] as? [String: Any]
        let message = errorObject?["message"] as? String ?? "unknown"
        throw AutomationWatchError.executionFailed(
          "Step " + String(stepIndex) + " (" + step.operation + ") failed: " + message)
      }
      guard fileManager.fileExists(atPath: temporaryOutput.path) else {
        throw AutomationWatchError.executionFailed(
          "Step " + String(stepIndex) + " did not write an output file.")
      }
      currentInput = temporaryOutput
    }

    try fileManager.createDirectory(
      at: configuration.outputFolder, withIntermediateDirectories: true)
    let baseName = input.deletingPathExtension().lastPathComponent
    let stem = baseName.isEmpty ? "output" : baseName
    var destination = configuration.outputFolder
      .appendingPathComponent(stem + ".pdf")
    var suffix = 1
    while fileManager.fileExists(atPath: destination.path) {
      suffix += 1
      destination = configuration.outputFolder
        .appendingPathComponent(stem + "-" + String(suffix) + ".pdf")
    }
    do {
      try fileManager.copyItem(at: currentInput, to: destination)
    } catch {
      throw AutomationWatchError.executionFailed(
        "Cannot publish the output file: " + error.localizedDescription)
    }
    return destination
  }
}

/// AUT-06: the scan engine. One scan observes the watched folders, settles new
/// inputs, processes each stable input once and persists the state atomically.
public final class WatchedFolderEngine {
  public struct Providers {
    public var listFiles: (URL) throws -> [WatchedFileSnapshot]
    public var now: () -> Date
    public var execute: (URL, AutomationRecipe, WatchedFolderConfiguration) throws -> URL

    public init(
      listFiles: @escaping (URL) throws -> [WatchedFileSnapshot],
      now: @escaping () -> Date,
      execute: @escaping (URL, AutomationRecipe, WatchedFolderConfiguration) throws -> URL
    ) {
      self.listFiles = listFiles
      self.now = now
      self.execute = execute
    }

    public static var live: Providers {
      Providers(
        listFiles: { folder in
          let contents = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants])
          var snapshots: [WatchedFileSnapshot] = []
          for url in contents {
            let values = try? url.resourceValues(forKeys: [
              .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ])
            guard values?.isRegularFile == true else { continue }
            snapshots.append(
              WatchedFileSnapshot(
                url: url, size: Int64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate ?? Date()))
          }
          return snapshots
        },
        now: { Date() },
        execute: { input, recipe, configuration in
          try AutomationRecipeExecutor.execute(
            input: input, recipe: recipe, configuration: configuration)
        })
    }
  }

  public let configuration: WatchedFolderConfiguration
  public let stateURL: URL
  public var providers: Providers

  public init(
    configuration: WatchedFolderConfiguration, stateURL: URL,
    providers: Providers = .live
  ) {
    self.configuration = configuration
    self.stateURL = stateURL
    self.providers = providers
  }

  public func loadState() throws -> AutomationWatchState {
    guard FileManager.default.fileExists(atPath: stateURL.path) else {
      return AutomationWatchState()
    }
    do {
      let data = try Data(contentsOf: stateURL)
      let decoder = JSONDecoder()
      // Seconds-since-1970 keeps sub-second modification-time precision, which
      // the settle comparison depends on.
      decoder.dateDecodingStrategy = .secondsSince1970
      let state = try decoder.decode(AutomationWatchState.self, from: data)
      guard state.schemaVersion == AutomationWatchState.schemaVersion else {
        throw AutomationWatchError.stateUnreadable(
          "The watched-folder state was written by an unsupported schema version.")
      }
      return state
    } catch let error as AutomationWatchError {
      throw error
    } catch {
      throw AutomationWatchError.stateUnreadable(
        "The watched-folder state cannot be read: " + error.localizedDescription)
    }
  }

  public func saveState(_ state: AutomationWatchState) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try data.write(to: stateURL, options: .atomic)
    } catch {
      throw AutomationWatchError.stateUnreadable(
        "Cannot save the watched-folder state: " + error.localizedDescription)
    }
  }

  /// Canonical absolute path used for identity, loop prevention and state
  /// prefixes. FileManager may hand back /private/var paths for a /var folder;
  /// resolving symlinks keeps one file to one identity across providers.
  public static func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// Identity of one stable input. A moved or edited file is a new identity by
  /// declaration (path + size + modification time), which is also why a stable
  /// input is processed once per identity.
  public static func fingerprint(_ snapshot: WatchedFileSnapshot) -> String {
    Self.canonicalPath(snapshot.url) + "|" + String(snapshot.size) + "|"
      + String(format: "%.3f", snapshot.modificationDate.timeIntervalSince1970)
  }

  public func scanOnce(retryFailed: Bool = false) throws -> AutomationWatchReport {
    var state = try loadState()
    let now = providers.now()
    let outputPath = Self.canonicalPath(configuration.outputFolder)
    var snapshots: [WatchedFileSnapshot] = []
    for folder in configuration.watchedFolders {
      snapshots.append(contentsOf: try providers.listFiles(folder))
    }
    snapshots.sort { Self.canonicalPath($0.url) < Self.canonicalPath($1.url) }

    var seenKeys = Set<String>()
    var pendingCount = 0
    var processed: [AutomationWatchItem] = []
    var failed: [AutomationWatchFailure] = []
    var alreadyProcessed = 0
    var skipped = 0

    for snapshot in snapshots {
      let url = snapshot.url.standardizedFileURL
      let path = Self.canonicalPath(url)
      let key = Self.fingerprint(snapshot)
      seenKeys.insert(key)
      if url.lastPathComponent.hasPrefix(".") { skipped += 1; continue }
      if path.hasPrefix(outputPath + "/") || path == outputPath { skipped += 1; continue }
      if state.outputs.values.contains(path) { skipped += 1; continue }
      guard configuration.allowedExtensions.contains(url.pathExtension.lowercased()) else {
        skipped += 1
        continue
      }
      if let existing = state.inputs[key] {
        switch existing.status {
        case .processed:
          alreadyProcessed += 1
          continue
        case .failed:
          if !retryFailed { continue }
          state.inputs.removeValue(forKey: key)
        case .pending:
          var record = existing
          if record.size != snapshot.size
            || abs(record.modificationDate.timeIntervalSince(snapshot.modificationDate)) > 0.0005
          {
            record.size = snapshot.size
            record.modificationDate = snapshot.modificationDate
            record.firstSeen = now
            record.lastSeen = now
            state.inputs[key] = record
            pendingCount += 1
            continue
          }
          record.lastSeen = now
          state.inputs[key] = record
          if now.timeIntervalSince(record.firstSeen) < configuration.settleInterval {
            pendingCount += 1
            continue
          }
          // Settled, unchanged and newly arrived: process exactly once.
          do {
            let output = try providers.execute(
              url, configuration.recipe, configuration)
            var processedRecord = record
            processedRecord.status = .processed
            processedRecord.lastSeen = now
            processedRecord.output = Self.canonicalPath(output)
            processedRecord.error = nil
            state.inputs[key] = processedRecord
            state.outputs[key] = Self.canonicalPath(output)
            processed.append(
              AutomationWatchItem(
                path: path, output: Self.canonicalPath(output)))
          } catch {
            var failedRecord = record
            failedRecord.status = .failed
            failedRecord.lastSeen = now
            failedRecord.error = error.localizedDescription
            state.inputs[key] = failedRecord
            failed.append(
              AutomationWatchFailure(path: path, message: error.localizedDescription))
          }
          continue
        }
      }
      state.inputs[key] = AutomationWatchState.InputRecord(
        path: path, size: snapshot.size, modificationDate: snapshot.modificationDate,
        firstSeen: now, lastSeen: now, status: .pending)
      pendingCount += 1
    }

    // Prune pending observations for files that no longer exist so a deleted
    // input cannot stay pending forever.
    let pendingPrefixes = configuration.watchedFolders.map {
      Self.canonicalPath($0) + "/"
    }
    state.inputs = state.inputs.filter {
      (key: String, record: AutomationWatchState.InputRecord) in
      if record.status != .pending { return true }
      if !pendingPrefixes.contains(where: { record.path.hasPrefix($0) }) { return true }
      return seenKeys.contains(key)
    }

    try saveState(state)
    return AutomationWatchReport(
      timestamp: now, watchedFolderCount: configuration.watchedFolders.count,
      scannedFileCount: snapshots.count, pendingCount: pendingCount,
      processed: processed, failed: failed, alreadyProcessedCount: alreadyProcessed,
      skippedCount: skipped)
  }
}
