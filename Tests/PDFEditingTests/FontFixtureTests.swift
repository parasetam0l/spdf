import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P03-010/P03-011: the embedded DejaVu Sans subset fixtures — known Unicode
/// mappings from a real font program, WinAnsi fallback when ToUnicode lacks
/// a code, Differences ligature decoding, and zero-width codes without
/// glyphs in the subset.
@Suite("Embedded font fixtures")
struct FontFixtureTests {
  private func layout(of data: Data, pageIndex: Int = 0) throws -> PageTextLayout {
    let parsed = try PDFParser.parse(data)
    let content = try PageContent.load(pageID: parsed.pageIDs[pageIndex], in: parsed.graph)
    return try PageTextLayout.build(in: content, graph: parsed.graph)
  }

  private func toUnicodeMap(in data: Data) throws -> ToUnicodeCMap {
    let parsed = try PDFParser.parse(data)
    for object in parsed.graph.objects.values {
      if case .dictionary(let dictionary) = object,
        dictionary[PDFName("Subtype")] == .name(PDFName("TrueType")),
        case .reference(let cmapID)? = dictionary[PDFName("ToUnicode")],
        case .stream(let stream)? = parsed.graph.objects[cmapID],
        let cmap = ToUnicodeCMap(stream: stream)
      {
        return cmap
      }
    }
    throw PDFError(.malformed, "No ToUnicode map in the fixture")
  }

  @Test func embeddedSubsetDecodesABCAndTheLigature() throws {
    let data = try PDFFixtures.fontEmbeddedPages()
    let page = try layout(of: data)
    #expect(page.lines.count == 2)
    #expect(page.text(in: page.lines[0]) == "ABC")
    #expect(page.text(in: page.lines[1]) == "ﬁ")
    // Every code resolves through the ToUnicode map (no fallback needed).
    let cmap = try toUnicodeMap(in: data)
    #expect(cmap.decode(0x41) == "A")
    #expect(cmap.decode(0x43) == "C")
    #expect(cmap.decode(0x01) == "ﬁ")
    // Advances come from the real program metrics (A = 684 thousandths).
    #expect(page.clusters[0].text == "A")
  }

