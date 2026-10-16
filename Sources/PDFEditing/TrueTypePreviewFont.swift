import Foundation
import PDFCore

extension PageTextFontProfile {
  /// PDF subsets often omit the font's Unicode cmap. Supply its verified
  /// PDF Unicode-to-GID mapping to TextKit in memory. The document continues
  /// to use its original program, codes and CIDToGIDMap unchanged.
  public var previewProgram: Data? {
    try? TrueTypePreviewFont.program(program, glyphs: glyphs)
  }
}

enum TrueTypePreviewFont {
  static func program(_ original: Data, glyphs: [String: PageTextFontProfile.Glyph]) throws -> Data {
    let bytes = [UInt8](original)
    let inspector = try TrueTypeInspector.inspect(original, requireUnicodeMap: false)
    guard !inspector.isCFF, [0x0001_0000, 0x7472_7565].contains(try TrueTypeInspector.u32(bytes, at: 0)) else {
      throw PDFError(.unsupported, "This embedded font has no native preview mapping")
    }
    let mappings = glyphs.compactMap { text, glyph -> (Int, Int)? in
      guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, let id = glyph.id,
        id > 0, id < inspector.glyphCount else { return nil }
      return (Int(scalar.value), id)
    }.sorted { $0.0 < $1.0 }
    guard !mappings.isEmpty, mappings.count <= 65_536 else {
      throw PDFError(.unsupported, "The embedded font has no verified glyph mapping")
    }
    func u16(_ value: Int) -> [UInt8] { TrueTypeSubsetter.u16Bytes(value) }
    func u32(_ value: Int) -> [UInt8] { TrueTypeSubsetter.u32Bytes(value) }
    // Two encoding records share a Unicode format12 subtable.
    var cmap = u16(0) + u16(2) + u16(0) + u16(4) + u32(20) + u16(3) + u16(10) + u32(20)
    cmap += u16(12) + u16(0) + u32(16 + mappings.count * 12) + u32(0) + u32(mappings.count)
    for (scalar, glyph) in mappings { cmap += u32(scalar) + u32(scalar) + u32(glyph) }
    var tables: [String: [UInt8]] = [:]
    for (tag, table) in inspector.tables {
      tables[tag] = Array(bytes[table.offset..<table.offset + table.length])
    }
    tables["cmap"] = cmap
    guard var head = tables["head"], head.count >= 12 else {
      throw PDFError(.malformed, "Missing font header")
    }
    head.replaceSubrange(8..<12, with: [0, 0, 0, 0]); tables["head"] = head
    // Layout follows explicit PDF glyph advances, not source-language shaping.
    for tag in ["DSIG", "GSUB", "GPOS", "kern", "morx", "mort", "kerx"] { tables[tag] = nil }
    let tags = tables.keys.sorted()
    let power = 1 << Int(floor(log2(Double(tags.count))))
    var result = Array(bytes.prefix(4)) + u16(tags.count) + u16(power * 16)
      + u16(Int(log2(Double(power)))) + u16(tags.count * 16 - power * 16)
    var records: [UInt8] = []; var payloads: [UInt8] = []
    let start = 12 + tags.count * 16
    var headOffset = 0
    for tag in tags {
      let payload = tables[tag]!
      let offset = start + payloads.count
      if tag == "head" { headOffset = offset }
      records += Array(tag.utf8) + u32(TrueTypeSubsetter.checksum(payload)) + u32(offset) + u32(payload.count)
      payloads += payload
      while !payloads.count.isMultiple(of: 4) { payloads.append(0) }
    }
    result += records + payloads
    let adjustment = (0xB1B0_AFBA - TrueTypeSubsetter.checksum(result)) & 0xFFFF_FFFF
    result.replaceSubrange(headOffset + 8..<headOffset + 12, with: u32(adjustment))
    return Data(result)
  }
}
