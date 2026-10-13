import AppKit
import Carbon.HIToolbox

/// P33-024: independent accessibility audit through the system accessibility
/// API — the same interface VoiceOver uses — plus a keyboard map audit over
/// the app's menu bar. The audit reports what it checked so the smoke can
/// assert it rather than trusting the implementation.
enum AccessibilityAudit {
  struct Report {
    let elementCount: Int
    let interactiveCount: Int
    let labels: Set<String>
    let unlabeled: [String]
    let windowsAudited: Int
  }

  /// Interactive roles whose accessible name must not be empty.
  private static let interactiveRoles: Set<String> = [
    kAXButtonRole as String, kAXPopUpButtonRole as String, kAXTextFieldRole as String,
    kAXCheckBoxRole as String, kAXRadioButtonRole as String, kAXSliderRole as String,
    "AXLink", kAXMenuButtonRole as String, kAXComboBoxRole as String,
    "AXSearchField", kAXDisclosureTriangleRole as String,
    kAXIncrementorRole as String, kAXTabGroupRole as String,
  ]

  /// Standard AppKit-provided controls need no app label: window buttons and
  /// scrollbar parts. Controls rendered from the PDF itself (form widgets,
  /// links, annotations) are document content, not native UI, and are skipped
  /// by the `inDocument` scope instead.
  private static let exemptSubroles: Set<String> = [
    "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    "AXIncrementPage", "AXDecrementPage", "AXIncrementArrow", "AXDecrementArrow",
    "AXIncrementLine", "AXDecrementLine", "AXThumb",
  ]

  static func run() -> Report {
    let application = AXUIElementCreateApplication(getpid())
    var windowsValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue)
        == .success,
      let windows = windowsValue as? [AXUIElement]
    else {
      return Report(
        elementCount: 0, interactiveCount: 0, labels: [], unlabeled: ["no windows"],
        windowsAudited: 0)
    }
    var elementCount = 0
    var interactiveCount = 0
    var labels: Set<String> = []
    var unlabeled: [String] = []
    var windowsAudited = 0
    for window in windows {
      let title = attribute(window, kAXTitleAttribute) ?? ""
      guard !title.isEmpty else { continue }
      windowsAudited += 1
      walk(
        window, windowTitle: title, inDocument: false, elementCount: &elementCount,
        interactiveCount: &interactiveCount, labels: &labels, unlabeled: &unlabeled)
    }
    return Report(
      elementCount: elementCount, interactiveCount: interactiveCount, labels: labels,
      unlabeled: unlabeled, windowsAudited: windowsAudited)
  }

  private static func walk(
    _ element: AXUIElement, windowTitle: String, inDocument: Bool, elementCount: inout Int,
    interactiveCount: inout Int, labels: inout Set<String>, unlabeled: inout [String]
  ) {
    elementCount += 1
    let role = attribute(element, kAXRoleAttribute) ?? ""
    let subrole = attribute(element, kAXSubroleAttribute) ?? ""
    let title = attribute(element, kAXTitleAttribute) ?? ""
    let description = attribute(element, kAXDescriptionAttribute) ?? ""
    let value = attribute(element, kAXValueAttribute) ?? ""
    let label = !description.isEmpty ? description : (!title.isEmpty ? title : value)
    if !label.isEmpty { labels.insert(label) }
    let insideDocument = inDocument || subrole == "AXSharedDocumentContainer"
    if interactiveRoles.contains(role), !exemptSubroles.contains(subrole), !insideDocument {
      interactiveCount += 1
      if label.isEmpty {
        unlabeled.append("\(role)/\(subrole) in \(windowTitle)")
      }
    }
    for child in children(of: element) {
      walk(
        child, windowTitle: windowTitle, inDocument: insideDocument,
        elementCount: &elementCount, interactiveCount: &interactiveCount, labels: &labels,
        unlabeled: &unlabeled)
    }
    if role == kAXOutlineRole as String || role == kAXScrollAreaRole as String
      || role == kAXGroupRole as String
    {
      // SwiftUI lists expose rows lazily through these attributes.
      for name in [kAXRowsAttribute, kAXContentsAttribute] {
        for child in elements(of: element, attribute: name) {
          walk(
            child, windowTitle: windowTitle, inDocument: insideDocument,
            elementCount: &elementCount, interactiveCount: &interactiveCount, labels: &labels,
            unlabeled: &unlabeled)
        }
      }
    }
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    elements(of: element, attribute: kAXChildrenAttribute)
  }

  private static func elements(of element: AXUIElement, attribute name: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
      let value
    else { return [] }
    if let list = value as? [AXUIElement] { return list }
    if CFGetTypeID(value) == AXUIElementGetTypeID() {
      return [unsafeBitCast(value, to: AXUIElement.self)]
    }
    return []
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  /// P12-026/P12-028: find a labeled element in the key window's AX tree
  /// (SwiftUI serves labels without backing every one onto an NSView
  /// property, so view-hierarchy walks cannot see them all).
  static func keyWindowElement(labeled label: String) -> AXUIElement? {
    guard let window = keyWindow() else { return nil }
    return findElement(labeled: label, in: window)
  }

  private static func findElement(labeled label: String, in element: AXUIElement) -> AXUIElement? {
    let description = attribute(element, kAXDescriptionAttribute) ?? ""
    let title = attribute(element, kAXTitleAttribute) ?? ""
    if description == label || title == label { return element }
    for child in children(of: element) {
      if let found = findElement(labeled: label, in: child) { return found }
    }
    return nil
  }

  private static func keyWindow() -> AXUIElement? {
    let application = AXUIElementCreateApplication(getpid())
    var windowsValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue)
        == .success,
      let windows = windowsValue as? [AXUIElement]
    else { return nil }
    for window in windows {
      var mainValue: CFTypeRef?
      guard AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &mainValue)
        == .success,
        (mainValue as? Bool) == true
      else { continue }
      return window
    }
    return nil
  }

  /// The element's size in points, if the AX tree reports one.
  static func size(of element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
      == .success,
      let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
    else { return nil }
    let ax = unsafeBitCast(axValue, to: AXValue.self)
    var size = CGSize.zero
    guard AXValueGetValue(ax, .cgSize, &size) else { return nil }
    return size
  }

  /// P12-026: the element's top-left position in screen coordinates.
  static func position(of element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
      == .success,
      let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID()
    else { return nil }
    let ax = unsafeBitCast(axValue, to: AXValue.self)
    var point = CGPoint.zero
    guard AXValueGetValue(ax, .cgPoint, &point) else { return nil }
    return point
  }

  /// Move keyboard focus to the element through the same interface
  /// VoiceOver uses.
  @discardableResult
  static func focus(_ element: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      == .success
  }
}

