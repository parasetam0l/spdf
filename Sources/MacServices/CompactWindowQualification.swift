import Foundation

// UX-02: compact-window qualification. Each workflow declares a minimum logical
// window size; the model drives resizes, sidebar/popover toggles and zoom and
// checks that context (document/page/selection), focus, property values and
// pending drafts stay stable. Values are logical points, so common display
// scaling does not change the declared minimum.

public struct CompactWindowMinimum: Sendable, Equatable {
  public let width: Double
  public let height: Double
  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }
  public var description: String {
    String(Int(width)) + " x " + String(Int(height)) + " pt"
  }
}

public enum CompactWindowScenario: String, CaseIterable, Sendable, Equatable {
  case editor
  case textEditing
  case comments
  case forms
  case compare
  case scanOCR

  public var title: String {
    switch self {
    case .editor: return "Editor"
    case .textEditing: return "Text editing with properties"
    case .comments: return "Comments and review"
    case .forms: return "Form filling"
    case .compare: return "Comparison"
    case .scanOCR: return "Scan, OCR and cleanup"
    }
  }

  /// Declared logical minimum sizes (points). The same values apply at any
  /// display scaling; only the backing pixels change.
  public var minimum: CompactWindowMinimum {
    switch self {
    case .editor: return CompactWindowMinimum(width: 760, height: 480)
    case .textEditing: return CompactWindowMinimum(width: 900, height: 560)
    case .comments: return CompactWindowMinimum(width: 720, height: 520)
    case .forms: return CompactWindowMinimum(width: 700, height: 480)
    case .compare: return CompactWindowMinimum(width: 900, height: 600)
    case .scanOCR: return CompactWindowMinimum(width: 800, height: 560)
    }
  }

  /// The controls that must remain reachable at the declared minimum.
  public var requiredControlIDs: [String] {
    switch self {
    case .editor:
      return ["toolbar.tool", "canvas.document", "status.page", "action.primary"]
    case .textEditing:
      return [
        "toolbar.tool", "canvas.document", "properties.bold", "properties.size",
        "action.primary",
      ]
    case .comments:
      return ["canvas.document", "comments.list", "comments.reply", "action.primary"]
    case .forms:
      return ["canvas.document", "form.field", "form.submit", "action.primary"]
    case .compare:
      return ["compare.controls", "canvas.compare", "compare.navigate", "action.primary"]
    case .scanOCR:
      return ["scan.controls", "scan.preview", "scan.progress", "action.primary"]
    }
  }

  /// Control ids that live inside the collapsible sidebar.
  public var sidebarControlIDs: [String] {
    switch self {
    case .comments: return ["comments.list", "comments.reply"]
    case .scanOCR: return []
    default: return []
    }
  }
}

public struct CompactWindowControl: Sendable, Equatable {
  public let id: String
  public let title: String
  public let minimumWidth: Double
  public let inSidebar: Bool
  public init(id: String, title: String, minimumWidth: Double, inSidebar: Bool = false) {
    self.id = id
    self.title = title
    self.minimumWidth = minimumWidth
    self.inSidebar = inSidebar
  }
}

public enum CompactWindowLayout {
  public static let controls: [CompactWindowControl] = [
    CompactWindowControl(id: "toolbar.tool", title: "Tool picker", minimumWidth: 520),
    CompactWindowControl(id: "canvas.document", title: "Document canvas", minimumWidth: 420),
    CompactWindowControl(id: "status.page", title: "Page status", minimumWidth: 480),
    CompactWindowControl(id: "properties.bold", title: "Bold", minimumWidth: 680),
    CompactWindowControl(id: "properties.size", title: "Font size", minimumWidth: 680),
    CompactWindowControl(id: "comments.list", title: "Comments list", minimumWidth: 640,
      inSidebar: true),
    CompactWindowControl(id: "comments.reply", title: "Reply", minimumWidth: 640,
      inSidebar: true),
    CompactWindowControl(id: "form.field", title: "Form field", minimumWidth: 560),
    CompactWindowControl(id: "form.submit", title: "Submit", minimumWidth: 620),
    CompactWindowControl(id: "compare.controls", title: "Compare controls", minimumWidth: 760),
    CompactWindowControl(id: "canvas.compare", title: "Comparison canvas", minimumWidth: 640),
    CompactWindowControl(id: "compare.navigate", title: "Change navigation", minimumWidth: 700),
    CompactWindowControl(id: "scan.controls", title: "Scan controls", minimumWidth: 700),
    CompactWindowControl(id: "scan.preview", title: "Scan preview", minimumWidth: 560),
    CompactWindowControl(id: "scan.progress", title: "Scan progress", minimumWidth: 620),
    CompactWindowControl(id: "action.primary", title: "Primary action", minimumWidth: 0),
  ]

  public static func control(_ id: String) -> CompactWindowControl? {
    controls.first { $0.id == id }
  }
}

