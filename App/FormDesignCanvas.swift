import AppKit
import PDFCore
import PDFEditing
import PDFKit
import MacServices

/// FRM-02: the direct form-design canvas.
///
/// The overlay is installed over the page view by SPDFDocument.showFormDesign().
/// In Design preview it draws widgets, tab-order badges, detection proposals and
/// drag guides and handles pointer gestures; every committed gesture goes
/// through one SPDFDocument route, so it is one undoable transaction. In Fill
/// preview the overlay stops drawing and passes every event through to PDFKit.
final class FormDesignCanvasView: NSView {
  weak var document: SPDFDocument?
  var session: FormDesignSession? {
    didSet { refreshFromDocument() }
  }

  private enum DragMode: Equatable {
    case none
    case marquee
    case move
    case resize(FormResizeHandle)
    case draw(FormDetectedFieldKind)
  }

  private struct DragState {
    var mode: DragMode = .none
    var startView = NSPoint.zero
    var currentView = NSPoint.zero
    var startPage: [Double]?
    var currentPage: [Double]?
    var originalWidgets: [FormWidgetDescriptor] = []
    var previewRects: [[Double]] = []
    var previewDelta: [Double] = [0, 0]
    var guideVertical: Double?
    var guideHorizontal: Double?
    var hasDragged = false
  }

  private var drag = DragState()
  private var widgets: [FormWidgetDescriptor] = []
  private var candidates: [FormFieldCandidate] = []
  private var tabIndexByField: [String: Int] = [:]
  private var pageBoundsForDrawing: [Double] = [0, 0, 612, 792]
  private var isObserving = false

