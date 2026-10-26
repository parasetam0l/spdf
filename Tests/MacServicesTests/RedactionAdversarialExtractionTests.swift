import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// RED-06 independent extractor cross-check: PDFKit must not recover any
/// protected seed from the distributed sanitized copy.
@Suite("Redaction adversarial extraction (RED-06)")
struct RedactionAdversarialExtractionTests {
  @Test func pdfKitCannotRecoverProtectedSeeds() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    let pageID = try #require(parsed.pageIDs.first)
    var store = RedactionMarkStore()
    _ = try store.add(kind: .page, pageID: pageID, pageIndex: 0, rects: [[0, 0, 612, 792]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let command = try #require(plan.command(marks: store.marks))
    let redacted = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let sanitized = try RedactionSanitizer.sanitize(in: redacted, policy: .secure)
    let data = try PDFWriter.write(sanitized.graph)
    let document = try #require(PDFDocument(data: data))
    #expect(document.pageCount == 1)
    let extracted = document.string ?? ""
    for seed in fixture.seeds {
      #expect(!extracted.contains(seed), Comment(rawValue: "PDFKit text retains " + seed))
    }
    for (key, value) in document.documentAttributes ?? [:] {
      let description = String(describing: value)
      for seed in fixture.seeds where description.contains(seed) {
        Issue.record(Comment(rawValue: "PDFKit attribute \(key) retains " + seed))
      }
    }
    let raw = String(decoding: data, as: UTF8.self)
    for seed in fixture.seeds {
      #expect(!raw.contains(seed), Comment(rawValue: "bytes retain " + seed))
    }
  }
}