public struct CompactWindowState: Sendable, Equatable {
  public var scenario: CompactWindowScenario
  public var width: Double
  public var height: Double
  public var focusedControlID: String
  public var documentName: String
  public var pageIndex: Int
  public var selection: String?
  public var propertyValues: [String: String]
  public var pendingDraft: String
  public var sidebarVisible: Bool
  public var popoverControlID: String?
  public var zoomPercent: Int

  public init(
    scenario: CompactWindowScenario, documentName: String = "Document A", pageIndex: Int = 1,
    focusedControlID: String = "canvas.document", selection: String? = "selection",
    propertyValues: [String: String] = ["Bold": "Off", "FontSize": "12"],
    pendingDraft: String = "Draft note", sidebarVisible: Bool = false,
    popoverControlID: String? = nil, zoomPercent: Int = 100
  ) {
    self.scenario = scenario
    self.width = scenario.minimum.width
    self.height = scenario.minimum.height
    self.focusedControlID = focusedControlID
    self.documentName = documentName
    self.pageIndex = pageIndex
    self.selection = selection
    self.propertyValues = propertyValues
    self.pendingDraft = pendingDraft
    self.sidebarVisible = sidebarVisible
    self.popoverControlID = popoverControlID
    self.zoomPercent = zoomPercent
  }
}

public struct CompactWindowIssue: Sendable, Equatable {
  public let action: String
  public let message: String
  public init(action: String, message: String) {
    self.action = action
    self.message = message
  }
}

public struct CompactWindowReport: Sendable, Equatable {
  public let scenario: CompactWindowScenario
  public let minimum: CompactWindowMinimum
  public let steps: [String]
  public let issues: [CompactWindowIssue]
  public var passed: Bool { issues.isEmpty }
  public var summary: String {
    passed
      ? scenario.title + ": passed compact-window qualification at "
        + minimum.description + "."
      : scenario.title + ": " + String(issues.count) + " issue(s) at "
        + minimum.description + "."
  }
}

/// Actionable compact-window model. Resizes clamp to the declared minimum, sidebar
/// and popover toggles move focus instead of dropping it, and switching documents
/// restores the other document's context.
public final class CompactWindowModel {
  public private(set) var state: CompactWindowState
  private var documentStates: [String: CompactWindowState] = [:]
  public private(set) var steps: [String] = []
  public private(set) var issues: [CompactWindowIssue] = []

  public init(scenario: CompactWindowScenario) {
    state = CompactWindowState(scenario: scenario)
    documentStates[state.documentName] = state
  }

  public var minimum: CompactWindowMinimum { state.scenario.minimum }

  /// Controls that can be reached at the current width (a sidebar control is
  /// reachable by showing the sidebar explicitly).
  public var reachableControls: [String] {
    state.scenario.requiredControlIDs.filter { id in
      guard let control = CompactWindowLayout.control(id) else { return true }
      return state.width >= control.minimumWidth
    }
  }

  /// Controls visible right now with the current sidebar/popover state.
  public var currentlyVisibleControls: [String] {
    reachableControls.filter { id in
      guard let control = CompactWindowLayout.control(id) else { return true }
      return !control.inSidebar || state.sidebarVisible
    }
  }

  public func resize(width: Double, height: Double) {
    let clampedWidth = max(width, minimum.width)
    let clampedHeight = max(height, minimum.height)
    state.width = clampedWidth
    state.height = clampedHeight
    steps.append("resize to " + String(Int(clampedWidth)) + " x " + String(Int(clampedHeight)))
    enforceFocusInvariant(action: "resize")
  }

  public func toggleSidebar() {
    state.sidebarVisible.toggle()
    steps.append(state.sidebarVisible ? "show sidebar" : "hide sidebar")
    if !state.sidebarVisible,
      let control = CompactWindowLayout.control(state.focusedControlID), control.inSidebar
    {
      state.focusedControlID = "canvas.document"
      steps.append("focus moved from the hidden sidebar to the canvas")
    }
    enforceFocusInvariant(action: "toggleSidebar")
  }

  public func openPopover(controlID: String) {
    state.popoverControlID = controlID
    steps.append("open popover for " + controlID)
    enforceFocusInvariant(action: "openPopover")
  }

  public func closePopover() {
    state.popoverControlID = nil
    steps.append("close popover")
    enforceFocusInvariant(action: "closePopover")
  }

  public func setZoom(percent: Int) {
    let clamped = min(max(percent, 25), 400)
    state.zoomPercent = clamped
    steps.append("zoom to " + String(clamped) + "%")
    enforceFocusInvariant(action: "zoom")
  }

  public func focus(controlID: String) {
    if let control = CompactWindowLayout.control(controlID), control.inSidebar,
      !state.sidebarVisible
    {
      state.sidebarVisible = true
      steps.append("show sidebar to focus " + controlID)
    }
    state.focusedControlID = controlID
    steps.append("focus " + controlID)
    enforceFocusInvariant(action: "focus")
  }

