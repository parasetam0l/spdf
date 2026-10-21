import Foundation
import PDFCore

/// P15-015: TrueType table inspection with bounds checks. Reads metrics,
/// the Unicode map, advances, and glyph offsets from a font program without
/// trusting any offset or count; every read is range-checked against the
/// program bytes and integer arithmetic is overflow-checked.
public struct TrueTypeInspector: Sendable, Equatable {
  public struct Table: Sendable, Equatable {
    public let tag: String
    public let offset: Int
    public let length: Int

    public init(tag: String, offset: Int, length: Int) {
      self.tag = tag
      self.offset = offset
      self.length = length
    }
  }

  public let tables: [String: Table]
  public let unitsPerEm: Int
  public let ascent: Int
  public let descent: Int
  public let fontBBox: [Int]
  public let italicAngle: Double
  public let glyphCount: Int
  /// OS/2 `fsType` embedding rights. Missing OS/2 rights are treated as
  /// unknown, so user-supplied programs cannot be embedded on assumption.
  public let embeddingFlags: Int?
  public let locaIsLong: Bool
  /// P15-020: true for CFF-flavored OpenType (CFF table instead of
  /// glyf/loca). Outlines live in CharStrings; only full-program embedding
  /// is supported, never subsetting.
  public let isCFF: Bool
  /// Unicode scalar value to glyph ID, merged from format-4 and format-12
  /// cmap subtables (format 12 wins ties).
  public let unicodeToGlyph: [Int: Int]
  /// Raw code-to-glyph entries from platform-1 cmaps. Some PDF subsetters
  /// key these by PDF character code instead of MacRoman byte; callers must
  /// still validate the resulting glyph against ToUnicode and `/Widths`.
  public let platform1CodeToGlyph: [Int: Int]
  /// Glyph ID to horizontal advance in font units.
  public let advances: [Int: Int]
  /// Glyph ID to byte offset of its outline data (loca-decoded).
  public let glyphOffsets: [Int]

  static func u16(_ bytes: [UInt8], at offset: Int) throws -> Int {
    guard offset >= 0, offset + 2 <= bytes.count else {
      throw PDFError(.malformed, "TrueType table read is outside the program")
    }
    return Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
  }

  static func u32(_ bytes: [UInt8], at offset: Int) throws -> Int {
    guard offset >= 0, offset + 4 <= bytes.count else {
      throw PDFError(.malformed, "TrueType table read is outside the program")
    }
    var value = 0
    for index in 0..<4 {
      let (shifted, overflow1) = value.multipliedReportingOverflow(by: 256)
      let (sum, overflow2) = shifted.addingReportingOverflow(Int(bytes[offset + index]))
      guard !overflow1, !overflow2 else {
        throw PDFError(.malformed, "TrueType table value overflows")
      }
      value = sum
    }
    return value
  }

  static func i16(_ bytes: [UInt8], at offset: Int) throws -> Int {
    let raw = try u16(bytes, at: offset)
    return raw >= 0x8000 ? raw - 0x1_0000 : raw
  }

  static func table(
    _ bytes: [UInt8], tables: [String: Table], tag: String, offset: Int, length: Int
  ) throws -> [UInt8] {
    guard let table = tables[tag] else {
      throw PDFError(.malformed, "TrueType program lacks the \(tag) table")
    }
    let (end, overflow) = table.offset.addingReportingOverflow(table.length)
    guard !overflow, table.offset >= 0, end <= bytes.count else {
      throw PDFError(.malformed, "TrueType \(tag) table is outside the program")
    }
    _ = (offset, length)
    return Array(bytes[table.offset..<end])
  }

