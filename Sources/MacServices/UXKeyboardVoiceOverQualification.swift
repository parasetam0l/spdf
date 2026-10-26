import Foundation

// UX-01: keyboard-only and VoiceOver qualification contracts plus a headless
// workflow harness. The harness models the declared app surfaces and their
// spoken announcements; it is deliberately paired with a manual VoiceOver
// protocol because a real speech session cannot be captured under the
// no-app-launch protocol. AX attributes are probed separately (see
// UXAppKitProbe) so "the element merely exists" is never treated as evidence.

public enum UXTransition: String, CaseIterable, Sendable, Equatable {
  case selection
  case caret
  case propertyChange
  case toolChange
  case dialogOpen
  case dialogConfirm
  case dialogCancel
  case jobStart
  case jobProgress
  case jobFailure
  case jobRetry
  case errorRecovery
  case documentSwitch
  case focusReturn
}

public struct UXAnnouncement: Sendable, Equatable {
  public enum Priority: String, Sendable, Equatable {
    case polite
    case assertive
  }

  public let transition: UXTransition
  public let role: String
  public let label: String
  public let value: String?
  public let help: String?
  public let priority: Priority

  public init(
    transition: UXTransition, role: String, label: String, value: String?, help: String?,
    priority: Priority = .polite
  ) {
    self.transition = transition
    self.role = role
    self.label = label
    self.value = value
    self.help = help
    self.priority = priority
  }

  public var spokenText: String {
    var parts = [label]
    if let value, !value.isEmpty { parts.append(value) }
    if let help, !help.isEmpty { parts.append(help) }
    return parts.joined(separator: ", ")
  }
}

public struct UXKeyCommand: Sendable, Equatable {
  public let keys: String
  public let action: String
  public init(keys: String, action: String) {
    self.keys = keys
    self.action = action
  }
}

/// One declared contract row: every state transition needs a spoken
/// announcement, a keyboard-only way to reach it and focus restoration.
public struct UXAccessibilityRequirement: Sendable, Equatable {
  public let transition: UXTransition
  public let announcement: UXAnnouncement
  public let keyboardCommand: UXKeyCommand
  public let restoresFocus: Bool
  public init(
    transition: UXTransition, announcement: UXAnnouncement, keyboardCommand: UXKeyCommand,
    restoresFocus: Bool
  ) {
    self.transition = transition
    self.announcement = announcement
    self.keyboardCommand = keyboardCommand
    self.restoresFocus = restoresFocus
  }
}

public enum UXAccessibilityContract {
  public static let identifier = "spdf-ux-accessibility-v1"

