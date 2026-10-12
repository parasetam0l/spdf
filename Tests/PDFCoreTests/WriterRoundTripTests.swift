import Foundation
import Testing

@testable import PDFCore

/// P09-021/P09-027: the full rewrite drops old revisions without implying
/// secure redaction.
@Suite("Full rewrite semantics")
struct WriterRoundTripTests {
  @Test func fullRewriteDropsRevisionsButKeepsUnreachableObjects() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/incremental-update.pdf")
    let data = try Data(contentsOf: url)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.revisionCount == 2)
    // The rewrite is one revision: a single startxref, no /Prev chain.
    let rewritten = try PDFWriter.write(parsed.graph)
    let raw = String(decoding: rewritten, as: UTF8.self)
    #expect(raw.components(separatedBy: "startxref").count == 2)
    #expect(!raw.contains("/Prev"))
    let reparsed = try PDFParser.parse(rewritten)
    #expect(reparsed.revisionCount == 1)
    // ...but it is NOT a sanitization: an unreachable object carrying a
    // secret survives in the output bytes.
    var seeded = parsed.graph
    seeded.objects[PDFObjectID(900)] = .string(Data("UNREACHABLE-SECRET".utf8))
    let seededBytes = try PDFWriter.write(seeded)
    let seededRaw = String(decoding: seededBytes, as: UTF8.self)
    #expect(seededRaw.contains("900 0 obj"))
    // The writer hex-encodes the string; the secret is present verbatim in
    // encoded form and parses back to the exact value — a rewrite is not a
    // sanitization.
    #expect(seededRaw.contains("<554E524541434841424C452D534543524554>"))
    let resanitized = try PDFParser.parse(seededBytes)
    #expect(resanitized.graph.objects[PDFObjectID(900)] == .string(Data("UNREACHABLE-SECRET".utf8)))
  }
}

extension WriterRoundTripTests {
  /// P09-023: linearized input refuses a plain rewrite; the explicit drop
  /// removes the unreferenced hints dictionary and the rewrite succeeds
  /// with pages intact.
  @Test func linearizedInputDropsHintsExplicitly() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/one-page.pdf")
    let parsed = try PDFParser.parse(Data(contentsOf: url))
    var graph = parsed.graph
    graph.objects[PDFObjectID(900)] = .dictionary([
      PDFName("Linearized"): .real(1.0),
      PDFName("L"): .integer(1000),
      PDFName("H"): .array([.integer(10), .integer(20)]),
      PDFName("O"): .integer(5),
      PDFName("E"): .integer(800),
      PDFName("N"): .integer(1),
      PDFName("T"): .integer(700),
    ])
    // The default refuses so stale hints never slip through silently.
    #expect(throws: PDFError.self) { try PDFWriter.write(graph) }
    let (cleaned, dropped) = PDFWriter.droppingLinearization(graph)
    #expect(dropped)
    #expect(cleaned.objects[PDFObjectID(900)] == nil)
    let written = try PDFWriter.write(cleaned, droppingLinearization: true)
    let raw = String(decoding: written, as: UTF8.self)
    #expect(!raw.contains("/Linearized"))
    let reparsed = try PDFParser.parse(written)
    #expect(reparsed.pageIDs.count == 1)
    // A referenced hints dictionary is kept, never silently unlinked.
    var linked = parsed.graph
    linked.objects[PDFObjectID(901)] = .dictionary([
      PDFName("Linearized"): .real(1.0), PDFName("Next"): .reference(PDFObjectID(1)),
    ])
    linked.objects[PDFObjectID(902)] = .dictionary([
      PDFName("Provenance"): .reference(PDFObjectID(901))
    ])
    let (kept, keptDropped) = PDFWriter.droppingLinearization(linked)
    #expect(!keptDropped)
    #expect(kept.objects[PDFObjectID(901)] != nil)
  }
}