  public static func inspect(_ data: Data, requireUnicodeMap: Bool = true) throws -> TrueTypeInspector {
    let bytes = [UInt8](data)
    guard bytes.count >= 12 else {
      throw PDFError(.malformed, "TrueType program is too short for a directory")
    }
    let sfnt = try u32(bytes, at: 0)
    guard sfnt == 0x0001_0000 || sfnt == 0x7472_7565 || sfnt == 0x7474_6366
      || sfnt == 0x4F54544F  // OTTO: CFF-flavored OpenType
    else {
      throw PDFError(.unsupported, "Not a TrueType- or CFF-flavored font program")
    }
    let tableCount = try u16(bytes, at: 4)
    guard tableCount > 0, tableCount <= 64 else {
      throw PDFError(.malformed, "TrueType table count is implausible")
    }
    guard 12 + tableCount * 16 <= bytes.count else {
      throw PDFError(.malformed, "TrueType directory runs past the program")
    }
    var tables: [String: Table] = [:]
    for index in 0..<tableCount {
      let base = 12 + index * 16
      let tagBytes = Array(bytes[base..<base + 4])
      guard let tag = String(bytes: tagBytes, encoding: .ascii) else {
        throw PDFError(.malformed, "TrueType table tag is not ASCII")
      }
      let offset = try u32(bytes, at: base + 8)
      let length = try u32(bytes, at: base + 12)
      let (end, overflow) = offset.addingReportingOverflow(length)
      guard !overflow, end <= bytes.count else {
        throw PDFError(.malformed, "TrueType \(tag) table runs past the program")
      }
      tables[tag] = Table(tag: tag, offset: offset, length: length)
    }

    let head = try table(bytes, tables: tables, tag: "head", offset: 0, length: 54)
    let unitsPerEm = try u16(head, at: 18)
    guard unitsPerEm >= 16, unitsPerEm <= 16384 else {
      throw PDFError(.malformed, "TrueType units-per-em is implausible")
    }
    let bbox = try [
      i16(head, at: 36), i16(head, at: 38), i16(head, at: 40), i16(head, at: 42),
    ]
    let locaIsLong = try i16(head, at: 50) != 0

    let hhea = try table(bytes, tables: tables, tag: "hhea", offset: 0, length: 36)
    let ascent = try i16(hhea, at: 4)
    let descent = try i16(hhea, at: 6)
    let numberOfHMetrics = try u16(hhea, at: 34)

    let maxp = try table(bytes, tables: tables, tag: "maxp", offset: 0, length: 6)
    let glyphCount = try u16(maxp, at: 4)

    var embeddingFlags: Int?
    if let os2 = tables["OS/2"] {
      guard os2.length >= 10, os2.offset + 10 <= bytes.count else {
        throw PDFError(.malformed, "TrueType OS/2 embedding rights are truncated")
      }
      embeddingFlags = try u16(bytes, at: os2.offset + 8)
    }

    var italicAngle = 0.0
    if let postTable = tables["post"], postTable.length >= 8,
      postTable.offset + 8 <= bytes.count
    {
      let whole = try i16(bytes, at: postTable.offset + 4)
      let fraction = try u16(bytes, at: postTable.offset + 6)
      italicAngle = Double(whole) + Double(fraction) / 65536
    }

    // Horizontal metrics: per-glyph advances, then implied repeats.
    let hmtx = try table(bytes, tables: tables, tag: "hmtx", offset: 0, length: 4)
    guard numberOfHMetrics > 0, numberOfHMetrics <= glyphCount else {
      throw PDFError(.malformed, "TrueType horizontal metric count is implausible")
    }
    let hmtxTable = tables["hmtx"]!
    guard hmtxTable.offset + numberOfHMetrics * 4 <= bytes.count else {
      throw PDFError(.malformed, "TrueType hmtx table is truncated")
    }
    var advances: [Int: Int] = [:]
    var lastAdvance = 0
    for glyph in 0..<glyphCount {
      let source = min(glyph, numberOfHMetrics - 1)
      let advance = try u16(bytes, at: hmtxTable.offset + source * 4)
      advances[glyph] = advance
      lastAdvance = advance
    }
    _ = lastAdvance
    _ = hmtx

    // loca: glyph outline offsets (short entries are halved). CFF programs
    // carry outlines in CharStrings instead.
    let isCFF = tables["CFF "] != nil
    if isCFF, tables["glyf"] != nil || tables["loca"] != nil {
      throw PDFError(.malformed, "Font program has both CFF and TrueType outlines")
    }
    if !isCFF, tables["glyf"] == nil || tables["loca"] == nil {
      throw PDFError(.malformed, "TrueType program lacks the glyf/loca tables")
    }
    var glyphOffsets: [Int] = []
    if !isCFF {
      guard let locaTable = tables["loca"] else {
        throw PDFError(.malformed, "TrueType program lacks the loca table")
      }
      let entrySize = locaIsLong ? 4 : 2
      let (locaEnd, locaOverflow) = (glyphCount + 1).multipliedReportingOverflow(by: entrySize)
      guard !locaOverflow, locaTable.offset + locaEnd <= bytes.count else {
        throw PDFError(.malformed, "TrueType loca table is truncated")
      }
      for glyph in 0...glyphCount {
        let at = locaTable.offset + glyph * entrySize
        let offset = locaIsLong ? try u32(bytes, at: at) : try u16(bytes, at: at) * 2
        glyphOffsets.append(offset)
      }
    }

    // cmap: merge format-4 segments, then format-12 groups (winning ties).
    if requireUnicodeMap && tables["cmap"] == nil {
      throw PDFError(.malformed, "TrueType program lacks the cmap table")
    }
    let cmapTable = tables["cmap"]
    let subtableCount = try cmapTable.map { try u16(bytes, at: $0.offset + 2) } ?? 0
    guard subtableCount <= 32 else {
      throw PDFError(.malformed, "TrueType cmap subtable count is implausible")
    }
    var unicodeToGlyph: [Int: Int] = [:]
    var platform1CodeToGlyph: [Int: Int] = [:]
    var format12: [(Int, Int, Int)] = []
    // Macintosh-platform subtables address MacRoman bytes, not Unicode.
    func translate(_ code: Int, platform: Int) -> Int? {
      guard platform == 1 else { return code }
      guard code < 256 else { return nil }
      if code < 128 { return code }
      guard let string = String(bytes: [UInt8(code)], encoding: .macOSRoman),
        string.unicodeScalars.count == 1
      else { return nil }
      return Int(string.unicodeScalars.first!.value)
    }
    func merge(_ merged: [Int: Int], platform: Int) {
      for (code, glyph) in merged {
        guard let scalar = translate(code, platform: platform),
          unicodeToGlyph[scalar] == nil
        else { continue }
        unicodeToGlyph[scalar] = glyph
      }
    }
    for index in 0..<subtableCount {
      guard let cmapTable else { break }
      let record = cmapTable.offset + 4 + index * 8
      guard record + 8 <= bytes.count else {
        throw PDFError(.malformed, "TrueType cmap record runs past the program")
      }
      let platform = try u16(bytes, at: record)
      let subtable = cmapTable.offset + (try u32(bytes, at: record + 4))
      guard subtable + 4 <= bytes.count else {
        throw PDFError(.malformed, "TrueType cmap subtable runs past the program")
      }
      let format = try u16(bytes, at: subtable)
      if format == 0 {
        let parsed = try parseCmapFormat0(bytes, at: subtable)
        if platform == 1 { platform1CodeToGlyph.merge(parsed) { _, new in new } }
        merge(parsed, platform: platform)
      } else if format == 4 {
        let parsed = try parseCmapFormat4(bytes, at: subtable)
        if platform == 1 { platform1CodeToGlyph.merge(parsed) { _, new in new } }
        merge(parsed, platform: platform)
      } else if format == 6 {
        let parsed = try parseCmapFormat6(bytes, at: subtable)
        if platform == 1 { platform1CodeToGlyph.merge(parsed) { _, new in new } }
        merge(parsed, platform: platform)
      } else if format == 12 {
        format12 += try parseCmapFormat12(bytes, at: subtable)
      }    }
    for (start, end, glyph) in format12 {
      var scalar = start
      var id = glyph
      while scalar <= end {
        unicodeToGlyph[scalar] = id
        scalar += 1
        id += 1
      }
    }

    return TrueTypeInspector(
      tables: tables, unitsPerEm: unitsPerEm, ascent: ascent, descent: descent,
      fontBBox: bbox, italicAngle: italicAngle, glyphCount: glyphCount,
      embeddingFlags: embeddingFlags,
      locaIsLong: locaIsLong, isCFF: isCFF, unicodeToGlyph: unicodeToGlyph,
      platform1CodeToGlyph: platform1CodeToGlyph,
      advances: advances, glyphOffsets: glyphOffsets)
  }

  /// Inline PDF writing requires embedding and subsetting. Respect restricted,
  /// preview/print-only, no-subsetting, and bitmap-only OS/2 flags.
  public var permitsEditableSubsetEmbedding: Bool {
    guard let embeddingFlags else { return false }
    return embeddingFlags & 0x0002 == 0 && embeddingFlags & 0x0004 == 0
      && embeddingFlags & 0x0100 == 0 && embeddingFlags & 0x0200 == 0
  }