  public static let requirements: [UXAccessibilityRequirement] = [
    UXAccessibilityRequirement(
      transition: .selection,
      announcement: UXAnnouncement(
        transition: .selection, role: "AXStaticText", label: "Text selection",
        value: "Selected text is announced with its content", help: "Use Shift+Arrow keys "
          + "to adjust the selection.", priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Shift+Right Arrow", action: "Extend selection"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .caret,
      announcement: UXAnnouncement(
        transition: .caret, role: "AXTextField", label: "Caret",
        value: "Current character and word are announced", help: "Option+Arrow moves by word.",
        priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Left Arrow", action: "Move caret"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .propertyChange,
      announcement: UXAnnouncement(
        transition: .propertyChange, role: "AXCheckBox", label: "Bold",
        value: "On or Off is announced", help: "Command+B toggles bold.", priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Command+B", action: "Toggle bold"),
      restoresFocus: false),
    UXAccessibilityRequirement(
      transition: .toolChange,
      announcement: UXAnnouncement(
        transition: .toolChange, role: "AXRadioButton", label: "Active tool",
        value: "Tool name and its restrictions", help: "V selects the text tool.", priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "V", action: "Select the text tool"),
      restoresFocus: false),
    UXAccessibilityRequirement(
      transition: .dialogOpen,
      announcement: UXAnnouncement(
        transition: .dialogOpen, role: "AXWindow", label: "Dialog title",
        value: "Dialog purpose", help: "Escape cancels; Return confirms.", priority: .assertive),
      keyboardCommand: UXKeyCommand(keys: "Command+Shift+P", action: "Open properties dialog"),
      restoresFocus: false),
    UXAccessibilityRequirement(
      transition: .dialogConfirm,
      announcement: UXAnnouncement(
        transition: .dialogConfirm, role: "AXButton", label: "Confirm",
        value: "The applied change and focus return", help: nil, priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Return", action: "Confirm dialog"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .dialogCancel,
      announcement: UXAnnouncement(
        transition: .dialogCancel, role: "AXButton", label: "Cancel",
        value: "No change was made", help: nil, priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Escape", action: "Cancel dialog"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .jobStart,
      announcement: UXAnnouncement(
        transition: .jobStart, role: "AXProgressIndicator", label: "Running job",
        value: "Job name and total work", help: "Escape requests cancellation.", priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Command+Shift+O", action: "Start OCR job"),
      restoresFocus: false),
    UXAccessibilityRequirement(
      transition: .jobProgress,
      announcement: UXAnnouncement(
        transition: .jobProgress, role: "AXProgressIndicator", label: "Job progress",
        value: "Percentage and remaining items", help: nil, priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Command+Shift+O", action: "Start OCR job"),
      restoresFocus: false),
    UXAccessibilityRequirement(
      transition: .jobFailure,
      announcement: UXAnnouncement(
        transition: .jobFailure, role: "AXStaticText", label: "Job failed",
        value: "Failure reason and the affected item", help: "Return retries the job.",
        priority: .assertive),
      keyboardCommand: UXKeyCommand(keys: "Return", action: "Retry failed job"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .jobRetry,
      announcement: UXAnnouncement(
        transition: .jobRetry, role: "AXProgressIndicator", label: "Retrying job",
        value: "The retried item", help: nil, priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Return", action: "Retry failed job"),
      restoresFocus: false),
    UXAccessibilityRequirement(
      transition: .errorRecovery,
      announcement: UXAnnouncement(
        transition: .errorRecovery, role: "AXStaticText", label: "Recovered",
        value: "What was restored and unchanged work", help: nil, priority: .assertive),
      keyboardCommand: UXKeyCommand(keys: "Escape", action: "Dismiss the error and recover"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .documentSwitch,
      announcement: UXAnnouncement(
        transition: .documentSwitch, role: "AXWindow", label: "Document",
        value: "Document name and page count", help: "Control+Tab switches documents.",
        priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Control+Tab", action: "Switch document"),
      restoresFocus: true),
    UXAccessibilityRequirement(
      transition: .focusReturn,
      announcement: UXAnnouncement(
        transition: .focusReturn, role: "AXGroup", label: "Focus returned",
        value: "The previously focused control", help: nil, priority: .polite),
      keyboardCommand: UXKeyCommand(keys: "Escape", action: "Return focus"),
      restoresFocus: true),
  ]

  /// The declared limits of the manual VoiceOver protocol. A passing harness is
  /// not evidence of real speech; these limits must be stated with any claim.
  public static let manualProtocolLimits: [String] = [
    "Real VoiceOver spoken output requires a human session with the app launched; this "
      + "workstream cannot launch the app or drive Computer Use, so synthetic speech is never "
      + "reported as real spoken output.",
    "The headless harness proves that every declared transition has a keyboard-only path, an "
      + "announcement value and focus restoration; it does not prove audio quality or speech "
      + "order in VoiceOver.",
    "AX attribute probes prove role/label/value/help/actions and a key view loop; an element "
      + "existing in the tree alone is treated as insufficient.",
    "The manual protocol below is the acceptance step for the remaining spoken-output claim: a "
      + "tester follows it with VoiceOver and records failures; any unrecorded row is not claimed.",
  ]

  public static let manualVoiceOverProtocol: [String] = [
    "Start VoiceOver (Command+F5) and open a document with text, a form field and a comment.",
    "Focus the document canvas; select a word with Shift+Option+Right Arrow and confirm the "
      + "selection is announced with its text.",
    "Move the caret with Left/Right/Option arrows and confirm character and word announcements.",
    "Toggle bold with Command+B and confirm On/Off plus the focused control survive.",
    "Switch tools with V/H and confirm the tool name and restrictions are announced.",
    "Open the properties dialog with Command+Shift+P, read the dialog label/value, press Escape "
      + "and confirm focus returns to the previous control with no change applied.",
    "Start an OCR job on a scanned page (Command+Shift+O), confirm start and progress "
      + "announcements, cancel or let it finish, then confirm the result is announced.",
    "Force a failure with a malformed input, confirm the failure and retry path are announced and "
      + "that retry restores focus.",
    "Switch documents with Control+Tab and confirm the document name and page count are "
      + "announced and the previous document's selection/property state is preserved.",
    "Record every row as pass/fail with the VoiceOver version; rows without a recording stay "
      + "unclaimed.",
  ]

  /// Validate the contract itself: every transition is covered exactly once, each
  /// row has a non-empty announcement, a keyboard path and focus policy.
  public static func validate() -> [String] {
    var issues: [String] = []
    var seen = Set<UXTransition>()
    for requirement in requirements {
      if !seen.insert(requirement.transition).inserted {
        issues.append("Transition " + requirement.transition.rawValue + " is declared twice.")
      }
      if requirement.announcement.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append("Transition " + requirement.transition.rawValue + " has no label.")
      }
      if requirement.announcement.role.isEmpty {
        issues.append("Transition " + requirement.transition.rawValue + " has no role.")
      }
      if requirement.announcement.value == nil {
        issues.append(
          "Transition " + requirement.transition.rawValue + " has no state value to speak.")
      }
      if requirement.keyboardCommand.keys.isEmpty || requirement.keyboardCommand.action.isEmpty {
        issues.append("Transition " + requirement.transition.rawValue + " has no keyboard path.")
      }
    }
    for transition in UXTransition.allCases where !seen.contains(transition) {
      issues.append("Transition " + transition.rawValue + " is not covered.")
    }
    return issues
  }

  public static func coveredTransitions() -> Set<UXTransition> {
    Set(requirements.map(\.transition))
  }
}

// MARK: - Headless keyboard-only workflow harness

public struct UXSurfaceObservation: Sendable, Equatable {
  public let focusedControl: String
  public let announcement: UXAnnouncement?
  public let documentName: String
  public let selection: String?
  public let caretIndex: Int?
  public let propertyValues: [String: String]
  public let draft: String
  public let activeTool: String
  public let hasVisiblePrimaryAction: Bool

  public init(
    focusedControl: String, announcement: UXAnnouncement?, documentName: String,
    selection: String?, caretIndex: Int?, propertyValues: [String: String], draft: String,
    activeTool: String, hasVisiblePrimaryAction: Bool
  ) {
    self.focusedControl = focusedControl
    self.announcement = announcement
    self.documentName = documentName
    self.selection = selection
    self.caretIndex = caretIndex
    self.propertyValues = propertyValues
    self.draft = draft
    self.activeTool = activeTool
    self.hasVisiblePrimaryAction = hasVisiblePrimaryAction
  }
}

public enum UXWorkflowAction: String, Sendable, Equatable, CaseIterable {
  case focusCanvas
  case selectWord
  case moveCaret
  case toggleBold
  case chooseTextTool
  case openDialog
  case cancelDialog
  case openDialogAgain
  case confirmDialog
  case startJob
  case observeProgress
  case failJob
  case retryJob
  case recoverError
  case switchDocument
  case returnFocus
}

/// A surface under qualification. The real app adapter and the headless test
/// double both implement it; the harness never uses pointer events.
public protocol UXQualifyingSurface: AnyObject {
  func perform(_ action: UXWorkflowAction) -> UXSurfaceObservation
}

public struct UXWorkflowStep: Sendable, Equatable {
  public let action: UXWorkflowAction
  public let expectedTransition: UXTransition
  public let observation: UXSurfaceObservation
  public init(
    action: UXWorkflowAction, expectedTransition: UXTransition, observation: UXSurfaceObservation
  ) {
    self.action = action
    self.expectedTransition = expectedTransition
    self.observation = observation
  }
}

public struct UXWorkflowTranscript: Sendable, Equatable {
  public let steps: [UXWorkflowStep]
  public let issues: [String]
  public var passed: Bool { issues.isEmpty }
  public var summary: String {
    passed
      ? "Keyboard-only workflow passed " + String(steps.count) + " steps with an announcement "
        + "for every transition."
      : "Keyboard-only workflow has " + String(issues.count) + " issue(s)."
  }
}

public enum UXKeyboardOnlyWorkflow {
  /// Declared workflow order and its expected spoken transition.
  public static let script: [(UXWorkflowAction, UXTransition)] = [
    (.focusCanvas, .focusReturn),
    (.selectWord, .selection),
    (.moveCaret, .caret),
    (.toggleBold, .propertyChange),
    (.chooseTextTool, .toolChange),
    (.openDialog, .dialogOpen),
    (.cancelDialog, .dialogCancel),
    (.openDialogAgain, .dialogOpen),
    (.confirmDialog, .dialogConfirm),
    (.startJob, .jobStart),
    (.observeProgress, .jobProgress),
    (.failJob, .jobFailure),
    (.retryJob, .jobRetry),
    (.recoverError, .errorRecovery),
    (.switchDocument, .documentSwitch),
    (.returnFocus, .focusReturn),
  ]

  public static func run(on surface: any UXQualifyingSurface) -> UXWorkflowTranscript {
    var steps: [UXWorkflowStep] = []
    var issues: [String] = []
    var initialDocument = ""
    var initialDraft = ""
    var initialProperties: [String: String] = [:]
    var sawFocusReturn = false
    var propertiesBeforeJob: [String: String]?
    for (index, entry) in script.enumerated() {
      let observation = surface.perform(entry.0)
      let step = UXWorkflowStep(
        action: entry.0, expectedTransition: entry.1, observation: observation)
      steps.append(step)
      if index == 0 {
        initialDocument = observation.documentName
        initialDraft = observation.draft
        initialProperties = observation.propertyValues
      }
      if observation.focusedControl.isEmpty {
        issues.append("Step " + String(index + 1) + " (" + entry.0.rawValue + ") has no focus.")
      }
      guard let announcement = observation.announcement else {
        issues.append(
          "Step " + String(index + 1) + " (" + entry.0.rawValue + ") produced no announcement.")
        continue
      }
      if announcement.transition != entry.1 {
        issues.append(
          "Step " + String(index + 1) + " (" + entry.0.rawValue + ") announced "
            + announcement.transition.rawValue + " instead of " + entry.1.rawValue + ".")
      }
      if announcement.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(
          "Step " + String(index + 1) + " (" + entry.0.rawValue + ") has empty spoken text.")
      }
      if announcement.value == nil {
        issues.append(
          "Step " + String(index + 1) + " (" + entry.0.rawValue + ") has no spoken state value.")
      }
      if entry.0 == .returnFocus { sawFocusReturn = true }
      if entry.0 == .switchDocument, observation.documentName == initialDocument {
        issues.append("Document switch did not change the announced document.")
      }
      if entry.0 == .confirmDialog, observation.draft != initialDraft {
        issues.append("A confirmed dialog unexpectedly changed the pending draft.")
      }
      if entry.0 == .cancelDialog, observation.draft != initialDraft {
        issues.append("A cancelled dialog changed the pending draft.")
      }
      if entry.0 == .startJob {
        propertiesBeforeJob = observation.propertyValues
      }
      if entry.0 == .recoverError, let propertiesBeforeJob,
        observation.propertyValues != propertiesBeforeJob
      {
        issues.append("Error recovery changed property values.")
      }
      if !observation.hasVisiblePrimaryAction {
        issues.append(
          "Step " + String(index + 1) + " (" + entry.0.rawValue
            + ") has no visible primary action for a compact window.")
      }
    }
    if !sawFocusReturn {
      issues.append("The workflow never returned focus after an overlay.")
    }
    return UXWorkflowTranscript(steps: steps, issues: issues)
  }
}

// MARK: - Accessibility attribute probe (element-existence is not evidence)

public struct UXAccessibilityElementProbe: Sendable, Equatable {
  public let role: String
  public let label: String
  public let value: String?
  public let help: String?
  public let actions: [String]
  public let isInteractive: Bool

  public init(
    role: String, label: String, value: String?, help: String?, actions: [String],
    isInteractive: Bool
  ) {
    self.role = role
    self.label = label
    self.value = value
    self.help = help
    self.actions = actions
    self.isInteractive = isInteractive
  }
}

public struct UXAccessibilityProbeReport: Sendable, Equatable {
  public let elementCount: Int
  public let issues: [String]
  public var passed: Bool { issues.isEmpty }
  public init(elementCount: Int, issues: [String]) {
    self.elementCount = elementCount
    self.issues = issues
  }
}

public enum UXAccessibilityProbe {
  public static func evaluate(_ elements: [UXAccessibilityElementProbe]) -> UXAccessibilityProbeReport {
    var issues: [String] = []
    if elements.isEmpty {
      issues.append("No accessibility elements were probed.")
    }
    var labels = Set<String>()
    for (index, element) in elements.enumerated() {
      let prefix = "Element " + String(index + 1) + " (" + element.role + ")"
      if element.role.isEmpty { issues.append(prefix + " has no accessibility role.") }
      if element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues.append(prefix + " has no accessible label.")
      } else if !labels.insert(element.label + "/" + element.role).inserted {
        issues.append(prefix + " duplicates another element's role and label.")
      }
      if element.isInteractive {
        if element.help?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
          issues.append(prefix + " has no help for a VoiceOver user.")
        }
        if element.actions.isEmpty {
          issues.append(prefix + " exposes no accessibility actions.")
        }
      }
      if element.value == nil, element.isInteractive {
        issues.append(prefix + " exposes no current value/state.")
      }
    }
    return UXAccessibilityProbeReport(elementCount: elements.count, issues: issues)
  }
}
