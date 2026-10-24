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
