import AppKit
import Combine
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI

/// IMG-04/IMG-05: the mixed text/image selection canvas.
///
/// The overlay rides above the existing text and graphic overlays. It only
/// claims pointer events required for mixed selection:
///
/// * Shift-click over a supported object toggles it in the selection.
/// * Shift-drag on empty page content starts an additive marquee.
/// * A click or drag inside an existing mixed selection moves the whole
///   selection; corner/edge handles resize it when every member supports that.
/// * In explicit Arrange mode every page click is claimed: plain clicks select,
///   plain drags marquee, and Esc leaves the mode.
///
/// Otherwise the overlay is transparent, so ordinary PDF text selection,
/// inline text editing, form filling and the existing image tools keep their
/// current behavior. Every commit goes through the controller, which applies
/// one core transaction (one Undo) and reloads the renderer.
struct PageObjectSelectionOverlay: NSViewRepresentable {
  @ObservedObject var viewer: PDFViewingSession

  func makeNSView(context: Context) -> PageObjectSelectionOverlayView {
    let view = PageObjectSelectionOverlayView()
    view.viewer = viewer
    return view
  }

  func updateNSView(_ nsView: PageObjectSelectionOverlayView, context: Context) {
    nsView.viewer = viewer
    nsView.refresh()
  }
}

@MainActor
final class PageObjectSelectionOverlayView: NSView {
  weak var viewer: PDFViewingSession?
  private weak var controller: PageObjectSelectionController?
  private var observations: Set<AnyCancellable> = []
  private static let clickTolerance: CGFloat = 4

  private enum Drag {
    case marquee(start: NSPoint, current: NSPoint)
    case move(start: NSPoint, current: NSPoint)
    case resize(handle: GraphicHandle, start: NSPoint, current: NSPoint, group: [Double])
  }

  private var drag: Drag?
  private var pressPoint = NSPoint.zero
  private var pressPageIndex = 0

  override var acceptsFirstResponder: Bool {
    guard let controller else { return false }
    return controller.selection != nil || controller.isArrangeMode
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    resolveController()
  }

  func refresh() {
    resolveController()
    needsDisplay = true
  }

