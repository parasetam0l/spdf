import DocumentSession
import PDFCore
import PDFFixtures
import PDFKit
import Testing

@Suite("Compressed source save interop")
struct CompressedSourceSaveTests {
  @Test func linearizedSourceRewritesWithoutStaleHintsAndKeepsExactUndo() throws {
    var graph = try PDFParser.parse(PDFFixtures.xrefStreamPages()).graph
    let hintID = PDFObjectID(30)
    graph.objects[hintID] = .dictionary([PDFName("Linearized"): .real(1), PDFName("L"): .integer(100)])
    let source = try PDFWriter.serialize(graph)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: source))
    #expect(try session.bytesForSave() == source)
    try session.rotatePage(at: 0, byDegrees: 90)
    let first = try session.bytesForSave()
    #expect(!first.starts(with: source))
    #expect(try PDFParser.parse(first).graph.objects[hintID] == nil)
    #expect(PDFDocument(data: first)?.page(at: 0)?.rotation == 90)
    #expect(session.currentGraph?.objects[hintID] == graph.objects[hintID])
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: destination) }
    try VerifiedFileWriter.write(first, to: destination, expectedGraph: #require(session.graphForSaveVerification))
    #expect(try Data(contentsOf: destination) == first)
    session.noteSaved()
    #expect(try session.bytesForSave() == first)
    try session.rotatePage(at: 1, byDegrees: 180)
    let second = try session.bytesForSave()
    #expect(second.starts(with: first))
    #expect(try PDFParser.parse(second).graph.objects[hintID] == nil)
    #expect(PDFDocument(data: second)?.page(at: 1)?.rotation == 180)
    #expect(session.undo())
    #expect(try session.bytesForSave() == first)
    #expect(session.undo())
    #expect(try session.bytesForSave() == source)
    #expect(session.graphForSaveVerification?.objects[hintID] == graph.objects[hintID])
  }

  @Test func linearizationCleanupDoesNotBypassReferencedHintsOrSignatures() throws {
    for signed in [false, true] {
      var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
      let hintID = PDFObjectID(30)
      graph.objects[hintID] = .dictionary([PDFName("Linearized"): .real(1)])
      if signed {
        graph.objects[PDFObjectID(31)] = .dictionary([PDFName("Type"): .name(PDFName("Sig")),
          PDFName("ByteRange"): .array([.integer(0),.integer(1),.integer(2),.integer(1)])])
      } else {
        guard case .reference(let root)? = graph.trailer[PDFName("Root")],
          case .dictionary(var catalog)? = graph.objects[root] else { Issue.record("Missing catalog"); return }
        catalog[PDFName("ReferencedHint")] = .reference(hintID)
        graph.objects[root] = .dictionary(catalog)
      }
      let source = try PDFWriter.serialize(graph)
      let session = DocumentEditSession()
      session.load(try PDFSource(data: source))
      #expect(try session.bytesForSave() == source)
      try session.rotatePage(at: 0, byDegrees: 90)
      do {
        _ = try session.bytesForSave()
        Issue.record("Unsafe rewrite was accepted")
      } catch let error as PDFError { #expect(error.kind == .unsupported) }
      #expect(session.isDirty)
      #expect(session.undo())
      #expect(try session.bytesForSave() == source)
    }
  }

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
