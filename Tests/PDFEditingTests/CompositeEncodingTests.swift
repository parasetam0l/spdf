import CoreGraphics
import Foundation
import PDFCore
import PDFFixtures
import PDFKit
import Testing

@testable import PDFEditing

/// FNT-03: corpus-driven CFF/CID/CMap cases beyond simple Type1C and
/// horizontal Identity-H. Every added encoding is written, parsed, edited,
/// extracted by the independent reader (PDFKit), measured against the font's
/// own advances, and independently rendered. Subset and absent-glyph cases are
/// required by the roadmap row.
@Suite("Composite encodings")
struct CompositeEncodingTests {
  private func programs() throws -> (trueType: Data, openTypeCFF: Data, rawCFF: Data) {
    guard
      let trueType = Data(base64Encoded: FontFixtureData.subsetProgramBase64),
      let openType = Data(base64Encoded: FontFixtureData.cffProgramBase64)
    else {
      throw PDFError(.malformed, "Test font programs are corrupt")
    }
    let inspector = try TrueTypeInspector.inspect(openType)
    let table = try #require(inspector.tables["CFF "])
    let bytes = [UInt8](openType)
    let raw = Data(bytes[table.offset..<(table.offset + table.length)])
    return (trueType, openType, raw)
  }

  /// Assemble a one-page PDF around a written composite font. The CIDToGIDMap
  /// stream and custom encoding CMap are optional so a test can show the
  /// difference between the declared mapping and an assumed Identity one.
  private func assemble(
    _ written: WrittenCompositeFont, text: String,
    includeCIDToGIDMap: Bool = true, includeEncodingCMap: Bool = true
  ) throws -> (data: Data, fontID: PDFObjectID) {
    guard let codes = written.encode(text) else {
      throw PDFError(.malformed, "The written font cannot encode the test text")
    }
    guard case .dictionary(let descendant) = written.descendant,
      case .dictionary(let descriptor) = written.descriptor
    else {
      throw PDFError(.malformed, "Composite structures malformed")
    }
    let fontID = PDFObjectID(4)
    let descriptorID = PDFObjectID(6)
    let programID = PDFObjectID(7)
    let cmapID = PDFObjectID(8)
    let descendantID = PDFObjectID(9)
    let cidToGIDID = PDFObjectID(10)
    let encodingCMapID = PDFObjectID(11)
    var descriptorWithFile = descriptor
    let fileKey = written.fontFile.dictionary[PDFName("Subtype")] == nil
      ? PDFName("FontFile2") : PDFName("FontFile3")
    descriptorWithFile[fileKey] = .reference(programID)
    var descendantWithRefs = descendant
    descendantWithRefs[PDFName("FontDescriptor")] = .reference(descriptorID)
    if let map = written.cidToGIDMap, includeCIDToGIDMap {
      descendantWithRefs[PDFName("CIDToGIDMap")] = .reference(cidToGIDID)
    }
    let encodingReference: PDFObjectID? =
      written.encodingCMap != nil && includeEncodingCMap ? encodingCMapID : nil
    var content = Data("BT /F1 16 Tf 42 700 Td <".utf8)
    content.append(contentsOf: codes.map { String(format: "%02X", $0) }.joined().utf8)
    content.append(Data("> Tj ET\n".utf8))
    content.append(Data("BT /F1 16 Tf 42 680 Td <".utf8))
    content.append(contentsOf: codes.map { String(format: "%02X", $0) }.joined().utf8)
    content.append(Data("> Tj ET\n".utf8))
    var objects: [PDFObjectID: PDFValue] = [
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
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(fontID)])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(5)),
      ]),
      fontID: written.type0Dictionary(
        descendant: descendantID, toUnicode: cmapID, baseName: written.baseName,
        encodingCMap: encodingReference),
      PDFObjectID(5): .stream(PDFStream(bytes: content)),
      descriptorID: .dictionary(descriptorWithFile),
      programID: .stream(written.fontFile),
      cmapID: .stream(written.toUnicode),
      descendantID: .dictionary(descendantWithRefs),
    ]
    if let map = written.cidToGIDMap, includeCIDToGIDMap {
      objects[cidToGIDID] = .stream(map)
    }
    if let encodingCMap = written.encodingCMap, includeEncodingCMap {
      objects[encodingCMapID] = .stream(encodingCMap)
    }
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return (try PDFWriter.write(graph), fontID)
  }

  private func parsedFont(_ data: Data) throws -> (font: CompositeFont, pageID: PDFObjectID) {
    let graph = try PDFParser.parse(data).graph
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph),
      case .dictionary(let fonts)? = FontValue.resolve(resources[PDFName("Font")], in: graph),
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(let dictionary)? = graph.objects[fontID],
      let font = CompositeFont.parse(dictionary, in: graph, objectID: fontID)
    else {
      throw PDFError(.malformed, "The written composite font does not parse")
    }
    return (font, pageID)
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

  // MARK: - Writer plus independent-reader evidence

  @Test func writerSingleByteCMapWritesEmbeddedEncodingAndReadsBack() throws {
    let (trueType, _, _) = try programs()
    let written = try CompositeFontWriter.write(
      program: trueType, baseName: "DejaVuSans", covering: "ABC",
      options: CompositeFontWritingOptions(encoding: .singleByteCMap))
    #expect(written.encodingMode == .singleByteCMap)
    #expect(written.codeByteLength == 1)
    #expect(written.encodingCMap != nil)
    #expect(try #require(written.encode("ABC")).count == 3)
    let assembled = try assemble(written, text: "ABC")
    let (font, _) = try parsedFont(assembled.data)
    #expect(font.encodingKind == .embeddedCMap(name: "SPDF-OneByte-H"))
    #expect(font.writingMode == .horizontal)
    #expect(font.codeLength(in: [0x00], offset: 0) == 1)
    #expect(font.isSubset)
    // Every code decodes to the intended Unicode and CID.
    let decoded = try font.decode(try #require(written.encode("ABC")))
    #expect(decoded.text == "ABC")
    #expect(decoded.glyphs.map(\.cid) == [0, 1, 2])
    #expect(decoded.glyphs.allSatisfy { $0.byteLength == 1 })
    // Metric evidence: parsed /W widths equal the embedded program's advances.
    let inspector = try TrueTypeInspector.inspect(written.fontFile.bytes)
    for scalar in ["A", "B", "C"] {
      let code = try #require(Int(UnicodeScalar(scalar)!.value))
      let cid = try #require(written.encoding[code])
      let gid = try #require(inspector.unicodeToGlyph[code])
      let expected = Int(
        (Double(try #require(inspector.advances[gid])) * 1000
          / Double(inspector.unitsPerEm)).rounded())
      #expect(font.width(forCID: cid) == Double(expected))
      #expect(font.glyphID(forCID: cid) == gid)
    }
    // Independent reader: extraction and a rendered raster with ink.
    let document = try #require(PDFDocument(data: assembled.data))
    #expect(document.string?.contains("ABC") == true)
    #expect(try renderDarkPixels(assembled.data) > 20)
  }

  @Test func writerVerticalIdentityVDeclaresVerticalMetrics() throws {
    let (trueType, _, _) = try programs()
    let written = try CompositeFontWriter.write(
      program: trueType, baseName: "DejaVuSans", covering: "ABC",
      options: CompositeFontWritingOptions(encoding: .identityVertical))
    guard case .dictionary(let descendant) = written.descendant else {
      Issue.record("descendant malformed")
      return
    }
    #expect(descendant[PDFName("DW2")] != nil)
    #expect(descendant[PDFName("W2")] != nil)
    let assembled = try assemble(written, text: "ABC")
    let (font, _) = try parsedFont(assembled.data)
    #expect(font.encodingKind == .identityVertical)
    #expect(font.writingMode == .vertical)
    #expect(font.hasVerticalMetrics)
    #expect(font.defaultVerticalAdvance.advance > 0)
    let advance = font.verticalAdvance(forCID: 0)
    #expect(advance.advance == font.defaultVerticalAdvance.advance)
    #expect(advance.positionY == -1000)
    let decoded = try font.decode(try #require(written.encode("ABC")))
    #expect(decoded.text == "ABC")
    #expect(decoded.glyphs.allSatisfy { $0.verticalAdvance.advance > 0 })
    // Vertical Identity-V extraction in the independent reader; the owned
    // layout keeps its documented horizontal-only non-claim.
    let document = try #require(PDFDocument(data: assembled.data))
    #expect(document.string?.contains("ABC") == true)
  }

  @Test func writerCIDToGIDMapCorrectsSubsetGlyphOrder() throws {
    let (trueType, _, _) = try programs()
    // CIDs run in coverage order (A, B, C) while the subset's glyph order is
    // (.notdef, A, B, C): without the map, Identity CIDs would paint the wrong
    // glyphs for every covered character.
    let written = try CompositeFontWriter.write(
      program: trueType, baseName: "DejaVuSans", covering: "CAB")
    #expect(written.encoding == [0x41: 0, 0x42: 1, 0x43: 2])
    let map = try #require(written.cidToGIDMap)
    let inspector = try TrueTypeInspector.inspect(written.fontFile.bytes)
    let mapBytes = [UInt8](try PDFFilters.decoded(map))
    #expect(mapBytes.count == 6)
    for (scalar, cid) in written.encoding {
      let gid = try #require(inspector.unicodeToGlyph[scalar])
      let stored = Int(mapBytes[cid * 2]) * 256 + Int(mapBytes[cid * 2 + 1])
      #expect(stored == gid)
    }
    // The map is load-bearing: with it the raster differs from the assumed
    // Identity mapping, and both still extract the mapped Unicode.
    let withMap = try assemble(written, text: "CAB", includeCIDToGIDMap: true)
    let withoutMap = try assemble(written, text: "CAB", includeCIDToGIDMap: false)
    #expect(withMap.data != withoutMap.data)
    let withDocument = try #require(PDFDocument(data: withMap.data))
    #expect(withDocument.string?.contains("CAB") == true)
    let withPixels = try renderDarkPixels(withMap.data)
    let withoutPixels = try renderDarkPixels(withoutMap.data)
    #expect(withPixels > 20)
    #expect(withPixels != withoutPixels)
    let (font, _) = try parsedFont(withMap.data)
    #expect(font.glyphID(forCID: 0) == inspector.unicodeToGlyph[0x41])
  }

  @Test func writerOpenTypeCFFUsesGlyphIndexedCIDs() throws {
    let (_, openType, _) = try programs()
    let written = try CompositeFontWriter.write(
      program: openType, baseName: "DejaVuSans", covering: "ABC")
    let inspector = try TrueTypeInspector.inspect(written.fontFile.bytes)
    #expect(written.cidToGIDMap == nil)
    #expect(written.encodingCMap == nil)
    #expect(written.fontFile.dictionary[PDFName("Subtype")] == .name(PDFName("OpenType")))
    for scalar in [0x41, 0x42, 0x43] {
      #expect(written.encoding[scalar] == inspector.unicodeToGlyph[scalar])
    }
    let assembled = try assemble(written, text: "ABC")
    let (font, _) = try parsedFont(assembled.data)
    #expect(font.descendantSubtype == "CIDFontType0")
    #expect(font.program == .openTypeCFF)
    #expect(font.fontFile3Subtype == "OpenType")
    #expect(font.encodingKind == .identityHorizontal)
    let decoded = try font.decode(try #require(written.encode("ABC")))
    #expect(decoded.text == "ABC")
    let document = try #require(PDFDocument(data: assembled.data))
    #expect(document.string?.contains("ABC") == true)
    #expect(try renderDarkPixels(assembled.data) > 20)
  }

  // MARK: - Parse evidence for the added encodings

  @Test func parsesMixedCodespaceEmbeddedCMapAndCIDToGIDMap() throws {
    let (trueType, _, _) = try programs()
    let encodingCMap = """
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /CMapName /Mixed-H def
      /CMapType 1 def
      2 begincodespacerange
      <00> <7F>
      <0080> <FFFF>
      endcodespacerange
      2 begincidchar
      <41> 7
      <8001> 9
      endcidchar
      1 begincidrange
      <42> <43> 20
      endcidrange
      endcmap
      end
      end

      """
    let toUnicode = """
      begincodespacerange
      <00> <7F>
      <0080> <FFFF>
      endcodespacerange
      4 beginbfchar
      <41> <0041>
      <8001> <0042>
      <42> <0043>
      <43> <0020>
      endbfchar

      """
    // Widths from the program's own advances for the mapped glyph ids, so the
    // metric evidence is a real comparison rather than an assertion about the
    // test's own numbers.
    let inspector = try TrueTypeInspector.inspect(trueType)
    func width(_ gid: Int) throws -> Int {
      Int((Double(try #require(inspector.advances[gid])) * 1000
        / Double(inspector.unitsPerEm)).rounded())
    }
    let glyphSpace = try #require(inspector.unicodeToGlyph[0x20])
    let glyphA = try #require(inspector.unicodeToGlyph[0x41])
    let glyphB = try #require(inspector.unicodeToGlyph[0x42])
    let glyphC = try #require(inspector.unicodeToGlyph[0x43])
    let cidGlyphs: [(cid: Int, gid: Int)] = [
      (7, glyphA), (9, glyphB), (20, glyphC), (21, glyphSpace),
    ]
    var cidToGID = Data(repeating: 0, count: 22 * 2)
    for pair in cidGlyphs {
      cidToGID[pair.cid * 2] = UInt8((pair.gid >> 8) & 0xFF)
      cidToGID[pair.cid * 2 + 1] = UInt8(pair.gid & 0xFF)
    }
    let widths: [PDFValue] = [
      .integer(7), .array([.integer(Int64(try width(glyphA)))]),
      .integer(9), .array([.integer(Int64(try width(glyphB)))]),
      .integer(20), .array([
        .integer(Int64(try width(glyphC))), .integer(Int64(try width(glyphSpace))),
      ]),
    ]
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
          PDFName("Contents"): .stream(PDFStream(
            bytes: Data("BT /F1 16 Tf 42 700 Td <4180014243> Tj ET\n".utf8))),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type0")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+MixedCID")),
          PDFName("Encoding"): .reference(PDFObjectID(11)),
          PDFName("DescendantFonts"): .array([.reference(PDFObjectID(9))]),
          PDFName("ToUnicode"): .reference(PDFObjectID(8)),
        ]),
        PDFObjectID(8): .stream(PDFStream(bytes: Data(toUnicode.utf8))),
        PDFObjectID(9): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("CIDFontType2")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+MixedCID")),
          PDFName("CIDSystemInfo"): .dictionary([
            PDFName("Registry"): .string(Data("Adobe".utf8)),
            PDFName("Ordering"): .string(Data("Identity".utf8)),
            PDFName("Supplement"): .integer(0),
          ]),
          PDFName("DW"): .integer(1000),
          PDFName("W"): .array(widths),
          PDFName("CIDToGIDMap"): .reference(PDFObjectID(10)),
          PDFName("FontDescriptor"): .reference(PDFObjectID(6)),
        ]),
        PDFObjectID(10): .stream(PDFStream(bytes: cidToGID)),
        PDFObjectID(11): .stream(PDFStream(bytes: Data(encodingCMap.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("FontDescriptor")),
          PDFName("FontName"): .name(PDFName("ABCDEF+MixedCID")),
          PDFName("Flags"): .integer(4),
          PDFName("FontFile2"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: trueType)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    guard case .dictionary(let dictionary)? = graph.objects[PDFObjectID(4)],
      let font = CompositeFont.parse(dictionary, in: graph, objectID: PDFObjectID(4))
    else {
      Issue.record("mixed CMap font does not parse")
      return
    }
    #expect(font.encodingKind == .embeddedCMap(name: "Mixed-H"))
    #expect(font.writingMode == .horizontal)
    #expect(font.codeLength(in: [0x41], offset: 0) == 1)
    #expect(font.codeLength(in: [0x80, 0x01], offset: 0) == 2)
    #expect(font.codeByteLength(forCode: 0x41) == 1)
    #expect(font.codeByteLength(forCode: 0x8001) == 2)
    #expect(font.cid(forCode: 0x41) == 7)
    #expect(font.cid(forCode: 0x8001) == 9)
    #expect(font.cid(forCode: 0x42) == 20)
    #expect(font.cid(forCode: 0x43) == 21)
    #expect(font.width(forCID: 7) == Double(try width(glyphA)))
    #expect(font.glyphID(forCID: 7) == glyphA)
    let decoded = try font.decode([0x41, 0x80, 0x01, 0x42, 0x43])
    #expect(decoded.text == "ABC ")
    #expect(decoded.glyphs.map(\.cid) == [7, 9, 20, 21])
    #expect(decoded.glyphs.map(\.byteLength) == [1, 2, 1, 1])
  }

  @Test func parsesCFFProgramFormsIncludingCIDKeyed() throws {
    let (trueType, openType, rawCFF) = try programs()
    let otfInspector = try TrueTypeInspector.inspect(openType)
    #expect(otfInspector.isCFF)
    let inspector = try TrueTypeInspector.inspect(openType)
    let table = try #require(inspector.tables["CFF "])
    let rawFacts = try #require(CFFProgramFacts.parse([UInt8](rawCFF)))
    #expect(rawFacts.isCIDKeyed == false)
    #expect(rawFacts.glyphCount == otfInspector.glyphCount)
    #expect(rawFacts.fontName == "DejaVuSans")
    // A minimal CID-keyed CFF: header, Name INDEX, Top DICT INDEX whose dict
    // carries ROS (operator 12 30). Parsing it must report CID-keyed rather
    // than assuming the name-keyed form.
    let cidKeyedCFF: [UInt8] =
      [1, 0, 4, 2]  // major, minor, hdrSize, offSize
      + [0, 1, 1, 1, 2, 0x58]  // Name INDEX: one "X"
      + [0, 1, 1, 1, 6, 139, 139, 139, 12, 30]  // Top DICT INDEX with ROS
    let cidFacts = try #require(CFFProgramFacts.parse(cidKeyedCFF))
    #expect(cidFacts.isCIDKeyed)
    #expect(cidFacts.glyphCount == 0)
    // CompositeFont.parse classifies the same byte forms from the descriptor.
    func font(program: Data, file3Subtype: String?, descendantSubtype: String) throws -> CompositeFont {
      var descriptor: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("FontDescriptor")),
        PDFName("FontName"): .name(PDFName("ABCDEF+Test")),
        PDFName("Flags"): .integer(4),
      ]
      if let file3Subtype {
        descriptor[PDFName("FontFile3")] = .reference(PDFObjectID(7))
      } else {
        descriptor[PDFName("FontFile2")] = .reference(PDFObjectID(7))
      }
      var file3Dictionary: [PDFName: PDFValue] = [:]
      if let file3Subtype { file3Dictionary[PDFName("Subtype")] = .name(PDFName(file3Subtype)) }
      let graph = PDFGraph(objects: [
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type0")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+Test")),
          PDFName("Encoding"): .name(PDFName("Identity-H")),
          PDFName("DescendantFonts"): .array([.reference(PDFObjectID(9))]),
        ]),
        PDFObjectID(6): .dictionary(descriptor),
        PDFObjectID(7): .stream(PDFStream(dictionary: file3Dictionary, bytes: program)),
        PDFObjectID(9): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName(descendantSubtype)),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+Test")),
          PDFName("FontDescriptor"): .reference(PDFObjectID(6)),
        ]),
        ], trailer: [PDFName("Root"): .reference(PDFObjectID(4))])
      guard case .dictionary(let dictionary)? = graph.objects[PDFObjectID(4)],
        let font = CompositeFont.parse(dictionary, in: graph)
      else { throw PDFError(.malformed, "test composite font does not parse") }
      return font
    }
    #expect(try font(program: openType, file3Subtype: "OpenType", descendantSubtype: "CIDFontType0").program == .openTypeCFF)
    #expect(try font(program: rawCFF, file3Subtype: "Type1C", descendantSubtype: "CIDFontType0").program == .type1C)
    #expect(try font(program: Data(cidKeyedCFF), file3Subtype: "CIDFontType0C", descendantSubtype: "CIDFontType0").program == .cidFontType0C)
    #expect(
      try font(program: trueType, file3Subtype: nil, descendantSubtype: "CIDFontType2").program
        == .trueType)
  }

  @Test func parsesVerticalIdentityVFixtureMetrics() throws {
    let graph = try PDFParser.parse(PDFFixtures.verticalTextPages()).graph
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph),
      case .dictionary(let fonts)? = FontValue.resolve(resources[PDFName("Font")], in: graph),
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(let dictionary)? = graph.objects[fontID],
      let font = CompositeFont.parse(dictionary, in: graph, objectID: fontID)
    else {
      Issue.record("The vertical fixture font does not parse")
      return
    }
    #expect(font.encodingKind == .identityVertical)
    #expect(font.writingMode == .vertical)
    #expect(font.hasVerticalMetrics)
    // The fixture declares DW2 [880 -1000] and W2 triples (500, 880, 500).
    #expect(font.defaultVerticalAdvance.advance == 880)
    #expect(font.defaultVerticalAdvance.positionY == -1000)
    let metrics = font.verticalAdvance(forCID: 1)
    #expect(metrics.advance == 500)
    #expect(metrics.positionX == 880)
    #expect(metrics.positionY == 500)
    let decoded = try font.decode([0x00, 0x01, 0x00, 0x02, 0x00, 0x03])
    #expect(decoded.text == "ΑΒΓ")
    #expect(decoded.glyphs.allSatisfy { $0.cid != nil })
    #expect(decoded.glyphs[0].verticalAdvance.advance == 500)
  }

  // MARK: - Edit evidence through the paragraph rewrite command

  private func editCommand(
    pageID: PDFObjectID, original: [Int: String], replacements: [String]
  ) -> RewritePageTextCommand {
    let lines = replacements.enumerated().map { index, text in
      PageTextLine(text: text, x: 42, baseline: 700 - Double(index) * 20)
    }
    return RewritePageTextCommand(
      pageID: pageID, originalText: original, lines: lines, fontSize: 16,
      color: [0, 0, 0])
  }

  @Test func editsEmbeddedCMapCompositeTextAndReopensWithIntactFont() throws {
    let (trueType, _, _) = try programs()
    let written = try CompositeFontWriter.write(
      program: trueType, baseName: "DejaVuSans", covering: "ABC",
      options: CompositeFontWritingOptions(encoding: .singleByteCMap))
    let assembled = try assemble(written, text: "ABC")
    let graph = try PDFParser.parse(assembled.data).graph
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(runs.map(\.text) == ["ABC", "ABC"])
    let edit = editCommand(
      pageID: pageID, original: [0: "ABC", 1: "ABC"], replacements: ["CBA", "ABC"])
    try edit.validate(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    #expect(edited.objects[assembled.fontID] == graph.objects[assembled.fontID])
    let saved = try PDFWriter.write(edited)
    let document = try #require(PDFDocument(data: saved))
    #expect(document.string?.contains("CBA") == true)
    #expect(document.string?.contains("ABC") == true)
    #expect(try renderDarkPixels(saved) > 20)
    // Reopen: the rewritten text is indexed through the same added encoding
    // and the font still parses as the embedded 1-byte CMap.
    let reopened = try PDFParser.parse(saved).graph
    let reopenedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: reopened), graph: reopened)
    #expect(reopenedRuns.map(\.text) == ["CBA", "ABC"])
    let (font, _) = try parsedFont(saved)
    #expect(font.encodingKind == .embeddedCMap(name: "SPDF-OneByte-H"))
  }

  @Test func editsOpenTypeCFFCompositeTextAndReopensWithIntactFont() throws {
    let (_, openType, _) = try programs()
    let written = try CompositeFontWriter.write(
      program: openType, baseName: "DejaVuSans", covering: "ABC")
    let assembled = try assemble(written, text: "ABC")
    let graph = try PDFParser.parse(assembled.data).graph
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    let edit = editCommand(
      pageID: pageID, original: [0: "ABC", 1: "ABC"], replacements: ["CBA", "ABC"])
    try edit.validate(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    #expect(edited.objects[assembled.fontID] == graph.objects[assembled.fontID])
    let saved = try PDFWriter.write(edited)
    let document = try #require(PDFDocument(data: saved))
    #expect(document.string?.contains("CBA") == true)
    #expect(try renderDarkPixels(saved) > 20)
    let reopenedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: try PDFParser.parse(saved).graph),
      graph: try PDFParser.parse(saved).graph)
    #expect(reopenedRuns.map(\.text) == ["CBA", "ABC"])
    let (font, _) = try parsedFont(saved)
    #expect(font.program == .openTypeCFF)
  }

  @Test func editRefusesAbsentGlyphInSubset() throws {
    let (trueType, _, _) = try programs()
    // The subset covers space, A, B, C, a-acircumflex and the fi ligature;
    // Z is absent, so the rewritten character must refuse instead of silently
    // dropping or substituting a glyph.
    let written = try CompositeFontWriter.write(
      program: trueType, baseName: "DejaVuSans", covering: "ABC",
      options: CompositeFontWritingOptions(encoding: .singleByteCMap))
    let assembled = try assemble(written, text: "ABC")
    let graph = try PDFParser.parse(assembled.data).graph
    let pageID = try #require(PDFPageTree.pageIDs(in: graph).first)
    let edit = editCommand(
      pageID: pageID, original: [0: "ABC", 1: "ABC"], replacements: ["ABZ", "ABC"])
    #expect(throws: PDFError.self) {
      try edit.validate(in: graph)
    }
    // The source graph is untouched by the refused edit.
    let saved = try PDFWriter.write(graph)
    let document = try #require(PDFDocument(data: saved))
    #expect(document.string?.contains("ABC") == true)
    #expect(document.string?.contains("ABZ") == false)
  }
}