  private func resolveController() {
    guard let document = window?.windowController?.document as? SPDFDocument else { return }
    let resolved = document.pageObjectSelectionController
    guard controller !== resolved else { return }
    controller = resolved
    observations.removeAll()
    resolved.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          self?.needsDisplay = true
        }
      }
      .store(in: &observations)
  }

  // MARK: - Geometry

  private func pageAndPoint(at overlayPoint: NSPoint)
    -> (page: PDFPage, index: Int, point: CGPoint)?
  {
    guard let viewer, let document = viewer.view.document,
      let page = viewer.view.page(for: convert(overlayPoint, to: viewer.view), nearest: false)
    else { return nil }
    let index = document.index(for: page)
    guard index >= 0 else { return nil }
    return (page, index, viewer.view.convert(convert(overlayPoint, to: viewer.view), to: page))
  }

  private func overlayRect(of rect: [Double], pageIndex: Int) -> CGRect? {
    guard let viewer, rect.count == 4,
      let page = viewer.view.document?.page(at: pageIndex)
    else { return nil }
    let pageRect = CGRect(
      x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1])
    return convert(viewer.view.convert(pageRect, from: page), from: viewer.view)
  }

  private func overlayBounds(of selection: PageObjectSelection) -> CGRect? {
    guard let controller else { return nil }
    var union: CGRect?
    for member in selection.members {
      guard let rect = overlayRect(of: member.bounds, pageIndex: controller.pageIndex) else {
        continue
      }
      union = union.map { $0.union(rect) } ?? rect
    }
    return union
  }

  private func pageDelta(from start: NSPoint, to end: NSPoint) -> CGPoint? {
    guard let viewer,
      let startPage = viewer.view.page(
        for: convert(start, to: viewer.view), nearest: false)
    else { return nil }
    let a = viewer.view.convert(convert(start, to: viewer.view), to: startPage)
    let b = viewer.view.convert(convert(end, to: viewer.view), to: startPage)
    return CGPoint(x: b.x - a.x, y: b.y - a.y)
  }

  private func resizeHandle(at point: NSPoint, selection: PageObjectSelection)
    -> GraphicHandle?
  {
    guard selection.supports(.resize), let bounds = overlayBounds(of: selection) else {
      return nil
    }
    return GraphicSelectionModel.handle(at: point, selection: bounds)
  }

  private func resizedDestination(
    handle: GraphicHandle, start: NSPoint, current: NSPoint, group: [Double]
  ) -> [Double]? {
    guard let viewer, let controller, group.count == 4,
      let page = viewer.view.document?.page(at: controller.pageIndex)
    else { return nil }
    let startPage = viewer.view.convert(convert(start, to: viewer.view), to: page)
    let currentPage = viewer.view.convert(convert(current, to: viewer.view), to: page)
    let groupRect = CGRect(
      x: group[0], y: group[1], width: group[2] - group[0], height: group[3] - group[1])
    guard
      let center = GraphicSelectionModel.handleCenters(bounds: groupRect)
        .first(where: { $0.0 == handle })?.1
    else { return nil }
    let delta = CGPoint(
      x: currentPage.x - startPage.x, y: currentPage.y - startPage.y)
    let uniform =
      controller.selection?.resizeRule == .uniformOnly
      || NSEvent.modifierFlags.contains(.shift)
    guard
      let mapping = GraphicSelectionModel.resize(
        handle: handle, startBounds: groupRect,
        current: CGPoint(x: center.x + delta.x, y: center.y + delta.y), uniform: uniform)
    else { return nil }
    let width = (group[2] - group[0]) * mapping.scaleX
    let height = (group[3] - group[1]) * mapping.scaleY
    return [
      group[0] + mapping.dx, group[1] + mapping.dy,
      group[0] + mapping.dx + width, group[1] + mapping.dy + height,
    ]
  }

  // MARK: - Hit testing

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point) else { return nil }
    resolveController()
    guard let viewer, let controller, controller.isAvailable else { return nil }
    let editingTool = viewer.activeTool == .textEdit
    let arrangeMode = controller.isArrangeMode && viewer.activeTool == .select
    guard editingTool || arrangeMode else { return nil }
    if drag != nil { return self }
    if arrangeMode { return self }
    if NSEvent.modifierFlags.contains(.shift), pageAndPoint(at: point) != nil { return self }
    if let selection = controller.selection, let bounds = overlayBounds(of: selection) {
      if resizeHandle(at: point, selection: selection) != nil { return self }
      if bounds.insetBy(dx: -2, dy: -2).contains(point) { return self }
    }
    return nil
  }

  // MARK: - Pointer

  override func mouseDown(with event: NSEvent) {
    resolveController()
    let point = convert(event.locationInWindow, from: nil)
    guard let controller, controller.isAvailable,
      let (_, pageIndex, pagePoint) = pageAndPoint(at: point)
    else { return }
    pressPoint = point
    pressPageIndex = pageIndex
    controller.begin(pageIndex: pageIndex)
    let values = [Double(pagePoint.x), Double(pagePoint.y)]
    let shift = event.modifierFlags.contains(.shift)
    let ref = controller.object(at: values, pageIndex: pageIndex)
    if shift {
      if let ref {
        controller.toggle(ref)
      } else if let reason = controller.refusal(at: values, pageIndex: pageIndex) {
        controller.report(reason)
      } else {
        drag = .marquee(start: point, current: point)
      }
      needsDisplay = true
      focusForKeyboard()
      return
    }
    if let selection = controller.selection {
      if let handle = resizeHandle(at: point, selection: selection),
        let group = selection.bounds
      {
        drag = .resize(handle: handle, start: point, current: point, group: group)
        focusForKeyboard()
        return
      }
      if let bounds = overlayBounds(of: selection),
        bounds.insetBy(dx: -2, dy: -2).contains(point)
      {
        drag = .move(start: point, current: point)
        focusForKeyboard()
        return
      }
    }
    if controller.isArrangeMode {
      if let ref {
        controller.select(ref)
        focusForKeyboard()
      } else {
        controller.clear()
        drag = .marquee(start: point, current: point)
      }
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard drag != nil else { return }
    let point = convert(event.locationInWindow, from: nil)
    switch drag {
    case .marquee(let start, _):
      drag = .marquee(start: start, current: point)
    case .move(let start, _):
      drag = .move(start: start, current: point)
    case .resize(let handle, let start, _, let group):
      drag = .resize(handle: handle, start: start, current: point, group: group)
    case .none:
      break
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let active = drag else { return }
    drag = nil
    needsDisplay = true
    let point = convert(event.locationInWindow, from: nil)
    guard let controller, controller.isAvailable else { return }
    switch active {
    case .marquee(let start, _):
      guard let startHit = pageAndPoint(at: start),
        let endHit = pageAndPoint(at: point),
        startHit.index == endHit.index
      else { return }
      let rect = [
        Double(min(startHit.point.x, endHit.point.x)),
        Double(min(startHit.point.y, endHit.point.y)),
        Double(max(startHit.point.x, endHit.point.x)),
        Double(max(startHit.point.y, endHit.point.y)),
      ]
      controller.marquee(
        pageIndex: startHit.index, rect: rect,
        additive: event.modifierFlags.contains(.shift))
    case .move(let start, _):
      guard hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance,
        let delta = pageDelta(from: start, to: point)
      else { return }
      controller.moveSelection(dx: Double(delta.x), dy: Double(delta.y))
    case .resize(let handle, let start, _, let group):
      guard hypot(point.x - start.x, point.y - start.y) > Self.clickTolerance,
        let destination = resizedDestination(
          handle: handle, start: start, current: point, group: group)
      else { return }
      controller.resizeSelection(from: group, to: destination)
    }
  }

  fileprivate func focusForKeyboard() {
    window?.makeFirstResponder(self)
  }

  // MARK: - Keyboard and scroll

  override func cancelOperation(_ sender: Any?) {
    if drag != nil {
      drag = nil
      needsDisplay = true
      return
    }
    guard let controller else { return }
    if controller.isArrangeMode {
      controller.setArrangeMode(false)
    } else {
      controller.clear()
    }
    if let view = viewer?.view { window?.makeFirstResponder(view) }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      cancelOperation(nil)
      return
    }
    guard drag == nil, let controller, let selection = controller.selection,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {
      controller.deleteSelection()
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
      _ = selection
      controller.moveSelection(dx: dx, dy: dy)
      return
    }
    super.keyDown(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    viewer?.scrollPage(with: event)
  }

  override func magnify(with event: NSEvent) {
    viewer?.view.magnify(with: event)
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let controller, controller.isAvailable else { return }
    let accent = NSColor.controlAccentColor
    if case .marquee(let start, let current) = drag {
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
    guard let selection = controller.selection else { return }
    var preview = NSPoint.zero
    if case .move(let start, let current) = drag,
      hypot(current.x - start.x, current.y - start.y) > Self.clickTolerance
    {
      preview = NSPoint(x: current.x - start.x, y: current.y - start.y)
    }
    var rects: [CGRect] = []
    if case .resize(let handle, let start, let current, let group) = drag,
      let destination = resizedDestination(
        handle: handle, start: start, current: current, group: group)
    {
      for member in selection.members {
        guard
          let transform = PageObjectRects.mapping(
            member: member.bounds, from: group, to: destination)
        else { continue }
        let width = member.bounds[2] - member.bounds[0]
        let height = member.bounds[3] - member.bounds[1]
        let pageRect = [
          member.bounds[0] + transform.dx, member.bounds[1] + transform.dy,
          member.bounds[0] + transform.dx + width * transform.scaleX,
          member.bounds[1] + transform.dy + height * transform.scaleY,
        ]
        if let rect = overlayRect(of: pageRect, pageIndex: controller.pageIndex) {
          rects.append(rect)
        }
      }
    } else {
      for member in selection.members {
        guard let rect = overlayRect(of: member.bounds, pageIndex: controller.pageIndex) else {
          continue
        }
        rects.append(rect.offsetBy(dx: preview.x, dy: preview.y))
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
    guard let first = rects.first else { return }
    let union = rects.dropFirst().reduce(first) { $0.union($1) }
    if rects.count > 1 {
      accent.setStroke()
      let groupFrame = NSBezierPath(rect: union)
      groupFrame.lineWidth = 1
      groupFrame.setLineDash([4, 3], count: 2, phase: 0)
      groupFrame.stroke()
    }
    guard selection.supports(.resize) else { return }
    for (_, center) in GraphicSelectionModel.handleCenters(bounds: union) {
      let visual = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
      NSColor.white.setFill()
      NSBezierPath(rect: visual).fill()
      accent.setStroke()
      let outline = NSBezierPath(rect: visual)
      outline.lineWidth = 1.5
      outline.stroke()
    }
  }
}
