import AppKit
import AppIntents
import Foundation
import PDFEditing

// AUT-05: native macOS automation surfaces beyond the CLI. App Intents power
// Shortcuts and AppleScript commands reuse the declared AutomationProfile
// catalog through AutomationService, so they cannot expose capabilities that
// the CLI/UI do not have. The Lead wires the Shortcuts metadata and the SDEF
// suite; no hidden flags are introduced here.

@MainActor
final class AutomationService {
  static let shared = AutomationService()
  private init() {}

  struct ServiceResult {
    let exitCode: Int32
    let json: String
    let text: String
    let error: String
  }

  func run(operation: String, inputs: [String], options: [String: String]) -> ServiceResult {
    var arguments = [operation]
    arguments.append(contentsOf: inputs)
    for (name, value) in options.sorted(by: { $0.key < $1.key }) {
      arguments.append(name)
      arguments.append(value)
    }
    let result = AutomationCLI.perform(arguments: arguments)
    return ServiceResult(
      exitCode: result.exitCode, json: result.standardOutput,
      text: result.standardOutput, error: result.standardError)
  }

  func capabilitiesJSON() -> String {
    AutomationCLI.perform(arguments: ["capabilities"]).standardOutput
  }

  func operationNames() -> [String] {
    AutomationProfile.operations.map(\.name)
  }
}

// MARK: - Shortcuts / App Intents

struct AutomationCapabilitiesIntent: AppIntent {
  // Computed statics keep App Intents metadata out of nonisolated mutable global
  // state, which Swift 6 strict concurrency rejects in the App target.
  static var title: LocalizedStringResource { "sPDF Automation Capabilities" }
  static var description: IntentDescription {
    IntentDescription(
      "Returns the declared sPDF automation profile: operations, options, exit codes and restrictions.")
  }
  static var openAppWhenRun: Bool { false }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let json = await MainActor.run { AutomationService.shared.capabilitiesJSON() }
    return .result(value: json)
  }
}

struct RunAutomationIntent: AppIntent {
  static var title: LocalizedStringResource { "Run sPDF Automation" }
  static var description: IntentDescription {
    IntentDescription(
      "Runs one declared sPDF automation operation with the same options and restrictions as the CLI and the app.")
  }
  static var openAppWhenRun: Bool { false }

  @Parameter(title: "Operation")
  var operation: String

  @Parameter(title: "Input Path")
  var inputPath: String

  @Parameter(title: "Output Path")
  var outputPath: String?

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    var options: [String: String] = [:]
    if let outputPath, !outputPath.isEmpty { options["--output"] = outputPath }
    let result = await MainActor.run {
      AutomationService.shared.run(
        operation: operation, inputs: [inputPath], options: options)
    }
    if result.exitCode != 0 {
      throw AutomationIntentError.failed(exitCode: result.exitCode, message: result.error)
    }
    return .result(value: result.json)
  }
}

enum AutomationIntentError: Error, LocalizedError {
  case failed(exitCode: Int32, message: String)

  var errorDescription: String? {
    switch self {
    case .failed(let exitCode, let message):
      return "sPDF automation failed (exit " + String(exitCode) + "): " + message
    }
  }
}

struct AutomationShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RunAutomationIntent(),
      phrases: ["Run automation in \(.applicationName)"],
      shortTitle: "Run Automation",
      systemImageName: "gearshape.2")
  }
}

// MARK: - AppleScript bridge

/// AUT-05 AppleScript command: run one declared automation operation and return
/// the structured JSON envelope as text.
@objc(AutomationRunScriptCommand)
final class AutomationRunScriptCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    let operation = (evaluatedArguments?["operation"] as? String) ?? ""
    let input = (evaluatedArguments?["input"] as? String) ?? ""
    let output = evaluatedArguments?["output"] as? String
    var options: [String: String] = [:]
    if let output, !output.isEmpty { options["--output"] = output }
    guard !operation.isEmpty, !input.isEmpty else {
      scriptErrorNumber = 2
      scriptErrorString = "The run automation command needs an operation and an input path."
      return nil
    }
    var arguments = [operation, input]
    for (name, value) in options.sorted(by: { $0.key < $1.key }) {
      arguments.append(name)
      arguments.append(value)
    }
    let result = AutomationCLI.perform(arguments: arguments)
    if result.exitCode != 0 {
      scriptErrorNumber = Int(result.exitCode)
      scriptErrorString = result.standardError
    }
    return result.standardOutput
  }
}

/// AUT-05 AppleScript command: return the automation profile JSON.
@objc(AutomationCapabilitiesScriptCommand)
final class AutomationCapabilitiesScriptCommand: NSScriptCommand {
  override func performDefaultImplementation() -> Any? {
    AutomationCLI.perform(arguments: ["capabilities"]).standardOutput
  }
}