  @Test func outlineMetricsMatchIndependentFontToolsValues() throws {
    // P14-016: glyf header boxes, independently verified with fontTools on
    // the committed program (units/em 2048).
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("test font program is corrupt")
      return
    }
    let metrics = try TrueTypeOutlineMetrics(program: program)
    #expect(metrics.inspector.unitsPerEm == 2048)
    #expect(metrics.bounds(scalar: 0x41) == [16, 0, 1384, 1493])  // A
    // Lowercase a is present as a glyph (a composite component) but has no
    // cmap entry; query it by glyph ID (order: .notdef, space, A, B, C, a).
    #expect(metrics.bounds(scalar: 0x61) == nil)
    #expect(metrics.bounds(glyphID: 5) == [123, -29, 1069, 1147])  // a (descends)
    #expect(metrics.bounds(scalar: 0xE2) == [123, -29, 1069, 1638])  // acircumflex (composite)
    #expect(metrics.bounds(scalar: 0xFB01) == [47, 0, 1098, 1556])  // fi ligature
    #expect(metrics.bounds(scalar: 0x20) == nil)  // space is empty
    #expect(metrics.bounds(scalar: 0x44) == nil)  // no glyph for D in the subset
    #expect(metrics.bounds(glyphID: 0) == [102, -362, 1126, 1444])  // .notdef
    #expect(metrics.bounds(glyphID: 99) == nil)
    // CFF programs have no glyf headers: nil, never a fabricated box.
    guard let cff = Data(base64Encoded: FontFixtureData.cffProgramBase64) else {
      Issue.record("test CFF program is corrupt")
      return
    }
    let cffMetrics = try TrueTypeOutlineMetrics(program: cff)
    #expect(cffMetrics.bounds(scalar: 0x41) == nil)
  }

  @Test func multilingualExtractionAndGeometryMatchTheProgram() throws {
    // P14-026: the licensed multilingual fixture (DejaVu: Greek, Cyrillic,
    // Hebrew) extracts exactly and its geometry follows the document widths
    // and program ink boxes, verified against fontTools values.
    let data = try PDFFixtures.multilingualPages()
    let page = try layout(of: data)
    #expect(page.lines.count == 3)
    #expect(page.text(in: page.lines[0]) == "ΑΒΓ")
    #expect(page.text(in: page.lines[1]) == "БВ")
    // The fixture stores Hebrew in the visual order RTL generators emit;
    // the owned layout has no bidi, so it returns the file order. The
    // independent reader applies bidi and returns reading order (verified
    // in the MacServices suite).
    #expect(page.text(in: page.lines[2]) == "שבא")
    // Advances come from the widths the fixture carries (program metrics):
    // Α 1401/2048 -> 684 thousandths; ש 1451/2048 -> 708.
    let alpha = page.clusters[page.lines[0].lowerBound]
    #expect(alpha.text == "Α")
    #expect(abs((alpha.advance ?? 0) - 684.0 * 24 / 1000) < 1e-9)
    let shin = page.clusters[page.lines[2].lowerBound]
    #expect(shin.text == "ש")
    #expect(abs((shin.advance ?? 0) - 708.0 * 24 / 1000) < 1e-9)
    // Ink boxes from the embedded program, independently verified with
    // fontTools on the generated subset.
    guard let program = Data(base64Encoded: FontFixtureData.multilingualProgramBase64) else {
      Issue.record("multilingual program is corrupt")
      return
    }
    let metrics = try TrueTypeOutlineMetrics(program: program)
    #expect(metrics.bounds(scalar: 0x0391) == [16, 0, 1384, 1493])  // Α
    #expect(metrics.bounds(scalar: 0x0392) == [201, 0, 1260, 1493])  // Β
    #expect(metrics.bounds(scalar: 0x0393) == [201, 0, 1130, 1493])  // Γ
    #expect(metrics.bounds(scalar: 0x0411) == [201, 0, 1260, 1493])  // Б
    #expect(metrics.bounds(scalar: 0x05D0) == [186, 0, 1183, 1120])  // א
    #expect(metrics.bounds(scalar: 0x05E9) == [88, 0, 1363, 1120])  // ש
    // The cluster box is the conservative union: ink inside the estimate
    // keeps the estimate (never shrinks).
    #expect(abs(shin.bounds[2] - (42 + 708.0 * 24 / 1000)) < 1e-9)
    #expect(shin.bounds[3] == 620 + 24)
  }

  @Test func verticalWritingDecodesButLayoutIsNotClaimed() throws {
    // P14-027: the vertical fixture's Type0 Identity-V font parses with
    // vertical metrics and its codes decode to the intended Greek; layout
    // does not fabricate geometry for vertical writing (P16-008 stays
    // open) — the non-claim is asserted, not implied.
    let data = try PDFFixtures.verticalTextPages()
    let parsed = try PDFParser.parse(data)
    let pageID = parsed.pageIDs[0]
    guard case .dictionary(let page)? = parsed.graph.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(let fontDictionary)? = parsed.graph.objects[fontID],
      let font = CompositeFont.parse(fontDictionary, in: parsed.graph, objectID: fontID)
    else {
      Issue.record("vertical font did not resolve")
      return
    }
    #expect(font.hasVerticalMetrics)
    #expect(font.encodingName == "Identity-V")
    let decoded = try font.decode([0x00, 0x01, 0x00, 0x02, 0x00, 0x03])
    #expect(decoded.text == "ΑΒΓ")
    #expect(decoded.glyphs.allSatisfy { $0.byteLength == 2 })
    // Layout: Type0 text is out of the supported profile; no clusters.
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    #expect(layout.clusters.isEmpty)
  }

  @Test func subsetFallsBackAndFlagsMissingGlyphs() throws {    let data = try PDFFixtures.fontSubsetPages()
    // C is absent from ToUnicode: extraction still yields it through the
    // WinAnsi fallback, but the map itself has no entry (proven below).
    let page = try layout(of: data)
    #expect(page.text(in: page.lines[0]) == "ABC")
    let cmap = try toUnicodeMap(in: data)
    #expect(cmap.decode(0x43) == nil)
    // D maps to U+0044 yet has no glyph in the subset: its Widths entry is
    // zero, so consumers render .notdef while extraction stays exact.
    let second = try layout(of: data, pageIndex: 1)
    #expect(second.text(in: second.lines[0]) == "AD")
    let parsed = try PDFParser.parse(data)
    var zeroWidth = false
    for object in parsed.graph.objects.values {
      if case .dictionary(let dictionary) = object,
        dictionary[PDFName("Subtype")] == .name(PDFName("TrueType")),
        case .array(let widths)? = dictionary[PDFName("Widths")]
      {
        // FirstChar 32, so D (68) sits at index 36.
        if case .integer(let width)? = widths[safe: 36] {
          zeroWidth = width == 0
        }
      }
    }
    #expect(zeroWidth)
  }
}
