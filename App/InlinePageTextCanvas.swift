import AppKit
import Combine
import MacServices
import PDFEditing
import PDFKit

extension PDFViewingSession {
  func scrollPage(with event: NSEvent) {
    if let scroll = view.documentView?.enclosingScrollView {
      scroll.scrollWheel(with: event)
    } else {
      view.scrollWheel(with: event)
    }
  }
}

final class PendingPageTextState: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false
  var hasChanges: Bool {
    get { lock.withLock { changed } }
    set { lock.withLock { changed = newValue } }
  }
}

@MainActor
final class PageTextColorPanelController: NSObject {
  static let shared = PageTextColorPanelController()
  private weak var viewer: PDFViewingSession?
  func show(for viewer: PDFViewingSession) {
    self.viewer = viewer
    let rgb = viewer.pageTextStyle.color
    let panel = NSColorPanel.shared
    panel.color = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    panel.showsAlpha = false
    panel.isContinuous = true
    panel.setTarget(self)
    panel.setAction(#selector(colorChanged(_:)))
    panel.makeKeyAndOrderFront(nil)
  }
  @objc private func colorChanged(_ sender: NSColorPanel) {
    guard let viewer, let rgb = sender.color.usingColorSpace(.sRGB) else { return }
    viewer.pageTextStyle.color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
    viewer.pageTextStyleApplier?(viewer.pageTextStyle)
  }
}

/// Native page text, rather than a form control: no bezel, background or
/// scroll chrome. TextKit supplies the caret, selection, IME and typing undo.
@MainActor
final class InlinePageTextView: NSTextView {
  let typingUndo = UndoManager()
  var finish: (() -> Void)?
  var cancel: (() -> Void)?
  var acceptsLineBreaks = false
  var onScroll: ((NSEvent) -> Void)?
  var onMagnify: ((NSEvent) -> Void)?
  override var undoManager: UndoManager? { typingUndo }

  override func insertNewline(_ sender: Any?) {
    if acceptsLineBreaks { super.insertNewline(sender) } else { finish?() }
  }

  override func cancelOperation(_ sender: Any?) { cancel?() }
  override func scrollWheel(with event: NSEvent) { onScroll?(event) }
  override func magnify(with event: NSEvent) { onMagnify?(event) }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.contains(.command) {
      finish?()
      return
    }
    super.keyDown(with: event)
  }
}

@MainActor
final class TextMoveHandle: NSView {
  var onDrag: ((NSPoint, Bool) -> Void)?
  var onNudge: ((Double, Double) -> Void)?
  private var start = NSPoint.zero
  override var acceptsFirstResponder: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Move text")
    setAccessibilityHelp(
      "Drag to move this text block. Arrow keys move it by one point; Shift moves ten.")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func mouseDown(with event: NSEvent) {
    start = event.locationInWindow
    window?.makeFirstResponder(self)
    NSCursor.closedHand.push()
  }
  override func mouseDragged(with event: NSEvent) {
    onDrag?(
      NSPoint(x: event.locationInWindow.x - start.x, y: event.locationInWindow.y - start.y), false)
  }
  override func mouseUp(with event: NSEvent) {
    onDrag?(
      NSPoint(x: event.locationInWindow.x - start.x, y: event.locationInWindow.y - start.y), true)
    NSCursor.pop()
  }
  override func keyDown(with event: NSEvent) {
    let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
    switch event.keyCode {
    case 123: onNudge?(-step, 0)
    case 124: onNudge?(step, 0)
    case 125: onNudge?(0, -step)
    case 126: onNudge?(0, step)
    default: super.keyDown(with: event)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
    NSImage(
      systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?
      .draw(in: bounds.insetBy(dx: 4, dy: 4))
  }
}

@MainActor
final class TextWidthHandle: NSView {
  var onDrag: ((Double, Bool) -> Void)?
  private var start = 0.0
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Resize text width")
    setAccessibilityHelp("Drag horizontally to change paragraph wrapping.")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
  override func mouseDown(with event: NSEvent) { start = event.locationInWindow.x }
  override func mouseDragged(with event: NSEvent) {
    onDrag?(event.locationInWindow.x - start, false)
  }
  override func mouseUp(with event: NSEvent) {
    onDrag?(event.locationInWindow.x - start, true)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 2, yRadius: 2)
    box.fill()
    NSColor.controlAccentColor.setStroke()
    box.lineWidth = 1
    box.stroke()
  }
}

@MainActor
final class InlinePageTextCanvas: NSView, NSTextViewDelegate {
  weak var viewer: PDFViewingSession?
  let textView = InlinePageTextView(frame: .zero)
  let moveHandle = TextMoveHandle(frame: .zero)
  let widthHandle = TextWidthHandle(frame: .zero)
  let pageIndex: Int
  let sourceRect: CGRect
  let sourceTarget: PageTextTarget?
  private let originalDocument: PDFDocument
  private let font: NSFont
  private let originalStyle: PageTextStyle
  private let initialClickPoint: NSPoint
  private var style: PageTextStyle
  private var dx = 0.0
  private var dy = 0.0
  private var textWidth = 0.0
  private var resizeBase: Double?
  private var dragBase: (Double, Double)?
  private(set) var isDragging = false
  private var isFinishing = false
  private var isTyping = false
  private var bodyDragStart = NSPoint.zero
  private var isLayingOut = false
  private var observations = Set<AnyCancellable>()
  var onFinish: ((Bool) -> Void)?

