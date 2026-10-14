import AppKit
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI

/// P12-017: pointer selection for app-created graphics (image stamps and
/// rectangles). Preview first: in Select (and Page) mode clicks select,
/// empty-area drags rubber-band multi-select, and nothing mutates the
/// document — body drags only preview the selection. Arming the Image Edit
/// tool enables move, resize handles, and keyboard nudging through the
/// P21-010 core commands as one transaction on release. Drags starting on
/// form widgets or document text pass through to the page view, so native
/// form editing and text selection keep working.
struct GraphicSelectionOverlay: NSViewRepresentable {
  @ObservedObject var viewer: PDFViewingSession

  func makeNSView(context: Context) -> GraphicSelectionOverlayView {
    let view = GraphicSelectionOverlayView()
    view.viewer = viewer
    viewer.hasPendingGraphicGesture = { [weak view] in view?.hasPendingGesture ?? false }
    return view
  }

  func updateNSView(_ nsView: GraphicSelectionOverlayView, context: Context) {
    nsView.viewer = viewer
    nsView.refresh()
  }
}

@MainActor
final class GraphicSelectionOverlayView: NSView {
  weak var viewer: PDFViewingSession?

  /// P12-017: the click/drag tolerance shared with the text overlay, so a
  /// press that barely moves still counts as a click everywhere.
  private static let clickTolerance: CGFloat = 4

  private enum Drag {
    case rubberBand(start: NSPoint, current: NSPoint, pageIndex: Int)
    case move(start: NSPoint, current: NSPoint)
    case resize(handle: GraphicHandle, start: NSPoint, current: NSPoint, uniform: Bool)
  }

  private var drag: Drag?
  fileprivate var hasPendingGesture: Bool { drag != nil }
  private var pressGraphic: AddedGraphicTarget?
  private var pressPoint: NSPoint = .zero

  override var acceptsFirstResponder: Bool {
    // Key status only while a selection exists to nudge or clear; otherwise
    // the overlay never disturbs window focus (and smoke-style menu routing).
    viewer?.selectedGraphics.isEmpty == false
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Redraw when the selection changes elsewhere (menu commands, undo).
  func refresh() {
    needsDisplay = true
  }

  private var toolsEnabled: Bool {
    guard let viewer else { return false }
    return viewer.activeTool == .select || viewer.activeTool == .page
      || viewer.activeTool == .imageEdit
  }

  /// Mutating gestures (move, resize, keyboard nudge) only in the explicit
  /// Image Edit tool. In Select/Page preview modes drags only select, so a
  /// stray drag can never dirty the document.
  private var editsEnabled: Bool {
    viewer?.activeTool == .imageEdit
  }

  // MARK: - Geometry

  private func pageAndPoint(at overlayPoint: NSPoint)
    -> (page: PDFPage, index: Int, pagePoint: NSPoint)?
  {
    guard let viewer, let document = viewer.view.document,
      let page = viewer.view.page(for: overlayPoint, nearest: false)
    else { return nil }
    return (page, document.index(for: page), viewer.view.convert(overlayPoint, to: page))
  }

  private func overlayRect(pageRect: CGRect, on page: PDFPage) -> CGRect? {
    guard let viewer else { return nil }
    let viewRect = viewer.view.convert(pageRect, from: page)
    return convert(viewRect, from: viewer.view)
  }

  private func overlayRect(of target: AddedGraphicTarget) -> CGRect? {
    guard target.rect.count == 4,
      let page = viewer?.view.document?.page(at: target.pageIndex)
    else { return nil }
    return overlayRect(
      pageRect: CGRect(
        x: target.rect[0], y: target.rect[1],
        width: target.rect[2] - target.rect[0], height: target.rect[3] - target.rect[1]),
      on: page)
  }

  /// Selection rects in overlay space for the current selection.
  private func selectionRects() -> [(AddedGraphicTarget, CGRect)] {
    guard let viewer else { return [] }
    var result: [(AddedGraphicTarget, CGRect)] = []
    for target in viewer.selectedGraphics {
      if let rect = overlayRect(of: target) { result.append((target, rect)) }
    }
    return result
  }

  private func handleAt(_ point: NSPoint) -> GraphicHandle? {
    for (_, rect) in selectionRects() {
      if let handle = GraphicSelectionModel.handle(at: point, selection: rect) {
        return handle
      }
    }
    return nil
  }

  private func graphicAt(_ point: NSPoint) -> AddedGraphicTarget? {
    guard let (_, index, pagePoint) = pageAndPoint(at: point),
      let target = viewer?.graphicTargetProvider?(
        index, [Double(pagePoint.x), Double(pagePoint.y)])
    else { return nil }
    return target
  }

  // MARK: - Hit testing

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard toolsEnabled else { return nil }
    // An active drag owns the pointer until release.
    if drag != nil { return self }
    guard let (_, index, pagePoint) = pageAndPoint(at: point) else { return nil }
    let values = [Double(pagePoint.x), Double(pagePoint.y)]
    // Form widgets always win; text drags stay native.
    if viewer?.formFieldProvider?(index, values) != nil { return nil }
    // Resize handles only exist in the Image Edit tool; in preview modes
    // the pointer passes through to selection and rubber-band behavior.
    if editsEnabled, handleAt(point) != nil { return self }
    if viewer?.graphicTargetProvider?(index, values) != nil { return self }
    if viewer?.textRunProvider?(index, values) != nil { return nil }
    // Empty area: a drag may rubber-band, a click clears the selection —
    // but only on pages that actually carry graphics. On plain pages the
    // overlay stays fully transparent, so native drag selection and clicks
    // behave exactly as if it were not in the stack.
    if viewer?.graphicsListProvider?(index).isEmpty == false { return self }
    return nil
  }

