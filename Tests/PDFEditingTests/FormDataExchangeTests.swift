import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-03: FDF/XFDF export and import preserve text, choice and button values
/// and report fields the document cannot accept.
@Suite("Form data exchange")
struct FormDataExchangeTests {
  private func filledForm() throws -> (PDFGraph, [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "name", text: "Ayse Izci"),
        SetFormButtonStateCommand(fieldName: "agree", state: PDFName("Yes")),
      ]), to: parsed.graph)
    return (filled, parsed.pageIDs)
  }

  @Test func xfdfRoundTripPreservesUnicodeAndButtonState() throws {
    let (filled, pageIDs) = try filledForm()
    let values = try FormValues.values(in: filled, pageIDs: pageIDs)
    let data = FormDataExchange.export(values, format: .xfdf)
    let raw = try FormDataExchange.parse(data, format: .xfdf)
    #expect(raw.contains { $0.name == "name" && $0.value == "Ayse Izci" })
    #expect(raw.contains { $0.name == "agree" && $0.value == "Yes" })

    let (commands, skipped, ambiguous) = try FormDataExchange.commands(
      forRawValues: raw, in: filled, pageIDs: pageIDs)
    #expect(skipped == ["locked"])
    #expect(ambiguous.isEmpty)
    let imported = try PDFEditingEngine.commit(PDFTransaction(commands), to: filled)
    let fields = try FormInventory.fields(in: imported, pageIDs: pageIDs)
    #expect(fields.first { $0.name == "name" }?.stringValue == "Ayse Izci")
    #expect(fields.first { $0.name == "agree" }?.buttonState == PDFName("Yes"))
  }

  @Test func fdfRoundTripPreservesUnicodeAndButtonState() throws {
    let (filled, pageIDs) = try filledForm()
    let values = try FormValues.values(in: filled, pageIDs: pageIDs)
    let data = FormDataExchange.export(values, format: .fdf)
    let raw = try FormDataExchange.parse(data, format: .fdf)
    #expect(raw.contains { $0.name == "name" && $0.value == "Ayse Izci" })
    #expect(raw.contains { $0.name == "agree" && $0.value == "Yes" })

    let (commands, skipped, _) = try FormDataExchange.commands(
      forRawValues: raw, in: filled, pageIDs: pageIDs)
    #expect(skipped == ["locked"])
    let imported = try PDFEditingEngine.commit(PDFTransaction(commands), to: filled)
    let fields = try FormInventory.fields(in: imported, pageIDs: pageIDs)
    #expect(fields.first { $0.name == "name" }?.stringValue == "Ayse Izci")
    #expect(fields.first { $0.name == "agree" }?.buttonState == PDFName("Yes"))
  }

  @Test func exchangeFormatsCarryUnicodeNamesAndValues() throws {
    let values = [
      FormFieldValue(name: "İsim", kind: "text", value: "Ayşe İzci"),
      FormFieldValue(name: "onay", kind: "button", buttonState: "Evet"),
    ]
    for format in FormDataExchange.Format.allCases {
      let data = FormDataExchange.export(values, format: format)
      let parsed = try FormDataExchange.parse(data, format: format)
      #expect(parsed.contains { $0.name == "İsim" && $0.value == "Ayşe İzci" })
      #expect(parsed.contains { $0.name == "onay" && $0.value == "Evet" })
    }
  }

  @Test func independentlyWrittenXFDFImports() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <xfdf xmlns="http://ns.adobe.com/xfdf/">
      <fields>
      <field name="name"><value>Independent XFDF</value></field>
      <field name="agree"><value>Yes</value></field>
      </fields>
      </xfdf>
      """
    let raw = try FormDataExchange.parse(Data(xml.utf8), format: .xfdf)
    let (commands, skipped, _) = try FormDataExchange.commands(
      forRawValues: raw, in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(skipped.isEmpty)
    let imported = try PDFEditingEngine.commit(PDFTransaction(commands), to: parsed.graph)
    let fields = try FormInventory.fields(in: imported, pageIDs: parsed.pageIDs)
    #expect(fields.first { $0.name == "name" }?.stringValue == "Independent XFDF")
    #expect(fields.first { $0.name == "agree" }?.buttonState == PDFName("Yes"))
  }

  @Test func independentlyWrittenFDFImports() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let fdf = """
      %FDF-1.2
      1 0 obj
      << /FDF << /Fields [
      << /T (name) /V (Independent FDF) >>
      << /T (agree) /V /Yes >>
      ] >> >>
      endobj
      trailer
      << /Root 1 0 R >>
      %%EOF

      """
    let raw = try FormDataExchange.parse(Data(fdf.utf8), format: .fdf)
    let (commands, skipped, _) = try FormDataExchange.commands(
      forRawValues: raw, in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(skipped.isEmpty)
    let imported = try PDFEditingEngine.commit(PDFTransaction(commands), to: parsed.graph)
    let fields = try FormInventory.fields(in: imported, pageIDs: parsed.pageIDs)
    #expect(fields.first { $0.name == "name" }?.stringValue == "Independent FDF")
    #expect(fields.first { $0.name == "agree" }?.buttonState == PDFName("Yes"))
  }

  @Test func multiSelectChoiceExchangeKeepsAllValues() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    guard case .dictionary(var field)? = parsed.graph.objects[PDFObjectID(210)] else {
      Issue.record("team field missing")
      return
    }
    field[PDFName("Ff")] = .integer(2_097_152)
    var graph = parsed.graph
    graph.objects[PDFObjectID(210)] = .dictionary(field)
    let selected = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormChoiceCommand(fieldName: "team", exportValues: ["red", "blue"])
      ]), to: graph)
    let values = try FormValues.values(in: selected, pageIDs: parsed.pageIDs)
    #expect(values.first { $0.name == "team" }?.selectedValues == ["red", "blue"])

    for format in FormDataExchange.Format.allCases {
      let data = FormDataExchange.export(values, format: format)
      let raw = try FormDataExchange.parse(data, format: format)
      let (commands, skipped, _) = try FormDataExchange.commands(
        forRawValues: raw, in: selected, pageIDs: parsed.pageIDs)
      #expect(skipped == ["locked"])
      let imported = try PDFEditingEngine.commit(PDFTransaction(commands), to: selected)
      let team = try #require(
        try FormInventory.fields(in: imported, pageIDs: parsed.pageIDs)
          .first { $0.name == "team" })
      #expect(team.selectedIndexes == [0, 1])
    }
  }

  @Test func nestedXFDFUsesFullyQualifiedNames() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <xfdf xmlns="http://ns.adobe.com/xfdf/">
      <fields>
      <field name="parent">
      <field name="child"><value>Nested</value></field>
      </field>
      </fields>
      </xfdf>
      """
    let raw = try FormDataExchange.parse(Data(xml.utf8), format: .xfdf)
    #expect(raw.contains { $0.name == "parent.child" && $0.value == "Nested" })
  }

  @Test func unknownFieldsAreReportedNotGuessed() throws {
    let (filled, pageIDs) = try filledForm()
    let (commands, skipped, _) = try FormDataExchange.commands(
      forRawValues: [("missing", "value")], in: filled, pageIDs: pageIDs)
    #expect(commands.isEmpty)
    #expect(skipped == ["missing"])
  }

  @Test func malformedExchangeFilesAreRefused() throws {
    #expect(throws: PDFError.self) {
      _ = try FormDataExchange.parse(Data("<not-xfdf/>".utf8), format: .xfdf)
    }
    #expect(throws: PDFError.self) {
      _ = try FormDataExchange.parse(Data("%FDF-1.2\n".utf8), format: .fdf)
    }
  }
}