  static func parseCmapFormat4(_ bytes: [UInt8], at base: Int) throws -> [Int: Int] {
    let length = try u16(bytes, at: base + 2)
    guard base + length <= bytes.count else {
      throw PDFError(.malformed, "TrueType cmap format 4 runs past the program")
    }
    let end = base + length
    let segCount = try u16(bytes, at: base + 6) / 2
    guard segCount > 0, segCount <= 256 else {
      throw PDFError(.malformed, "TrueType cmap segment count is implausible")
    }
    func array(at offset: Int, count: Int) throws -> [Int] {
      guard offset + count * 2 <= end else {
        throw PDFError(.malformed, "TrueType cmap arrays run past the subtable")
      }
      return try (0..<count).map { try u16(bytes, at: offset + $0 * 2) }
    }
    let ends = try array(at: base + 14, count: segCount)
    let starts = try array(at: base + 16 + segCount * 2, count: segCount)
    let deltas = try array(at: base + 16 + segCount * 4, count: segCount)
    let rangeBase = base + 16 + segCount * 6
    var result: [Int: Int] = [:]
    for segment in 0..<segCount {
      guard starts[segment] <= ends[segment] else {
        throw PDFError(.malformed, "TrueType cmap segment is inverted")
      }
      guard ends[segment] - starts[segment] <= 4096 else {
        throw PDFError(.malformed, "TrueType cmap segment is implausibly large")
      }
      let rangeOffset = try u16(bytes, at: rangeBase + segment * 2)
      var code = starts[segment]
      while code <= ends[segment] {
        if rangeOffset == 0 {
          result[code] = (code + deltas[segment]) % 65536
        } else {
          let position = rangeBase + segment * 2 + rangeOffset + (code - starts[segment]) * 2
          guard position + 2 <= end else {
            throw PDFError(.malformed, "TrueType cmap glyph lookup runs past the subtable")
          }
          let glyph = try u16(bytes, at: position)
          if glyph != 0 {
            result[code] = (glyph + deltas[segment]) % 65536
          }
        }
        code += 1
      }
    }
    return result
  }

  static func parseCmapFormat0(_ bytes: [UInt8], at base: Int) throws -> [Int: Int] {
    let length = try u16(bytes, at: base + 2)
    guard length == 262, base + length <= bytes.count else {
      throw PDFError(.malformed, "TrueType cmap format 0 has an invalid length")
    }
    var result: [Int: Int] = [:]
    for code in 0..<256 {
      let glyph = bytes[base + 6 + code]
      if glyph != 0 {
        result[code] = Int(glyph)
      }
    }
    return result
  }

  static func parseCmapFormat6(_ bytes: [UInt8], at base: Int) throws -> [Int: Int] {
    let length = try u16(bytes, at: base + 2)
    guard base + length <= bytes.count else {
      throw PDFError(.malformed, "TrueType cmap format 6 runs past the program")
    }
    let firstCode = try u16(bytes, at: base + 6)
    let entryCount = try u16(bytes, at: base + 8)
    guard entryCount <= 4096, base + 10 + entryCount * 2 <= bytes.count else {
      throw PDFError(.malformed, "TrueType cmap format 6 entry count is implausible")
    }
    var result: [Int: Int] = [:]
    for offset in 0..<entryCount {
      let glyph = try u16(bytes, at: base + 10 + offset * 2)
      if glyph != 0 {
        result[firstCode + offset] = glyph
      }
    }
    return result
  }

  static func parseCmapFormat12(_ bytes: [UInt8], at base: Int) throws
    -> [(start: Int, end: Int, glyph: Int)]
  {
    let length = try u32(bytes, at: base + 4)
    guard base + length <= bytes.count else {
      throw PDFError(.malformed, "TrueType cmap format 12 runs past the program")
    }
    let count = try u32(bytes, at: base + 12)
    guard count <= 4096, base + 16 + count * 12 <= bytes.count else {
      throw PDFError(.malformed, "TrueType cmap format 12 group count is implausible")
    }
    var groups: [(Int, Int, Int)] = []
    for index in 0..<count {
      let at = base + 16 + index * 12
      let start = try u32(bytes, at: at)
      let end = try u32(bytes, at: at + 4)
      let glyph = try u32(bytes, at: at + 8)
      guard start <= end, end - start <= 65536 else {
        throw PDFError(.malformed, "TrueType cmap format 12 group is invalid")
      }
      groups.append((start, end, glyph))
    }
    return groups
  }
}

/// P15-009–P15-014: TrueType font writing — full-program embedding with
/// generated descriptors, simple-font resources, and ToUnicode maps.
/// Subsetting builds on this once full embedding verifies (P15-016).
public struct WrittenFont: Sendable, Equatable {
  /// Byte code to Unicode scalar value for the encoded text.
  public let encoding: [UInt8: Int]
  /// Byte code to advance width in thousandths of an em.
  public let widths: [UInt8: Int]
  public let fontDictionary: PDFValue
  public let descriptor: PDFValue
  public let fontFile: PDFStream
  public let toUnicode: PDFStream

  /// Encode text with this font's codes (P18-006: nil for unencodable text,
  /// never silent substitution).
  public func encode(_ text: String) -> [UInt8]? {
    var reverse: [Int: UInt8] = [:]
    for (code, scalar) in encoding {
      if reverse[scalar] == nil { reverse[scalar] = code }
    }
    var bytes: [UInt8] = []
    for scalar in text.unicodeScalars {
      guard let code = reverse[Int(scalar.value)] else { return nil }
      bytes.append(code)
    }
    return bytes
  }
}

