import Foundation
import PDFCore

/// FNT-07: the stable decomposition of one composed page-space text matrix.
public struct TextTransformDecomposition: Sendable, Equatable {
  /// Translation (e, f).
  public let translation: [Double]
  public let scaleX: Double
  public let scaleY: Double
  /// Normalized to (-180, 180].
  public let rotationDegrees: Double
  /// Normalized horizontal shear (c/a for horizontal text).
  public let horizontalShear: Double
  public let determinant: Double

  public init(
    translation: [Double], scaleX: Double, scaleY: Double, rotationDegrees: Double,
    horizontalShear: Double, determinant: Double
  ) {
    self.translation = translation
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.rotationDegrees = rotationDegrees
    self.horizontalShear = horizontalShear
    self.determinant = determinant
  }
}

/// FNT-07: why a transform cannot be represented faithfully by either text
/// writer profile. Each case has an explicit user-facing reason.
public enum TextTransformRefusal: Sendable, Equatable {
  case invalid
  case singular
  case flipped
  case nonUniformScale
  case verticalShear
  case excessiveShear
  case nearHorizontalRotation
  case rotationWithShear

  public var message: String {
    switch self {
    case .invalid:
      return "The text transform contains a non-finite value."
    case .singular:
      return "The text transform is singular and cannot be rendered or rewritten faithfully."
    case .flipped:
      return "The text transform mirrors the text; flipped text is not represented by either writer profile."
    case .nonUniformScale:
      return "The text transform scales horizontally and vertically by different amounts; non-uniform scaling is not represented faithfully."
    case .verticalShear:
      return "The text transform includes vertical shear; only bounded horizontal synthetic-italic shear is supported."
    case .excessiveShear:
      return "The text transform's horizontal shear is stronger than the supported 0.35 synthetic-italic bound."
    case .nearHorizontalRotation:
      return "The text transform is rotated by too small an angle for either the horizontal or the rotated text profile."
    case .rotationWithShear:
      return "The text transform combines rotation with shear; that combination is not represented faithfully."
    }
  }
}

/// FNT-07: one supported transform profile. The profiles match what the writers
/// actually emit, so a supported preview is the same transform the saved PDF
/// keeps.
public enum TextTransformProfile: Sendable, Equatable {
  /// Horizontal page-space text with no shear (inline paragraph writer).
  case horizontal
  /// Horizontal text with bounded synthetic-italic shear (inline paragraph
  /// writer stores it as a text matrix).
  case horizontalShear(Double)
  /// Rotation with a positive uniform scale (run-level replacement keeps the
  /// run's text matrix).
  case rotated(degrees: Double, scale: Double)
  case unsupported(TextTransformRefusal)

  public var isSupported: Bool {
    if case .unsupported = self { return false }
    return true
  }

  /// The inline paragraph writer can carry horizontal text and bounded
  /// horizontal shear, but not rotation.
  public var supportsInlineParagraph: Bool {
    switch self {
    case .horizontal, .horizontalShear: return true
    default: return false
    }
  }

  /// Run-level replacement preserves the run's text matrix, so rotation and
  /// horizontal shear are both supported there.
  public var supportsRunReplacement: Bool {
    switch self {
    case .horizontal, .horizontalShear, .rotated: return true
    case .unsupported: return false
    }
  }
}

/// FNT-07: what a caller wants to do with the text.
public enum TextTransformUse: String, Sendable, Equatable {
  case inlineParagraph
  case runReplacement
  /// A preview may only use the profile the writer will save; unsupported
  /// transforms must be refused instead of approximately previewed.
  case preview
}

/// FNT-07: the complete capability result for one composed text matrix.
public struct TextTransformCapability: Sendable, Equatable {
  public let transform: [Double]
  public let decomposition: TextTransformDecomposition?
  public let profile: TextTransformProfile

  public init(
    transform: [Double], decomposition: TextTransformDecomposition?,
    profile: TextTransformProfile
  ) {
    self.transform = transform
    self.decomposition = decomposition
    self.profile = profile
  }

  public var isSupported: Bool { profile.isSupported }

  public var refusalMessage: String? {
    if case .unsupported(let refusal) = profile { return refusal.message }
    return nil
  }

  /// Preview is allowed only when the final writer for the intended use is
  /// available; this keeps previews and saved output on one capability result.
  public func supports(_ use: TextTransformUse) -> Bool {
    switch use {
    case .inlineParagraph: return profile.supportsInlineParagraph
    case .runReplacement: return profile.supportsRunReplacement
    case .preview: return profile.isSupported
    }
  }

  /// Which uses are supported, for capability reports.
  public var supportedUses: [TextTransformUse] {
    [.inlineParagraph, .runReplacement, .preview].filter { supports($0) }
  }
}

/// FNT-07: one place that classifies composed page-space text matrices for
/// preview, inline paragraph editing and run replacement. The thresholds mirror
/// the existing writers (uniform positive scale, bounded horizontal shear
/// |k| <= 0.35, pure rotation with positive uniform scale).
public enum TextTransformInspector {
  public static let maximumHorizontalShear = 0.35
  public static let minimumRotationDegrees = 0.05
  private static let epsilon = 1e-6

