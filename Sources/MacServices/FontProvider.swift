import AppKit
import CoreText
import Foundation
import PDFCore
import PDFEditing

/// P15-001–P15-005/P15-008/P15-025/P15-003: the macOS typography adapter.
/// CoreText provides shaping, glyph IDs, advances, and cluster mappings;
/// embedding permissions are recorded, never assumed. Direction and language
/// context are preserved for shaping; see `shape(_:fontName:pointSize:language:)`.
public struct FontProvider: Sendable {
  public struct ShapedGlyph: Sendable, Equatable {
    public let glyphID: UInt16
    public let advance: Double
    /// UTF-16 offsets of the source cluster (P15-025).
    public let clusterStart: Int
    public let clusterEnd: Int
    /// True when the glyph came from a fallback cascade rather than the
    /// requested font (P15-008).
    public let isFallback: Bool
  }

  public struct ShapedRun: Sendable, Equatable {
    public let fontName: String
    public let pointSize: Double
    public let glyphs: [ShapedGlyph]
    public let missingGlyphCount: Int
    /// P15-003: the paragraph base direction used for shaping ("ltr"/"rtl").
    public let direction: String
    /// P15-003: the validated BCP-47 language tag passed to shaping, or nil
    /// when none was supplied or the supplied tag was malformed.
    public let language: String?
    public var advance: Double { glyphs.reduce(0) { $0 + $1.advance } }
  }

  /// P15-005: what the system font may legally be used for.
  public struct PermissionRecord: Sendable, Equatable {
    public let fontName: String
    public let mayEmbedForPreview: Bool
    public let mayEmbedForEditing: Bool
    public let maySubset: Bool
    public let note: String

    public static func systemFont(_ name: String) -> PermissionRecord {
      // System fonts are usable for rendering but are not redistributable;
      // documents must not embed them as if they were licensed for it.
      PermissionRecord(
        fontName: name, mayEmbedForPreview: false, mayEmbedForEditing: false, maySubset: false,
        note: "System font: render-only; embedding/subsetting requires an explicitly licensed font file.")
    }

    public static func provisionedFont(_ name: String) -> PermissionRecord {
      // Fonts the user provisioned through the app (Google Fonts, OFL) permit
      // embedding and subsetting under their own license.
      PermissionRecord(
        fontName: name, mayEmbedForPreview: true, mayEmbedForEditing: true, maySubset: true,
        note: "User-provisioned font: embedding and subsetting follow the font's own license (for example OFL).")
    }
  }

  public init() {}

  /// P15-002/P15-003/P15-025: shape a string with the requested font (falling
  /// back through the system cascade), preserving cluster boundaries so
  /// selection mapping can reverse ligatures and combining sequences.
  /// P15-003: `language` is a BCP-47 tag (for example "en", "ar", "he")
  /// preserved as CoreText language context when well-formed; malformed tags
  /// are ignored rather than guessed. The paragraph base direction is derived
  /// from the text (RTL-majority non-whitespace content shapes as "rtl") so
  /// Hebrew/Arabic and mixed-script strings keep their script direction
  /// instead of being forced left-to-right.
  public func shape(
    _ text: String, fontName: String, pointSize: Double, language: String? = nil
  ) -> ShapedRun {
    let base = NSFont(name: fontName, size: pointSize)
      ?? NSFont(name: "Helvetica", size: pointSize)
      ?? NSFont.systemFont(ofSize: pointSize)
    let normalizedLanguage = Self.normalizedLanguage(language)
    let isRTL = Self.isRTLMajority(text)
    var attributes: [NSAttributedString.Key: Any] = [.font: base, .ligature: 1]
    var baseDirection: Int8 = isRTL ? 1 : 0
    withUnsafePointer(to: &baseDirection) { pointer in
      var setting = CTParagraphStyleSetting(
        spec: .baseWritingDirection,
        valueSize: MemoryLayout<Int8>.size,
        value: UnsafeRawPointer(pointer))
      let paragraphStyle = CTParagraphStyleCreate(&setting, 1)
      attributes[.paragraphStyle] = paragraphStyle
    }
    if let normalizedLanguage {
      attributes[NSAttributedString.Key(rawValue: kCTLanguageAttributeName as String)] =
        normalizedLanguage
    }
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    var glyphs: [ShapedGlyph] = []
    var missing = 0
    for run in runs {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      var glyphIDs = [CGGlyph](repeating: 0, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      var indices = [CFIndex](repeating: 0, count: count)
      CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphIDs)
      CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
      let runRange = CTRunGetStringRange(run)
      let runEnd = runRange.location + runRange.length
      // Logical boundaries within this run so reordered (RTL) glyphs still
      // map to the source range they came from: each cluster runs from its
      // start to the next boundary inside the run.
      var boundaries = Set(indices.map { Int($0) })
      boundaries.insert(runEnd)
      let sortedBoundaries = boundaries.sorted()
      let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? NSFont
      let isFallback = runFont?.fontName != base.fontName
      for index in 0..<count {
        let clusterStart = Int(indices[index])
        let clusterEnd = sortedBoundaries.first { $0 > clusterStart }
          ?? min(runEnd, clusterStart + 1)
        if glyphIDs[index] == 0 { missing += 1 }
        glyphs.append(
          ShapedGlyph(
            glyphID: glyphIDs[index], advance: Double(advances[index].width),
            clusterStart: clusterStart, clusterEnd: max(clusterEnd, clusterStart + 1),
            isFallback: isFallback))
      }
    }
    return ShapedRun(
      fontName: base.fontName, pointSize: pointSize, glyphs: glyphs,
      missingGlyphCount: missing,
      direction: text.isEmpty ? "ltr" : (isRTL ? "rtl" : "ltr"),
      language: normalizedLanguage)
  }

