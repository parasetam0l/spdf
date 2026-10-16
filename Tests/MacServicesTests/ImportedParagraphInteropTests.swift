import AppKit
import CoreText
import Foundation
import MacServices
import PDFCore
@testable import PDFEditing
import PDFFixtures
import PDFKit
import Testing

@Suite("Imported paragraph editing")
struct ImportedParagraphInteropTests {
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
    let blocks = try PageTextEditing.blocks(pageID: pageID, in: graph).map { block in
      let matches = reader.findString(block.text.trimmingCharacters(in: .whitespacesAndNewlines), withOptions: [])
      let nearest = matches.map { $0.bounds(for: page) }.min {
        hypot($0.minX - block.rect[0], $0.minY - block.rect[1]) < hypot($1.minX - block.rect[0], $1.minY - block.rect[1])
      }
      let rect = nearest.map { [$0.minX, $0.minY, $0.maxX, $0.maxY] } ?? block.rect
      return PageTextTarget(pageIndex: 0, runIndex: block.runIndices[0], rect: rect,
        text: block.text, style: block.style, runIndices: block.runIndices)
    }
    return NativeParagraphEditing.targets(from: blocks, pageID: pageID, graph: graph, page: page)
  }

  @Test @MainActor func embeddedSimpleAndIdentitySubsetParagraphsKeepTheOriginalFont() throws {
    for composite in [false, true] {
      let (graph, pageID) = try fixture(composite: composite)
      let grouped = try targets(graph, pageID: pageID)
      let target = try #require(grouped.first { $0.paragraph?.originalText.count == 2 })
      let paragraph = try #require(target.paragraph)
      #expect(paragraph.fragments.first?.format.sourceFont?.name == "DejaVuSans")
      #expect(target.text == "ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC ABC")
      let view = NSTextView(); let initial = try #require(paragraph.fragments.first?.format)
      let formatting = NativeTextFormatting(view: view, fragments: paragraph.fragments,
        initial: initial, profiles: paragraph.fontProfiles)
      formatting.render(scale: 1, minimumLineSpacing: 22)
      #expect(!formatting.hasChanges)
      #expect((view.font?.fontName ?? "").contains("DejaVuSans"))
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
    let states: [[PDFName: PDFValue]] = [
      [PDFName("BM"): .name(PDFName("Normal")), PDFName("ca"): .real(1)],
      [PDFName("ca"): .real(0.5)], [PDFName("Font"): .array([.reference(PDFObjectID(4)), .integer(16)])]
    ]
    for state in states {
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
      #expect(hasParagraph == (state[PDFName("BM")] != nil))
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
    var bytes = [UInt8](stream.bytes)
    let inspector = try TrueTypeInspector.inspect(Data(bytes))
    let count = try TrueTypeInspector.u16(bytes, at: 4)
    for index in 0..<count {
      let offset = 12 + index * 16
      if String(decoding: bytes[offset..<offset + 4], as: UTF8.self) == "cmap" {
        bytes.replaceSubrange(offset..<offset + 4, with: Array("zzzz".utf8))
      }
    }
    let head = try #require(inspector.tables["head"])
    bytes.replaceSubrange(head.offset + 8..<head.offset + 12, with: [0, 0, 0, 0])
    let adjustment = (0xB1B0_AFBA - TrueTypeSubsetter.checksum(bytes)) & 0xFFFF_FFFF
    bytes.replaceSubrange(head.offset + 8..<head.offset + 12, with: TrueTypeSubsetter.u32Bytes(adjustment))
    graph.objects[PDFObjectID(7)] = .stream(PDFStream(bytes: Data(bytes)))
    #expect(throws: PDFError.self) { try TrueTypeInspector.inspect(Data(bytes)) }
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: graph)
    let profile = try #require(profiles[PDFName("F1")])
    let preview = try #require(profile.previewProgram)
    let previewInfo = try TrueTypeInspector.inspect(preview)
    let originalInfo = try TrueTypeInspector.inspect(Data(bytes), requireUnicodeMap: false)
    #expect(previewInfo.unicodeToGlyph[65] == inspector.unicodeToGlyph[65])
    for tag in ["glyf", "loca", "hmtx", "maxp"] {
      let before = try #require(originalInfo.tables[tag]); let after = try #require(previewInfo.tables[tag])
      #expect(Array(bytes[before.offset..<before.offset + before.length])
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
    #expect(graph.objects[PDFObjectID(7)] == .stream(PDFStream(bytes: Data(bytes))))
  }
  @Test @MainActor func rectangularClipsSurviveNativeDiscoveryRewriteAndReopen() throws {
    for composite in [false, true] {
      var (graph, pageID) = try fixture(composite: composite)
      guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else { return }
      // Two nested clips, one under a transformed CTM, have one intersection.
      let prefix = "q 20 660 360 80 re W n q 2 0 0 2 0 0 cm 20 336 140 21 re W* n 0.5 0 0 0.5 0 0 cm\n"
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(prefix.utf8) + stream.bytes + Data("\nQ Q".utf8)))
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
    var large = format; large.size = 36
    #expect(issue("ABC", format: large) != nil)
    #expect(issue("ABC") == nil)
  }

}
