import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// RED-06: adversarial validation of irreversible outputs.
@Suite("Redaction adversarial (RED-06)")
struct RedactionAdversarialTests {
  static func redactedAndSanitized(
    _ fixture: RedactionAdversarialFixture
  ) throws -> (withOCR: PDFGraph, sanitized: PDFGraph, report: RedactionSanitizationReport) {
    let parsed = try PDFParser.parse(fixture.data)
    let pageID = try #require(parsed.pageIDs.first)
    var store = RedactionMarkStore()
    _ = try store.add(kind: .page, pageID: pageID, pageIndex: 0, rects: [[0, 0, 612, 792]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let command = try #require(plan.command(marks: store.marks))
    let redacted = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let withOCR = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [
            SearchableTextLine(text: "OCR-SEED synthetic scan text", rect: [50, 700, 320, 730])
          ])
      ]), to: redacted)
    let sanitized = try RedactionSanitizer.sanitize(in: withOCR, policy: .secure)
    return (withOCR, sanitized.graph, sanitized.report)
  }

  @Test func seededMatrixCannotBeRecoveredFromDistributedBytes() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let output = try Self.redactedAndSanitized(fixture)
    let data = try PDFWriter.write(output.sanitized)
    let seeds = fixture.seeds + ["OCR-SEED"]
    let result = RedactionAdversarialValidator.validate(
      distributed: data, seeds: seeds, source: fixture.data)
    #expect(result.distributedClean, Comment(rawValue: result.summary))
    #expect(result.survivingLocations.isEmpty)
    #expect(result.survivingSeeds.isEmpty)
    #expect(result.checks.count >= 4)
    for seed in seeds {
      #expect(!String(decoding: data, as: UTF8.self).contains(seed))
    }
  }

  @Test func sourceRetentionAndRecoveryAreExplicitlyDistinguished() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let output = try Self.redactedAndSanitized(fixture)
    let data = try PDFWriter.write(output.sanitized)
    let result = RedactionAdversarialValidator.validate(
      distributed: data, seeds: fixture.seeds, source: fixture.data)
    #expect(result.distributedClean)
    #expect(!result.sourceRetainedSeeds.isEmpty)
    #expect(result.sourceRetainedSeeds.contains("REVISION-ONLY-SEED"))
    #expect(result.summary.contains("source retention"))
    #expect(result.recoveryDisclosure.contains("recovery snapshots"))
    #expect(result.summary.contains("Distributed output"))
  }

  @Test func negativeControlFindsSeedsWithoutSanitization() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let parsed = try PDFParser.parse(fixture.data)
    let pageID = try #require(parsed.pageIDs.first)
    var store = RedactionMarkStore()
    _ = try store.add(kind: .page, pageID: pageID, pageIndex: 0, rects: [[0, 0, 612, 792]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let command = try #require(plan.command(marks: store.marks))
    let redactedOnly = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let data = try PDFWriter.write(redactedOnly)
    let result = RedactionAdversarialValidator.validate(
      distributed: data, seeds: fixture.seeds)
    #expect(!result.distributedClean)
    for seed in ["INFO-SEED", "ATTACH-SEED", "ACTION-SEED", "ID-SEED"] {
      #expect(result.survivingSeeds.contains(seed), Comment(rawValue: seed))
    }
    #expect(
      result.survivingLocations.contains { $0.category == .metadata }
        || result.survivingLocations.contains { $0.category == .objectString })
    #expect(result.survivingLocations.contains { $0.seed == "ATTACH-SEED" })
  }

  @Test func orphansAndEarlierRevisionsCannotSurviveTheRewrite() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let output = try Self.redactedAndSanitized(fixture)
    let data = try PDFWriter.write(output.sanitized)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.revisionCount == 1)
    #expect(data.range(of: Data("/Prev".utf8)) == nil)
    let reachable = SanitizeDocumentCommand.reachableObjectIDs(in: parsed.graph)
    #expect(reachable.count == parsed.graph.objects.count)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("ORPHAN-SEED"))
    #expect(!text.contains("REVISION-ONLY-SEED"))
    #expect(!text.contains("ID-SEED"))
  }

  @Test func ocrLayerSeedIsRemovedByTheSanitizer() throws {
    let fixture = try RedactionAdversarialFixture.make()
    let output = try Self.redactedAndSanitized(fixture)
    let data = try PDFWriter.write(output.sanitized)
    #expect(!String(decoding: data, as: UTF8.self).contains("OCR-SEED"))
    let pageID = try #require(try PDFParser.parse(data).pageIDs.first)
    let layout = try PageTextLayout.build(
      pageID: pageID, in: try PDFParser.parse(data).graph)
    #expect(!layout.text(in: 0..<layout.clusters.count).contains("OCR-SEED"))
    #expect(output.report.outcome(.ocrLayers) == .removed)
  }
}

