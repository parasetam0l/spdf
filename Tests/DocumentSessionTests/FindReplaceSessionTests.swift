import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

@Suite("Find and replace session")
struct FindReplaceSessionTests {
  @Test func previewedReplacementsCommitAsOneUndoableSessionEdit() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let pageIDs = session.pageIDs
    let preview = try FindReplace.preview(
      FindReplaceRequest(
        scope: .document, pageIDs: pageIDs, currentPageIndex: 0,
        query: "fixture", replacement: "fix"),
      in: try #require(session.currentGraph))
    #expect(preview.eligibleCount == 3)
    let command = try #require(preview.command)
    try session.apply(PDFTransaction([command]))
    let edited = try session.bytesForSave()
    #expect(edited != original)
    #expect(try session.undo())
    #expect(try session.bytesForSave() == original)
    #expect(try session.redo())
    #expect(try session.bytesForSave() == edited)
  }
}