  override var isFlipped: Bool { false }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }

  // MARK: Lifecycle

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    if window != nil {
      startObserving()
      refreshFromDocument()
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let session, session.previewMode == .design else { return nil }
    guard window != nil else { return nil }
    return super.hitTest(point)
  }

  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }

  private func startObserving() {
    guard !isObserving, let pdfView = document?.viewer?.view else { return }
    isObserving = true
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(pageViewDidChange(_:)), name: .PDFViewPageChanged,
      object: pdfView)
    center.addObserver(
      self, selector: #selector(pageViewDidChange(_:)), name: .PDFViewScaleChanged,
      object: pdfView)
    center.addObserver(
      self, selector: #selector(pageViewDidChange(_:)), name: NSWindow.didResizeNotification,
      object: window)
  }

  private func stopObserving() {
    NotificationCenter.default.removeObserver(self)
    isObserving = false
  }

  @objc private func pageViewDidChange(_ notification: Notification) {
    refreshFromDocument()
  }

  // MARK: Data

  /// Reload the widgets and proposals the canvas shows from canonical state.
  func refreshFromDocument() {
    guard let document, let session else {
      widgets = []
      candidates = []
      needsDisplay = true
      return
    }
    guard session.previewMode == .design else {
      needsDisplay = true
      return
    }
    document.syncFormDesignPage()
    widgets = document.formDesignWidgetsForCurrentPage()
    candidates = session.review?.report.candidates.filter {
      $0.pageIndex == session.pageIndex
    } ?? []
    let state = document.formDesignTabOrderState()
    tabIndexByField = Dictionary(
      uniqueKeysWithValues: state.current.enumerated().map { ($1, $0 + 1) })
    pageBoundsForDrawing = document.formDesignPageBounds()
    let liveIDs = Set(widgets.map(\.id))
    if session.selection.widgets.contains(where: { !liveIDs.contains($0.id) }) {
      session.selection = FormWidgetSelection(
        widgets: session.selection.widgets.filter { liveIDs.contains($0.id) })
    }
    needsDisplay = true
  }

  // MARK: Coordinate helpers

  private func currentPage() -> PDFPage? {
    guard let viewer = document?.viewer, let pdfDocument = viewer.view.document,
      viewer.pageNumber >= 1, viewer.pageNumber <= pdfDocument.pageCount
    else { return nil }
    return pdfDocument.page(at: viewer.pageNumber - 1)
  }

  private func pdfViewPoint(_ point: NSPoint) -> NSPoint {
    convert(point, to: document?.viewer?.view)
  }

  private func pagePoint(_ point: NSPoint) -> [Double]? {
    guard let viewer = document?.viewer, let page = currentPage() else { return nil }
    let converted = viewer.view.convert(pdfViewPoint(point), to: page)
    return [Double(converted.x), Double(converted.y)]
  }

  private func viewRect(_ pageRect: [Double]) -> NSRect? {
    guard pageRect.count == 4, let viewer = document?.viewer, let page = currentPage() else {
      return nil
    }
    let inPDFView = viewer.view.convert(
      NSRect(
        x: pageRect[0], y: pageRect[1], width: pageRect[2] - pageRect[0],
        height: pageRect[3] - pageRect[1]), from: page)
    return convert(inPDFView, from: viewer.view)
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let session, session.previewMode == .design else { return }
    NSColor.clear.setFill()
    dirtyRect.fill()
    drawCandidates()
    drawWidgets()
    drawDragPreview()
  }

  private func drawCandidates() {
    guard let session, let review = session.review else { return }
    for candidate in candidates {
      let effective = review.effectiveCandidate(candidate.id) ?? candidate
      let decision = review.decision(for: candidate.id)
      let color: NSColor
      switch decision {
      case .accepted: color = .systemGreen
      case .rejected: color = .tertiaryLabelColor
      case .pending: color = candidate.isEligible ? .systemOrange : .systemRed
      }
      var firstRect: NSRect?
      for pageRect in candidate.rects {
        guard let rect = viewRect(pageRect) else { continue }
        if firstRect == nil { firstRect = rect }
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.5
        path.setLineDash([5, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
      }
      guard let firstRect else { continue }
      let caption =
        effective.kind.label + " " + effective.confidenceLabel
        + (candidate.isEligible ? "" : " - refused")
      drawCaption(caption, at: NSPoint(x: firstRect.minX, y: firstRect.maxY + 2), color: color)
    }
  }

  private func drawWidgets() {
    guard let session else { return }
    let selectedIDs = Set(session.selection.widgets.map(\.id))
    for widget in widgets {
      guard let rect = viewRect(widget.rect) else { continue }
      let isSelected = selectedIDs.contains(widget.id)
      let fill = isSelected
        ? NSColor.controlAccentColor.withAlphaComponent(0.20)
        : NSColor.systemBlue.withAlphaComponent(0.08)
      let stroke = isSelected ? NSColor.controlAccentColor : NSColor.systemBlue
      fill.setFill()
      NSBezierPath(rect: rect).fill()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = isSelected ? 2 : 1
      stroke.setStroke()
      path.stroke()
      if session.showTabOrder, let index = tabIndexByField[widget.fieldName],
        let pageRect = viewRect(widget.rect)
      {
        drawBadge(String(index), at: NSPoint(x: pageRect.minX - 9, y: pageRect.maxY + 4))
      }
      if rect.width > 70, rect.height > 14 {
        let label = widget.label ?? widget.fieldName
        drawCaption(label, at: NSPoint(x: rect.minX + 2, y: rect.midY - 5),
          color: NSColor.labelColor)
      }
      if isSelected, session.selection.count == 1 {
        drawHandles(for: rect)
      }
    }
    if session.showGuides, let union = FormDesignGeometry.union(
      session.selection.widgets.map(\.rect)), let rect = viewRect(union)
    {
      drawCaption("x " + format(union[0]) + "  y " + format(union[1])
        + "  w " + format(union[2] - union[0]) + "  h " + format(union[3] - union[1]),
        at: NSPoint(x: rect.minX, y: rect.minY - 16), color: .secondaryLabelColor)
    }
  }

  private func drawHandles(for rect: NSRect) {
    NSColor.white.setFill()
    NSColor.controlAccentColor.setStroke()
    for point in handlePoints(in: rect) {
      let handle = NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
      NSBezierPath(rect: handle).fill()
      NSBezierPath(rect: handle).stroke()
    }
  }

  private func handlePoints(in rect: NSRect) -> [NSPoint] {
    [
      NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY),
      NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.midY),
      NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.midX, y: rect.maxY),
      NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.midY),
    ]
  }

  private func drawDragPreview() {
    guard drag.mode != .none else { return }
    switch drag.mode {
    case .marquee:
      let rect = marqueeViewRect()
      let path = NSBezierPath(rect: rect)
      path.setLineDash([4, 2], count: 2, phase: 0)
      NSColor.controlAccentColor.setStroke()
      path.stroke()
    case .move, .resize:
      for widgetRect in drag.previewRects {
        guard let rect = viewRect(widgetRect) else { continue }
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(rect: rect).fill()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.setLineDash([6, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
      }
      drawGuideLines()
    case .draw:
      guard let preview = drag.previewRects.first, let rect = viewRect(preview) else { return }
      NSColor.systemOrange.withAlphaComponent(0.2).setFill()
      NSBezierPath(rect: rect).fill()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 1.5
      NSColor.systemOrange.setStroke()
      path.stroke()
    case .none:
      break
    }
  }

  private func drawGuideLines() {
    guard let viewer = document?.viewer else { return }
    let lineColor = NSColor.systemOrange.withAlphaComponent(0.8)
    lineColor.setStroke()
    if let guide = drag.guideVertical, let page = currentPage() {
      let top = viewer.view.convert(
        NSRect(x: guide, y: pageBoundsForDrawing[1], width: 0.5,
          height: pageBoundsForDrawing[3] - pageBoundsForDrawing[1]), from: page)
      let line = convert(top, from: viewer.view)
      let path = NSBezierPath()
      path.move(to: NSPoint(x: line.minX, y: line.minY))
      path.line(to: NSPoint(x: line.minX, y: line.maxY))
      path.lineWidth = 1
      path.stroke()
    }
    if let guide = drag.guideHorizontal, let page = currentPage() {
      let span = viewer.view.convert(
        NSRect(x: pageBoundsForDrawing[0], y: guide,
          width: pageBoundsForDrawing[2] - pageBoundsForDrawing[0], height: 0.5), from: page)
      let line = convert(span, from: viewer.view)
      let path = NSBezierPath()
      path.move(to: NSPoint(x: line.minX, y: line.minY))
      path.line(to: NSPoint(x: line.maxX, y: line.minY))
      path.lineWidth = 1
      path.stroke()
    }
  }

  private func drawCaption(_ text: String, at point: NSPoint, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9, weight: .medium),
      .foregroundColor: color,
      .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.75),
    ]
    (text as NSString).draw(at: point, withAttributes: attributes)
  }

  private func drawBadge(_ text: String, at point: NSPoint) {
    let rect = NSRect(x: point.x, y: point.y, width: 16, height: 14)
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9, weight: .bold),
      .foregroundColor: NSColor.white,
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(
      at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
      withAttributes: attributes)
  }

  private func format(_ value: Double) -> String {
    String(format: "%.1f", value)
  }

  // MARK: Hit testing

  private func widget(at point: NSPoint) -> FormWidgetDescriptor? {
    for widget in widgets.reversed() {
      if let rect = viewRect(widget.rect), rect.contains(point) { return widget }
    }
    return nil
  }

  private func candidate(at point: NSPoint) -> FormFieldCandidate? {
    for candidate in candidates {
      for pageRect in candidate.rects {
        if let rect = viewRect(pageRect), rect.contains(point) { return candidate }
      }
    }
    return nil
  }

  private func handle(at point: NSPoint) -> FormResizeHandle? {
    guard let session, session.selection.count == 1,
      let widget = session.selection.widgets.first, let rect = viewRect(widget.rect)
    else { return nil }
    let handles = FormResizeHandle.allCases
    for (index, handle) in handles.enumerated() {
      let center = handlePoints(in: rect)[index]
      if abs(point.x - center.x) <= 5, abs(point.y - center.y) <= 5 { return handle }
    }
    return nil
  }

  private func marqueeViewRect() -> NSRect {
    NSRect(
      x: min(drag.startView.x, drag.currentView.x),
      y: min(drag.startView.y, drag.currentView.y),
      width: abs(drag.currentView.x - drag.startView.x),
      height: abs(drag.currentView.y - drag.startView.y))
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    guard let session, session.previewMode == .design, let document else { return }
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    let page = pagePoint(point)
    drag = DragState()
    drag.startView = point
    drag.currentView = point
    drag.startPage = page
    drag.currentPage = page

    // A detection proposal is a review target first: clicking it toggles the
    // decision so a reviewer can accept or reject right on the page.
    if let candidate = candidate(at: point), session.review != nil {
      document.syncFormDesignPage()
      switch session.review?.decision(for: candidate.id) {
      case .accepted: document.rejectFormCandidate(candidate.id)
      case .rejected: document.resetFormCandidate(candidate.id)
      default: document.acceptFormCandidate(candidate.id)
      }
      refreshFromDocument()
      return
    }

    if let kind = session.newFieldKind, let page {
      drag.mode = .draw(kind)
      drag.currentPage = page
      drag.previewRects = [FormCanvasAuthoring.draggedRect(from: page, to: page)]
      needsDisplay = true
      return
    }

    if let handle = handle(at: point) {
      drag.mode = .resize(handle)
      drag.originalWidgets = session.selection.widgets
      needsDisplay = true
      return
    }

    if let hit = widget(at: point) {
      if event.modifierFlags.contains(.shift) {
        document.toggleFormWidgetSelection(hit)
      } else if !session.selection.widgets.contains(where: { $0.id == hit.id }) {
        document.selectFormWidgets([hit])
      }
      drag.mode = .move
      drag.originalWidgets = session.selection.widgets
      needsDisplay = true
      return
    }

    if !event.modifierFlags.contains(.shift) {
      document.clearFormWidgetSelection()
    }
    drag.mode = .marquee
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard drag.mode != .none else { return }
    let point = convert(event.locationInWindow, from: nil)
    drag.currentView = point
    drag.currentPage = pagePoint(point) ?? drag.currentPage
    drag.hasDragged = true
    updateDragPreview()
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      drag = DragState()
      needsDisplay = true
      refreshFromDocument()
    }
    guard let session, session.previewMode == .design, let document else { return }
    switch drag.mode {
    case .move:
      guard drag.hasDragged else { return }
      let delta = drag.previewDelta
      if abs(delta[0]) < 0.25, abs(delta[1]) < 0.25 { return }
      document.moveFormWidgetSelection(by: delta)
    case .resize(let handle):
      guard drag.hasDragged, let original = drag.originalWidgets.first,
        let preview = drag.previewRects.first
      else { return }
      let pageDelta = drag.currentPage.flatMap { end -> [Double]? in
        guard let start = drag.startPage else { return nil }
        return [end[0] - start[0], end[1] - start[1]]
      } ?? [0, 0]
      var delta = pageDelta
      switch handle {
      case .left, .topLeft, .bottomLeft: delta[0] = preview[0] - original.rect[0]
      case .right, .topRight, .bottomRight: delta[0] = preview[2] - original.rect[2]
      default: delta[0] = 0
      }
      switch handle {
      case .top, .topLeft, .topRight: delta[1] = preview[3] - original.rect[3]
      case .bottom, .bottomLeft, .bottomRight: delta[1] = preview[1] - original.rect[1]
      default: delta[1] = 0
      }
      document.resizeFormWidgetSelection(handle: handle, by: delta)
    case .draw(let kind):
      guard drag.hasDragged, let rect = drag.previewRects.first else { return }
      document.createFormFieldOnCanvas(kind: kind, rect: rect, name: nil, label: nil)
      if session.newFieldKind != nil {
        session.newFieldKind = nil
        session.panelController?.refresh()
      }
    case .marquee:
      guard drag.hasDragged else { return }
      let marquee = marqueeViewRect()
      let selected = widgets.filter { widget in
        guard let rect = viewRect(widget.rect) else { return false }
        return rect.intersects(marquee)
      }
      document.selectFormWidgets(selected)
    case .none:
      break
    }
  }

  override func cancelOperation(_ sender: Any?) {
    drag = DragState()
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      cancelOperation(nil)
      return
    }
    super.keyDown(with: event)
  }

  private func updateDragPreview() {
    guard let session else { return }
    switch drag.mode {
    case .move:
      guard let start = drag.startPage, let end = drag.currentPage else { return }
      let delta = [end[0] - start[0], end[1] - start[1]]
      var moved = drag.originalWidgets.map {
        FormDesignGeometry.clamped(
          FormDesignGeometry.translated($0.rect, by: delta), to: $0.pageBounds)
      }
      drag.guideVertical = nil
      drag.guideHorizontal = nil
      if session.showGuides, let union = FormDesignGeometry.union(moved) {
        let selectedIDs = Set(drag.originalWidgets.map(\.id))
        let otherRects = widgets.filter { !selectedIDs.contains($0.id) }.map(\.rect)
        let guides = FormDesignGeometry.guides(
          pageBounds: pageBoundsForDrawing, widgetRects: otherRects)
        let snapped = FormDesignGeometry.snap(union, guides: guides, tolerance: 5)
        let adjust = [snapped.rect[0] - union[0], snapped.rect[1] - union[1]]
        moved = drag.originalWidgets.map {
          FormDesignGeometry.clamped(
            FormDesignGeometry.translated($0.rect, by: [delta[0] + adjust[0], delta[1] + adjust[1]]),
            to: $0.pageBounds)
        }
        drag.guideVertical = snapped.verticalGuide
        drag.guideHorizontal = snapped.horizontalGuide
      }
      drag.previewRects = moved
      if let firstOriginal = drag.originalWidgets.first, let firstMoved = moved.first {
        drag.previewDelta = [
          firstMoved[0] - firstOriginal.rect[0], firstMoved[1] - firstOriginal.rect[1],
        ]
      }
    case .resize(let handle):
      guard let start = drag.startPage, let end = drag.currentPage,
        let original = drag.originalWidgets.first
      else { return }
      let delta = [end[0] - start[0], end[1] - start[1]]
      var preview = FormDesignGeometry.resized(
        original.rect, handle: handle, by: delta)
      drag.guideVertical = nil
      drag.guideHorizontal = nil
      if session.showGuides {
        let selectedIDs = Set(drag.originalWidgets.map(\.id))
        let otherRects = widgets.filter { !selectedIDs.contains($0.id) }.map(\.rect)
        let guides = FormDesignGeometry.guides(
          pageBounds: pageBoundsForDrawing, widgetRects: otherRects)
        let snapped = FormDesignGeometry.snap(preview, guides: guides, tolerance: 5)
        preview = snapped.rect
        drag.guideVertical = snapped.verticalGuide
        drag.guideHorizontal = snapped.horizontalGuide
      }
      drag.previewRects = [FormDesignGeometry.clamped(preview, to: original.pageBounds)]
    case .draw:
      guard let start = drag.startPage, let end = drag.currentPage else { return }
      drag.previewRects = [
        FormDesignGeometry.clamped(
          FormCanvasAuthoring.draggedRect(from: start, to: end), to: pageBoundsForDrawing)
      ]
    case .marquee, .none:
      break
    }
  }
}
