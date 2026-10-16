import DocumentSession
import PDFCore
import PDFFixtures
import PDFKit
import Testing

@Suite("Compressed source save interop")
struct CompressedSourceSaveTests {
  @Test func streamBasedSourceSavesAndReopensAcrossTwoEditsInPDFKit() throws {
    let source = try PDFFixtures.xrefStreamPages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: source))
    #expect(try session.bytesForSave() == source)
    try session.rotatePage(at: 0, byDegrees: 90)
    let first = try session.bytesForSave()
    let reader = try #require(PDFDocument(data: first))
    #expect(reader.pageCount == 2)
    #expect(reader.page(at: 0)?.rotation == 90)
    #expect(reader.string?.contains("xref-stream fixture - page 2") == true)
    session.noteSaved()
    #expect(try session.bytesForSave() == first)
    try session.rotatePage(at: 1, byDegrees: 180)
    let second = try session.bytesForSave()
    let reopened = try #require(PDFDocument(data: second))
    #expect(reopened.page(at: 0)?.rotation == 90)
    #expect(reopened.page(at: 1)?.rotation == 180)
    #expect(reopened.string?.contains("xref-stream fixture - page 1") == true)
    #expect(second.starts(with: first))
    #expect(session.undo())
    #expect(try session.bytesForSave() == first)
  }
}
