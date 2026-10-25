import AppKit
import Combine
import MacServices
import PDFEditing
import PDFKit

extension PDFViewingSession {
  func scrollPage(with event: NSEvent) {
    if handleCommandScroll(event) { return }
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
    panel.color = NSColor(
      srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: viewer.pageTextStyle.opacity)
    panel.showsAlpha = false
    panel.isContinuous = true
    panel.setTarget(self)
    panel.setAction(#selector(colorChanged(_:)))
    panel.makeKeyAndOrderFront(nil)
  }
  @objc private func colorChanged(_ sender: NSColorPanel) {
    guard let viewer, let rgb = sender.color.usingColorSpace(.sRGB) else { return }
    let color: [Double] = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
    if let apply = viewer.pageTextFormattingApplier { apply(.color(color)) }
    else { viewer.pageTextStyle.color = color; viewer.pageTextStyleApplier?(viewer.pageTextStyle) }
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
  var toggleBold: (() -> Void)?
  var toggleItalic: (() -> Void)?
  /// Return true when the canvas inserted attributed text to preserve source
  /// character spacing or use another verified font from the paragraph.
  var insertWithSourceFallback: ((Any, NSRange) -> Bool)?
  override var undoManager: UndoManager? { typingUndo }
  override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    if insertWithSourceFallback?(string, replacementRange) == true { return }
    super.insertText(string, replacementRange: replacementRange)
  }

  override func insertNewline(_ sender: Any?) {
    if acceptsLineBreaks { super.insertNewline(sender) } else { finish?() }
  }

  override func cancelOperation(_ sender: Any?) { cancel?() }
  override func scrollWheel(with event: NSEvent) { onScroll?(event) }
  override func magnify(with event: NSEvent) { onMagnify?(event) }

  static func formattingKey(_ event: NSEvent) -> String? {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
      return nil
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "b": return "b"
    // Turkish input sources can report dotless ı or dotted capital İ for
    // the same command. Keep the text command usable in those layouts.
    case "i", "ı", "i\u{0307}": return "i"
    default: return nil
    }
  }