public enum FontWriter {
  /// P15-010: a generated font descriptor from inspected metrics.
  public static func descriptor(
    baseName: String, inspector: TrueTypeInspector
  ) -> [PDFName: PDFValue] {
    var flags = 32
    if inspector.italicAngle != 0 { flags += 64 }
    return [
      PDFName("Type"): .name(PDFName("FontDescriptor")),
      PDFName("FontName"): .name(PDFName(baseName)),
      PDFName("Flags"): .integer(Int64(flags)),
      PDFName("FontBBox"): .array(inspector.fontBBox.map { PDFValue.integer(Int64($0)) }),
      PDFName("ItalicAngle"): .real(inspector.italicAngle),
      PDFName("Ascent"): .integer(Int64(inspector.ascent)),
      PDFName("Descent"): .integer(Int64(inspector.descent)),
    ]
  }
  /// Embed `program` covering exactly `text`: WinAnsi-encodable glyphs take
  /// their WinAnsi codes, others take Differences codes from 1 upward. Every
  /// character needs a glyph in the program; anything else throws rather
  /// than substituting.
  public static func writeTrueType(
    program: Data, baseName: String, covering text: String
  ) throws -> WrittenFont {
    let inspector = try TrueTypeInspector.inspect(program)
    // WinAnsi byte to scalar, skipping undefined controls.
    var winAnsi: [UInt8: Int] = [:]
    for byte in UInt8(32)..<UInt8(255) {
      if let string = String(bytes: [byte], encoding: .windowsCP1252),
        string.unicodeScalars.count == 1
      {
        winAnsi[byte] = Int(string.unicodeScalars.first!.value)
      }
    }
    var encoding: [UInt8: Int] = [:]
    var used: Set<UInt8> = []
    var differences: [(code: UInt8, name: String)] = []
    var nextDifference = 1
    for scalar in text.unicodeScalars.map({ Int($0.value) }) {
      if encoding.values.contains(scalar) { continue }
      guard inspector.unicodeToGlyph[scalar].map({
        $0 > 0 && $0 < inspector.glyphCount
      }) == true else {
        throw PDFError(
          .unsupported, "The font program has no glyph for U+\(String(scalar, radix: 16, uppercase: true))")
      }
      var placed = false
      for (code, mapped) in winAnsi where mapped == scalar && !used.contains(code) {
        encoding[code] = scalar
        used.insert(code)
        placed = true
        break
      }
      if !placed {
        while used.contains(UInt8(nextDifference)) {
          nextDifference += 1
        }
        guard nextDifference <= 255 else {
          throw PDFError(.limitExceeded, "Too many non-WinAnsi glyphs for Differences codes")
        }
        let code = UInt8(nextDifference)
        nextDifference += 1
        encoding[code] = scalar
        used.insert(code)
        differences.append((code, "g\(scalar)"))
      }
    }
    var widths: [UInt8: Int] = [:]
    for (code, scalar) in encoding {
      guard let glyph = inspector.unicodeToGlyph[scalar],
        let advance = inspector.advances[glyph]
      else {
        throw PDFError(.malformed, "Font program metrics are missing a covered glyph")
      }
      widths[code] = Int((Double(advance) * 1000 / Double(inspector.unitsPerEm)).rounded())
    }
    let firstChar = encoding.keys.min() ?? 32
    let lastChar = encoding.keys.max() ?? 32
    let widthArray: [PDFValue] = (Int(firstChar)...Int(lastChar)).map { code in
      .integer(Int64(widths[UInt8(code)] ?? 0))
    }
    var fontDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("TrueType")),
      PDFName("BaseFont"): .name(PDFName(baseName)),
      PDFName("FirstChar"): .integer(Int64(firstChar)),
      PDFName("LastChar"): .integer(Int64(lastChar)),
      PDFName("Widths"): .array(widthArray),
    ]
    if differences.isEmpty {
      // Name form when no remapping is needed; some consumers mishandle
      // an explicit dictionary without Differences.
      fontDictionary[PDFName("Encoding")] = .name(PDFName("WinAnsiEncoding"))
    } else {
      var encodingDictionary: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("Encoding")),
        PDFName("BaseEncoding"): .name(PDFName("WinAnsiEncoding")),
      ]
      var items: [PDFValue] = []
      let sorted = differences.sorted { $0.code < $1.code }
      var index = 0
      while index < sorted.count {
        let start = sorted[index].code
        items.append(.integer(Int64(start)))
        var expected = Int(start)
        while index < sorted.count, Int(sorted[index].code) == expected {
          items.append(.name(PDFName(sorted[index].name)))
          index += 1
          expected += 1
        }
      }
      encodingDictionary[PDFName("Differences")] = .array(items)
      fontDictionary[PDFName("Encoding")] = .dictionary(encodingDictionary)
    }
    let descriptor = Self.descriptor(baseName: baseName, inspector: inspector)
    // ToUnicode: BMP scalars as four hex digits, astral as surrogate pairs.
    var bfchar: [String] = []
    for code in encoding.keys.sorted() {
      let scalar = encoding[code]!
      let destination: String
      if scalar <= 0xFFFF {
        destination = String(format: "<%04X>", scalar)
      } else {
        let adjusted = scalar - 0x1_0000
        destination = String(
          format: "<%04X%04X>", 0xD800 + adjusted / 0x400, 0xDC00 + adjusted % 0x400)
      }
      bfchar.append(String(format: "<%02X> %@", code, destination))
    }
    let cmapText =
      "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo\n<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n\(bfchar.count) beginbfchar\n\(bfchar.joined(separator: "\n"))\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    return WrittenFont(
      encoding: encoding, widths: widths,
      fontDictionary: .dictionary(fontDictionary),
      descriptor: .dictionary(descriptor),
      fontFile: PDFStream(bytes: program),
      toUnicode: PDFStream(bytes: Data(cmapText.utf8)))
  }
}

/// P15-016–P15-019: TrueType subsetting. Keeps requested glyphs (plus
/// `.notdef` and composite dependencies), rebuilds glyf/loca/hmtx/cmap/maxp,
/// preserves hinting programs and metrics, and recomputes checksums.
/// Only full-program embedding must verify first — it does (P15-009).
public enum TrueTypeSubsetter {
  // glyf composite component flags.
  private static let argWords = 0x0001
  private static let haveScale = 0x0008
  private static let moreComponents = 0x0020
  private static let haveXYScale = 0x0040
  private static let haveTwoByTwo = 0x0080
  private static let haveInstructions = 0x0100

  private struct Component {
    let flags: Int
    let glyph: Int
    let arguments: [UInt8]
    let transform: [UInt8]
  }

  private static func readBytes(
    _ bytes: [UInt8], at offset: Int, count: Int, what: String
  ) throws -> [UInt8] {
    let (end, overflow) = offset.addingReportingOverflow(count)
    guard !overflow, offset >= 0, end <= bytes.count else {
      throw PDFError(.malformed, "TrueType subset read of \(what) is out of bounds")
    }
    return Array(bytes[offset..<end])
  }

  /// Parse one composite glyph's components, remapping glyph IDs through
  /// `remap` (which must already contain every reachable glyph).
  private static func parseComposite(
    _ bytes: [UInt8], at offset: Int, remap: [Int: Int]
  ) throws -> (header: [UInt8], components: [Component], instructions: [UInt8]) {
    var cursor = offset
    let header = try readBytes(bytes, at: cursor, count: 10, what: "composite header")
    cursor += 10
    var components: [Component] = []
    var hasInstructions = false
    while true {
      let flags = try TrueTypeInspector.u16(bytes, at: cursor)
      cursor += 2
      let glyph = try TrueTypeInspector.u16(bytes, at: cursor)
      cursor += 2
      guard let mapped = remap[glyph] else {
        throw PDFError(
          .malformed, "TrueType subset is missing a composite dependency")
      }
      let argumentCount = (flags & argWords) != 0 ? 4 : 2
      let arguments = try readBytes(bytes, at: cursor, count: argumentCount, what: "arguments")
      cursor += argumentCount
      var transform: [UInt8] = []
      if (flags & haveScale) != 0 {
        transform = try readBytes(bytes, at: cursor, count: 2, what: "scale")
        cursor += 2
      } else if (flags & haveXYScale) != 0 {
        transform = try readBytes(bytes, at: cursor, count: 4, what: "xy-scale")
        cursor += 4
      } else if (flags & haveTwoByTwo) != 0 {
        transform = try readBytes(bytes, at: cursor, count: 8, what: "2x2")
        cursor += 8
      }
      if (flags & haveInstructions) != 0 { hasInstructions = true }
      components.append(
        Component(flags: flags, glyph: mapped, arguments: arguments, transform: transform))
      if (flags & moreComponents) == 0 { break }
      guard components.count <= 256 else {
        throw PDFError(.malformed, "TrueType composite component count is implausible")
      }
    }
    var instructions: [UInt8] = []
    if hasInstructions {
      let count = try TrueTypeInspector.u16(bytes, at: cursor)
      cursor += 2
      instructions = try readBytes(bytes, at: cursor, count: count, what: "instructions")
    }
    return (header, components, instructions)
  }

