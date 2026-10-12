import Foundation
import Testing

@testable import PDFCore

/// P06-018/P06-019: conflicting entries refuse, revision counts surface,
/// and prefix views show older revisions for inspection.
@Suite("Revision chain views")
struct RevisionViewTests {
  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name).pdf")
    return try Data(contentsOf: url)
  }

  private func text(of data: Data, revision: Int? = nil) throws -> String {
    let parsed =
      if let revision {
        try PDFParser.parse(data, throughRevision: revision)
      } else {
        try PDFParser.parse(data)
      }
    guard case .dictionary(let page)? = parsed.graph.objects[parsed.pageIDs[0]],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .stream(let stream)? = parsed.graph.objects[contentID]
    else {
      Issue.record("content stream missing")
      return ""
    }
    return String(decoding: try PDFFilters.decoded(stream), as: UTF8.self)
  }

  @Test func revisionCountsSurfaceAndDuplicatesRefuse() throws {
    let single = try PDFParser.parse(Data(try fixture("one-page")))
    #expect(single.revisionCount == 1)
    let incremental = try PDFParser.parse(Data(try fixture("incremental-update")))
    #expect(incremental.revisionCount == 2)
    // A duplicate definition inside one xref section conflicts loudly.
    let bad = [UInt8](
      "%PDF-1.7\n1 0 obj\n1\nendobj\nxref\n0 2\n0000000000 65535 f \n0000000009 00000 n \n0000000009 00000 n \ntrailer\n<< /Size 2 /Root 1 0 R >>\nstartxref\n26\n%%EOF"
        .utf8)
    #expect(throws: PDFError.self) { try PDFParser.parse(Data(bad)) }
  }

  @Test func prefixViewsShowOlderRevisions() throws {
    let data = try fixture("incremental-update")
    #expect(try text(of: data, revision: 1).contains("base revision"))
    #expect(!(try text(of: data, revision: 1)).contains("updated revision"))
    #expect(try text(of: data, revision: 2).contains("updated revision"))
    let first = try PDFParser.parse(data, throughRevision: 1)
    let full = try PDFParser.parse(data)
    #expect(first.revisionCount == 1)
    #expect(full.revisionCount == 2)
    // The base revision still carries its own document info.
    #expect(first.graph.objects[PDFObjectID(6)] != nil)
    #expect(throws: PDFError.self) { try PDFParser.parse(data, throughRevision: 0) }
    #expect(throws: PDFError.self) { try PDFParser.parse(data, throughRevision: 3) }
  }

  @Test func redactionHistoryIsVisiblePerRevision() throws {
    let data = try fixture("redaction-pages")
    #expect(try PDFParser.parse(data).revisionCount == 2)
    // Revision 1 predates the black rectangle and the annotation.
    let first = try PDFParser.parse(data, throughRevision: 1)
    #expect(first.graph.objects[PDFObjectID(6)] == nil)
    let firstText = try text(of: data, revision: 1)
    #expect(firstText.contains("SECRET-TOKEN-123"))
    #expect(!firstText.contains("re f"))
  }
}
