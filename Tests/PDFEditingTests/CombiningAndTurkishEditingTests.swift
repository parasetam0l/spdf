import CoreGraphics
import CoreText
import Foundation
import PDFCore
import PDFFixtures
import PDFKit
import Testing

@testable import PDFEditing

/// FNT-04: Core Text shaped graphemes survive editing. Combining-accent
/// examples (base + U+0301, decomposed dotted İ) and Turkish İ/ı are stored,
/// selected, deleted, replaced and re-read as complete graphemes with the
/// correct Unicode in the independent reader.
@Suite("Combining and Turkish editing")
struct CombiningAndTurkishEditingTests {
  private func program() throws -> Data {
    guard let program = Data(base64Encoded: ShapingFixtureData.programBase64) else {
      throw PDFError(.malformed, "The shaping fixture program is corrupt")
    }
    return program
  }

  private func coreTextFont(_ program: Data, size: Double = 16) -> CTFont {
    if let descriptors = CTFontManagerCreateFontDescriptorsFromData(program as CFData)
      as? [CTFontDescriptor], let descriptor = descriptors.first
    {
      return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
    return CTFontCreateWithName("Helvetica" as CFString, size, nil)
  }

  private func assemble(
    _ written: WrittenCompositeFont, lines: [String], baselines: [Double]
  ) throws -> (data: Data, fontID: PDFObjectID, pageID: PDFObjectID) {
    guard case .dictionary(let descendant) = written.descendant,
      case .dictionary(let descriptor) = written.descriptor
    else { throw PDFError(.malformed, "Composite structures malformed") }
    let fontID = PDFObjectID(4)
    let pageID = PDFObjectID(3)
    var content = Data()
    for (index, line) in lines.enumerated() {
      guard let codes = written.encode(line) else {
        throw PDFError(.malformed, "The written font cannot encode \(line)")
      }
      content.append(Data("BT /F1 16 Tf 42 \(baselines[index]) Td <".utf8))
      content.append(contentsOf: codes.map { String(format: "%02X", $0) }.joined().utf8)
      content.append(Data("> Tj ET\n".utf8))
    }
    var descendantWithRefs = descendant
    descendantWithRefs[PDFName("FontDescriptor")] = .reference(PDFObjectID(6))
    if written.cidToGIDMap != nil {
      descendantWithRefs[PDFName("CIDToGIDMap")] = .reference(PDFObjectID(10))
    }
    var descriptorWithFile = descriptor
    let fileKey = written.fontFile.dictionary[PDFName("Subtype")] == nil
      ? PDFName("FontFile2") : PDFName("FontFile3")
    descriptorWithFile[fileKey] = .reference(PDFObjectID(7))
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(pageID)]),
      ]),
      pageID: .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(5)),
      ]),
      fontID: written.type0Dictionary(
        descendant: PDFObjectID(9), toUnicode: PDFObjectID(8), baseName: written.baseName,
        encodingCMap: written.encodingCMap == nil ? nil : PDFObjectID(11)),
      PDFObjectID(5): .stream(PDFStream(bytes: content)),
      PDFObjectID(6): .dictionary(descriptorWithFile),
      PDFObjectID(7): .stream(written.fontFile),
      PDFObjectID(8): .stream(written.toUnicode),
      PDFObjectID(9): .dictionary(descendantWithRefs),
    ]
    if let map = written.cidToGIDMap { objects[PDFObjectID(10)] = .stream(map) }
    if let encodingCMap = written.encodingCMap { objects[PDFObjectID(11)] = .stream(encodingCMap) }
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return (try PDFWriter.write(graph), fontID, pageID)
  }

  private func pageFont(
    _ graph: PDFGraph, pageID: PDFObjectID, resource: PDFName = PDFName("F1")
  ) throws -> (page: [PDFName: PDFValue], font: IndexedTextFont) {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Missing page")
    }
    let font = try #require(IndexedTextFont.resolve(resource: resource, page: page, in: graph))
    return (page, font)
  }

  private func sourceGlyphs(_ run: TextRun, font: IndexedTextFont) throws -> [PDFSourceGlyph] {
    let glyphs = try #require(font.glyphs(run.rawCodes))
    return glyphs.map { PDFSourceGlyph(text: $0.text, codes: $0.codes) }
  }

  private func runs(_ graph: PDFGraph, pageID: PDFObjectID) throws -> [TextRun] {
    try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
  }

  private func renderDarkPixels(_ data: Data) throws -> Int {
    let document = try #require(PDFDocument(data: data))
    let page = try #require(document.page(at: 0))
    let width = 153
    let height = 198
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { pointer in
      guard let context = CGContext(
        data: pointer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.saveGState()
      context.scaleBy(x: CGFloat(width) / 612, y: CGFloat(height) / 792)
      page.draw(with: .cropBox, to: context)
      context.restoreGState()
    }
    var dark = 0
    for pixel in 0..<(width * height) {
      if buffer[pixel * 4] < 200 && buffer[pixel * 4 + 1] < 200
        && buffer[pixel * 4 + 2] < 200
      {
        dark += 1
      }
    }
    return dark
  }

  // MARK: - Grapheme-safe caret and deletion

  @Test func coreTextShapingKeepsTurkishAndCombiningGraphemesWhole() throws {
    let font = coreTextFont(try program())
    let text = "İstanbul ıI e\u{0301}x I\u{0307}stanbul"
    let shaped = ScriptShaping.shape(text, font: font)
    #expect(shaped.isLogicallyOrdered)
    #expect(shaped.coversAllSourceOffsets)
    #expect(shaped.clusters.map(\.text).joined() == text)
    // Every Turkish letter is one cluster; the decomposed accent pair and the
    // decomposed dotted capital are one cluster each.
    let accented = try #require(shaped.clusters.first { $0.text == "e\u{0301}" })
    #expect(accented.sourceRange.count == 2)
    #expect(accented.graphemeCount == 1)
    let decomposedDotted = try #require(shaped.clusters.first { $0.text == "I\u{0307}" })
    #expect(decomposedDotted.graphemeCount == 1)
    let dottedCapital = try #require(shaped.clusters.first { $0.text == "İ" })
    #expect(dottedCapital.sourceRange.count == 1)
    // Caret positions stop only on grapheme boundaries.
    let boundaries = ScriptGraphemes.boundaries(in: text)
    var caret = 0
    var visited: [Int] = [caret]
    for _ in 0..<40 {
      let next = ScriptGraphemes.caretOffset(caret, movingForward: true, in: text)
      if next == caret { break }
      caret = next
      visited.append(caret)
      #expect(ScriptGraphemes.isBoundary(caret, in: text))
    }
    #expect(visited == boundaries)
    // Deleting backwards after the accent removes base and mark together.
    let accentStart = accented.sourceRange.lowerBound
    #expect(
      ScriptGraphemes.deleteBackward(at: accentStart + 2, in: text)
        == accentStart..<(accentStart + 2))
    #expect(
      ScriptGraphemes.replacing(
        accentStart..<(accentStart + 1), in: text, with: "") .contains("e\u{0301}") == false)
    // The two Turkish case forms stay distinct and intact.
    #expect(ScriptGraphemes.uppercased("istanbul", localeIdentifier: "tr") == "İSTANBUL")
    #expect(ScriptGraphemes.lowercased("I", localeIdentifier: "tr") == "ı")
  }

  @Test func inlineWritingAllowsOnlyCompleteCombiningGraphemes() throws {
    #expect(PageTextSourceFont.canWriteInline("e\u{0301}"))
    #expect(PageTextSourceFont.canWriteInline("İstanbul"))
    #expect(PageTextSourceFont.canWriteInline("I\u{0307}stanbul"))
    #expect(PageTextSourceFont.canWriteInline("e\u{0301}\u{0307}"))
    #expect(!PageTextSourceFont.canWriteInline("\u{0301}e"))
    #expect(!PageTextSourceFont.canWriteInline("\u{0301}"))
  }

  // MARK: - Output and edit evidence

  @Test func combiningAccentOutputAndMapKeepOneAtomicGrapheme() throws {
    let program = try program()
    let written = try CompositeFontWriter.write(
      program: program, baseName: "DejaVuSans", covering: "e\u{0301}x")
    let assembled = try assemble(written, lines: ["e\u{0301}x"], baselines: [700])
    let graph = try PDFParser.parse(assembled.data).graph
    let allRuns = try runs(graph, pageID: assembled.pageID)
    #expect(allRuns.map(\.text) == ["e\u{0301}x"])
    let (_, font) = try pageFont(graph, pageID: assembled.pageID)
    let glyphs = try sourceGlyphs(try #require(allRuns.first), font: font)
    #expect(glyphs.map(\.text) == ["e", "\u{0301}", "x"])
    #expect(glyphs[0].codes.count == 2)
    #expect(glyphs[1].codes.count == 2)
    let shaped = ScriptShaping.shape("e\u{0301}x", font: coreTextFont(program))
    let map = try GlyphClusterSourceMap(text: "e\u{0301}x", glyphs: glyphs, shaped: shaped)
    let accented = try #require(map.clusters.first)
    #expect(accented.text == "e\u{0301}")
    #expect(accented.sourceRange == 0..<2)
    #expect(accented.pdfGlyphRange == 0..<2)
    #expect(accented.codeRange == 0..<4)
    // Editing the mark alone or the base alone snaps to both stored codes.
    let markRemoved = try map.applying(replacing: 1..<2, with: "", encoded: [])
    #expect(markRemoved.replacedRange == 0..<2)
    #expect(markRemoved.text == "x")
    #expect(try font.decode(markRemoved.codes) == "x")
    let replacement = try #require(written.encode("e\u{0301}"))
    let baseReplaced = try map.applying(replacing: 0..<1, with: "e\u{0301}", encoded: replacement)
    #expect(baseReplaced.text == "e\u{0301}x")
    #expect(try font.decode(baseReplaced.codes) == "e\u{0301}x")
    // The independent reader extracts the accented letter (decomposed or
    // composed canonical form) and renders ink for the complete grapheme.
    let document = try #require(PDFDocument(data: assembled.data))
    let extracted = try #require(document.string)
    #expect(extracted.contains("e\u{0301}") || extracted.contains("é"))
    #expect(try renderDarkPixels(assembled.data) > 5)
  }

  @Test func editKeepsTurkishAndCombiningUnicodeThroughSaveReopen() throws {
    let program = try program()
    let written = try CompositeFontWriter.write(
      program: program, baseName: "DejaVuSans",
      covering: "e\u{0301}xistanbulİı")
    let assembled = try assemble(
      written, lines: ["e\u{0301}x", "istanbul"], baselines: [700, 680])
    let graph = try PDFParser.parse(assembled.data).graph
    let originalRuns = try runs(graph, pageID: assembled.pageID)
    #expect(originalRuns.map(\.text) == ["e\u{0301}x", "istanbul"])
    // The combining run is discoverable as an editable text block now that
    // complete graphemes are writable.
    let blocks = try PageTextEditing.blocks(pageID: assembled.pageID, in: graph)
    #expect(blocks.contains { $0.text == "e\u{0301}x" })
    #expect(blocks.contains { $0.text == "istanbul" })
    let lines = [
      PageTextLine(text: "e\u{0301}ı", x: 42, baseline: 700),
      PageTextLine(text: "İstanbul", x: 42, baseline: 680),
    ]
    let command = RewritePageTextCommand(
      pageID: assembled.pageID,
      originalText: [0: "e\u{0301}x", 1: "istanbul"],
      lines: lines, fontSize: 16, color: [0, 0, 0])
    try command.validate(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    #expect(edited.objects[assembled.fontID] == graph.objects[assembled.fontID])
    let saved = try PDFWriter.write(edited)
    let document = try #require(PDFDocument(data: saved))
    let extracted = try #require(document.string)
    #expect(extracted.contains("İstanbul"))
    #expect(extracted.contains("e\u{0301}") || extracted.contains("é"))
    #expect(extracted.contains("ı"))
    #expect(try renderDarkPixels(saved) > 20)
    // Reopen: the same encoding decodes the intended Unicode, and the accent
    // line still shapes to one complete grapheme cluster.
    let reopened = try PDFParser.parse(saved).graph
    let reopenedRuns = try runs(reopened, pageID: assembled.pageID)
    #expect(reopenedRuns.map(\.text) == ["e\u{0301}ı", "İstanbul"])
    let (_, font) = try pageFont(reopened, pageID: assembled.pageID)
    let accentGlyphs = try sourceGlyphs(try #require(reopenedRuns.first), font: font)
    let shaped = ScriptShaping.shape("e\u{0301}ı", font: coreTextFont(program))
    let map = try GlyphClusterSourceMap(
      text: "e\u{0301}ı", glyphs: accentGlyphs, shaped: shaped)
    let accented = try #require(map.clusters.first)
    #expect(accented.text == "e\u{0301}")
    #expect(accented.codeRange.count == 4)
    // Turkish dotted/dotless letters keep their own scalars (no case folding).
    #expect(reopenedRuns[1].text.unicodeScalars.first?.value == 0x0130)
    #expect(reopenedRuns[0].text.unicodeScalars.last?.value == 0x0131)
  }
}