  private static func componentBytes(_ component: Component) -> [UInt8] {
    var out: [UInt8] = [
      UInt8(component.flags / 256), UInt8(component.flags % 256),
      UInt8(component.glyph / 256), UInt8(component.glyph % 256),
    ]
    out += component.arguments
    out += component.transform
    return out
  }

  static func u16Bytes(_ value: Int) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
  }

  static func u32Bytes(_ value: Int) -> [UInt8] {
    [
      UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
  }

  static func checksum(_ bytes: [UInt8]) -> Int {
    var sum = 0
    var index = 0
    while index < bytes.count {
      var word = 0
      for slot in 0..<4 {
        word = word * 256 + (index + slot < bytes.count ? Int(bytes[index + slot]) : 0)
      }
      sum = (sum + word) & 0xFFFF_FFFF
      index += 4
    }
    return sum
  }

  /// P14-021: which Unicode scalars a font program can supply glyphs for,
  /// so replacement paths can check coverage before attempting a subset.
  /// A scalar is available when the program's cmap maps it to a non-.notdef
  /// glyph ID inside the glyph count. Availability is not subsettability: CFF
  /// programs report availability normally, but subsetting them still
  /// refuses (P15-020) — whole-program embedding is their only route.
  public struct GlyphAvailability: Sendable, Equatable {
    public let covered: Set<Int>
    public let missing: Set<Int>

    public init(covered: Set<Int>, missing: Set<Int>) {
      self.covered = covered
      self.missing = missing
    }
  }

  /// Inspect `program` once and split `unicodes` into covered/missing.
  public static func availability(
    program: Data, unicodes: Set<Int>
  ) throws -> GlyphAvailability {
    let inspector = try TrueTypeInspector.inspect(program)
    var covered: Set<Int> = []
    var missing: Set<Int> = []
    for scalar in unicodes {
      if let glyph = inspector.unicodeToGlyph[scalar],
        glyph > 0, glyph < inspector.glyphCount
      {
        covered.insert(scalar)
      } else {
        missing.insert(scalar)
      }
    }
    return GlyphAvailability(covered: covered, missing: missing)
  }

  /// Subset `program` to `unicodes`, returning a complete rewritten font.
  /// Every requested scalar needs a glyph (P18-006: throw, never silently
  /// drop). Composite dependencies close over `remap` (P15-017); hinting
  /// programs, metrics, and names carry over verbatim (P15-019); tables,
  /// offsets, and checksums are rebuilt (P15-018).
  public static func subset(program: Data, unicodes: Set<Int>) throws -> Data {
    let bytes = [UInt8](program)
    let inspector = try TrueTypeInspector.inspect(program)
    // P15-020: CFF outlines have no subset path; whole-program embedding
    // through the composite writer is the only supported route.
    guard !inspector.isCFF else {
      throw PDFError(
        .unsupported, "Subsetting CFF/OpenType programs is not supported; embed the whole program")
    }
    // P15-017: close over composite dependencies (cycle-safe).
    var needed: Set<Int> = [0]
    var visiting: Set<Int> = []
    func require(_ glyph: Int) throws {
      if needed.contains(glyph) { return }
      guard !visiting.contains(glyph) else {
        throw PDFError(.malformed, "TrueType composite glyphs form a cycle")
      }
      guard glyph >= 0, glyph < inspector.glyphCount else {
        throw PDFError(.malformed, "TrueType subset references an absent glyph")
      }
      visiting.insert(glyph)
      let start = inspector.glyphOffsets[glyph]
      let end = inspector.glyphOffsets[glyph + 1]
      if end > start, end <= bytes.count,
        let glyfTable = inspector.tables["glyf"],
        start + (end - start) <= bytes.count,
        start >= 0
      {
        let base = glyfTable.offset + start
        if base + 2 <= bytes.count,
          try TrueTypeInspector.i16(bytes, at: base) == -1
        {
          // Composite: only reachability matters here (remapping happens
          // when the glyf entries rebuild below).
          var cursor = base + 10
          var depth = 0
          while true {
            guard cursor + 4 <= bytes.count else {
              throw PDFError(.malformed, "TrueType composite glyph is truncated")
            }
            let flags = try TrueTypeInspector.u16(bytes, at: cursor)
            let component = try TrueTypeInspector.u16(bytes, at: cursor + 2)
            cursor += 4
            cursor += (flags & argWords) != 0 ? 4 : 2
            if (flags & haveScale) != 0 { cursor += 2 }
            else if (flags & haveXYScale) != 0 { cursor += 4 }
            else if (flags & haveTwoByTwo) != 0 { cursor += 8 }
            try require(component)
            depth += 1
            guard depth <= 256 else {
              throw PDFError(.malformed, "TrueType composite component count is implausible")
            }
            if (flags & moreComponents) == 0 { break }
          }
        }
      }
      visiting.remove(glyph)
      needed.insert(glyph)
    }
    for scalar in unicodes {
      guard let glyph = inspector.unicodeToGlyph[scalar], glyph > 0 else {
        throw PDFError(
          .unsupported,
          "The font program has no glyph for U+\(String(scalar, radix: 16, uppercase: true))")
      }
      try require(glyph)
    }
    // Deterministic new IDs: .notdef stays 0, the rest ascend.
    let ordered = [0] + needed.filter { $0 != 0 }.sorted()
    var remap: [Int: Int] = [:]
    for (new, old) in ordered.enumerated() { remap[old] = new }

    guard let glyfTable = inspector.tables["glyf"] else {
      throw PDFError(.malformed, "TrueType program lacks the glyf table")
    }
    // Rebuild glyf with remapped composite components.
    // Rebuild glyf with remapped composite components. Entries collect
    // first so loca can upgrade to long form when an offset is odd (short
    // loca stores halved offsets and cannot represent odd positions).
    var entries: [[UInt8]] = []
    for old in ordered {
      let start = inspector.glyphOffsets[old]
      let end = inspector.glyphOffsets[old + 1]
      if end <= start {
        entries.append([])
        continue
      }
      let base = glyfTable.offset + start
      if try TrueTypeInspector.i16(bytes, at: base) == -1 {
        let (header, components, instructions) = try parseComposite(
          bytes, at: base, remap: remap)
        var entry = header
        for component in components { entry += componentBytes(component) }
        if !instructions.isEmpty {
          entry += u16Bytes(instructions.count)
          entry += instructions
        }
        entries.append(entry)
      } else {
        entries.append(
          try readBytes(bytes, at: base, count: end - start, what: "simple glyph"))
      }
    }
    var newOffsets: [Int] = [0]
    for entry in entries {
      newOffsets.append(newOffsets.last! + entry.count)
    }
    // loca keeps the source format unless offsets overflow short form or
    // land on odd positions.
    var locaIsLong = inspector.locaIsLong
    if !locaIsLong, let biggest = newOffsets.max(),
      biggest % 2 != 0 || biggest > 0xFFFF * 2
    {
      locaIsLong = true
    }
    var newGlyf: [UInt8] = []
    for entry in entries { newGlyf += entry }
    var newLoca: [UInt8] = []
    for offset in newOffsets {
      if locaIsLong {
        newLoca += u32Bytes(offset)
      } else {
        newLoca += u16Bytes(offset / 2)
      }
    }
    // hmtx: every kept glyph gets its advance explicitly.
    var newHmtx: [UInt8] = []
    for old in ordered {
      newHmtx += u16Bytes(inspector.advances[old] ?? 0)
      newHmtx += u16Bytes(0)
    }
    // cmap: one format-4 table over the kept mappings (plus terminator).
    var kept: [(code: Int, glyph: Int)] = []
    for scalar in unicodes {
      if let old = inspector.unicodeToGlyph[scalar], let new = remap[old] {
        kept.append((scalar, new))
      }
    }
    kept.sort { $0.code < $1.code }
    let segCount = kept.count + 1
    var cmapBody: [UInt8] = []
    cmapBody += u16Bytes(4) + u16Bytes(0) + u16Bytes(0)  // format, length fixup, language
    cmapBody += u16Bytes(segCount * 2)
    let log = segCount > 1 ? Int(floor(log2(Double(segCount)))) : 0
    let searchRange = Int(pow(2.0, Double(log))) * 2
    cmapBody += u16Bytes(searchRange) + u16Bytes(log) + u16Bytes(segCount * 2 - searchRange)
    for entry in kept.map(\.code) + [0xFFFF] { cmapBody += u16Bytes(entry) }
    cmapBody += u16Bytes(0)  // reserved pad
    for entry in kept.map(\.code) + [0xFFFF] { cmapBody += u16Bytes(entry) }
    for _ in kept { cmapBody += u16Bytes(0) }  // idDelta (identity via glyph array)
    cmapBody += u16Bytes(1)
    for _ in kept {
      // Every glyph entry packs after all range offsets, so each segment
      // shares one offset: the glyph array address minus this value's own.
      cmapBody += u16Bytes((kept.count + 1) * 2)
    }
    cmapBody += u16Bytes(0)  // terminator segment offset
    for entry in kept { cmapBody += u16Bytes(entry.glyph) }
    let cmapLength = cmapBody.count
    cmapBody[2] = UInt8((cmapLength >> 8) & 0xFF)
    cmapBody[3] = UInt8(cmapLength & 0xFF)
    let cmapTable: [UInt8] =
      u16Bytes(0) + u16Bytes(1)  // version, one subtable
      + u16Bytes(3) + u16Bytes(1) + u32Bytes(12)  // platform 3, encoding 1, offset 12
      + cmapBody
    // maxp: same version, new glyph count.
    guard let maxpTable = inspector.tables["maxp"],
      maxpTable.length >= 6,
      maxpTable.offset + maxpTable.length <= bytes.count
    else {
      throw PDFError(.malformed, "TrueType maxp table is unusable")
    }
    var newMaxp = Array(bytes[maxpTable.offset..<maxpTable.offset + maxpTable.length])
    newMaxp[4] = UInt8((ordered.count >> 8) & 0xFF)
    newMaxp[5] = UInt8(ordered.count & 0xFF)
    // hhea: new horizontal metric count.
    guard let hheaTable = inspector.tables["hhea"],
      hheaTable.length >= 36,
      hheaTable.offset + hheaTable.length <= bytes.count
    else {
      throw PDFError(.malformed, "TrueType hhea table is unusable")
    }
    var newHhea = Array(bytes[hheaTable.offset..<hheaTable.offset + hheaTable.length])
    newHhea[34] = UInt8((ordered.count >> 8) & 0xFF)
    newHhea[35] = UInt8(ordered.count & 0xFF)
    // head: checkSumAdjustment zeroes for now; indexToLocFormat on upgrade.
    guard let headTable = inspector.tables["head"],
      headTable.length >= 54,
      headTable.offset + headTable.length <= bytes.count
    else {
      throw PDFError(.malformed, "TrueType head table is unusable")
    }
    var newHead = Array(bytes[headTable.offset..<headTable.offset + headTable.length])
    newHead[8] = 0; newHead[9] = 0; newHead[10] = 0; newHead[11] = 0
    let wasLong = inspector.locaIsLong
    if locaIsLong, !wasLong {
      newHead[50] = 0; newHead[51] = 1
    }
    // post format 2: prune the glyph-name index array, keep the string pool.
    var newPost: [UInt8]? = nil
    if let postTable = inspector.tables["post"],
      postTable.length >= 32,
      postTable.offset + postTable.length <= bytes.count
    {
      let format = (try TrueTypeInspector.u16(bytes, at: postTable.offset)) * 65536
        + (try TrueTypeInspector.u16(bytes, at: postTable.offset + 2))
      if format == 0x00020000 {
        let keptCount = try TrueTypeInspector.u16(bytes, at: postTable.offset + 32)
        if keptCount == inspector.glyphCount {
          var pruned = Array(bytes[postTable.offset..<postTable.offset + 34])
          pruned[32] = UInt8((ordered.count >> 8) & 0xFF)
          pruned[33] = UInt8(ordered.count & 0xFF)
          for old in ordered {
            let at = postTable.offset + 34 + old * 2
            guard at + 2 <= postTable.offset + postTable.length else {
              throw PDFError(.malformed, "TrueType post table is truncated")
            }
            pruned += [bytes[at], bytes[at + 1]]
          }
          pruned += bytes[(postTable.offset + 34 + keptCount * 2)..<(postTable.offset + postTable.length)]
          newPost = pruned
        }
      }
    }
    // Verbatim tables (no glyph references): name, OS/2, cvt, fpgm, prep,
    // gasp, and post when it is not pruned above.
    func verbatim(_ tag: String) throws -> [UInt8] {
      guard let table = inspector.tables[tag],
        table.offset + table.length <= bytes.count
      else {
        throw PDFError(.malformed, "TrueType \(tag) table runs past the program")
      }
      return Array(bytes[table.offset..<table.offset + table.length])
    }
    var rebuilt: [String: [UInt8]] = [:]
    rebuilt["glyf"] = newGlyf
    rebuilt["loca"] = newLoca
    rebuilt["hmtx"] = newHmtx
    rebuilt["cmap"] = cmapTable
    rebuilt["maxp"] = newMaxp
    rebuilt["hhea"] = newHhea
    rebuilt["head"] = newHead
    if let post = newPost {
      rebuilt["post"] = post
    } else if inspector.tables["post"] != nil {
      rebuilt["post"] = try verbatim("post")
    }
    for tag in ["name", "OS/2", "cvt ", "fpgm", "prep", "gasp"] {
      if inspector.tables[tag] != nil {
        rebuilt[tag] = try verbatim(tag)
      }
    }
    // sfnt directory: sorted tags, aligned tables, per-table checksums.
    let tags = rebuilt.keys.sorted()
    let count = tags.count
    var directory: [UInt8] = []
    directory += u32Bytes(0x00010000)
    directory += u16Bytes(count)
    let dirLog = count > 1 ? Int(floor(log2(Double(count)))) : 0
    let dirSearch = Int(pow(2.0, Double(dirLog))) * 16
    directory += u16Bytes(dirSearch) + u16Bytes(dirLog) + u16Bytes(count * 16 - dirSearch)
    var offset = 12 + count * 16
    var file: [UInt8] = []
    var records: [UInt8] = []
    var headPosition = 0
    for tag in tags {
      while offset % 4 != 0 { offset += 1 }
      let payload = rebuilt[tag]!
      if tag == "head" { headPosition = offset }
      records += Array(tag.utf8)
      records += u32Bytes(checksum(payload))
      records += u32Bytes(offset)
      records += u32Bytes(payload.count)
      while file.count < offset - (12 + count * 16) { file.append(0) }
      file += payload
      offset += payload.count
    }
    var result = directory + records + file
    // Whole-file checksum adjustment.
    var sum = 0
    var index = 0
    while index < result.count {
      var word = 0
      for slot in 0..<4 {
        word = word * 256 + (index + slot < result.count ? Int(result[index + slot]) : 0)
      }
      sum = (sum + word) & 0xFFFF_FFFF
      index += 4
    }
    let adjustment = (0xB1B0AFBA - sum) & 0xFFFF_FFFF
    let at = headPosition + 8
    result[at] = UInt8((adjustment >> 24) & 0xFF)
    result[at + 1] = UInt8((adjustment >> 16) & 0xFF)
    result[at + 2] = UInt8((adjustment >> 8) & 0xFF)
    result[at + 3] = UInt8(adjustment & 0xFF)
    return Data(result)
  }
}

