import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-06: updating an applied mark set is one undoable session edit and does
/// not disturb unrelated content or other mark sets.
@Suite("Page mark sessions")
struct PageMarkSessionTests {
  private func pageText(_ graph: PDFGraph, pageID: PDFObjectID) throws -> String {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
  }

  @Test func updatingAMarkSetIsOneUndoStep() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.threePages()))
    let pages = session.pageIDs
    try session.apply(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: pages,
          mark: .header(text: "STATE-ONE", style: AddedTextStyle(size: 10)),
          groupID: "set-a"),
        AddRepeatedMarkCommand(
          pageIDs: [pages[1]],
          mark: .footer(text: "KEEP-STATE", style: AddedTextStyle(size: 8)),
          groupID: "set-b"),
      ]))
    let afterAdd = try session.bytesForSave()
    try session.apply(
      PDFTransaction([
        UpdateRepeatedMarkCommand(
          groupID: "set-a", allPageIDs: pages, pageIDs: [pages[0], pages[2]],
          mark: .footer(text: "STATE-TWO", style: AddedTextStyle(size: 9)),
          margin: 24, placement: .bottomRight)
      ]))
    #expect(session.isDirty)
    let afterUpdate = try session.bytesForSave()
    #expect(afterUpdate != afterAdd)
    let updated = try PDFParser.parse(afterUpdate)
    let firstText = try pageText(updated.graph, pageID: updated.pageIDs[0])
    #expect(firstText.contains("STATE-TWO"))
    #expect(!firstText.contains("STATE-ONE"))
    let secondText = try pageText(updated.graph, pageID: updated.pageIDs[1])
    #expect(!secondText.contains("STATE-TWO"))
    #expect(secondText.contains("KEEP-STATE"))
    #expect(try pageText(updated.graph, pageID: updated.pageIDs[2]).contains("STATE-TWO"))
    let group = try #require(
      RepeatedMarkInventory.groups(in: updated.graph, pageIDs: updated.pageIDs)
        .first { $0.groupID == "set-a" })
    #expect(group.spec?.placement == .bottomRight)
    #expect(group.spec?.margin == 24)

    // One Undo restores the exact previous revision; one Redo reapplies it.
    #expect(session.undo())
    #expect(try session.bytesForSave() == afterAdd)
    #expect(session.redo())
    #expect(try session.bytesForSave() == afterUpdate)
  }

  @Test func removingAnUpdatedSetLeavesOtherSetsIntact() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.threePages()))
    let pages = session.pageIDs
    try session.apply(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [pages[0]],
          mark: .header(text: "FIRST", style: AddedTextStyle(size: 10)),
          groupID: "first"),
        AddRepeatedMarkCommand(
          pageIDs: [pages[0]],
          mark: .footer(text: "SECOND", style: AddedTextStyle(size: 10)),
          groupID: "second"),
      ]))
    try session.apply(
      PDFTransaction([
        UpdateRepeatedMarkCommand(
          groupID: "first", allPageIDs: pages, pageIDs: [pages[0]],
          mark: .header(text: "FIRST-UPDATED", style: AddedTextStyle(size: 10)))
      ]))
    let groups = RepeatedMarkInventory.groups(
      in: session.currentGraph!, pageIDs: pages)
    #expect(groups.count == 2)
    try session.apply(
      PDFTransaction([
        RemoveRepeatedMarkCommand(groupID: "first", pageIDs: [pages[0]])
      ]))
    let removed = try PDFParser.parse(try session.bytesForSave())
    let text = try pageText(removed.graph, pageID: removed.pageIDs[0])
    #expect(!text.contains("FIRST-UPDATED"))
    #expect(text.contains("SECOND"))
  }
}
