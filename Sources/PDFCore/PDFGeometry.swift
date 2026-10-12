import Foundation

/// P04-021: internal geometry types for exact PDF coordinate work. PDF
/// uses double-precision affine transforms everywhere; these types keep
/// that precision end to end (no integer truncation, no hidden rounding)
/// with deterministic IEEE semantics: identity, composition, and inversion
/// behave exactly, and callers convert to device pixels only at the final
/// step with an explicit rounding policy.
public struct PDFPoint: Sendable, Equatable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public func applying(_ matrix: PDFMatrix) -> PDFPoint {
    PDFPoint(
      x: matrix.a * x + matrix.c * y + matrix.tx,
      y: matrix.b * x + matrix.d * y + matrix.ty)
  }
}

public struct PDFRect: Sendable, Equatable {
  public let x0: Double
  public let y0: Double
  public let x1: Double
  public let y1: Double

  public init(x0: Double, y0: Double, x1: Double, y1: Double) {
    self.x0 = x0
    self.y0 = y0
    self.x1 = x1
    self.y1 = y1
  }

  public var normalized: PDFRect {
    PDFRect(
      x0: min(x0, x1), y0: min(y0, y1), x1: max(x0, x1), y1: max(y0, y1))
  }

  public var width: Double { x1 - x0 }
  public var height: Double { y1 - y0 }
  public var isEmpty: Bool { width <= 0 || height <= 0 }

  public func contains(_ point: PDFPoint) -> Bool {
    let bounds = normalized
    return point.x >= bounds.x0 && point.x <= bounds.x1
      && point.y >= bounds.y0 && point.y <= bounds.y1
  }

  public func union(_ other: PDFRect) -> PDFRect {
    let left = normalized
    let right = other.normalized
    return PDFRect(
      x0: min(left.x0, right.x0), y0: min(left.y0, right.y0),
      x1: max(left.x1, right.x1), y1: max(left.y1, right.y1))
  }

  /// Map all four corners and bound the results (correct for rotations that
  /// swap the axes).
  public func applying(_ matrix: PDFMatrix) -> PDFRect {
    let corners = [
      PDFPoint(x: x0, y: y0), PDFPoint(x: x1, y: y0),
      PDFPoint(x: x0, y: y1), PDFPoint(x: x1, y: y1),
    ].map { $0.applying(matrix) }
    let xs = corners.map(\.x)
    let ys = corners.map(\.y)
    return PDFRect(
      x0: xs.min() ?? 0, y0: ys.min() ?? 0, x1: xs.max() ?? 0,
      y1: ys.max() ?? 0)
  }
}

public struct PDFMatrix: Sendable, Equatable {
  public let a: Double
  public let b: Double
  public let c: Double
  public let d: Double
  public let tx: Double
  public let ty: Double

  public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
    self.a = a
    self.b = b
    self.c = c
    self.d = d
    self.tx = tx
    self.ty = ty
  }

  public static let identity = PDFMatrix(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

  public static func translation(x: Double, y: Double) -> PDFMatrix {
    PDFMatrix(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
  }

  public static func scale(x: Double, y: Double) -> PDFMatrix {
    PDFMatrix(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
  }

  /// Clockwise quarter-turns for page rotation, with exact (not
  /// trigonometric) entries.
  public static func quarterTurns(clockwise count: Int) -> PDFMatrix {
    switch ((count % 4) + 4) % 4 {
    case 1:
      return PDFMatrix(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
    case 2:
      return PDFMatrix(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
    case 3:
      return PDFMatrix(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    default:
      return .identity
    }
  }

  /// Concatenation: applying `self` then `next`.
  public func concatenating(_ next: PDFMatrix) -> PDFMatrix {
    PDFMatrix(
      a: a * next.a + b * next.c,
      b: a * next.b + b * next.d,
      c: c * next.a + d * next.c,
      d: c * next.b + d * next.d,
      tx: tx * next.a + ty * next.c + next.tx,
      ty: tx * next.b + ty * next.d + next.ty)
  }

  public var determinant: Double {
    a * d - b * c
  }

  /// The inverse, or nil for singular matrices (zero determinant) rather
  /// than infinities.
  public func inverted() -> PDFMatrix? {
    let determinant = determinant
    guard determinant != 0 else { return nil }
    return PDFMatrix(
      a: d / determinant, b: -b / determinant, c: -c / determinant,
      d: a / determinant,
      tx: (c * ty - d * tx) / determinant,
      ty: (b * tx - a * ty) / determinant)
  }
}
