import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P25-010/P25-018/P25-019/P25-023/P25-024/P25-028: duplication with a
/// value-sharing policy, tab-order editing, geometry alignment/distribution,
/// the repeated-name import policy, and the XFA stance.
@Suite("Form organization")
struct FormOrganizationTests {
  private func page() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    return (parsed.graph, parsed.pageIDs[0])
  }

  private func fields(_ graph: PDFGraph, _ pageIDs: [PDFObjectID]) throws -> [FormField] {
    try FormInventory.fields(in: graph, pageIDs: pageIDs)
  }

  private func annotationOrder(_ graph: PDFGraph, pageID: PDFObjectID) -> [PDFObjectID] {
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .array(let annotations)? = page[PDFName("Annots")]
    else { return [] }
    return annotations.compactMap { value in
      if case .reference(let id) = value { return id }
      return nil
    }
  }

  @Test func duplicationSharesOrCopiesValues() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageID, rect: [72, 640, 272, 664], name: "Note", defaultValue: "A")
      ]), to: graph)
    // Shared value: another widget on the same field.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        DuplicateFormFieldCommand(
          fieldName: "Note", pageID: pageID, offset: [0, -40], sharing: .sharedValue)
      ]), to: edited)
    var note = try #require(try fields(edited, [pageID]).first { $0.name == "Note" })
    #expect(note.widgets.count == 2)
    #expect(note.stringValue == "A")
    // Filling the shared field updates every widget's appearance.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Note", text: "B")]), to: edited)
    note = try #require(try fields(edited, [pageID]).first { $0.name == "Note" })
    #expect(note.widgets.count == 2)
    for widget in note.widgets {
      guard let widgetID = widget.objectID,
        case .dictionary(let dictionary)? = edited.objects[widgetID],
        case .dictionary(let ap)? = dictionary[PDFName("AP")],
        case .reference(let streamID)? = ap[PDFName("N")],
        case .stream(let stream)? = edited.objects[streamID]
      else {
        Issue.record("Widget appearance missing")
        continue
      }
      let content = String(decoding: try PDFFilters.decoded(stream), as: UTF8.self)
      #expect(content.contains("(B) Tj"))
    }

    // Independent copy: its own field and value.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        DuplicateFormFieldCommand(
          fieldName: "Note", pageID: pageID, offset: [220, 0], sharing: .independentCopy)
      ]), to: edited)
    let names = try fields(edited, [pageID]).map(\.name).sorted()
    #expect(names == ["Note", "Note2"])
    edited = try PDFEditingEngine.commit(
      PDFTransaction([SetFormTextCommand(fieldName: "Note", text: "C")]), to: edited)
    let all = try fields(edited, [pageID])
    #expect(all.first { $0.name == "Note" }?.stringValue == "C")
    #expect(all.first { $0.name == "Note2" }?.stringValue == "B")

    // Radio duplication adds a widget that shares the group value.
    var withRadio = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRadioGroupCommand(
          pageID: pageID, rects: [[72, 560, 90, 578], [100, 560, 118, 578]], name: "Plan",
          exportValues: ["A", "B"], selectedIndex: 0)
      ]), to: edited)
    withRadio = try PDFEditingEngine.commit(
      PDFTransaction([
        DuplicateFormFieldCommand(
          fieldName: "Plan", pageID: pageID, offset: [0, -40], sharing: .sharedValue)
      ]), to: withRadio)
    let plan = try #require(try fields(withRadio, [pageID]).first { $0.name == "Plan" })
    #expect(plan.widgets.count == 3)
    #expect(plan.buttonState == PDFName("A"))
  }

  @Test func reorderChangesFieldAndAnnotationOrder() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 660, 172, 684], name: "Alpha"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 620, 172, 644], name: "Beta"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 580, 172, 604], name: "Gamma"),
      ]), to: graph)
    var byID: [PDFObjectID: String] = [:]
    for field in try fields(edited, [pageID]) {
      if let widgetID = field.widgets.first?.objectID { byID[widgetID] = field.name }
    }
    #expect(annotationOrder(edited, pageID: pageID).compactMap { byID[$0] } == ["Alpha", "Beta", "Gamma"])
    edited = try PDFEditingEngine.commit(
      PDFTransaction([ReorderFormFieldsCommand(order: ["Gamma", "Alpha", "Beta"])]), to: edited)
    #expect(annotationOrder(edited, pageID: pageID).compactMap { byID[$0] } == ["Gamma", "Alpha", "Beta"])
    #expect(try fields(edited, [pageID]).map(\.name).sorted() == ["Alpha", "Beta", "Gamma"])
    // The order must list every field exactly once.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ReorderFormFieldsCommand(order: ["Alpha", "Beta"])]), to: edited)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ReorderFormFieldsCommand(order: ["Alpha", "Alpha", "Beta"])]), to: edited)
    }
  }

  @Test func alignmentAndDistributionMoveWidgets() throws {
    let (graph, pageID) = try page()
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [100, 660, 200, 684], name: "One"),
        AddTextFieldCommand(pageID: pageID, rect: [150, 620, 250, 644], name: "Two"),
        AddTextFieldCommand(pageID: pageID, rect: [260, 580, 360, 604], name: "Three"),
      ]), to: graph)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AlignFormWidgetsCommand(fields: ["One", "Two", "Three"], edge: .left)
      ]), to: edited)
    var rects = try fields(edited, [pageID]).compactMap { $0.widgets.first?.rect }
    #expect(rects.allSatisfy { $0[0] == 100 })
    // Distribution evens the horizontal gaps.
    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        DistributeFormWidgetsCommand(fields: ["One", "Two", "Three"], axis: .horizontal)
      ]), to: edited)
    rects = try fields(edited, [pageID]).compactMap { $0.widgets.first?.rect }
    let lefts = rects.map { $0[0] }.sorted()
    #expect(abs((lefts[1] - lefts[0]) - (lefts[2] - lefts[1])) < 0.01)
    // Alignment needs two fields; distribution needs three.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([AlignFormWidgetsCommand(fields: ["One"], edge: .top)]), to: edited)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          DistributeFormWidgetsCommand(fields: ["One", "Two"], axis: .vertical)
        ]), to: edited)
    }
  }

  @Test func repeatedNamesAreReportedOnImport() throws {
    let (graph, pageID) = try page()
    // A document with two canonical fields sharing the full name "Dup".
    var duplicated = graph
    duplicated.objects[PDFObjectID(60)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("T"): .string(Data("Dup".utf8)),
      PDFName("Rect"): .array([
        .integer(72), .integer(600), .integer(172), .integer(624),
      ]),
      PDFName("P"): .reference(pageID),
    ])
    duplicated.objects[PDFObjectID(61)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Widget")),
      PDFName("FT"): .name(PDFName("Tx")),
      PDFName("T"): .string(Data("Dup".utf8)),
      PDFName("Rect"): .array([
        .integer(72), .integer(560), .integer(172), .integer(584),
      ]),
      PDFName("P"): .reference(pageID),
    ])
    duplicated.objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
      PDFName("AcroForm"): .dictionary([
        PDFName("Fields"): .array([.reference(PDFObjectID(60)), .reference(PDFObjectID(61))])
      ]),
    ])
    let values = [
      FormFieldValue(name: "Dup", kind: "text", value: "first"),
      FormFieldValue(name: "Missing", kind: "text", value: "x"),
    ]
    let (commands, skipped, ambiguous) = try FormValues.commands(
      for: values, in: duplicated, pageIDs: [pageID])
    #expect(ambiguous == ["Dup"])
    #expect(skipped == ["Missing"])
    #expect(commands.count == 1)
    let filled = try PDFEditingEngine.commit(PDFTransaction(commands), to: duplicated)
    let dupFields = try fields(filled, [pageID]).filter { $0.name == "Dup" }
    #expect(dupFields.count == 2)
    #expect(dupFields[0].stringValue == "first")
    #expect(dupFields[1].stringValue == nil)
  }

  @Test func xfaPresenceIsDistinctFromAcroFormAuthoring() throws {
    let (graph, pageID) = try page()
    #expect(!FormXAFFlag.hasXFA(in: graph))
    var withXFA = graph
    withXFA.objects[PDFObjectID(70)] = .stream(
      PDFStream(
        dictionary: [PDFName("Subtype"): .name(PDFName("XML"))],
        bytes: Data("<xfa>packet</xfa>".utf8)))
    withXFA.objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
      PDFName("AcroForm"): .dictionary([
        PDFName("Fields"): .array([]),
        PDFName("XFA"): .reference(PDFObjectID(70)),
      ]),
    ])
    #expect(FormXAFFlag.hasXFA(in: withXFA))
    let xfaBefore = withXFA.objects[PDFObjectID(70)]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "AcroOnly")
      ]), to: withXFA)
    // AcroForm authoring works; the XFA packet is untouched.
    #expect(try fields(edited, [pageID]).map(\.name) == ["AcroOnly"])
    #expect(edited.objects[PDFObjectID(70)] == xfaBefore)
    #expect(FormXAFFlag.hasXFA(in: edited))
    #expect(!FormXAFFlag.authoringWarning.isEmpty)
  }
}
