import AppKit
import MacServices
import PDFEditing
import SwiftUI

/// P24-013/P18-021: in-page editing. The overlay hit-tests form widgets and
/// document text runs under the pointer, positions a native text field
/// exactly over the target's page geometry, commits on Enter or focus loss,
/// and cancels on Escape. Clicks anywhere else pass through to the PDF view
/// unchanged, so native text input (including IME composition) works in
/// place.
struct PageEditOverlay: NSViewRepresentable {
  @ObservedObject var viewer: PDFViewingSession

  func makeNSView(context: Context) -> PageEditOverlayView {
    let view = PageEditOverlayView()
    view.viewer = viewer
    return view
  }

  func updateNSView(_ nsView: PageEditOverlayView, context: Context) {
    nsView.viewer = viewer
    // P12-013: leaving the text tool finishes the pending edit instead of
    // abandoning it behind the new tool.
    if viewer.activeTool != .textEdit {
      nsView.commitEditing()
    }
  }
}

@MainActor
final class PageEditOverlayView: NSView, NSTextFieldDelegate {
  weak var viewer: PDFViewingSession?

  enum EditTarget {
    case form(FormFieldTarget)
    case textRun(PageTextTarget)

    var pageIndex: Int {
      switch self {
      case .form(let target): return target.pageIndex
      case .textRun(let target): return target.pageIndex
      }
    }

    var rect: [Double] {
      switch self {
      case .form(let target): return target.rect
      case .textRun(let target): return target.rect
      }
    }

    var value: String {
      switch self {
      case .form(let target): return target.value
      case .textRun(let target): return target.text
      }
    }

    /// P15-024: the run's input style; nil for form targets, which keep the
    /// existing system-styled editor.
    var style: TextInputStyle? {
      switch self {
      case .form: return nil
      case .textRun(let target): return target.style
      }
    }

    var editorIdentifier: String {
      switch self {
      case .form: return "spdf-form-editor"
      case .textRun: return "spdf-text-editor"
      }
    }
  }

  private var editor: NSTextField?
  private var target: EditTarget?

  override var acceptsFirstResponder: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// P12-017: a press that may become a drag. Editing begins on mouse-up
  /// over the same target (a click); drags are never claimed here so the
  /// page view keeps native drag selection.
  private var pressTarget: EditTarget?
  private var pressPoint: NSPoint = .zero

  override func hitTest(_ point: NSPoint) -> NSView? {
    if let editor {
      return super.hitTest(point) ?? self
    }
    guard let target = target(at: point) else { return nil }
    // P12-017: form widgets always edit on click; text runs only claim the
    // pointer in the text tool so drag selection passes through otherwise.
    switch target {
    case .form:
      return self
    case .textRun:
      return viewer?.activeTool == .textEdit ? self : nil
    }
  }

  override func mouseDown(with event: NSEvent) {
    if editor != nil {
      commitEditing()
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    pressTarget = target(at: point)
    pressPoint = point
  }

  override func mouseUp(with event: NSEvent) {
    guard editor == nil, let pending = pressTarget else {
      pressTarget = nil
      return
    }
    pressTarget = nil
    let point = convert(event.locationInWindow, from: nil)
    guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) <= 4,
      let landed = target(at: point),
      landed.pageIndex == pending.pageIndex
    else { return }
    // Editing arms the text tool; a vetoed switch aborts the edit.
    guard viewer?.activateTool(.textEdit) != false else { return }
    beginEditing(pending)
  }

  /// Resolve an editable target under an overlay point. The overlay shares
  /// the PDF view's frame, so overlay and view coordinates agree.
  private func target(at point: NSPoint) -> EditTarget? {
    guard let viewer, let document = viewer.view.document,
      let page = viewer.view.page(for: point, nearest: false)
    else { return nil }
    let pagePoint = viewer.view.convert(point, to: page)
    let index = document.index(for: page)
    let values = [Double(pagePoint.x), Double(pagePoint.y)]
    if let form = viewer.formFieldProvider?(index, values) {
      return .form(form)
    }
    if let run = viewer.textRunProvider?(index, values) {
      return .textRun(run)
    }
    return nil
  }

  private func beginEditing(_ target: EditTarget) {
    guard let viewer, let document = viewer.view.document,
      target.pageIndex >= 0, target.pageIndex < document.pageCount,
      let page = document.page(at: target.pageIndex),
      target.rect.count == 4
    else { return }
    if case .form(let form) = target, form.isReadOnly { return }
    var pageRect = CGRect(
      x: target.rect[0], y: target.rect[1], width: target.rect[2] - target.rect[0],
      height: target.rect[3] - target.rect[1])
    // Conservative metrics can produce zero-width run bounds; widen the
    // editor so native input stays usable over the line.
    if pageRect.width < 8 {
      pageRect.size.width = max(60, Double(target.value.count) * pageRect.height * 0.55)
    }
    let viewRect = viewer.view.convert(pageRect, from: page)
    let localRect = convert(viewRect, from: viewer.view)
    guard localRect.width > 4, localRect.height > 4 else { return }

    let field = NSTextField(frame: localRect)
    field.identifier = NSUserInterfaceItemIdentifier(target.editorIdentifier)
    field.stringValue = target.value
    // P15-024: the editor shows the run's own family and color at the
    // on-screen size; form targets keep the previous system styling.
    field.font = target.style?.nativeFont(viewHeight: localRect.height)
      ?? .systemFont(ofSize: max(9, min(28, localRect.height * 0.62)))
    if let color = target.style?.nativeTextColor {
      field.textColor = color
    }
    field.bezelStyle = .squareBezel
    field.focusRingType = .none
    field.delegate = self
    field.target = self
    field.action = #selector(commitFromEditor(_:))
    addSubview(field)
    editor = field
    self.target = target
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
  }

  @objc private func commitFromEditor(_ sender: Any?) {
    commitEditing()
  }

  func commitEditing() {
    guard let editor, let target else { return }
    let text = editor.stringValue
    removeEditor()
    switch target {
    case .form(let form):
      viewer?.onFormFieldCommit?(form.fieldName, text)
    case .textRun(let run):
      viewer?.onTextRunCommit?(run.pageIndex, run.runIndex, text)
    }
  }

  private func cancelEditing() {
    removeEditor()
  }

  private func removeEditor() {
    // P17-011: clear the editor state *before* removing the view. Removing a
    // focused field fires controlTextDidEndEditing synchronously, and a
    // still-set editor there would commit the text this call is discarding.
    let field = editor
    editor = nil
    target = nil
    field?.removeFromSuperview()
    if let view = viewer?.view { window?.makeFirstResponder(view) }
  }

  // MARK: - NSTextFieldDelegate

  func controlTextDidEndEditing(_ obj: Notification) {
    // P17-011: end-editing fires for Escape too; the movement value tells
    // cancel apart from a real commit (Return or focus loss), so Escape can
    // never commit the edit it was meant to discard.
    if let movement = obj.userInfo?["NSTextMovement"] as? Int,
      movement == NSTextMovement.cancel.rawValue
    {
      cancelEditing()
      return
    }
    // Enter commits through the action; this covers focus loss.
    commitEditing()
  }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      cancelEditing()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      commitEditing()
      return true
    }
    return false
  }
}
