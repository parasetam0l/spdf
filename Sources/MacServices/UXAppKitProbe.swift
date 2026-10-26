import AppKit

// UX-01: real AppKit accessibility-attribute probe. It builds a small native
// surface (button, text field, slider and a labelled group), connects a real
// nextKeyView loop and reads the same accessibility attributes VoiceOver uses.
// This proves attributes/actions/loop membership rather than element existence;
// it is not a substitute for a human VoiceOver session (see the manual protocol).

@MainActor
public enum UXAppKitProbe {
  public struct Result {
    public let elements: [UXAccessibilityElementProbe]
    public let keyViewOrder: [String]
    public let report: UXAccessibilityProbeReport
    public let currentFocusLabel: String?
    public init(
      elements: [UXAccessibilityElementProbe], keyViewOrder: [String],
      report: UXAccessibilityProbeReport, currentFocusLabel: String?
    ) {
      self.elements = elements
      self.keyViewOrder = keyViewOrder
      self.report = report
      self.currentFocusLabel = currentFocusLabel
    }
  }

  public static func run() -> Result {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))

    let bold = NSButton(title: "Bold", target: nil, action: nil)
    bold.setAccessibilityLabel("Bold")
    bold.setAccessibilityHelp("Toggles bold for the current selection.")
    bold.setAccessibilityRole(.button)
    bold.setAccessibilityValue("Off")
    bold.frame = NSRect(x: 16, y: 160, width: 120, height: 28)

    let fontSize = NSSlider(value: 12, minValue: 6, maxValue: 72, target: nil, action: nil)
    fontSize.setAccessibilityRole(.slider)
    fontSize.setAccessibilityLabel("Font size")
    fontSize.setAccessibilityHelp("Adjusts the font size of the current selection.")
    fontSize.setAccessibilityValue("12")
    fontSize.frame = NSRect(x: 16, y: 112, width: 220, height: 28)

    let draft = NSTextField(string: "Draft note")
    draft.setAccessibilityRole(.textField)
    draft.setAccessibilityLabel("Pending draft")
    draft.setAccessibilityHelp("Shows the unsaved note draft; Command+S saves it.")
    draft.setAccessibilityValue("Draft note")
    draft.frame = NSRect(x: 16, y: 64, width: 280, height: 24)

    let primary = NSButton(title: "Apply", target: nil, action: nil)
    primary.setAccessibilityLabel("Apply changes")
    primary.setAccessibilityHelp("Applies the reviewed changes and returns focus to the canvas.")
    primary.setAccessibilityRole(.button)
    primary.setAccessibilityValue("enabled")
    primary.frame = NSRect(x: 16, y: 16, width: 120, height: 28)

    let group = NSBox(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
    group.title = "Properties"
    group.setAccessibilityLabel("Properties group")
    group.setAccessibilityRole(.group)

    container.addSubview(group)
    for view in [bold, fontSize, draft, primary] { container.addSubview(view) }

    // A real key view loop: VoiceOver and keyboard-only users traverse this order.
    bold.nextKeyView = fontSize
    fontSize.nextKeyView = draft
    draft.nextKeyView = primary
    primary.nextKeyView = bold

    var order: [String] = []
    var current: NSView? = bold
    var guardCount = 0
    while let view = current, guardCount < 16 {
      let label = view.accessibilityLabel() ?? view.className
      order.append(label)
      current = view.nextKeyView
      guardCount += 1
    }

    let interactiveViews: [NSView] = [bold, fontSize, draft, primary]
    let elements = interactiveViews.map { view -> UXAccessibilityElementProbe in
      let role = view.accessibilityRole()?.rawValue ?? ""
      let value = view.accessibilityValue().map { String(describing: $0) }
      return UXAccessibilityElementProbe(
        role: role,
        label: view.accessibilityLabel() ?? "",
        value: value,
        help: view.accessibilityHelp(),
        actions: accessibilityActions(of: view),
        isInteractive: true)
    }
    let report = UXAccessibilityProbe.evaluate(elements)
    let firstResponderLabel = container.window?.firstResponder.flatMap { responder in
      (responder as? NSView)?.accessibilityLabel()
    }
    return Result(
      elements: elements, keyViewOrder: order, report: report,
      currentFocusLabel: firstResponderLabel)
  }

  /// Accessibility actions a keyboard/VoiceOver user can trigger on the control.
  static func accessibilityActions(of view: NSView) -> [String] {
    var actions: [String] = []
    if let button = view as? NSButton {
      actions.append(contentsOf: button.accessibilityActionNames().map(\.rawValue))
      if actions.isEmpty { actions.append("AXPress") }
    } else if view is NSTextField {
      actions.append("AXConfirm")
    } else if view is NSSlider {
      actions.append("AXIncrement")
      actions.append("AXDecrement")
    } else {
      actions.append(contentsOf: view.accessibilityActionNames().map(\.rawValue))
    }
    return actions
  }
}
