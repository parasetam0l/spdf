import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P17-021: importing pages from another document is one transaction with
/// one undo entry; undo restores the original bytes exactly.
@Suite("Page import session")
struct ImportPagesSessionTests {
  @Test func importIsOneUndoStepRestoringExactBytes() throws {
    // P17-021 with the session: the whole import is one transaction, one
    // undo entry, and undo restores the original bytes exactly.
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let importedBytes = try PDFFixtures.textWidthsPages()
    try session.apply(
      PDFTransaction([
        ImportPagesCommand(documentBytes: importedBytes, pageIndices: [0], atIndex: 1)
      ]))
    #expect(session.pageIDs.count == 4)
    #expect(session.isDirty)
    // Imported pages do not exist before the commit: the change set is
    // conservative (nil = all pages).
    #expect(session.changedPageIndices() == nil)
    let edited = try session.bytesForSave()
    #expect(edited != original)
    #expect(try PDFParser.parse(edited).pageIDs.count == 4)

    #expect(session.undo())
    #expect(try session.bytesForSave() == original)
    #expect(session.pageIDs.count == 3)
    #expect(!session.isDirty)
    #expect(session.redo())
    #expect(session.pageIDs.count == 4)
  }
}
