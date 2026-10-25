import Foundation
import PDFCore

/// PAG-06/PAG-07: persisted settings for one applied repeated-mark set.
///
/// Every mark content stream stores this document as JSON under the
/// `SPDFMarkSpec` key. That lets an applied set be discovered, verified and
/// updated in place after Save and reopen instead of stacking a second paint.
/// Sets written before this key existed remain removable but are reported as
/// not editable: their original text, style and placement cannot be
/// reconstructed reliably from the painted content alone.
public struct RepeatedMarkSpec: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case watermark
    case header
    case footer
    case pageNumber
    case bates

    public var displayName: String {
      switch self {
      case .watermark: return "Watermark"
      case .header: return "Header"
      case .footer: return "Footer"
      case .pageNumber: return "Page number"
      case .bates: return "Bates numbering"
      }
    }
  }

  /// Dictionary key used inside each mark content stream.
  static let streamKey = PDFName("SPDFMarkSpec")

  public let kind: Kind
  /// Watermark/header/footer text, the page-number template, or the Bates
  /// prefix.
  public let text: String
  /// Bates suffix (empty for every other kind).
  public let suffix: String
  public let familyName: String
  public let bold: Bool
  public let italic: Bool
  public let size: Double
  public let color: [Double]
  public let alignment: String
  public let lineSpacing: Double
  public let opacity: Double
  public let angle: Double
  public let offset: Int
  public let start: Int
  public let digits: Int
  public let margin: Double
  public let placement: RepeatedMarkPlacement
  /// True when the set was authored with a caller-supplied font program. Such
  /// sets are removable but not editable in place, because the original font
  /// program is not part of this settings record.
  public let usesCustomFont: Bool

  public init(
    mark: RepeatedMark, margin: Double, placement: RepeatedMarkPlacement,
    usesCustomFont: Bool
  ) {
    let style = mark.style
    self.familyName = style.family.rawValue
    self.bold = style.bold
    self.italic = style.italic
    self.size = style.size
    self.color = style.color
    self.alignment = style.alignment.rawValue
    self.lineSpacing = style.lineSpacing
    self.opacity = style.opacity
    self.margin = margin
    self.placement = placement
    self.usesCustomFont = usesCustomFont
    switch mark {
    case .watermark(let text, _, let angle):
      self.kind = .watermark
      self.text = text
      self.suffix = ""
      self.angle = angle
      self.offset = 0
      self.start = 0
      self.digits = 0
    case .header(let text, _):
      self.kind = .header
      self.text = text
      self.suffix = ""
      self.angle = 0
      self.offset = 0
      self.start = 0
      self.digits = 0
    case .footer(let text, _):
      self.kind = .footer
      self.text = text
      self.suffix = ""
      self.angle = 0
      self.offset = 0
      self.start = 0
      self.digits = 0
    case .pageNumber(let text, _, let offset):
      self.kind = .pageNumber
      self.text = text
      self.suffix = ""
      self.angle = 0
      self.offset = offset
      self.start = 0
      self.digits = 0
    case .bates(let prefix, let suffix, let start, let digits, _):
      self.kind = .bates
      self.text = prefix
      self.suffix = suffix
      self.angle = 0
      self.offset = 0
      self.start = start
      self.digits = digits
    }
  }

  /// Rebuild the mark for an in-place update.
  public func makeMark() -> RepeatedMark {
    let style = AddedTextStyle(
      family: AddedTextStyle.Family(rawValue: familyName) ?? .helvetica,
      bold: bold, italic: italic, size: size, color: color,
      alignment: TextParagraphCandidate.Alignment(rawValue: alignment) ?? .left,
      lineSpacing: lineSpacing, opacity: opacity)
    switch kind {
    case .watermark:
      return .watermark(text: text, style: style, angle: angle)
    case .header:
      return .header(text: text, style: style)
    case .footer:
      return .footer(text: text, style: style)
    case .pageNumber:
      return .pageNumber(text: text, style: style, offset: offset)
    case .bates:
      return .bates(prefix: text, suffix: suffix, start: start, digits: digits, style: style)
    }
  }

  /// PAG-06/PAG-07: the text this set should paint on one page.
  public func expectedText(pageIndex: Int, pageCount: Int) -> String {
    makeMark().text(pageIndex: pageIndex, pageCount: pageCount)
  }

  /// PAG-06: short human-readable label for an applied set.
  public var displayLabel: String {
    let sample = (text + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
    return sample.isEmpty ? kind.displayName : "\(kind.displayName): \(sample.prefix(48))"
  }

  /// Encode the settings for storage inside each mark stream.
  public func jsonData() throws -> Data {
    let object: [String: Any] = [
      "version": 1,
      "kind": kind.rawValue,
      "text": text,
      "suffix": suffix,
      "family": familyName,
      "bold": bold,
      "italic": italic,
      "size": size,
      "color": color,
      "alignment": alignment,
      "lineSpacing": lineSpacing,
      "opacity": opacity,
      "angle": angle,
      "offset": offset,
      "start": start,
      "digits": digits,
      "margin": margin,
      "placement": placement.rawValue,
      "usesCustomFont": usesCustomFont,
    ]
    do {
      return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    } catch {
      throw PDFError(.malformed, "The page mark settings could not be stored")
    }
  }

  /// Decode settings from a mark stream. Returns nil for missing or malformed
  /// records so older documents stay readable and removable.
  public static func decode(_ data: Data) -> RepeatedMarkSpec? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let kindName = dictionary["kind"] as? String,
      let kind = Kind(rawValue: kindName)
    else { return nil }
    func string(_ key: String, _ fallback: String) -> String {
      dictionary[key] as? String ?? fallback
    }
    func number(_ key: String, _ fallback: Double) -> Double {
      (dictionary[key] as? NSNumber)?.doubleValue ?? fallback
    }
    func integer(_ key: String, _ fallback: Int) -> Int {
      (dictionary[key] as? NSNumber)?.intValue ?? fallback
    }
    func boolean(_ key: String, _ fallback: Bool) -> Bool {
      (dictionary[key] as? NSNumber)?.boolValue ?? fallback
    }
    let text = string("text", "")
    let suffix = string("suffix", "")
    let size = number("size", 12)
    let lineSpacing = number("lineSpacing", 1.2)
    let opacity = number("opacity", 1)
    let angle = number("angle", 0)
    let offset = integer("offset", 0)
    let start = integer("start", 1)
    let digits = integer("digits", 6)
    let margin = number("margin", 36)
    let color: [Double]
    if let values = dictionary["color"] as? [Any] {
      color = values.compactMap { ($0 as? NSNumber)?.doubleValue }
    } else {
      color = [0, 0, 0]
    }
    let placement =
      RepeatedMarkPlacement(rawValue: string("placement", ""))
      ?? (kind == .header ? .topCenter : .bottomCenter)
    guard size.isFinite, (2...400).contains(size),
      lineSpacing.isFinite, (0.5...10).contains(lineSpacing),
      opacity.isFinite, (0...1).contains(opacity),
      margin.isFinite, (0...500).contains(margin),
      angle.isFinite,
      abs(offset) <= 1_000_000,
      start >= 0,
      kind != .bates || (1...12).contains(digits),
      color.count == 3, color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
      text.utf8.count <= 10_000,
      suffix.utf8.count <= 200
    else { return nil }
    // Rebuild through the mark model so the stored style stays representable.
    let spec = RepeatedMarkSpec(
      kind: kind, text: text, suffix: suffix,
      familyName: string("family", AddedTextStyle.Family.helvetica.rawValue),
      bold: boolean("bold", false), italic: boolean("italic", false),
      size: size, color: color, alignment: string("alignment", "left"),
      lineSpacing: lineSpacing, opacity: opacity, angle: angle, offset: offset,
      start: start, digits: digits, margin: margin, placement: placement,
      usesCustomFont: boolean("usesCustomFont", false))
    return spec
  }

  private init(
    kind: Kind, text: String, suffix: String, familyName: String, bold: Bool,
    italic: Bool, size: Double, color: [Double], alignment: String,
    lineSpacing: Double, opacity: Double, angle: Double, offset: Int, start: Int,
    digits: Int, margin: Double, placement: RepeatedMarkPlacement,
    usesCustomFont: Bool
  ) {
    self.kind = kind
    self.text = text
    self.suffix = suffix
    self.familyName = familyName
    self.bold = bold
    self.italic = italic
    self.size = size
    self.color = color
    self.alignment = alignment
    self.lineSpacing = lineSpacing
    self.opacity = opacity
    self.angle = angle
    self.offset = offset
    self.start = start
    self.digits = digits
    self.margin = margin
    self.placement = placement
    self.usesCustomFont = usesCustomFont
  }
}
