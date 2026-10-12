import CoreGraphics
import Foundation

/// P12-017: resize-handle geometry for selected app-created graphics. All
/// math is in one coordinate space (the caller converts); handles draw at
/// `handleVisualSize` points and hit-test at `handleHitSize` points, so the
/// visuals stay compact on a dense canvas while every target stays readable
/// to the pointer. This matches the toolbar precedent (P12-026), where hit
/// areas grow past their visuals.
public enum GraphicHandle: String, Sendable, Equatable, CaseIterable {
  case northWest
  case north
  case northEast
  case east
  case southEast
  case south
  case southWest
  case west
}

public enum GraphicSelectionModel {
  /// Drawn handle square, in points.
  public static let handleVisualSize: CGFloat = 12
  /// Hit-test square around each handle center, in points. Never below the
  /// visual size, so small selections stay grabbable.
  public static let handleHitSize: CGFloat = 24

  /// Handle centers for a view-space selection rect, in fixed reading order.
  public static func handleCenters(bounds: CGRect) -> [(GraphicHandle, CGPoint)] {
    let midX = bounds.midX
    let midY = bounds.midY
    return [
      (.northWest, CGPoint(x: bounds.minX, y: bounds.maxY)),
      (.north, CGPoint(x: midX, y: bounds.maxY)),
      (.northEast, CGPoint(x: bounds.maxX, y: bounds.maxY)),
      (.east, CGPoint(x: bounds.maxX, y: midY)),
      (.southEast, CGPoint(x: bounds.maxX, y: bounds.minY)),
      (.south, CGPoint(x: midX, y: bounds.minY)),
      (.southWest, CGPoint(x: bounds.minX, y: bounds.minY)),
      (.west, CGPoint(x: bounds.minX, y: midY)),
    ]
  }

  /// The handle under a view-space point, if any. Handles win over the body
  /// when regions overlap, so a grab near an edge resizes instead of moving.
  public static func handle(at point: CGPoint, selection bounds: CGRect) -> GraphicHandle? {
    let slop = max(handleHitSize, handleVisualSize) / 2
    for (handle, center) in handleCenters(bounds: bounds) {
      if abs(point.x - center.x) <= slop, abs(point.y - center.y) <= slop {
        return handle
      }
    }
    return nil
  }

  /// Whether a view-space point falls inside the selection body (for moves).
  public static func bodyContains(_ point: CGPoint, selection bounds: CGRect) -> Bool {
    bounds.insetBy(dx: -2, dy: -2).contains(point)
  }

  /// Indices of candidates intersecting a rubber-band rect (any overlap, in
  /// either space as long as both share it). Empty rects select nothing, so
  /// a click never multi-selects by accident.
  public static func rubberBandSelect(rect: CGRect, candidates: [CGRect]) -> [Int] {
    let normalized = rect.standardized
    guard normalized.width > 1, normalized.height > 1 else { return [] }
    var result: [Int] = []
    for (index, candidate) in candidates.enumerated() {
      if normalized.intersects(candidate.standardized) { result.append(index) }
    }
    return result
  }

  /// Resize mapping for a handle drag in page space: the translation plus the
  /// scale factors for `ScaleAddedGraphicCommand` (which scales about the
  /// graphic's own origin) composed with `MoveAddedGraphicCommand` for the
  /// origin shift. West/north sides move the origin, so they need both;
  /// east/south sides only scale. Returns nil when the start bounds are
  /// degenerate. Extents clamp to a 1-point minimum and non-finite input
  /// refuses, mirroring the command's own validation.
  public static func resize(
    handle: GraphicHandle, startBounds: CGRect, current: CGPoint, uniform: Bool = false
  ) -> (dx: Double, dy: Double, scaleX: Double, scaleY: Double)? {
    let start = startBounds.standardized
    guard start.width > 0, start.height > 0,
      current.x.isFinite, current.y.isFinite
    else { return nil }
    var minX = start.minX
    var minY = start.minY
    var maxX = start.maxX
    var maxY = start.maxY
    switch handle {
    case .northWest:
      minX = min(current.x, maxX - 1)
      maxY = max(current.y, minY + 1)
    case .north:
      maxY = max(current.y, minY + 1)
    case .northEast:
      maxX = max(current.x, minX + 1)
      maxY = max(current.y, minY + 1)
    case .east:
      maxX = max(current.x, minX + 1)
    case .southEast:
      maxX = max(current.x, minX + 1)
      minY = min(current.y, maxY - 1)
    case .south:
      minY = min(current.y, maxY - 1)
    case .southWest:
      minX = min(current.x, maxX - 1)
      minY = min(current.y, maxY - 1)
    case .west:
      minX = min(current.x, maxX - 1)
    }
    var scaleX = (maxX - minX) / start.width
    var scaleY = (maxY - minY) / start.height
    if uniform {
      // Shift constrains corner drags to a uniform scale; edge handles keep
      // their single-axis mapping.
      switch handle {
      case .northWest, .northEast, .southEast, .southWest:
        let uniformScale = max(scaleX, scaleY)
        scaleX = uniformScale
        scaleY = uniformScale
        // Re-derive the dragged edges from the uniform scale so the reported
        // translation matches the scale the command applies.
        switch handle {
        case .northWest:
          minX = maxX - start.width * uniformScale
          maxY = minY + start.height * uniformScale
        case .northEast:
          maxX = minX + start.width * uniformScale
          maxY = minY + start.height * uniformScale
        case .southEast:
          maxX = minX + start.width * uniformScale
          minY = maxY - start.height * uniformScale
        case .southWest:
          minX = maxX - start.width * uniformScale
          minY = maxY - start.height * uniformScale
        default:
          break
        }
      default:
        break
      }
    }
    guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
    return (
      dx: Double(minX - start.minX), dy: Double(minY - start.minY),
      scaleX: Double(scaleX), scaleY: Double(scaleY))
  }
}