  init?(
    viewer: PDFViewingSession, target: PageTextTarget?, pageIndex: Int, rect: CGRect,
    clickPoint: NSPoint
  ) {
    guard let document = viewer.view.document, let page = document.page(at: pageIndex),
      page.rotation % 360 == 0
    else { return nil }
    var preview: PDFDocument?
    if let target {
      guard let bytes = viewer.onTextBlockPreview?(target), let hidden = PDFDocument(data: bytes)
      else {
        return nil
      }
      preview = hidden
    }
    self.viewer = viewer
    self.pageIndex = pageIndex
    sourceRect = rect
    sourceTarget = target
    textWidth = rect.width
    initialClickPoint = clickPoint
    originalDocument = document
    let attributed = page.selection(for: rect)?.attributedString
    let attributes: [NSAttributedString.Key: Any] =
      (attributed?.length ?? 0) > 0
      ? attributed!.attributes(at: 0, effectiveRange: nil) : [:]
    let input = target?.style
    let pointSize = input?.fontSize ?? viewer.pageTextStyle.fontSize
    let family = input?.fontFamily ?? "Helvetica"
    font =
      (target == nil ? nil : attributes[.font] as? NSFont)
      ?? NSFont(name: family, size: pointSize) ?? .systemFont(ofSize: pointSize)
    style = PageTextStyle(
      fontFamily: family, fontSize: pointSize,
      color: input?.fillColor ?? viewer.pageTextStyle.color)
    originalStyle = style
    super.init(frame: viewer.view.bounds)
    autoresizingMask = [.width, .height]
    textView.identifier = .init(target == nil ? "spdf-new-text-editor" : "spdf-text-editor")
    textView.setAccessibilityLabel("Page text")
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isEditable = target == nil
    textView.isSelectable = target == nil
    isTyping = target == nil
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.acceptsLineBreaks = target == nil || target?.paragraph != nil
    textView.string = target?.text ?? ""
    textView.delegate = self
    textView.finish = { [weak self] in _ = self?.commit() }
    textView.cancel = { [weak self] in self?.cancel() }
    textView.onScroll = { [weak viewer] event in viewer?.scrollPage(with: event) }
    textView.onMagnify = { [weak viewer] event in viewer?.view.magnify(with: event) }
    addSubview(textView)
    addSubview(moveHandle)
    addSubview(widthHandle)
    widthHandle.isHidden = target?.paragraph == nil
    widthHandle.onDrag = { [weak self] delta, finished in
      guard let self, let viewer = self.viewer,
        let page = viewer.view.document?.page(at: self.pageIndex) else { return }
      if self.resizeBase == nil { self.resizeBase = self.textWidth }
      self.isDragging = !finished
      let zero = viewer.view.convert(NSPoint.zero, to: page)
      let mapped = viewer.view.convert(NSPoint(x: delta, y: 0), to: page)
      self.setTextWidth((self.resizeBase ?? self.textWidth) + mapped.x - zero.x)
      if finished { self.resizeBase = nil }
    }
    moveHandle.onDrag = { [weak self] delta, finished in
      self?.move(byWindowDelta: delta, finished: finished)
    }
    moveHandle.onNudge = { [weak self] x, y in
      guard let self else { return }
      self.dx += x
      self.dy += y
      self.synchronizeGeometry()
      self.publishPendingChange()
    }
    if let preview { swapRenderer(to: preview) }
    viewer.view.clearSelection()
    viewer.view.setAccessibilityHidden(true)
    viewer.pageTextStyle = style
    viewer.isEditingPageText = true
    viewer.isTypingPageText = isTyping
    viewer.pageTextBeginTyping = { [weak self] in self?.beginTyping() }
    viewer.pageTextCancel = { [weak self] in self?.cancel() }
    viewer.pageTextPositionApplier = { [weak self] x, y in
      guard let self else { return }
      self.dx = x - self.sourceRect.minX
      self.dy = y - self.sourceRect.minY
      self.synchronizeGeometry()
      self.publishPendingChange()
    }
    viewer.pageTextStyleApplier = { [weak self] style in self?.applyStyle(style) }
    viewer.pageTextWidthApplier = target?.paragraph == nil ? nil : { [weak self] width in
      self?.setTextWidth(width)
    }
    viewer.hasPendingTextGesture = { [weak self] in self?.isDragging ?? false }
    for name in [
      Notification.Name.NSUndoManagerDidUndoChange,
      .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
    ] {
      NotificationCenter.default.publisher(for: name, object: textView.typingUndo)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.viewer?.canUndoPageTyping = self.textView.typingUndo.canUndo
            self.viewer?.canRedoPageTyping = self.textView.typingUndo.canRedo
          }
        }.store(in: &observations)
    }
    for name in [
      Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged,
      NSView.boundsDidChangeNotification,
    ] {
      NotificationCenter.default.publisher(for: name, object: nil)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
          MainActor.assumeIsolated {
            guard let self, let viewer = self.viewer else { return }
            if let changed = notification.object as? NSView,
              changed === viewer.view || changed.isDescendant(of: viewer.view)
            {
              self.synchronizeGeometry()
            }
          }
        }.store(in: &observations)
    }
    synchronizeGeometry()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var acceptsFirstResponder: Bool { true }

  func focusText() {
    if isTyping { placeCaret(at: initialClickPoint) } else { window?.makeFirstResponder(self) }
  }

  func beginTyping(at point: NSPoint? = nil, selectWord: Bool = false) {
    isTyping = true
    textView.isEditable = true
    textView.isSelectable = true
    viewer?.isTypingPageText = true
    placeCaret(at: point ?? initialClickPoint)
    if selectWord { textView.selectWord(nil) }
    needsDisplay = true
  }

  private func placeCaret(at point: NSPoint) {
    window?.makeFirstResponder(textView)
    if let viewer {
      let local = textView.convert(point, from: viewer.view)
      let index = textView.characterIndexForInsertion(at: local)
      textView.setSelectedRange(
        NSRange(location: min(index, (textView.string as NSString).length), length: 0))
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if moveHandle.frame.contains(point) { return moveHandle }
    if !widthHandle.isHidden, widthHandle.frame.contains(point) { return widthHandle }
    if textView.frame.contains(point) { return isTyping ? textView : self }
    return nil
  }

  override func resetCursorRects() {
    if !isTyping { addCursorRect(textView.frame, cursor: .openHand) }
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2, let viewer {
      beginTyping(at: viewer.view.convert(event.locationInWindow, from: nil), selectWord: true)
      return
    }
    bodyDragStart = event.locationInWindow
    window?.makeFirstResponder(self)
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isTyping else { return }
    move(
      byWindowDelta: NSPoint(
        x: event.locationInWindow.x - bodyDragStart.x,
        y: event.locationInWindow.y - bodyDragStart.y), finished: false)
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    move(
      byWindowDelta: NSPoint(
        x: event.locationInWindow.x - bodyDragStart.x,
        y: event.locationInWindow.y - bodyDragStart.y), finished: true)
  }

  override func keyDown(with event: NSEvent) {
    let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
    switch event.keyCode {
    case 53: cancel()
    case 36:
      if event.modifierFlags.contains(.command) { _ = commit() } else { beginTyping() }
    case 51, 117:
      textView.string = ""
      _ = commit()
    case 123:
      dx -= step
      synchronizeGeometry()
      publishPendingChange()
    case 124:
      dx += step
      synchronizeGeometry()
      publishPendingChange()
    case 125:
      dy -= step
      synchronizeGeometry()
      publishPendingChange()
    case 126:
      dy += step
      synchronizeGeometry()
      publishPendingChange()
    default: super.keyDown(with: event)
    }
  }

  private func swapRenderer(to document: PDFDocument) {
    guard let viewer else { return }
    let scale = viewer.view.scaleFactor
    let automatic = viewer.view.autoScales
    let clip = viewer.view.documentView?.enclosingScrollView?.contentView
    let origin = clip?.bounds.origin
    viewer.view.document = document
    viewer.view.autoScales = false
    viewer.view.scaleFactor = scale
    viewer.view.layoutDocumentView()
    if let origin, let newClip = viewer.view.documentView?.enclosingScrollView?.contentView {
      newClip.scroll(to: origin)
      newClip.enclosingScrollView?.reflectScrolledClipView(newClip)
    }
    viewer.view.autoScales = automatic
  }

  func applyStyle(_ requested: PageTextStyle) {
    guard requested.fontSize.isFinite, (2...144).contains(requested.fontSize),
      requested.color.count == 3,
      requested.color.allSatisfy({ $0.isFinite && (0...1).contains($0) })
    else { return }
    style = requested
    synchronizeGeometry()
    publishPendingChange()
  }

  func setTextWidth(_ width: Double) {
    guard width.isFinite, (24...2_000).contains(width) else { return }
    textWidth = width
    synchronizeGeometry()
    publishPendingChange()
  }

  func synchronizeGeometry() {
    guard !isLayingOut, !isFinishing, let viewer,
      let page = viewer.view.document?.page(at: pageIndex)
    else { return }
    isLayingOut = true
    defer { isLayingOut = false }
    let base = viewer.view.convert(
      NSPoint(x: sourceRect.minX + dx, y: sourceRect.minY + dy), from: page)
    let unit = viewer.view.convert(
      NSPoint(x: sourceRect.minX + dx + 1, y: sourceRect.minY + dy), from: page)
    let scale = max(0.01, hypot(unit.x - base.x, unit.y - base.y))
    let scaled =
      NSFont(
        descriptor: font.fontDescriptor,
        size: font.pointSize * (style.fontSize / originalStyle.fontSize) * scale) ?? font
    let color = NSColor(
      srgbRed: style.color[0], green: style.color[1], blue: style.color[2], alpha: 1)
    let selected = textView.selectedRange()
    textView.font = scaled
    textView.textColor = color
    textView.insertionPointColor = color
    var attributes: [NSAttributedString.Key: Any] = [
      .font: scaled, .foregroundColor: color, .kern: 0, .ligature: 0,
    ]
    if sourceTarget == nil || sourceTarget?.paragraph != nil {
      let paragraph = NSMutableParagraphStyle()
      let spacing = sourceTarget?.paragraph?.lineSpacing ?? originalStyle.fontSize * 1.2
      paragraph.minimumLineHeight = spacing * style.fontSize / originalStyle.fontSize * scale
      paragraph.maximumLineHeight = paragraph.minimumLineHeight
      attributes[.paragraphStyle] = paragraph
      if !textView.string.isEmpty {
        textView.textStorage?.addAttribute(
          .paragraphStyle, value: paragraph,
          range: NSRange(location: 0, length: (textView.string as NSString).length))
      }
    }
    if sourceTarget?.paragraph != nil, !textView.string.isEmpty {
      textView.textStorage?.addAttributes(
        [.kern: 0, .ligature: 0],
        range: NSRange(location: 0, length: (textView.string as NSString).length))
    }
    textView.typingAttributes = attributes
    let manager = textView.layoutManager
    let height = max(16, manager?.defaultLineHeight(for: scaled) ?? scaled.pointSize * 1.2)
    var baselineOffset = manager?.defaultBaselineOffset(for: scaled) ?? scaled.ascender
    let originalBaseline: Double
    if let paragraph = sourceTarget?.paragraph {
      originalBaseline = paragraph.firstBaseline
    } else {
      originalBaseline = sourceTarget == nil
        ? sourceRect.maxY - style.fontSize * 0.8 : sourceRect.minY - font.descender
    }
    let baseline = viewer.view.convert(
      NSPoint(x: sourceRect.minX + dx, y: originalBaseline + dy), from: page)
    let availableWidth =
      sourceTarget == nil || sourceTarget?.paragraph != nil
      ? textWidth * scale
      : max(
        sourceRect.width * scale + 8,
        (textView.string as NSString).size(withAttributes: [.font: scaled]).width + 8)
    textView.textContainer?.containerSize = NSSize(width: availableWidth, height: 1_000_000)
    textView.textContainer?.widthTracksTextView = false
    if let container = textView.textContainer, let manager {
      manager.ensureLayout(for: container)
      if manager.numberOfGlyphs > 0 {
        baselineOffset =
          manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
          + manager.location(forGlyphAt: 0).y
      }
    }
    textView.frame = NSRect(
      x: baseline.x, y: baseline.y - (height - baselineOffset),
      width: max(24, availableWidth), height: height)
    if sourceTarget == nil || sourceTarget?.paragraph != nil, let container = textView.textContainer {
      manager?.ensureLayout(for: container)
      let used = manager?.usedRect(for: container).height ?? height
      textView.frame.size.height = max(height, used)
      textView.frame.origin.y = baseline.y + baselineOffset - textView.frame.height
    }
    textView.setSelectedRange(selected)
    moveHandle.frame = NSRect(
      x: textView.frame.minX - 20, y: textView.frame.maxY - 16, width: 16, height: 16)
    widthHandle.frame = NSRect(
      x: textView.frame.maxX - 6, y: textView.frame.midY - 9, width: 12, height: 18)
    let position = [sourceRect.minX + dx, sourceRect.minY + dy]
    if viewer.pageTextPosition != position { viewer.pageTextPosition = position }
    if viewer.pageTextWidth != textWidth { viewer.pageTextWidth = textWidth }
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
  }

  func textDidChange(_ notification: Notification) {
    synchronizeGeometry()
    publishPendingChange()
  }

  private func publishPendingChange() {
    let changed =
      textView.string != (sourceTarget?.text ?? "")
      || style != originalStyle || dx != 0 || dy != 0
      || abs(textWidth - sourceRect.width) > 0.01
    viewer?.hasPendingPageTextChanges = changed
    viewer?.onPendingPageTextChange?(changed)
  }

  func move(byWindowDelta delta: NSPoint, finished: Bool) {
    guard let viewer, let page = viewer.view.document?.page(at: pageIndex) else { return }
    if dragBase == nil { dragBase = (dx, dy) }
    isDragging = !finished
    let zero = viewer.view.convert(NSPoint.zero, to: page)
    let mapped = viewer.view.convert(delta, to: page)
    dx = (dragBase?.0 ?? 0) + mapped.x - zero.x
    dy = (dragBase?.1 ?? 0) + mapped.y - zero.y
    synchronizeGeometry()
    publishPendingChange()
    if finished { dragBase = nil }
  }

  @discardableResult
  func commit() -> Bool {
    guard !isFinishing else { return true }
    guard !isDragging, !textView.hasMarkedText(), let viewer else { return false }
    isFinishing = true
    swapRenderer(to: originalDocument)
    let accepted: Bool
    if let target = sourceTarget {
      accepted = viewer.onTextBlockCommit?(
        target, textView.string, style, dx, dy, target.paragraph == nil ? nil : pageLines()) ?? false
    } else if textView.string.isEmpty {
      accepted = true
    } else {
      let rect = sourceRect.offsetBy(dx: dx, dy: dy)
      accepted =
        viewer.onNewTextBlockCommit?(
          pageIndex, [rect.minX, rect.minY, rect.maxX, rect.maxY], textView.string, style) ?? false
    }
    if accepted {
      retire(committed: true)
    } else {
      isFinishing = false
      if let target = sourceTarget, let data = viewer.onTextBlockPreview?(target),
        let hidden = PDFDocument(data: data)
      {
        swapRenderer(to: hidden)
      }
      focusText()
    }
    return accepted
  }

  func cancel() {
    guard !isFinishing else { return }
    isFinishing = true
    swapRenderer(to: originalDocument)
    retire(committed: false)
  }

  private func retire(committed: Bool) {
    observations.removeAll()
    viewer?.onPendingPageTextChange?(false)
    viewer?.view.setAccessibilityHidden(false)
    viewer?.isEditingPageText = false
    viewer?.isTypingPageText = false
    viewer?.hasPendingPageTextChanges = false
    viewer?.canUndoPageTyping = false
    viewer?.canRedoPageTyping = false
    viewer?.pageTextBeginTyping = nil
    viewer?.pageTextCancel = nil
    viewer?.pageTextPositionApplier = nil
    viewer?.pageTextStyleApplier = nil
    viewer?.pageTextWidthApplier = nil
    viewer?.hasPendingTextGesture = nil
    textView.delegate = nil
    onFinish?(committed)
    removeFromSuperview()
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
    var box = textView.frame
    if sourceTarget?.paragraph == nil, let container = textView.textContainer, let manager = textView.layoutManager {
      box.size.width = max(18, min(box.width, manager.usedRect(for: container).width + 4))
    }
    let outline = NSBezierPath(rect: box.insetBy(dx: -3, dy: -3))
    outline.lineWidth = 0.75
    outline.stroke()
  }

  /// Read the actual TextKit line fragments/caret geometry in page space.
  /// Saving must use these exact baselines, widths and soft-wrap boundaries.
  func pageLines() -> [PageTextLine] {
    guard let viewer, let page = viewer.view.document?.page(at: pageIndex),
      let manager = textView.layoutManager, let container = textView.textContainer else { return [] }
    manager.ensureLayout(for: container)
    let text = textView.string as NSString
    var lines: [PageTextLine] = []
    manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
      [self] rect, _, _, glyphs, _ in
      let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      let value = text.substring(with: range).trimmingCharacters(in: .newlines)
      let location = manager.location(forGlyphAt: glyphs.location)
      let native = textView.convert(
        NSPoint(x: rect.minX + location.x, y: rect.minY + location.y), to: viewer.view)
      let point = viewer.view.convert(native, to: page)
      lines.append(PageTextLine(text: value, x: point.x, baseline: point.y))
    }
    return lines
  }

  override func scrollWheel(with event: NSEvent) { viewer?.scrollPage(with: event) }
  override func magnify(with event: NSEvent) { viewer?.view.magnify(with: event) }
}
