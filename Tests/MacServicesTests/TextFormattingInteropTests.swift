import AppKit
import Foundation
import MacServices
import PDFCore
@testable import PDFEditing
import PDFFixtures
import PDFKit
import Testing

@MainActor
private final class FormatTestTextView: NSTextView {
  let history = UndoManager()
  override var undoManager: UndoManager? { history }
}

@Suite("Native character formatting and saved PDF text")
struct TextFormattingInteropTests {
  @Test @MainActor func nativePreviewRetainsConstantTextOpacity() throws {
    let view = FormatTestTextView(frame: .zero)
    let format = PageTextFormat(size: 16, opacity: 0.5)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "Half", format: format)], initial: format)
    formatting.render(scale: 1, minimumLineSpacing: 19)
    let color = try #require(
      view.textStorage?.attribute(
        .foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    #expect(abs(color.alphaComponent - 0.5) < 0.001)
  }

  @Test @MainActor func mixedEmbeddedSubsetsResolvePerCharacterWithoutSubstitution() throws {
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    let first = PageTextSourceFont(resource: PDFName("TT1"), name: "DejaVuSans")
    let second = PageTextSourceFont(resource: PDFName("TT2"), name: "DejaVuSans")
    let unrelated = PageTextSourceFont(resource: PDFName("C1"), name: "OtherSans")
    let glyphA = PageTextFontProfile.Glyph(
      id: inspector.unicodeToGlyph[0x41]!, width: 700, codes: [0x41])
    let glyphB = PageTextFontProfile.Glyph(
      id: inspector.unicodeToGlyph[0x42]!, width: 700, codes: [0x42])
    let firstProfile = PageTextFontProfile(source: first, program: program, glyphs: ["A": glyphA])
    let secondProfile = PageTextFontProfile(source: second, program: program, glyphs: ["B": glyphB])
    let unrelatedProfile = PageTextFontProfile(
      source: unrelated, program: program, glyphs: ["B": glyphB])
    let base = PageTextFormat(size: 16, sourceFont: first)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "A", format: base)], initial: base,
      profiles: [firstProfile.source.resource: firstProfile, secondProfile.source.resource: secondProfile])
    formatting.render(scale: 1, minimumLineSpacing: 19)
    view.setSelectedRange(NSRange(location: 1, length: 0))
    let plan = formatting.insertionPlan("BA", replacing: view.selectedRange())
    #expect(plan.issue == nil)
    #expect(plan.usesSourceFontFallback)
    #expect(plan.fragments.map(\.text) == ["B", "A"])
    #expect(plan.fragments.map { $0.format.sourceFont?.resource } == [PDFName("TT2"), PDFName("TT1")])
    #expect(plan.attributedText?.length == 2)

    let unrelatedView = FormatTestTextView(frame: .zero)
    let unrelatedFormatting = NativeTextFormatting(
      view: unrelatedView, fragments: [.init(text: "A", format: base)], initial: base,
      profiles: [firstProfile.source.resource: firstProfile,
        unrelatedProfile.source.resource: unrelatedProfile])
    unrelatedFormatting.render(scale: 1, minimumLineSpacing: 19)
    unrelatedView.setSelectedRange(NSRange(location: 1, length: 0))
    let refused = unrelatedFormatting.insertionPlan("B", replacing: unrelatedView.selectedRange())
    #expect(refused.issue != nil)
    #expect(!refused.usesSourceFontFallback)
    #expect(refused.attributedText == nil)
  }

  @Test @MainActor func embeddedParagraphFontsAreSelectableOnlyForCoveredText() throws {
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    let first = PageTextSourceFont(resource: PDFName("TT1"), name: "DejaVuSans")
    let second = PageTextSourceFont(resource: PDFName("TT2"), name: "DejaVuSans")
    let glyphA = PageTextFontProfile.Glyph(
      id: inspector.unicodeToGlyph[0x41]!, width: 700, codes: [0x41])
    let glyphB = PageTextFontProfile.Glyph(
      id: inspector.unicodeToGlyph[0x42]!, width: 700, codes: [0x42])
    let firstProfile = PageTextFontProfile(
      source: first, program: program, glyphs: ["A": glyphA, "B": glyphB])
    let secondProfile = PageTextFontProfile(source: second, program: program, glyphs: ["A": glyphA])
    let original = PageTextFormat(size: 16, sourceFont: first)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view,
      fragments: [
        .init(text: "AB", format: original),
        .init(text: "A", format: PageTextFormat(size: 16, sourceFont: second)),
      ], initial: original,
      profiles: [first.resource: firstProfile, second.resource: secondProfile])
    formatting.render(scale: 1, minimumLineSpacing: 19)

    view.setSelectedRange(NSRange(location: 0, length: 2))
    #expect(formatting.availableSourceFonts(isTyping: true) == [first])
    let before = formatting.fragments()
    #expect(formatting.apply(.sourceFont(second), isTyping: true) != nil)
    #expect(formatting.fragments() == before)

    view.setSelectedRange(NSRange(location: 0, length: 1))
    #expect(formatting.availableSourceFonts(isTyping: true) == [first, second])
    #expect(formatting.apply(.sourceFont(second), isTyping: true) == nil)
    #expect(formatting.fragments() == [
      .init(text: "A", format: PageTextFormat(size: 16, sourceFont: second)),
      .init(text: "B", format: original),
      .init(text: "A", format: PageTextFormat(size: 16, sourceFont: second)),
    ])
  }

  @Test @MainActor func acceptedLicensedFontPreviewsFormatsAndPersistsParagraphText() throws {
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let custom = CustomTextFont(
      program: program, familyName: "DejaVuSans", faceName: "DejaVu Sans · Book",
      identifier: "fixture-font")
    let original = PageTextFormat(size: 16)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "AB", format: original)], initial: original,
      licensedFonts: [custom])
    formatting.render(scale: 1, minimumLineSpacing: 20)
    view.setSelectedRange(NSRange(location: 0, length: 2))

    #expect(formatting.availableLicensedFonts(isTyping: true) == [custom])
    #expect(formatting.apply(.licensedFont(custom), isTyping: true) == nil)
    #expect(formatting.fragments() == [
      .init(text: "AB", format: PageTextFormat(size: 16, customFont: custom))
    ])
    let preview = try #require(
      view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(preview.fontName.localizedCaseInsensitiveContains("DejaVu"))

    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    let format = PageTextFormat(size: 16, customFont: custom)
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 120, lineSpacing: 20)
    let line = PageTextLine(text: "AB", x: 48, baseline: 700,
      segments: [.init(text: "AB", x: 48, format: format)], endsParagraph: true)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)
    ]), to: parsed.graph)
    let bytes = try PDFWriter.write(edited)
    let reopened = try PDFParser.parse(bytes)
    let record = try #require(
      AuthoredPageTextBoxes.read(pageID: pageID, in: reopened.graph).first)
    #expect(record.fragments.map(\.text).joined() == "AB\n")
    #expect(record.fragments.first?.format.sourceFont != nil)
    #expect(record.fragments.first?.format.customFont == nil)
    #expect(PDFDocument(data: bytes)?.string?.contains("AB") == true)
  }

  @Test @MainActor func selectedLicensedFontBecomesTheReplacementTypingStyle() throws {
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let inspector = try TrueTypeInspector.inspect(program, requireUnicodeMap: false)
    let source = PageTextSourceFont(resource: PDFName("Subset"), name: "DejaVuSans")
    let glyphB = PageTextFontProfile.Glyph(
      id: try #require(inspector.unicodeToGlyph[0x42]), width: 700, codes: [0x42])
    let profile = PageTextFontProfile(source: source, program: program, glyphs: ["B": glyphB])
    let custom = CustomTextFont(
      program: program, familyName: "DejaVuSans", faceName: "DejaVu Sans · Book",
      identifier: "replacement-font")
    let original = PageTextFormat(size: 16, sourceFont: source)
    let view = FormatTestTextView(frame: .zero)
    let formatting = NativeTextFormatting(
      view: view, fragments: [.init(text: "B", format: original)], initial: original,
      profiles: [source.resource: profile], licensedFonts: [custom])
    formatting.render(scale: 1, minimumLineSpacing: 20)
    view.setSelectedRange(NSRange(location: 0, length: 1))

    #expect(formatting.apply(.licensedFont(custom), isTyping: true) == nil)
    let plan = formatting.insertionPlan("A", replacing: view.selectedRange())
    #expect(plan.issue == nil)
    #expect(plan.fragments == [.init(
      text: "A", format: PageTextFormat(size: 16, customFont: custom))])
  }

  @Test @MainActor func selectedWordsKeepIndependentStylesAndFormattingUndo() throws {
    let view = FormatTestTextView(frame: .zero)
    view.history.groupsByEvent = false
    let regular = PageTextFormat(size: 16)
    let input = "Keep these words and this."
    let formatting = NativeTextFormatting(
      view: view,
      fragments: [.init(text: input, format: regular)], initial: regular)
    formatting.render(scale: 1, minimumLineSpacing: 19.2)
    #expect(!formatting.hasChanges)
    view.setSelectedRange((input as NSString).range(of: "these words"))
    for change: PageTextFormatChange in [
      .bold(true), .italic(true), .family(.times), .size(18), .color([0.8, 0.1, 0.2]),
    ] {
      #expect(formatting.apply(change, isTyping: true) == nil)
    }
    let expected = [
      PageTextFragment(text: "Keep ", format: regular),
      .init(
        text: "these words",
        format: .init(font: .timesBoldItalic, size: 18, color: [0.8, 0.1, 0.2])),
      .init(text: " and this.", format: regular),
    ]
    #expect(formatting.fragments() == expected)
    view.history.undo()
    let withoutColor = try #require(formatting.fragments().first { $0.text == "these words" })
    #expect(withoutColor.format.color == [0, 0, 0])
    view.history.undo()
    let withoutSize = try #require(formatting.fragments().first { $0.text == "these words" })
    #expect(withoutSize.format.size == 16)
    view.history.redo()
    view.history.redo()
    #expect(formatting.fragments() == expected)
    formatting.render(scale: 2, minimumLineSpacing: 19.2)
    let selected = (view.string as NSString).range(of: "these words")
    let font = try #require(
      view.textStorage?.attribute(.font, at: selected.location, effectiveRange: nil) as? NSFont)
    #expect(font.pointSize == 36)
    #expect(formatting.fragments() == expected)
  }

  @Test @MainActor func zoomAndCaretFormattingDoNotDirtyUnchangedText() throws {
    let view = FormatTestTextView(frame: .zero)
    let format = PageTextFormat(size: 14)
    let formatting = NativeTextFormatting(
      view: view,
      fragments: [.init(text: "One ", format: format), .init(text: "paragraph", format: format)],
      initial: format)
    for scale in [1.0, 2, 0.75, 1.25] {
      formatting.render(scale: scale, minimumLineSpacing: 18)
      #expect(!formatting.hasChanges)
    }
    view.setSelectedRange(NSRange(location: 4, length: 0))
    #expect(formatting.apply(.bold(true), isTyping: true) == nil)
    #expect(!formatting.hasChanges)
    #expect(formatting.selection(isTyping: true).format.font.isBold)
    view.insertText("new ", replacementRange: view.selectedRange())
    #expect(formatting.fragments().contains { $0.text == "new " && $0.format.font.isBold })
  }

  @Test @MainActor func unsupportedCharactersRefuseFormattingWithoutSubstitution() throws {
    let view = FormatTestTextView(frame: .zero)
    let input = "Keep 🐈 intact"
    let format = PageTextFormat(size: 16)
    let formatting = NativeTextFormatting(
      view: view,
      fragments: [.init(text: input, format: format)], initial: format)
    view.setSelectedRange(NSRange(location: 0, length: (input as NSString).length))
    let before = formatting.fragments()
    #expect(formatting.apply(.family(.courier), isTyping: true) != nil)
    #expect(formatting.fragments() == before)
    #expect(view.string == input)
  }

  @Test @MainActor func savedMixedFontBoxRetainsWidthBreaksAndCanBeEditedAgain() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    let regular = PageTextFormat(size: 16)
    let emphasized = PageTextFormat(font: .timesBoldItalic, size: 18, color: [0.8, 0.1, 0.2])
    let lines = [
      PageTextLine(
        text: "Keep these words ", x: 48, baseline: 700,
        segments: [
          .init(text: "Keep ", x: 48, format: regular),
          .init(text: "these words ", x: 92, format: emphasized),
        ]),
      .init(
        text: "and this.", x: 48, baseline: 676,
        segments: [.init(text: "and this.", x: 48, format: regular)], endsParagraph: true),
      .init(text: "", x: 48, baseline: 652, endsParagraph: true),
      .init(
        text: "Next paragraph.", x: 48, baseline: 628,
        segments: [.init(text: "Next paragraph.", x: 48, format: regular)]),
    ]
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 287.125, lineSpacing: 24)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(pageID: pageID, lines: lines, box: box)
      ]), to: parsed.graph)
    let bytes = try PDFWriter.write(graph)
    let reopened = try PDFParser.parse(bytes)
    let records = try AuthoredPageTextBoxes.read(pageID: pageID, in: reopened.graph)
    let record = try #require(records.first)
    #expect(records.count == 1)
    #expect(record.box == box)
    #expect(
      record.fragments.map(\.text).joined() == "Keep these words and this.\n\nNext paragraph.")
    let reader = try #require(PDFDocument(data: bytes))
    let page = try #require(reader.page(at: 0))
    let selection = try #require(
      reader.findString("these words", withOptions: []).first?.attributedString)
    let font = try #require(selection.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(font.fontName == "Times-BoldItalic")
    #expect(abs(font.pointSize - 18) < 0.01)
    let color = try #require(
      (selection.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
        .usingColorSpace(.sRGB))
    #expect(abs(color.redComponent - 0.8) < 0.001)
    let targets = NativeParagraphEditing.targets(
      from: [], pageID: pageID, graph: reopened.graph, page: page, pageIndex: 0)
    let target = try #require(targets.first)
    #expect(target.paragraph?.fragments == record.fragments)
    #expect(abs(target.rect[2] - target.rect[0] - box.width) < 0.001)
    let updated = try PDFEditingEngine.commit(
      PDFTransaction([
        RewritePageTextCommand(
          pageID: pageID, originalText: record.originalText,
          lines: lines, fontSize: 16, color: [0, 0, 0],
          standardFontAdvances: target.paragraph?.standardFontAdvances ?? [:], box: box)
      ]), to: reopened.graph)
    #expect(try AuthoredPageTextBoxes.read(pageID: pageID, in: updated).count == 1)
    #expect(
      PDFDocument(data: try PDFWriter.write(updated))?.string?.contains("Next paragraph.") == true)
  }

  @Test func selectedEmbeddedFontCanBeReusedInSavedParagraph() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    let embedded = try PDFEditingEngine.commit(PDFTransaction([
      AddTextObjectCommand(pageID: pageID, rect: [48, 680, 200, 710], text: "AB",
        customFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
    ]), to: parsed.graph)
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: embedded)
    let profile = try #require(profiles.values.first { $0.glyphs["B"] != nil })
    let format = PageTextFormat(size: 14, sourceFont: profile.source)
    let box = PageTextBox(x: 48, firstBaseline: 640, width: 200, lineSpacing: 18, wraps: false)
    let line = PageTextLine(text: "B", x: 48, baseline: 640,
      segments: [.init(text: "B", x: 48, format: format)])
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)
    ]), to: embedded)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let record = try #require(AuthoredPageTextBoxes.read(pageID: pageID, in: reopened.graph).first)

    #expect(record.fragments == [.init(text: "B", format: format)])
    #expect(record.fragments.first?.format.sourceFont == profile.source)
  }

  @Test @MainActor func authoredWrappedLinesReconstructSoftSeparators() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = parsed.pageIDs[0]
    let format = PageTextFormat(size: 16)
    let lines = [
      PageTextLine(text: "First visual line", x: 48, baseline: 700,
        segments: [.init(text: "First visual line", x: 48, format: format)]),
      PageTextLine(text: "second wrapped line", x: 48, baseline: 676,
        segments: [.init(text: "second wrapped line", x: 48, format: format)]),
    ]
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 200, lineSpacing: 24, wraps: true)
    let graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(pageID: pageID, lines: lines, box: box)
    ]), to: parsed.graph)
    let reopened = try PDFParser.parse(PDFWriter.write(graph))
    let record = try #require(AuthoredPageTextBoxes.read(pageID: pageID, in: reopened.graph).first)

    #expect(record.fragments.map(\.text).joined() == "First visual line second wrapped line")
  }

  @Test @MainActor func standardFontWriterKeepsCombinedTraitsForAllFamilies() throws {
    for family: AddedTextStyle.Family in [.helvetica, .times, .courier] {
      let parsed = try PDFParser.parse(BlankPDF.data())
      let graph = try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextObjectCommand(
            pageID: parsed.pageIDs[0], rect: [40, 600, 450, 700], text: "Bold italic",
            style: .init(family: family, bold: true, italic: true, size: 18))
        ]), to: parsed.graph)
      let reader = try #require(PDFDocument(data: PDFWriter.write(graph)))
      let attributes = try #require(
        reader.findString("Bold italic", withOptions: []).first?.attributedString)
      let font = try #require(attributes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
      #expect(
        font.fontName == StandardTextFont.face(family: family, bold: true, italic: true).rawValue)
    }
  }

  @Test @MainActor func supportedGlyphsRoundTripAndUnsupportedGlyphsRefuseSave() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let box = PageTextBox(x: 48, firstBaseline: 700, width: 300, lineSpacing: 20)
    let supported = "Café costs €5 — résumé."
    let format = PageTextFormat(font: .timesItalic, size: 16)
    func command(_ text: String) -> AddPageTextLinesCommand {
      .init(
        pageID: parsed.pageIDs[0],
        lines: [
          .init(
            text: text, x: 48, baseline: 700,
            segments: [.init(text: text, x: 48, format: format)])
        ], box: box)
    }
    let graph = try PDFEditingEngine.commit(PDFTransaction([command(supported)]), to: parsed.graph)
    let reader = try #require(PDFDocument(data: PDFWriter.write(graph)))
    #expect(reader.string?.trimmingCharacters(in: .whitespacesAndNewlines) == supported)
    #expect(throws: PDFError.self) { try command("Keep 東京 intact").validate(in: parsed.graph) }
    #expect(throws: PDFError.self) { try command("Keep 🐈 intact").validate(in: parsed.graph) }

    var forged = graph
    for (id, object) in graph.objects {
      guard case .stream(let stream) = object,
        case .array(var geometry)? = stream.dictionary[PDFName("SPDFTextBox")]
      else { continue }
      geometry[0] = .real(148)
      var dictionary = stream.dictionary
      dictionary[PDFName("SPDFTextBox")] = .array(geometry)
      forged.objects[id] = .stream(.init(dictionary: dictionary, bytes: stream.bytes))
    }
    #expect(try AuthoredPageTextBoxes.read(pageID: parsed.pageIDs[0], in: forged).isEmpty)
    #expect(PDFDocument(data: try PDFWriter.write(forged))?.string == reader.string)
  }

  @Test @MainActor func newFormattedTextRestoresInitialPageGraphicsState() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let page = parsed.pageIDs[0]
    guard case .dictionary(var dictionary)? = parsed.graph.objects[page]
    else {
      Issue.record("Missing blank page stream")
      return
    }
    var source = parsed.graph
    let streamID = PDFObjectID(1_000)
    dictionary[PDFName("Contents")] = .reference(streamID)
    source.objects[page] = .dictionary(dictionary)
    source.objects[streamID] = .stream(
      .init(
        dictionary: [:],
        bytes: Data("2 0 0 2 10 10 cm\n0 0 1 1 re W n\n".utf8)))
    let originalStream = source.objects[streamID]
    let format = PageTextFormat(size: 16)
    let command = AddPageTextLinesCommand(
      pageID: page,
      lines: [
        .init(
          text: "Visible at page position", x: 48, baseline: 700,
          segments: [.init(text: "Visible at page position", x: 48, format: format)])
      ],
      box: .init(x: 48, firstBaseline: 700, width: 300, lineSpacing: 20))
    let result = try PDFEditingEngine.commit(PDFTransaction([command]), to: source)
    let reader = try #require(PDFDocument(data: PDFWriter.write(result)))
    let selection = try #require(
      reader.findString("Visible at page position", withOptions: []).first)
    let outputPage = try #require(reader.page(at: 0))
    #expect(abs(selection.bounds(for: outputPage).minX - 48) < 0.01)
    #expect(
      selection.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        == NSFont(name: "Helvetica", size: 16))
    #expect(source.objects[streamID] == originalStream)
    var unbalanced = source
    unbalanced.objects[streamID] = .stream(.init(dictionary: [:], bytes: Data("q\n".utf8)))
    #expect(throws: PDFError.self) { try command.validate(in: unbalanced) }
  }

  @Test @MainActor func familiarFontNameDoesNotPermitSilentSourceSubstitution() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let page = parsed.pageIDs[0]
    let source = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(pageID: page, rect: [48, 600, 350, 720], text: "Keep the source font")
      ]), to: parsed.graph)
    #expect(try StandardTextFont.editableRunIndices(pageID: page, in: source) == [0])
    guard case .dictionary(let pageObject)? = source.objects[page],
      case .dictionary(let resources)? = pageObject[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let id)? = fonts.values.first,
      case .dictionary(let originalFont)? = source.objects[id]
    else {
      Issue.record("Missing source font")
      return
    }
    for customization: (PDFName, PDFValue) in [
      (PDFName("Widths"), .array([.integer(900)])),
      (PDFName("FontDescriptor"), .dictionary([:])),
      (
        PDFName("Encoding"),
        .dictionary([PDFName("Differences"): .array([.integer(65), .name(PDFName("B"))])])
      ),
    ] {
      var customized = source
      var font = originalFont
      font[customization.0] = customization.1
      customized.objects[id] = .dictionary(font)
      #expect(try StandardTextFont.editableRunIndices(pageID: page, in: customized).isEmpty)
      let reader = try #require(PDFDocument(data: PDFWriter.write(customized)))
      let nativePage = try #require(reader.page(at: 0))
      let block = PageTextTarget(
        pageIndex: 0, runIndex: 0, rect: [48, 690, 300, 720],
        text: "Keep the source font", style: .init(fontFamily: "Helvetica", fontSize: 12, fillColor: [0, 0, 0]))
      let target = NativeParagraphEditing.targets(
        from: [block], pageID: page,
        graph: customized, page: nativePage)
      #expect(target.count == 1 && target[0].paragraph == nil)
    }
  }
}
