import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-04 session evidence: Freeze Static Results is one undoable transaction
/// that restores the exact previous bytes.
@Suite("Form rule sessions")
struct FormRulesSessionTests {
  @Test func freezeIsOneUndoableSessionStep() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    let pageID = try #require(session.pageIDs.first)
    try session.apply(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "A"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 560, 272, 584], name: "B"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 520, 272, 544], name: "C"),
        SetFormTextCommand(fieldName: "A", text: "1"),
        SetFormTextCommand(fieldName: "B", text: "2"),
        SetFormFieldCalculationCommand(fieldName: "C", calculation: .sum(fields: ["A", "B"])),
      ]))
    let baseline = try session.bytesForSave()
    try session.apply(PDFTransaction([FreezeFormResultsCommand()]))
    let frozen = try #require(session.currentGraph)
    let fields = try FormInventory.fields(in: frozen, pageIDs: [pageID])
    #expect(fields.first(where: { $0.name == "C" })?.stringValue == "3")
    #expect(session.undo())
    #expect(try session.bytesForSave() == baseline)
    let restored = try #require(session.currentGraph)
    let restoredFields = try FormInventory.fields(in: restored, pageIDs: [pageID])
    #expect(restoredFields.first(where: { $0.name == "C" })?.stringValue == nil)
    #expect(session.redo())
    let redone = try #require(session.currentGraph)
    let redoneFields = try FormInventory.fields(in: redone, pageIDs: [pageID])
    #expect(redoneFields.first(where: { $0.name == "C" })?.stringValue == "3")
  }
}
