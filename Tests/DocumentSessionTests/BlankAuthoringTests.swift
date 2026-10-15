import DocumentSession
import Foundation
import PDFCore
import PDFEditing
import PDFKit
import Testing

@Suite("Blank document authoring")
struct BlankAuthoringTests {
  @Test func addedPageTextSavesAsEditableContentAndUndoRestoresBlank() throws {
    let original = try BlankPDF.data()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.apply(PDFTransaction([
      AddTextObjectCommand(pageID: session.pageIDs[0], rect: [48, 650, 400, 680],
        text: "New PDF content")
    ]))
    let written = try session.bytesForSave()
    let independent = try #require(PDFDocument(data: written))
    #expect(independent.pageCount == 1)
    #expect(independent.string?.contains("New PDF content") == true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("new.pdf")
    try VerifiedFileWriter.write(written, to: destination,
      expectedGraph: try #require(session.currentGraph))
    #expect(try Data(contentsOf: destination) == written)
    #expect(independent.page(at: 0)?.annotations.isEmpty == true)
    try session.replaceText(pageAt: 0, runIndex: 0, with: "Edited PDF content")
    #expect(PDFDocument(data: try session.bytesForSave())?.string?.contains("Edited PDF content") == true)
    #expect(session.undo())
    #expect(try session.bytesForSave() == written)
    #expect(session.undo())
    #expect(try session.bytesForSave() == original)
    #expect(session.redo())
    #expect(try session.bytesForSave() == written)
  }
}
