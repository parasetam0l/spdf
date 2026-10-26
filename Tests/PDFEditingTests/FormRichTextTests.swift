import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-05 evidence: selection-level rich runs, RTF mirror, mixed-run
/// appearances, multiline/comb/long-value behavior and inherited defaults.
@Suite("Form rich text")
struct FormRichTextTests {
  private func textField(
    name: String = "Notes", rect: [Double] = [72, 600, 372, 630], multiline: Bool = false,
    maxLength: Int? = nil, comb: Bool = false
  ) throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: rect, name: name, multiline: multiline,
          required: false, readOnly: false, password: false, defaultValue: nil),
        SetFormFieldValidationCommand(fieldName: name, maxLength: maxLength),
      ]), to: graph)
    if comb {
      guard let fieldID = FormAuthoringSupport.findField(named: name, in: graph),
        case .dictionary(var field)? = graph.objects[fieldID]
      else { return (graph, pageID) }
      var flags: Int64 = 0
      if case .integer(let raw)? = field[PDFName("Ff")] { flags = raw }
      field[PDFName("Ff")] = .integer(flags | 16_777_216)
      graph.objects[fieldID] = .dictionary(field)
    }
    return (graph, pageID)
  }

  private func fieldDictionary(_ name: String, in graph: PDFGraph) throws
    -> [PDFName: PDFValue]
  {
    guard let fieldID = FormAuthoringSupport.findField(named: name, in: graph),
      case .dictionary(let dictionary)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "field missing") }
    return dictionary
  }

  private func appearanceContents(_ name: String, in graph: PDFGraph) throws -> [String] {
    let pageIDs = try PageTreeView(graph: graph).pages
    guard let field = try FormInventory.fields(in: graph, pageIDs: pageIDs)
      .first(where: { $0.name == name })
    else { throw PDFError(.malformed, "field missing") }
    var contents: [String] = []
    for widget in field.widgets {
      guard let widgetID = widget.objectID,
        case .dictionary(let dictionary)? = graph.objects[widgetID],
        case .dictionary(let appearance)? = dictionary[PDFName("AP")],
        case .reference(let streamID)? = appearance[PDFName("N")],
        case .stream(let stream)? = graph.objects[streamID],
        let decoded = try? PDFFilters.decoded(stream)
      else { continue }
      contents.append(String(decoding: decoded, as: UTF8.self))
    }
    return contents
  }

  @Test func rtfMirrorRoundTripsStyledRuns() throws {
    var value = FormRichTextValue.plain("Fatura İçin: 42 (ok)")
    value.runs = [
      FormRichTextRun(
        location: 7, length: 4,
        style: FormRichTextStyle(
          bold: true, italic: true, fontSize: 14, color: [1, 0, 0])),
      FormRichTextRun(
        location: 13, length: 2,
        style: FormRichTextStyle(bold: false, italic: false, fontSize: 9, color: [0, 0, 1])),
    ]
    let rtf = FormRichTextRTF.encode(value)
    #expect(rtf.hasPrefix("{\\rtf1"))
    #expect(rtf.contains("\\fonttbl"))
    #expect(rtf.contains("\\colortbl"))
    let decoded = try #require(FormRichTextRTF.decode(rtf))
    #expect(decoded.plainText == value.plainText)
    #expect(decoded.baseStyle.fontSize == 12)
    #expect(decoded.runs.count == 2)
    let bold = try #require(decoded.runs.first)
    #expect(bold.style.bold)
    #expect(bold.style.italic)
    #expect(bold.style.fontSize == 14)
    #expect(bold.style.color == [1, 0, 0], "decoded bold color \(bold.style.color)")
    #expect((decoded.plainText as NSString).substring(with: bold.range) == "İçin")
    let second = try #require(decoded.runs.last)
    #expect(second.style.fontSize == 9)
    #expect(second.style.color == [0, 0, 1], "decoded second color \(second.style.color)")
    #expect((decoded.plainText as NSString).substring(with: second.range) == "42")
    // Astral scalars survive the surrogate-pair mirror.
    let astral = FormRichTextValue.plain("A\u{1F600}B")
    let astralDecoded = try #require(FormRichTextRTF.decode(FormRichTextRTF.encode(astral)))
    #expect(astralDecoded.plainText == "A\u{1F600}B")
  }

  @Test func rtfDecoderRejectsMalformedInput() {
    #expect(FormRichTextRTF.decode("") == nil)
    #expect(FormRichTextRTF.decode("not rtf at all") != nil)
    let deep = String(repeating: "{", count: 100) + "x"
    #expect(FormRichTextRTF.decode(deep) == nil)
  }

  @Test func applyingStyleOverSelectionRebuildsMinimalRuns() throws {
    let value = FormRichTextValue.plain("Hello world")
    let bold = try value.applying(
      style: FormRichTextStyle(bold: true, fontSize: 12), to: NSRange(location: 6, length: 5))
    #expect(bold.runs.count == 1)
    #expect(bold.runs.first?.location == 6)
    #expect(bold.runs.first?.length == 5)
    #expect(bold.style(atUTF16Offset: 0).bold == false)
    #expect(bold.style(atUTF16Offset: 8).bold == true)
    // A second style over the same selection replaces the first.
    let italic = try bold.applying(
      style: FormRichTextStyle(italic: true, fontSize: 12), to: NSRange(location: 6, length: 5))
    #expect(italic.runs.count == 1)
    #expect(italic.runs.first?.style.bold == false)
    #expect(italic.runs.first?.style.italic == true)
  }

  @Test func appliedRangeSnapsToComposedCharacters() throws {
    // "I" + combining dot above is one composed character over two UTF-16 units.
    let value = FormRichTextValue.plain("I\u{0307}st")
    #expect(value.utf16Length == 4)
    // A range that covers only the combining mark expands to the complete
    // composed character instead of splitting it.
    let expanded = try value.applying(
      style: FormRichTextStyle(bold: true), to: NSRange(location: 1, length: 1))
    #expect(expanded.runs.first?.location == 0)
    #expect(expanded.runs.first?.length == 2)
  }

  @Test func singleLineRichFillWritesValueRichValueAndMixedAppearance() throws {
    var (graph, pageID) = try textField()
    var value = FormRichTextValue.plain(
      "Total 42", style: FormRichTextStyle(fontSize: 14, color: [0, 0, 0]))
    value.runs = [
      FormRichTextRun(
        location: 6, length: 2,
        style: FormRichTextStyle(bold: true, fontSize: 18, color: [1, 0, 0]))
    ]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    let field = try fieldDictionary("Notes", in: graph)
    guard case .string(let valueData)? = field[PDFName("V")],
      case .string(let richData)? = field[PDFName("RV")],
      case .integer(let flags)? = field[PDFName("Ff")],
      case .string(let daData)? = field[PDFName("DA")]
    else {
      Issue.record("value/rich value/flags/DA missing")
      return
    }
    #expect(AnnotationText.decode(valueData) == "Total 42")
    #expect(flags & 33_554_432 != 0)
    #expect(String(decoding: daData, as: UTF8.self).contains("14"))
    let decodedRich = try #require(
      FormRichTextRTF.decode(String(decoding: richData, as: UTF8.self)))
    #expect(decodedRich.plainText == "Total 42")
    #expect(decodedRich.runs.first?.style.bold == true)
    let contents = try appearanceContents("Notes", in: graph)
    #expect(contents.count == 1)
    let content = try #require(contents.first)
    // Two font sizes and the run color are painted in one appearance.
    #expect(content.contains("18 Tf"))
    #expect(content.contains("14 Tf"))
    #expect(content.contains("1 0 0 rg"))
    // Reopening keeps the canonical value and rich mirror.
    let reopened = try PDFParser.parse(try PDFWriter.write(graph))
    let reopenedField = try FormInventory.fields(
      in: reopened.graph, pageIDs: [pageID]).first { $0.name == "Notes" }
    #expect(reopenedField?.stringValue == "Total 42")
    let reopenedDictionary = try #require(
      reopenedField?.fieldID.flatMap { reopened.graph.objects[$0] })
    if case .dictionary(let dictionary) = reopenedDictionary {
      #expect(dictionary[PDFName("RV")] != nil)
    } else {
      Issue.record("reopened field missing")
    }
  }

  @Test func multilineRichFillWrapsIntoSeveralLines() throws {
    var (graph, _) = try textField(rect: [72, 560, 272, 630], multiline: true)
    let value = FormRichTextValue.plain(
      "The quick brown fox jumps over the lazy dog and keeps running for a long time",
      style: FormRichTextStyle(fontSize: 12))
    let properties = try FormEffectivePropertiesReader.properties(
      forFieldNamed: "Notes", in: graph)
    #expect(properties.isMultiline, "field must be multiline")
    #expect(properties.widgetRects == [[72, 560, 272, 630]], "widget rect \\(properties.widgetRects)")
    let base = try FormEffectivePropertiesReader.appearanceFont(for: properties, in: graph)
    let layout = FormRichTextAppearance.layout(
      value: value, rect: [72, 560, 272, 630], multiline: true, comb: false, maxLength: nil,
      baseFont: base, runFonts: [:])
    #expect(layout.lineCount > 2, "layout lines \\(layout.lineCount)")
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    let content = try #require(try appearanceContents("Notes", in: graph).first)
    let tmCount = content.components(separatedBy: " Tm ").count - 1
    #expect(tmCount > 2, "multiline appearance shows \(tmCount) text segments")
    #expect(content.contains("12 Tf") || content.contains(" Tf"))
  }

  @Test func combRichFillPaintsOneCharacterPerCell() throws {
    var (graph, _) = try textField(rect: [72, 560, 272, 590], maxLength: 5, comb: true)
    let value = FormRichTextValue.plain("AB12C", style: FormRichTextStyle(fontSize: 14))
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    let content = try #require(try appearanceContents("Notes", in: graph).first)
    let showCount = content.components(separatedBy: " Tj ").count - 1
    #expect(showCount == 5)
    // Overlong comb values are refused explicitly.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormRichTextCommand(
            fieldName: "Notes",
            value: FormRichTextValue.plain("TOOLONG"))
        ]), to: graph)
    }
  }

  @Test func longSingleLineValueShrinksButUnusableValueRefuses() throws {
    var (graph, _) = try textField(rect: [72, 600, 192, 624])
    let fits = String(repeating: "wide ", count: 7)
    let value = FormRichTextValue.plain(fits, style: FormRichTextStyle(fontSize: 12))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    let content = try #require(try appearanceContents("Notes", in: edited).first)
    let sizes = content.components(separatedBy: " Tf ").compactMap { chunk -> Double? in
      let tokens = chunk.split(whereSeparator: { $0 == " " || $0 == "\n" })
      return tokens.last.flatMap { Double($0) }
    }
    #expect(sizes.allSatisfy { $0 < 12 && $0 >= 4 })
    graph = edited
    let unusable = String(repeating: "W", count: 400)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormRichTextCommand(
            fieldName: "Notes",
            value: FormRichTextValue.plain(unusable, style: FormRichTextStyle(fontSize: 12)))
        ]), to: graph)
    }
  }

  @Test func runLevelEmbeddedFontAndNewlinesAreRefused() throws {
    let (graph, _) = try textField()
    var value = FormRichTextValue.plain("Hi")
    value.runs = [
      FormRichTextRun(
        location: 0, length: 2,
        style: FormRichTextStyle(font: .embedded(
          FormEmbeddedFontSource(program: Data([0x00]), familyName: "Fake"))))
    ]
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormRichTextCommand(
            fieldName: "Notes", value: FormRichTextValue.plain("line one\nline two"))
        ]), to: graph)
    }
  }

  @Test func standardFaceThatCannotEncodeTheTextIsRefused() throws {
    let (graph, _) = try textField()
    var value = FormRichTextValue.plain("Greek: ΑΒΓ")
    value.runs = [
      FormRichTextRun(
        location: 7, length: 3,
        style: FormRichTextStyle(fontSize: 12, font: .standard(.helveticaBold)))
    ]
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    }
  }

  @Test func repeatedWidgetsAllGetTheRichAppearance() throws {
    var (graph, pageID) = try textField()
    // Duplicate the field as a shared-value widget so one field has two widgets.
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        DuplicateFormFieldCommand(
          fieldName: "Notes", pageID: pageID, offset: [0, -40], sharing: .sharedValue)
      ]), to: graph)
    let pageIDs = try PageTreeView(graph: graph).pages
    let field = try #require(
      try FormInventory.fields(in: graph, pageIDs: pageIDs).first { $0.name == "Notes" })
    #expect(field.widgets.count == 2)
    var value = FormRichTextValue.plain("Shared", style: FormRichTextStyle(fontSize: 11))
    value.runs = [
      FormRichTextRun(
        location: 0, length: 3,
        style: FormRichTextStyle(italic: true, fontSize: 16))
    ]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]), to: graph)
    let contents = try appearanceContents("Notes", in: graph)
    #expect(contents.count == 2)
    #expect(contents.allSatisfy { $0.contains("16 Tf") })
  }
}
