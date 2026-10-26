import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// A11Y-02 evidence: the visual reading-order inventory connects page overlay
/// bounds to tags, and reordering changes only logical order — page paint and
/// overlays stay put and the order survives save/reopen.
@Suite("Reading order editor (A11Y-02)")
struct ReadingOrderEditorTests {
  private func tagged() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    return (parsed.graph, parsed.pageIDs)
  }

  @Test func inventoryConnectsEveryPageTagToOverlayBounds() throws {
    let (graph, pageIDs) = try tagged()
    let pageID = try #require(pageIDs.first)
    let paintBefore = try ReadingOrderEditor.pagePaintBytes(pageID: pageID, in: graph)
    let inventory = try ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs)
    let page = try #require(inventory.pages.first)
    #expect(page.items.count >= 5)
    #expect(page.items.map(\.role).prefix(3) == ["H1", "P", "Figure"])
    #expect(page.items.contains { $0.role == "Link" && $0.contentKind.contains("annotation") })
    #expect(page.items.contains { $0.role == "Form" && $0.contentKind.contains("annotation") })
    let heading = try #require(page.items.first { $0.role == "H1" })
    #expect(heading.textSnippet.contains("Tagged heading"))
    let bounds = try #require(heading.bounds)
    #expect(bounds.count == 4)
    #expect(bounds[2] > bounds[0] && bounds[3] > bounds[1])
    #expect(page.untaggedMCIDs.isEmpty)
    #expect(page.issues.isEmpty)
    #expect(inventory.summary.contains("Reading order"))
    // Overlay inventory is read-only.
    #expect(try ReadingOrderEditor.pagePaintBytes(pageID: pageID, in: graph) == paintBefore)
  }

  @Test func reorderChangesOnlyLogicalOrder() throws {
    let (graph, pageIDs) = try tagged()
    let pageID = try #require(pageIDs.first)
    let before = try #require(
      try ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs).pages.first)
    let paintBefore = try ReadingOrderEditor.pagePaintBytes(pageID: pageID, in: graph)
    let boundsBefore = Dictionary(
      uniqueKeysWithValues: before.items.map { ($0.elementID, $0.bounds) })
    let reversed = Array(before.items.map(\.elementID).reversed())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReorderPageReadingOrderCommand(pageID: pageID, orderedElementIDs: reversed)
      ]), to: graph)
    let after = try #require(
      try ReadingOrderEditor.inventory(in: edited, pageIDs: pageIDs).pages.first)
    #expect(after.items.map(\.elementID) == reversed)
    #expect(try ReadingOrderEditor.pagePaintBytes(pageID: pageID, in: edited) == paintBefore)
    for item in after.items {
      #expect(boundsBefore[item.elementID] == item.bounds)
    }
    #expect(try PDFStructureInspector.inspect(in: edited, pageIDs: pageIDs).issues.isEmpty)
    let reopened = try PDFParser.parse(try PDFWriter.write(edited))
    let reopenedPage = try #require(
      try ReadingOrderEditor.inventory(in: reopened.graph, pageIDs: reopened.pageIDs).pages.first)
    #expect(reopenedPage.items.map(\.elementID) == reversed)
    #expect(
      try PDFStructureInspector.inspect(in: reopened.graph, pageIDs: reopened.pageIDs)
        .issues.isEmpty)
  }

  @Test func qualificationProvesIndependenceAndSaveSurvival() throws {
    let (graph, pageIDs) = try tagged()
    let report = try ReadingOrderEditor.qualify(in: graph, pageIDs: pageIDs)
    #expect(report.passed, Comment(rawValue: report.summary + " " + report.findings.joined(separator: "; ")))
    #expect(report.paintBytesUnchanged)
    #expect(report.boundsUnchanged)
    #expect(report.orderChanged)
    #expect(report.saveReopenPreserved)
    #expect(report.issuesAfterSave.isEmpty)
    #expect(report.orderBefore != report.orderAfter)
    // The caller graph was never mutated.
    let initialOrder = try ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs)
      .pages.first?.orderDescription
    #expect(initialOrder == report.orderBefore)
  }

  @Test func reorderRefusesAmbiguousRequests() throws {
    let (graph, pageIDs) = try tagged()
    let pageID = try #require(pageIDs.first)
    let items = try ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs)
      .pages.first?.items ?? []
    let ids = items.map(\.elementID)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReorderPageReadingOrderCommand(pageID: pageID, orderedElementIDs: [ids[0]])
        ]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReorderPageReadingOrderCommand(pageID: pageID, orderedElementIDs: [ids[0], ids[0]])
        ]), to: graph)
    }
    // Elements from different parents cannot be interleaved.
    let grouped = try PDFEditingEngine.commit(
      PDFTransaction([
        GroupStructureElementsCommand(
          parentID: PDFObjectID(20), elementIDs: [PDFObjectID(21), PDFObjectID(22)])
      ]), to: graph)
    let groupID = try #require(
      try PDFStructureInspector.inspect(in: grouped, pageIDs: pageIDs)
        .elements.first { $0.role == "Sect" }?.objectID)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReorderPageReadingOrderCommand(
            pageID: pageID, orderedElementIDs: [PDFObjectID(21), PDFObjectID(23)])
        ]), to: grouped)
    }
    // The root itself is not a page child and cannot be listed.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReorderPageReadingOrderCommand(
            pageID: pageID, orderedElementIDs: [PDFObjectID(20), PDFObjectID(21)])
        ]), to: graph)
    }
  }

  @Test func untaggedContentIsReportedAndDoesNotChangeOrder() throws {
    let (baseGraph, pageIDs) = try tagged()
    guard case .stream(let stream)? = baseGraph.objects[PDFObjectID(5)] else {
      Issue.record("fixture content missing")
      return
    }
    var objects = baseGraph.objects
    var bytes = stream.bytes
    bytes.append(Data("/Unmapped <</MCID 7>> BDC\n0 0 m 10 10 l S\nEMC\n".utf8))
    objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: stream.dictionary, bytes: bytes))
    let modified = PDFGraph(objects: objects, trailer: baseGraph.trailer)
    let inventory = try ReadingOrderEditor.inventory(in: modified, pageIDs: pageIDs)
    let page = try #require(inventory.pages.first)
    #expect(page.untaggedMCIDs.contains(7))
    #expect(page.issues.contains { $0.contains("not mapped") })
    #expect(page.items.map(\.role).prefix(3) == ["H1", "P", "Figure"])
  }
}

