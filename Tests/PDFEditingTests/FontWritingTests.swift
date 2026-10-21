import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P15-009–P15-015: TrueType inspection with bounds checks and full-program
/// embedding with generated descriptors, simple-font resources, and
/// ToUnicode maps.
@Suite("Font writing")
struct FontWritingTests {
  private var fontProgram: Data {
    get throws {
      guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
        throw PDFError(.malformed, "Test font program is corrupt")
      }
      return program
    }
  }

  private func dictionary(_ value: PDFValue) throws -> [PDFName: PDFValue] {
    guard case .dictionary(let dictionary) = value else {
      throw PDFError(.malformed, "Expected a dictionary value")
    }
    return dictionary
  }

  private func packaged(_ written: WrittenFont, text: Data) throws -> Data {
    var font = try dictionary(written.fontDictionary)
    font[PDFName("FontDescriptor")] = .reference(PDFObjectID(6))
    font[PDFName("ToUnicode")] = .reference(PDFObjectID(8))
    var descriptor = try dictionary(written.descriptor)
    descriptor[PDFName("FontFile2")] = .reference(PDFObjectID(7))
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary(font),
        PDFObjectID(5): .stream(PDFStream(bytes: text)),
        PDFObjectID(6): .dictionary(descriptor),
        PDFObjectID(7): .stream(written.fontFile),
        PDFObjectID(8): .stream(written.toUnicode),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    _ = try PDFParser.parse(data)
    return data
  }

  @Test func inspectorReadsSubsetMetrics() throws {
    let inspector = try TrueTypeInspector.inspect(try fontProgram)
    #expect(inspector.unitsPerEm == 2048)
    #expect(inspector.glyphCount == 9)
    #expect(inspector.locaIsLong == false)
    #expect(inspector.unicodeToGlyph[0x41] != nil)
    #expect(inspector.unicodeToGlyph[0x42] != nil)
    #expect(inspector.unicodeToGlyph[0x43] != nil)
    #expect(inspector.unicodeToGlyph[0xFB01] != nil)
    #expect(inspector.unicodeToGlyph[0x44] == nil)
    #expect(inspector.advances[inspector.unicodeToGlyph[0x41]!] == 1401)
    #expect(inspector.ascent == 1901)
    #expect(inspector.descent == -483)
    #expect(inspector.fontBBox == [-2090, -948, 3673, 2524])
    #expect(inspector.glyphOffsets.count == 10)
    #expect(inspector.italicAngle == 0)
  }

  @Test func simpleSubsetGlyphLookupResolvesCodeCollisionsByWidth() {
    // A platform-1 cmap keyed by PDF bytes can make U+0020 and U+002C look
    // like unrelated glyph IDs in the merged Unicode lookup. The source
    // byte mappings remain usable when exactly one candidate matches /Widths.
    let inspector = TrueTypeInspector(
      tables: [:], unitsPerEm: 1_000, ascent: 800, descent: -200,
      fontBBox: [0, -200, 1_000, 800], italicAngle: 0, glyphCount: 45,
      embeddingFlags: nil, locaIsLong: false, isCFF: false,
      unicodeToGlyph: [0x20: 32, 0x2C: 44],
      platform1CodeToGlyph: [10: 10, 14: 14],
      advances: [10: 317, 14: 317, 32: 684, 44: 636],
      glyphOffsets: Array(repeating: 0, count: 45))

    #expect(IndexedTextFont.verifiedSimpleGlyphID(
      scalar: 0x20, code: 10, width: 317, inspector: inspector) == 10)
    #expect(IndexedTextFont.verifiedSimpleGlyphID(
      scalar: 0x2C, code: 14, width: 317, inspector: inspector) == 14)
    #expect(IndexedTextFont.verifiedSimpleGlyphID(
      scalar: 0x20, code: 10, width: 318, inspector: inspector) == 10)
    #expect(IndexedTextFont.verifiedSimpleGlyphID(
      scalar: 0x20, code: 10, width: 500, inspector: inspector) == nil)

    let ambiguous = TrueTypeInspector(
      tables: [:], unitsPerEm: 1_000, ascent: 800, descent: -200,
      fontBBox: [0, -200, 1_000, 800], italicAngle: 0, glyphCount: 45,
      embeddingFlags: nil, locaIsLong: false, isCFF: false,
      unicodeToGlyph: [0x20: 32], platform1CodeToGlyph: [10: 10],
      advances: [10: 317, 32: 317], glyphOffsets: Array(repeating: 0, count: 45))
    #expect(IndexedTextFont.verifiedSimpleGlyphID(
      scalar: 0x20, code: 10, width: 317, inspector: ambiguous) == nil)
  }

  @Test func inspectorRefusesTruncatedAndForeignPrograms() throws {
    let program = try fontProgram
    #expect(throws: PDFError.self) {
      try TrueTypeInspector.inspect(program.prefix(64))
    }
    #expect(throws: PDFError.self) {
      try TrueTypeInspector.inspect(Data("not a font at all........".utf8))
    }
    do {
      _ = try TrueTypeInspector.inspect(Data("not a font at all........".utf8))
      Issue.record("expected a refusal")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    } catch {
      Issue.record("wrong error type \(error)")
    }
  }

  @Test func embeddingCoversTextWithWinAnsiAndDifferences() throws {
    let written = try FontWriter.writeTrueType(
      program: fontProgram, baseName: "DejaVuSans", covering: "ABCﬁ")
    // WinAnsi codes for A/B/C, a Differences code for the ligature.
    #expect(written.encoding[0x41] == 0x41)
    #expect(written.encoding[0x42] == 0x42)
    #expect(written.encoding[0x43] == 0x43)
    let fiCodes = written.encoding.filter { $0.value == 0xFB01 }.map(\.key)
    #expect(fiCodes.count == 1)
    #expect(fiCodes[0] < 32)
    #expect(written.widths[0x41] == 684)
    // Encoding refuses unencodable text instead of substituting.
    #expect(written.encode("AB") == [0x41, 0x42])
    #expect(written.encode("caf\u{E9}") == nil)
    #expect(written.encode("\u{1F600}") == nil)
    // The font dictionary carries generated WinAnsi + Differences resources.
    guard case .dictionary(let font)? = Optional(written.fontDictionary),
      case .dictionary(let encoding)? = font[PDFName("Encoding")],
      case .array(let widths)? = font[PDFName("Widths")]
    else {
      Issue.record("font dictionary malformed")
      return
    }
    #expect(encoding[PDFName("BaseEncoding")] == .name(PDFName("WinAnsiEncoding")))
    #expect(encoding[PDFName("Differences")] != nil)
    #expect(widths.count == 67 - 1 + 1)  // FirstChar 1 (Differences) through LastChar 67
  }

  @Test func embeddedFontExtractsThroughLayout() throws {
    let written = try FontWriter.writeTrueType(
      program: fontProgram, baseName: "DejaVuSans", covering: "ABCﬁ")
    guard let abc = written.encode("ABC"), let fi = written.encode("ﬁ") else {
      Issue.record("encoding failed")
      return
    }
    var content = Data("BT /F1 24 Tf 42 700 Td (".utf8)
    content.append(contentsOf: abc)
    content.append(Data(") Tj ET\nBT /F1 24 Tf 42 660 Td (".utf8))
    content.append(contentsOf: fi)
    content.append(Data(") Tj ET\n".utf8))
    let data = try packaged(written, text: content)
    let parsed = try PDFParser.parse(data)
    let pageContent = try PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph)
    let layout = try PageTextLayout.build(in: pageContent, graph: parsed.graph)
    #expect(layout.lines.count == 2)
    #expect(layout.text(in: layout.lines[0]) == "ABC")
    #expect(layout.text(in: layout.lines[1]) == "ﬁ")
  }
}

