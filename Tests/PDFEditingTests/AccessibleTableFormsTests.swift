import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// A11Y-04 evidence: header scope and associations, row/column spans, form
/// labels and tab order exposed as a read model, plus the screen-reader-shaped
/// transcript used for independent qualification.
@Suite("Accessible tables and forms")
struct AccessibleTableFormsTests {
  @Test func tableModelExposesScopeHeadersSpansAndSummary() throws {
    var (graph, pageIDs) = try A11YFixtures.taggedTableGraph()
    let tableID = PDFObjectID(70)
    let ageHeaderID = PDFObjectID(73)
    let nameDataID = PDFObjectID(75)
    let nameHeaderID = PDFObjectID(72)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetTableSummaryCommand(elementID: tableID, summary: "People and their ages"),
        SetTableCellSpanCommand(elementID: nameDataID, rowSpan: 2, columnSpan: 1),
        SetTableCellHeadersCommand(elementID: nameDataID, headerElementIDs: [nameHeaderID]),
        SetTableHeaderScopeCommand(elementID: ageHeaderID, scope: PDFName("Column")),
      ]), to: graph)
    let tables = AccessibleTableStructure.tables(in: graph, pageIDs: pageIDs)
    #expect(tables.count == 1)
    let table = try #require(tables.first)
    #expect(table.summary == "People and their ages")
    #expect(table.rowCount == 2)
    #expect(table.columnCount == 2)
    #expect(table.headerCellCount == 2)
    #expect(table.dataCellCount == 2)
    #expect(table.headerCells.allSatisfy { $0.scope == "Column" })
    let nameData = try #require(table.cells.first { $0.elementID == nameDataID })
    #expect(
      AccessibleTableStructure.attributes(of: nameDataID, in: graph).rowSpan == 2,
      "attributes \(AccessibleTableStructure.attributes(of: nameDataID, in: graph))")
    #expect(nameData.rowSpan == 2)
    #expect(nameData.explicitHeaderIDs == [nameHeaderID])
    #expect(nameData.resolvedHeaderIDs == [nameHeaderID])
    #expect(nameData.spanLabel.contains("2 rows"))
    #expect(nameData.positionLabel.contains("row 2"))
    #expect(table.hasSpans)
    #expect(table.hasExplicitAssociations)
    let ageData = try #require(table.cells.first {
      $0.isHeader == false && $0.elementID != nameDataID
    })
    // No explicit association on this cell: scope inference finds the column header.
    #expect(ageData.resolvedHeaderIDs.contains(PDFObjectID(73)))

    let narration = table.narrationLines(tableNumber: 1).joined(separator: "\n")
    #expect(narration.contains("Table 1"))
    #expect(narration.contains("summary: \"People and their ages\""))
    #expect(narration.contains("scope Column"))
    #expect(narration.contains("headers"))
    #expect(narration.contains("spans 2 rows"))
  }

  @Test func headerScopeAndAssociationCommandsValidate() throws {
    let (graph, _) = try A11YFixtures.taggedTableGraph()
    let td = PDFObjectID(75)
    let th = PDFObjectID(72)
    let otherTableHeader = PDFObjectID(999)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetTableHeaderScopeCommand(elementID: td, scope: PDFName("Column"))]),
        to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetTableCellHeadersCommand(elementID: td, headerElementIDs: [otherTableHeader])
        ]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([SetTableCellSpanCommand(elementID: td, rowSpan: 0, columnSpan: 1)]),
        to: graph)
    }
    // Clearing explicit associations falls back to scope inference.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetTableCellHeadersCommand(elementID: td, headerElementIDs: []),
        SetTableHeaderScopeCommand(elementID: th, scope: PDFName("Row")),
      ]), to: graph)
    let tables = try AccessibleTableStructure.tables(
      in: edited, pageIDs: try PDFTreePages.pages(in: edited))
    let table = try #require(tables.first)
    let cell = try #require(table.cells.first { $0.elementID == td })
    #expect(cell.explicitHeaderIDs.isEmpty)
    #expect(cell.scope == nil)
    let header = try #require(table.cells.first { $0.elementID == th })
    #expect(header.scope == "Row")
  }

  @Test func tableRelationshipsPersistThroughSaveAndReopen() throws {
    var (graph, pageIDs) = try A11YFixtures.taggedTableGraph()
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetTableCellSpanCommand(elementID: PDFObjectID(76), rowSpan: 1, columnSpan: 2),
        SetTableHeaderScopeCommand(elementID: PDFObjectID(72), scope: PDFName("Both")),
      ]), to: graph)
    let before = AccessibleTableStructure.tables(in: graph, pageIDs: pageIDs)
    let reopened = try PDFParser.parse(try PDFWriter.write(graph))
    let after = AccessibleTableStructure.tables(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(before == after)
    let table = try #require(after.first)
    #expect(table.cells.contains { $0.columnSpan == 2 })
    #expect(table.cells.contains { $0.scope == "Both" })
  }

  @Test func formRelationshipsExposeLabelsAndTabOrder() throws {
    let (graph, pageIDs) = try A11YFixtures.taggedTableWithForm()
    let form = AccessibleDocumentRelationshipsBuilder.formRelationships(
      in: graph, pageIDs: pageIDs)
    #expect(
      form.fields.filter { $0.name == "Name" || $0.name == "Email" }.count == 2)
    #expect(form.tabOrderIsDocumentOrder)
    let name = try #require(form.fields.first { $0.name == "Name" })
    #expect(name.label == "Full name")
    #expect(name.labelSource == .tooltip)
    #expect(name.tabOrderIndex == (form.fields.firstIndex(of: name) ?? -1))
    #expect(name.kind == "text")
    #expect(name.positionLabel.contains("page 1"))
    let lines = form.narrationLines().joined(separator: "\n")
    #expect(lines.contains("\"Full name\""))
    #expect(lines.contains("Tab order:"))
    #expect(lines.contains("Full name"))
  }

  @Test func missingLabelFallbackAndDuplicateNamesAreVisible() throws {
    let (graph, pageIDs) = try A11YFixtures.taggedTableGraph()
    let withFields = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(
          pageID: pageIDs[0], rect: [72, 380, 272, 404], name: "Unlabelled"),
      ]), to: graph)
    let form = AccessibleDocumentRelationshipsBuilder.formRelationships(
      in: withFields, pageIDs: pageIDs)
    let field = try #require(form.fields.first { $0.name == "Unlabelled" })
    #expect(field.labelSource == .fieldName)
    #expect(field.label == "Unlabelled")
    #expect(form.issues.contains { $0.kind == .missingLabel && $0.fieldName == "Unlabelled" })
    #expect(form.narrationLines().joined().contains("no tooltip"))
  }

  @Test func combinedTranscriptDescribesTablesAndForms() throws {
    let (graph, pageIDs) = try A11YFixtures.taggedTableWithForm()
    let relationships = AccessibleDocumentRelationshipsBuilder.build(
      in: graph, pageIDs: pageIDs)
    #expect(relationships.tables.count == 1)
    #expect(relationships.form.fields.count >= 2)
    let transcript = relationships.transcript()
    #expect(transcript.contains("Table 1"))
    #expect(transcript.contains("Header at"))
    #expect(transcript.contains("Data cell at"))
    #expect(transcript.contains("Form:"))
    #expect(transcript.contains("\"Full name\""))
    #expect(transcript.contains("\"Email address\""))
    #expect(transcript.contains("Tab order:"))
    #expect(transcript.contains("Full name") && transcript.contains("Email address"))
    #expect(transcript.contains("not an accessibility-conformance claim"))
    #expect(relationships.summary.contains("table"))
    let lines = relationships.narrationLines()
    #expect(lines.first?.contains("Table 1") == true)
  }

  @Test func inferredAssociationsMatchHeaderScope() throws {
    let (graph, pageIDs) = try A11YFixtures.taggedTableGraph()
    let tables = AccessibleTableStructure.tables(in: graph, pageIDs: pageIDs)
    let table = try #require(tables.first)
    let firstHeader = try #require(table.cells.first {
      $0.isHeader && $0.scope == "Column"
    })
    let data = table.dataCells.filter { $0.column == firstHeader.column }
    #expect(!data.isEmpty)
    #expect(data.allSatisfy { $0.resolvedHeaderIDs.contains(firstHeader.elementID) })
    let secondHeader = try #require(table.cells.first {
      $0.isHeader && $0.elementID != firstHeader.elementID && $0.scope == "Column"
    })
    // The second header's column has no data cell in this 2x2 fixture except its own.
    #expect(table.narrationLines(tableNumber: 1).contains { $0.contains("scope Column") })
    #expect(secondHeader.scope == "Column")
  }
}

/// Small helper so tests can list page IDs from a graph without the internal
/// page-tree type if it changes.
enum PDFTreePages {
  static func pages(in graph: PDFGraph) throws -> [PDFObjectID] {
    try PageTreeView(graph: graph).pages
  }
}