/// P14-016: conservative per-glyph ink bounds from an embedded TrueType
/// program. Parsed once, queried per glyph; empty glyphs (for example a
/// space) return nil so callers keep their fallback estimate. CFF programs
/// have no glyf headers and always return nil.
public struct TrueTypeOutlineMetrics: Sendable {
  public let inspector: TrueTypeInspector
  private let program: [UInt8]

  public init(program: Data, requireUnicodeMap: Bool = true) throws {
    self.inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: requireUnicodeMap)
    self.program = [UInt8](program)
  }

  /// The glyf header box `[xMin, yMin, xMax, yMax]` in font units for one
  /// glyph, or nil for empty glyphs, CFF programs, and out-of-range IDs.
  /// The header box of a composite glyph is the font's own conservative
  /// union of its components (verified against fontTools on the fixture).
  public func bounds(glyphID: Int) -> [Int]? {
    guard !inspector.isCFF, glyphID >= 0, glyphID < inspector.glyphCount,
      inspector.glyphOffsets.count > glyphID + 1,
      let glyf = inspector.tables["glyf"]
    else { return nil }
    let start = inspector.glyphOffsets[glyphID]
    let end = inspector.glyphOffsets[glyphID + 1]
    // An empty glyph (equal loca offsets) has no outline data.
    guard end > start, start >= 0, end <= glyf.length else { return nil }
    let base = glyf.offset + start
    // glyf header: int16 numberOfContours, then xMin, yMin, xMax, yMax.
    guard base + 10 <= program.count else { return nil }
    func value(at offset: Int) -> Int {
      let raw = Int(program[base + offset]) * 256 + Int(program[base + offset + 1])
      return raw >= 0x8000 ? raw - 0x1_0000 : raw
    }
    return [value(at: 2), value(at: 4), value(at: 6), value(at: 8)]
  }

  /// The ink box of one Unicode scalar, in font units, when the cmap maps
  /// it to a non-empty glyph.
  public func bounds(scalar: Int) -> [Int]? {
    guard let glyph = inspector.unicodeToGlyph[scalar] else { return nil }
    return bounds(glyphID: glyph)
  }
}