extension FontWritingTests {
  /// P15-028: adding font resources changes nothing else — every original
  /// object round-trips identically and existing text extracts the same.
  @Test func fontAdditionsLeaveExistingTextUntouched() throws {
    let base = try PDFParser.parse(PDFFixtures.threePages())
    let before = try layoutOfThreePages(base)
    let written = try FontWriter.writeTrueType(
      program: fontProgram, baseName: "DejaVuSans", covering: "AB")
    var graph = base.graph
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    graph.objects[PDFObjectID(next)] = written.fontDictionary
    graph.objects[PDFObjectID(next + 1)] = written.descriptor
    graph.objects[PDFObjectID(next + 2)] = .stream(written.fontFile)
    graph.objects[PDFObjectID(next + 3)] = .stream(written.toUnicode)
    let data = try PDFWriter.write(graph)
    let reparsed = try PDFParser.parse(data)
    for (id, value) in base.graph.objects {
      #expect(reparsed.graph.objects[id] == value, "object \(id.number) changed")
    }
    #expect(try layoutOfThreePages(reparsed) == before)
    // P15-029 (partial): growth is bounded by the program plus structures.
    #expect(data.count - base.source.count < 20_000)
  }

  private func layoutOfThreePages(_ parsed: ParsedPDF) throws -> [String] {
    var texts: [String] = []
    for pageID in parsed.pageIDs {
      let content = try PageContent.load(pageID: pageID, in: parsed.graph)
      let layout = try PageTextLayout.build(in: content, graph: parsed.graph)
      texts.append(layout.lines.map { layout.text(in: $0) }.joined(separator: "\n"))
    }
    return texts
  }
}
