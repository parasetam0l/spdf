import AppKit
import Foundation
import Testing
@testable import MacServices

/// UX-01/UX-02 evidence: keyboard/VoiceOver contract validation, a headless
/// keyboard-only workflow with a recording surface, real AppKit accessibility
/// attribute/key-view probes, and compact-window stability at declared sizes.
@Suite("UX keyboard and VoiceOver qualification")
struct UXQualificationTests {
  final class RecordingSurface: UXQualifyingSurface {
    var focusedControl = "canvas.document"
    var documentName = "Document A"
    var selection: String? = "first selection"
    var caretIndex: Int? = 4
    var propertyValues: [String: String] = ["Bold": "Off", "FontSize": "12"]
    var draft = "Draft note"
    var activeTool = "text"
    var hasVisiblePrimaryAction = true
    private var documentAState: [String: String] = [:]
    private var documentASelection: String?
    var suppressedAnnouncementAction: UXWorkflowAction?
    var clearFocusOnAction: UXWorkflowAction?

    func perform(_ action: UXWorkflowAction) -> UXSurfaceObservation {
      var transition: UXTransition = .focusReturn
      switch action {
      case .focusCanvas:
        focusedControl = "canvas.document"
        transition = .focusReturn
      case .selectWord:
        selection = "selected word"
        focusedControl = "canvas.document"
        transition = .selection
      case .moveCaret:
        caretIndex = (caretIndex ?? 0) + 1
        transition = .caret
      case .toggleBold:
        propertyValues["Bold"] = propertyValues["Bold"] == "On" ? "Off" : "On"
        focusedControl = "properties.bold"
        transition = .propertyChange
      case .chooseTextTool:
        activeTool = "text"
        focusedControl = "toolbar.tool"
        transition = .toolChange
      case .openDialog, .openDialogAgain:
        focusedControl = "dialog.properties"
        transition = .dialogOpen
      case .cancelDialog:
        focusedControl = "canvas.document"
        transition = .dialogCancel
      case .confirmDialog:
        focusedControl = "properties.bold"
        transition = .dialogConfirm
      case .startJob:
        focusedControl = "job.progress"
        transition = .jobStart
      case .observeProgress:
        activeTool = "job"
        transition = .jobProgress
      case .failJob:
        focusedControl = "job.failure"
        transition = .jobFailure
      case .retryJob:
        focusedControl = "job.progress"
        transition = .jobRetry
      case .recoverError:
        focusedControl = "canvas.document"
        transition = .errorRecovery
      case .switchDocument:
        if documentName == "Document A" {
          documentAState = propertyValues
          documentASelection = selection
          documentName = "Document B"
          selection = nil
          propertyValues = [:]
          draft = "Draft B"
        } else {
          documentName = "Document A"
          propertyValues = documentAState
          selection = documentASelection
        }
        focusedControl = "canvas.document"
        transition = .documentSwitch
      case .returnFocus:
        focusedControl = "canvas.document"
        transition = .focusReturn
      }
      if action == clearFocusOnAction { focusedControl = "" }
      let announcement: UXAnnouncement? = action == suppressedAnnouncementAction
        ? nil
        : UXAnnouncement(
          transition: transition, role: "AXGroup", label: "Announcement for " + action.rawValue,
          value: "state value", help: "keyboard help")
      return UXSurfaceObservation(
        focusedControl: focusedControl, announcement: announcement, documentName: documentName,
        selection: selection, caretIndex: caretIndex, propertyValues: propertyValues,
        draft: draft, activeTool: activeTool, hasVisiblePrimaryAction: hasVisiblePrimaryAction)
    }
  }

