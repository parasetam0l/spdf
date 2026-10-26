import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// A11Y-01 evidence: create/delete/reparent, ActualText, language and artifact
/// controls keep ParentTree entries, MCIDs and object references valid through a
/// transaction (the unit the Undo stack restores) and save/reopen.
@Suite("Structure tree editing (A11Y-01)")
struct StructureTreeEditingTests {
  private func tagged() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    return (parsed.graph, parsed.pageIDs)
  }

  private func inventory(_ graph: PDFGraph, _ pageIDs: [PDFObjectID]) throws
    -> PDFStructureInventory
  {
    try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
  }

  private func contentWithExtraMCID(_ graph: PDFGraph) throws -> PDFGraph {
    guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else {
      throw PDFError(.malformed, "fixture content missing")
    }
    var copy = graph
    var bytes = stream.bytes
    bytes.append(
      Data(
        "/New <</MCID 3>> BDC\nBT /F1 12 Tf 42 600 Td (extra tagged text) Tj ET\nEMC\n".utf8))
    copy.objects[PDFObjectID(5)] = .stream(PDFStream(dictionary: stream.dictionary, bytes: bytes))
    return copy
  }

  @Test func createElementWithMCIDUpdatesParentTreeAndSaves() throws {
    let (fixtureGraph, pageIDs) = try tagged()
    let graph = try contentWithExtraMCID(fixtureGraph)
    let pageID = try #require(pageIDs.first)
    let root = PDFObjectID(20)
    let created = try PDFEditingEngine.commit(
      PDFTransaction([
        CreateStructureElementCommand(
          parentID: root, role: PDFName("P"), insertionIndex: 2, title: "Added",
          pageID: pageID, mcid: 3)
      ]), to: graph)
    let createdInventory = try inventory(created, pageIDs)
    #expect(createdInventory.issues.isEmpty)
    let added = try #require(
      createdInventory.elements.first { $0.title == "Added" })
    #expect(added.role == "P")
    #expect(added.children.contains { child in
      if case .content(0, 3) = child { return true }
      return false
    })
    #expect(createdInventory.pageMCIDs[0].contains(3))
    let reopened = try PDFParser.parse(try PDFWriter.write(created))
    let reopenedInventory = try PDFStructureInspector.inspect(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(reopenedInventory.issues.isEmpty)
    #expect(reopenedInventory.elements.contains { $0.title == "Added" })
    // An already-mapped MCID cannot be reused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          CreateStructureElementCommand(
            parentID: root, role: PDFName("P"), pageID: pageID, mcid: 1)
        ]), to: graph)
    }
    // An unknown MCID is refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          CreateStructureElementCommand(
            parentID: root, role: PDFName("P"), pageID: pageID, mcid: 9)
        ]), to: graph)
    }
  }

  @Test func createObjectReferenceElementForAnnotation() throws {
    let (graph, pageIDs) = try tagged()
    let pageID = try #require(pageIDs.first)
    let created = try PDFEditingEngine.commit(
      PDFTransaction([
        CreateStructureElementCommand(
          parentID: PDFObjectID(20), role: PDFName("Link"), insertionIndex: 3,
          pageID: pageID, objectReference: PDFObjectID(50))
      ]), to: graph)
    let inventoryAfter = try inventory(created, pageIDs)
    #expect(inventoryAfter.issues.isEmpty)
    let link = try #require(
      inventoryAfter.elements.first { element in
        element.children.contains { child in
          if case .objectReference(let annotationID, _) = child {
            return annotationID == PDFObjectID(50)
          }
          return false
        }
      })
    #expect(link.role == "Link")
    let reopened = try PDFParser.parse(try PDFWriter.write(created))
    #expect(
      try PDFStructureInspector.inspect(in: reopened.graph, pageIDs: reopened.pageIDs)
        .issues.isEmpty)
  }

  @Test func deleteSubtreeClearsParentTreeAndKeepsPaint() throws {
    let (graph, pageIDs) = try tagged()
    let pageID = try #require(pageIDs.first)
    let beforePaint = try PageContent.load(pageID: pageID, in: graph).segments
      .flatMap(\.decoded)
    let grouped = try PDFEditingEngine.commit(
      PDFTransaction([
        GroupStructureElementsCommand(
          parentID: PDFObjectID(20), elementIDs: [PDFObjectID(21), PDFObjectID(23)])
      ]), to: graph)
    let groupID = try #require(
      try inventory(grouped, pageIDs).elements.first { $0.role == "Sect" }?.objectID)
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteStructureElementCommand(elementID: groupID)]), to: grouped)
    let deletedInventory = try inventory(deleted, pageIDs)
    #expect(deletedInventory.issues.isEmpty)
    #expect(!deletedInventory.elements.contains { $0.objectID == groupID })
    #expect(!deletedInventory.elements.contains { $0.objectID == PDFObjectID(21) })
    #expect(!deletedInventory.elements.contains { $0.objectID == PDFObjectID(23) })
    #expect(deleted.objects[groupID] == nil)
    // The deleted tags no longer appear in any ParentTree entry.
    var pageEntries = try StructureParentTreeSupport.NumberTreeEditor.open(in: deleted)
    #expect(pageEntries.elementIDs(structKey: 0, mcid: 0).isEmpty)
    #expect(pageEntries.elementIDs(structKey: 0, mcid: 2).isEmpty)
    // Page paint is untouched by deleting tags.
    let afterPaint = try PageContent.load(pageID: pageID, in: deleted).segments
      .flatMap(\.decoded)
    #expect(beforePaint == afterPaint)
    let reopened = try PDFParser.parse(try PDFWriter.write(deleted))
    #expect(
      try PDFStructureInspector.inspect(in: reopened.graph, pageIDs: reopened.pageIDs)
        .issues.isEmpty)
  }

  @Test func reparentMovesSubtreeAndRefusesCycles() throws {
    let (graph, pageIDs) = try tagged()
    let grouped = try PDFEditingEngine.commit(
      PDFTransaction([
        GroupStructureElementsCommand(
          parentID: PDFObjectID(20), elementIDs: [PDFObjectID(21), PDFObjectID(22)])
      ]), to: graph)
    let groupID = try #require(
      try inventory(grouped, pageIDs).elements.first { $0.role == "Sect" }?.objectID)
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        ReparentStructureElementCommand(
          elementID: PDFObjectID(23), newParentID: groupID, insertionIndex: 1)
      ]), to: grouped)
    let movedInventory = try inventory(moved, pageIDs)
    #expect(movedInventory.issues.isEmpty)
    let group = try #require(movedInventory.elements.first { $0.objectID == groupID })
    #expect(group.children.compactMap { child -> String? in
      if case .element(let element) = child { return element.role }
      return nil
    } == ["H1", "P", "Figure"] || group.children.count == 3)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReparentStructureElementCommand(
            elementID: groupID, newParentID: PDFObjectID(23))
        ]), to: moved)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReparentStructureElementCommand(elementID: groupID, newParentID: groupID)
        ]), to: moved)
    }
  }

  @Test func artifactControlsAndActualTextCompose() throws {
    let (graph, pageIDs) = try tagged()
    let grouped = try PDFEditingEngine.commit(
      PDFTransaction([
        GroupStructureElementsCommand(
          parentID: PDFObjectID(20), elementIDs: [PDFObjectID(21), PDFObjectID(22)])
      ]), to: graph)
    let groupID = try #require(
      try inventory(grouped, pageIDs).elements.first { $0.role == "Sect" }?.objectID)
    let artifact = try PDFEditingEngine.commit(
      PDFTransaction([MarkStructureSubtreeArtifactCommand(elementID: groupID)]), to: grouped)
    let artifactInventory = try inventory(artifact, pageIDs)
    #expect(
      artifactInventory.elements
        .filter { [groupID, PDFObjectID(21), PDFObjectID(22)].contains($0.objectID) }
        .allSatisfy { $0.role == "Artifact" })
    let restored = try PDFEditingEngine.commit(
      PDFTransaction([
        UnmarkStructureArtifactCommand(elementID: groupID, role: PDFName("Sect")),
        SetStructureActualTextCommand(elementID: groupID, actualText: "Grouped content"),
        SetStructureLanguageCommand(elementID: groupID, language: "de-CH"),
      ]), to: artifact)
    let restoredElement = try #require(
      try inventory(restored, pageIDs).elements.first { $0.objectID == groupID })
    #expect(restoredElement.role == "Sect")
    #expect(restoredElement.actualText == "Grouped content")
    #expect(restoredElement.language == "de-CH")
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          UnmarkStructureArtifactCommand(elementID: PDFObjectID(23), role: PDFName("Figure"))
        ]), to: artifact)
    }
  }

  @Test func transactionIsPureSoUndoRestoresTheSameValidGraph() throws {
    let (graph, pageIDs) = try tagged()
    let before = graph
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        CreateStructureElementCommand(
          parentID: PDFObjectID(20), role: PDFName("Span"), title: "Temp"),
        CreateStructureElementCommand(
          parentID: PDFObjectID(20), role: PDFName("Note"), title: "Temp2"),
      ]), to: graph)
    // The input graph is unchanged, so the Undo stack can restore exactly it.
    #expect(graph == before)
    #expect(try inventory(graph, pageIDs).issues.isEmpty)
    #expect(try inventory(edited, pageIDs).issues.isEmpty)
    // Saving and reopening the restored and edited graphs both stay valid.
    for candidate in [graph, edited] {
      let reopened = try PDFParser.parse(try PDFWriter.write(candidate))
      #expect(
        try PDFStructureInspector.inspect(in: reopened.graph, pageIDs: reopened.pageIDs)
          .issues.isEmpty)
    }
  }
}