/// P15-007: a caller-supplied font program for writing, with the family name
/// used for resource bookkeeping. The app sources programs from provisioned
/// (embeddable) fonts; tests use the committed DejaVu subset.
public struct CustomTextFont: Sendable, Equatable {
  public let program: Data
  public let familyName: String
  /// User-facing face label used by native previews and font menus.
  public let faceName: String
  /// Stable identity for one installed font file; unlike the family name it
  /// distinguishes regular, italic, and variable files in the same family.
  public let identifier: String
  /// The face's built-in style. Inline formatting may synthesize a bold stroke
  /// only when this font program itself is not already bold.
  public let isBold: Bool
  public let isItalic: Bool

  public init(
    program: Data, familyName: String, faceName: String? = nil, identifier: String? = nil,
    isBold: Bool = false, isItalic: Bool = false
  ) {
    self.program = program
    self.familyName = familyName
    self.faceName = faceName ?? familyName
    self.identifier = identifier ?? faceName ?? familyName
    self.isBold = isBold
    self.isItalic = isItalic
  }
}

/// P15-007/P15-021/P15-022: a font selected for writing — either an existing
/// graph font reused as-is or a newly embedded (subset) program. Internal
/// plumbing between font selection and the text renderer below.
enum WritableTextFont: Sendable, Equatable {
  case graph(font: SimpleFont, resourceName: PDFName)
  case embedded(written: WrittenFont, resourceName: PDFName)