  @Test func accessibilityContractCoversEveryTransition() throws {
    #expect(UXAccessibilityContract.validate().isEmpty)
    #expect(
      UXAccessibilityContract.coveredTransitions() == Set(UXTransition.allCases))
    #expect(UXAccessibilityContract.requirements.count == UXTransition.allCases.count)
    #expect(UXAccessibilityContract.requirements.allSatisfy { !$0.announcement.spokenText.isEmpty })
    #expect(UXAccessibilityContract.requirements.allSatisfy { $0.announcement.value != nil })
    #expect(UXAccessibilityContract.requirements.allSatisfy { $0.restoresFocus || $0.transition != .focusReturn })
  }

  @Test func manualProtocolDocumentsLimitsAndRows() throws {
    #expect(UXAccessibilityContract.manualVoiceOverProtocol.count >= 8)
    #expect(UXAccessibilityContract.manualProtocolLimits.count >= 4)
    #expect(UXAccessibilityContract.manualProtocolLimits.contains {
      $0.contains("cannot launch the app") && $0.contains("synthetic speech is never")
    })
    #expect(UXAccessibilityContract.manualVoiceOverProtocol.contains {
      $0.contains("Start VoiceOver")
    })
    #expect(UXAccessibilityContract.manualVoiceOverProtocol.contains {
      $0.contains("Escape") && $0.contains("focus returns")
    })
  }

  @Test func keyboardOnlyWorkflowAnnouncesEveryTransition() throws {
    let surface = RecordingSurface()
    let transcript = UXKeyboardOnlyWorkflow.run(on: surface)
    #expect(transcript.passed, "\(transcript.issues.joined(separator: "; "))")
    #expect(transcript.steps.count == UXKeyboardOnlyWorkflow.script.count)
    for step in transcript.steps {
      let announcement = try #require(step.observation.announcement)
      #expect(!announcement.spokenText.isEmpty)
      #expect(announcement.transition == step.expectedTransition)
      #expect(!step.observation.focusedControl.isEmpty)
      #expect(step.observation.hasVisiblePrimaryAction)
    }
    #expect(transcript.steps.contains { $0.action == .cancelDialog })
    #expect(transcript.steps.contains { $0.action == .retryJob })
    #expect(transcript.steps.contains { $0.action == .switchDocument })
  }

  @Test func harnessRejectsMissingAnnouncementsAndFocus() throws {
    let silent = RecordingSurface()
    silent.suppressedAnnouncementAction = UXWorkflowAction.toggleBold
    let silentTranscript = UXKeyboardOnlyWorkflow.run(on: silent)
    #expect(!silentTranscript.passed)
    #expect(silentTranscript.issues.contains { $0.contains("no announcement") })

    let unfocused = RecordingSurface()
    unfocused.clearFocusOnAction = UXWorkflowAction.observeProgress
    let unfocusedTranscript = UXKeyboardOnlyWorkflow.run(on: unfocused)
    #expect(!unfocusedTranscript.passed)
    #expect(unfocusedTranscript.issues.contains { $0.contains("has no focus") })
  }

  @Test func accessibilityProbeRequiresAttributesNotElementExistence() throws {
    let good = [
      UXAccessibilityElementProbe(
        role: "AXButton", label: "Apply", value: "enabled", help: "Applies changes.",
        actions: ["AXPress"], isInteractive: true),
      UXAccessibilityElementProbe(
        role: "AXSlider", label: "Font size", value: "12", help: "Adjusts size.",
        actions: ["AXIncrement"], isInteractive: true),
    ]
    let goodReport = UXAccessibilityProbe.evaluate(good)
    #expect(goodReport.passed, "\(goodReport.issues.joined(separator: "; "))")
    #expect(goodReport.elementCount == 2)

    let missingLabel = UXAccessibilityProbe.evaluate([
      UXAccessibilityElementProbe(
        role: "AXButton", label: " ", value: "enabled", help: "H", actions: ["AXPress"],
        isInteractive: true)
    ])
    #expect(!missingLabel.passed)
    let missingHelp = UXAccessibilityProbe.evaluate([
      UXAccessibilityElementProbe(
        role: "AXButton", label: "Apply", value: "enabled", help: nil, actions: ["AXPress"],
        isInteractive: true)
    ])
    #expect(!missingHelp.passed)
    let missingActions = UXAccessibilityProbe.evaluate([
      UXAccessibilityElementProbe(
        role: "AXButton", label: "Apply", value: "enabled", help: "H", actions: [],
        isInteractive: true)
    ])
    #expect(!missingActions.passed)
    let noValue = UXAccessibilityProbe.evaluate([
      UXAccessibilityElementProbe(
        role: "AXButton", label: "Apply", value: nil, help: "H", actions: ["AXPress"],
        isInteractive: true)
    ])
    #expect(!noValue.passed)
    #expect(!UXAccessibilityProbe.evaluate([]).passed)
  }

  @Test @MainActor func appKitProbeReadsRealAttributesAndKeyLoop() throws {
    let result = UXAppKitProbe.run()
    #expect(result.elements.count == 4)
    #expect(result.report.passed, "\(result.report.issues.joined(separator: "; "))")
    #expect(result.keyViewOrder.count >= 4)
    #expect(result.keyViewOrder.contains("Bold"))
    #expect(result.keyViewOrder.contains("Font size"))
    #expect(result.keyViewOrder.contains("Apply changes"))
    #expect(result.elements.allSatisfy { !$0.actions.isEmpty })
    #expect(result.elements.allSatisfy { !$0.role.isEmpty })
    #expect(result.elements.allSatisfy { ($0.value?.isEmpty == false) })
  }

  @Test func compactWindowScenariosPassAtDeclaredMinimumsAndScales() throws {
    for scenario in CompactWindowScenario.allCases {
      for scale in CompactWindowQualification.displayScales {
        let report = CompactWindowQualification.run(scenario: scenario, scale: scale)
        #expect(report.passed, "\(report.issues.map(\.message).joined(separator: "; "))")
        #expect(report.minimum.width > 0 && report.minimum.height > 0)
        #expect(report.steps.contains { $0.contains("scale=") })
      }
    }
    #expect(CompactWindowQualification.runAll().count == CompactWindowScenario.allCases.count)
  }

  @Test func compactWindowKeepsFocusContextPropertiesAndDraft() throws {
    let model = CompactWindowModel(scenario: .textEditing)
    let baseline = model.state
    model.resize(width: 400, height: 300)
    #expect(model.state.width >= model.minimum.width)
    #expect(model.state.height >= model.minimum.height)
    model.toggleSidebar()
    model.toggleSidebar()
    model.setZoom(percent: 50)
    model.setZoom(percent: 200)
    model.openPopover(controlID: "properties.bold")
    model.closePopover()
    model.editDraft("Updated draft")
    model.focus(controlID: "canvas.document")
    #expect(model.state.documentName == baseline.documentName)
    #expect(model.state.pageIndex == baseline.pageIndex)
    #expect(model.state.selection == baseline.selection)
    #expect(model.state.propertyValues == baseline.propertyValues)
    #expect(model.state.pendingDraft == "Updated draft")
    #expect(model.state.focusedControlID == "canvas.document")
    #expect(model.issues.isEmpty, "\(model.issues.map(\.message).joined(separator: "; "))")
    #expect(model.reachableControls.contains("properties.bold"))
  }

  @Test func compactWindowSidebarAndDocumentSwitchingStayStable() throws {
    let model = CompactWindowModel(scenario: .comments)
    model.focus(controlID: "comments.list")
    model.toggleSidebar() // hide: focus must move instead of vanishing.
    #expect(model.state.focusedControlID == "canvas.document")
    #expect(model.reachableControls.contains("comments.list"))
    #expect(!model.currentlyVisibleControls.contains("comments.list"))
    model.toggleSidebar()
    model.switchDocument(to: "Document B")
    model.editDraft("Draft B")
    model.resize(width: model.minimum.width + 100, height: model.minimum.height)
    model.switchDocument(to: "Document A")
    #expect(model.state.documentName == "Document A")
    #expect(model.state.pendingDraft == "Draft note")
    #expect(model.state.pageIndex == 1)
    #expect(model.state.selection == "selection")
    #expect(model.issues.isEmpty, "\(model.issues.map(\.message).joined(separator: "; "))")
  }
}
