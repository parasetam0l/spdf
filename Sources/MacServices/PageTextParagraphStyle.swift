import AppKit
import Foundation

/// TXT-03: paragraph-level controls shown by the contextual text inspector.
/// Values are page-space points; `leading == 0` keeps the source line height.
public enum PageTextParagraphAlignment: String, CaseIterable, Sendable, Equatable {
  case left
  case center
  case right
  case justified

  public var title: String {
    switch self {
    case .left: return "Left"
    case .center: return "Center"
    case .right: return "Right"
    case .justified: return "Justified"
    }
  }

  public var symbol: String {
    switch self {
    case .left: return "text.alignleft"
    case .center: return "text.aligncenter"
    case .right: return "text.alignright"
    case .justified: return "text.justify"
    }
  }

  public var textAlignment: NSTextAlignment {
    switch self {
    case .left: return .left
    case .center: return .center
    case .right: return .right
    case .justified: return .justified
    }
  }
}

public struct PageTextParagraphStyle: Sendable, Equatable {
  public var alignment: PageTextParagraphAlignment
  /// Total line height in page-space points. Zero keeps the source spacing.
  public var leading: Double
  public var spacingBefore: Double
  public var spacingAfter: Double
  public var leftIndent: Double
  public var rightIndent: Double
  public var firstLineIndent: Double

  public init(
    alignment: PageTextParagraphAlignment = .left, leading: Double = 0,
    spacingBefore: Double = 0, spacingAfter: Double = 0,
    leftIndent: Double = 0, rightIndent: Double = 0, firstLineIndent: Double = 0
  ) {
    self.alignment = alignment
    self.leading = leading
    self.spacingBefore = spacingBefore
    self.spacingAfter = spacingAfter
    self.leftIndent = leftIndent
    self.rightIndent = rightIndent
    self.firstLineIndent = firstLineIndent
  }

  public var isValid: Bool {
    leading.isFinite && (0...1_000).contains(leading)
      && spacingBefore.isFinite && (0...500).contains(spacingBefore)
      && spacingAfter.isFinite && (0...500).contains(spacingAfter)
      && leftIndent.isFinite && (0...1_000).contains(leftIndent)
      && rightIndent.isFinite && (0...1_000).contains(rightIndent)
      && firstLineIndent.isFinite && (-1_000...1_000).contains(firstLineIndent)
  }

  /// Build the TextKit paragraph attributes for the current view scale. The
  /// editor stores font sizes in page space, so callers pass the page-to-view
  /// scale rather than the zoom factor alone.
  public func textKitStyle(
    scale: Double, fallbackLeading: Double, maximumLineHeight: Double? = nil
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment.textAlignment
    let height = max(1, (leading > 0 ? leading : fallbackLeading) * scale)
    style.minimumLineHeight = height
    style.maximumLineHeight = max(height, maximumLineHeight ?? height)
    style.paragraphSpacingBefore = max(0, spacingBefore) * scale
    style.paragraphSpacing = max(0, spacingAfter) * scale
    style.headIndent = max(0, leftIndent) * scale
    style.tailIndent = -max(0, rightIndent) * scale
    style.firstLineHeadIndent = firstLineIndent * scale
    return style
  }
}