  private func performFormattingKey(_ event: NSEvent) -> Bool {
    let action = Self.formattingKey(event) == "b" ? toggleBold
      : Self.formattingKey(event) == "i" ? toggleItalic : nil
    guard let action else { return false }
    action()
    return true
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    performFormattingKey(event) || super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if performFormattingKey(event) { return }
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
  private let originalParagraphStyle: PageTextParagraphStyle
  private let initialBaseline: Double
  private(set) var formatting: NativeTextFormatting?
  private var wrapsText = true
  private let initialClickPoint: NSPoint
  private var style: PageTextStyle
  private var dx = 0.0
  private var dy = 0.0
  private var textWidth = 0.0
  private var resizeBase: Double?
  private var dragBase: (Double, Double)?
  private(set) var isDragging = false
  private var isFinishing = false
  private var clippingLayoutIssue: String?
  private lazy var clippingFonts = NativeParagraphEditing.fonts(profiles: sourceTarget?.paragraph?.fontProfiles ?? [:])
  private var isTyping = false
  private var bodyDragStart = NSPoint.zero
  private var isLayingOut = false
  private var isApplyingOverflowCorrection = false
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
    wrapsText = target?.paragraph?.wraps ?? (target == nil)
    textWidth = rect.width
    initialClickPoint = clickPoint
    originalDocument = document
    let attributed = page.selection(for: rect)?.attributedString
    let attributes: [NSAttributedString.Key: Any] =
      (attributed?.length ?? 0) > 0
      ? attributed!.attributes(at: 0, effectiveRange: nil) : [:]
    let input = target?.style
    let pointSize = input?.fontSize ?? viewer.pageTextStyle.fontSize
    let requestedFamily = input?.fontFamily ?? viewer.pageTextStyle.fontFamily
    let licensedFonts = ProvisionedFontStore.availableFonts(
      in: SPDFDocument.fontsInstallDirectoryOverride)
    let newTextDefaults = NativeTextFormatting.defaultsForNewText(
      requestedFamily: requestedFamily, size: pointSize,
      color: input?.fillColor ?? viewer.pageTextStyle.color,
      opacity: input?.opacity ?? viewer.pageTextStyle.opacity,
      licensedFonts: licensedFonts)
    let family = target == nil ? newTextDefaults.familyName : requestedFamily
    let resolvedFont =
      (target == nil ? nil : attributes[.font] as? NSFont)
      ?? NSFont(name: family, size: pointSize) ?? .systemFont(ofSize: pointSize)
    font = resolvedFont
    initialBaseline = target?.paragraph?.firstBaseline ?? (target == nil
      ? rect.maxY - pointSize * 0.8 : rect.minY - resolvedFont.descender)
    style = PageTextStyle(
      fontFamily: family, fontSize: pointSize,
      color: input?.fillColor ?? viewer.pageTextStyle.color,
      opacity: input?.opacity ?? viewer.pageTextStyle.opacity)
    originalStyle = style
    let initialParagraphStyle = PageTextParagraphStyle()
    originalParagraphStyle = initialParagraphStyle
    super.init(frame: viewer.view.bounds)
    autoresizingMask = [.width, .height]
    textView.identifier = .init(target == nil ? "spdf-new-text-editor" : "spdf-text-editor")
    textView.setAccessibilityLabel("Page text")
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    // The PDF page remains white in either system appearance. Keep its native
    // selection readable when a dark inspector takes keyboard focus.
    textView.appearance = NSAppearance(named: .aqua)
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
    textView.acceptsLineBreaks = wrapsText
    textView.string = target?.text ?? ""
    let initialFormat = target?.paragraph?.fragments.first?.format ?? newTextDefaults.format
    if target == nil || target?.paragraph != nil {
      formatting = NativeTextFormatting(view: textView,
        fragments: target?.paragraph?.fragments ?? [], initial: initialFormat,
        profiles: target?.paragraph?.fontProfiles ?? [:],
        licensedFonts: licensedFonts)
      formatting?.onChange = { [weak self] in self?.formattingChanged() }
      textView.toggleBold = { [weak self] in self?.toggleFormat(italic: false) }
      textView.toggleItalic = { [weak self] in self?.toggleFormat(italic: true) }
    }
    textView.delegate = self
    textView.finish = { [weak self] in _ = self?.commit() }
    textView.cancel = { [weak self] in self?.cancel() }
    textView.onScroll = { [weak viewer] event in viewer?.scrollPage(with: event) }
    textView.onMagnify = { [weak viewer] event in viewer?.view.magnify(with: event) }
    textView.insertWithSourceFallback = { [weak self, weak textView] value, range in
      guard let self, let textView, let formatting = self.formatting,
        !textView.hasMarkedText(), !(value is NSAttributedString) else { return false }
      guard let text = value as? String else { return false }
      let plan = formatting.insertionPlan(text, replacing: range)
      if let issue = plan.issue {
        self.viewer?.pageTextFormattingIssue = issue
        NSSound.beep()
        return true
      }
      guard let attributed = plan.attributedText else { return false }
      textView.insertText(attributed, replacementRange: range)
      return true
    }
    addSubview(textView)
    addSubview(moveHandle)
    addSubview(widthHandle)
    widthHandle.isHidden = formatting == nil
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
    viewer.pageTextParagraphStyle = originalParagraphStyle
    viewer.pageTextParagraphStyleApplier = { [weak self] paragraph in
      self?.applyParagraphStyle(paragraph)
    }
    viewer.canFormatPageText = formatting != nil
    viewer.pageTextFormattingIssue = nil
    viewer.pageTextFormattingApplier = formatting == nil ? nil : { [weak self] change in
      guard let self else { return }
      self.viewer?.pageTextFormattingIssue = self.formatting?.apply(change, isTyping: self.isTyping)
      self.updateClippingIssue()
    }
    viewer.pageTextFitOverflow = formatting == nil ? nil : { [weak self] in
      self?.fitOverflowText() ?? false
    }
    viewer.pageTextWidenOverflowBox = formatting == nil ? nil : { [weak self] in
      self?.widenOverflowBox() ?? false
    }
    viewer.pageTextMoveOverflowInside = sourceTarget?.paragraph?.clippingRect == nil ? nil : {
      [weak self] in self?.moveOverflowInsideBoundary() ?? false
    }
    viewer.isEditingPageText = true
    viewer.isTypingPageText = isTyping
    viewer.pageTextBeginTyping = { [weak self] in self?.beginTyping() }
    viewer.pageTextCancel = { [weak self] in self?.cancel() }
    viewer.pageTextUndo = { [weak self] in
      guard let self, self.textView.typingUndo.canUndo else { return false }
      self.textView.typingUndo.undo()
      return true
    }
    viewer.pageTextRedo = { [weak self] in
      guard let self, self.textView.typingUndo.canRedo else { return false }
      self.textView.typingUndo.redo()
      return true
    }
    viewer.pageTextPositionApplier = { [weak self] x, y in
      guard let self else { return }
      self.dx = x - self.sourceRect.minX
      self.dy = y - self.sourceRect.minY
      self.synchronizeGeometry()
      self.publishPendingChange()
    }
    viewer.pageTextAlignmentApplier = { [weak self] alignment in
      guard let self, let viewer = self.viewer,
        let page = viewer.view.document?.page(at: self.pageIndex),
        let container = self.textView.textContainer, let manager = self.textView.layoutManager else { return }
      manager.ensureLayout(for: container)
      let used = manager.usedRect(for: container).offsetBy(
        dx: self.textView.textContainerOrigin.x, dy: self.textView.textContainerOrigin.y)
      let native = self.textView.convert(used, to: viewer.view)
      var bounds = viewer.view.convert(native, to: page)
      bounds.origin.x = self.sourceRect.minX + self.dx
      bounds.size.width = self.pageBox().width
      let delta = alignment.delta(for: bounds, in: page.bounds(for: viewer.view.displayBox))
      self.dx += delta.x; self.dy += delta.y
      self.synchronizeGeometry()
      self.publishPendingChange()
    }
    viewer.pageTextStyleApplier = { [weak self] style in self?.applyStyle(style) }
    viewer.pageTextWidthApplier = formatting == nil ? nil : { [weak self] width in
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
    updateClippingIssue()
    publishFormattingSelection()
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
    publishFormattingSelection()
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
    if formatting != nil, let key = InlinePageTextView.formattingKey(event) {
      toggleFormat(italic: key == "i")
      return
    }
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

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if formatting != nil, let key = InlinePageTextView.formattingKey(event) {
      toggleFormat(italic: key == "i")
      return true
    }
    return super.performKeyEquivalent(with: event)
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
    clearNonClippingOverflow()
    guard requested.fontSize.isFinite, (2...144).contains(requested.fontSize),
      requested.color.count == 3,
      requested.color.allSatisfy({ $0.isFinite && (0...1).contains($0) })
    else { return }
    if let formatting {
      if let face = StandardTextFont(rawValue: requested.fontFamily), requested.fontFamily != style.fontFamily {
        _ = formatting.apply(.family(face.family), isTyping: isTyping)
        _ = formatting.apply(.bold(face.isBold), isTyping: isTyping)
        _ = formatting.apply(.italic(face.isItalic), isTyping: isTyping)
      }
      if requested.fontSize != style.fontSize { _ = formatting.apply(.size(requested.fontSize), isTyping: isTyping) }
      if requested.color != style.color { _ = formatting.apply(.color(requested.color), isTyping: isTyping) }
      return
    }
    style = requested
    synchronizeGeometry()
    publishPendingChange()
  }

  func setTextWidth(_ width: Double) {
    clearNonClippingOverflow()
    guard width.isFinite, (24...2_000).contains(width) else { return }
    wrapsText = true
    textView.acceptsLineBreaks = true
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
      srgbRed: style.color[0], green: style.color[1], blue: style.color[2],
      alpha: style.opacity)
    let selected = textView.selectedRange()
    if let formatting {
      formatting.render(scale: scale,
        minimumLineSpacing: sourceTarget?.paragraph?.lineSpacing ?? originalStyle.fontSize * 1.2)
    } else {
      textView.font = scaled
      textView.textColor = color
      textView.insertionPointColor = color
    }
    var attributes: [NSAttributedString.Key: Any] = [
      .font: scaled, .foregroundColor: color, .kern: 0, .ligature: 0,
    ]
    var maximumFontPointSize = scaled.pointSize
    if let storage = textView.textStorage {
      storage.enumerateAttribute(
        .font, in: NSRange(location: 0, length: storage.length)
      ) { value, _, _ in
        if let value = value as? NSFont {
          maximumFontPointSize = max(maximumFontPointSize, value.pointSize)
        }
      }
    }
    if viewer.pageTextParagraphStyle != originalParagraphStyle {
      let paragraphStyle = viewer.pageTextParagraphStyle.textKitStyle(
        scale: scale * style.fontSize / originalStyle.fontSize,
        fallbackLeading: sourceTarget?.paragraph?.lineSpacing ?? originalStyle.fontSize * 1.2,
        maximumLineHeight: maximumFontPointSize)
      attributes[.paragraphStyle] = paragraphStyle
      textView.defaultParagraphStyle = paragraphStyle
      if !textView.string.isEmpty {
        textView.textStorage?.addAttributes(
          [
            .paragraphStyle: paragraphStyle,
            .kern: formatting == nil ? 0 : attributes[.kern] ?? 0,
            .ligature: formatting == nil ? 0 : attributes[.ligature] ?? 0,
          ],
          range: NSRange(location: 0, length: (textView.string as NSString).length))
      }
      if formatting == nil { textView.typingAttributes = attributes }
    } else if formatting == nil,
      sourceTarget == nil || sourceTarget?.paragraph != nil
    {
      let paragraph = NSMutableParagraphStyle()
      let spacing = sourceTarget?.paragraph?.lineSpacing ?? originalStyle.fontSize * 1.2
      paragraph.minimumLineHeight = spacing * style.fontSize / originalStyle.fontSize * scale
      paragraph.maximumLineHeight = max(paragraph.minimumLineHeight, maximumFontPointSize)
      attributes[.paragraphStyle] = paragraph
      if !textView.string.isEmpty {
        textView.textStorage?.addAttribute(
          .paragraphStyle, value: paragraph,
          range: NSRange(location: 0, length: (textView.string as NSString).length))
      }
      textView.typingAttributes = attributes
    }
    let manager = textView.layoutManager
    let height = max(16, manager?.defaultLineHeight(for: scaled) ?? scaled.pointSize * 1.2)
    var baselineOffset = manager?.defaultBaselineOffset(for: scaled) ?? scaled.ascender
    let baseline = viewer.view.convert(
      NSPoint(x: sourceRect.minX + dx, y: initialBaseline + dy), from: page)
    let availableWidth =
      wrapsText
      ? textWidth * scale
      : max(
        textWidth * scale + 8,
        (formatting == nil ? (textView.string as NSString).size(withAttributes: [.font: scaled]).width
          : textView.attributedString().size().width) + 8)
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
    if sourceTarget == nil || formatting != nil, let container = textView.textContainer {
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

  private func applyParagraphStyle(_ paragraph: PageTextParagraphStyle) {
    clearNonClippingOverflow()
    guard paragraph.isValid, let viewer else { return }
    viewer.pageTextParagraphStyle = paragraph
    synchronizeGeometry()
    publishPendingChange()
  }

  func textDidChange(_ notification: Notification) {
    clearNonClippingOverflow()
    synchronizeGeometry()
    publishPendingChange()
    publishFormattingSelection()
  }

  func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?) -> Bool {
    guard let replacementString, let formatting else { return true }
    let issue = formatting.insertionIssue(replacementString)
    viewer?.pageTextFormattingIssue = issue
    if issue != nil { NSSound.beep() }
    return issue == nil
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard !isLayingOut else { return }
    publishFormattingSelection()
  }

  private func formattingChanged() {
    clearNonClippingOverflow()
    synchronizeGeometry()
    publishPendingChange()
    publishFormattingSelection()
  }

  private func toggleFormat(italic: Bool) {
    guard let formatting else { return }
    let selection = formatting.selection(isTyping: isTyping)
    let enabled = selection.mixed.contains(italic ? "italic" : "bold")
      || !(italic ? selection.format.font.isItalic : selection.format.font.isBold)
    viewer?.pageTextFormattingIssue = formatting.apply(
      italic ? .italic(enabled) : .bold(enabled), isTyping: isTyping)
    updateClippingIssue()
  }

  private func publishFormattingSelection() {
    guard let selection = formatting?.selection(isTyping: isTyping), let viewer else { return }
    style = PageTextStyle(fontFamily: selection.format.fontName,
      fontSize: selection.format.size, color: selection.format.color,
      opacity: selection.format.opacity)
    if viewer.pageTextStyle != style { viewer.pageTextStyle = style }
    if viewer.pageTextMixedFormatting != selection.mixed { viewer.pageTextMixedFormatting = selection.mixed }
    let availableFonts = formatting?.availableSourceFonts(isTyping: isTyping) ?? []
    if viewer.pageTextAvailableSourceFonts != availableFonts {
      viewer.pageTextAvailableSourceFonts = availableFonts
    }
    let availableLicensedFonts = formatting?.availableLicensedFonts(isTyping: isTyping) ?? []
    if viewer.pageTextAvailableLicensedFonts != availableLicensedFonts {
      viewer.pageTextAvailableLicensedFonts = availableLicensedFonts
    }
    if viewer.pageTextSelectionScope != selection.scope { viewer.pageTextSelectionScope = selection.scope }
    viewer.canChangePageTextTraits = !selection.usesSourceFont
  }

  /// TXT-06: scale every run down until the draft fits the clip or clears a
  /// collision. The text, mixed fonts and all characters stay in place.
  @discardableResult
  func fitOverflowText() -> Bool {
    guard let formatting, let viewer else { return false }
    guard viewer.pageTextOverflow?.canFitText != false else { return false }
    updateClippingIssue()
    let collision = viewer.pageTextOverflow?.cause == .collision
    isApplyingOverflowCorrection = true
    defer { isApplyingOverflowCorrection = false }
    var changed = false
    for _ in 0..<32 {
      let clipped = clippingLayoutIssue != nil
      let collisionIssue = collision ? currentDraftIssue() : nil
      if !clipped, collisionIssue == nil {
        if changed || viewer.pageTextOverflow != nil {
          viewer.pageTextOverflow = nil
          viewer.pageTextFormattingIssue = nil
          publishPendingChange()
        }
        return changed
      }
      let sizes = formatting.fragments().map(\.format.size)
      guard let largest = sizes.max(), largest > 2.01 else { break }
      let factor = max(0.9, 2.0 / largest)
      guard formatting.scaleFontSizes(by: factor) == nil else { return false }
      changed = true
      synchronizeGeometry()
      updateClippingIssue()
    }
    if clippingLayoutIssue == nil, !collision || currentDraftIssue() == nil {
      viewer.pageTextOverflow = nil
      viewer.pageTextFormattingIssue = nil
      publishPendingChange()
      return changed
    }
    viewer.pageTextFormattingIssue =
      "Text still does not fit at the minimum supported size. Widen the box or move it."
    publishPendingChange()
    return false
  }

  /// TXT-06: grow the authored wrapping width. A source clip is a hard ceiling,
  /// so this can never move ink outside the highlighted boundary.
  @discardableResult
  func widenOverflowBox() -> Bool {
    guard wrapsText, let viewer else { return false }
    let clip = sourceTarget?.paragraph?.clippingRect
    let baseX = sourceRect.minX + dx
    let maximum: Double
    if let clip, clip.count == 4, clip.allSatisfy(\.isFinite), clip[2] > clip[0] {
      maximum = min(2_000, max(24, clip[2] - baseX))
    } else {
      maximum = 2_000
    }
    let step = max(18, min(120, textWidth * 0.18))
    let next = min(maximum, textWidth + step)
    guard next > textWidth + 0.01 else {
      viewer.pageTextFormattingIssue =
        "There is no room to widen inside the boundary. Fit the text or move it inside."
      publishPendingChange()
      return false
    }
    let priorCause = viewer.pageTextOverflow?.cause
    isApplyingOverflowCorrection = true
    setTextWidth(next)
    isApplyingOverflowCorrection = false
    if clippingLayoutIssue == nil, priorCause == .collision {
      refreshCollisionOverflow()
    }
    if clippingLayoutIssue == nil, viewer.pageTextOverflow?.cause == .clipping {
      viewer.pageTextOverflow = nil
      viewer.pageTextFormattingIssue = nil
    }
    return true
  }

  /// TXT-06: shift a clipped draft back inside its source clip rectangle. This
  /// is deliberately a whole-box correction; it cannot shrink a box that is
  /// wider/taller than the clip, which Fit text handles instead.
  @discardableResult
  func moveOverflowInsideBoundary() -> Bool {
    guard let viewer, let clip = sourceTarget?.paragraph?.clippingRect,
      clip.count == 4, clip.allSatisfy(\.isFinite), clip[2] > clip[0], clip[3] > clip[1],
      let page = viewer.view.document?.page(at: pageIndex)
    else { return false }
    // The authored source box is the safe fallback for an editor that was
    // moved outside its clip: restoring it is an exact, text-preserving move.
    if sourceRect.minX >= clip[0] - 0.01, sourceRect.maxX <= clip[2] + 0.01,
      sourceRect.minY >= clip[1] - 0.01, sourceRect.maxY <= clip[3] + 0.01
    {
      isApplyingOverflowCorrection = true
      dx = 0
      dy = 0
      synchronizeGeometry()
      isApplyingOverflowCorrection = false
      publishPendingChange()
      if clippingLayoutIssue == nil { return true }
    }
    let frame = textView.frame
    func pagePoint(_ point: NSPoint) -> NSPoint {
      viewer.view.convert(convert(point, to: viewer.view), to: page)
    }
    let corners = [
      pagePoint(NSPoint(x: frame.minX, y: frame.minY)),
      pagePoint(NSPoint(x: frame.maxX, y: frame.minY)),
      pagePoint(NSPoint(x: frame.minX, y: frame.maxY)),
      pagePoint(NSPoint(x: frame.maxX, y: frame.maxY)),
    ]
    let minX = Double(corners.map(\.x).min() ?? CGFloat(clip[0]))
    let maxX = Double(corners.map(\.x).max() ?? CGFloat(clip[2]))
    let minY = Double(corners.map(\.y).min() ?? CGFloat(clip[1]))
    let maxY = Double(corners.map(\.y).max() ?? CGFloat(clip[3]))
    var shiftX = 0.0
    var shiftY = 0.0
    if minX < clip[0] { shiftX = clip[0] - minX }
    else if maxX > clip[2] { shiftX = clip[2] - maxX }
    if minY < clip[1] { shiftY = clip[1] - minY }
    else if maxY > clip[3] { shiftY = clip[3] - maxY }
    guard abs(shiftX) + abs(shiftY) > 0.01 else {
      viewer.pageTextFormattingIssue =
        "The box is already inside the boundary or is larger than it. Fit the text instead."
      publishPendingChange()
      return false
    }
    let priorCause = viewer.pageTextOverflow?.cause
    isApplyingOverflowCorrection = true
    dx += shiftX
    dy += shiftY
    synchronizeGeometry()
    isApplyingOverflowCorrection = false
    publishPendingChange()
    if clippingLayoutIssue == nil, priorCause == .collision {
      refreshCollisionOverflow()
    }
    return true
  }

  private func currentDraftIssue() -> String? {
    guard let viewer, let target = sourceTarget, target.paragraph != nil else { return nil }
    return viewer.pageTextDraftIssue?(target, pageLines(), pageBox(), style)
  }

  /// Recheck a collision after a width or position correction. Clipping is
  /// already refreshed by `updateClippingIssue`; this keeps the correction
  /// card and its actions visible while the draft still overlaps.
  private func refreshCollisionOverflow() {
    guard let viewer, let issue = currentDraftIssue() else {
      viewer?.pageTextOverflow = nil
      viewer?.pageTextFormattingIssue = nil
      return
    }
    viewer.pageTextOverflow = PageTextOverflowCorrection(
      cause: .collision, message: issue, canFitText: true,
      canWidenBox: true, canMoveInsideBoundary: false)
    viewer.pageTextFormattingIssue = issue
  }

  /// A new edit makes a collision/tagged message stale. Clipping is
  /// recalculated by `updateClippingIssue` after every layout change.
  private func clearNonClippingOverflow() {
    guard !isApplyingOverflowCorrection else { return }
    guard let viewer, let overflow = viewer.pageTextOverflow,
      overflow.cause != .clipping else { return }
    viewer.pageTextOverflow = nil
    if viewer.pageTextFormattingIssue == overflow.message {
      viewer.pageTextFormattingIssue = nil
    }
  }

  private func updateClippingIssue() {
    guard let viewer else { return }
    guard let paragraph = sourceTarget?.paragraph, let clippingRect = paragraph.clippingRect else {
      clippingLayoutIssue = nil
      if viewer.pageTextOverflow?.cause == .clipping {
        viewer.pageTextOverflow = nil
        viewer.pageTextFormattingIssue = nil
      }
      needsDisplay = true
      return
    }
    let prior = clippingLayoutIssue
    clippingLayoutIssue = NativeParagraphEditing.clippingIssue(lines: pageLines(),
      clippingRect: clippingRect, profiles: paragraph.fontProfiles, nativeFonts: clippingFonts)
    if let issue = clippingLayoutIssue {
      viewer.pageTextFormattingIssue = issue
      viewer.pageTextOverflow = PageTextOverflowCorrection(
        cause: .clipping, message: issue, canFitText: true, canWidenBox: true,
        canMoveInsideBoundary: clippingRect.count == 4
          && clippingRect[2] > clippingRect[0] && clippingRect[3] > clippingRect[1])
    } else if viewer.pageTextOverflow?.cause == .clipping {
      viewer.pageTextOverflow = nil
      if viewer.pageTextFormattingIssue == prior { viewer.pageTextFormattingIssue = nil }
    }
    needsDisplay = true
  }

  private func publishPendingChange() {
    updateClippingIssue()
    let changed =
      (formatting?.hasChanges ?? (textView.string != (sourceTarget?.text ?? "") || style != originalStyle))
      || dx != 0 || dy != 0
      || abs(textWidth - sourceRect.width) > 0.01
      || (viewer?.pageTextParagraphStyle ?? originalParagraphStyle) != originalParagraphStyle
    viewer?.hasPendingPageTextChanges = changed
    viewer?.onPendingPageTextChange?(changed)
  }

  func move(byWindowDelta delta: NSPoint, finished: Bool) {
    clearNonClippingOverflow()
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
    updateClippingIssue()
    guard clippingLayoutIssue == nil else { NSSound.beep(); return false }
    isFinishing = true
    swapRenderer(to: originalDocument)
    let accepted: Bool
    if let target = sourceTarget {
      accepted = viewer.onTextBlockCommit?(
        target, textView.string, style, dx, dy,
        formatting == nil ? nil : pageLines(), formatting == nil ? nil : pageBox()) ?? false
    } else if textView.string.isEmpty {
      accepted = true
    } else {
      let rect = sourceRect.offsetBy(dx: dx, dy: dy)
      accepted =
        viewer.onNewTextBlockCommit?(
          pageIndex, [rect.minX, rect.minY, rect.maxX, rect.maxY], textView.string, style,
          pageLines(), pageBox()) ?? false
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
      needsDisplay = true
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
    viewer?.pageTextUndo = nil
    viewer?.pageTextRedo = nil
    viewer?.pageTextPositionApplier = nil
    viewer?.pageTextAlignmentApplier = nil
    viewer?.pageTextParagraphStyleApplier = nil
    viewer?.pageTextStyleApplier = nil
    viewer?.pageTextWidthApplier = nil
    viewer?.pageTextFormattingApplier = nil
    viewer?.pageTextFitOverflow = nil
    viewer?.pageTextWidenOverflowBox = nil
    viewer?.pageTextMoveOverflowInside = nil
    viewer?.pageTextOverflow = nil
    viewer?.pageTextMixedFormatting = []
    viewer?.pageTextAvailableSourceFonts = []
    viewer?.pageTextAvailableLicensedFonts = []
    viewer?.pageTextFormattingIssue = nil
    viewer?.canFormatPageText = false
    viewer?.canChangePageTextTraits = true
    viewer?.hasPendingTextGesture = nil
    textView.delegate = nil
    onFinish?(committed)
    removeFromSuperview()
  }

  override func draw(_ dirtyRect: NSRect) {
    if let rect = sourceTarget?.paragraph?.clippingRect, let viewer,
      let page = viewer.view.document?.page(at: pageIndex) {
      let area = viewer.view.convert(NSRect(x: rect[0], y: rect[1], width: rect[2] - rect[0],
        height: rect[3] - rect[1]), from: page)
      let boundary = NSBezierPath(rect: convert(area, from: viewer.view))
      ((clippingLayoutIssue != nil || viewer.pageTextOverflow != nil)
        ? NSColor.systemRed : NSColor.controlAccentColor).setStroke()
      boundary.lineWidth = 1
      boundary.setLineDash([4, 3], count: 2, phase: 0)
      boundary.stroke()
    }
    (viewer?.pageTextOverflow != nil
      ? NSColor.systemRed : NSColor.controlAccentColor.withAlphaComponent(0.6)).setStroke()
    var box = textView.frame
    if !wrapsText, let container = textView.textContainer, let manager = textView.layoutManager {
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
      let rawLine = text.substring(with: range)
      let hard = rawLine.hasSuffix("\n") || rawLine.hasSuffix("\r")
      let contentRange = NativeParagraphEditing.lineContentRange(
        range, in: text, hasHardBreak: hard)
      let value = text.substring(with: contentRange)
      let location = manager.location(forGlyphAt: glyphs.location)
      let native = textView.convert(
        NSPoint(x: rect.minX + location.x, y: rect.minY + location.y), to: viewer.view)
      let point = viewer.view.convert(native, to: page)
      var segments: [PageTextSegment] = []
      if let formatting {
        var offset = contentRange.location
        for fragment in formatting.fragments(in: contentRange) {
          let raw = fragment.text as NSString
          let cleaned = fragment.text
          if !cleaned.isEmpty {
            let glyph = manager.glyphIndexForCharacter(at: offset)
            let origin = manager.location(forGlyphAt: glyph)
            let native = textView.convert(NSPoint(x: rect.minX + origin.x, y: rect.minY + origin.y), to: viewer.view)
            let mapped = viewer.view.convert(native, to: page)
            segments.append(.init(text: cleaned, x: mapped.x, format: fragment.format))
          }
          offset += raw.length
        }
      }
      let breakFormat = hard ? formatting?.fragments(in:
        NSRange(location: NSMaxRange(range) - 1, length: 1)).first?.format : nil
      lines.append(PageTextLine(text: value, x: point.x, baseline: point.y,
        segments: segments, endsParagraph: hard, breakFormat: breakFormat))
    }
    return lines
  }

  func pageBox() -> PageTextBox {
    let width: Double
    if !wrapsText, let container = textView.textContainer, let manager = textView.layoutManager,
      let scale = viewer?.view.scaleFactor {
      width = max(textWidth, manager.usedRect(for: container).width / scale)
    } else { width = textWidth }
    let baseX = sourceRect.minX + dx
    let lineX = pageLines().map(\.x).min() ?? baseX
    let boxX = min(baseX, lineX)
    let boxWidth = max(width, baseX + width - boxX)
    return .init(x: boxX, firstBaseline: initialBaseline + dy,
      width: max(24, min(2_000, boxWidth)),
      lineSpacing: {
        let leading = viewer?.pageTextParagraphStyle.leading ?? 0
        if leading > 0 { return leading }
        return sourceTarget?.paragraph?.lineSpacing ?? originalStyle.fontSize * 1.2
      }(),
      wraps: wrapsText)
  }

  override func scrollWheel(with event: NSEvent) { viewer?.scrollPage(with: event) }
  override func magnify(with event: NSEvent) { viewer?.view.magnify(with: event) }
}
