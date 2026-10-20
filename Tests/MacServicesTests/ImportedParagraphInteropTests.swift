import AppKit
import CoreText
import Foundation
@testable import MacServices
import PDFCore
@testable import PDFEditing
import PDFFixtures
import PDFKit
import Testing

@Suite("Imported paragraph editing")
struct ImportedParagraphInteropTests {
  @Test @MainActor func overlappingParagraphHitsPreferTheNearestParagraph() {
    let partial = PageTextTarget(pageIndex: 0, runIndex: 4,
      rect: [0, 0, 120, 20], text: "first source line", runIndices: [4, 5],
      paragraph: .init(originalText: [4: "first source line"], lineSpacing: 20,
        firstBaseline: 12, standardFontAdvances: [:], fragments: [], wraps: false))
    let complete = PageTextTarget(pageIndex: 0, runIndex: 4,
      rect: [0, 0, 180, 42], text: "first source line second source line", runIndices: [4, 5, 6, 7],
      paragraph: .init(originalText: [4: "first source line", 6: "second source line"],
        lineSpacing: 20, firstBaseline: 32, standardFontAdvances: [:], fragments: [], wraps: true))
    let fallback = PageTextTarget(pageIndex: 0, runIndex: 4,
      rect: [0, 0, 100, 20], text: "legacy run", runIndices: [4])

    #expect(NativeParagraphEditing.preferredHitTarget(from: [partial, fallback, complete],
      at: [90, 21]) == complete)
    #expect(NativeParagraphEditing.preferredHitTarget(from: [partial, fallback, complete],
      at: [60, 10]) == partial)
    #expect(NativeParagraphEditing.preferredHitTarget(from: [fallback], at: [60, 10]) == fallback)
  }

  @Test @MainActor func softWrapLineRangeDropsOnlyTrailingSeparatorWhitespace() {
    let text = NSString(string: " alpha \t\r\nbeta")
    let softRange = NSRange(location: 0, length: 8)
    let softContent = NativeParagraphEditing.lineContentRange(
      softRange, in: text, hasHardBreak: false)
    #expect(text.substring(with: softContent) == " alpha")

    let hardRange = NSRange(location: 0, length: 10)
    let hardContent = NativeParagraphEditing.lineContentRange(
      hardRange, in: text, hasHardBreak: true)
    #expect(text.substring(with: hardContent) == " alpha \t")
  }

  private func fixture(composite: Bool, adjusted: Bool = false) throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.fontEmbeddedPages())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    let text = "ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC"
    var instructions = ""
    if composite {
      let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
      let inspector = try TrueTypeInspector.inspect(program)
      let coverage = Set(text.unicodeScalars.map { Int($0.value) }).sorted()
      let entries = try coverage.map { value -> String in
        let glyph = try #require(inspector.unicodeToGlyph[value])
        return String(format: "<%04X> <%04X>", glyph, value)
      }.joined(separator: "\n")
      let widths = try coverage.flatMap { value -> [PDFValue] in
        let glyph = try #require(inspector.unicodeToGlyph[value])
        let advance = try #require(inspector.advances[glyph])
        return [.integer(Int64(glyph)), .array([.real((Double(advance) * 1000 / Double(inspector.unitsPerEm)).rounded())])]
      }
      graph.objects[PDFObjectID(20)] = .dictionary([
        PDFName("Type"): .name(PDFName("Font")), PDFName("Subtype"): .name(PDFName("CIDFontType2")),
        PDFName("BaseFont"): .name(PDFName("ABCDEF+DejaVuSans")),
        PDFName("CIDSystemInfo"): .dictionary([PDFName("Registry"): .string(Data("Adobe".utf8)),
          PDFName("Ordering"): .string(Data("Identity".utf8)), PDFName("Supplement"): .integer(0)]),
        PDFName("FontDescriptor"): .reference(PDFObjectID(6)),
        PDFName("CIDToGIDMap"): .name(PDFName("Identity")), PDFName("W"): .array(widths)])
      graph.objects[PDFObjectID(21)] = .stream(PDFStream(bytes: Data("""
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        1 begincodespacerange <0000> <FFFF> endcodespacerange
        \(coverage.count) beginbfchar
        \(entries)
        endbfchar endcmap end end
        """.utf8)))
      graph.objects[PDFObjectID(4)] = .dictionary([
        PDFName("Type"): .name(PDFName("Font")), PDFName("Subtype"): .name(PDFName("Type0")),
        PDFName("BaseFont"): .name(PDFName("ABCDEF+DejaVuSans")),
        PDFName("Encoding"): .name(PDFName("Identity-H")),
        PDFName("DescendantFonts"): .array([.reference(PDFObjectID(20))]),
        PDFName("ToUnicode"): .reference(PDFObjectID(21))])
      func operand(_ text: String) throws -> String {
        let codes = try text.unicodeScalars.map { try #require(inspector.unicodeToGlyph[Int($0.value)]) }
        return "<" + codes.map { String(format: "%04X", $0) }.joined() + ">"
      }
      if adjusted {
        instructions = "BT /F1 16 Tf 1 0 0 1 42 700 Tm [\(try operand("ABC ")) -12 \(try operand("ABC"))] TJ (Not used) Tj ET"
        instructions = instructions.replacingOccurrences(of: "(Not used) Tj", with: "\(try operand(" ABC")) Tj")
      } else {
        let lines = ["ABC ABC ABC ABC ABC ABC", "ABC ABC ABC ABC ABC ABC"]
        instructions = try lines.enumerated().map { index, line in
          "BT /F1 16 Tf 1 0 0 1 42 \(700 - index * 22) Tm \(try operand(line)) Tj ET"
        }.joined(separator: "\n")
      }
    } else {
      instructions = "BT /F1 16 Tf 1 0 0 1 42 700 Tm (ABC ABC ABC ABC ABC ABC) Tj 0 -22 Td (ABC ABC ABC ABC ABC ABC) Tj ET"
    }
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(instructions.utf8)))
    return (graph, pageID)
  }

  @MainActor private func targets(_ graph: PDFGraph, pageID: PDFObjectID) throws -> [PageTextTarget] {
    let reader = try #require(PDFDocument(data: PDFWriter.write(graph)))
    let page = try #require(reader.page(at: 0))
    let blocks = try PageTextEditing.blocks(pageID: pageID, in: graph)
    return NativeParagraphEditing.targets(from: blocks, pageID: pageID, graph: graph, page: page, pageIndex: 0)
  }

  private func removingUnicodeCmap(from program: Data) throws -> Data {
    var bytes = [UInt8](program)
    let inspector = try TrueTypeInspector.inspect(program)
    let count = try TrueTypeInspector.u16(bytes, at: 4)
    var removed = false
    for index in 0..<count {
      let offset = 12 + index * 16
      if String(decoding: bytes[offset..<offset + 4], as: UTF8.self) == "cmap" {
        bytes.replaceSubrange(offset..<offset + 4, with: Array("zzzz".utf8))
        removed = true
      }
    }
    guard removed, let head = inspector.tables["head"] else {
      throw PDFError(.malformed, "The test font has no cmap or head table")
    }
    bytes.replaceSubrange(head.offset + 8..<head.offset + 12, with: [0, 0, 0, 0])
    let adjustment = (0xB1B0_AFBA - TrueTypeSubsetter.checksum(bytes)) & 0xFFFF_FFFF
    bytes.replaceSubrange(head.offset + 8..<head.offset + 12, with: TrueTypeSubsetter.u32Bytes(adjustment))
    return Data(bytes)
  }

  private func cmaplessExplicitCIDMapFixture() throws -> (PDFGraph, PDFObjectID) {
    var (graph, pageID) = try fixture(composite: true)
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let inspector = try TrueTypeInspector.inspect(program)
    let scalars = [32, 65, 66, 67]
    let cidByScalar = try Dictionary(uniqueKeysWithValues: scalars.map { scalar in
      (scalar, try #require(inspector.unicodeToGlyph[scalar]) + 256)
    })
    let maximumCID = cidByScalar.values.max() ?? 0
    var cidToGID = [UInt8](repeating: 0, count: (maximumCID + 1) * 2)
    var widths: [PDFValue] = []
    var unicodeEntries: [String] = []
    for scalar in scalars {
      let cid = cidByScalar[scalar]!
      let glyphID = try #require(inspector.unicodeToGlyph[scalar])
      cidToGID[cid * 2] = UInt8((glyphID >> 8) & 0xFF)
      cidToGID[cid * 2 + 1] = UInt8(glyphID & 0xFF)
      let advance = try #require(inspector.advances[glyphID])
      widths += [.integer(Int64(cid)), .array([.real((Double(advance) * 1_000
        / Double(inspector.unitsPerEm)).rounded())])]
      unicodeEntries.append(String(format: "<%04X> <%04X>", cid, scalar))
    }

    guard case .dictionary(var descendant)? = graph.objects[PDFObjectID(20)] else {
      throw PDFError(.malformed, "The test CID font is missing")
    }
    descendant[PDFName("CIDToGIDMap")] = .reference(PDFObjectID(22))
    descendant[PDFName("W")] = .array(widths)
    graph.objects[PDFObjectID(20)] = .dictionary(descendant)
    graph.objects[PDFObjectID(22)] = .stream(PDFStream(bytes: Data(cidToGID)))
    graph.objects[PDFObjectID(21)] = .stream(PDFStream(bytes: Data("""
      /CIDInit /ProcSet findresource begin 12 dict begin begincmap
      1 begincodespacerange <0000> <FFFF> endcodespacerange
      \(unicodeEntries.count) beginbfchar
      \(unicodeEntries.joined(separator: "\n"))
      endbfchar endcmap end end
      """.utf8)))

    func operand(_ text: String) -> String {
      "<" + text.unicodeScalars.map {
        String(format: "%04X", cidByScalar[Int($0.value)]!)
      }.joined() + ">"
    }
    let content = [700, 688].map { baseline in
      "BT /F1 16 Tf 1 0 0 1 42 \(baseline) Tm \(operand("ABC")) Tj ET"
    }.joined(separator: "\n")
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(content.utf8)))
    graph.objects[PDFObjectID(7)] = .stream(PDFStream(bytes: try removingUnicodeCmap(from: program)))
    return (graph, pageID)
  }

  @Test @MainActor func embeddedSimpleAndIdentitySubsetParagraphsKeepTheOriginalFont() throws {
    for composite in [false, true] {
      let (graph, pageID) = try fixture(composite: composite)
      let grouped = try targets(graph, pageID: pageID)
      let target = try #require(grouped.first { $0.paragraph?.originalText.count == 2 })
      let paragraph = try #require(target.paragraph)
      #expect(paragraph.fragments.first?.format.sourceFont?.name == "DejaVuSans")
      #expect(target.text == "ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC")
      let initial = try #require(paragraph.fragments.first?.format)
      let retainedLines = paragraph.originalText.keys.sorted().enumerated().map { offset, index in
        let text = paragraph.originalText[index]!
        let x = target.rect[0]
        return PageTextLine(text: text, x: x,
          baseline: paragraph.firstBaseline - Double(offset) * paragraph.lineSpacing,
          segments: [.init(text: text, x: x, format: initial)])
      }
      let retained = try PDFEditingEngine.commit(PDFTransaction([
        RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
          lines: retainedLines, fontSize: initial.size, color: initial.color,
          box: .init(x: target.rect[0], firstBaseline: paragraph.firstBaseline,
            width: target.rect[2] - target.rect[0], lineSpacing: paragraph.lineSpacing,
            wraps: paragraph.wraps))
      ]), to: graph)
      let retainedBytes = try PDFWriter.write(retained)
      let reselected = try #require(targets(PDFParser.parse(retainedBytes).graph, pageID: pageID)
        .first { $0.paragraph?.originalText.count == 2 })
      #expect(abs(reselected.rect[0] - target.rect[0]) < 0.001)
      #expect(abs(reselected.rect[1] - target.rect[1]) < 0.001)
      #expect(abs(reselected.rect[2] - target.rect[2]) < 0.001)
      #expect(abs(reselected.rect[3] - target.rect[3]) < 0.001)

      let view = NSTextView()
      let formatting = NativeTextFormatting(view: view, fragments: paragraph.fragments,
        initial: initial, profiles: paragraph.fontProfiles)
      formatting.render(scale: 1, minimumLineSpacing: 22)
      #expect(!formatting.hasChanges)
      let usesEmbeddedFont = (view.font?.fontName ?? "").contains("DejaVuSans")
      #expect(usesEmbeddedFont)
      view.setSelectedRange(NSRange(location: 0, length: 3))
      #expect(formatting.apply(.color([0.2, 0.4, 0.7]), isTyping: true) == nil)
      #expect(formatting.fragments().first?.format.sourceFont == initial.sourceFont)
      let lines = [PageTextLine(text: "CBA ABC", x: 42, baseline: 700,
        segments: [.init(text: "CBA ABC", x: 42, format: initial)])]
      let command = RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
        lines: lines, fontSize: 16, color: [0, 0, 0], box: .init(x: 42, firstBaseline: 700,
          width: 240, lineSpacing: 22))
      let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      let bytes = try PDFWriter.write(edited)
      #expect(PDFDocument(data: bytes)?.string?.contains("CBA ABC") == true)
      #expect(edited.objects[PDFObjectID(4)] == graph.objects[PDFObjectID(4)])
      #expect(edited.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
      let reopened = try targets(PDFParser.parse(bytes).graph, pageID: pageID)
      #expect(reopened.first?.paragraph?.fragments.first?.format.sourceFont == initial.sourceFont)
      let missing = PageTextLine(text: "Z", x: 42, baseline: 700,
        segments: [.init(text: "Z", x: 42, format: initial)])
      #expect(throws: PDFError.self) {
        try RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
          lines: [missing], fontSize: 16, color: [0, 0, 0]).validate(in: graph)
      }
    }
  }

  @Test @MainActor func rawType1CParagraphPreviewsAndRewritesWithItsOriginalFont() throws {
    #expect(GlyphNames.name(for: "0") == "zero")
    #expect(GlyphNames.name(for: "-") == "hyphen")
    #expect(GlyphNames.name(for: "A") == "A")
    var (graph, pageID) = try fixture(composite: false)
    let openType = try #require(Data(base64Encoded: FontFixtureData.cffProgramBase64))
    let openTypeInfo = try TrueTypeInspector.inspect(openType)
    let cffTable = try #require(openTypeInfo.tables["CFF "])
    let bytes = [UInt8](openType)
    let rawCFF = Data(bytes[cffTable.offset..<cffTable.offset + cffTable.length])
    let cffFont = try #require(CGFont(CGDataProvider(data: rawCFF as CFData)!))

    guard case .dictionary(var simpleFont)? = graph.objects[PDFObjectID(4)],
      case .dictionary(var descriptor)? = graph.objects[PDFObjectID(6)]
    else { Issue.record("Simple CFF fixture font is missing"); return }
    guard case .array(var widths)? = simpleFont[PDFName("Widths")] else {
      Issue.record("Simple CFF fixture widths are missing"); return
    }
    for (code, name) in [(32, "space"), (65, "A"), (66, "B"), (67, "C")] {
      let glyph = cffFont.getGlyphWithGlyphName(name: name as CFString)
      var advance: Int32 = 0
      #expect(glyph > 0)
      #expect(cffFont.getGlyphAdvances(glyphs: [glyph], count: 1, advances: &advance))
      widths[code - 32] = .integer(Int64((Double(advance) * 1_000
        / Double(cffFont.unitsPerEm)).rounded()))
    }
    simpleFont[PDFName("Widths")] = .array(widths)
    simpleFont[PDFName("Subtype")] = .name(PDFName("Type1"))
    descriptor[PDFName("FontFile2")] = nil
    descriptor[PDFName("FontFile3")] = .reference(PDFObjectID(7))
    graph.objects[PDFObjectID(4)] = .dictionary(simpleFont)
    graph.objects[PDFObjectID(6)] = .dictionary(descriptor)
    graph.objects[PDFObjectID(7)] = .stream(PDFStream(
      dictionary: [PDFName("Subtype"): .name(PDFName("Type1C"))], bytes: rawCFF))

    let profile = try #require(PageTextEditing.fontProfiles(pageID: pageID, in: graph)[PDFName("F1")])
    let aGlyph = cffFont.getGlyphWithGlyphName(name: "A" as CFString)
    var aAdvance: Int32 = 0
    #expect(cffFont.getGlyphAdvances(glyphs: [aGlyph], count: 1, advances: &aAdvance))
    #expect(profile.glyphs["A"]?.width == Double(aAdvance) * 1_000 / Double(cffFont.unitsPerEm))
    #expect(profile.previewProgram == nil)
    let previewFont = try #require(NativeParagraphEditing.fonts(profiles: [PDFName("F1"): profile])[PDFName("F1")])
    let nativeFont = previewFont as CTFont
    var characters: [UniChar] = [65, 66, 67]
    var nativeGlyphs = Array(repeating: CGGlyph(0), count: characters.count)
    #expect(CTFontGetGlyphsForCharacters(nativeFont, &characters, &nativeGlyphs, characters.count))
    #expect(nativeGlyphs == [
      CGGlyph(try #require(profile.glyphs["A"]?.id)),
      CGGlyph(try #require(profile.glyphs["B"]?.id)),
      CGGlyph(try #require(profile.glyphs["C"]?.id)),
    ])

    let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph?.originalText.count == 2 })
    let paragraph = try #require(target.paragraph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
        lines: [.init(text: "CBA ABC", x: target.rect[0], baseline: paragraph.firstBaseline,
          segments: [.init(text: "CBA ABC", x: target.rect[0], format: paragraph.fragments[0].format)])],
        fontSize: paragraph.fragments[0].format.size,
        color: paragraph.fragments[0].format.color,
        box: .init(x: target.rect[0], firstBaseline: paragraph.firstBaseline,
          width: target.rect[2] - target.rect[0], lineSpacing: paragraph.lineSpacing))
    ]), to: graph)
    #expect(edited.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
    let saved = try PDFWriter.write(edited)
    #expect(PDFDocument(data: saved)?.string?.contains("CBA ABC") == true)
    let reopened = try targets(PDFParser.parse(saved).graph, pageID: pageID)
    #expect(reopened.first { $0.paragraph != nil }?.text == "CBA ABC")
  }

  @Test @MainActor func macRomanSubsetParagraphReopensWithoutSubstitution() throws {
    let (original, pageID) = try fixture(composite: false)
    var graph = original
    guard case .dictionary(var font)? = graph.objects[PDFObjectID(4)] else {
      Issue.record("fixture font missing"); return
    }
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let inspector = try TrueTypeInspector.inspect(program)
    font[PDFName("Encoding")] = .name(PDFName("MacRomanEncoding"))
    font.removeValue(forKey: PDFName("ToUnicode"))
    font[PDFName("FirstChar")] = .integer(32)
    font[PDFName("LastChar")] = .integer(255)
    font[PDFName("Widths")] = .array((32...255).map { code in
      let scalar = PDFMacRoman.characters[UInt8(code)]?.unicodeScalars.first
      let glyph = scalar.flatMap { inspector.unicodeToGlyph[Int($0.value)] }
      let advance = glyph.flatMap { inspector.advances[$0] } ?? 0
      return .real((Double(advance) * 1_000 / Double(inspector.unitsPerEm)).rounded())
    })
    graph.objects[PDFObjectID(4)] = .dictionary(font)
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /F1 16 Tf 1 0 0 1 42 700 Tm <414243208920DE20414243208920DE> Tj
      0 -22 Td <414243208920DE20414243208920DE> Tj ET
      """.utf8)))
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: graph)
    let profile = try #require(profiles[PDFName("F1")])
    #expect(profile.glyphs["â"]?.codes == [137])
    #expect(profile.glyphs["ﬁ"]?.codes == [222])
    #expect(profile.glyphs["Z"] == nil)
    let readerText = try #require(PDFDocument(data: PDFWriter.write(graph))?.string)
    #expect(readerText.contains("ABC â fi"))
    #expect(!readerText.contains("ﬁ"))
    let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph != nil })
    let paragraph = try #require(target.paragraph)
    #expect(target.text.contains("ABC â ﬁ"))
    let format = try #require(paragraph.fragments.first?.format)
    #expect(format.sourceFont?.name == "DejaVuSans")
    let view = NSTextView()
    let formatting = NativeTextFormatting(view: view, fragments: paragraph.fragments,
      initial: format, profiles: profiles)
    formatting.render(scale: 1, minimumLineSpacing: 22)
    #expect(!formatting.hasChanges)
    #expect(view.string == target.text)
    let text = "CBA â ﬁ ABC"
    let lines = [PageTextLine(text: text, x: 42, baseline: 700,
      segments: [.init(text: text, x: 42, format: format)])]
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
        lines: lines, fontSize: 16, color: [0, 0, 0],
        box: .init(x: 42, firstBaseline: 700, width: 240, lineSpacing: 22))
    ]), to: graph)
    let bytes = try PDFWriter.write(edited)
    // PDFKit expands the fi presentation ligature during text extraction.
    // The owned decoder/reselected paragraph must retain its actual scalar.
    #expect(PDFDocument(data: bytes)?.string?.contains("CBA â fi ABC") == true)
    #expect(edited.objects[PDFObjectID(4)] == graph.objects[PDFObjectID(4)])
    #expect(edited.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
    let reopened = try targets(PDFParser.parse(bytes).graph, pageID: pageID)
    let reselected = try #require(reopened.first { $0.text == text && $0.paragraph != nil })
    #expect(reselected.paragraph?.fragments.first?.format.sourceFont == format.sourceFont)
  }

  @Test @MainActor func adjustedIdentityArrayKeepsItsFollowingPenAndRefusesPartialErasure() throws {
    let (graph, pageID) = try fixture(composite: true, adjusted: true)
    let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph != nil })
    let paragraph = try #require(target.paragraph)
    #expect(paragraph.fragments.contains { $0.format.characterSpacing > 0.1 })
    let source = try #require(PDFDocument(data: PDFWriter.write(graph)))
    let before = try #require(source.findString("ABC", withOptions: []).last)
    let line = PageTextLine(text: "CAB", x: 42, baseline: 650,
      segments: [.init(text: "CAB", x: 42, format: paragraph.fragments[0].format)])
    let selected = paragraph.originalText.filter { $0.key < 2 }
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: pageID, originalText: selected, lines: [line], fontSize: 16, color: [0, 0, 0])
    ]), to: graph)
    let after = try #require(PDFDocument(data: PDFWriter.write(edited)))
    let neighbor = try #require(after.findString("ABC", withOptions: []).last)
    #expect(abs(before.bounds(for: source.page(at: 0)!).minX - neighbor.bounds(for: after.page(at: 0)!).minX) < 0.01)
    #expect(throws: PDFError.self) {
      try RewritePageTextCommand(pageID: pageID, originalText: [0: selected[0]!],
        lines: [], fontSize: 16, color: [0, 0, 0]).validate(in: graph)
    }
  }

  @Test @MainActor func indirectFontMetricsAndDescendantsKeepGlyphCoverageAndEditingGeometry() throws {
    for composite in [false, true] {
      let (direct, pageID) = try fixture(composite: composite)
      let expected = try PageTextEditing.fontProfiles(pageID: pageID, in: direct)
      var graph = direct
      guard case .dictionary(var font)? = graph.objects[PDFObjectID(4)] else {
        Issue.record("Missing fixture font"); return
      }
      if composite {
        guard case .dictionary(var descendant)? = graph.objects[PDFObjectID(20)] else {
          Issue.record("Missing fixture descendant"); return
        }
        graph.objects[PDFObjectID(40)] = descendant[PDFName("W")]
        descendant[PDFName("W")] = .reference(PDFObjectID(40))
        graph.objects[PDFObjectID(20)] = .dictionary(descendant)
        graph.objects[PDFObjectID(41)] = font[PDFName("DescendantFonts")]
        font[PDFName("DescendantFonts")] = .reference(PDFObjectID(41))
      } else {
        graph.objects[PDFObjectID(40)] = font[PDFName("Widths")]
        font[PDFName("Widths")] = .reference(PDFObjectID(40))
        graph.objects[PDFObjectID(41)] = .dictionary([
          PDFName("BaseEncoding"): .name(PDFName("WinAnsiEncoding"))])
        font[PDFName("Encoding")] = .reference(PDFObjectID(41))
      }
      graph.objects[PDFObjectID(4)] = .dictionary(font)
      #expect(try PageTextEditing.fontProfiles(pageID: pageID, in: graph) == expected)
      #expect(try PageTextEditing.blocks(pageID: pageID, in: graph)
        == PageTextEditing.blocks(pageID: pageID, in: direct))
      let paragraph = try #require(targets(graph, pageID: pageID).first?.paragraph)
      #expect(paragraph.originalText.count == 2)
      let format = paragraph.fragments[0].format
      let edited = try PDFEditingEngine.commit(PDFTransaction([
        RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
          lines: [.init(text: "CBA ABC", x: 42, baseline: 700,
            segments: [.init(text: "CBA ABC", x: 42, format: format)])], fontSize: 16,
          color: [0, 0, 0], box: .init(x: 42, firstBaseline: 700, width: 240, lineSpacing: 22))
      ]), to: graph)
      let bytes = try PDFWriter.write(edited)
      #expect(PDFDocument(data: bytes)?.string?.contains("CBA ABC") == true)
      #expect(edited.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
      #expect(try targets(PDFParser.parse(bytes).graph, pageID: pageID).first?.paragraph != nil)
      // A broken metric reference must not turn into guessed advances.
      graph.objects[PDFObjectID(40)] = .reference(PDFObjectID(40))
      #expect(try PageTextEditing.fontProfiles(pageID: pageID, in: graph).values.allSatisfy { $0.glyphs.isEmpty })
    }
  }

  @Test @MainActor func importedProseGroupsMixedStylesWithoutAdoptingTheHeadingOrNeighbor() throws {
    let parsed = try PDFParser.parse(PDFFixtures.importedParagraphPages())
    let blocks = try targets(parsed.graph, pageID: parsed.pageIDs[0])
    let target = try #require(blocks.first { $0.text.hasPrefix("This imported paragraph") })
    let paragraph = try #require(target.paragraph)
    #expect(target.text.contains("The saved PDF"))
    #expect(!target.text.contains("Editing imported documents"))
    #expect(!target.text.contains("unchanged neighbor"))
    #expect(paragraph.originalText.count > 3)
    #expect(paragraph.fragments.contains { $0.format.color == [0.1, 0.3, 0.7] })
    let preview = try PageTextEditing.hidingParagraph(pageID: parsed.pageIDs[0],
      originalText: paragraph.originalText, standardFontAdvances: paragraph.standardFontAdvances,
      in: parsed.graph)
    #expect(try PDFWriter.write(parsed.graph) == PDFFixtures.importedParagraphPages())
    #expect(try PDFWriter.write(preview) != PDFWriter.write(parsed.graph))
    let text = NSTextView(); text.allowsUndo = true
    let formatting = NativeTextFormatting(view: text, fragments: paragraph.fragments,
      initial: paragraph.fragments[0].format, profiles: paragraph.fontProfiles)
    formatting.render(scale: 1, minimumLineSpacing: paragraph.lineSpacing)
    #expect(!formatting.hasChanges)
    text.setSelectedRange(NSRange(location: 0, length: 4))
    #expect(formatting.apply(.family(.times), isTyping: true) == nil)
    #expect(formatting.fragments().first?.format.sourceFont == nil)
    #expect(formatting.fragments().dropFirst().contains { $0.format.sourceFont != nil })
    #expect(formatting.apply(.bold(true), isTyping: true) == nil)
  }

  @Test @MainActor func tightLeadingAndInterleavedColumnsKeepSeparateParagraphs() throws {
    let parsed = try PDFParser.parse(PDFFixtures.importedParagraphPages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data()))
    // Discover the existing source profile before removing the fixture text.
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: parsed.graph)
    let source = try #require(profiles[PDFName("Body")])
    let fonts = NativeParagraphEditing.fonts(profiles: profiles)
    let base = try #require(fonts[source.source.resource])
    let font = CTFontCreateCopyWithAttributes(base, 10, nil, nil) as NSFont
    let format = PageTextFormat(size: 10, sourceFont: source.source)
    let first = "This first paragraph contains enough words to wrap over several lines while keeping its own column and original font."
    let second = "Another paragraph starts immediately below the short final line."
    let right = "The separate right column must keep its own text and never become part of the paragraph on the left."
    let width = 190.0, spacing = 10.98
    let firstLines = NativeParagraphEditing.wrappedLines(first, font: font, width: width)
    let secondLines = NativeParagraphEditing.wrappedLines(second, font: font, width: width)
    let rightLines = NativeParagraphEditing.wrappedLines(right, font: font, width: width)
    #expect(firstLines.count >= 3)
    func lines(_ text: [String], x: Double, start: Int = 0) -> [PageTextLine] {
      text.enumerated().map { index, value in
        .init(text: value, x: x, baseline: 650 - Double(start + index) * spacing,
          segments: [.init(text: value, x: x, format: format)])
      }
    }
    for (values, x, start) in [(firstLines, 42.0, 0), (secondLines, 42.0, firstLines.count), (rightLines, 320.0, 0)] {
      graph = try PDFEditingEngine.commit(PDFTransaction([
        AddPageTextLinesCommand(pageID: pageID, lines: lines(values, x: x, start: start),
          box: .init(x: x, firstBaseline: 650 - Double(start) * spacing, width: width, lineSpacing: spacing))
      ]), to: graph)
    }
    for (id, value) in graph.objects {
      if case .stream(let stream) = value {
        var dictionary = stream.dictionary
        for key in ["SPDFAdded", "SPDFTextVersion", "SPDFTextBox", "SPDFTextLines"] { dictionary[PDFName(key)] = nil }
        graph.objects[id] = .stream(PDFStream(dictionary: dictionary, bytes: stream.bytes))
      }
    }
    let found = try targets(graph, pageID: pageID)
    let selected = try #require(found.first { $0.text == first })
    let paragraph = try #require(selected.paragraph)
    #expect(paragraph.wraps)
    #expect(abs(paragraph.lineSpacing - spacing) < 0.001)
    #expect(found.contains { $0.text == second && $0.paragraph?.wraps == true })
    #expect(found.contains { $0.text == right && $0.paragraph?.wraps == true })
    let view = NSTextView(frame: .init(x: 0, y: 0, width: selected.rect[2] - selected.rect[0], height: 1_000))
    let formatting = NativeTextFormatting(view: view, fragments: paragraph.fragments,
      initial: format, profiles: paragraph.fontProfiles)
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = false
    view.textContainer?.containerSize = .init(width: selected.rect[2] - selected.rect[0], height: 10_000)
    formatting.render(scale: 1, minimumLineSpacing: paragraph.lineSpacing)
    let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
    manager.ensureLayout(for: container)
    var baselines: [Double] = []
    manager.enumerateLineFragments(forGlyphRange: .init(location: 0, length: manager.numberOfGlyphs)) {
      rect, _, _, glyphs, _ in baselines.append(rect.minY + manager.location(forGlyphAt: glyphs.location).y)
    }
    #expect(baselines.count == firstLines.count)
    for pair in zip(baselines, baselines.dropFirst()) { #expect(abs(pair.1 - pair.0 - spacing) < 0.001) }
    #expect(!formatting.hasChanges)
  }

  @Test @MainActor func opaqueDefaultGraphicsStatesAreEditableButTransparencyAndUnknownStatesRefuse() throws {
    let (base, pageID) = try fixture(composite: true)
    let states: [([PDFName: PDFValue], Bool)] = [
      ([PDFName("BM"): .name(PDFName("Normal")), PDFName("ca"): .real(1)], true),
      ([PDFName("Type"): .name(PDFName("ExtGState")), PDFName("SA"): .boolean(false),
        PDFName("SM"): .real(0.02), PDFName("OP"): .boolean(false),
        PDFName("op"): .boolean(false), PDFName("OPM"): .integer(1)], true),
      ([PDFName("SA"): .boolean(true), PDFName("SM"): .integer(1)], true),
      ([PDFName("ca"): .real(0.5)], true),
      ([PDFName("OP"): .boolean(true)], true), ([PDFName("op"): .boolean(true)], true),
      ([PDFName("OPM"): .integer(2)], false), ([PDFName("SA"): .integer(0)], false),
      ([PDFName("SM"): .real(-0.1)], false), ([PDFName("SM"): .real(1.1)], false),
      ([PDFName("Font"): .array([.reference(PDFObjectID(4)), .integer(16)])], false)
    ]
    for (state, expected) in states {
      var graph = base
      guard case .dictionary(var page)? = graph.objects[pageID],
        case .dictionary(var resources)? = page[PDFName("Resources")],
        case .stream(let content)? = graph.objects[PDFObjectID(5)] else {
        Issue.record("Missing fixture resources"); return
      }
      resources[PDFName("ExtGState")] = .dictionary([PDFName("GS"): .reference(PDFObjectID(40))])
      page[PDFName("Resources")] = .dictionary(resources)
      graph.objects[pageID] = .dictionary(page)
      graph.objects[PDFObjectID(40)] = .dictionary(state)
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("/GS gs\n".utf8) + content.bytes))
      let hasParagraph = try targets(graph, pageID: pageID).contains { $0.paragraph != nil }
      #expect(hasParagraph == expected, "\(state)")
    }
  }

  @Test @MainActor func sourceWidthCorrectionsAffectPreviewWithoutChangingCanonicalSpacing() throws {
    var (graph, pageID) = try fixture(composite: true)
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let info = try TrueTypeInspector.inspect(program)
    guard case .dictionary(var descendant)? = graph.objects[PDFObjectID(20)] else {
      Issue.record("Missing descendant"); return
    }
    descendant[PDFName("W")] = .array(try [32, 65, 66, 67].flatMap { value -> [PDFValue] in
      let gid = try #require(info.unicodeToGlyph[value]), advance = try #require(info.advances[gid])
      return [.integer(Int64(gid)), .array([.real(Double(advance) * 1000 / Double(info.unitsPerEm) + 1)])]
    })
    graph.objects[PDFObjectID(20)] = .dictionary(descendant)
    let paragraph = try #require(targets(graph, pageID: pageID).first?.paragraph)
    let initial = paragraph.fragments[0].format
    let view = NSTextView(frame: .init(x: 0, y: 0, width: 600, height: 400))
    view.textContainer?.lineFragmentPadding = 0
    let formatting = NativeTextFormatting(view: view, fragments: paragraph.fragments,
      initial: initial, profiles: paragraph.fontProfiles)
    formatting.render(scale: 1, minimumLineSpacing: paragraph.lineSpacing)
    let manager = try #require(view.layoutManager), container = try #require(view.textContainer)
    manager.ensureLayout(for: container)
    let profile = try #require(paragraph.fontProfiles[PDFName("F1")])
    var x = 0.0
    for index in 0..<12 {
      let glyph = manager.glyphIndexForCharacter(at: index)
      #expect(abs(manager.location(forGlyphAt: glyph).x - x) < 0.001)
      let value = (view.string as NSString).substring(with: .init(location: index, length: 1))
      x += try #require(profile.glyphs[value]).width * initial.size / 1_000
    }
    #expect(!formatting.hasChanges)
    #expect(formatting.fragments().allSatisfy { $0.format.characterSpacing == 0 })
  }

  @Test @MainActor func scaledTextMatricesApplyLineTranslationsInTextSpace() throws {
    var (graph, pageID) = try fixture(composite: true)
    guard case .dictionary(let page)? = graph.objects[pageID] else { Issue.record("Missing page"); return }
    let font = try #require(IndexedTextFont.resolve(resource: PDFName("F1"), page: page, in: graph))
    let codes = try #require(font.encode("ABC ABC ABC ABC ABC ABC"))
    let operand = "<" + codes.map { String(format: "%02X", $0) }.joined() + ">"
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /F1 1.6 Tf 10 0 0 10 42 700 Tm
      \(operand) Tj 0 -2.2 TD \(operand) Tj ET
      """.utf8)))
    let source = try PageTextEditing.sourceRuns(pageID: pageID, in: graph)
    #expect(source.count == 2)
    #expect(abs(source[0].baseline - 700) < 0.001)
    #expect(abs(source[1].baseline - 678) < 0.001)
    #expect(source.allSatisfy { abs($0.x - 42) < 0.001 && $0.format.size == 16 })
    #expect(try targets(graph, pageID: pageID).contains { $0.paragraph?.originalText.count == 2 })
  }

  @Test @MainActor func paintedRulesSeparateRowsButUnpaintedPathsDoNot() throws {
    let (base, pageID) = try fixture(composite: true)
    for painted in [true, false] {
      var graph = base
      guard case .stream(let content)? = graph.objects[PDFObjectID(5)] else { Issue.record("Missing content"); return }
      let rule = "\nq 1 0 0 1 10 20 cm 20 669 m 300 669 l \(painted ? "S" : "n") Q\n"
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: content.bytes + Data(rule.utf8)))
      #expect(try PageTextEditing.paragraphSeparators(pageID: pageID, in: graph).count == (painted ? 1 : 0))
      #expect(try targets(graph, pageID: pageID).contains { $0.paragraph?.wraps == true } == !painted)
    }
  }

  @Test @MainActor func standaloneSpaceOperandsKeepWordBoundariesWithoutSeparateHitTargets() throws {
    var (graph, pageID) = try fixture(composite: true)
    guard case .dictionary(let page)? = graph.objects[pageID] else { Issue.record("Missing page"); return }
    let font = try #require(IndexedTextFont.resolve(resource: PDFName("F1"), page: page, in: graph))
    func show(_ value: String) throws -> String {
      let codes = try #require(font.encode(value))
      return "<" + codes.map { String(format: "%02X", $0) }.joined() + "> Tj"
    }
    let line = try (0..<6).map { _ in try show("ABC") + " " + show(" ") }.joined(separator: " ")
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /F1 16 Tf 1 0 0 1 42 700 Tm \(line) 0 -22 Td \(line) ET
      """.utf8)))
    let found = try targets(graph, pageID: pageID)
    let target = try #require(found.first { $0.paragraph?.wraps == true })
    #expect(target.text == Array(repeating: "ABC", count: 12).joined(separator: " "))
    #expect(target.paragraph?.originalText.count == 24)
    #expect(found.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
  }

  @Test @MainActor func sourceGlyphMismatchAndUnknownEncodingDoNotBecomeEditableParagraphs() throws {
    let (graph, pageID) = try fixture(composite: true)
    for missingEncoding in [false, true] {
      var modified = graph
      if missingEncoding {
        guard case .dictionary(var font)? = modified.objects[PDFObjectID(4)] else { return }
        font[PDFName("Encoding")] = nil
        modified.objects[PDFObjectID(4)] = .dictionary(font)
      } else {
        guard case .dictionary(var descendant)? = modified.objects[PDFObjectID(20)] else { return }
        descendant[PDFName("CIDToGIDMap")] = .reference(PDFObjectID(22))
        modified.objects[PDFObjectID(22)] = .stream(PDFStream(bytes: Data(repeating: 0, count: 512)))
        modified.objects[PDFObjectID(20)] = .dictionary(descendant)
      }
      #expect(try targets(modified, pageID: pageID).allSatisfy { $0.paragraph == nil })
    }
  }

  @Test @MainActor func foreignStandardFontRunsBecomeOneMixedParagraph() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    let regular = PageTextFormat(size: 16)
    let emphasized = PageTextFormat(font: .timesBoldItalic, size: 16, color: [0.1, 0.3, 0.8])
    let first = "This paragraph has "
    let word = "different fonts"
    let x = 42 + NativeParagraphEditing.standardAdvance(first, family: "Helvetica", size: 16)!
    let lines = [PageTextLine(text: first + word, x: 42, baseline: 700,
      segments: [.init(text: first, x: 42, format: regular), .init(text: word, x: x, format: emphasized)]),
      PageTextLine(text: "and follows naturally here.", x: 42, baseline: 678,
        segments: [.init(text: "and follows naturally here.", x: 42, format: regular)])]
    graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(pageID: pageID, lines: lines,
        box: .init(x: 42, firstBaseline: 700, width: 240, lineSpacing: 22))
    ]), to: graph)
    // Remove authoring hints: this must exercise foreign reconstruction.
    for (id, value) in graph.objects {
      if case .stream(let stream) = value {
        var dictionary = stream.dictionary
        for key in ["SPDFAdded", "SPDFTextVersion", "SPDFTextBox", "SPDFTextLines"] { dictionary[PDFName(key)] = nil }
        graph.objects[id] = .stream(PDFStream(dictionary: dictionary, bytes: stream.bytes))
      }
    }
    let paragraph = try #require(targets(graph, pageID: pageID)
      .first { $0.text.hasPrefix("This paragraph") }?.paragraph)
    #expect(paragraph.originalText.count == 3)
    #expect(paragraph.fragments.filter { $0.format.font == .timesBoldItalic }.map(\.text).joined().trimmingCharacters(in: .whitespaces) == "different fonts")
  }

  @Test @MainActor func scaledAndFlippedSourceCoordinatesEditAtTheSamePagePosition() throws {
    let parsed = try PDFParser.parse(PDFFixtures.importedParagraphPages())
    guard case .stream(let stream)? = parsed.graph.objects[PDFObjectID(5)] else { return }
    let original = String(decoding: stream.bytes, as: UTF8.self)
    let expression = try NSRegularExpression(pattern: "1 0 0 1 ([0-9.]+) ([0-9.]+) Tm")
    for flipped in [false, true] {
      var content = original.replacingOccurrences(of: "/Body 16 Tf", with: "/Body 32 Tf")
        .replacingOccurrences(of: "/Heading 24 Tf", with: "/Heading 48 Tf")
      for match in expression.matches(in: content, range: NSRange(content.startIndex..., in: content)).reversed() {
        let x = Double((content as NSString).substring(with: match.range(at: 1)))!
        let y = Double((content as NSString).substring(with: match.range(at: 2)))!
        let matrix = "1 0 0 \(flipped ? -1 : 1) \((x - 10) * 2) \(flipped ? (792 - y) * 2 : (y - 20) * 2) Tm"
        content = (content as NSString).replacingCharacters(in: match.range, with: matrix)
      }
      content = "q 0.5 0 0 \(flipped ? -0.5 : 0.5) 10 \(flipped ? 792 : 20) cm\n" + content + "\nQ"
      var graph = parsed.graph
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(content.utf8)))
      let target = try #require(targets(graph, pageID: parsed.pageIDs[0]).first { $0.text.hasPrefix("This imported") })
      let paragraph = try #require(target.paragraph)
      let format = paragraph.fragments[0].format
      #expect(format.size == 16)
      #expect(abs(paragraph.firstBaseline - 700) < 0.001)
      let source = try #require(PDFDocument(data: PDFWriter.write(graph)))
      let before = try #require(source.findString("unchanged neighbor", withOptions: []).first)
      let edited = try PDFEditingEngine.commit(PDFTransaction([
        RewritePageTextCommand(pageID: parsed.pageIDs[0], originalText: paragraph.originalText,
          lines: [.init(text: "Edited imported text", x: 66, baseline: 620,
            segments: [.init(text: "Edited imported text", x: 66, format: format)])],
          fontSize: 16, color: [0, 0, 0])
      ]), to: graph)
      let after = try #require(PDFDocument(data: PDFWriter.write(edited)))
      let replacement = try #require(after.findString("Edited imported text", withOptions: []).first)
      #expect(abs(replacement.bounds(for: after.page(at: 0)!).minX - 66) < 0.01)
      let following = try #require(after.findString("unchanged neighbor", withOptions: []).first)
      #expect(following.bounds(for: after.page(at: 0)!) == before.bounds(for: source.page(at: 0)!))
    }
  }

  @Test @MainActor func cidSubsetWithoutUnicodeCmapUsesItsOriginalGlyphsForTheNativePreview() throws {
    var (graph, pageID) = try fixture(composite: true)
    guard case .stream(let stream)? = graph.objects[PDFObjectID(7)] else { return }
    let program = try removingUnicodeCmap(from: stream.bytes)
    let inspector = try TrueTypeInspector.inspect(stream.bytes)
    graph.objects[PDFObjectID(7)] = .stream(PDFStream(bytes: program))
    #expect(throws: PDFError.self) { try TrueTypeInspector.inspect(program) }
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: graph)
    let profile = try #require(profiles[PDFName("F1")])
    let preview = try #require(profile.previewProgram)
    let previewInfo = try TrueTypeInspector.inspect(preview)
    let originalInfo = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    #expect(previewInfo.unicodeToGlyph[65] == inspector.unicodeToGlyph[65])
    let programBytes = [UInt8](program)
    for tag in ["glyf", "loca", "hmtx", "maxp"] {
      let before = try #require(originalInfo.tables[tag]); let after = try #require(previewInfo.tables[tag])
      #expect(Array(programBytes[before.offset..<before.offset + before.length])
        == Array(preview[after.offset..<after.offset + after.length]))
    }
    let paragraph = try #require(targets(graph, pageID: pageID).first?.paragraph)
    let text = NSTextView()
    let formatting = NativeTextFormatting(view: text, fragments: paragraph.fragments,
      initial: paragraph.fragments[0].format, profiles: paragraph.fontProfiles)
    formatting.render(scale: 1, minimumLineSpacing: paragraph.lineSpacing)
    #expect(!formatting.hasChanges)
    #expect(formatting.insertionIssue("ABC") == nil)
    #expect(formatting.insertionIssue("D") != nil)
    #expect(graph.objects[PDFObjectID(7)] == .stream(PDFStream(bytes: program)))
  }

  @Test @MainActor func cmaplessExplicitCIDOutlinesAllowSafeSpacingAndRefuseRealInkOverlap() throws {
    let (graph, pageID) = try cmaplessExplicitCIDMapFixture()
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    #expect(Set(layout.clusters.map(\.runIndex)) == Set([0, 1]))
    #expect(layout.clusters.filter { $0.runIndex == 0 }.map(\.text).joined() == "ABC")
    #expect(layout.clusters.filter { $0.runIndex == 1 }.map(\.text).joined() == "ABC")

    let format = PageTextFormat(font: .helvetica, size: 16,
      sourceFont: .init(resource: PDFName("F1"), name: "DejaVuSans"))
    let safelySpaced = RewritePageTextCommand(pageID: pageID, originalText: [0: "ABC"],
      lines: [.init(text: "ABC", x: 42, baseline: 700,
        segments: [.init(text: "ABC", x: 42, format: format)])],
      fontSize: 16, color: [0, 0, 0])
    try safelySpaced.validate(in: graph)

    let overlapping = RewritePageTextCommand(pageID: pageID, originalText: [0: "ABC"],
      lines: [.init(text: "ABC", x: 42, baseline: 696,
        segments: [.init(text: "ABC", x: 42, format: format)])],
      fontSize: 16, color: [0, 0, 0])
    do {
      try overlapping.validate(in: graph)
      Issue.record("An edit overlapping source glyph ink was accepted")
    } catch let error as PDFError {
      #expect(error.message.contains("overlap another text block"))
    }
  }
  @Test @MainActor func rectangularClipsSurviveNativeDiscoveryRewriteAndReopen() throws {
    for composite in [false, true] {
      var (graph, pageID) = try fixture(composite: composite)
      guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else { return }
      // Two nested clips, one under a transformed CTM, have one intersection.
      let prefix = "q 20 660 360 80 re W n q 2 0 0 2 0 0 cm 20 336 140 21 re W* n 0.5 0 0 0.5 0 0 cm\n"
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(prefix.utf8) + stream.bytes + Data("\nQ Q\n0 0 500 790 re".utf8)))
      let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph != nil })
      let paragraph = try #require(target.paragraph)
      #expect(paragraph.originalText.count == 2)
      #expect(paragraph.clippingRect == [40, 672, 320, 714])
      let initial = paragraph.fragments[0].format
      let lines = [PageTextLine(text: "CBA ABC", x: 42, baseline: 700,
        segments: [.init(text: "CBA ABC", x: 42, format: initial)])]
      #expect(NativeParagraphEditing.clippingIssue(lines: lines, clippingRect: paragraph.clippingRect,
        profiles: paragraph.fontProfiles) == nil)
      let rewritten = try PDFEditingEngine.commit(PDFTransaction([
        RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
          lines: lines, fontSize: 16, color: [0, 0, 0], box: .init(x: 42, firstBaseline: 700,
            width: 240, lineSpacing: 22))
      ]), to: graph)
      let reopened = try targets(PDFParser.parse(PDFWriter.write(rewritten)).graph, pageID: pageID)
      let again = try #require(reopened.first { $0.text == "CBA ABC" }?.paragraph)
      #expect(again.clippingRect == paragraph.clippingRect)
      #expect(rewritten.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
      let content = try PageContent.load(pageID: pageID, in: rewritten)
      #expect(String(decoding: content.bytes, as: UTF8.self).contains("40 672 280 42 re W n"))
    }
  }

  @Test @MainActor func clippedSourceInkAndDifferentCellRegionsDoNotBecomeAParagraph() throws {
    let (base, pageID) = try fixture(composite: false)
    guard case .stream(let stream)? = base.objects[PDFObjectID(5)] else { return }
    // The visible source is partial. Never put its hidden full string into
    // an unclipped native text editor.
    var partial = base
    partial.objects[PDFObjectID(5)] = .stream(PDFStream(bytes:
      Data("q 50 675 15 35 re W n\n".utf8) + stream.bytes + Data("\nQ".utf8)))
    #expect(try targets(partial, pageID: pageID).isEmpty)
    var cells = base
    cells.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      q 40 690 280 24 re W n BT /F1 16 Tf 1 0 0 1 42 700 Tm (ABC ABC ABC ABC ABC ABC) Tj ET Q
      q 40 668 280 24 re W n BT /F1 16 Tf 1 0 0 1 42 678 Tm (ABC ABC ABC ABC ABC ABC) Tj ET Q
      """.utf8)))
    let validator = try PageTextRewriteValidator(pageID: pageID, in: cells)
    #expect(throws: PDFError.self) { try validator.clippingRect(for: [0,1]) }
    #expect(try targets(cells, pageID: pageID).allSatisfy { $0.paragraph?.wraps != true })
  }

  @Test @MainActor func unsupportedPathsAndTextClippingStayRefusedAfterTextModeReset() throws {
    let (base, pageID) = try fixture(composite: true)
    guard case .stream(let stream)? = base.objects[PDFObjectID(5)] else { return }
    let prefixes = [
      "q 40 660 m 320 660 l 180 740 l h W n",
      "q 20 660 360 80 re 30 670 20 20 re W* n", // even-odd hole
      "q 1 0.2 0 1 0 0 cm 20 660 360 80 re W n", // skewed clip
      "q BT /F1 16 Tf 4 Tr 1 0 0 1 42 700 Tm <0024> Tj ET 0 Tr",
      "q BT q /F1 16 Tf 4 Tr 1 0 0 1 42 700 Tm <0024> Tj Q ET 0 Tr",
      "q 20 660 360 80 re W n 0 0 m 1 1 l W n" // complex intersection
    ]
    for prefix in prefixes {
      var graph = base
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data((prefix + "\n").utf8)
        + stream.bytes + Data("\nQ".utf8)))
      let validator = try PageTextRewriteValidator(pageID: pageID, in: graph)
      let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
      let last = runs.count - 1
      #expect(throws: PDFError.self) { try validator.clippingRect(for: [last]) }
    }
    // q/Q restores clipping state, but does not restore the current path.
    var graph = base
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes:
      Data("q 40 660 280 80 re Q W n\n".utf8) + stream.bytes))
    let validator = try PageTextRewriteValidator(pageID: pageID, in: graph)
    #expect(try validator.clippingRect(for: [0,1]) == [40,660,320,740])
  }

  @Test @MainActor func clippedTextOverflowUsesGlyphInkAndCanBeRepairedWithoutMutation() throws {
    let (graph, pageID) = try fixture(composite: true)
    let paragraph = try #require(targets(graph, pageID: pageID).first?.paragraph)
    let format = paragraph.fragments[0].format
    let clip = [40.0,690,90,714]
    func issue(_ value: String, x: Double = 42, y: Double = 700, format: PageTextFormat? = nil) -> String? {
      NativeParagraphEditing.clippingIssue(lines: [.init(text: value, x: x, baseline: y,
        segments: [.init(text: value, x: x, format: format ?? paragraph.fragments[0].format)])],
        clippingRect: clip, profiles: paragraph.fontProfiles)
    }
    #expect(issue("ABC") == nil)
    #expect(issue("ABC ABC ABC") != nil)
    #expect(issue("ABC", x: 20) != nil)
    #expect(issue("ABC", y: 684) != nil)
    #expect(issue("j", x: 40, format: .init(font: .timesItalic, size: 16)) != nil)
    var large = format; large.size = 36
    #expect(issue("ABC", format: large) != nil)
    #expect(issue("ABC") == nil)
  }

  @Test @MainActor func separateSymbolMarkersKeepWrappedItemsApart() throws {
    var (graph, pageID) = try fixture(composite: false)
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var fonts)? = resources[PDFName("Font")] else { return }
    fonts[PDFName("Marker")] = .reference(PDFObjectID(40))
    resources[PDFName("Font")] = .dictionary(fonts); page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
    // An unsupported symbol mapping still provides a list boundary. It must
    // never need to become writable or be substituted to detect that boundary.
    graph.objects[PDFObjectID(40)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")), PDFName("Subtype"): .name(PDFName("TrueType")),
      PDFName("BaseFont"): .name(PDFName("ABCDEF+Wingdings")), PDFName("FirstChar"): .integer(65),
      PDFName("LastChar"): .integer(65), PDFName("Widths"): .array([.integer(684)]),
      PDFName("FontDescriptor"): .reference(PDFObjectID(6)), PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      PDFName("ToUnicode"): .reference(PDFObjectID(41))])
    graph.objects[PDFObjectID(41)] = .stream(PDFStream(bytes: Data("""
      /CIDInit /ProcSet findresource begin 12 dict begin begincmap
      1 begincodespacerange <00> <FF> endcodespacerange
      1 beginbfchar <41> <F0D8> endbfchar endcmap end end
      """.utf8)))
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /Marker 16 Tf 1 0 0 1 20 700 Tm (A) Tj ET
      BT /F1 16 Tf 1 0 0 1 42 700 Tm (ABC ABC ABC ABC ABC ABC) Tj 0 -22 Td (ABC ABC ABC ABC ABC ABC) Tj ET
      BT /Marker 16 Tf 3 Tr 1 0 0 1 20 678 Tm (A) Tj 0 Tr ET
      BT /Marker 16 Tf 1 0 0 1 350 678 Tm (A) Tj ET
      BT /Marker 16 Tf 1 0 0 1 20 656 Tm (A) Tj ET
      BT /F1 16 Tf 1 0 0 1 42 656 Tm (ABC ABC ABC ABC ABC ABC) Tj 0 -22 Td (ABC ABC ABC ABC ABC ABC) Tj ET
      """.utf8)))
    let found = try targets(graph, pageID: pageID).filter { $0.paragraph != nil }
    #expect(found.count == 2)
    #expect(found.allSatisfy { $0.paragraph?.originalText.count == 2 && $0.paragraph?.wraps == true })
    #expect(Set(found.flatMap(\.runIndices)) == [1,2,6,7])
    #expect(try PageTextEditing.listMarkers(pageID: pageID, in: graph).count == 3)
  }

  @Test @MainActor func inlineNumberedItemsDoNotMergeThroughStandardFontFallback() throws {
    var (graph, pageID) = try fixture(composite: false)
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var fonts)? = resources[PDFName("Font")] else { return }
    fonts[PDFName("Std")] = .reference(PDFObjectID(60))
    resources[PDFName("Font")] = .dictionary(fonts); page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
    graph.objects[PDFObjectID(60)] = .dictionary([PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")), PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding"))])
    let font = try #require(NSFont(name: "Helvetica", size: 16))
    let texts = ["1. This first item has enough words to wrap into more than one line while keeping its own place.",
      "2. This second item also has enough words to wrap into more than one line in the same column."]
    var baseline = 700.0, body = ""
    for text in texts {
      for line in NativeParagraphEditing.wrappedLines(text, font: font, width: 260) {
        body += "BT /Std 16 Tf 1 0 0 1 42 \(baseline) Tm (\(line)) Tj ET\n"
        baseline -= 22
      }
    }
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(body.utf8)))
    let found = try targets(graph, pageID: pageID).filter { $0.paragraph != nil }
    #expect(found.map(\.text) == texts)
    #expect(found.allSatisfy { $0.paragraph?.wraps == true })
  }

  @Test func listMarkerPrefixesDistinguishItemsFromDecimalsAndOrdinaryText() throws {
    var (graph, pageID) = try fixture(composite: false)
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data()))
    let tokens = ["• First item", "1. First item", "a) First item", "iv. First item",
      "3.14 is a decimal", "A regular paragraph", "- literal hyphen", "Item 1. inside prose", "civil. A word, not a list number"]
    let lines = tokens.enumerated().map { index, text in
      PageTextLine(text: text, x: 42, baseline: 700 - Double(index) * 22,
        segments: [.init(text: text, x: 42, format: .init(size: 16))])
    }
    graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(pageID: pageID, lines: lines,
        box: .init(x: 42, firstBaseline: 700, width: 500, lineSpacing: 22))
    ]), to: graph)
    let markers = try PageTextEditing.listMarkers(pageID: pageID, in: graph)
    #expect(markers.map(\.runIndex) == [0,1,2,3])
    #expect(markers.allSatisfy { !$0.isStandalone && $0.x == 42 && $0.fontSize == 16 })
  }

  @Test @MainActor func positionedWordGapsBecomeEditableSpacesWithoutMovingGlyphs() throws {
    var (graph, pageID) = try fixture(composite: false)
    let profile = try #require(PageTextEditing.fontProfiles(pageID: pageID, in: graph)[PDFName("F1")])
    let size = 16.0
    let word = ["A","B","C"].reduce(0.0) { $0 + profile.glyphs[$1]!.width * size / 1000 }
    let space = try #require(profile.glyphs[" "]?.width) * size / 1000
    let second = 42 + word + space * 0.9, third = second + word + space * 0.8
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /F1 16 Tf 1 0 0 1 42 700 Tm (ABC) Tj
      1 0 0 1 \(second) 700 Tm (ABC) Tj
      1 0 0 1 \(third) 700 Tm (ABC) Tj ET
      """.utf8)))
    let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph != nil })
    let paragraph = try #require(target.paragraph)
    #expect(target.text == "ABC ABC ABC")
    #expect(paragraph.originalText.values.allSatisfy { $0 == "ABC" })
    let spaces = paragraph.fragments.filter { $0.text == " " }
    #expect(spaces.count == 2)
    #expect(abs((spaces.first?.format.characterSpacing ?? 100) + space * 0.1) < 1e-6)
    #expect(abs((spaces.last?.format.characterSpacing ?? 100) + space * 0.2) < 1e-6)
    let view = NSTextView()
    let format = try #require(paragraph.fragments.first?.format)
    let formatting = NativeTextFormatting(view: view, fragments: paragraph.fragments,
      initial: format, profiles: paragraph.fontProfiles)
    formatting.render(scale: 1, minimumLineSpacing: paragraph.lineSpacing)
    #expect(!formatting.hasChanges)
    var x = 42.0
    let segments = paragraph.fragments.map { fragment -> PageTextSegment in
      defer { x += profile.glyphs[fragment.text]!.width * size / 1000 + fragment.format.characterSpacing }
      return .init(text: fragment.text, x: x, format: fragment.format)
    }
    try #require(segments.count == 11)
    #expect(abs(segments[4].x - second) < 1e-6)
    #expect(abs(segments[8].x - third) < 1e-6)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
        lines: [.init(text: target.text, x: 42, baseline: 700, segments: segments)],
        fontSize: size, color: [0,0,0], box: .init(x: 42, firstBaseline: 700, width: 240, lineSpacing: 22))
    ]), to: graph)
    let reopened = try targets(PDFParser.parse(PDFWriter.write(edited)).graph, pageID: pageID)
    #expect(reopened.first?.text == target.text)
    #expect(edited.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
  }

  @Test @MainActor func uniformWideLetterTrackingDoesNotInventWordBreaks() throws {
    var (graph, pageID) = try fixture(composite: false)
    let profile = try #require(PageTextEditing.fontProfiles(pageID: pageID, in: graph)[PDFName("F1")])
    let space = profile.glyphs[" "]!.width * 16 / 1000
    var x = 42.0, source = ""
    for character in ["A","B","C"] {
      source += "BT /F1 16 Tf 1 0 0 1 \(x) 700 Tm (\(character)) Tj ET\n"
      x += profile.glyphs[character]!.width * 16 / 1000 + space * 0.75
    }
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(source.utf8)))
    let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph != nil })
    #expect(target.text == "ABC")
    #expect(target.paragraph?.fragments.contains { $0.text == " " } == false)
  }

  @Test @MainActor func leadingWhitespaceKeepsTheVisibleOriginAndSavedGlyphs() throws {
    var (graph, pageID) = try fixture(composite: false)
    let spaces = String(repeating: " ", count: 20)
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /F1 16 Tf 1 0 0 1 42 700 Tm (\(spaces)ABC ABC) Tj ET
      """.utf8)))
    let profile = try #require(PageTextEditing.fontProfiles(pageID: pageID, in: graph)[PDFName("F1")])
    let visibleX = 42 + Double(spaces.count) * profile.glyphs[" "]!.width * 16 / 1000
    let target = try #require(targets(graph, pageID: pageID).first { $0.paragraph != nil })
    let paragraph = try #require(target.paragraph)
    #expect(target.text == "ABC ABC")
    #expect(abs(target.rect[0] - visibleX) < 0.00001)
    let format = try #require(paragraph.fragments.first?.format)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: pageID, originalText: paragraph.originalText,
        lines: [.init(text: "CBA ABC", x: target.rect[0], baseline: 700,
          segments: [.init(text: "CBA ABC", x: target.rect[0], format: format)])],
        fontSize: 16, color: [0,0,0], box: .init(x: target.rect[0], firstBaseline: 700,
          width: target.rect[2] - target.rect[0], lineSpacing: paragraph.lineSpacing, wraps: false))
    ]), to: graph)
    let reader = try #require(PDFDocument(data: PDFWriter.write(edited)))
    let page = try #require(reader.page(at: 0))
    let selection = try #require(reader.findString("CBA", withOptions: []).first)
    #expect(abs(selection.bounds(for: page).minX - visibleX) < 0.01)
    let reopened = try #require(targets(edited, pageID: pageID).first { $0.paragraph != nil })
    #expect(abs(reopened.rect[0] - visibleX) < 0.01)
    #expect(reopened.text == "CBA ABC")
  }

  @Test @MainActor func offsetImportedLinesStaySeparateUntilIndentationIsRepresentable() throws {
    var (graph, pageID) = try fixture(composite: false)
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      BT /F1 16 Tf 1 0 0 1 42 700 Tm (ABC ABC ABC ABC ABC ABC) Tj ET
      BT /F1 16 Tf 1 0 0 1 42.48 678 Tm (ABC ABC ABC ABC ABC ABC) Tj ET
      """.utf8)))
    let selected = try targets(graph, pageID: pageID).filter { $0.paragraph != nil }
    #expect(selected.count == 2)
    #expect(selected.allSatisfy { $0.paragraph?.wraps == false })
    #expect(selected.map { $0.rect[0] }.sorted() == [42,42.48])
    #expect(selected.allSatisfy { $0.runIndices.count == 1 })
  }

}
