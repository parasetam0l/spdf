import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P14-002–P14-029: composite Type0 parsing, codespace-aware ToUnicode
/// decoding, missing-mapping policy, widths, subset prefixes, and the bounded
/// mapping cache.
@Suite("Composite fonts")
struct CompositeFontTests {
  @Test func identityCMapArrayRangesAndAdjacentTokensDecodeWithoutGuessing() throws {
    var (source, id) = graph(withToUnicode: true)
    source.objects[PDFObjectID(14)] = .stream(PDFStream(bytes: Data("""
      1 begincodespacerange <0000><FFFF> endcodespacerange
      1 beginbfrange <0001><0003>[<0041><0042><00660069>] endbfrange
      """.utf8)))
    guard case .dictionary(let dictionary)? = source.objects[id],
      let font = CompositeFont.parse(dictionary, in: source, objectID: id) else {
      Issue.record("Missing font"); return
    }
    #expect(try font.decode([0, 1, 0, 2, 0, 3]).text == "ABfi")
  }
  private func graph(withToUnicode: Bool) -> (PDFGraph, PDFObjectID) {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
      ]),
      PDFObjectID(4): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(10))])
        ]),
        PDFName("Contents"): .stream(PDFStream(bytes: Data("q Q\n".utf8))),
      ]),
      PDFObjectID(11): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("CIDFontType2")),
        PDFName("BaseFont"): .name(PDFName("ABCDEF+CustomCID")),
        PDFName("CIDToGIDMap"): .name(PDFName("Identity")),
        PDFName("DW"): .integer(500),
        PDFName("W"): .array([.integer(1), .array([.integer(600), .integer(700)])]),
        PDFName("DW2"): .array([.integer(880), .integer(-1000)]),
        PDFName("FontDescriptor"): .reference(PDFObjectID(12)),
      ]),
      PDFObjectID(12): .dictionary([
        PDFName("Type"): .name(PDFName("FontDescriptor")),
        PDFName("FontName"): .name(PDFName("ABCDEF+CustomCID")),
        PDFName("Flags"): .integer(4),
        PDFName("FontFile2"): .reference(PDFObjectID(13)),
      ]),
      PDFObjectID(13): .stream(PDFStream(bytes: Data([0, 1, 2, 3]))),
    ]
    var type0: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type0")),
      PDFName("BaseFont"): .name(PDFName("ABCDEF+CustomCID")),
      PDFName("Encoding"): .name(PDFName("Identity-H")),
      PDFName("DescendantFonts"): .array([.reference(PDFObjectID(11))]),
    ]
    if withToUnicode {
      type0[PDFName("ToUnicode")] = .reference(PDFObjectID(14))
      let cMap = """
        begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        1 beginbfchar
        <0003> <006600660069>
        endbfchar
        2 beginbfrange
        <0001> <0002> <0041>
        <0004> <0005> <0061>
        endbfrange

        """
      objects[PDFObjectID(14)] = .stream(PDFStream(bytes: Data(cMap.utf8)))
    }
    objects[PDFObjectID(10)] = .dictionary(type0)
    return (
      PDFGraph(
        version: "1.7", objects: objects,
        trailer: [PDFName("Root"): .reference(PDFObjectID(1))]),
      PDFObjectID(10)
    )
  }

  @Test func parsesType0FactsAndDecodesWithCodespaces() throws {
    let (graph, fontID) = graph(withToUnicode: true)
    guard case .dictionary(let dictionary)? = graph.objects[fontID] else {
      Issue.record("font missing")
      return
    }
    let font = try #require(CompositeFont.parse(dictionary, in: graph, objectID: fontID))
    #expect(font.baseFont == "ABCDEF+CustomCID")
    #expect(font.isSubset)  // P14-020: subset prefix detected, not identity
    #expect(font.encodingName == "Identity-H")
    #expect(font.hasCIDToGIDMap)
    #expect(font.cidToGIDMapIdentity)
    #expect(font.defaultWidth == 500)
    #expect(font.hasVerticalMetrics)
    #expect(font.isEmbedded)
    #expect(font.hasUnicodeCMap)

    // Codes: 0x0001 → "A", 0x0002 → "B" (bfrange start), 0x0003 → ligature
    // "ffi", 0x0005 → "b".
    let bytes: [UInt8] = [0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x05]
    let result = try font.decode(bytes)
    #expect(result.text == "ABffib")
    #expect(result.unmappedCount == 0)
    #expect(result.glyphs.count == 4)
    #expect(result.glyphs[2].unicode == "ffi")
    #expect(result.glyphs[0].byteLength == 2)
    #expect(result.glyphs[0].cid == 1)
    #expect(result.glyphs[0].width == 500)
    #expect(font.coverage().contains("subset"))
  }

  @Test func missingMappingsAreExplicitNeverSilentlyWrong() throws {
    let (graph, fontID) = graph(withToUnicode: false)
    guard case .dictionary(let dictionary)? = graph.objects[fontID] else {
      Issue.record("font missing")
      return
    }
    let font = try #require(CompositeFont.parse(dictionary, in: graph))
    #expect(!font.hasUnicodeCMap)
    let bytes: [UInt8] = [0x00, 0x41]
    // Default policy: fail explicitly (P14-019/P14-028).
    #expect(throws: CompositeFont.DecodeError.self) {
      _ = try font.decode(bytes)
    }
    // Explicit replacement policy flags the unmapped code instead.
    let replaced = try font.decode(bytes, policy: .replacementCharacter)
    #expect(replaced.hasUnmappedCodes)
    #expect(replaced.text == "\u{FFFD}")
    #expect(replaced.glyphs[0].unicode == "\u{FFFD}")
  }

  @Test func widthsComeFromWAndDW() throws {
    let (graph, fontID) = graph(withToUnicode: true)
    guard case .dictionary(let dictionary)? = graph.objects[fontID] else {
      Issue.record("font missing")
      return
    }
    let font = try #require(CompositeFont.parse(dictionary, in: graph))
    // The W array declares 600/700 for CIDs 1/2; others use DW.
    let result = try font.decode(
      [0x00, 0x01, 0x00, 0x02, 0x00, 0x09], policy: .replacementCharacter,
      widths: [1: 600, 2: 700])
    #expect(result.glyphs[0].width == 600)
    #expect(result.glyphs[1].width == 700)
    #expect(result.glyphs[2].width == 500)
  }

  @Test func mappingCacheIsBoundedAndMeasured() throws {
    let cache = FontMappingCache(owner: "session-1", capacity: 2)
    let first = PDFObjectID(10)
    let second = PDFObjectID(11)
    let third = PDFObjectID(12)
    cache.store("A", for: first)
    cache.store("B", for: second)
    #expect(cache.text(for: first) == "A")
    #expect(cache.text(for: second) == "B")
    // Eviction keeps the most recent entries bounded (P14-029).
    cache.store("C", for: third)
    #expect(cache.count == 2)
    #expect(cache.text(for: third) == "C")
    #expect(cache.text(for: first) == nil)
    #expect(cache.hits >= 2)
    #expect(cache.misses >= 1)
    cache.clear()
    #expect(cache.count == 0)
  }
}
