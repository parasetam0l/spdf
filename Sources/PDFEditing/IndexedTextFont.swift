import Foundation
import CoreGraphics
import PDFCore

/// The page's existing font resource. Reusing it never embeds a replacement
/// program or invents codes for glyphs absent from a subset.
public struct PageTextSourceFont: Sendable, Equatable {
  public let resource: PDFName
  public let name: String
  public init(resource: PDFName, name: String) { self.resource = resource; self.name = name }

  /// Recover common face traits from the embedded PDF font's PostScript or
  /// subset name so a replacement font can retain the paragraph's weight.
  public var isBold: Bool {
    let face = name.split(separator: "+", maxSplits: 1).last.map(String.init) ?? name
    let normalized = face.lowercased()
    return normalized.contains("bold") || normalized.contains("black")
      || normalized.contains("heavy")
  }

  public var isItalic: Bool {
    let face = name.split(separator: "+", maxSplits: 1).last.map(String.init) ?? name
    let normalized = face.lowercased()
    return normalized.contains("italic") || normalized.contains("oblique")
  }

  /// This writer reuses individual horizontal glyphs; it does not reorder
  /// bidirectional text or position combining/contextual glyph clusters.
  public static func canWriteInline(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { scalar in
      guard !CharacterSet.controlCharacters.contains(scalar),
        !CharacterSet.nonBaseCharacters.contains(scalar) else { return false }
      switch scalar.value {
      case 0x20...0x024F, 0x0370...0x052F, 0x1F00...0x1FFF,
        0x2000...0x206F, 0x20A0...0x214F, 0xFB00...0xFB06: return true
      default: return false
      }
    }
  }
}

public struct PageTextFontProfile: Sendable, Equatable {
  public struct Glyph: Sendable, Equatable {
    public let id: Int?
    public let width: Double
    public let codes: [UInt8]
  }
  public let source: PageTextSourceFont
  public let program: Data
  public let glyphs: [String: Glyph]
}

/// Shared indexing/measurement for simple fonts and horizontal Identity-H
/// TrueType subsets. Legacy simple-font commands keep their own edit gates.
struct IndexedTextFont {
  struct Glyph {
    let text: String
    let codes: [UInt8]
    let width: Double?
  }
  let simple: SimpleFont?
  let resource: PDFName
  let fontID: PDFObjectID
  let baseFont: String
  private let mapping: [Int: String]
  private let encoding: [String: Int]
  private let widths: [Int: Double]
  private let defaultWidth: Double
  private let gids: [UInt8]?
  private let program: Data?

  static func resolve(resource: PDFName, page: [PDFName: PDFValue], in graph: PDFGraph) -> Self? {
    func dictionary(_ value: PDFValue?) -> [PDFName: PDFValue]? {
      guard case .dictionary(let d)? = FontValue.resolve(value, in: graph) else { return nil }
      return d
    }
    func stream(_ value: PDFValue?) -> Data? {
      guard case .stream(let stream)? = FontValue.resolve(value, in: graph) else { return nil }
      return try? PDFFilters.decoded(stream)
    }
    guard let resources = dictionary(page[PDFName("Resources")]),
      let fonts = dictionary(resources[PDFName("Font")]), let entry = fonts[resource],
      let font = dictionary(entry) else { return nil }
    let simple = SimpleFont.resolve(resource: resource, page: page, in: graph)
    let fontID: PDFObjectID
    if case .reference(let id) = entry { fontID = id }
    else if let simple { fontID = simple.fontID }
    else { return nil }
    var descriptor = dictionary(font[PDFName("FontDescriptor")])
    var mappings: [Int: String] = [:]
    var widths: [Int: Double] = [:]
    var fallback = 0.0
    var gids: [UInt8]?
    let name: String
    if let simple {
      name = simple.baseFont
    } else {
      guard let composite = CompositeFont.parse(font, in: graph, objectID: fontID),
        let mapping = composite.identityMappings, !mapping.isEmpty,
        case .array(let descendants)? = FontValue.resolve(font[PDFName("DescendantFonts")], in: graph),
        let descendant = dictionary(descendants.first),
        descendant[PDFName("Subtype")] == .name(PDFName("CIDFontType2")),
        composite.defaultWidth.isFinite, composite.defaultWidth >= 0
      else { return nil }
      name = composite.baseFont; mappings = mapping; fallback = composite.defaultWidth
      descriptor = dictionary(descendant[PDFName("FontDescriptor")])
      switch FontValue.resolve(descendant[PDFName("CIDToGIDMap")], in: graph) {
      case nil, .name(PDFName("Identity"))?: break
      case .stream?:
        guard let data = stream(descendant[PDFName("CIDToGIDMap")]), data.count <= 131_072,
          data.count.isMultiple(of: 2) else { return nil }
        gids = [UInt8](data)
      default: return nil
      }
      if descendant[PDFName("CIDToGIDMap")] != nil &&
        FontValue.resolve(descendant[PDFName("CIDToGIDMap")], in: graph) == nil { return nil }
      if descendant[PDFName("W")] != nil {
        guard case .array(let values)? = FontValue.resolve(descendant[PDFName("W")], in: graph) else { return nil }
        var cursor = 0
        while cursor < values.count {
          guard case .integer(let first)? = FontValue.resolve(values[cursor], in: graph), (0...65_535).contains(first),
            cursor + 1 < values.count else { return nil }
          cursor += 1
          if case .array(let entries)? = FontValue.resolve(values[cursor], in: graph) {
            guard first + Int64(entries.count) <= 65_536 else { return nil }
            for (offset, value) in entries.enumerated() {
              guard let resolved = FontValue.resolve(value, in: graph),
                let width = number(resolved), width.isFinite, width >= 0 else { return nil }
              widths[Int(first) + offset] = width
            }
            cursor += 1
          } else {
            guard case .integer(let last)? = FontValue.resolve(values[cursor], in: graph), last >= first, last <= 65_535,
              cursor + 1 < values.count, let resolved = FontValue.resolve(values[cursor + 1], in: graph),
              let width = number(resolved),
              width.isFinite, width >= 0 else { return nil }
            for code in Int(first)...Int(last) { widths[code] = width }
            cursor += 2
          }
        }
      }
    }
    var encoding: [String: Int] = [:]
    for (code, text) in mappings.sorted(by: { $0.key < $1.key })
      where text.unicodeScalars.count == 1 && encoding[text] == nil { encoding[text] = code }
    return Self(simple: simple, resource: resource, fontID: fontID, baseFont: name,
      mapping: mappings, encoding: encoding, widths: widths, defaultWidth: fallback, gids: gids,
      program: stream(descriptor?[PDFName("FontFile2")])
        ?? stream(descriptor?[PDFName("FontFile3")]))
  }

