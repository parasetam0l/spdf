import AppKit
import MacServices
import PDFKit
import SwiftUI

/// P12-018: optional page rulers. Tick values come from `PageRulers` over
/// the live-measured origin, direction, and scale; the views only map them
/// to rows and columns, so flipped and rotated pages stay consistent.
struct HorizontalRuler: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    GeometryReader { geometry in
      Canvas { context, size in
        let scale = max(0.02, viewer.scale)
        let width = Double(size.width)
        guard
          let range = PageRulers.visibleRange(
            origin: Double(viewer.rulerPageOrigin.x),
            direction: viewer.rulerXDirection, scale: scale, length: width)
        else { return }
        for tick in PageRulers.values(in: range, scale: scale) {
          guard
            let x = PageRulers.position(
              value: tick.value, origin: Double(viewer.rulerPageOrigin.x),
              direction: viewer.rulerXDirection, scale: scale),
            x >= 0, x <= width
          else { continue }
          var path = Path()
          path.move(to: CGPoint(x: x, y: size.height))
          path.addLine(to: CGPoint(x: x, y: tick.labeled ? 6 : size.height - 6))
          context.stroke(
            path, with: .color(.secondary),
            lineWidth: tick.labeled ? 1 : 0.5)
          if tick.labeled {
            context.draw(
              Text("\(Int(tick.value))").font(.caption2).foregroundStyle(.secondary),
              at: CGPoint(x: x + 2, y: 8), anchor: .topLeading)
          }
        }
      }
    }
    .background(.bar)
  }
}

struct VerticalRuler: View {
  @ObservedObject var viewer: PDFViewingSession

  var body: some View {
    GeometryReader { geometry in
      Canvas { context, size in
        let scale = max(0.02, viewer.scale)
        let height = Double(size.height)
        guard
          let range = PageRulers.visibleRange(
            origin: Double(viewer.rulerPageOrigin.y),
            direction: viewer.rulerYDirection, scale: scale, length: height)
        else { return }
        for tick in PageRulers.values(in: range, scale: scale) {
          guard
            let viewY = PageRulers.position(
              value: tick.value, origin: Double(viewer.rulerPageOrigin.y),
              direction: viewer.rulerYDirection, scale: scale),
            viewY >= 0, viewY <= height
          else { continue }
          // SwiftUI draws top-down; AppKit view coordinates may not.
          let y = viewer.view.isFlipped ? viewY : height - viewY
          guard y >= 0, y <= height else { continue }
          var path = Path()
          path.move(to: CGPoint(x: size.width, y: y))
          path.addLine(to: CGPoint(x: tick.labeled ? 6 : size.width - 6, y: y))
          context.stroke(
            path, with: .color(.secondary),
            lineWidth: tick.labeled ? 1 : 0.5)
          if tick.labeled {
            context.draw(
              Text("\(Int(tick.value))").font(.caption2).foregroundStyle(.secondary),
              at: CGPoint(x: 4, y: y - 8), anchor: .topLeading)
          }
        }
      }
    }
    .background(.bar)
  }
}

/// P12-018: snapping guide overlay. Display-only lines from `PageGuides`
/// mapped through the live page-to-view transform; placement snapping itself
/// stays in `AddedContent.snap` until drag consumers arrive with P12-017.
struct GuideOverlayView: NSViewRepresentable {
  @ObservedObject var viewer: PDFViewingSession

  func makeNSView(context: Context) -> GuideOverlay {
    let view = GuideOverlay()
    view.viewer = viewer
    // NSView AX properties always expose; the representable modifier may not.
    view.setAccessibilityLabel("Alignment guides")
    view.setAccessibilityRole(.group)
    return view
  }

  func updateNSView(_ nsView: GuideOverlay, context: Context) {
    nsView.viewer = viewer
    nsView.needsDisplay = true
  }
}

final class GuideOverlay: NSView {
  weak var viewer: PDFViewingSession?

  override var acceptsFirstResponder: Bool { false }

  /// Display-only: never claim the pointer.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let viewer, let page = viewer.view.currentPage,
      viewer.areGuidesVisible
    else { return }
    let box = page.bounds(for: viewer.view.displayBox)
    guard box.width > 4, box.height > 4 else { return }
    let guides = PageGuides.lines(pageWidth: box.width, pageHeight: box.height)
    NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    let dash: [CGFloat] = [5, 4]
    path.setLineDash(dash, count: dash.count, phase: 0)
    // Map page fractions into view points (rotation may flip or swap axes,
    // so interpolate rather than assuming an orientation).
    let corners = [
      viewer.view.convert(CGPoint(x: box.minX, y: box.minY), from: page),
      viewer.view.convert(CGPoint(x: box.maxX, y: box.maxY), from: page),
    ]
    func viewPoint(pageX: Double, pageY: Double) -> NSPoint {
      let fx = box.width > 0 ? CGFloat((pageX - box.minX) / box.width) : 0
      let fy = box.height > 0 ? CGFloat((pageY - box.minY) / box.height) : 0
      return convert(
        NSPoint(
          x: corners[0].x + (corners[1].x - corners[0].x) * fx,
          y: corners[0].y + (corners[1].y - corners[0].y) * fy),
        from: viewer.view)
    }
    for x in guides.vertical {
      let top = viewPoint(pageX: x, pageY: box.maxY)
      let bottom = viewPoint(pageX: x, pageY: box.minY)
      path.move(to: bottom)
      path.line(to: top)
    }
    for y in guides.horizontal {
      let left = viewPoint(pageX: box.minX, pageY: y)
      let right = viewPoint(pageX: box.maxX, pageY: y)
      path.move(to: left)
      path.line(to: right)
    }
    path.stroke()
  }
}
