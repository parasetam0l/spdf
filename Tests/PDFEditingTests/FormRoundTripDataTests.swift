import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-06 evidence: round-trip-friendly form data with values/field semantics
/// only, no viewer-specific cleanup instructions, clear identification of
/// unsupported external actions, and an honest round-trip comparison.
@Suite("Round-trip form data (FRM-06)")
struct FormRoundTripDataTests {
  private func parsed(_ data: Data) throws -> PDFGraph {
    try PDFParser.parse(data).graph
  }

  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private func filledFixture() throws -> PDFGraph {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [
        SetFormTextCommand(fieldName: "name", text: "Alice Example"),
        SetFormFieldTooltipCommand(fieldName: "name", tooltip: "Full legal name"),
        SetFormTextCommand(fieldName: "notes", text: "Line one\nLine two"),
      ], to: graph)
    return graph
  }

  private func pageIDs(_ graph: PDFGraph) throws -> [PDFObjectID] {
    try PDFPageTree.pageIDs(in: graph)
  }

  @Test func captureCarriesValuesLabelsAndRequiredFlags() throws {
    let graph = try filledFixture()
    let pages = try pageIDs(graph)
    let bundle = try FormRoundTripData.capture(in: graph, pageIDs: pages)
    #expect(!bundle.fields.isEmpty)
    guard let name = bundle.fields.first(where: { $0.name == "name" }),
      let notes = bundle.fields.first(where: { $0.name == "notes" })
    else {
      Issue.record("Expected form fields are missing")
      return
    }
    #expect(name.value == "Alice Example")
    #expect(name.tooltip == "Full legal name")
    #expect(!name.required)
    #expect(notes.required)
    #expect(bundle.summaryLines.joined().contains("Round-trip form data"))
    #expect(bundle.summaryLines.joined().contains("no NeedAppearances"))
  }

  @Test func bundleContainsNoViewerCleanupInstructions() throws {
    let graph = try filledFixture()
    let bundle = try FormRoundTripData.capture(in: graph, pageIDs: try pageIDs(graph))
    let object = try #require(
      try JSONSerialization.jsonObject(with: try bundle.jsonData()) as? [String: Any])
    for key in FormRoundTripBundle.viewerInstructionKeys {
      #expect(object[key] == nil)
    }
    let entries = try #require(object["fields"] as? [[String: Any]])
    for entry in entries {
      for key in FormRoundTripBundle.viewerInstructionKeys {
        #expect(entry[key] == nil)
      }
    }
    let parsed = try FormRoundTripData.parse(try bundle.jsonData())
    #expect(parsed.fields == bundle.fields)
    #expect(try FormRoundTripData.capture(in: graph, pageIDs: try pageIDs(graph))
      .jsonData() == bundle.jsonData())
  }

  @Test func importRejectsViewerCleanupRequests() throws {
    let needsAppearances = Data(
      """
      {"schemaVersion":1,"fields":[],"NeedAppearances":true}
      """.utf8)
    #expect(throws: PDFError.self) { _ = try FormRoundTripData.parse(needsAppearances) }
    let xfa = Data(
      """
      {"schemaVersion":1,"fields":[],"XFA":[{"packet":"fake"}]}
      """.utf8)
    #expect(throws: PDFError.self) { _ = try FormRoundTripData.parse(xfa) }
    let unsupportedVersion = Data(
      """
      {"schemaVersion":99,"fields":[]}
      """.utf8)
    #expect(throws: PDFError.self) {
      _ = try FormRoundTripData.parse(unsupportedVersion)
    }
  }

  @Test func valuesRoundTripExactlyWithoutViewerInstructions() throws {
    let original = try filledFixture()
    let originalBundle = try FormRoundTripData.capture(
      in: original, pageIDs: try pageIDs(original))
    let target = try parsed(PDFFixtures.formPages())
    let targetPages = try pageIDs(target)
    let mapping = try FormRoundTripData.commands(
      for: originalBundle, in: target, pageIDs: targetPages)
    // Read-only fields are reported, never overwritten; unselected choice
    // fields have no value to import. Values still round-trip exactly because
    // their stored values are unchanged.
    #expect(mapping.skipped.allSatisfy { $0 == "locked" || $0 == "color" })
    #expect(!mapping.commands.isEmpty)
    let imported = try commit(mapping.commands, to: target)
    let importedBundle = try FormRoundTripData.capture(
      in: imported, pageIDs: try pageIDs(imported))
    let comparison = FormRoundTripData.compare(
      original: originalBundle, imported: importedBundle)
    #expect(comparison.isRoundTripClean)
    #expect(comparison.summaryLines.joined().contains("round-tripped exactly"))
    // Import writes values only; it never asks a viewer to regenerate fields.
    guard case .reference(let catalogID)? = imported.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = imported.objects[catalogID],
      case .reference(let acroFormID)? = catalog[PDFName("AcroForm")],
      case .dictionary(let acroForm)? = imported.objects[acroFormID]
    else {
      Issue.record("AcroForm is missing after import")
      return
    }
    #expect(acroForm[PDFName("NeedAppearances")] != .boolean(true))
    #expect(acroForm[PDFName("XFA")] == nil)
  }

  @Test func readOnlyFieldsAreReportedNotOverwritten() throws {
    let original = try filledFixture()
    let bundle = try FormRoundTripData.capture(in: original, pageIDs: try pageIDs(original))
    let target = try parsed(PDFFixtures.formPages())
    let readOnlyTarget = try commit(
      [SetFormFieldFlagsCommand(fieldName: "name", readOnly: true)], to: target)
    let mapping = try FormRoundTripData.commands(
      for: bundle, in: readOnlyTarget, pageIDs: try pageIDs(readOnlyTarget))
    #expect(mapping.skipped.contains("name"))
    let imported = try commit(mapping.commands, to: readOnlyTarget)
    let importedBundle = try FormRoundTripData.capture(
      in: imported, pageIDs: try pageIDs(imported))
    let comparison = FormRoundTripData.compare(
      original: bundle, imported: importedBundle)
    #expect(comparison.changed.contains("name"))
  }

  @Test func unsupportedExternalActionsAreIdentifiedNotExecuted() throws {
    var graph = try filledFixture()
    let pages = try pageIDs(graph)
    let fields = try FormInventory.fields(in: graph, pageIDs: pages)
    let nameField = try #require(fields.first { $0.name == "name" })
    let fieldID = try #require(nameField.fieldID)
    guard case .dictionary(var fieldDictionary)? = graph.objects[fieldID] else {
      Issue.record("Field dictionary missing")
      return
    }
    fieldDictionary[PDFName("AA")] = .dictionary([
      PDFName("V"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert('x')".utf8)),
      ])
    ])
    graph.objects[fieldID] = .dictionary(fieldDictionary)
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID],
      case .reference(let acroFormID)? = catalog[PDFName("AcroForm")],
      case .dictionary(var acroForm)? = graph.objects[acroFormID]
    else {
      Issue.record("AcroForm missing")
      return
    }
    acroForm[PDFName("CO")] = .array([.reference(fieldID)])
    graph.objects[acroFormID] = .dictionary(acroForm)
    catalog[PDFName("AcroForm")] = .reference(acroFormID)
    graph.objects[catalogID] = .dictionary(catalog)
    let bundle = try FormRoundTripData.capture(in: graph, pageIDs: pages)
    #expect(bundle.unsupported.contains { $0.action.contains("additional actions") && $0.field == "name" })
    #expect(bundle.unsupported.contains { $0.action == "calculation order" })
    #expect(bundle.summaryLines.joined().contains("never executed"))
    // Unsupported actions are reported in the JSON but never turned into
    // executable instructions.
    let json = bundle.jsonText
    #expect(json.contains("unsupported"))
    #expect(!json.contains("app.alert"))
  }
}