  private static func number(_ value: PDFValue) -> Double? {
    switch value { case .real(let n): return n; case .integer(let n): return Double(n); default: return nil }
  }
  var isSupported: Bool { simple?.isSupported ?? !mapping.isEmpty }
  var isInlineEditable: Bool { simple.map { $0.isEditable && !$0.isType3 } ?? (program != nil) }

  /// Read-only outline metrics for collision checks. This deliberately does
  /// not apply the font embedding-permission gate used by the writer: reading
  /// an already embedded outline to check ink geometry does not embed it.
  var outlineMetrics: TrueTypeOutlineMetrics? {
    guard let program else { return nil }
    return try? TrueTypeOutlineMetrics(program: program, requireUnicodeMap: false)
  }

  /// Resolve a source PDF character code through the font's actual
  /// code-to-glyph mapping, including CIDToGIDMap for Identity-H fonts.
  func outlineGlyphID(for glyph: Glyph, inspector: TrueTypeInspector) -> Int? {
    guard !glyph.text.isEmpty else { return nil }
    let glyphID: Int
    if simple != nil {
      guard glyph.codes.count == 1, let width = glyph.width,
        let verified = Self.verifiedSimpleGlyphID(text: glyph.text,
          code: Int(glyph.codes[0]), width: width, inspector: inspector) else { return nil }
      glyphID = verified
    } else {
      guard glyph.text.unicodeScalars.count == 1 else { return nil }
      guard glyph.codes.count == 2 else { return nil }
      let cid = Int(glyph.codes[0]) * 256 + Int(glyph.codes[1])
      if let gids {
        guard cid * 2 + 1 < gids.count else { return nil }
        glyphID = Int(gids[cid * 2]) * 256 + Int(gids[cid * 2 + 1])
      } else {
        glyphID = cid
      }
    }
    guard glyphID > 0, glyphID < inspector.glyphCount else { return nil }
    return glyphID
  }

  func glyphs(_ codes: [UInt8]) -> [Glyph]? {
    if let simple {
      return codes.map { Glyph(text: simple.decode([$0]), codes: [$0], width: simple.width(of: $0)) }
    }
    guard codes.count.isMultiple(of: 2) else { return nil }
    var result: [Glyph] = []
    for offset in stride(from: 0, to: codes.count, by: 2) {
      let code = Int(codes[offset]) * 256 + Int(codes[offset + 1])
      guard let text = mapping[code] else { return nil }
      result.append(Glyph(text: text, codes: Array(codes[offset..<offset + 2]),
        width: widths[code] ?? defaultWidth))
    }
    return result
  }
  func decode(_ codes: [UInt8]) -> String { glyphs(codes)?.map(\.text).joined() ?? "\u{FFFD}" }
  func encode(_ text: String) -> [UInt8]? {
    if let simple { return simple.encode(text) }
    var result: [UInt8] = []
    for scalar in text.unicodeScalars {
      guard let code = encoding[String(scalar)] else { return nil }
      result += [UInt8(code >> 8), UInt8(code & 255)]
    }
    return result
  }

  static func verifiedSimpleGlyphID(scalar: Int, code: Int, width: Double,
    inspector: TrueTypeInspector) -> Int? {
    guard let unicode = UnicodeScalar(scalar) else { return nil }
    return verifiedSimpleGlyphID(text: String(unicode), code: code,
      width: width, inspector: inspector)
  }

