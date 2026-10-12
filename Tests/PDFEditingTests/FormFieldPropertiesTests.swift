import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P25-007/P25-012/P25-013/P25-014/P25-015/P25-017/P25-027: the field
/// properties read model, styles, validation, declarative formats and
/// calculations, script preservation, and appearance survival.
@Suite("Form field properties")
struct FormFieldPropertiesTests {
  private func authored() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 640, 272, 664], name: "Amount", defaultValue: nil),
        AddCheckboxCommand(pageID: pageID, rect: [72, 600, 90, 618], name: "Flag"),
      ]), to: graph)
    return (graph, pageID)
  }

  private func appearanceContent(_ graph: PDFGraph, fieldName: String) throws -> String {
    guard let fieldID = FormAuthoringSupport.findField(named: fieldName, in: graph),
      case .dictionary(let field)? = graph.objects[fieldID],
      case .dictionary(let ap)? = field[PDFName("AP")]
    else { return "" }
    var streamID: PDFObjectID?
    if case .reference(let id)? = ap[PDFName("N")] { streamID = id }
    if case .dictionary(let states)? = ap[PDFName("N")] {
      if case .reference(let id)? = states[PDFName("Off")] { streamID = id }
    }
    guard let streamID, case .stream(let stream)? = graph.objects[streamID] else { return "" }
    return String(decoding: try PDFFilters.decoded(stream), as: UTF8.self)
  }

  @Test func styleChangesUpdateDAAlignmentAndAppearances() throws {
    let (graph, pageID) = try authored()
    let styled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldStyleCommand(
          fieldName: "Amount", fontSize: 14, textColor: [1, 0, 0], alignment: 2,
          borderColor: [0, 0, 1], backgroundColor: [1, 1, 0.8], borderWidth: 2)
      ]), to: graph)
    let properties = try #require(
      FormFieldPropertiesReader.properties(forFieldNamed: "Amount", in: styled))
    #expect(properties.fontSize == 14)
    #expect(properties.textColor == [1, 0, 0])
    #expect(properties.alignment == 2)
    #expect(properties.borderColor == [0, 0, 1])
    #expect(properties.backgroundColor == [1, 1, 0.8])
    #expect(properties.borderWidth == 2)
    // The appearance stream was regenerated with the new font size.
    let appearance = try appearanceContent(styled, fieldName: "Amount")
    // The appearance fits the 24 pt box, so the size is clamped to 16.8 at
    // most; 14 pt is honored exactly.
    #expect(appearance.contains("14 Tf"))
    #expect(appearance.contains("1 0 0 rg"))

    // Buttons rebuild their state appearances from the new /MK.
    let buttonStyled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldStyleCommand(fieldName: "Flag", borderColor: [0, 0.5, 0], borderWidth: 2)
      ]), to: styled)
    let buttonAppearance = try appearanceContent(buttonStyled, fieldName: "Flag")
    #expect(buttonAppearance.contains("0.5"))
    #expect(try FormInventory.fields(in: buttonStyled, pageIDs: [pageID]).count == 2)

    // Out-of-range styles are refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormFieldStyleCommand(fieldName: "Amount", alignment: 5)]),
        to: styled)
    }
  }

  @Test func validationLimitsAreEnforced() throws {
    let (graph, _) = try authored()
    let limited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormFieldValidationCommand(fieldName: "Amount", maxLength: 5)]), to: graph)
    #expect(
      FormFieldPropertiesReader.properties(forFieldNamed: "Amount", in: limited)?.maxLength == 5)
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Amount", text: "12345")]), to: limited)
    #expect(
      try FormInventory.fields(in: filled, pageIDs: try PDFPageTree.pageIDs(in: filled))
        .first { $0.name == "Amount" }?.stringValue == "12345")
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormTextCommand(fieldName: "Amount", text: "123456")]), to: limited)
    }
    // Removing the limit allows longer text again.
    let unlimited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormFieldValidationCommand(fieldName: "Amount", maxLength: nil)]),
      to: limited)
    #expect(throws: Never.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormTextCommand(fieldName: "Amount", text: "123456")]), to: unlimited)
    }
    // Length limits apply to text fields only.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormFieldValidationCommand(fieldName: "Flag", maxLength: 3)]),
        to: graph)
    }
  }

  @Test func declarativeFormatsApplyToFilledValues() throws {
    let (graph, _) = try authored()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldFormatCommand(
          fieldName: "Amount",
          format: .number(decimals: 2, prefix: "$", suffix: nil))
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Amount", text: "1234.5")]), to: edited)
    var fields = try FormInventory.fields(in: edited, pageIDs: try PDFPageTree.pageIDs(in: edited))
    #expect(fields.first { $0.name == "Amount" }?.stringValue == "$1234.50")
    // Values that do not match the rule are refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormTextCommand(fieldName: "Amount", text: "not a number")]),
        to: edited)
    }
    // Date formats work through the same declarative rule.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldFormatCommand(fieldName: "Amount", format: .date(style: .long)),
        SetFormTextCommand(fieldName: "Amount", text: "2026-10-11"),
      ]), to: edited)
    fields = try FormInventory.fields(in: edited, pageIDs: try PDFPageTree.pageIDs(in: edited))
    #expect(fields.first { $0.name == "Amount" }?.stringValue == "October 11, 2026")
    #expect(
      FormFieldPropertiesReader.properties(forFieldNamed: "Amount", in: edited)?.format
        == .date(style: .long))
  }

  @Test func calculationsEvaluateDeclaratively() throws {
    let (graph, pageID) = try authored()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 172, 584], name: "Price"),
        AddTextFieldCommand(pageID: pageID, rect: [180, 560, 260, 584], name: "Qty"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 520, 272, 544], name: "Total"),
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldFormatCommand(
          fieldName: "Total", format: .number(decimals: 2, prefix: "$", suffix: nil)),
        SetFormFieldCalculationCommand(
          fieldName: "Total", calculation: .sum(fields: ["Price", "Qty"])),
      ]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "Price", text: "10.5"),
        SetFormTextCommand(fieldName: "Qty", text: "2"),
      ]), to: edited)
    let recalculated = try PDFEditingEngine.commit(
      PDFTransaction([RecalculateFormCommand()]), to: edited)
    let fields = try FormInventory.fields(
      in: recalculated, pageIDs: try PDFPageTree.pageIDs(in: recalculated))
    #expect(fields.first { $0.name == "Total" }?.stringValue == "$12.50")
    #expect(
      FormFieldPropertiesReader.properties(forFieldNamed: "Total", in: recalculated)?.calculation
        == .sum(fields: ["Price", "Qty"]))
    // Missing references and self-references are refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormFieldCalculationCommand(fieldName: "Total", calculation: .sum(fields: ["Nope"]))
        ]), to: edited)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetFormFieldCalculationCommand(fieldName: "Total", calculation: .sum(fields: ["Total"]))
        ]), to: edited)
    }
  }

  @Test func existingScriptsArePreservedWithoutExecution() throws {
    let (graph, pageID) = try authored()
    // Attach a document JavaScript entry to the field (never executed by us).
    guard let fieldID = FormAuthoringSupport.findField(named: "Amount", in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    else {
      Issue.record("Field missing")
      return
    }
    field[PDFName("AA")] = .dictionary([
      PDFName("F"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert('format');".utf8)),
      ])
    ])
    var scripted = graph
    scripted.objects[fieldID] = .dictionary(field)
    let before = scripted.objects[fieldID]

    // Style, validation, format, fill, and rename must not touch /AA.
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldStyleCommand(fieldName: "Amount", fontSize: 14, alignment: 1),
        SetFormFieldValidationCommand(fieldName: "Amount", maxLength: 20),
        SetFormFieldFormatCommand(
          fieldName: "Amount", format: .number(decimals: 1, prefix: nil, suffix: nil)),
      ]), to: scripted)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Amount", text: "42")]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([RenameFormFieldCommand(fieldName: "Amount", newName: "Price")]), to: edited)
    guard let renamedID = FormAuthoringSupport.findField(named: "Price", in: edited),
      case .dictionary(let renamed)? = edited.objects[renamedID],
      case .dictionary(let beforeField)? = before
    else {
      Issue.record("Renamed field missing")
      return
    }
    #expect(renamed[PDFName("AA")] == beforeField[PDFName("AA")])
    #expect(renamed[PDFName("AA")] != nil)
    _ = pageID
  }

  @Test func appearancesSurviveStyleChangesAndSiblingEdits() throws {
    let (graph, _) = try authored()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldStyleCommand(fieldName: "Amount", fontSize: 16, alignment: 1)
      ]), to: graph)
    let appearanceBefore = try appearanceContent(edited, fieldName: "Amount")
    #expect(appearanceBefore.contains("16 Tf"))
    // Renaming and deleting a sibling leaves the appearance untouched.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([RenameFormFieldCommand(fieldName: "Flag", newName: "Subscribe")]),
      to: edited)
    #expect(try appearanceContent(edited, fieldName: "Amount") == appearanceBefore)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([RemoveFormFieldCommand(fieldName: "Subscribe")]), to: edited)
    #expect(try appearanceContent(edited, fieldName: "Amount") == appearanceBefore)
    // The styled field survives a full write/reparse.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(
      FormFieldPropertiesReader.properties(forFieldNamed: "Amount", in: reparsed.graph)?.fontSize
        == 16)
    #expect(try appearanceContent(reparsed.graph, fieldName: "Amount").contains("16 Tf"))
  }
}
