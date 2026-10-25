import Foundation

/// TXT-06: a page-text edit that cannot be committed as drawn. The draft stays
/// in the inline editor; these capabilities describe the safe corrections the
/// same draft can apply without discarding text.
public enum PageTextOverflowCause: String, Sendable, Equatable {
  /// Text is outside the source clipping rectangle.
  case clipping
  /// The replacement would overlap a neighboring text block.
  case collision
  /// A tagged paragraph cannot preserve its marked-content layout.
  case taggedLayout
  /// The writer refused for a different unsupported reason.
  case unsupported

  public var title: String {
    switch self {
    case .clipping: return "Text clipping"
    case .collision: return "Text collision"
    case .taggedLayout: return "Tagged layout"
    case .unsupported: return "Unsupported text layout"
    }
  }
}

/// A cause-specific overflow report with the corrections that are safe for
/// this document. `message` is user-facing; the capability flags prevent the
/// UI from offering an action that cannot respect a clip or tagged boundary.
public struct PageTextOverflowCorrection: Sendable, Equatable {
  public let cause: PageTextOverflowCause
  public let message: String
  public let canFitText: Bool
  public let canWidenBox: Bool
  public let canMoveInsideBoundary: Bool

  public init(
    cause: PageTextOverflowCause, message: String, canFitText: Bool,
    canWidenBox: Bool, canMoveInsideBoundary: Bool
  ) {
    self.cause = cause
    self.message = message
    self.canFitText = canFitText
    self.canWidenBox = canWidenBox
    self.canMoveInsideBoundary = canMoveInsideBoundary
  }

  /// Classify a failed paragraph rewrite. Only an overlap is an overflow the
  /// user can correct by changing geometry or size; tagged/unsupported
  /// refusals stay explicit and must not be misrepresented as a fit problem.
  public static func classify(error: Error) -> PageTextOverflowCorrection? {
    let message = error.localizedDescription
    let lower = message.lowercased()
    if lower.contains("overlap another text block") {
      return PageTextOverflowCorrection(
        cause: .collision, message: message, canFitText: true,
        canWidenBox: true, canMoveInsideBoundary: false)
    }
    if lower.contains("tagged paragraph") || lower.contains("tagged layout") {
      return PageTextOverflowCorrection(
        cause: .taggedLayout, message: message, canFitText: false,
        canWidenBox: false, canMoveInsideBoundary: false)
    }
    return nil
  }
}
