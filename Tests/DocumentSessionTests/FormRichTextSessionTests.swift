import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-05 session evidence: a rich text fill is one undoable transaction and
/// restores the exact prior bytes.
@Suite("Form rich text sessions")
struct FormRichTextSessionTests {
  @Test func richFillIsOneUndoStepAndRestoresExactBytes() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    let pageID = try #require(session.pageIDs.first)
    try session.apply(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 372, 630], name: "Notes"),
        SetFormTextCommand(fieldName: "Notes", text: "old"),
      ]))
    let baseline = try session.bytesForSave()
    var value = FormRichTextValue.plain("Hello rich", style: FormRichTextStyle(fontSize: 12))
    value.runs = [
      FormRichTextRun(
        location: 0, length: 5,
        style: FormRichTextStyle(bold: true, fontSize: 16, color: [1, 0, 0]))
    ]
    try session.apply(PDFTransaction([SetFormRichTextCommand(fieldName: "Notes", value: value)]))
    let edited = try #require(session.currentGraph)
    let editedFields = try FormInventory.fields(in: edited, pageIDs: [pageID])
    #expect(editedFields.first(where: { $0.name == "Notes" })?.stringValue == "Hello rich")
    #expect(session.undo())
    #expect(try session.bytesForSave() == baseline)
    let restored = try #require(session.currentGraph)
    let restoredFields = try FormInventory.fields(in: restored, pageIDs: [pageID])
    #expect(restoredFields.first(where: { $0.name == "Notes" })?.stringValue == "old")
    #expect(session.redo())
    let redone = try #require(session.currentGraph)
    let redoneFields = try FormInventory.fields(in: redone, pageIDs: [pageID])
    #expect(redoneFields.first(where: { $0.name == "Notes" })?.stringValue == "Hello rich")
  }
}
