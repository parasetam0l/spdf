import AppKit
import MacServices
import PDFEditing
import SwiftUI

/// Routes page text to the direct canvas and form widgets to native fields.
/// Outside Edit PDF, ordinary page text selection passes through to PDFKit.
struct PageEditOverlay: NSViewRepresentable {
  @ObservedObject var viewer: PDFViewingSession

  func makeNSView(context: Context) -> PageEditOverlayView {
    let view = PageEditOverlayView()
    view.viewer = viewer
    viewer.pendingEditFinisher = { [weak view] in view?.commitEditing() ?? true }
    viewer.textBlockEditStarter = { [weak view] target in view?.editTextBlock(target) }
    return view
  }

  func updateNSView(_ nsView: PageEditOverlayView, context: Context) {
    nsView.viewer = viewer
    viewer.pendingEditFinisher = { [weak nsView] in nsView?.commitEditing() ?? true }
    viewer.textBlockEditStarter = { [weak nsView] target in nsView?.editTextBlock(target) }
    // P12-013: leaving the text tool finishes the pending edit instead of
    // abandoning it behind the new tool.
    if viewer.activeTool != .textEdit && viewer.activeTool != .addText {
      nsView.commitEditing()
    }
    nsView.synchronizeCanvas()
  }

  static func dismantleNSView(_ nsView: PageEditOverlayView, coordinator: ()) {
    nsView.discardPendingEditing()
  }
}

@MainActor
final class PageEditOverlayView: NSView, NSTextFieldDelegate {
  weak var viewer: PDFViewingSession?
  private var isCommitting = false

  enum EditTarget {
    case form(FormFieldTarget)
    case textRun(PageTextTarget)
    case newText(pageIndex: Int, rect: [Double])

    var pageIndex: Int {
      switch self {
      case .form(let target): return target.pageIndex
      case .textRun(let target): return target.pageIndex
      case .newText(let pageIndex, _): return pageIndex
      }
    }

    var rect: [Double] {
      switch self {
      case .form(let target): return target.rect
      case .textRun(let target): return target.rect
      case .newText(_, let rect): return rect
      }
    }

    var value: String {
      switch self {
      case .form(let target): return target.value
      case .textRun(let target): return target.text
      case .newText: return ""
      }
    }

    /// P15-024: the run's input style; nil for form targets, which keep the
    /// existing system-styled editor.
    var style: TextInputStyle? {
      switch self {
      case .form: return nil
      case .textRun(let target): return target.style
      case .newText: return nil
      }
    }

    var editorIdentifier: String {
      switch self {
      case .form: return "spdf-form-editor"
      case .textRun: return "spdf-text-editor"
      case .newText: return "spdf-new-text-editor"
      }
    }
  }

  private var editor: NSTextField?
  private var target: EditTarget?
  private var textCanvas: InlinePageTextCanvas?