/// P33-024: keyboard workflow audit over the app's menu bar. Key equivalents
/// are read from the live menu, so the audit follows AppKit's keyboard-layout
/// localization (a Turkish layout maps [ and ] to ğ and ü, for example).
enum KeyboardAudit {
  struct Requirement {
    let title: String
    let modifiers: NSEvent.ModifierFlags
  }

  struct Report {
    let shortcutCount: Int
    let missing: [String]
  }

  /// Every menu item in the bar with a key equivalent.
  @MainActor
  static func shortcuts(in menu: NSMenu = NSApp.mainMenu ?? NSMenu()) -> [NSMenuItem] {
    var found: [NSMenuItem] = []
    func walk(_ menu: NSMenu) {
      for item in menu.items {
        if !item.keyEquivalent.isEmpty { found.append(item) }
        if let submenu = item.submenu { walk(submenu) }
      }
    }
    walk(menu)
    return found
  }

  @MainActor
  static func find(_ title: String, in menu: NSMenu = NSApp.mainMenu ?? NSMenu()) -> NSMenuItem? {
    for item in menu.items {
      if item.title == title { return item }
      if let submenu = item.submenu, let found = find(title, in: submenu) { return found }
    }
    return nil
  }

  /// Verify that each required command has a key equivalent with the expected
  /// modifiers under the current keyboard layout.
  @MainActor
  static func verify(_ requirements: [Requirement]) -> Report {
    var missing: [String] = []
    for requirement in requirements {
      guard let item = find(requirement.title), !item.keyEquivalent.isEmpty else {
        missing.append(requirement.title)
        continue
      }
      let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
      let expected = requirement.modifiers.intersection(.deviceIndependentFlagsMask)
      if mask != expected { missing.append(requirement.title) }
    }
    return Report(shortcutCount: shortcuts().count, missing: missing)
  }

  /// Invoke a menu item the same way a key press would (action to target).
  @discardableResult
  @MainActor
  static func invoke(_ title: String) -> Bool {
    guard let item = find(title), let action = item.action else { return false }
    return NSApp.sendAction(action, to: item.target, from: item)
  }

  /// Press the command's actual (layout-localized) key equivalent through the
  /// menu's key-equivalent path, exactly as a real key press would be routed.
  @discardableResult
  @MainActor
  static func press(_ title: String) -> Bool {
    guard let item = find(title), !item.keyEquivalent.isEmpty else { return false }
    item.menu?.update()
    // Text commands need their physical keys as well as their characters.
    // Key code zero is A, which can route Command-S/F as Select All.
    let keyCode: UInt16
    switch item.keyEquivalent {
    case "s": keyCode = UInt16(kVK_ANSI_S)
    case "f": keyCode = UInt16(kVK_ANSI_F)
    default: keyCode = 0
    }
    guard item.isEnabled,
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: item.keyEquivalentModifierMask,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
        characters: item.keyEquivalent, charactersIgnoringModifiers: item.keyEquivalent,
        isARepeat: false, keyCode: keyCode)
    else { return false }
    return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
  }
}
