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
    viewer.graphicSelectionFocuser = { [weak view] in view?.focusForKeyboard() }
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
      let page = viewer.view.page(for: convert(overlayPoint, to: viewer.view), nearest: false)
    else { return nil }
    return (page, document.index(for: page), viewer.view.convert(convert(overlayPoint, to: viewer.view), to: page))
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
    guard let viewer, let bounds = GraphicSelectionModel.union(selectionRects().map(\.1)),
      let handle = GraphicSelectionModel.handle(at: point, selection: bounds),
      let selected = viewer.selectedGraphics.first,
      let page = viewer.view.document?.page(at: selected.pageIndex),
      let pageBounds = viewer.selectedGraphicBounds,
      let center = GraphicSelectionModel.handleCenters(bounds: bounds).first(where: { $0.0 == handle })?.1
    else { return nil }
    // Handle names belong to page space, even when PDFKit rotates the page.
    let mapped = viewer.view.convert(convert(center, to: viewer.view), to: page)
    return GraphicSelectionModel.handleCenters(bounds: pageBounds).min {
      hypot($0.1.x - mapped.x, $0.1.y - mapped.y) < hypot($1.1.x - mapped.x, $1.1.y - mapped.y)
    }?.0
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
    if viewer?.graphicRefusalProvider?(index, values) != nil { return self }
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
    pressGraphic = nil
    if editsEnabled, let handle = handleAt(point) {
      drag = .resize(
        handle: handle, start: point, current: point,
        uniform: event.modifierFlags.contains(.shift))
      focusForKeyboard()
      return
    }
    if let target = graphicAt(point), let viewer {
      if event.modifierFlags.contains(.shift) {
        let exists = viewer.selectedGraphics.contains { $0.streamID == target.streamID }
        viewer.selectGraphics(exists ? viewer.selectedGraphics.filter { $0.streamID != target.streamID }
          : viewer.selectedGraphics + [target])
        focusForKeyboard()
        return
      }
      if !viewer.selectedGraphics.contains(where: { $0.streamID == target.streamID }) {
        viewer.selectGraphics([target])
      }
      pressGraphic = target
      drag = .move(start: point, current: point)
      focusForKeyboard()
      return
    }
    if let (_, index, pagePoint) = pageAndPoint(at: point),
      let reason = viewer?.graphicRefusalProvider?(
        index, [Double(pagePoint.x), Double(pagePoint.y)]) {
      viewer?.reportGraphicUnavailable(pageIndex: index, reason: reason)
      NSSound.beep()
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
      if editsEnabled, hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance,
        let delta = pageDelta(from: start, to: point),
        delta.x.isFinite, delta.y.isFinite,
        let viewer {
        viewer.previewGraphicTransform(viewer.selectedGraphics.map {
          (target: $0, dx: Double(delta.x), dy: Double(delta.y), scaleX: 1.0, scaleY: 1.0)
        })
      }
    case .resize(let handle, let start, _, _):
      drag = .resize(
        handle: handle, start: start, current: point,
        uniform: event.modifierFlags.contains(.shift))
      if editsEnabled, hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance,
        let group = viewer?.selectedGraphicBounds,
        let destination = resizedBounds(
          handle: handle, from: start, to: point,
          uniform: event.modifierFlags.contains(.shift)) {
        let mappings = viewer?.graphicResizeMappings(from: group, to: destination) ?? []
        if !mappings.isEmpty { viewer?.previewGraphicTransform(mappings) }
      }
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
    viewer?.endGraphicPreview()
    switch active {
    case .rubberBand(let start, _, let pageIndex):
      commitRubberBand(from: start, to: point, pageIndex: pageIndex)
    case .move(let start, _):
      let moved = hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance
      if moved, editsEnabled {
        commitMove(from: start, to: point)
      } else if pressGraphic != nil {
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
      let startPage = viewer.view.page(for: convert(start, to: viewer.view), nearest: false)
    else { return nil }
    let a = viewer.view.convert(convert(start, to: viewer.view), to: startPage)
    let b = viewer.view.convert(convert(end, to: viewer.view), to: startPage)
    return NSPoint(x: b.x - a.x, y: b.y - a.y)
  }

  private func commitMove(from start: NSPoint, to end: NSPoint) {
    guard let viewer, let delta = pageDelta(from: start, to: end),
      delta.x.isFinite, delta.y.isFinite,
      hypot(delta.x, delta.y) > 0.001, !viewer.selectedGraphics.isEmpty
    else { return }
    viewer.onMoveGraphics?(
      viewer.selectedGraphics.map { (target: $0, dx: Double(delta.x), dy: Double(delta.y)) })
  }

  private func resizedBounds(handle: GraphicHandle, from start: NSPoint, to end: NSPoint,
    uniform: Bool) -> CGRect? {
    guard let viewer, let group = viewer.selectedGraphicBounds,
      let delta = pageDelta(from: start, to: end),
      let center = GraphicSelectionModel.handleCenters(bounds: group).first(where: { $0.0 == handle })?.1,
      let m = GraphicSelectionModel.resize(handle: handle, startBounds: group,
        current: CGPoint(x: center.x + delta.x, y: center.y + delta.y), uniform: uniform)
    else { return nil }
    return CGRect(x: group.minX + m.dx, y: group.minY + m.dy,
      width: group.width * m.scaleX, height: group.height * m.scaleY)
  }

  private func commitResize(
    handle: GraphicHandle, from start: NSPoint, to end: NSPoint, uniform: Bool
  ) {
    guard let bounds = resizedBounds(handle: handle, from: start, to: end, uniform: uniform) else { return }
    viewer?.setGraphicBounds(bounds)
  }

  private func commitRubberBand(from start: NSPoint, to end: NSPoint, pageIndex: Int) {
    guard let viewer,
      let candidates = viewer.graphicsListProvider?(pageIndex)
    else { return }
    let rect = CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y))
    let valid = candidates.compactMap { target -> (AddedGraphicTarget, CGRect)? in
      guard let box = overlayRect(of: target) else { return nil }; return (target, box)
    }
    let hits = GraphicSelectionModel.rubberBandSelect(rect: rect, candidates: valid.map(\.1))
    viewer.selectGraphics(hits.map { valid[$0].0 })
    if !hits.isEmpty { focusForKeyboard() }
  }

  fileprivate func focusForKeyboard() {
    window?.makeFirstResponder(self)
  }

  // MARK: - Keyboard

  override func cancelOperation(_ sender: Any?) {
    if drag != nil {
      viewer?.endGraphicPreview()
      drag = nil; pressGraphic = nil
      needsDisplay = true
    } else {
      viewer?.clearGraphicSelection()
      window?.makeFirstResponder(viewer?.view)
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { cancelOperation(nil); return }
    if drag != nil { return }
    guard editsEnabled, let viewer, !viewer.selectedGraphics.isEmpty,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {
      viewer.deleteSelectedGraphics()
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
        viewer.selectedGraphics.map { (target: $0, dx: dx, dy: dy) })
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
    var rects = selectionRects().map(\.1).map { $0.offsetBy(dx: preview.x, dy: preview.y) }
    if case .resize(let handle, let start, let current, let uniform) = drag,
      let viewer, let group = viewer.selectedGraphicBounds,
      let destination = resizedBounds(handle: handle, from: start, to: current, uniform: uniform),
      let selected = viewer.selectedGraphics.first,
      let page = viewer.view.document?.page(at: selected.pageIndex) {
      rects = viewer.selectedGraphics.compactMap { target in
        let member = CGRect(x: target.rect[0], y: target.rect[1],
          width: target.rect[2] - target.rect[0], height: target.rect[3] - target.rect[1])
        guard let m = GraphicSelectionModel.mapping(member: member, from: group, to: destination) else { return nil }
        return overlayRect(pageRect: CGRect(x: member.minX + m.dx, y: member.minY + m.dy,
          width: member.width * m.scaleX, height: member.height * m.scaleY), on: page)
      }
    }
    for drawn in rects {
      accent.setStroke()
      let frame = NSBezierPath(rect: drawn)
      frame.lineWidth = 2
      frame.stroke()
      NSColor.selectedContentBackgroundColor.setStroke()
      let inner = NSBezierPath(rect: drawn.insetBy(dx: 1, dy: 1))
      inner.lineWidth = 1
      inner.stroke()
    }
    // One set of handles describes the shared transform, including spacing.
    if editsEnabled, let bounds = GraphicSelectionModel.union(rects) {
      if rects.count > 1 {
        accent.setStroke()
        let group = NSBezierPath(rect: bounds)
        group.setLineDash([4, 3], count: 2, phase: 0); group.stroke()
      }
      for (_, center) in GraphicSelectionModel.handleCenters(bounds: bounds) {
        let visual = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        NSColor.white.setFill(); NSBezierPath(rect: visual).fill()
        accent.setStroke()
        let outline = NSBezierPath(rect: visual); outline.lineWidth = 2; outline.stroke()
      }
    }
  }
}