  public static func inspect(transform: [Double]) -> TextTransformCapability {
    guard transform.count == 6, transform.allSatisfy(\.isFinite) else {
      return TextTransformCapability(
        transform: transform, decomposition: nil, profile: .unsupported(.invalid))
    }
    let a = transform[0], b = transform[1], c = transform[2]
    let d = transform[3], e = transform[4], f = transform[5]
    let scaleX = hypot(a, b)
    let scaleY = hypot(c, d)
    let determinant = a * d - b * c
    let scale = max(scaleX, scaleY)
    let tolerance = max(1e-4, scale * 1e-3)
    var degrees = atan2(b, a) * 180 / .pi
    if degrees > 180 { degrees -= 360 }
    if degrees <= -180 { degrees += 360 }
    let shear = scaleX > epsilon ? (a * c + b * d) / (scaleX * scaleX) : 0
    let decomposition = TextTransformDecomposition(
      translation: [e, f], scaleX: scaleX, scaleY: scaleY,
      rotationDegrees: degrees, horizontalShear: shear, determinant: determinant)

    guard scale > epsilon else {
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .unsupported(.singular))
    }
    guard abs(determinant) > max(1e-10, scale * scale * 1e-6) else {
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .unsupported(.singular))
    }
    guard determinant > 0 else {
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .unsupported(.flipped))
    }
    let magnitude = abs(degrees)
    // Match the inline writer's exact horizontal profile first: positive a,
    // d == a, no vertical shear, bounded horizontal shear.
    if a > 0, abs(a - d) < epsilon, abs(b) < epsilon {
      let obliqueness = c / a
      guard obliqueness.isFinite, abs(obliqueness) <= maximumHorizontalShear else {
        return TextTransformCapability(
          transform: transform, decomposition: decomposition,
          profile: .unsupported(.excessiveShear))
      }
      if abs(obliqueness) < epsilon {
        return TextTransformCapability(
          transform: transform, decomposition: decomposition, profile: .horizontal)
      }
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .horizontalShear(obliqueness))
    }
    // Pure vertical shear of horizontal text (d == a, nonzero b, no
    // horizontal component in the second column) is named explicitly. A
    // near-horizontal pure rotation has c == -b and is diagnosed later.
    let nearHorizontalRotation =
      magnitude < minimumRotationDegrees && abs(c + b) <= tolerance
    if a > 0, abs(a - d) < epsilon, abs(b) >= epsilon, abs(c) <= tolerance,
      !nearHorizontalRotation
    {
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .unsupported(.verticalShear))
    }
    // Match the rotated writer profile: equal positive column scales, no
    // shear, positive determinant and at least the minimum rotation.
    let rotatedShear = abs(a * c + b * d) / (scale * scale)
    if abs(scaleX - scaleY) <= tolerance,
      rotatedShear <= tolerance / max(1, scale), magnitude >= minimumRotationDegrees
    {
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .rotated(degrees: degrees, scale: scale))
    }
    // Diagnostics for the writer refusals, ordered by what the matrix means.
    if magnitude < minimumRotationDegrees {
      if abs(a - d) < epsilon, abs(b) >= epsilon {
        // A pure near-horizontal rotation has c == -b; a vertical shear does
        // not.
        if nearHorizontalRotation {
          return TextTransformCapability(
            transform: transform, decomposition: decomposition,
            profile: .unsupported(.nearHorizontalRotation))
        }
        return TextTransformCapability(
          transform: transform, decomposition: decomposition,
          profile: .unsupported(.verticalShear))
      }
      if a > 0, abs(a - d) < epsilon, abs(b) < epsilon,
        abs(c / a) > maximumHorizontalShear
      {
        return TextTransformCapability(
          transform: transform, decomposition: decomposition,
          profile: .unsupported(.excessiveShear))
      }
      if abs(scaleX - scaleY) > tolerance
        || (a > 0 && abs(a - d) >= epsilon && abs(b) < epsilon)
      {
        return TextTransformCapability(
          transform: transform, decomposition: decomposition,
          profile: .unsupported(.nonUniformScale))
      }
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .unsupported(.nearHorizontalRotation))
    }
    if abs(scaleX - scaleY) > tolerance {
      return TextTransformCapability(
        transform: transform, decomposition: decomposition,
        profile: .unsupported(.nonUniformScale))
    }
    return TextTransformCapability(
      transform: transform, decomposition: decomposition,
      profile: .unsupported(.rotationWithShear))
  }

  /// Classify the composed matrix of a text run (CTM * text matrix).
  public static func inspect(ctm: [Double], textMatrix: [Double]) -> TextTransformCapability {
    guard ctm.count == 6, textMatrix.count == 6,
      ctm.allSatisfy(\.isFinite), textMatrix.allSatisfy(\.isFinite)
    else {
      return TextTransformCapability(
        transform: [], decomposition: nil, profile: .unsupported(.invalid))
    }
    let composed = [
      ctm[0] * textMatrix[0] + ctm[2] * textMatrix[1],
      ctm[1] * textMatrix[0] + ctm[3] * textMatrix[1],
      ctm[0] * textMatrix[2] + ctm[2] * textMatrix[3],
      ctm[1] * textMatrix[2] + ctm[3] * textMatrix[3],
      ctm[0] * textMatrix[4] + ctm[2] * textMatrix[5] + ctm[4],
      ctm[1] * textMatrix[4] + ctm[3] * textMatrix[5] + ctm[5],
    ]
    return inspect(transform: composed)
  }
}