  override var acceptsFirstResponder: Bool { false }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// In Edit PDF a body drag moves a block; a click places its text caret.
  /// The Select tool keeps PDFKit's native character selection.
  private var pressTarget: EditTarget?
  private var pressPoint: NSPoint = .zero

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point) else { return nil }
    if let canvas = textCanvas {
      return canvas.hitTest(canvas.convert(point, from: self)) ?? self
    }
    if editor != nil {
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
    case .newText:
      return self
    }
  }

  override func mouseDown(with event: NSEvent) {
    if editor != nil || textCanvas != nil, !commitEditing() { return }
    let point = convert(event.locationInWindow, from: nil)
    pressTarget = target(at: point)
    pressPoint = point
  }

  override func mouseDragged(with event: NSEvent) {
    guard let pending = pressTarget, case .textRun = pending else { return }
    let start = convert(pressPoint, to: nil)
    let delta = NSPoint(
      x: event.locationInWindow.x - start.x, y: event.locationInWindow.y - start.y)
    guard hypot(delta.x, delta.y) > 4 else { return }
    if textCanvas == nil { beginEditing(pending, at: pressPoint) }
    textCanvas?.move(byWindowDelta: delta, finished: false)
  }

  override func mouseUp(with event: NSEvent) {
    if let canvas = textCanvas, canvas.isDragging {
      let start = convert(pressPoint, to: nil)
      canvas.move(
        byWindowDelta: NSPoint(
          x: event.locationInWindow.x - start.x,
          y: event.locationInWindow.y - start.y), finished: true)
      pressTarget = nil
      return
    }
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
    if case .newText = pending {
      // Keep Add Text armed while the new inline field is being edited.
    } else if viewer?.activateTool(.textEdit) == false {
      return
    }
    beginEditing(pending, at: point)
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
    if viewer.activeTool == .addText {
      let bounds = page.bounds(for: viewer.view.displayBox)
      let x = min(max(pagePoint.x, bounds.minX), bounds.maxX - 24)
      let top = min(max(pagePoint.y, bounds.minY + 20), bounds.maxY)
      return .newText(
        pageIndex: index,
        rect: [Double(x), Double(top - 20), Double(min(x + 300, bounds.maxX)), Double(top)])
    }
    if let form = viewer.formFieldProvider?(index, values) {
      return .form(form)
    }
    if let run = viewer.textRunProvider?(index, values) {
      return .textRun(run)
    }
    return nil
  }

  private func beginEditing(_ target: EditTarget, at point: NSPoint) {
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

    if case .form = target {
    } else {
      let run: PageTextTarget?
      if case .textRun(let text) = target { run = text } else { run = nil }
      guard
        let canvas = InlinePageTextCanvas(
          viewer: viewer, target: run,
          pageIndex: target.pageIndex, rect: pageRect, clickPoint: point)
      else {
        let alert = NSAlert()
        alert.messageText = "Inline Editing Unavailable"
        alert.informativeText =
          "Direct editing currently supports horizontal text with ordinary character spacing on unrotated pages. This block cannot be edited inline."
        alert.runModal()
        return
      }
      textCanvas = canvas
      canvas.frame = bounds
      canvas.onFinish = { [weak self, weak viewer] in
        self?.textCanvas = nil
        if let view = viewer?.view { self?.window?.makeFirstResponder(view) }
      }
      addSubview(canvas)
      canvas.focusText()
      return
    }

    let field = NSTextField(frame: localRect)
    field.identifier = NSUserInterfaceItemIdentifier(target.editorIdentifier)
    field.stringValue = target.value
    field.font = .systemFont(ofSize: max(9, min(28, localRect.height * 0.62)))
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

  @discardableResult
  func commitEditing() -> Bool {
    if let canvas = textCanvas { return canvas.commit() }
    guard !isCommitting, let editor, let target else { return true }
    isCommitting = true
    defer { isCommitting = false }
    let text = editor.currentEditor()?.string ?? editor.stringValue
    let accepted: Bool
    switch target {
    case .form(let form):
      accepted = viewer?.onFormFieldCommit?(form.fieldName, text) ?? false
    case .textRun(let run):
      accepted = viewer?.onTextRunCommit?(run.pageIndex, run.runIndex, text) ?? false
    case .newText(let pageIndex, let rect):
      if text.isEmpty {
        removeEditor()
        return true
      }
      accepted = viewer?.onAddPageText?(pageIndex, rect, text) ?? false
    }
    guard accepted else { return false }
    removeEditor()
    return true
  }

  func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
    commitEditing()
  }

  func synchronizeCanvas() { textCanvas?.synchronizeGeometry() }
  func editTextBlock(_ target: PageTextTarget) {
    guard let viewer, let page = viewer.view.document?.page(at: target.pageIndex),
      commitEditing()
    else { return }
    let rect = target.rect
    let point = viewer.view.convert(
      NSPoint(x: (rect[0] + rect[2]) / 2, y: (rect[1] + rect[3]) / 2), from: page)
    beginEditing(.textRun(target), at: convert(point, from: viewer.view))
  }
  func discardPendingEditing() {
    textCanvas?.cancel()
    if editor != nil { cancelEditing() }
  }
  override func scrollWheel(with event: NSEvent) { viewer?.scrollPage(with: event) }
  override func magnify(with event: NSEvent) { viewer?.view.magnify(with: event) }

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
