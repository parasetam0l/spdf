import Foundation
import PDFCore
import PDFFixtures
import Testing

/// P09-019 evidence: incremental append with correct Prev/Size bookkeeping,
/// retained base bytes, shadowed deletions, and refusal of ineligible graphs.
@Suite("Incremental saves")
struct IncrementalSaveTests {
  @Test func incrementalAppendRetainsBaseBytesAndResolvesNewRevision() throws {
    let original = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(original)
    let pageID = parsed.pageIDs[0]
    var updated = parsed.graph
    guard case .dictionary(var page)? = updated.objects[pageID] else {
      Issue.record("Page missing")
      return
    }
    page[PDFName("Rotate")] = .integer(90)
    updated.objects[pageID] = .dictionary(page)

    let output = try PDFWriter.incrementalUpdate(from: parsed, to: updated)
    #expect(output.prefix(original.count) == original)
    let reopened = try PDFParser.parse(output)
    #expect(reopened.graph == updated)
    #expect(reopened.pageIDs == parsed.pageIDs)
    // The chain has the original pointer plus the appended one.
    var occurrences = 0
    var search = output.startIndex
    while let found = output.range(of: Data("startxref".utf8), in: search..<output.endIndex) {
      occurrences += 1
      search = found.upperBound
    }
    #expect(occurrences == 2)
  }

  @Test func incrementalFreeEntriesShadowAddedObjects() throws {
    let original = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(original)
    var added = parsed.graph
    added.objects[PDFObjectID(42)] = .dictionary([
      PDFName("Note"): .string(Data("incremental".utf8))
    ])
    added.trailer[PDFName("Size")] = .integer(43)
    let first = try PDFWriter.incrementalUpdate(from: parsed, to: added)
    let firstParsed = try PDFParser.parse(first)
    #expect(firstParsed.graph == added)

    var removed = firstParsed.graph
    removed.objects.removeValue(forKey: PDFObjectID(42))
    removed.trailer[PDFName("Size")] = .integer(43)
    let second = try PDFWriter.incrementalUpdate(from: firstParsed, to: removed)
    #expect(second.prefix(first.count) == first)
    let final = try PDFParser.parse(second)
    #expect(final.graph == removed)
    #expect(final.graph.objects[PDFObjectID(42)] == nil)
  }

  @Test func incrementalRefusesSignaturesLinearizedAndProtectedGraphs() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var signed = parsed.graph
    signed.objects[PDFObjectID(42)] = .dictionary([PDFName("Type"): .name(PDFName("Sig"))])
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.incrementalUpdate(from: parsed, to: signed)
    }
    var linearized = parsed.graph
    linearized.objects[PDFObjectID(43)] = .dictionary([PDFName("Linearized"): .integer(1)])
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.incrementalUpdate(from: parsed, to: linearized)
    }
    var protected = parsed.graph
    protected.trailer[PDFName("Encrypt")] = .dictionary([:])
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.incrementalUpdate(from: parsed, to: protected)
    }
  }
}
