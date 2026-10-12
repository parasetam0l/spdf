import CoreGraphics
import Foundation

/// P12-018: one ruler tick — its page-space value and whether it carries a
/// label. Views map values to positions; the mapping stays correct for
/// flipped and rotated pages because the session measures axis directions.
public struct RulerTickValue: Sendable, Equatable {
  public let value: Double
  public let labeled: Bool

  public init(value: Double, labeled: Bool) {
    self.value = value
    self.labeled = labeled
  }
}

public enum PageRulers {
  /// Tick step ladder in page points (1/2/5 powers of ten).
  private static let ladder: [Double] = [
    1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000,
  ]

  /// The minor tick step for a scale so ticks sit 24–192 view points apart.
  public static func step(forScale scale: Double) -> Double {
    let clamped = max(0.02, scale)
    for candidate in ladder {
      if candidate * clamped >= 24 { return candidate }
    }
    return ladder.last!
  }

  /// Tick values covering the page-space range `range` at `scale`. Every
  /// fifth tick is labeled. Bounded so hostile inputs cannot allocate
  /// unbounded arrays.
  public static func values(
    in range: ClosedRange<Double>, scale: Double, maxTicks: Int = 4000
  ) -> [RulerTickValue] {
    let clampedScale = max(0.02, scale)
    guard range.lowerBound <= range.upperBound, maxTicks > 0 else { return [] }
    let step = step(forScale: clampedScale)
    let first = Int(floor(range.lowerBound / step))
    let count = Int(ceil(range.upperBound / step)) - first + 1
    guard count > 0, count <= maxTicks else { return [] }
    return (0..<count).map { offset in
      let index = first + offset
      return RulerTickValue(value: Double(index) * step, labeled: index % 5 == 0)
    }
  }

  /// View position for a tick value along one axis: `origin` is the
  /// page-space value at the ruler edge, `direction` is +1/-1 measured live
  /// (0 yields no position), and `scale` is view points per page point.
  public static func position(
    value: Double, origin: Double, direction: Double, scale: Double
  ) -> Double? {
    guard direction != 0 else { return nil }
    return (value - origin) * direction * max(0.02, scale)
  }

  /// Page-space range visible along one axis from the edge `origin` in the
  /// measured `direction` over `length` view points at `scale`.
  public static func visibleRange(
    origin: Double, direction: Double, scale: Double, length: Double
  ) -> ClosedRange<Double>? {
    guard direction != 0, length > 0 else { return nil }
    let span = length / max(0.02, scale)
    if direction > 0 {
      return origin...(origin + span)
    } else {
      return (origin - span)...origin
    }
  }
}

/// P12-018: snapping guide lines for a page size in page points — centerlines
/// plus a 36 pt inset frame (dropped where the page is too narrow to hold
/// them distinctly). Rendered as an overlay; the `AddedContent.snap` math
/// consumes guide points for placement.
public enum PageGuides {
  public static let inset = 36.0

  public static func lines(pageWidth: Double, pageHeight: Double) -> (
    vertical: [Double], horizontal: [Double]
  ) {
    func distinct(_ values: [Double], limit: Double) -> [Double] {
      values.filter { $0 > 0.5 && $0 < limit - 0.5 }
        .sorted()
        .reduce(into: [Double]()) { unique, value in
          if unique.last.map({ abs($0 - value) > 0.5 }) ?? true {
            unique.append(value)
          }
        }
    }
    // The inset frame needs room on both sides; narrow pages keep only the
    // centerline.
    func axis(limit: Double) -> [Double] {
      var values = [limit / 2]
      if limit > inset * 2 {
        values += [inset, limit - inset]
      }
      return distinct(values, limit: limit)
    }
    return (vertical: axis(limit: pageWidth), horizontal: axis(limit: pageHeight))
  }
}
