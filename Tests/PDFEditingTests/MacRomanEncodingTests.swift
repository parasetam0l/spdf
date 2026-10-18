import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

@Suite("PDF MacRoman encoding")
struct MacRomanEncodingTests {
  private func dictionary(_ value: PDFValue?) throws -> [PDFName: PDFValue] {
    guard case .dictionary(let dictionary)? = value else {
      throw PDFError(.malformed, "Fixture dictionary missing")
    }
    return dictionary
  }

  private func fixture(
    encoding: PDFValue = .name(PDFName("MacRomanEncoding")), cmap: String? = nil
  ) throws -> (PDFGraph, PDFObjectID, SimpleFont) {
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = PDFObjectID(3)
    let page = try dictionary(graph.objects[pageID])
    var font = try dictionary(graph.objects[PDFObjectID(4)])
    font[PDFName("Encoding")] = encoding
    if let cmap {
      font[PDFName("ToUnicode")] = .stream(PDFStream(bytes: Data(cmap.utf8)))
    }
    graph.objects[PDFObjectID(4)] = .dictionary(font)
    return (graph, pageID, try #require(SimpleFont.resolve(
      resource: PDFName("F1"), page: page, in: graph)))
  }

  @Test func annexDCharactersAndPDFOnlyUndefinedSlots() throws {
    let (_, _, font) = try fixture()
    #expect(font.isSupported && font.isEditable)
    // Annex D, codes 128–255, including undefined slots. This oracle uses
    // literal characters independently of the implementation's scalar table.
    let high = Array((
      "ÄÅÇÉÑÖÜáàâäãåçéèêëíìîïñóòôöõúùûü" +
      "†°¢£§•¶ß®©™´¨�ÆØ�±��¥µ�����ªº�æø" +
      "¿¡¬�ƒ��«»… ÀÃÕŒœ–—“”‘’÷�ÿŸ⁄¤‹›ﬁﬂ" +
      "‡·‚„‰ÂÊÁËÈÍÎÏÌÓÔ�ÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ").unicodeScalars)
    #expect(high.count == 128)
    for code in 0...255 {
      let expected: String
      if (32...126).contains(code) { expected = String(UnicodeScalar(code)!) }
      else if code >= 128 { expected = String(high[code - 128]) }
      else { expected = "�" }
      #expect(font.decode([UInt8(code)]) == expected, "code \(code)")
      if expected != "�" {
        let encoded = try #require(font.encode(expected))
        #expect(font.decode(encoded) == expected)
        #expect(encoded == [UInt8(code == 202 ? 32 : code)])
      }
    }
    // macOS Roman has extra symbols and Euro that PDF MacRoman does not.
    for text in ["≠", "∞", "≤", "≥", "∂", "∑", "∏", "π", "∫", "Ω", "√", "≈", "∆", "◊", "", "€", "\u{00A0}"] {
      #expect(font.encode(text) == nil)
    }
  }

  @Test func differencesAndToUnicodeCannotLeakOverriddenBaseGlyphs() throws {
    let encoding: PDFValue = .dictionary([
      PDFName("BaseEncoding"): .name(PDFName("MacRomanEncoding")),
      PDFName("Differences"): .array([
        .integer(65), .name(PDFName("uni2192")),
        .integer(219), .name(PDFName("euro")),
      ]),
    ])
    let (_, _, font) = try fixture(encoding: encoding)
    #expect(font.decode([65, 219]) == "→€")
    #expect(font.encode("→€") == [65, 219])
    #expect(font.encode("A") == nil)
    #expect(font.encode("¤") == nil)

    let (_, _, mapped) = try fixture(encoding: encoding, cmap: """
      1 begincodespacerange <00> <FF> endcodespacerange
      2 beginbfchar <41> <0042> <DB> <00A4> endbfchar
      """)
    #expect(mapped.decode([65, 219]) == "B¤")
    #expect(mapped.encode("B¤") == [65, 219])
    #expect(mapped.encode("A→€") == nil)
  }

  @Test(arguments: ["WinAnsiEncoding", "StandardEncoding", "MacRomanEncoding"])
  func unknownDifferencesRefuseEvenWithPartialToUnicode(base: String) throws {
    let (_, _, font) = try fixture(encoding: .dictionary([
      PDFName("BaseEncoding"): .name(PDFName(base)),
      PDFName("Differences"): .array([.integer(65), .name(PDFName("unknownGlyph"))]),
    ]), cmap: "1 beginbfchar <42> <0042> endbfchar")
    #expect(font.decode([65, 66]) == "�B")
    #expect(font.encode("A") == nil)
    #expect(font.encode("B") == [66])
  }

  @Test(arguments: ["WinAnsiEncoding", "StandardEncoding", "MacRomanEncoding"])
  func knownOverridesCannotWriteDisplacedBaseCharacters(base: String) throws {
    let (_, _, font) = try fixture(encoding: .dictionary([
      PDFName("BaseEncoding"): .name(PDFName(base)),
      PDFName("Differences"): .array([.integer(65), .name(PDFName("bullet"))]),
    ]))
    #expect(font.decode([65]) == "•")
    #expect(font.encode("A") == nil)
    #expect(font.encode("•") == [65])
    #expect(font.encode("B") == [66])
  }

  @Test func duplicateMappingsChooseDeterministicallyAndPreserveWordSpacingRules() throws {
    let (_, _, font) = try fixture(encoding: .dictionary([
      PDFName("BaseEncoding"): .name(PDFName("MacRomanEncoding")),
      PDFName("Differences"): .array([
        .integer(32), .name(PDFName("bullet")),
        .integer(100), .name(PDFName("uni2192")), .name(PDFName("uni2192")),
      ]),
    ]))
    #expect(font.encode(" ") == [202])
    #expect(font.encode("→") == [100])
    #expect(font.decode([32, 202]) == "• ")
    let ordinary = try #require(font.advance(of: [32], fontSize: 20,
      charSpacing: 1, wordSpacing: 7, horizontalScale: 100))
    let duplicate = try #require(font.advance(of: [202], fontSize: 20,
      charSpacing: 1, wordSpacing: 7, horizontalScale: 100))
    #expect(ordinary == (font.width(of: 32)! / 1_000 * 20 + 8))
    #expect(duplicate == (font.width(of: 202)! / 1_000 * 20 + 1))
  }

  @Test func replacementReopensWithOriginalFontObjectsAndExtendedBytes() throws {
    var (original, pageID, _) = try fixture()
    // Exercise an indirect encoding dictionary and its indirect base name.
    original.objects[PDFObjectID(80)] = .dictionary([
      PDFName("BaseEncoding"): .reference(PDFObjectID(81))])
    original.objects[PDFObjectID(81)] = .name(PDFName("MacRomanEncoding"))
    var font = try dictionary(original.objects[PDFObjectID(4)])
    font[PDFName("Encoding")] = .reference(PDFObjectID(80))
    original.objects[PDFObjectID(4)] = .dictionary(font)
    let replacement = "Café ‘fi’ ﬁ £¤"
    #expect(TextEditabilityCheck.assess(pageID: pageID, runIndex: 0, in: original).isEditable)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: replacement)
    ]), to: original)
    let content = try PageContent.load(pageID: pageID, in: edited)
    let contentIDs = Set(content.segments.map(\.objectID))
    for (id, value) in original.objects where !contentIDs.contains(id) {
      #expect(edited.objects[id] == value)
    }
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: reopened.graph),
      graph: reopened.graph)
    #expect(runs.first?.text == replacement)
    #expect(runs.dropFirst().map(\.text) == (try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: original), graph: original)).dropFirst().map(\.text))
    #expect(reopened.graph.objects[PDFObjectID(4)] == original.objects[PDFObjectID(4)])
  }
}
