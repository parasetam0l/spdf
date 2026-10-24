import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-06: applied mark sets are discoverable and removable without touching
/// unrelated content or other marks.
@Suite("Repeated mark removal")
struct RepeatedMarkRemovalTests {
  private func text(_ graph: PDFGraph, pageID: PDFObjectID) throws -> String {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
  }

  @Test func markSetIsFoundAndRemovedAsOneUnit() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let first = parsed.pageIDs[0]
    let second = parsed.pageIDs[1]
    let third = parsed.pageIDs[2]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddRepeatedMarkCommand(
          pageIDs: [first, second],
          mark: .header(text: "REMOVE-ME", style: AddedTextStyle(size: 10)),
          groupID: "group-a"),
        AddRepeatedMarkCommand(
          pageIDs: [second],
          mark: .footer(text: "KEEP-ME", style: AddedTextStyle(size: 10)),
          groupID: "group-b"),
      ]), to: parsed.graph)
    let groups = RepeatedMarkInventory.groups(
      in: marked, pageIDs: parsed.pageIDs)
    #expect(groups.count == 2)
    #expect(groups.first { $0.groupID == "group-a" }?.pageIDs == [first, second])
    #expect(groups.first { $0.groupID == "group-a" }?.label.contains("Header") == true)

    let removed = try PDFEditingEngine.commit(
      PDFTransaction([
        RemoveRepeatedMarkCommand(groupID: "group-a", pageIDs: [first, second])
      ]), to: marked)
    #expect(try !text(removed, pageID: first).contains("REMOVE-ME"))
    #expect(try !text(removed, pageID: second).contains("REMOVE-ME"))
    #expect(try text(removed, pageID: second).contains("KEEP-ME"))
    #expect(try text(removed, pageID: third).contains("fixture"))
    #expect(RepeatedMarkInventory.groups(in: removed, pageIDs: parsed.pageIDs).count == 1)
  }

  @Test func removingAMissingMarkRefuses() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RemoveRepeatedMarkCommand(
            groupID: "missing", pageIDs: [parsed.pageIDs[0]])
        ]), to: parsed.graph)
    }
  }
}
