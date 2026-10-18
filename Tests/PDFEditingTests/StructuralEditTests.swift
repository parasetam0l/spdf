import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P23-001/002/004/025 and P09-008 evidence: reorder, delete with reference
/// preflight, blank-page insertion, retained raw content, and collision-free
/// object identity allocation.
@Suite("Structural edits")
struct StructuralEditTests {
  @Test func reorderMovesPageAndKeepsCountsConsistent() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let order = parsed.pageIDs
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: order[2], toIndex: 0)]), to: parsed.graph)
    let movedParsed = try PDFParser.parse(PDFWriter.write(moved))
    #expect(movedParsed.pageIDs == [order[2], order[0], order[1]])
    try moved.validate()

    // Moving within the same parent keeps the array and counts correct.
    let shifted = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: order[0], toIndex: 1)]), to: parsed.graph)
    #expect(try PDFParser.parse(PDFWriter.write(shifted)).pageIDs == [order[1], order[0], order[2]])
    try shifted.validate()

    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ReorderPagesCommand(pageID: order[0], toIndex: 3)]), to: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ReorderPagesCommand(pageID: PDFObjectID(3), toIndex: 0)]), to: parsed.graph)
    }
  }

  @Test func reorderCrossesNestedPageTreeBranches() throws {
    let graph = Self.nestedGraph()
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: PDFObjectID(12), toIndex: 0)]), to: graph)
    let view = try PageTreeView(graph: moved)
    #expect(view.pages == [PDFObjectID(12), PDFObjectID(10), PDFObjectID(11)])
    try moved.validate()
    let reopened = try PDFParser.parse(PDFWriter.write(moved))
    #expect(reopened.pageIDs == [PDFObjectID(12), PDFObjectID(10), PDFObjectID(11)])
  }

  @Test func deleteRefusesExternalReferencesAndKeepsLastPage() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let order = parsed.pageIDs

    // A catalog destination referencing a page blocks deletion.
    var referenced = parsed.graph
    guard case .reference(let root)? = referenced.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = referenced.objects[root]
    else {
      Issue.record("Catalog missing")
      return
    }
    catalog[PDFName("OpenDest")] = .reference(order[1])
    referenced.objects[root] = .dictionary(catalog)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([DeletePagesCommand(pageIDs: [order[1]])]), to: referenced)
    }

    // Deleting every page is refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(PDFTransaction([DeletePagesCommand(pageIDs: order)]), to: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(PDFTransaction([DeletePagesCommand(pageIDs: [])]), to: parsed.graph)
    }

    // A safe deletion removes the page from the order but retains its object.
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [order[1]])]), to: parsed.graph)
    let reopened = try PDFParser.parse(PDFWriter.write(deleted))
    #expect(reopened.pageIDs == [order[0], order[2]])
    #expect(reopened.graph.objects[order[1]] != nil)
    try deleted.validate()
  }

  @Test func deleteAndInsertAcrossNestedBranchesKeepStructure() throws {
    let graph = Self.nestedGraph()
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [PDFObjectID(10)])]), to: graph)
    let view = try PageTreeView(graph: deleted)
    #expect(view.pages == [PDFObjectID(11), PDFObjectID(12)])
    try deleted.validate()

    let inserted = try PDFEditingEngine.commit(
      PDFTransaction([InsertBlankPageCommand(atIndex: 1, width: 300, height: 400)]), to: deleted)
    let insertedView = try PageTreeView(graph: inserted)
    #expect(insertedView.pages.count == 3)
    let newID = insertedView.pages[1]
    guard case .dictionary(let page)? = inserted.objects[newID] else {
      Issue.record("Inserted page missing")
      return
    }
    #expect(page[PDFName("MediaBox")] == .array([.integer(0), .integer(0), .integer(300), .integer(400)]))
    #expect(page[PDFName("Parent")] != nil)
    #expect(page[PDFName("Resources")] == .dictionary([:]))
    try inserted.validate()
  }

  @Test func blankInsertionAllocatesUniqueIdentities() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    graph.objects[PDFObjectID(50)] = .null
    let first = try PDFEditingEngine.commit(
      PDFTransaction([InsertBlankPageCommand(atIndex: 1, width: 200, height: 200)]), to: graph)
    let firstID = try PageTreeView(graph: first).pages[1]
    #expect(firstID == PDFObjectID(51))
    // The declared Size must track the new object or save verification fails.
    #expect(first.trailer[PDFName("Size")] == .integer(Int64(firstID.number) + 1))
    #expect(try PDFParser.parse(PDFWriter.write(first)).graph == first)
    let second = try PDFEditingEngine.commit(
      PDFTransaction([InsertBlankPageCommand(atIndex: 0, width: 100, height: 100)]), to: first)
    let secondView = try PageTreeView(graph: second)
    #expect(secondView.pages[0] != firstID)
    #expect(secondView.pages.count == 3)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([InsertBlankPageCommand(atIndex: 0, width: 0, height: 100)]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([InsertBlankPageCommand(atIndex: 9, width: 100, height: 100)]), to: graph)
    }
  }

  @Test func structuralEditsPreserveRawContentBytes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    // Content streams for the three pages are objects 5, 7, and 9.
    let contentIDs = [PDFObjectID(5), PDFObjectID(7), PDFObjectID(9)]
    let before = contentIDs.compactMap { parsed.graph.objects[$0] }
    #expect(before.count == 3)

    let reordered = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: parsed.pageIDs[2], toIndex: 0)]), to: parsed.graph)
    let inserted = try PDFEditingEngine.commit(
      PDFTransaction([InsertBlankPageCommand(atIndex: 0, width: 10, height: 10)]), to: reordered)
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [inserted.pageIDsFromGraph[0]])]), to: inserted)
    for (index, id) in contentIDs.enumerated() {
      #expect(deleted.objects[id] == before[index])
    }
  }

  // MARK: - Nested test graph

  /// Root Pages (2) -> interior Pages (3) with pages 10/11, plus page 12.
  private static func nestedGraph() -> PDFGraph {
    func page(_ number: Int, parent: Int, width: Int64) -> PDFValue {
      .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(parent)),
        PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(width), .integer(400)]),
      ])
    }
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(3),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(12))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(10)), .reference(PDFObjectID(11))]),
        ]),
        PDFObjectID(10): page(10, parent: 3, width: 300),
        PDFObjectID(11): page(11, parent: 3, width: 400),
        PDFObjectID(12): page(12, parent: 2, width: 500),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }
}

private extension PDFGraph {
  var pageIDsFromGraph: [PDFObjectID] {
    (try? PageTreeView(graph: self).pages) ?? []
  }
}
