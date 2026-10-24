import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P24-001–P24-020 evidence: AcroForm inventory with inherited attributes,
/// widget associations, orphan detection, text filling, and button states.
@Suite("Form filling")
struct FormTests {
  @Test func inventoryParsesTheFieldTree() throws {
    let (graph, pageIDs) = try formFixture()
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    #expect(
      fields.map(\.name) == [
        "name", "notes", "agree", "color", "submit", "sig", "locked", "extra",
        "department", "team",
      ])
    #expect(
      fields.map(\.kind) == [
        .text, .text, .button, .button, .button, .signature, .text, .button,
        .choice, .choice,
      ])

    let name = fields[0]
    #expect(name.fieldID == PDFObjectID(110))
    #expect(name.widgets.count == 1)
    #expect(name.widgets[0].pageIndex == 0)
    #expect(name.widgets[0].rect == [100, 600, 300, 620])
    #expect(name.stringValue == "")

    let notes = fields[1]
    #expect(notes.isMultiline)
    #expect(notes.isRequired)
    #expect(notes.defaultStringValue == "default notes")
    #expect(notes.widgets[0].objectID == PDFObjectID(121))

    let agree = fields[2]
    #expect(!agree.isRadio)
    #expect(agree.widgets[0].appearanceStates == [PDFName("Off"), PDFName("Yes")])
    #expect(agree.buttonState == PDFName("Off"))
    #expect(!agree.isChecked)

    let color = fields[3]
    #expect(color.isRadio)
    #expect(color.widgets.count == 2)
    #expect(color.widgets.map(\.pageIndex) == [0, 1])
    #expect(color.widgets[0].appearanceStates == [PDFName("A"), PDFName("Off")])
    #expect(color.widgets[1].appearanceStates == [PDFName("B"), PDFName("Off")])

    #expect(fields[4].isPushButton)
    #expect(fields[5].kind == .signature)
    #expect(fields[6].isReadOnly)
    #expect(fields[6].stringValue == "locked")

    // P24-009: choice fields expose export/display pairs and selections.
    let department = fields[8]
    #expect(department.isCombo)
    #expect(!department.isMultiSelect)
    #expect(department.options.map(\.export) == ["Engineering", "Sales", "Support"])
    #expect(department.stringValue == "Engineering")
    #expect(department.defaultStringValue == "Sales")
    let team = fields[9]
    #expect(!team.isCombo)
    #expect(team.selectedIndexes == [1])
    #expect(team.selectedOption?.display == "Blue Team")
    #expect(team.options.map(\.export) == ["red", "blue"])
    #expect(team.options.map(\.display) == ["Red Team", "Blue Team"])

    // P24-004: the orphaned widget is reported separately, not duplicated.
    let orphans = FormInventory.orphanedWidgets(in: graph, pageIDs: pageIDs)
    #expect(orphans.count == 1)
    #expect(orphans[0].objectID == PDFObjectID(180))
    #expect(orphans[0].pageIndex == 0)

    // P24-005: literal periods inside partial names are escaped.
    #expect(FormInventory.escapeName("first.last") == "first\\.last")

    // P24-010: the push button's JavaScript action is inventoried but never
    // executed by the model.
    let actions = ActionInventory.actions(in: graph, pageIDs: pageIDs)
    #expect(
      actions.contains {
        $0.location == .annotation(pageIndex: 0, annotationIndex: 4) && $0.isJavaScript
      })
  }

  @Test func fillTextUpdatesValueAndAppearance() throws {
    let (graph, pageIDs) = try formFixture()
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "name", text: "Ada Lovelace")]),
      to: graph)

    // Canonical value on the field, appearance replaced in place.
    guard case .dictionary(let field)? = filled.objects[PDFObjectID(110)],
      case .string(let value)? = field[PDFName("V")]
    else {
      Issue.record("Filled field is missing")
      return
    }
    #expect(AnnotationText.decode(value) == "Ada Lovelace")
    guard case .stream(let appearance)? = filled.objects[PDFObjectID(111)] else {
      Issue.record("Widget appearance is missing")
      return
    }
    let content = String(decoding: appearance.bytes, as: UTF8.self)
    #expect(content.contains("(Ada Lovelace) Tj"))
    #expect(content.contains("BT"))
    #expect(content.contains("/F1"))

    // The fill never adds /NeedAppearances and leaves /DV alone.
    let acroForm = try #require(FormInventory.acroFormDictionary(in: filled))
    #expect(acroForm[PDFName("NeedAppearances")] == nil)
    #expect(field[PDFName("DV")] == nil)

    // P24-025: reopening the written bytes shows the new value.
    let reopened = try PDFParser.parse(PDFWriter.write(filled))
    let reopenedFields = try FormInventory.fields(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(reopenedFields.first { $0.name == "name" }?.stringValue == "Ada Lovelace")
    #expect(reopened.graph == filled)

    // Multiline text keeps its newlines in /V and draws separate lines.
    let notes = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "notes", text: "line one\nline two")]),
      to: graph)
    guard case .dictionary(let notesField)? = notes.objects[PDFObjectID(120)],
      case .string(let notesValue)? = notesField[PDFName("V")],
      case .stream(let notesAppearance)? = notes.objects[PDFObjectID(122)]
    else {
      Issue.record("Multiline field is missing")
      return
    }
    #expect(AnnotationText.decode(notesValue) == "line one\nline two")
    let notesContent = String(decoding: notesAppearance.bytes, as: UTF8.self)
    #expect(notesContent.contains("(line one) Tj"))
    #expect(notesContent.contains("(line two) Tj"))
    // The default value stays separate from the current value.
    #expect(notesField[PDFName("DV")] != nil)
    #expect(notesField[PDFName("V")] != notesField[PDFName("DV")])

    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    refuse(SetFormTextCommand(fieldName: "locked", text: "nope"))
    refuse(SetFormTextCommand(fieldName: "sig", text: "nope"))
    refuse(SetFormTextCommand(fieldName: "agree", text: "nope"))
    refuse(SetFormTextCommand(fieldName: "missing", text: "nope"))
    refuse(SetFormTextCommand(fieldName: "name", text: "hello 🙂"))
  }

  @Test func buttonStateUpdatesValueAndAppearance() throws {
    let (graph, pageIDs) = try formFixture()
    let checked = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormButtonStateCommand(fieldName: "agree", state: PDFName("Yes"))
      ]), to: graph)
    guard case .dictionary(let field)? = checked.objects[PDFObjectID(130)],
      case .dictionary(let widget)? = checked.objects[PDFObjectID(131)],
      case .name(let fieldState)? = field[PDFName("V")],
      case .name(let widgetState)? = widget[PDFName("AS")]
    else {
      Issue.record("Checked field is missing")
      return
    }
    #expect(fieldState == PDFName("Yes"))
    #expect(widgetState == PDFName("Yes"))
    // Existing state appearances are preserved, not regenerated.
    #expect(checked.objects[PDFObjectID(132)] == graph.objects[PDFObjectID(132)])
    #expect(checked.objects[PDFObjectID(133)] == graph.objects[PDFObjectID(133)])

    let cleared = try PDFEditingEngine.commit(
      PDFTransaction([SetFormButtonStateCommand(fieldName: "agree", state: nil)]), to: checked)
    guard case .dictionary(let clearedField)? = cleared.objects[PDFObjectID(130)],
      case .dictionary(let clearedWidget)? = cleared.objects[PDFObjectID(131)],
      case .name(let clearedValue)? = clearedField[PDFName("V")],
      case .name(let clearedAS)? = clearedWidget[PDFName("AS")]
    else {
      Issue.record("Cleared field is missing")
      return
    }
    #expect(clearedValue == PDFName("Off"))
    #expect(clearedAS == PDFName("Off"))

    // Radio groups select one widget and switch the others off.
    let radio = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormButtonStateCommand(fieldName: "color", state: PDFName("B"))
      ]), to: graph)
    guard case .dictionary(let radioField)? = radio.objects[PDFObjectID(140)],
      case .name(let radioValue)? = radioField[PDFName("V")],
      case .dictionary(let widgetA)? = radio.objects[PDFObjectID(141)],
      case .dictionary(let widgetB)? = radio.objects[PDFObjectID(142)],
      case .name(let stateA)? = widgetA[PDFName("AS")],
      case .name(let stateB)? = widgetB[PDFName("AS")]
    else {
      Issue.record("Radio field is missing")
      return
    }
    #expect(radioValue == PDFName("B"))
    #expect(stateA == PDFName("Off"))
    #expect(stateB == PDFName("B"))

    // Missing state appearances are generated with a visible mark.
    let extra = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormButtonStateCommand(fieldName: "extra", state: PDFName("Yes"))
      ]), to: graph)
    guard case .dictionary(let extraWidget)? = extra.objects[PDFObjectID(191)],
      case .dictionary(let appearance)? = extraWidget[PDFName("AP")],
      case .dictionary(let states)? = appearance[PDFName("N")],
      case .reference(let yesID)? = states[PDFName("Yes")],
      case .stream(let yesStream)? = extra.objects[yesID],
      case .name(let extraAS)? = extraWidget[PDFName("AS")]
    else {
      Issue.record("Generated button appearance is missing")
      return
    }
    #expect(extraAS == PDFName("Yes"))
    #expect(states[PDFName("Off")] != nil)
    let yesContent = String(decoding: yesStream.bytes, as: UTF8.self)
    #expect(yesContent.contains("l S"))
    #expect(extra.objects[yesID] != graph.objects[yesID])

    let reopened = try PDFParser.parse(PDFWriter.write(extra))
    #expect(reopened.graph == extra)

    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    refuse(SetFormButtonStateCommand(fieldName: "submit", state: PDFName("Yes")))
    refuse(SetFormButtonStateCommand(fieldName: "color", state: PDFName("Maybe")))
    refuse(SetFormButtonStateCommand(fieldName: "missing", state: PDFName("Yes")))
  }

  @Test func choiceSelectionUpdatesValueIndexAndAppearance() throws {
    let (graph, pageIDs) = try formFixture()
    let selected = try PDFEditingEngine.commit(
      PDFTransaction([SetFormChoiceCommand(fieldName: "department", exportValue: "Support")]),
      to: graph)
    guard case .dictionary(let field)? = selected.objects[PDFObjectID(200)],
      case .string(let value)? = field[PDFName("V")],
      case .array(let indexes)? = field[PDFName("I")],
      case .stream(let appearance)? = selected.objects[PDFObjectID(202)]
    else {
      Issue.record("Selected choice field is missing")
      return
    }
    #expect(AnnotationText.decode(value) == "Support")
    #expect(indexes == [.integer(2)])
    #expect(String(decoding: appearance.bytes, as: UTF8.self).contains("(Support) Tj"))
    // The default value stays separate from the current value.
    #expect(field[PDFName("DV")] != nil)

    // A list field selects by export value and draws its display text.
    let team = try PDFEditingEngine.commit(
      PDFTransaction([SetFormChoiceCommand(fieldName: "team", exportValue: "red")]), to: graph)
    guard case .dictionary(let teamField)? = team.objects[PDFObjectID(210)],
      case .array(let teamIndexes)? = teamField[PDFName("I")],
      case .stream(let teamAppearance)? = team.objects[PDFObjectID(212)]
    else {
      Issue.record("Selected list field is missing")
      return
    }
    #expect(teamIndexes == [.integer(0)])
    #expect(String(decoding: teamAppearance.bytes, as: UTF8.self).contains("(Red Team) Tj"))

    let reopened = try PDFParser.parse(PDFWriter.write(selected))
    #expect(reopened.graph == selected)
    #expect(
      try FormInventory.fields(in: reopened.graph, pageIDs: reopened.pageIDs)
        .first { $0.name == "department" }?.stringValue == "Support")

    func refuse(_ command: any PDFEditCommand, in graph: PDFGraph) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    refuse(SetFormChoiceCommand(fieldName: "department", exportValue: "Marketing"), in: graph)
    refuse(SetFormChoiceCommand(fieldName: "name", exportValue: "x"), in: graph)
    // A multi-select list accepts several export values and records both /V
    // and /I arrays.
    var multi = graph
    guard case .dictionary(var multiField)? = multi.objects[PDFObjectID(210)] else { return }
    multiField[PDFName("Ff")] = .integer(2_097_152)
    multi.objects[PDFObjectID(210)] = .dictionary(multiField)
    let multiple = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormChoiceCommand(fieldName: "team", exportValues: ["red", "blue"])
      ]), to: multi)
    guard case .dictionary(let selectedTeam)? = multiple.objects[PDFObjectID(210)],
      case .array(let teamValues)? = selectedTeam[PDFName("V")],
      case .array(let teamIndexes)? = selectedTeam[PDFName("I")]
    else {
      Issue.record("Selected multi-select field is missing")
      return
    }
    #expect(teamValues.count == 2)
    #expect(teamIndexes == [.integer(0), .integer(1)])
    let reopenedMulti = try PDFParser.parse(PDFWriter.write(multiple))
    let reopenedTeam = try #require(
      try FormInventory.fields(in: reopenedMulti.graph, pageIDs: pageIDs)
        .first { $0.name == "team" })
    #expect(reopenedTeam.selectedIndexes == [0, 1])
    #expect(reopenedTeam.stringValue == "red, blue")
  }

  @Test func combTextFieldDistributesCharactersAcrossCells() throws {
    let (graph, _) = try formFixture()
    var comb = graph
    guard case .dictionary(var field)? = comb.objects[PDFObjectID(110)] else {
      Issue.record("name field missing")
      return
    }
    field[PDFName("Ff")] = .integer(16_777_216)
    field[PDFName("MaxLen")] = .integer(6)
    comb.objects[PDFObjectID(110)] = .dictionary(field)
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "name", text: "ABC")]), to: comb)
    guard case .stream(let appearance)? = filled.objects[PDFObjectID(111)] else {
      Issue.record("comb appearance missing")
      return
    }
    let content = String(decoding: appearance.bytes, as: UTF8.self)
    #expect(content.components(separatedBy: " Tm ").count - 1 == 3)
    #expect(content.contains("(A) Tj"))
    #expect(content.contains("(B) Tj"))
    #expect(content.contains("(C) Tj"))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormTextCommand(fieldName: "name", text: "ABCDEFG")]), to: comb)
    }
  }

  @Test func inheritedMaxLenAppliesToChildField() throws {
    let (base, pageIDs) = try formFixture()
    var graph = base
    guard case .dictionary(var acro)? = graph.objects[PDFObjectID(101)],
      case .array(var fields)? = acro[PDFName("Fields")]
    else {
      Issue.record("AcroForm missing")
      return
    }
    fields = fields.map { value in
      if case .reference(let id) = value, id == PDFObjectID(110) {
        return .reference(PDFObjectID(220))
      }
      return value
    }
    acro[PDFName("Fields")] = .array(fields)
    graph.objects[PDFObjectID(101)] = .dictionary(acro)
    graph.objects[PDFObjectID(220)] = .dictionary([
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("T"): .string(Data("group".utf8)),
      PDFName("MaxLen"): .integer(4),
      PDFName("Kids"): .array([.reference(PDFObjectID(110))]),
    ])
    let fieldsAfter = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let child = try #require(fieldsAfter.first { $0.name == "group.name" })
    #expect(child.maxLength == 4)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetFormTextCommand(fieldName: "group.name", text: "ABCDE")]),
        to: graph)
    }
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "group.name", text: "ABCD")]),
      to: graph)
    let reopened = try FormInventory.fields(in: filled, pageIDs: pageIDs)
    #expect(reopened.first { $0.name == "group.name" }?.stringValue == "ABCD")
  }

  @Test func repeatedWidgetsAllReceiveTheAppearance() throws {
    let (base, pageIDs) = try formFixture()
    var graph = base
    guard case .dictionary(var page)? = graph.objects[PDFObjectID(3)] else {
      Issue.record("page missing")
      return
    }
    var annots: [PDFValue] = []
    if case .array(let existing)? = page[PDFName("Annots")] { annots = existing }
    annots.append(.reference(PDFObjectID(123)))
    page[PDFName("Annots")] = .array(annots)
    graph.objects[PDFObjectID(3)] = .dictionary(page)
    graph.objects[PDFObjectID(123)] = .dictionary([
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("Parent"): .reference(PDFObjectID(120)),
      PDFName("Rect"): .array([.integer(320), .integer(520), .integer(480), .integer(560)]),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(124))]),
    ])
    graph.objects[PDFObjectID(124)] = .stream(PDFStream(bytes: Data()))
    guard case .dictionary(var notes)? = graph.objects[PDFObjectID(120)],
      case .array(var kids)? = notes[PDFName("Kids")]
    else {
      Issue.record("notes field missing")
      return
    }
    kids.append(.reference(PDFObjectID(123)))
    notes[PDFName("Kids")] = .array(kids)
    graph.objects[PDFObjectID(120)] = .dictionary(notes)
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    #expect(fields.first { $0.name == "notes" }?.widgets.count == 2)

    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "notes", text: "updated")]), to: graph)
    for streamID in [PDFObjectID(122), PDFObjectID(124)] {
      guard case .stream(let stream)? = filled.objects[streamID] else {
        Issue.record("widget appearance missing")
        return
      }
      #expect(String(decoding: stream.bytes, as: UTF8.self).contains("updated"))
    }
  }

  @Test func multilineFieldWrapsLongTextAtWidgetWidth() throws {
    let (graph, _) = try formFixture()
    let text = Array(repeating: "word", count: 40).joined(separator: " ")
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "notes", text: text)]), to: graph)
    guard case .stream(let appearance)? = filled.objects[PDFObjectID(122)] else {
      Issue.record("multiline appearance missing")
      return
    }
    let content = String(decoding: appearance.bytes, as: UTF8.self)
    #expect(content.components(separatedBy: " Tm ").count - 1 > 1)
    #expect(content.contains("word word"))
  }

  @Test func duplicateFieldNamesAcrossDocumentsAreDetected() throws {
    let form = try PDFParser.parse(PDFFixtures.formPages()).graph
    let names = try FormInventory.duplicateNames(across: [form, form])
    #expect(names.contains("name"))
    #expect(!names.isEmpty)
    let plain = try PDFParser.parse(PDFFixtures.onePage()).graph
    #expect(try FormInventory.duplicateNames(across: [form, plain]).isEmpty)
  }

  @Test func resetRestoresDocumentedDefaultValues() throws {
    let (graph, pageIDs) = try formFixture()
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "name", text: "Ada"),
        SetFormTextCommand(fieldName: "notes", text: "changed"),
        SetFormChoiceCommand(fieldName: "department", exportValue: "Support"),
        SetFormButtonStateCommand(fieldName: "agree", state: PDFName("Yes")),
      ]), to: graph)
    let reset = try PDFEditingEngine.commit(PDFTransaction([ResetFormCommand()]), to: filled)
    let fields = try FormInventory.fields(in: reset, pageIDs: pageIDs)
    #expect(fields.first { $0.name == "name" }?.stringValue == "")
    #expect(fields.first { $0.name == "notes" }?.stringValue == "default notes")
    #expect(fields.first { $0.name == "department" }?.stringValue == "Sales")
    #expect(fields.first { $0.name == "agree" }?.buttonState == PDFName("Off"))
    // Read-only fields are left alone by the reset.
    #expect(fields.first { $0.name == "locked" }?.stringValue == "locked")
    let reopened = try PDFParser.parse(PDFWriter.write(reset))
    #expect(reopened.graph == reset)

    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ResetFormCommand()]),
        to: try PDFParser.parse(PDFFixtures.onePage()).graph)
    }
  }

  @Test func valuesExportImportRoundTripsWithExplicitSchema() throws {
    let (graph, pageIDs) = try formFixture()
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "name", text: "Ada"),
        SetFormChoiceCommand(fieldName: "department", exportValue: "Support"),
        SetFormButtonStateCommand(fieldName: "agree", state: PDFName("Yes")),
      ]), to: graph)
    let exported = try FormValues.export(in: filled, pageIDs: pageIDs)
    let parsed = try FormValues.parse(exported)
    #expect(parsed.contains { $0.name == "name" && $0.value == "Ada" })
    #expect(parsed.contains { $0.name == "department" && $0.selectedIndex == 2 })
    #expect(parsed.contains { $0.name == "agree" && $0.buttonState == "Yes" })
    #expect(!parsed.contains { $0.name == "sig" })

    // Import into the pristine fixture reproduces the values; read-only
    // fields are reported as skipped instead of being guessed.
    let (importCommands, skipped, ambiguous) = try FormValues.commands(
      for: parsed, in: graph, pageIDs: pageIDs)
    #expect(skipped == ["locked"])
    #expect(ambiguous.isEmpty)
    let imported = try PDFEditingEngine.commit(PDFTransaction(importCommands), to: graph)
    let importedFields = try FormInventory.fields(in: imported, pageIDs: pageIDs)
    #expect(importedFields.first { $0.name == "name" }?.stringValue == "Ada")
    #expect(importedFields.first { $0.name == "department" }?.stringValue == "Support")
    #expect(importedFields.first { $0.name == "agree" }?.buttonState == PDFName("Yes"))

    // Unknown fields are reported, and unsupported schemas refuse.
    let unknown = FormFieldValue(name: "missing", kind: "text", value: "x")
    let (unknownCommands, unknownSkipped, unknownAmbiguous) = try FormValues.commands(
      for: [unknown], in: graph, pageIDs: pageIDs)
    #expect(unknownCommands.isEmpty)
    #expect(unknownSkipped == ["missing"])
    #expect(unknownAmbiguous.isEmpty)
    #expect(throws: PDFError.self) {
      _ = try FormValues.parse(Data("{\"schemaVersion\": 99, \"fields\": []}".utf8))
    }
    #expect(throws: PDFError.self) { _ = try FormValues.parse(Data("not json".utf8)) }
  }

  @Test func flattenFormBurnsWidgetsAndRemovesTheTree() throws {
    let (graph, pageIDs) = try formFixture()
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "name", text: "Ada")]), to: graph)
    let flattened = try PDFEditingEngine.commit(PDFTransaction([FlattenFormCommand()]), to: filled)
    #expect(try FormInventory.fields(in: flattened, pageIDs: pageIDs).isEmpty)
    #expect(FormInventory.orphanedWidgets(in: flattened, pageIDs: pageIDs).isEmpty)
    let annotations = try AnnotationInventory.annotations(in: flattened, pageID: pageIDs[0])
    #expect(!annotations.contains { $0.subtype == PDFName("Widget") })
    guard case .reference(let rootID)? = flattened.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = flattened.objects[rootID]
    else {
      Issue.record("Catalog is missing")
      return
    }
    #expect(catalog[PDFName("AcroForm")] == nil)
    // The name field's appearance was burned into page content.
    guard case .dictionary(let page)? = flattened.objects[pageIDs[0]],
      case .array(let contents)? = page[PDFName("Contents")],
      case .reference(let streamID) = contents.last!,
      case .stream(let stream)? = flattened.objects[streamID]
    else {
      Issue.record("Flattened content is missing")
      return
    }
    #expect(String(decoding: stream.bytes, as: UTF8.self).contains("cm"))
    #expect(String(decoding: stream.bytes, as: UTF8.self).contains("Do"))
    let reopened = try PDFParser.parse(PDFWriter.write(flattened))
    #expect(reopened.graph == flattened)
  }

  @Test func radioSurvivesPageReorganization() throws {
    let (graph, pageIDs) = try formFixture()
    let reordered = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: pageIDs[1], toIndex: 0)]), to: graph)
    let newOrder = try PageTreeView(graph: reordered).pages
    #expect(newOrder == [pageIDs[1], pageIDs[0]])
    let fields = try FormInventory.fields(in: reordered, pageIDs: newOrder)
    let color = try #require(fields.first { $0.name == "color" })
    #expect(color.isRadio)
    #expect(color.widgets.count == 2)
    #expect(color.widgets.compactMap(\.pageIndex).sorted() == [0, 1])
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([SetFormButtonStateCommand(fieldName: "color", state: PDFName("A"))]),
      to: reordered)
    guard case .dictionary(let field)? = filled.objects[PDFObjectID(140)],
      case .dictionary(let widgetA)? = filled.objects[PDFObjectID(141)],
      case .dictionary(let widgetB)? = filled.objects[PDFObjectID(142)],
      case .name(let value)? = field[PDFName("V")],
      case .name(let stateA)? = widgetA[PDFName("AS")],
      case .name(let stateB)? = widgetB[PDFName("AS")]
    else {
      Issue.record("Reordered radio field is missing")
      return
    }
    #expect(value == PDFName("A"))
    #expect(stateA == PDFName("A"))
    #expect(stateB == PDFName("Off"))
  }

  private func formFixture() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    return (parsed.graph, parsed.pageIDs)
  }
}
