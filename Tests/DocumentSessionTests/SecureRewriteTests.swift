import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// SAF-02 evidence: a redaction or sanitize command forces a verified full
/// rewrite, prunes now-unreachable objects, and never leaves the removed
/// content in an earlier revision. Ordinary edits keep the incremental path.
@Suite("Secure rewrite saves")
struct SecureRewriteTests {
  /// Seeds an object that only the pre-redaction graph references, so the
  /// secure rewrite must prune it rather than serialize it again.
  private struct SeedUnreachableObject: PDFEditCommand {
    var name: String { "Seed Unreachable Object" }
    func validate(in graph: PDFGraph) throws {}
    func apply(to graph: PDFGraph) throws -> PDFGraph {
      var graph = graph
      graph.objects[PDFObjectID(900)] = .dictionary([
        PDFName("Marker"): .string(Data("pre-redaction-orphan".utf8))
      ])
      return graph
    }
  }

  @Test func redactionForcesFullRewriteAndDropsEarlierContent() throws {
    let original = try PDFFixtures.textWidthsPages()
    let parsed = try PDFParser.parse(original)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.apply(PDFTransaction([SeedUnreachableObject()]))
    try session.apply(
      PDFTransaction([
        RedactRegionsCommand(pageID: parsed.pageIDs[0], regions: [[40, 705, 95, 735]])
      ]))

    #expect(session.requiresSecureRewrite)
    let bytes = try session.bytesForSave()
    #expect(bytes.range(of: Data("/Prev".utf8)) == nil)
    #expect(!bytes.starts(with: original))
    let reopened = try PDFParser.parse(bytes)
    // The orphan from the earlier graph state is pruned, not re-serialized.
    #expect(reopened.graph.objects[PDFObjectID(900)] == nil)
    let layout = try PageTextLayout.build(pageID: reopened.pageIDs[0], in: reopened.graph)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: " ")
    #expect(!text.contains("AB"))
    #expect(session.noteSaved())
    #expect(!session.requiresSecureRewrite)
  }

  @Test func undoRestoresTheIncrementalPolicyAndRedoReappliesIt() throws {
    let original = try PDFFixtures.textWidthsPages()
    let parsed = try PDFParser.parse(original)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.apply(
      PDFTransaction([
        RedactRegionsCommand(pageID: parsed.pageIDs[0], regions: [[40, 705, 95, 735]])
      ]))
    #expect(session.requiresSecureRewrite)

    #expect(session.undo())
    #expect(!session.requiresSecureRewrite)
    #expect(try session.bytesForSave() == original)

    #expect(session.redo())
    #expect(session.requiresSecureRewrite)
    let rewritten = try session.bytesForSave()
    #expect(!rewritten.starts(with: original))
    #expect(rewritten.range(of: Data("/Prev".utf8)) == nil)
  }

  @Test func ordinaryEditKeepsIncrementalSave() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.rotatePage(at: 0, byDegrees: 90)

    #expect(!session.requiresSecureRewrite)
    let bytes = try session.bytesForSave()
    #expect(bytes.starts(with: original))
    #expect(bytes.range(of: Data("/Prev".utf8)) != nil)
  }

  @Test func saveAfterRedactionReturnsToIncrementalForLaterEdits() throws {
    let original = try PDFFixtures.textWidthsPages()
    let parsed = try PDFParser.parse(original)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.apply(
      PDFTransaction([
        RedactRegionsCommand(pageID: parsed.pageIDs[0], regions: [[40, 705, 95, 735]])
      ]))
    let rewritten = try session.bytesForSave()
    #expect(session.noteSaved())

    try session.rotatePage(at: 0, byDegrees: 90)
    let incremental = try session.bytesForSave()
    // The post-redaction base is clean, so later ordinary edits may append.
    #expect(incremental.starts(with: rewritten))
    #expect(incremental.range(of: Data("/Prev".utf8)) != nil)
  }
}
