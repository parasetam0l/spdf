import AppKit
import Foundation
import Testing
@testable import MacServices

/// UX-01/UX-02 evidence artifact writer (opt-in):
///   SPDF_UX_ARTIFACT_DIR=<dir> swift test --filter UXArtifactTests
/// Writes the accessibility contract, the headless keyboard-only transcript, the
/// real AppKit attribute probe and all compact-window reports. Real VoiceOver
/// speech remains the manual protocol step documented in the session evidence.
@Suite("UX qualification artifacts")
struct UXArtifactTests {
  final class EvidenceSurface: UXQualifyingSurface {
    var focusedControl = "canvas.document"
    var documentName = "Document A"
    var selection: String? = "selection"
    var caretIndex: Int? = 3
    var propertyValues: [String: String] = ["Bold": "Off", "FontSize": "12"]
    var draft = "Draft note"
    var activeTool = "text"
    private var storedA: [String: String] = [:]
    private var storedSelection: String?

    func perform(_ action: UXWorkflowAction) -> UXSurfaceObservation {
      var transition: UXTransition
      switch action {
      case .focusCanvas: focusedControl = "canvas.document"; transition = .focusReturn
      case .selectWord: selection = "word"; transition = .selection
      case .moveCaret: caretIndex = (caretIndex ?? 0) + 1; transition = .caret
      case .toggleBold:
        propertyValues["Bold"] = propertyValues["Bold"] == "On" ? "Off" : "On"
        transition = .propertyChange
      case .chooseTextTool: activeTool = "text"; transition = .toolChange
      case .openDialog, .openDialogAgain: transition = .dialogOpen
      case .cancelDialog: focusedControl = "canvas.document"; transition = .dialogCancel
      case .confirmDialog: transition = .dialogConfirm
      case .startJob: transition = .jobStart
      case .observeProgress: transition = .jobProgress
      case .failJob: focusedControl = "job.failure"; transition = .jobFailure
      case .retryJob: focusedControl = "job.progress"; transition = .jobRetry
      case .recoverError: focusedControl = "canvas.document"; transition = .errorRecovery
      case .switchDocument:
        if documentName == "Document A" {
          storedA = propertyValues
          storedSelection = selection
          documentName = "Document B"
          propertyValues = [:]
          selection = nil
        } else {
          documentName = "Document A"
          propertyValues = storedA
          selection = storedSelection
        }
        transition = .documentSwitch
      case .returnFocus: focusedControl = "canvas.document"; transition = .focusReturn
      }
      return UXSurfaceObservation(
        focusedControl: focusedControl,
        announcement: UXAnnouncement(
          transition: transition, role: "AXGroup", label: "Announcement " + action.rawValue,
          value: "state", help: "keyboard help"),
        documentName: documentName, selection: selection, caretIndex: caretIndex,
        propertyValues: propertyValues, draft: draft, activeTool: activeTool,
        hasVisiblePrimaryAction: true)
    }
  }

  @Test @MainActor func writesArtifactsWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directoryPath = environment["SPDF_UX_ARTIFACT_DIR"], !directoryPath.isEmpty
    else { return }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let contract: [String: Any] = [
      "identifier": UXAccessibilityContract.identifier,
      "transitions": UXTransition.allCases.map(\.rawValue),
      "requirements": UXAccessibilityContract.requirements.map { requirement -> [String: Any] in
        [
          "transition": requirement.transition.rawValue,
          "role": requirement.announcement.role,
          "label": requirement.announcement.label,
          "value": requirement.announcement.value ?? "",
          "spokenText": requirement.announcement.spokenText,
          "keys": requirement.keyboardCommand.keys,
          "action": requirement.keyboardCommand.action,
          "restoresFocus": requirement.restoresFocus,
        ]
      },
      "manualVoiceOverProtocol": UXAccessibilityContract.manualVoiceOverProtocol,
      "manualProtocolLimits": UXAccessibilityContract.manualProtocolLimits,
      "contractIssues": UXAccessibilityContract.validate(),
    ]
    try writeJSON(contract, to: directory.appendingPathComponent("ux-contract.json"))

    let transcript = UXKeyboardOnlyWorkflow.run(on: EvidenceSurface())
    let workflow: [String: Any] = [
      "passed": transcript.passed,
      "summary": transcript.summary,
      "issues": transcript.issues,
      "steps": transcript.steps.map { step -> [String: Any] in
        [
          "action": step.action.rawValue,
          "expectedTransition": step.expectedTransition.rawValue,
          "focusedControl": step.observation.focusedControl,
          "announcement": step.observation.announcement?.spokenText ?? "",
          "value": step.observation.announcement?.value ?? "",
        ]
      },
    ]
    try writeJSON(workflow, to: directory.appendingPathComponent("ux-workflow.json"))

    let probe = UXAppKitProbe.run()
    let probeReport: [String: Any] = [
      "passes": probe.report.passed,
      "issues": probe.report.issues,
      "elementCount": probe.elements.count,
      "keyViewOrder": probe.keyViewOrder,
      "elements": probe.elements.map { element -> [String: Any] in
        [
          "role": element.role,
          "label": element.label,
          "value": element.value ?? "",
          "help": element.help ?? "",
          "actions": element.actions,
          "isInteractive": element.isInteractive,
        ]
      },
    ]
    try writeJSON(probeReport, to: directory.appendingPathComponent("ux-ax-probe.json"))

    let reports = CompactWindowQualification.runAll()
    let compact: [String: Any] = [
      "displayScales": CompactWindowQualification.displayScales,
      "reports": reports.map { report -> [String: Any] in
        [
          "scenario": report.scenario.rawValue,
          "minimum": report.minimum.description,
          "passed": report.passed,
          "summary": report.summary,
          "steps": report.steps,
          "issues": report.issues.map { ["action": $0.action, "message": $0.message] },
        ]
      },
    ]
    try writeJSON(compact, to: directory.appendingPathComponent("ux-compact-windows.json"))
    #expect(transcript.passed)
    #expect(probe.report.passed)
    let allCompactScenariosPassed = reports.allSatisfy(\.passed)
    #expect(allCompactScenariosPassed)
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }
}