  static func verifiedSimpleGlyphID(text: String, code: Int, width: Double,
    inspector: TrueTypeInspector) -> Int? {
    guard !inspector.isCFF, inspector.unitsPerEm > 0,
      width.isFinite, width >= 0 else { return nil }
    var candidates = Set([inspector.platform1CodeToGlyph[code]]
      .compactMap { $0 }.filter { $0 > 0 && $0 < inspector.glyphCount })
    if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
      let unicodeGlyph = inspector.unicodeToGlyph[Int(scalar.value)],
      unicodeGlyph > 0, unicodeGlyph < inspector.glyphCount {
      candidates.insert(unicodeGlyph)
    }
    let matching = candidates.filter { glyphID in
      guard let advance = inspector.advances[glyphID] else { return false }
      return abs(Double(advance) * 1_000 / Double(inspector.unitsPerEm) - width) <= 1.1
    }
    guard matching.count == 1 else { return nil }
    return matching.first
  }

  func advance(of codes: [UInt8], fontSize: Double, charSpacing: Double,
    wordSpacing: Double, horizontalScale: Double) -> Double? {
    guard let glyphs = glyphs(codes) else { return nil }
    var total = 0.0
    for glyph in glyphs {
      guard let width = glyph.width else { return nil }
      total += width * fontSize / 1_000 + charSpacing
      // Word spacing applies only to the single-byte code32 (ISO32000-1 9.3.3).
      if glyph.codes == [32] { total += wordSpacing }
    }
    return total * horizontalScale / 100
  }
  var profile: PageTextFontProfile? {
    guard let program else { return nil }
    let parts = baseFont.split(separator: "+", maxSplits: 1)
    let name = parts.count == 2 && parts[0].count == 6 ? String(parts[1]) : baseFont
    var glyphs: [String: PageTextFontProfile.Glyph] = [:]
    let candidates = simple == nil ? mapping.keys.sorted() : Array(0...255)
    if let inspector = try? TrueTypeInspector.inspect(program, requireUnicodeMap: false) {
      for code in candidates {
        let codes = simple == nil ? [UInt8(code >> 8), UInt8(code & 255)] : [UInt8(code)]
        guard let glyph = self.glyphs(codes)?.first, !glyph.text.isEmpty,
          glyph.text != "\u{FFFD}", let width = glyph.width, width.isFinite, width >= 0,
          encode(glyph.text) == codes else { continue }
        let gid: Int?
        if simple != nil {
          // Some simple-font subsetters put PDF character codes in a
          // platform-1 cmap. TrueTypeInspector also merges those entries into
          // its Unicode map, where a code such as 0x20 can look like a real
          // U+0020 mapping even though it names a different subset glyph.
          // Consider both possible mappings, but accept only the unique glyph
          // whose hmtx advance agrees with this source code's PDF /Widths.
          gid = Self.verifiedSimpleGlyphID(text: glyph.text, code: code,
            width: width, inspector: inspector)
          guard gid != nil else { continue }
        }
        else if let gids {
          guard glyph.text.unicodeScalars.count == 1 else { continue }
          guard code * 2 + 1 < gids.count else { continue }
          gid = Int(gids[code * 2]) * 256 + Int(gids[code * 2 + 1])
        } else {
          guard glyph.text.unicodeScalars.count == 1 else { continue }
          gid = code
        }
        guard let gid, gid > 0, gid < inspector.glyphCount,
          let advance = inspector.advances[gid],
          abs(Double(advance) * 1_000 / Double(inspector.unitsPerEm) - width) <= 1.1 else { continue }
        glyphs[glyph.text] = .init(id: gid, width: width, codes: codes)
      }
    } else if simple != nil,
      let provider = CGDataProvider(data: program as CFData),
      let font = CGFont(provider), font.unitsPerEm > 0 {
      for code in 0...255 {
        let codes = [UInt8(code)]
        guard let glyph = self.glyphs(codes)?.first, glyph.text.unicodeScalars.count == 1,
          glyph.text != "\u{FFFD}", let width = glyph.width, width.isFinite, width >= 0,
          encode(glyph.text) == codes,
          let glyphName = simple?.glyphName(for: UInt8(code))
            ?? GlyphNames.name(for: glyph.text) else { continue }
        let gid = font.getGlyphWithGlyphName(name: glyphName as CFString)
        var advance: Int32 = 0
        guard gid > 0,
          font.getGlyphAdvances(glyphs: [gid], count: 1, advances: &advance),
          abs(Double(advance) * 1_000 / Double(font.unitsPerEm) - width) <= 1.1
        else { continue }
        glyphs[glyph.text] = .init(id: Int(gid), width: width, codes: codes)
      }
    }
    guard !glyphs.isEmpty else { return nil }
    return .init(source: .init(resource: resource, name: name), program: program, glyphs: glyphs)
  }
}