  public var resourceName: PDFName {
    switch self {
    case .graph(_, let name): return name
    case .embedded(_, let name): return name
    }
  }

  public func encode(_ line: String) -> [UInt8]? {
    switch self {
    case .graph(let font, _):
      return font.encode(line)
    case .embedded(let written, _):
      return written.encode(line)
    }
  }

  public func advance(of codes: [UInt8], fontSize: Double) -> Double? {
    switch self {
    case .graph(let font, _):
      return font.advance(
        of: codes, fontSize: fontSize, charSpacing: 0, wordSpacing: 0,
        horizontalScale: 1)
    case .embedded(let written, _):
      var total = 0.0
      for code in codes {
        guard let width = written.widths[code] else { return nil }
        total += Double(width) / 1000 * fontSize
      }
      return total
    }
  }
}

/// P15-012/P15-014: a composite (Type0/Identity-H) font written from an
/// embedded program — CIDFontType2 for TrueType outlines, CIDFontType0 for
/// CFF outlines, with identity CID-to-GID mapping, W widths, and ToUnicode.
public struct WrittenCompositeFont: Sendable, Equatable {
  /// Tagged base name (subset tag plus family) for Type0/BaseFont use.
  public let baseName: String
  /// Unicode scalar value to CID (CIDs run 0...n in coverage order).
  public let encoding: [Int: Int]
  /// CID to advance width in thousandths of an em.
  public let widths: [Int: Int]
  /// The descendant font value (the assembler references it from the
  /// Type0 dictionary it builds with `type0Dictionary(descendant:)`).
  public let descendant: PDFValue
  public let descriptor: PDFValue
  /// The embedded program stream, with `/Subtype /OpenType` already set
  /// for CFF programs (FontFile3) and a bare stream for TrueType
  /// (FontFile2).
  public let fontFile: PDFStream
  public let toUnicode: PDFStream

  /// The Type0 dictionary referencing an assembled descendant object and
  /// the ToUnicode map. The map lives here (as in our OCR layers), matching
  /// Table 118 — readers do not consult the descendant for it.
  public func type0Dictionary(
    descendant descendantID: PDFObjectID, toUnicode cmapID: PDFObjectID, baseName: String
  ) -> PDFValue {
    .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type0")),
      PDFName("BaseFont"): .name(PDFName(baseName)),
      PDFName("Encoding"): .name(PDFName("Identity-H")),
      PDFName("DescendantFonts"): .array([.reference(descendantID)]),
      PDFName("ToUnicode"): .reference(cmapID),
    ])
  }

  /// Encode text as big-endian CIDs (P18-006: nil for unencodable text).
  public func encode(_ text: String) -> [UInt8]? {
    var bytes: [UInt8] = []
    for scalar in text.unicodeScalars {
      guard let cid = encoding[Int(scalar.value)] else { return nil }
      bytes.append(UInt8((cid >> 8) & 0xFF))
      bytes.append(UInt8(cid & 0xFF))
    }
    return bytes
  }
}

public enum CompositeFontWriter {
  /// Write `text` with `program`: TrueType programs are subset first;
  /// CFF programs embed whole (subsetting CFF is explicitly unsupported).
  /// CIDFontType2 backs TrueType outlines, CIDFontType0 backs CFF outlines.
  public static func write(
    program: Data, baseName: String, covering text: String
  ) throws -> WrittenCompositeFont {
    let inspector = try TrueTypeInspector.inspect(program)
    let needed = Set(text.unicodeScalars.map { Int($0.value) })
    guard !needed.isEmpty else {
      throw PDFError(.malformed, "No text to cover")
    }
    let embedded: Data
    let isCFF = inspector.isCFF
    if isCFF {
      embedded = program
    } else {
      embedded = try TrueTypeSubsetter.subset(program: program, unicodes: needed)
    }
    let tagged = "\(AddedContent.subsetTag(covering: needed))+\(baseName)"
    // CIDs run over the sorted coverage; the subset (or whole program for
    // CFF) must contain every needed glyph.
    let sub = try TrueTypeInspector.inspect(embedded)
    var encoding: [Int: Int] = [:]
    var widths: [Int: Int] = [:]
    for (cid, scalar) in needed.sorted().enumerated() {
      guard let glyph = sub.unicodeToGlyph[scalar],
        let advance = sub.advances[glyph]
      else {
        throw PDFError(
          .unsupported,
          "The font program has no glyph for U+\(String(scalar, radix: 16, uppercase: true))")
      }
      encoding[scalar] = cid
      widths[cid] = Int((Double(advance) * 1000 / Double(sub.unitsPerEm)).rounded())
    }
    let consecutive = (0..<needed.count).map { widths[$0] ?? 0 }
    let descendantSubtype = isCFF ? "CIDFontType0" : "CIDFontType2"
    let descendant: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName(descendantSubtype)),
      PDFName("BaseFont"): .name(PDFName(tagged)),
      PDFName("CIDSystemInfo"): .dictionary([
        PDFName("Registry"): .string(Data("Adobe".utf8)),
        PDFName("Ordering"): .string(Data("UCS".utf8)),
        PDFName("Supplement"): .integer(0),
      ]),
      PDFName("DW"): .integer(1000),
      PDFName("W"): .array([.integer(0), .array(consecutive.map { PDFValue.integer(Int64($0)) })]),
    ]
    var bfchar: [String] = []
    for scalar in needed.sorted() {
      let cid = encoding[scalar]!
      let destination: String
      if scalar <= 0xFFFF {
        destination = String(format: "<%04X>", scalar)
      } else {
        let adjusted = scalar - 0x1_0000
        destination = String(
          format: "<%04X%04X>", 0xD800 + adjusted / 0x400, 0xDC00 + adjusted % 0x400)
      }
      bfchar.append(String(format: "<%04X> %@", cid, destination))
    }
    let cmapText =
      "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo\n<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n\(bfchar.count) beginbfchar\n\(bfchar.joined(separator: "\n"))\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    var fileDictionary: [PDFName: PDFValue] = [:]
    if isCFF {
      // FontFile3 carries the CFF program with its subtype declared.
      fileDictionary[PDFName("Subtype")] = .name(PDFName("OpenType"))
    }
    return WrittenCompositeFont(
      baseName: tagged, encoding: encoding, widths: widths,
      descendant: .dictionary(descendant),
      descriptor: .dictionary(FontWriter.descriptor(baseName: tagged, inspector: sub)),
      fontFile: PDFStream(dictionary: fileDictionary, bytes: embedded),
      toUnicode: PDFStream(bytes: Data(cmapText.utf8)))
  }
}
