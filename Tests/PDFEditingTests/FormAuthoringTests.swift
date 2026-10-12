import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P25-001–P25-006/P25-008/P25-009/P25-011/P25-020/P25-021/P25-029: field
/// authoring, hierarchical naming, flags, rename, deletion, round-trips, and
/// the many-field measurement.
@Suite("Form authoring")
struct FormAuthoringTests {
  private func page() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    return (parsed.graph, parsed.pageIDs[0])
  }

  private func inventory(_ graph: PDFGraph, _ pageIDs: [PDFObjectID]) throws -> [FormField] {
    try FormInventory.fields(in: graph, pageIDs: pageIDs)
  }

  @Test func textFieldAuthoringWithFlagsAndDefaults() throws {
    let (graph, pageID) = try page()
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 600, 272, 624], name: "FullName", required: true,
          defaultValue: "Jane Doe", fontSize: 11)
      ]), to: graph)
    let fields = try inventory(edited, [pageID])
    #expect(fields.count == 1)
    let field = try #require(fields.first)
    #expect(field.name == "FullName")
    #expect(field.kind == .text)
    #expect(field.isRequired)
    #expect(!field.isReadOnly)
    #expect(field.defaultStringValue == "Jane Doe")
    #expect(field.stringValue == "Jane Doe")
    #expect(field.widgets.count == 1)
    #expect(field.widgets[0].rect == [72, 600, 272, 624])
    // The page carries the widget annotation.
    guard case .dictionary(let page)? = edited.objects[pageID],
      case .array(let annotations)? = page[PDFName("Annots")]
    else {
      Issue.record("Page annotations missing")
      return
    }
    #expect(annotations.count == 1)
    // The AcroForm has a default resource and no appearance regeneration.
    guard case .reference(let catalogID)? = edited.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = edited.objects[catalogID],
      case .dictionary(let acroForm)? = catalog[PDFName("AcroForm")]
    else {
      Issue.record("AcroForm missing")
      return
    }
    #expect(acroForm[PDFName("NeedAppearances")] == .boolean(false))
    guard case .dictionary(let resources)? = acroForm[PDFName("DR")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else {
      Issue.record("Default resources missing")
      return
    }
    #expect(fonts[PDFName("Helv")] != nil)
  }

  @Test func checkboxAndRadioGroupAuthoring() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddCheckboxCommand(
          pageID: pageID, rect: [72, 560, 90, 578], name: "Agree", checkedByDefault: true)
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRadioGroupCommand(
          pageID: pageID, rects: [[72, 520, 90, 538], [100, 520, 118, 538], [128, 520, 146, 538]],
          name: "Plan", exportValues: ["Basic", "Pro", "Team"], selectedIndex: 1)
      ]), to: edited)
    let fields = try inventory(edited, [pageID])
    #expect(fields.count == 2)
    let agree = try #require(fields.first { $0.name == "Agree" })
    #expect(agree.kind == .button)
    #expect(agree.isChecked)
    #expect(Set(agree.widgets[0].appearanceStates) == [PDFName("Off"), PDFName("Yes")])
    let plan = try #require(fields.first { $0.name == "Plan" })
    #expect(plan.isRadio)
    #expect(plan.widgets.count == 3)
    #expect(plan.buttonState == PDFName("Pro"))
    #expect(plan.widgets[1].appearanceState == PDFName("Pro"))
    #expect(plan.widgets[0].appearanceState == PDFName("Off"))
    // Selecting another widget through the existing fill command works.
    let switched = try PDFEditingEngine.commit(
      PDFTransaction([SetFormButtonStateCommand(fieldName: "Plan", state: PDFName("Team"))]),
      to: edited)
    let switchedPlan = try #require(try inventory(switched, [pageID]).first { $0.name == "Plan" })
    #expect(switchedPlan.buttonState == PDFName("Team"))
    #expect(switchedPlan.widgets[2].appearanceState == PDFName("Team"))
  }

  @Test func choicePushButtonAndSignatureAuthoring() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddChoiceFieldCommand(
          pageID: pageID, rect: [72, 480, 220, 504], name: "Department",
          options: [
            AuthoredChoiceOption(exportValue: "eng", displayValue: "Engineering"),
            AuthoredChoiceOption(exportValue: "sales", displayValue: "Sales"),
          ], combo: true, defaultExportValue: "sales")
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPushButtonCommand(
          pageID: pageID, rect: [72, 440, 180, 464], name: "Docs", caption: "Open Docs",
          uri: "https://example.invalid/docs")
      ]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSignatureFieldCommand(pageID: pageID, rect: [72, 400, 280, 432], name: "Approval")
      ]), to: edited)
    let fields = try inventory(edited, [pageID])
    #expect(fields.count == 3)
    let department = try #require(fields.first { $0.name == "Department" })
    #expect(department.kind == .choice)
    #expect(department.isCombo)
    #expect(department.options.map(\.export) == ["eng", "sales"])
    #expect(department.options.map(\.display) == ["Engineering", "Sales"])
    #expect(department.selectedOption?.export == "sales")
    let docs = try #require(fields.first { $0.name == "Docs" })
    #expect(docs.isPushButton)
    guard let docsID = docs.fieldID, case .dictionary(let docsField)? = edited.objects[docsID],
      case .dictionary(let action)? = docsField[PDFName("A")]
    else {
      Issue.record("Push button action missing")
      return
    }
    #expect(action[PDFName("S")] == .name(PDFName("URI")))
    let approval = try #require(fields.first { $0.name == "Approval" })
    #expect(approval.kind == .signature)
    guard let approvalID = approval.fieldID,
      case .dictionary(let approvalField)? = edited.objects[approvalID]
    else {
      Issue.record("Signature field missing")
      return
    }
    #expect(approvalField[PDFName("V")] == nil)

    // Unsafe button actions are refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          AddPushButtonCommand(
            pageID: pageID, rect: [72, 360, 180, 384], name: "Bad", caption: "Bad",
            uri: "javascript:alert(1)")
        ]), to: edited)
    }
  }

  @Test func hierarchicalNamesAndUniqueness() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Details.Name")
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "Details.Name")
      ]), to: edited)
    let fields = try inventory(edited, [pageID])
    #expect(fields.map(\.name).sorted() == ["Details.Name", "Details.Name2"])
    // The shared parent exists once.
    guard case .reference(let catalogID)? = edited.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = edited.objects[catalogID],
      case .dictionary(let acroForm)? = catalog[PDFName("AcroForm")],
      case .array(let roots)? = acroForm[PDFName("Fields")]
    else {
      Issue.record("AcroForm missing")
      return
    }
    #expect(roots.count == 1)
    guard case .reference(let parentID) = roots[0],
      case .dictionary(let parent)? = edited.objects[parentID],
      case .array(let kids)? = parent[PDFName("Kids")]
    else {
      Issue.record("Parent field missing")
      return
    }
    #expect(kids.count == 2)
  }

  @Test func renameUpdatesNamesAndRelationships() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Details.Name"),
        AddRadioGroupCommand(
          pageID: pageID, rects: [[72, 520, 90, 538], [100, 520, 118, 538]], name: "Plan",
          exportValues: ["A", "B"]),
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([RenameFormFieldCommand(fieldName: "Details.Name", newName: "Profile.Name")]),
      to: edited)
    var fields = try inventory(edited, [pageID])
    #expect(fields.map(\.name).sorted() == ["Plan", "Profile.Name"])
    #expect(fields.first { $0.name == "Profile.Name" }?.kind == .text)
    // Renaming to an existing name is refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RenameFormFieldCommand(fieldName: "Profile.Name", newName: "Plan")]),
        to: edited)
    }
    // Flags can be toggled afterwards.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormFieldFlagsCommand(fieldName: "Profile.Name", required: true, readOnly: true)
      ]), to: edited)
    fields = try inventory(edited, [pageID])
    let renamed = try #require(fields.first { $0.name == "Profile.Name" })
    #expect(renamed.isRequired && renamed.isReadOnly)
  }

  @Test func deletionCleansTreeAnnotationsAndObjects() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "Keep"),
        AddRadioGroupCommand(
          pageID: pageID, rects: [[72, 520, 90, 538], [100, 520, 118, 538]], name: "Remove",
          exportValues: ["A", "B"], selectedIndex: 0),
      ]), to: graph)
    let before = edited.objects.count
    edited = try PDFEditingEngine.commit(
      PDFTransaction([RemoveFormFieldCommand(fieldName: "Remove")]), to: edited)
    let fields = try inventory(edited, [pageID])
    #expect(fields.map(\.name) == ["Keep"])
    // The page keeps only the remaining widget.
    guard case .dictionary(let page)? = edited.objects[pageID],
      case .array(let annotations)? = page[PDFName("Annots")]
    else {
      Issue.record("Page annotations missing")
      return
    }
    #expect(annotations.count == 1)
    // Radio field + two widgets + their appearances were removed.
    #expect(edited.objects.count < before)
    // The result survives a full write/reparse.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    let reparsedFields = try inventory(reparsed.graph, reparsed.pageIDs)
    #expect(reparsedFields.map(\.name) == ["Keep"])
  }

  @Test func authoredFieldsFillResetAndRoundTrip() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 600, 272, 624], name: "City", defaultValue: "Berlin"),
        AddCheckboxCommand(pageID: pageID, rect: [72, 560, 90, 578], name: "Subscribe"),
      ]), to: graph)
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    var fields = try inventory(reparsed.graph, reparsed.pageIDs)
    #expect(fields.count == 2)
    #expect(fields.first { $0.name == "City" }?.stringValue == "Berlin")
    // Fill and reset work on authored fields through the canonical commands.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "City", text: "Hamburg"),
        SetFormButtonStateCommand(fieldName: "Subscribe", state: PDFName("Yes")),
      ]), to: reparsed.graph)
    fields = try inventory(edited, reparsed.pageIDs)
    #expect(fields.first { $0.name == "City" }?.stringValue == "Hamburg")
    #expect(fields.first { $0.name == "Subscribe" }?.isChecked == true)
    let reset = try PDFEditingEngine.commit(
      PDFTransaction([ResetFormCommand()]), to: edited)
    fields = try inventory(reset, reparsed.pageIDs)
    #expect(fields.first { $0.name == "City" }?.stringValue == "Berlin")
    #expect(fields.first { $0.name == "Subscribe" }?.isChecked == false)
  }

  @Test func authoringManyFieldsStaysBounded() throws {
    let (graph, pageID) = try page()
    var edited = graph
    let start = ContinuousClock.now
    for index in 0..<200 {
      let y = 700.0 - Double(index % 25) * 26
      let x = 72.0 + Double(index / 25) * 120
      edited = try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextFieldCommand(
            pageID: pageID, rect: [x, y, x + 110, y + 20], name: "Field\(index)")
        ]), to: edited)
    }
    let duration = ContinuousClock.now - start
    let milliseconds = duration.components.seconds * 1000
      + duration.components.attoseconds / 1_000_000_000_000_000
    let fields = try inventory(edited, [pageID])
    print("[P25-029] authored \(fields.count) fields in \(milliseconds) ms")
    #expect(fields.count == 200)
    #expect(duration < .seconds(5))
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(try inventory(reparsed.graph, reparsed.pageIDs).count == 200)
  }
}
