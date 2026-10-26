import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// OCR-06 evidence: mixed scanned/digital classification, bounded layers that
/// preserve pixels/coordinates, layer replacement without duplicate layers,
/// page-construction association and redaction-safe re-recognition.
@Suite("Mixed scanned/digital OCR pages (OCR-06)")
struct OCRMixedPageTests {
  private func parsed(_ data: Data) throws -> (graph: PDFGraph, source: Data) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, data)
  }

  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private func imageStreamBytes(
    for placements: [ImagePlacement], in graph: PDFGraph
  ) -> [Data] {
    placements.compactMap { placement in
      guard case .stream(let stream)? = graph.objects[placement.imageID] else { return nil }
      return stream.bytes
    }
  }

  private func pageTexts(_ graph: PDFGraph) throws -> [String] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    return try pageIDs.map { pageID in
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    }
  }

  private func mixedPageGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    var graph = try parsed(PDFFixtures.scannedPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try commit(
      [
        AddTextObjectCommand(
          pageID: pageID, rect: [80, 650, 320, 670], text: "Digital label",
          style: AddedTextStyle(size: 12), clips: false)
      ], to: graph)
    return (graph, pageID)
  }

  @Test func digitalTextPagesAreSkipped() throws {
    let document = try parsed(PDFFixtures.threePages())
    let profiles = try OCRMixedPagePlanner.profiles(in: document.graph)
    #expect(profiles.count == 3)
    #expect(profiles.allSatisfy { $0.kind == .digitalTextOnly })
    #expect(profiles.allSatisfy { $0.action == .skip })
    #expect(profiles.allSatisfy { $0.digitalLineCount > 0 })
    let plan = try OCRMixedPagePlanner.plan(in: document.graph)
    #expect(!plan.hasWork)
    #expect(plan.ocrPageIndexes.isEmpty)
    #expect(plan.summaryLines.joined().contains("skipped"))
  }

  @Test func plainScansBecomeBoundedLayerCandidates() throws {
    let document = try parsed(PDFFixtures.scannedPages())
    let profiles = try OCRMixedPagePlanner.profiles(in: document.graph)
    #expect(profiles.count == 1)
    #expect(profiles[0].kind == .scannedNoText)
    #expect(profiles[0].action == .addBoundedLayer)
    #expect(profiles[0].boundedRegions.count == 1)
    #expect(profiles[0].boundedRegions[0].imageIndex == 0)
    #expect(profiles[0].scanCoverage > 0.6)
    #expect(profiles[0].pageBox == [0, 0, 612, 792])
    let plan = try OCRMixedPagePlanner.plan(in: document.graph)
    #expect(plan.ocrPageIndexes == [0])
    #expect(plan.replacingPageIndexes.isEmpty)
  }

  @Test func mixedPageBoundedLinesPreserveDigitalText() throws {
    let fixture = try mixedPageGraph()
    let profiles = try OCRMixedPagePlanner.profiles(in: fixture.graph)
    #expect(profiles[0].kind == .mixedDigitalAndScan)
    #expect(profiles[0].action == .addBoundedLayer)
    #expect(profiles[0].digitalLineCount >= 1)
    #expect(profiles[0].imageCount == 1)
    let region = profiles[0].boundedRegions[0].rect
    let lines = [
      SearchableTextLine(text: "scan line", rect: [100, 100, 300, 120], confidence: 0.9),
      SearchableTextLine(text: "outside", rect: [region[2] + 20, 100, region[2] + 50, 120]),
      SearchableTextLine(text: "duplicate", rect: [90, 648, 310, 672]),
    ]
    let bounded = OCRMixedPagePlanner.boundedLines(lines, for: profiles[0])
    #expect(bounded.count == 1)
    #expect(bounded[0].line.text == "scan line")
    #expect(bounded[0].regionIndex == 0)
  }

  @Test func boundedLayerPreservesPixelsAndPlacements() throws {
    let fixture = try mixedPageGraph()
    let profile = try OCRMixedPagePlanner.profiles(in: fixture.graph)[0]
    let pageID = fixture.pageID
    let placementsBefore = try ImageInventory.placements(in: fixture.graph, pageID: pageID)
    let encodedBefore = imageStreamBytes(for: placementsBefore, in: fixture.graph)
    guard case .dictionary(let pageBefore)? = fixture.graph.objects[pageID],
      case .array(let mediaBefore)? = pageBefore[PDFName("MediaBox")]
    else {
      Issue.record("Fixture page missing")
      return
    }
    let command = AddBoundedSearchableTextLayerCommand(
      pageID: pageID,
      lines: [SearchableTextLine(text: "bounded scan text", rect: [100, 100, 300, 120], confidence: 0.92)],
      boundedRegions: profile.boundedRegions.map(\.rect),
      replaceExistingLayer: false)
    try command.validate(in: fixture.graph)
    let updated = try commit([command], to: fixture.graph)
    let placementsAfter = try ImageInventory.placements(in: updated, pageID: pageID)
    #expect(placementsAfter.map(\.bounds) == placementsBefore.map(\.bounds))
    #expect(imageStreamBytes(for: placementsAfter, in: updated) == encodedBefore)
    guard case .dictionary(let pageAfter)? = updated.objects[pageID],
      case .array(let mediaAfter)? = pageAfter[PDFName("MediaBox")]
    else {
      Issue.record("Updated page missing")
      return
    }
    #expect(mediaAfter == mediaBefore)
    let texts = try pageTexts(updated)
    #expect(texts[0].contains("Digital label"))
    #expect(texts[0].contains("bounded scan text"))
  }

  @Test func reOCRReplacesOnlyTheChosenLayer() throws {
    let document = try parsed(PDFFixtures.scannedPages())
    let pageID = try PDFPageTree.pageIDs(in: document.graph)[0]
    let withLayer = try commit(
      [
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "alpha secret", rect: [100, 100, 300, 120])])
      ], to: document.graph)
    #expect(try pageTexts(withLayer)[0].contains("alpha secret"))
    let profile = try OCRMixedPagePlanner.profiles(in: withLayer)[0]
    #expect(profile.kind == .scannedGeneratedLayer)
    #expect(profile.action == .replaceGeneratedLayer)
    let replacement = AddBoundedSearchableTextLayerCommand(
      pageID: pageID,
      lines: [SearchableTextLine(text: "alpha visible", rect: [100, 100, 300, 120])],
      boundedRegions: profile.boundedRegions.map(\.rect),
      replaceExistingLayer: true)
    try replacement.validate(in: withLayer)
    let replaced = try commit([replacement], to: withLayer)
    let text = try pageTexts(replaced)[0]
    #expect(text.contains("alpha visible"))
    #expect(!text.contains("secret"))
    #expect(OCRLayer.hasGeneratedLayer(in: replaced, pageID: pageID))
  }

  @Test func boundedLayerRefusesDuplicateOrUnboundedLayers() throws {
    let document = try parsed(PDFFixtures.scannedPages())
    let pageID = try PDFPageTree.pageIDs(in: document.graph)[0]
    let withLayer = try commit(
      [
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "existing", rect: [100, 100, 300, 120])])
      ], to: document.graph)
    let profile = try OCRMixedPagePlanner.profiles(in: withLayer)[0]
    let duplicate = AddBoundedSearchableTextLayerCommand(
      pageID: pageID, lines: [SearchableTextLine(text: "new", rect: [100, 100, 200, 120])],
      boundedRegions: profile.boundedRegions.map(\.rect), replaceExistingLayer: false)
    #expect(throws: PDFError.self) { try duplicate.validate(in: withLayer) }
    let outside = AddBoundedSearchableTextLayerCommand(
      pageID: pageID, lines: [SearchableTextLine(text: "new", rect: [600, 100, 700, 120])],
      boundedRegions: profile.boundedRegions.map(\.rect), replaceExistingLayer: true)
    #expect(throws: PDFError.self) { try outside.validate(in: withLayer) }
    // A page with digital text but no scan image cannot gain a bounded layer.
    let textOnly = try parsed(PDFFixtures.threePages()).graph
    let textPage = try PDFPageTree.pageIDs(in: textOnly)[0]
    let noImage = AddBoundedSearchableTextLayerCommand(
      pageID: textPage,
      lines: [SearchableTextLine(text: "x", rect: [100, 100, 200, 120])],
      boundedRegions: [[0, 0, 612, 792]], replaceExistingLayer: false)
    #expect(throws: PDFError.self) { try noImage.validate(in: textOnly) }
    // Replacing requires a generated layer to replace.
    let nothingToReplace = AddBoundedSearchableTextLayerCommand(
      pageID: pageID, lines: [SearchableTextLine(text: "x", rect: [100, 100, 200, 120])],
      boundedRegions: profile.boundedRegions.map(\.rect), replaceExistingLayer: true)
    #expect(throws: PDFError.self) { try nothingToReplace.validate(in: document.graph) }
  }

  @Test func redactedPageDoesNotRegainRemovedContent() throws {
    var graph = try parsed(PDFFixtures.scannedPages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try commit(
      [
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "secret removed", rect: [100, 100, 300, 120])])
      ], to: graph)
    // Redacted flattened derivative rebuilds the page from already-redacted
    // pixels and drops every generated layer.
    let pixels = Data(repeating: 220, count: 8 * 8 * 3)
    graph = try FlattenedRedactedDerivative.make(
      from: graph, pageID: pageID, width: 8, height: 8, rgb8: pixels)
    #expect(FlattenedRedactedDerivative.isFlattenedDerivative(graph, pageID: pageID))
    #expect(!OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID))
    let profiles = try OCRMixedPagePlanner.profiles(in: graph)
    #expect(profiles[0].kind == .scannedNoText)
    #expect(profiles[0].action == .addBoundedLayer)
    let command = AddBoundedSearchableTextLayerCommand(
      pageID: pageID,
      lines: [SearchableTextLine(text: "surviving word", rect: [100, 100, 300, 120])],
      boundedRegions: profiles[0].boundedRegions.map(\.rect))
    try command.validate(in: graph)
    let updated = try commit([command], to: graph)
    let text = try pageTexts(updated)[0]
    #expect(text.contains("surviving word"))
    #expect(!text.contains("secret removed"))
    #expect(FlattenedRedactedDerivative.isFlattenedDerivative(updated, pageID: pageID))
  }

  @Test func layersFollowPagesAcrossConstruction() throws {
    var graph = try parsed(PDFFixtures.imagePages()).graph
    var pageIDs = try PDFPageTree.pageIDs(in: graph)
    graph = try commit(
      [
        AddSearchableTextLayerCommand(
          pageID: pageIDs[0],
          lines: [SearchableTextLine(text: "first layer", rect: [100, 600, 300, 620])])
      ], to: graph)
    // Move the page carrying the layer to the end (page construction).
    graph = try commit(
      [MovePagesCommand(pageIDs: [pageIDs[0]], toIndex: 1)], to: graph)
    pageIDs = try PDFPageTree.pageIDs(in: graph)
    let profiles = try OCRMixedPagePlanner.profiles(in: graph)
    #expect(profiles.count == 2)
    #expect(profiles[1].pageID == pageIDs[1])
    #expect(profiles[1].kind == .scannedGeneratedLayer)
    #expect(profiles[1].action == .replaceGeneratedLayer)
    let replacement = AddBoundedSearchableTextLayerCommand(
      pageID: profiles[1].pageID,
      lines: [SearchableTextLine(text: "second layer", rect: [100, 600, 300, 620])],
      boundedRegions: profiles[1].boundedRegions.map(\.rect),
      replaceExistingLayer: true)
    try replacement.validate(in: graph)
    let updated = try commit([replacement], to: graph)
    let texts = try pageTexts(updated)
    #expect(!texts[0].contains("first layer"))
    #expect(texts[1].contains("second layer"))
  }

  @Test func policyOptionsCanKeepMixedPagesUntouched() throws {
    let fixture = try mixedPageGraph()
    let profiles = try OCRMixedPagePlanner.profiles(
      in: fixture.graph,
      options: OCRMixedPageOptions(allowBoundedLayersOnMixedPages: false))
    #expect(profiles[0].kind == .mixedDigitalAndScan)
    #expect(profiles[0].action == .skip)
    #expect(profiles[0].skipReason?.contains("mixed") == true)
  }
}
