import AppKit
import MacServices
import SwiftUI

/// P22-008: native pointer input for the ink tool. The overlay sits above the
/// PDF view only while the tool is active, collects the drag, previews the
/// stroke, and hands page-space points to the session on mouse-up.
struct InkOverlay: NSViewRepresentable {
  @ObservedObject var viewer: PDFViewingSession

  func makeNSView(context: Context) -> InkOverlayView {
    let view = InkOverlayView()
    view.viewer = viewer
    return view
  }

  func updateNSView(_ nsView: InkOverlayView, context: Context) {
    nsView.viewer = viewer
  }
}

@MainActor
final class InkOverlayView: NSView {
  weak var viewer: PDFViewingSession?
  private var stroke: [NSPoint] = []
  private var pageIndex: Int?

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseDown(with event: NSEvent) {
    guard let viewer, viewer.isInkToolActive else { return }
    let point = convert(event.locationInWindow, from: nil)
    let viewPoint = viewer.view.convert(event.locationInWindow, from: nil)
    guard let page = viewer.view.page(for: viewPoint, nearest: true),
      let document = viewer.view.document
    else { return }
    pageIndex = document.index(for: page)
    stroke = [point]
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard viewer?.isInkToolActive == true, !stroke.isEmpty else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let last = stroke.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
    stroke.append(point)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let viewer, viewer.isInkToolActive, let pageIndex,
      stroke.count >= 2, let page = viewer.view.document?.page(at: pageIndex)
    else {
      reset()
      return
    }
    var points: [Double] = []
    points.reserveCapacity(stroke.count * 2)
    for point in stroke {
      let windowPoint = convert(point, to: nil)
      let viewPoint = viewer.view.convert(windowPoint, from: nil)
      let pagePoint = viewer.view.convert(viewPoint, to: page)
      points.append(Double(pagePoint.x))
      points.append(Double(pagePoint.y))
    }
    reset()
    if points.count >= 4 { viewer.onInkStroke?(pageIndex, points) }
  }

  override func cancelOperation(_ sender: Any?) {
    reset()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard stroke.count >= 2 else { return }
    // P12-025: the transient preview follows the appearance (Dark Mode and
    // high contrast included); the committed ink keeps its document color.
    NSColor.labelColor.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 2
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: stroke[0])
    for point in stroke.dropFirst() { path.line(to: point) }
    path.stroke()
  }

  private func reset() {
    stroke = []
    pageIndex = nil
    needsDisplay = true
  }
}
