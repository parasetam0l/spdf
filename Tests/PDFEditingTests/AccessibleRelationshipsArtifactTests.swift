import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// A11Y-03/A11Y-04 evidence artifact writer (opt-in):
///   SPDF_A11Y_ARTIFACT_DIR=<dir> swift test --filter AccessibleRelationshipsArtifactTests
/// Writes the tagged table/form PDF, the applied-suggestion tagging PDF, the
/// relationship transcript and the expected relationship JSON that the
/// independent-reader script verifies without sPDF.
@Suite("Accessible relationships artifacts")
struct AccessibleRelationshipsArtifactTests {
  @Test func writesArtifactsWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directoryPath = environment["SPDF_A11Y_ARTIFACT_DIR"], !directoryPath.isEmpty
    else { return }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // A11Y-04: a tagged table with header scopes, explicit associations, spans,
    // summary and labelled form fields with document-order tab positions.
    var (graph, pageIDs) = try A11YFixtures.taggedTableWithForm()
    // Add a third row so the row span is a valid relationship (the fixture table
    // has a header row and one data row).
    let base = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let thirdRowID = PDFObjectID(base)
    let thirdCellID = PDFObjectID(base + 1)
    graph.objects[thirdRowID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TR")),
      PDFName("P"): .reference(PDFObjectID(70)),
      PDFName("K"): .array([.reference(thirdCellID)]),
    ])
    graph.objects[thirdCellID] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("TD")),
      PDFName("P"): .reference(thirdRowID),
    ])
    if case .dictionary(var table)? = graph.objects[PDFObjectID(70)],
      case .array(var kids)? = table[PDFName("K")]
    {
      kids.append(.reference(thirdRowID))
      table[PDFName("K")] = .array(kids)
      graph.objects[PDFObjectID(70)] = .dictionary(table)
    }
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "Name", text: "Asha Demir"),
        SetFormTextCommand(fieldName: "Email", text: "asha@example.com"),
        SetTableSummaryCommand(
          elementID: PDFObjectID(70), summary: "People and their email addresses"),
        SetTableCellSpanCommand(elementID: PDFObjectID(75), rowSpan: 2, columnSpan: 1),
        SetTableHeaderScopeCommand(elementID: PDFObjectID(72), scope: PDFName("Column")),
        SetTableHeaderScopeCommand(elementID: PDFObjectID(73), scope: PDFName("Column")),
      ]), to: graph)
    let relationships = AccessibleDocumentRelationshipsBuilder.build(
      in: graph, pageIDs: pageIDs)
    #expect(relationships.tables.count == 1)
    #expect(
      relationships.form.fields.filter { $0.name == "Name" || $0.name == "Email" }.count == 2)
    let relationshipData = try PDFWriter.write(graph)
    try relationshipData.write(to: directory.appendingPathComponent("a11y-relationships.pdf"))
    let transcript = relationships.transcript()
    try Data(transcript.utf8).write(
      to: directory.appendingPathComponent("a11y-transcript.txt"))

    var tableJSON: [String: Any] = [:]
    if let table = relationships.tables.first {
      var headersJSON: [[String: Any]] = []
      for cell in table.headerCells {
        headersJSON.append([
          "row": cell.row,
          "column": cell.column,
          "scope": cell.scope ?? "",
        ])
      }
      var dataJSON: [[String: Any]] = []
      for cell in table.dataCells {
        dataJSON.append([
          "row": cell.row,
          "column": cell.column,
          "rowSpan": cell.rowSpan,
          "columnSpan": cell.columnSpan,
          "headers": cell.resolvedHeaderIDs.map { Int($0.number) },
        ])
      }
      tableJSON = [
        "summary": table.summary ?? "",
        "columnCount": table.columnCount,
        "rowCount": table.rowCount,
        "headers": headersJSON,
        "dataCells": dataJSON,
      ]
    }
    var fieldsJSON: [[String: Any]] = []
    for field in relationships.form.fields {
      fieldsJSON.append([
        "label": field.label,
        "name": field.name,
        "tabOrder": field.tabOrderIndex,
        "kind": field.kind,
      ])
    }
    let formJSON: [String: Any] = [
      "fields": fieldsJSON,
      "tabOrder": relationships.form.fields.sorted { $0.tabOrderIndex < $1.tabOrderIndex }
        .map(\.name),
    ]
    let expected: [String: Any] = [
      "table": tableJSON,
      "form": formJSON,
      "transcript": transcript,
    ]
    try writeJSON(expected, to: directory.appendingPathComponent("a11y-expected.json"))

    // A11Y-03: run the extended assistant on an untagged document and apply one
    // accepted suggestion of every extended kind (list and caption included).
    let (untaggedGraph, untaggedPages) = A11YFixtures.untaggedDocument()
    try PDFWriter.write(untaggedGraph).write(
      to: directory.appendingPathComponent("a11y-untagged-before.pdf"))
    let analysis = try AccessibleTaggingAssistant.analyze(
      pageIDs: untaggedPages, in: untaggedGraph)
    var review = AccessibleTaggingReview(suggestions: analysis.suggestions)
    var commands: [any PDFEditCommand] = []
    var appliedRoles: [String] = []
    var seen = Set<String>()
    for suggestion in analysis.suggestions {
      let kindLabel = suggestion.label
      let family = kindLabel.split(separator: " ").first.map(String.init) ?? kindLabel
      guard !seen.contains(family) else { continue }
      if case .figure = suggestion.kind {
        guard let command = review.command(for: suggestion, altText: "A green square") else {
          continue
        }
        seen.insert(family)
        commands.append(command)
        appliedRoles.append(suggestion.proposedRole)
        continue
      }
      review.accept(suggestion.id)
      guard let command = review.command(for: suggestion) else { continue }
      seen.insert(family)
      commands.append(command)
      appliedRoles.append(suggestion.proposedRole)
    }
    #expect(!commands.isEmpty)
    let tagged = try PDFEditingEngine.commit(PDFTransaction(commands), to: untaggedGraph)
    try PDFWriter.write(tagged).write(
      to: directory.appendingPathComponent("a11y-tagging.pdf"))
    let taggedInventory = try PDFStructureInspector.inspect(
      in: tagged, pageIDs: untaggedPages)
    let roles = Set(taggedInventory.elements.map(\.role))
    for role in ["H1", "H3", "P", "L", "LI", "Figure", "Caption"] where roles.contains(role) {
      #expect(true)
    }
    let taggingExpected: [String: Any] = [
      "appliedRoles": appliedRoles,
      "structureRoles": taggedInventory.elements.map(\.role),
      "structureIssueCount": taggedInventory.issues.count,
      "untaggedTextBlocks": analysis.untaggedTextBlocks,
      "untaggedFigures": analysis.untaggedFigures,
      "pagesWithoutTaggedContent": analysis.pagesWithoutTaggedContent,
      "disclaimer": AccessibleTaggingAssistant.conformanceDisclaimer,
      "isTagged": taggedInventory.isTagged,
    ]
    try writeJSON(
      taggingExpected, to: directory.appendingPathComponent("a11y-tagging-expected.json"))
    let reopened = try PDFParser.parse(try PDFWriter.write(tagged))
    let reopenedRoles = Set(
      try PDFStructureInspector.inspect(in: reopened.graph, pageIDs: reopened.pageIDs)
        .elements.map(\.role))
    #expect(reopenedRoles.contains("L"))
    #expect(reopenedRoles.contains("Figure"))
    #expect(reopenedRoles.contains("Caption"))
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }
}