  public func editDraft(_ text: String) {
    state.pendingDraft = text
    steps.append("edit draft")
    enforceFocusInvariant(action: "editDraft")
  }

  public func switchDocument(to name: String) {
    documentStates[state.documentName] = state
    steps.append("switch document to " + name)
    if let stored = documentStates[name] {
      let currentDocumentName = name
      state = stored
      state.documentName = currentDocumentName
    } else {
      state.documentName = name
      state.pageIndex = 1
      state.selection = nil
      state.propertyValues = [:]
      state.pendingDraft = ""
      state.popoverControlID = nil
    }
    enforceFocusInvariant(action: "switchDocument")
  }

  private func enforceFocusInvariant(action: String) {
    if state.width < minimum.width || state.height < minimum.height {
      issues.append(
        CompactWindowIssue(
          action: action,
          message: "The window is below the declared minimum " + minimum.description + "."))
    }
    if state.focusedControlID.isEmpty {
      issues.append(CompactWindowIssue(action: action, message: "The focus control is empty."))
    } else if let control = CompactWindowLayout.control(state.focusedControlID) {
      if control.inSidebar, !state.sidebarVisible {
        issues.append(
          CompactWindowIssue(
            action: action,
            message: "Focus stayed on hidden sidebar control " + control.id + "."))
      }
      if state.width < control.minimumWidth {
        issues.append(
          CompactWindowIssue(
            action: action,
            message: "Focused control " + control.id + " is clipped at width "
              + String(Int(state.width)) + "."))
      }
    } else if !state.scenario.requiredControlIDs.contains(state.focusedControlID) {
      issues.append(
        CompactWindowIssue(
          action: action, message: "Focus moved to unknown control " + state.focusedControlID + "."))
    }
  }
}

public enum CompactWindowQualification {
  /// Common display scaling values. Logical minimum sizes do not change; the
  /// model records the scale so the evidence is explicit.
  public static let displayScales: [Double] = [1.0, 1.5, 2.0]

  public static func run(
    scenario: CompactWindowScenario, scale: Double = 1.0
  ) -> CompactWindowReport {
    let model = CompactWindowModel(scenario: scenario)
    var issues: [CompactWindowIssue] = []
    let baseline = model.state
    let minimum = scenario.minimum

    model.resize(width: minimum.width + 160, height: minimum.height + 100)
    model.focus(controlID: "canvas.document")
    model.toggleSidebar()
    model.resize(width: minimum.width, height: minimum.height)
    model.setZoom(percent: 150)
    model.setZoom(percent: 75)
    model.openPopover(controlID: "toolbar.tool")
    model.closePopover()
    model.toggleSidebar()
    model.resize(width: minimum.width - 260, height: minimum.height - 200)
    model.switchDocument(to: "Document B")
    model.editDraft("Draft for B")
    model.switchDocument(to: baseline.documentName)
    model.focus(controlID: "canvas.document")

    if model.state.width < minimum.width || model.state.height < minimum.height {
      issues.append(
        CompactWindowIssue(
          action: "minimum", message: "Resizing below the minimum was not clamped."))
    }
    if model.state.documentName != baseline.documentName {
      issues.append(
        CompactWindowIssue(action: "document", message: "Document switch did not restore A."))
    }
    if model.state.pageIndex != baseline.pageIndex || model.state.selection != baseline.selection {
      issues.append(
        CompactWindowIssue(
          action: "context", message: "Page or selection changed across resizing/zooming."))
    }
    if model.state.propertyValues != baseline.propertyValues {
      issues.append(
        CompactWindowIssue(
          action: "properties", message: "Property values changed across resizing/zooming."))
    }
    if model.state.pendingDraft != baseline.pendingDraft {
      issues.append(
        CompactWindowIssue(
          action: "draft", message: "The pending draft changed across resizing/zooming."))
    }
    for controlID in scenario.requiredControlIDs {
      if !model.reachableControls.contains(controlID) {
        issues.append(
          CompactWindowIssue(
            action: "reachability",
            message: "Required control " + controlID + " is unreachable at the minimum size."))
      }
    }
    if scenario.title.isEmpty {
      issues.append(CompactWindowIssue(action: "scenario", message: "Scenario has no title."))
    }
    if !(displayScales.contains(scale)) {
      issues.append(
        CompactWindowIssue(action: "scale", message: "Display scale is outside the declared set."))
    }
    issues.append(contentsOf: model.issues)
    return CompactWindowReport(
      scenario: scenario, minimum: minimum,
      steps: ["scale=" + String(scale)] + model.steps, issues: issues)
  }

  public static func runAll() -> [CompactWindowReport] {
    CompactWindowScenario.allCases.map { run(scenario: $0) }
  }
}
