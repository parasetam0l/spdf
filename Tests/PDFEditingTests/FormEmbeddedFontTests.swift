import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-05 evidence: embedded TrueType appearance fonts (Type0 Identity-H with
/// ToUnicode/CIDToGIDMap), refusal of missing glyphs/CFF, reuse and independent
/// decode after save/reopen.
@Suite("Form embedded appearance fonts")
struct FormEmbeddedFontTests {
  private func shapingProgram() throws -> Data {
    guard let data = Data(base64Encoded: ShapingFixtureData.programBase64) else {
      throw PDFError(.malformed, "fixture program is corrupt")
    }
    return data
  }

  private func multilingualProgram() throws -> Data {
    guard let data = Data(base64Encoded: FontFixtureData.multilingualProgramBase64) else {
      throw PDFError(.malformed, "fixture program is corrupt")
    }
    return data
  }

  private func textField() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 372, 630], name: "Name")
      ]), to: graph)
    return (graph, pageID)
  }

  private func field(_ name: String, in graph: PDFGraph) throws -> FormField {
    let pageIDs = try PageTreeView(graph: graph).pages
    guard let field = try FormInventory.fields(in: graph, pageIDs: pageIDs)
      .first(where: { $0.name == name })
    else { throw PDFError(.malformed, "field missing") }
    return field
  }

  private func appearanceContent(_ name: String, in graph: PDFGraph) throws -> String {
    let field = try field(name, in: graph)
    guard let widgetID = field.widgets.first?.objectID,
      case .dictionary(let dictionary)? = graph.objects[widgetID],
      case .dictionary(let appearance)? = dictionary[PDFName("AP")],
      case .reference(let streamID)? = appearance[PDFName("N")],
      case .stream(let stream)? = graph.objects[streamID],
      let decoded = try? PDFFilters.decoded(stream)
    else { throw PDFError(.malformed, "appearance missing") }
    return String(decoding: decoded, as: UTF8.self)
  }

  @Test func embeddedFontIsWrittenAsTaggedType0SubsetInFieldResources() throws {
    var (graph, _) = try textField()
    let source = FormEmbeddedFontSource(
      program: try shapingProgram(), familyName: "DejaVu Turkish", faceName: "DejaVu Turkish")
    let value = FormRichTextValue.plain(
      "Işıl", style: FormRichTextStyle(fontSize: 14, font: .embedded(source)))
    graph = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Name", value: value)]), to: graph)
    let fieldDictionary = try #require(
      try field("Name", in: graph).fieldID.flatMap { graph.objects[$0] })
    guard case .dictionary(let dictionary) = fieldDictionary,
      case .dictionary(let resources)? = dictionary[PDFName("DR")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else {
      Issue.record("field /DR fonts missing")
      return
    }
    // The field /DR carries the flattened inherited Standard face plus the
    // newly embedded Type0 program.
    #expect(fonts.count == 2)
    var type0Font: [PDFName: PDFValue]?
    var type0ID: PDFObjectID?
    for value in fonts.values {
      guard case .reference(let fontID) = value,
        case .dictionary(let font)? = graph.objects[fontID],
        font[PDFName("Subtype")] == .name(PDFName("Type0"))
      else { continue }
      type0Font = font
      type0ID = fontID
    }
    guard let font = type0Font, let fontID = type0ID else {
      Issue.record("embedded Type0 font missing")
      return
    }
    #expect(font[PDFName("Subtype")] == .name(PDFName("Type0")))
    #expect(font[PDFName("Encoding")] == .name(PDFName("Identity-H")))
    guard case .name(let baseFont)? = font[PDFName("BaseFont")] else {
      Issue.record("BaseFont missing")
      return
    }
    #expect(String(decoding: baseFont.bytes, as: UTF8.self).contains("+DejaVu"))
    guard case .reference(let cmapID)? = font[PDFName("ToUnicode")],
      case .stream(let cmap)? = graph.objects[cmapID],
      let cmapBytes = try? PDFFilters.decoded(cmap)
    else {
      Issue.record("ToUnicode missing")
      return
    }
    let cmapText = String(decoding: cmapBytes, as: UTF8.self)
    #expect(cmapText.contains("<0049>"))  // I
    #expect(cmapText.contains("<015F>"))  // ş
    #expect(cmapText.contains("<0131>"))  // ı
    let content = try appearanceContent("Name", in: graph)
    #expect(content.contains("<"))
    #expect(content.contains("Tf"))
    let storedValue = try field("Name", in: graph).stringValue
    #expect(storedValue == "Işıl")
  }

  @Test func embeddedFontEnablesCharactersStandardFacesCannotEncode() throws {
    let (graph, _) = try textField()
    #expect(StandardTextFont.canEncode("ΑΒΓ") == false)
    // The Standard-14 path refuses Greek instead of substituting.
    #expect(throws: PDFError.self) {
      var value = FormRichTextValue.plain("ΑΒΓ")
      value = try value.applying(
        style: FormRichTextStyle(font: .standard(.helvetica)), to: NSRange(location: 0, length: 3))
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormRichTextCommand(fieldName: "Name", value: value)]), to: graph)
    }
    var value = FormRichTextValue.plain("ΑΒΓ", style: FormRichTextStyle(fontSize: 16))
    value.baseStyle.font = .embedded(
      FormEmbeddedFontSource(program: try multilingualProgram(), familyName: "Multilingual"))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Name", value: value)]), to: graph)
    #expect(try field("Name", in: edited).stringValue == "ΑΒΓ")
    let content = try appearanceContent("Name", in: edited)
    #expect(content.contains("<0000") || content.contains("<00"))
    // The value survives a save/reopen cycle.
    let reopened = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(
      try field("Name", in: reopened.graph).stringValue == "ΑΒΓ")
  }

  @Test func missingGlyphInEmbeddedProgramIsRefused() throws {
    let (graph, _) = try textField()
    var value = FormRichTextValue.plain("IşılZ")
    value.baseStyle.font = .embedded(
      FormEmbeddedFontSource(program: try shapingProgram(), familyName: "Turkish"))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormRichTextCommand(fieldName: "Name", value: value)]), to: graph)
    }
  }

  @Test func cffProgramsAreRefusedWithAnActionableProfileMessage() throws {
    guard let cff = Data(base64Encoded: FontFixtureData.cffProgramBase64) else {
      Issue.record("CFF fixture missing")
      return
    }
    var graph = try textField().graph
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    do {
      _ = try FormAppearanceFonts.register(
        source: FormEmbeddedFontSource(program: cff, familyName: "CFF"), covering: "Hi",
        in: &graph, ownerFieldID: nil)
      Issue.record("Expected a CFF refusal")
    } catch let error as PDFError {
      #expect(error.message.contains("TrueType"))
    }
    _ = nextNumber
  }

  @Test func registeringTheSameProgramTwiceReusesTheEmbeddedSubset() throws {
    var (graph, _) = try textField()
    let source = FormEmbeddedFontSource(
      program: try shapingProgram(), familyName: "Turkish", faceName: "Turkish")
    let value = FormRichTextValue.plain("Işıl", style: FormRichTextStyle(font: .embedded(source)))
    let first = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Name", value: value)]), to: graph)
    let second = try PDFEditingEngine.commit(
      PDFTransaction([SetFormRichTextCommand(fieldName: "Name", value: value)]), to: first)
    #expect(second.objects.count == first.objects.count)
    // The registered Type0 font decodes its appearance codes back to the text
    // through the independent composite-font reader.
    let fieldInfo = try field("Name", in: second)
    guard let fieldID = fieldInfo.fieldID, case .dictionary(let dictionary)? = second.objects[fieldID],
      case .dictionary(let resources)? = dictionary[PDFName("DR")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      let widgetID = fieldInfo.widgets.first?.objectID,
      let type0 = fonts.values.first(where: { value in
        guard case .reference(let fontID) = value,
          case .dictionary(let font)? = second.objects[fontID]
        else { return false }
        return font[PDFName("Subtype")] == .name(PDFName("Type0"))
      }),
      case .reference(let fontID) = type0,
      case .dictionary(let fontDictionary)? = second.objects[fontID],
      let composite = CompositeFont.parse(fontDictionary, in: second, objectID: fontID),
      case .dictionary(let widget)? = second.objects[widgetID],
      case .dictionary(let appearance)? = widget[PDFName("AP")],
      case .reference(let streamID)? = appearance[PDFName("N")],
      case .stream(let stream)? = second.objects[streamID],
      let content = try? PDFFilters.decoded(stream)
    else {
      Issue.record("embedded font could not be read back")
      return
    }
    let codes = extractHexCodes(in: String(decoding: content, as: UTF8.self))
    // Four Identity-H characters, two bytes per CID.
    #expect(codes.count == 8)
    let decoded = try composite.decode(codes)
    #expect(decoded.text == "Işıl")
    graph = second
    #expect(try field("Name", in: graph).stringValue == "Işıl")
  }


  /// When SPDF_FRM05_ARTIFACT_DIR is set, writes a form PDF with a rich styled
  /// value and an embedded-font value for independent-reader qualification
  /// (qpdf/mutool checks run outside the test suite). Otherwise this test only
  /// verifies the writer round-trip.
  @Test func independentReaderArtifactWhenRequested() throws {
    var (graph, pageID) = try textField()
    guard let dir = ProcessInfo.processInfo.environment["SPDF_FRM05_ARTIFACT_DIR"] else {
      let artifact = try PDFWriter.write(graph)
      let reopened = try PDFParser.parse(artifact)
      #expect(reopened.pageIDs.count == 1)
      return
    }
    var rich = FormRichTextValue.plain(
      "Total 42", style: FormRichTextStyle(fontSize: 16, color: [0, 0.1, 0.4]))
    rich.runs = [
      FormRichTextRun(
        location: 0, length: 5,
        style: FormRichTextStyle(bold: true, fontSize: 18, color: [0.8, 0, 0]))
    ]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 520, 372, 550], name: "RichValue"),
        SetFormRichTextCommand(fieldName: "RichValue", value: rich),
      ]), to: graph)
    let embedded = FormRichTextValue.plain(
      "Işıl", style: FormRichTextStyle(
        fontSize: 16,
        font: .embedded(
          FormEmbeddedFontSource(
            program: try shapingProgram(), familyName: "DejaVu Turkish"))))
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 470, 372, 500], name: "EmbeddedValue"),
        SetFormRichTextCommand(fieldName: "EmbeddedValue", value: embedded),
      ]), to: graph)
    let data = try PDFWriter.write(graph)
    let directory = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent("frm05-rich-form.pdf"))
    let manifest: [String: Any] = [
      "richField": ["name": "RichValue", "value": "Total 42", "baseSize": 16],
      "embeddedField": [
        "name": "EmbeddedValue", "value": "Işıl", "family": "DejaVu Turkish",
      ],
      "expectations": [
        "qpdf --check reports no syntax or stream errors",
        "the widget appearances paint the stored values after a full save/reopen cycle",
        "the embedded field uses a tagged Type0 Identity-H subset with a ToUnicode map",
      ],
    ]
    let json = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: directory.appendingPathComponent("frm05-artifact.json"))
    let reopened = try PDFParser.parse(data)
    #expect(reopened.pageIDs.count == 1)
    #expect(
      try field("RichValue", in: reopened.graph).stringValue == "Total 42")
    #expect(try field("EmbeddedValue", in: reopened.graph).stringValue == "Işıl")
  }

  private func extractHexCodes(in content: String) -> [UInt8] {
    guard let open = content.firstIndex(of: "<"),
      let close = content[open...].firstIndex(of: ">")
    else { return [] }
    let hex = content[content.index(after: open)..<close]
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let end = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
      if let value = UInt8(String(hex[index..<end]).prefix(2), radix: 16),
        let second = UInt8(String(hex[index..<end]).suffix(2), radix: 16)
      {
        bytes.append(value)
        bytes.append(second)
      }
      index = end
    }
    return bytes
  }
}
