import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import MacServices
import Testing

/// OCR-06 service evidence: mixed-page selection and bounded command building
/// from recognition results (no engine run; synthetic OCR observations).
@Suite("Mixed-page OCR service (OCR-06)")
struct OCRMixedPageServiceTests {
  private func parsed(_ data: Data) throws -> PDFGraph {
    try PDFParser.parse(data).graph
  }

  private func mixedGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    var graph = try parsed(PDFFixtures.scannedPages())
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [80, 650, 320, 670], text: "Digital label",
          style: AddedTextStyle(size: 12), clips: false)
      ]), to: graph)
    return (graph, pageID)
  }

  @Test func planSelectsMixedAndNewPagesOnly() throws {
    let fixture = try mixedGraph()
    let pageIDs = try PDFPageTree.pageIDs(in: fixture.graph)
    let plan = try OCRMixedPageService.plan(
      graph: fixture.graph, pageIDs: pageIDs)
    #expect(plan.hasWork)
    #expect(plan.ocrPageIndexes == [0])
    #expect(plan.replacingPageIndexes.isEmpty)
    #expect(plan.profiles[0].kind == .mixedDigitalAndScan)
    #expect(plan.summaryLines.joined().contains("Mixed-page plan"))
    // Pure digital-text pages are not candidates.
    let text = try parsed(PDFFixtures.threePages())
    let textPages = try PDFPageTree.pageIDs(in: text)
    let textPlan = try OCRMixedPageService.plan(graph: text, pageIDs: textPages)
    #expect(!textPlan.hasWork)
    #expect(textPlan.skippedProfiles.count == 3)
  }

  @Test func commandsDropOutsideAndDuplicateLinesAndPreservePixels() throws {
    let fixture = try mixedGraph()
    let pageIDs = try PDFPageTree.pageIDs(in: fixture.graph)
    let plan = try OCRMixedPageService.plan(graph: fixture.graph, pageIDs: pageIDs)
    let placementsBefore = try ImageInventory.placements(
      in: fixture.graph, pageID: fixture.pageID)
    let results = [
      OCRPageResult(
        pageIndex: 0,
        lines: [
          OCRTextLine(text: "inside scan", rect: [100, 100, 300, 120], confidence: 0.9),
          OCRTextLine(text: "outside bounds", rect: [560, 100, 600, 120], confidence: 0.9),
          OCRTextLine(text: "duplicate digital", rect: [90, 648, 310, 672], confidence: 0.9),
        ],
        usedFastFallback: false)
    ]
    let prepared = OCRMixedPageService.commands(
      results: results, graph: fixture.graph, pageIDs: pageIDs, plan: plan)
    #expect(prepared.commands.count == 1)
    #expect(prepared.acceptedLineCount == 1)
    #expect(prepared.droppedLineCount == 2)
    #expect(prepared.summaryLines.joined().contains("dropped"))
    let updated = try PDFEditingEngine.commit(
      PDFTransaction(prepared.commands), to: fixture.graph)
    let placementsAfter = try ImageInventory.placements(
      in: updated, pageID: fixture.pageID)
    #expect(placementsAfter.map(\.bounds) == placementsBefore.map(\.bounds))
    let bytesBefore = placementsBefore.compactMap { placement -> Data? in
      guard case .stream(let stream)? = fixture.graph.objects[placement.imageID] else {
        return nil
      }
      return stream.bytes
    }
    let bytesAfter = placementsAfter.compactMap { placement -> Data? in
      guard case .stream(let stream)? = updated.objects[placement.imageID] else { return nil }
      return stream.bytes
    }
    #expect(bytesAfter == bytesBefore)
    let layout = try PageTextLayout.build(pageID: fixture.pageID, in: updated)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(text.contains("inside scan"))
    #expect(text.contains("Digital label"))
    #expect(!text.contains("outside bounds"))
    #expect(!text.contains("duplicate digital"))
  }

  @Test func replacementPlanKeepsOnlyChosenLayer() throws {
    var graph = try parsed(PDFFixtures.scannedPages())
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "old layer", rect: [100, 100, 300, 120])])
      ]), to: graph)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let plan = try OCRMixedPageService.plan(graph: graph, pageIDs: pageIDs)
    #expect(plan.replacingPageIndexes == [0])
    let results = [
      OCRPageResult(
        pageIndex: 0,
        lines: [OCRTextLine(text: "new layer", rect: [100, 100, 300, 120], confidence: 0.95)],
        usedFastFallback: false)
    ]
    let prepared = OCRMixedPageService.commands(
      results: results, graph: graph, pageIDs: pageIDs, plan: plan)
    #expect(prepared.commands.count == 1)
    let updated = try PDFEditingEngine.commit(
      PDFTransaction(prepared.commands), to: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: updated)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(text.contains("new layer"))
    #expect(!text.contains("old layer"))
  }
}
