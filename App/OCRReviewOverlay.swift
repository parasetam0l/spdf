import AppKit
import MacServices
import PDFCore
import PDFKit

/// OCR-03: the page overlay for the review queue. Suspect word boxes are drawn
/// over the recognized page; the current word is highlighted more strongly.
/// The view is click-through and never edits the page.
@MainActor
final class OCRReviewOverlayView: NSView {
  weak var viewer: PDFViewingSession?
  private var pageIndex = 0
  private var suspectRects: [[Double]] = []
  private var currentRect: [Double]?

  override var isFlipped: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(pageIndex: Int, suspectRects: [[Double]], currentRect: [Double]?) {
    self.pageIndex = pageIndex
    self.suspectRects = suspectRects
    self.currentRect = currentRect
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let viewer, let document = viewer.view.document,
      let page = viewer.view.currentPage,
      document.index(for: page) == pageIndex
    else { return }
    let fill = NSColor.systemOrange.withAlphaComponent(0.16)
    let stroke = NSColor.systemOrange.withAlphaComponent(0.85)
    for pageRect in suspectRects {
      let rect = viewRect(pageRect, page: page)
      guard rect.width > 0.5, rect.height > 0.5 else { continue }
      fill.setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
      stroke.setStroke()
      let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
      path.lineWidth = 1
      path.stroke()
    }
    if let currentRect {
      let rect = viewRect(currentRect, page: page)
      guard rect.width > 0.5, rect.height > 0.5 else { return }
      NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3).fill()
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3)
      path.lineWidth = 2
      path.stroke()
    }
  }

  private func viewRect(_ pageRect: [Double], page: PDFPage) -> NSRect {
    guard pageRect.count == 4, pageRect.allSatisfy(\.isFinite) else { return .zero }
    let rect = NSRect(
      x: pageRect[0], y: pageRect[1],
      width: pageRect[2] - pageRect[0], height: pageRect[3] - pageRect[1])
    return viewer?.view.convert(rect, from: page) ?? .zero
  }
}
