import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-09: bookmark authoring.
@Suite("Outline authoring")
struct OutlineAuthoringTests {
  @Test func addAndRemoveBookmarksRoundTrip() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let second = parsed.pageIDs[1]
    let added = try PDFEditingEngine.commit(
      PDFTransaction([AddBookmarkCommand(title: "Chapter Two", pageID: second)]),
      to: parsed.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(added))
    let items = PDFOutlineInventory.items(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(items.count == 1)
    #expect(items[0].title == "Chapter Two")
    #expect(items[0].pageIndex == 1)
    let bookmarkID = try #require(items[0].objectID)

    let removed = try PDFEditingEngine.commit(
      PDFTransaction([RemoveBookmarkCommand(objectID: bookmarkID)]),
      to: reopened.graph)
    let after = try PDFParser.parse(try PDFWriter.write(removed))
    #expect(PDFOutlineInventory.items(in: after.graph, pageIDs: after.pageIDs).isEmpty)
  }

  @Test func secondBookmarkKeepsTheFirst() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let first = try PDFEditingEngine.commit(
      PDFTransaction([
        AddBookmarkCommand(title: "One", pageID: parsed.pageIDs[0]),
        AddBookmarkCommand(title: "Two", pageID: parsed.pageIDs[2]),
      ]), to: parsed.graph)
    let items = PDFOutlineInventory.items(in: first, pageIDs: parsed.pageIDs)
    #expect(items.count == 2)
    guard items.count == 2 else { return }
    #expect(items.map(\.title) == ["One", "Two"])
    #expect(items.map(\.pageIndex) == [0, 2])
    let secondID = try #require(items[1].objectID)
    let removed = try PDFEditingEngine.commit(
      PDFTransaction([RemoveBookmarkCommand(objectID: secondID)]), to: first)
    #expect(
      PDFOutlineInventory.items(in: removed, pageIDs: parsed.pageIDs).map(\.title)
        == ["One"])
  }

  @Test func bookmarkTitleAndDestinationCanBeEdited() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let added = try PDFEditingEngine.commit(
      PDFTransaction([
        AddBookmarkCommand(title: "Old", pageID: parsed.pageIDs[0])
      ]), to: parsed.graph)
    let item = try #require(
      PDFOutlineInventory.items(in: added, pageIDs: parsed.pageIDs).first)
    let objectID = try #require(item.objectID)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        EditBookmarkCommand(
          objectID: objectID, title: "New", pageID: parsed.pageIDs[2])
      ]), to: added)
    let reopened = try PDFParser.parse(try PDFWriter.write(edited))
    let updated = PDFOutlineInventory.items(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(updated.count == 1)
    #expect(updated[0].title == "New")
    #expect(updated[0].pageIndex == 2)
  }

  @Test func bookmarksReorderWithinSiblings() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let added = try PDFEditingEngine.commit(
      PDFTransaction([
        AddBookmarkCommand(title: "A", pageID: parsed.pageIDs[0]),
        AddBookmarkCommand(title: "B", pageID: parsed.pageIDs[1]),
        AddBookmarkCommand(title: "C", pageID: parsed.pageIDs[2]),
      ]), to: parsed.graph)
    var items = PDFOutlineInventory.items(in: added, pageIDs: parsed.pageIDs)
    #expect(items.map(\.title) == ["A", "B", "C"])
    let cID = try #require(items[2].objectID)
    let movedUp = try PDFEditingEngine.commit(
      PDFTransaction([MoveBookmarkCommand(objectID: cID, direction: .up)]), to: added)
    items = PDFOutlineInventory.items(in: movedUp, pageIDs: parsed.pageIDs)
    #expect(items.map(\.title) == ["A", "C", "B"])
    let aID = try #require(items[0].objectID)
    let movedDown = try PDFEditingEngine.commit(
      PDFTransaction([MoveBookmarkCommand(objectID: aID, direction: .down)]), to: movedUp)
    let reopened = try PDFParser.parse(try PDFWriter.write(movedDown))
    items = PDFOutlineInventory.items(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(items.map(\.title) == ["C", "A", "B"])
    #expect(items.map(\.pageIndex) == [2, 0, 1])
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([MoveBookmarkCommand(objectID: cID, direction: .up)]),
        to: movedDown)
    }
  }

  @Test func bookmarkNestAndOutdentPreserveHierarchy() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let added = try PDFEditingEngine.commit(
      PDFTransaction([
        AddBookmarkCommand(title: "Chapter", pageID: parsed.pageIDs[0]),
        AddBookmarkCommand(title: "Section", pageID: parsed.pageIDs[1]),
      ]), to: parsed.graph)
    var items = PDFOutlineInventory.items(in: added, pageIDs: parsed.pageIDs)
    let sectionID = try #require(items[1].objectID)
    let nested = try PDFEditingEngine.commit(
      PDFTransaction([NestBookmarkCommand(objectID: sectionID)]), to: added)
    items = PDFOutlineInventory.items(in: nested, pageIDs: parsed.pageIDs)
    #expect(items.count == 1)
    #expect(items[0].title == "Chapter")
    #expect(items[0].children.map(\.title) == ["Section"])

    let outdented = try PDFEditingEngine.commit(
      PDFTransaction([OutdentBookmarkCommand(objectID: sectionID)]), to: nested)
    items = PDFOutlineInventory.items(in: outdented, pageIDs: parsed.pageIDs)
    #expect(items.map(\.title) == ["Chapter", "Section"])
    #expect(items[0].children.isEmpty)
    let reopened = try PDFParser.parse(try PDFWriter.write(outdented))
    #expect(
      PDFOutlineInventory.items(in: reopened.graph, pageIDs: reopened.pageIDs).map(\.title)
        == ["Chapter", "Section"])
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([OutdentBookmarkCommand(objectID: sectionID)]), to: outdented)
    }
  }

  @Test func invalidPageAndMissingBookmarkAreRefused() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          AddBookmarkCommand(title: "Missing", pageID: PDFObjectID(999))
        ]), to: parsed.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RemoveBookmarkCommand(objectID: PDFObjectID(999))]),
        to: parsed.graph)
    }
  }
}