  /// P15-003: BCP-47 language tags preserved as shaping context
  /// ("en", "en-US", "ar"). Anything else returns nil.
  public static func normalizedLanguage(_ tag: String?) -> String? {
    guard let tag else { return nil }
    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 35 else { return nil }
    let pattern = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/
    guard trimmed.wholeMatch(of: pattern) != nil else { return nil }
    return trimmed
  }

  /// P15-003: right-to-left Unicode ranges (Hebrew, Arabic, Syriac, Thaana,
  /// N'Ko, Samaritan, Mandaic, and the RTL presentation forms), matching the
  /// export layer's ranges so shaping direction agrees with output tagging.
  public static func isRTLScalar(_ value: UInt32) -> Bool {
    switch value {
    case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F,
      0x0780...0x07BF, 0x07C0...0x07FF, 0x0800...0x083F, 0x0840...0x085F,
      0x0860...0x086F, 0x0870...0x089F, 0x08A0...0x08FF, 0xFB1D...0xFB4F,
      0xFB50...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
      return true
    default:
      return false
    }
  }

  /// P15-003: the paragraph base direction is RTL when at least half the
  /// non-whitespace scalars are RTL; empty and LTR-majority text stays LTR.
  public static func isRTLMajority(_ text: String) -> Bool {
    let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
    guard !scalars.isEmpty else { return false }
    let rtl = scalars.filter { isRTLScalar($0.value) }.count
    return rtl * 2 >= scalars.count
  }

  /// P15-004/P15-005: inventory installed font files with permission records.
  public func availableFonts(limit: Int = 2_000) -> [PermissionRecord] {
    var records: [PermissionRecord] = []
    let manager = NSFontManager.shared
    for family in manager.availableFontFamilies.prefix(limit) {
      records.append(PermissionRecord.systemFont(family))
    }
    return records
  }

  /// P15-008: the fallback family that will actually render a string, or nil
  /// when no installed font covers every character.
  public func coveringFont(for text: String, preferred: String? = nil) -> String? {
    let candidates = [preferred, "Helvetica", "Times-Roman", "Arial", "Menlo"].compactMap { $0 }
    for name in candidates {
      guard let font = NSFont(name: name, size: 12) else { continue }
      if text.unicodeScalars.allSatisfy({ font.coveredCharacterSet.contains($0) }) {
        return name
      }
    }
    return nil
  }

  /// P15-006/P15-008: the licensed fallback family to *embed* for `text`, or
  /// nil when no member of the licensed set qualifies. Unlike `coveringFont`
  /// (preview-only, system fonts allowed), this never returns a render-only
  /// system font: candidates come only from `LicensedFallbackSet`, in style
  /// preference order, and each candidate's real glyph coverage is verified
  /// before it is returned. `installed` and `covers` are injectable so tests
  /// never depend on machine state; when nil, installed CoreText fonts are
  /// queried directly.
  public func licensedFallback(
    for text: String,
    preferring style: LicensedFallbackFont.Style? = nil,
    installed: [String]? = nil,
    covers: ((String) -> Bool)? = nil
  ) -> String? {
    for member in LicensedFallbackSet.ordered(preferring: style) {
      if let installed, !installed.contains(member.family) { continue }
      let covered: Bool
      if let covers {
        covered = covers(member.family)
      } else if let font = NSFont(name: member.family, size: 12) {
        covered = text.unicodeScalars.allSatisfy { font.coveredCharacterSet.contains($0) }
      } else {
        continue
      }
      if covered { return member.family }
    }
    return nil
  }
}
