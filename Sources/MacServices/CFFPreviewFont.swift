import CoreGraphics
import CoreText
import Foundation
import PDFCore
import PDFEditing

/// Makes a Unicode-mapped, in-memory OpenType wrapper around an embedded
/// Type 1C program. The PDF itself keeps the original CFF bytes and encoding.
enum CFFPreviewFont {
  private struct Metric {
    let advance: Int
    let leftSideBearing: Int
    let rightSideBearing: Int
    let extent: Int
  }

  static func program(_ profile: PageTextFontProfile) -> Data? {
    let cff = [UInt8](profile.program)
    guard cff.count >= 4, cff[0] == 1, (4...cff.count).contains(Int(cff[2])),
      (1...4).contains(Int(cff[3])),
      let provider = CGDataProvider(data: profile.program as CFData),
      let font = CGFont(provider), font.numberOfGlyphs > 0,
      font.numberOfGlyphs <= Int(UInt16.max), (16...16_384).contains(font.unitsPerEm)
    else { return nil }

    let glyphCount = font.numberOfGlyphs
    let unitsPerEm = Int(font.unitsPerEm)
    let ctFont = CTFontCreateWithGraphicsFont(font, CGFloat(unitsPerEm), nil, nil)
    var metrics: [Metric] = []
    metrics.reserveCapacity(glyphCount)
    for rawID in 0..<glyphCount {
      let glyph = CGGlyph(rawID)
      var rawAdvance: Int32 = 0
      guard font.getGlyphAdvances(glyphs: [glyph], count: 1, advances: &rawAdvance),
        rawAdvance >= 0, rawAdvance <= Int32(UInt16.max)
      else { return nil }
      let bounds = CTFontCreatePathForGlyph(ctFont, glyph, nil)?.boundingBoxOfPath ?? .zero
      guard [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
        let left = signed(Double(bounds.minX.rounded(.down))),
        let right = signed(Double(bounds.maxX.rounded(.up)))
      else { return nil }
      let advance = Int(rawAdvance)
      let bearing = left
      let rightBearing = advance - left - (right - left)
      guard signed(rightBearing) != nil, signed(left + (right - left)) != nil else { return nil }
      metrics.append(.init(advance: advance, leftSideBearing: bearing,
        rightSideBearing: rightBearing, extent: left + (right - left)))
    }

    var cmap: [(scalar: Int, glyph: Int)] = []
    for (text, mapping) in profile.glyphs {
      guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
        scalar.value <= 0xFFFF, let glyph = mapping.id,
        glyph > 0, glyph < glyphCount
      else { return nil }
      let advance = metrics[glyph].advance
      guard abs(Double(advance) * 1_000 / Double(unitsPerEm) - mapping.width) <= 1.1 else {
        return nil
      }
      cmap.append((Int(scalar.value), glyph))
    }
    guard !cmap.isEmpty else { return nil }
    cmap.sort { $0.scalar < $1.scalar }

    let bbox = font.fontBBox
    guard let xMin = signed(Double(bbox.minX.rounded(.down))),
      let yMin = signed(Double(bbox.minY.rounded(.down))),
      let xMax = signed(Double(bbox.maxX.rounded(.up))),
      let yMax = signed(Double(bbox.maxY.rounded(.up))),
      let ascent = signed(Double(font.ascent)), let descent = signed(Double(font.descent))
    else { return nil }

    let maxAdvance = metrics.map(\.advance).max() ?? 0
    guard (1...Int(UInt16.max)).contains(maxAdvance),
      let minLeft = metrics.map(\.leftSideBearing).min(), signed(minLeft) != nil,
      let minRight = metrics.map(\.rightSideBearing).min(), signed(minRight) != nil,
      let maxExtent = metrics.map(\.extent).max(), signed(maxExtent) != nil
    else { return nil }

    let mappedScalars = cmap.map(\.scalar)
    let os2 = os2Table(
      averageAdvance: Int((Double(metrics.reduce(0) { $0 + $1.advance }) / Double(metrics.count)).rounded()),
      firstScalar: mappedScalars.min()!, lastScalar: mappedScalars.max()!,
      ascent: ascent, descent: descent, yMin: yMin)
    let tables: [String: [UInt8]] = [
      "CFF ": cff,
      "OS/2": os2,
      "cmap": cmapTable(cmap),
      "head": headTable(unitsPerEm: unitsPerEm, bbox: [xMin, yMin, xMax, yMax]),
      "hhea": hheaTable(ascent: ascent, descent: descent, maxAdvance: maxAdvance,
        minLeft: minLeft, minRight: minRight, maxExtent: maxExtent, glyphCount: glyphCount),
      "hmtx": hmtxTable(metrics),
      "maxp": u32(0x0000_5000) + u16(glyphCount),
      "name": nameTable(profile.source.name),
      "post": postTable,
    ]
    return try? sfnt(tables)
  }

  private static func signed(_ value: Double) -> Int? {
    guard value.isFinite, value >= Double(Int16.min), value <= Double(Int16.max) else { return nil }
    return Int(value)
  }

  private static func signed(_ value: Int) -> Int? {
    Int16(exactly: value) == nil ? nil : value
  }

  private static func u16(_ value: Int) -> [UInt8] {
    let bits = UInt16(truncatingIfNeeded: value)
    return [UInt8(bits >> 8), UInt8(bits & 0xFF)]
  }

  private static func u32(_ value: Int) -> [UInt8] {
    let bits = UInt32(truncatingIfNeeded: value)
    return [UInt8(bits >> 24), UInt8((bits >> 16) & 0xFF),
      UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
  }

  private static func i16(_ value: Int) -> [UInt8] { u16(value) }

  private static func cmapTable(_ mappings: [(scalar: Int, glyph: Int)]) -> [UInt8] {
    var subtable = u16(12) + u16(0) + u32(16 + mappings.count * 12) + u32(0) + u32(mappings.count)
    for mapping in mappings {
      subtable += u32(mapping.scalar) + u32(mapping.scalar) + u32(mapping.glyph)
    }
    return u16(0) + u16(2)
      + u16(0) + u16(4) + u32(20)
      + u16(3) + u16(10) + u32(20)
      + subtable
  }

  private static func headTable(unitsPerEm: Int, bbox: [Int]) -> [UInt8] {
    u32(0x0001_0000) + u32(0x0001_0000) + u32(0) + u32(0x5F0F_3CF5)
      + u16(0) + u16(unitsPerEm)
      + Array(repeating: UInt8(0), count: 16)
      + i16(bbox[0]) + i16(bbox[1]) + i16(bbox[2]) + i16(bbox[3])
      + u16(0) + u16(8) + i16(2) + i16(0) + i16(0)
  }

  private static func hheaTable(ascent: Int, descent: Int, maxAdvance: Int,
    minLeft: Int, minRight: Int, maxExtent: Int, glyphCount: Int) -> [UInt8] {
    u32(0x0001_0000) + i16(ascent) + i16(descent) + i16(0)
      + u16(maxAdvance) + i16(minLeft) + i16(minRight) + i16(maxExtent)
      + i16(1) + i16(0) + i16(0)
      + Array(repeating: UInt8(0), count: 8)
      + i16(0) + u16(glyphCount)
  }

  private static func hmtxTable(_ metrics: [Metric]) -> [UInt8] {
    metrics.reduce(into: [UInt8]()) { result, metric in
      result += u16(metric.advance) + i16(metric.leftSideBearing)
    }
  }

  private static func os2Table(averageAdvance: Int, firstScalar: Int, lastScalar: Int,
    ascent: Int, descent: Int, yMin: Int) -> [UInt8] {
    let winAscent = max(0, max(ascent, -yMin))
    let winDescent = max(0, max(-descent, -yMin))
    var bytes = u16(0) + i16(min(Int(Int16.max), max(Int(Int16.min), averageAdvance)))
      + u16(400) + u16(5) + u16(0)
    bytes += Array(repeating: UInt8(0), count: 16)
    bytes += i16(50) + i16(250) + i16(0)
    bytes += Array(repeating: UInt8(0), count: 10)
    bytes += Array(repeating: UInt8(0), count: 16)
    bytes += Array("SPDF".utf8) + u16(0)
    bytes += u16(firstScalar) + u16(lastScalar)
    bytes += i16(ascent) + i16(descent) + i16(0)
    bytes += u16(min(Int(UInt16.max), winAscent)) + u16(min(Int(UInt16.max), winDescent))
    return bytes
  }

  private static func nameTable(_ sourceName: String) -> [UInt8] {
    let suffix = String(sourceName.unicodeScalars.filter {
      $0.value < 128 && CharacterSet.alphanumerics.contains($0)
    }.prefix(40))
    let family = "sPDF CFF Preview \(sourceName)"
    let postScript = "sPDFCFFPreview\(suffix.isEmpty ? "Font" : suffix)"
    let names = [(1, family), (2, "Regular"), (4, family), (6, postScript)]
    let encoded = names.map { utf16be($0.1) }
    let stringOffset = 6 + names.count * 12
    var records: [UInt8] = []
    var strings: [UInt8] = []
    for (index, name) in names.enumerated() {
      let value = encoded[index]
      records += u16(3) + u16(1) + u16(0x0409) + u16(name.0)
        + u16(value.count) + u16(stringOffset + strings.count)
      strings += value
    }
    return u16(0) + u16(names.count) + u16(stringOffset) + records + strings
  }

  private static func utf16be(_ value: String) -> [UInt8] {
    value.utf16.flatMap { u16(Int($0)) }
  }

  private static var postTable: [UInt8] {
    u32(0x0003_0000) + i16(0) + i16(-100) + i16(50) + u32(0)
      + Array(repeating: UInt8(0), count: 16)
  }

  private static func checksum(_ bytes: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    for start in stride(from: 0, to: bytes.count, by: 4) {
      var word: UInt32 = 0
      for offset in 0..<4 {
        word = (word << 8) | (start + offset < bytes.count ? UInt32(bytes[start + offset]) : 0)
      }
      sum = sum &+ word
    }
    return sum
  }

  private static func sfnt(_ tables: [String: [UInt8]]) throws -> Data {
    let tags = tables.keys.sorted()
    guard !tags.isEmpty, tags.count <= Int(UInt16.max) else {
      throw PDFError(.malformed, "Invalid preview font table count")
    }
    var power = 1
    var selector = 0
    while power * 2 <= tags.count { power *= 2; selector += 1 }
    var records: [UInt8] = []
    var payloads: [UInt8] = []
    var headOffset: Int?
    let payloadStart = 12 + tags.count * 16
    for tag in tags {
      guard let raw = tables[tag], let tagBytes = tag.data(using: .ascii), tagBytes.count == 4 else {
        throw PDFError(.malformed, "Invalid OpenType preview table")
      }
      var table = raw
      if tag == "head" {
        guard table.count >= 12 else { throw PDFError(.malformed, "Invalid preview font header") }
        table.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        headOffset = payloadStart + payloads.count
      }
      let offset = payloadStart + payloads.count
      records += Array(tagBytes) + u32(Int(checksum(table))) + u32(offset) + u32(table.count)
      payloads += table
      while !payloads.count.isMultiple(of: 4) { payloads.append(0) }
    }
    guard let headOffset else { throw PDFError(.malformed, "Missing preview font header") }
    var result = Array("OTTO".utf8) + u16(tags.count) + u16(power * 16)
      + u16(selector) + u16(tags.count * 16 - power * 16) + records + payloads
    result.replaceSubrange(headOffset + 8..<headOffset + 12,
      with: u32(Int(0xB1B0_AFBA &- checksum(result))))
    return Data(result)
  }
}