  // MARK: - Pointer

  override func mouseDown(with event: NSEvent) {
    guard toolsEnabled else { return }
    let point = convert(event.locationInWindow, from: nil)
    pressPoint = point
    pressGraphic = nil
    if editsEnabled, let handle = handleAt(point) {
      drag = .resize(
        handle: handle, start: point, current: point,
        uniform: event.modifierFlags.contains(.shift))
      return
    }
    if let target = graphicAt(point) {
      pressGraphic = target
      drag = .move(start: point, current: point)
      return
    }
    if let (_, index, _) = pageAndPoint(at: point),
      viewer?.graphicsListProvider?(index).isEmpty == false
    {
      drag = .rubberBand(start: point, current: point, pageIndex: index)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard drag != nil else { return }
    let point = convert(event.locationInWindow, from: nil)
    switch drag {
    case .rubberBand(let start, _, let pageIndex):
      drag = .rubberBand(start: start, current: point, pageIndex: pageIndex)
    case .move(let start, _):
      drag = .move(start: start, current: point)
    case .resize(let handle, let start, _, _):
      drag = .resize(
        handle: handle, start: start, current: point,
        uniform: event.modifierFlags.contains(.shift))
    case .none:
      break
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      drag = nil
      pressGraphic = nil
      needsDisplay = true
    }
    guard let active = drag else { return }
    let point = convert(event.locationInWindow, from: nil)
    switch active {
    case .rubberBand(let start, _, let pageIndex):
      commitRubberBand(from: start, to: point, pageIndex: pageIndex)
    case .move(let start, _):
      let moved = hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance
      if moved, editsEnabled {
        commitMove(from: start, to: point)
      } else if let target = pressGraphic {
        viewer?.selectGraphics([target])
        focusForKeyboard()
      } else {
        viewer?.clearGraphicSelection()
      }
    case .resize(let handle, let start, _, let uniform):
      let moved = hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance
      if moved, editsEnabled {
        commitResize(handle: handle, from: start, to: point, uniform: uniform)
      }
    }
  }

  private func pageDelta(from start: NSPoint, to end: NSPoint) -> NSPoint? {
    guard let viewer,
      let startPage = viewer.view.page(for: start, nearest: false)
    else { return nil }
    let a = viewer.view.convert(start, to: startPage)
    let b = viewer.view.convert(end, to: startPage)
    return NSPoint(x: b.x - a.x, y: b.y - a.y)
  }

  private func commitMove(from start: NSPoint, to end: NSPoint) {
    guard let viewer, let delta = pageDelta(from: start, to: end),
      delta.x.isFinite, delta.y.isFinite,
      hypot(delta.x, delta.y) > 0.001, !viewer.selectedGraphics.isEmpty
    else { return }
    viewer.onMoveGraphics?(
      viewer.selectedGraphics.map { (streamID: $0.streamID, dx: Double(delta.x), dy: Double(delta.y)) })
  }

  private func commitResize(
    handle: GraphicHandle, from start: NSPoint, to end: NSPoint, uniform: Bool
  ) {
    guard let viewer, !viewer.selectedGraphics.isEmpty else { return }
    var batch: [(
      streamID: PDFObjectID, dx: Double, dy: Double, scaleX: Double, scaleY: Double
    )] = []
    for target in viewer.selectedGraphics {
      guard target.rect.count == 4,
        let page = viewer.view.document?.page(at: target.pageIndex)
      else { continue }
      let current = viewer.view.convert(end, to: page)
      let bounds = CGRect(
        x: target.rect[0], y: target.rect[1],
        width: target.rect[2] - target.rect[0], height: target.rect[3] - target.rect[1])
      guard
        let mapping = GraphicSelectionModel.resize(
          handle: handle, startBounds: bounds,
          current: CGPoint(x: Double(current.x), y: Double(current.y)),
          uniform: uniform)
      else { continue }
      batch.append((
        streamID: target.streamID, dx: mapping.dx, dy: mapping.dy,
        scaleX: mapping.scaleX, scaleY: mapping.scaleY))
    }
    if !batch.isEmpty { viewer.onResizeGraphics?(batch) }
  }

  private func commitRubberBand(from start: NSPoint, to end: NSPoint, pageIndex: Int) {
    guard let viewer,
      let candidates = viewer.graphicsListProvider?(pageIndex)
    else { return }
    let rect = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y))
    var boxes: [CGRect] = []
    for target in candidates {
      guard let box = overlayRect(of: target) else { continue }
      boxes.append(box)
    }
    let hits = GraphicSelectionModel.rubberBandSelect(rect: rect, candidates: boxes)
    viewer.selectGraphics(hits.map { candidates[$0] })
    if !hits.isEmpty { focusForKeyboard() }
  }

  private func focusForKeyboard() {
    window?.makeFirstResponder(self)
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    guard editsEnabled, let viewer, !viewer.selectedGraphics.isEmpty else {
      super.keyDown(with: event)
      return
    }
    // Escape clears the selection; arrows nudge it (Shift: 10 pt).
    if event.keyCode == 53 {
      viewer.clearGraphicSelection()
      window?.makeFirstResponder(viewer.view)
      return
    }
    let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
    let delta: (Double, Double)?
    switch event.keyCode {
    case 123: delta = (-step, 0)
    case 124: delta = (step, 0)
    case 125: delta = (0, -step)
    case 126: delta = (0, step)
    default: delta = nil
    }
    if let (dx, dy) = delta {
      viewer.onMoveGraphics?(
        viewer.selectedGraphics.map { (streamID: $0.streamID, dx: dx, dy: dy) })
      return
    }
    super.keyDown(with: event)
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard toolsEnabled else { return }
    let accent = NSColor.controlAccentColor
    // Rubber band.
    if case .rubberBand(let start, let current, _) = drag {
      let rect = CGRect(
        x: min(start.x, current.x), y: min(start.y, current.y),
        width: abs(current.x - start.x), height: abs(current.y - start.y))
      accent.withAlphaComponent(0.15).setFill()
      rect.fill()
      accent.setStroke()
      let path = NSBezierPath(rect: rect)
      path.lineWidth = 1
      path.setLineDash([4, 3], count: 2, phase: 0)
      path.stroke()
    }
    // Move preview offset in overlay points (same-frame assumption as the
    // text overlay: overlay and view coordinates agree).
    var preview = NSPoint.zero
    if editsEnabled, case .move(let start, let current) = drag,
      hypot(current.x - start.x, current.y - start.y) > Self.clickTolerance
    {
      preview = NSPoint(x: current.x - start.x, y: current.y - start.y)
    }
    for (_, rect) in selectionRects() {
      let drawn = rect.offsetBy(dx: preview.x, dy: preview.y)
      accent.setStroke()
      let frame = NSBezierPath(rect: drawn)
      frame.lineWidth = 2
      frame.stroke()
      NSColor.selectedContentBackgroundColor.setStroke()
      let inner = NSBezierPath(rect: drawn.insetBy(dx: 1, dy: 1))
      inner.lineWidth = 1
      inner.stroke()
      // Handles only in the Image Edit tool; preview modes show the
      // selection frame without offering a mutation affordance.
      guard editsEnabled else { continue }
      for (_, center) in GraphicSelectionModel.handleCenters(bounds: drawn) {
        let visual = CGRect(
          x: center.x - GraphicSelectionModel.handleVisualSize / 2,
          y: center.y - GraphicSelectionModel.handleVisualSize / 2,
          width: GraphicSelectionModel.handleVisualSize,
          height: GraphicSelectionModel.handleVisualSize)
        NSColor.white.setFill()
        NSBezierPath(rect: visual).fill()
        accent.setStroke()
        let outline = NSBezierPath(rect: visual)
        outline.lineWidth = 2
        outline.stroke()
      }
    }
  }
}
