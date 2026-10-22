import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P16-002/005/006/011/012/022/023/024/026/027 evidence: display-space
/// normalization, paragraph/reading-order resolution, cross-page selection,
/// glyph quads, artifact filtering, duplicate-text dedup, boundary certainty,
/// and multi-column/tagged/rotated verification.
@Suite("Text pipeline geometry and reading")
struct TextPipelineTests {
  private func graph(_ data: Data) throws -> (PDFGraph, [PDFObjectID]) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, parsed.pageIDs)
  }

  private func pageLayout(_ data: Data, page: Int = 0) throws -> (PageTextLayout, PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(data)
    let pageID = parsed.pageIDs[page]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    return (layout, parsed.graph, pageID)
  }

  // MARK: - P16-002 normalization

  @Test func displayNormalizationRoundTripsAcrossRotation() throws {
    var base = PDFFixtures.graph(pages: 1)
    guard case .dictionary(var page)? = base.objects[PDFObjectID(4)] else {
      Issue.record("fixture page missing")
      return
    }
    page[PDFName("Rotate")] = .integer(90)
    page[PDFName("UserUnit")] = .real(2)
    page[PDFName("CropBox")] = .array([.integer(10), .integer(20), .integer(610), .integer(820)])
    base.objects[PDFObjectID(4)] = .dictionary(page)
    let geometry = try #require(PageDisplayGeometry.resolve(pageID: PDFObjectID(4), in: base))
    #expect(geometry.quarterTurns == 1)
    // Rotation swaps the axes after UserUnit scaling.
    #expect(abs(geometry.displayWidth - 800 * 2) < 1e-9)
    #expect(abs(geometry.displayHeight - 600 * 2) < 1e-9)
    let point = [42.0, 710.0]
    let display = try #require(geometry.toDisplay(point))
    let back = try #require(geometry.toContent(display))
    #expect(abs(back[0] - point[0]) < 1e-9 && abs(back[1] - point[1]) < 1e-9)
    // Bounds map through all four corners and stay positive-area.
    let layout = try PageTextLayout.build(pageID: PDFObjectID(4), in: base)
    for cluster in layout.clusters {
      let mapped = try #require(geometry.toDisplay(bounds: cluster.bounds))
      #expect(mapped[2] >= mapped[0] && mapped[3] >= mapped[1])
    }
  }

  @Test func identityGeometryIsAUnitScaleShift() throws {
    let (_, graph, pageID) = try pageLayout(PDFFixtures.textWidthsPages())
    let geometry = try #require(PageDisplayGeometry.resolve(pageID: pageID, in: graph))
    #expect(geometry.quarterTurns == 0 && geometry.userUnit == 1)
    #expect(geometry.toDisplay([42, 710]) == [42, 710])
    #expect(geometry.toContent([42, 710]) == [42, 710])
  }

  // MARK: - P16-027 rotated-page highlight and hit test

  @Test func rotatedPageHighlightAndHitTestAgree() throws {
    // A widths-carrying page with /Rotate 90: display bounds keep positive
    // area (the shared croppedPages stream has no widths, so its clusters
    // are zero-width markers and cannot pin area).
    var graph = TextPipelineTests.syntheticSinglePage(content:
      "BT /F1 12 Tf 42 700 Td (Rotated check) Tj ET\n")
    guard case .dictionary(var page)? = graph.objects[PDFObjectID(3)] else {
      Issue.record("synthetic page missing")
      return
    }
    page[PDFName("Rotate")] = .integer(90)
    graph.objects[PDFObjectID(3)] = .dictionary(page)
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let rotatedID = parsed.pageIDs[0]
    let geometry = try #require(PageDisplayGeometry.resolve(pageID: rotatedID, in: parsed.graph))
    #expect(geometry.quarterTurns == 1)
    // Rotation swaps the axes after scaling.
    #expect(abs(geometry.displayWidth - 792) < 1e-9)
    #expect(abs(geometry.displayHeight - 612) < 1e-9)
    let layout = try PageTextLayout.build(pageID: rotatedID, in: parsed.graph)
    #expect(!layout.clusters.isEmpty)
    let range = layout.lines[0]
    let displayBounds = try #require(NormalizedHitTesting.displayBounds(
      of: range, layout: layout, geometry: geometry))
    #expect(displayBounds[2] > displayBounds[0] && displayBounds[3] > displayBounds[1])
    // A probe at the display center of the first cluster hits that cluster.
    let first = layout.clusters[range.lowerBound]
    let contentCenter = [
      (first.bounds[0] + first.bounds[2]) / 2, (first.bounds[1] + first.bounds[3]) / 2,
    ]
    let displayCenter = try #require(geometry.toDisplay(contentCenter))
    #expect(NormalizedHitTesting.clusterIndex(
      atDisplayPoint: displayCenter, layout: layout, geometry: geometry) == range.lowerBound)
    // The shared croppedPages rotated page still resolves and hit-tests.
    let cropped = try PDFParser.parse(PDFFixtures.croppedPages())
    let croppedGeometry = try #require(PageDisplayGeometry.resolve(
      pageID: cropped.pageIDs[1], in: cropped.graph))
    #expect(croppedGeometry.quarterTurns == 1)
  }

  // MARK: - P16-011 cross-page drag selection

  @Test func dragSelectionSpansPageBoundariesInDocumentOrder() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var counts: [Int] = []
    for pageID in parsed.pageIDs {
      counts.append(try PageTextLayout.build(pageID: pageID, in: parsed.graph).clusters.count)
    }
    #expect(counts.allSatisfy { $0 > 0 })
    // Forward drag from page 0 into page 2.
    let forward = CrossPageSelection(
      anchor: CrossPageSelection.Endpoint(pageIndex: 0, clusterIndex: 2),
      focus: CrossPageSelection.Endpoint(pageIndex: 2, clusterIndex: 3))
    let ranges = forward.perPageRanges(clusterCounts: counts)
    #expect(ranges.count == 3)
    #expect(ranges[0] == 2..<counts[0])
    #expect(ranges[1] == 0..<counts[1])
    #expect(ranges[2] == 0..<3)
    // Backward drag resolves identically (direction-independent).
    let backward = CrossPageSelection(anchor: forward.focus, focus: forward.anchor)
    #expect(backward.perPageRanges(clusterCounts: counts) == ranges)
    // Same-page drag clamps and orders the endpoints.
    let same = CrossPageSelection(
      anchor: CrossPageSelection.Endpoint(pageIndex: 1, clusterIndex: 9),
      focus: CrossPageSelection.Endpoint(pageIndex: 1, clusterIndex: 4))
    #expect(same.perPageRanges(clusterCounts: counts) == [1: 4..<9])
    #expect(forward.isCollapsed == false)
    let caret = CrossPageSelection(
      anchor: CrossPageSelection.Endpoint(pageIndex: 1, clusterIndex: 1),
      focus: CrossPageSelection.Endpoint(pageIndex: 1, clusterIndex: 1))
    #expect(caret.isCollapsed && caret.perPageRanges(clusterCounts: counts) == [1: 1..<1])
  }

  // MARK: - P16-012 glyph quads

  @Test func selectionQuadsFollowGlyphOrientation() throws {
    let (layout, graph, _) = try pageLayout(PDFFixtures.transformedTextPages())
    let content = try PageContent.load(
      pageID: (try PDFParser.parse(PDFFixtures.transformedTextPages()).pageIDs[0]),
      in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    // Identity run: quad corners are the bounds corners.
    let scaledLine = try #require(layout.lines.first {
      layout.text(in: $0).contains("Scaled")
    })
    let quads = SelectionQuads.quads(range: scaledLine, layout: layout, runs: runs, in: graph)
    #expect(quads.count == scaledLine.count)
    let first = layout.clusters[scaledLine.lowerBound]
    #expect(abs(quads[0][0] - first.bounds[0]) < 1e-9)
    #expect(abs(quads[0][5] - first.bounds[3]) < 1e-9)
    // Rotated run: the quad is not its axis-aligned box diagonal — the
    // corners come from the run matrix, so opposite corners differ on both
    // axes exactly as the composed bounds do.
    let rotatedLine = try #require(layout.lines.first {
      layout.text(in: $0).contains("Rotated")
    })
    let rotatedQuads = SelectionQuads.quads(
      range: rotatedLine.lowerBound..<(rotatedLine.lowerBound + 1),
      layout: layout, runs: runs, in: graph)
    #expect(rotatedQuads.count == 1)
    let quad = rotatedQuads[0]
    // A 90-degree glyph cell is tall in y only through the matrix: x0 == x1
    // for the first edge (advance runs along -x from the baseline).
    #expect(quad.count == 8)
    #expect(abs(quad[0] - quad[2]) < 1e-9 || abs(quad[1] - quad[3]) < 1e-9)
  }

  // MARK: - P16-005 paragraph candidates

  @Test func paragraphCandidatesCarryConfidenceAndSources() throws {
    let (_, graph, pageID) = try pageLayout(PDFFixtures.textEditPages())
    let candidates = try TextReadingOrder.paragraphCandidates(pageID: pageID, in: graph)
    #expect(!candidates.isEmpty)
    for candidate in candidates {
      #expect(candidate.confidence >= 0 && candidate.confidence <= 1)
      #expect(!candidate.runIndices.isEmpty)
      #expect(!candidate.text.isEmpty)
      #expect(candidate.bounds.count == 4)
    }
    let joined = candidates.map(\.text).joined(separator: "\n")
    #expect(joined.contains("Replace this text"))
  }

  // MARK: - P16-006 structure order

  @Test func structureTreeOrderGovernsTaggedPages() throws {
    let (_, parsedGraph, pageID) = try pageLayout(PDFFixtures.taggedPages())
    var graph = parsedGraph
    // A nested inline span is represented both inside its parent and in the
    // inventory's flattened element list. Reading order must visit it once.
    guard case .dictionary(var paragraphStruct)? = graph.objects[PDFObjectID(22)],
      case .dictionary(var parentTree)? = graph.objects[PDFObjectID(25)],
      case .array(var numberTreeEntries)? = parentTree[PDFName("Nums")],
      numberTreeEntries.count > 1,
      case .array(var pageParents) = numberTreeEntries[1]
    else { throw CocoaError(.fileReadCorruptFile) }
    paragraphStruct[PDFName("K")] = .reference(PDFObjectID(60))
    graph.objects[PDFObjectID(22)] = .dictionary(paragraphStruct)
    graph.objects[PDFObjectID(60)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("Span")),
      PDFName("P"): .reference(PDFObjectID(22)),
      PDFName("Pg"): .reference(PDFObjectID(3)),
      PDFName("K"): .integer(1),
    ])
    pageParents[1] = .reference(PDFObjectID(60))
    numberTreeEntries[1] = .array(pageParents)
    parentTree[PDFName("Nums")] = .array(numberTreeEntries)
    graph.objects[PDFObjectID(25)] = .dictionary(parentTree)

    let order = try TextReadingOrder.orderedClusterIndices(pageID: pageID, in: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    #expect(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: layout, in: graph, limits: PDFLimits()) != nil)
    #expect(order.count == layout.clusters.count)
    #expect(Set(order) == Set(layout.clusters.indices))
    // The heading (MCID 0) reads before the paragraph (MCID 1).
    let headingPosition = order.first {
      layout.clusters[$0].text.contains("T")
        && layout.text(in: layout.lines[layout.lineIndex(containing: $0)!]).contains("Tagged heading")
    }
    let paragraphPosition = order.first {
      layout.text(in: layout.lines[layout.lineIndex(containing: $0)!]).contains("Tagged paragraph")
    }
    let heading = try #require(headingPosition)
    let paragraph = try #require(paragraphPosition)
    #expect(order.firstIndex(of: heading)! < order.firstIndex(of: paragraph)!)
    // Untagged pages keep geometric order.
    let (plainLayout, plainGraph, plainID) = try pageLayout(PDFFixtures.textEditPages())
    #expect(
      try TextReadingOrder.orderedClusterIndices(pageID: plainID, in: plainGraph)
        == Array(plainLayout.clusters.indices))

    var duplicateMCIDGraph = graph
    guard case .dictionary(var duplicateParagraph)? = duplicateMCIDGraph.objects[PDFObjectID(22)] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    duplicateParagraph[PDFName("K")] = .array([
      .reference(PDFObjectID(60)), .integer(1),
    ])
    duplicateMCIDGraph.objects[PDFObjectID(22)] = .dictionary(duplicateParagraph)
    let duplicateLayout = try PageTextLayout.build(pageID: pageID, in: duplicateMCIDGraph)
    #expect(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: duplicateLayout, in: duplicateMCIDGraph,
      limits: PDFLimits()) == nil)
  }

  // MARK: - P16-022 artifact exclusion

  @Test func artifactTextLeavesReadingOrderWhenTagged() throws {
    var graph = try PDFParser.parse(PDFFixtures.taggedPages()).graph
    // Add an artifact-wrapped footer line to the tagged page's stream
    // (object 5 is the tagged fixture's content stream).
    guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else {
      Issue.record("tagged content missing")
      return
    }
    var bytes = [UInt8](try PDFFilters.decoded(PDFStream(
      dictionary: stream.dictionary, bytes: stream.bytes)))
    bytes.append(contentsOf: Array(
      "/Artifact <</Type /Pagination>> BDC\nBT /F1 12 Tf 42 560 Td (Page footer) Tj ET\nEMC\n".utf8))
    let filters = try PDFFilters.filterNames(in: stream.dictionary)
    let encoded: Data
    var dictionary = stream.dictionary
    if filters.isEmpty {
      encoded = Data(bytes)
    } else {
      encoded = try PDFFilters.encodeFlate(Data(bytes))
      dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
    }
    dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(dictionary: dictionary, bytes: encoded))
    let rewritten = try PDFParser.parse(PDFWriter.write(graph))
    let artifacts = try ArtifactFiltering.artifactRunIndices(
      pageID: rewritten.pageIDs[0], in: rewritten.graph)
    #expect(!artifacts.isEmpty)
    let kept = try ArtifactFiltering.contentClusterIndices(
      pageID: rewritten.pageIDs[0], in: rewritten.graph)
    let layout = try PageTextLayout.build(pageID: rewritten.pageIDs[0], in: rewritten.graph)
    #expect(kept.count < layout.clusters.count)
    let keptText = kept.map { layout.clusters[$0].text }.joined()
    #expect(!keptText.contains("Page footer"))
    #expect(layout.clusters.map(\.text).joined().contains("Page footer"))
    // Untagged documents exclude nothing (no applicable structure).
    let (plainLayout, plainGraph, plainID) = try pageLayout(PDFFixtures.textEditPages())
    #expect(try ArtifactFiltering.artifactRunIndices(pageID: plainID, in: plainGraph).isEmpty)
    #expect(
      try ArtifactFiltering.contentClusterIndices(pageID: plainID, in: plainGraph).count
        == plainLayout.clusters.count)
  }

  // MARK: - P16-023 duplicate invisible text

  @Test func invisibleDuplicatesDoNotDuplicateSearch() throws {
    // Exact-position shadow copy: the merged line garbles a plain search,
    // while the duplicate-aware search reports the visible hit exactly once.
    let content = """
      BT /F1 12 Tf 42 700 Td (Hello world) Tj ET
      3 Tr BT /F1 12 Tf 42 700 Td (Hello world) Tj ET 0 Tr
      """ + "\n"
    let graph = TextPipelineTests.syntheticSinglePage(content: content)
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let invisible = try DuplicateTextHandling.invisibleRunIndices(
      pageID: pageID, in: parsed.graph)
    #expect(invisible.count == 1)
    let plain = TextSearch.search(query: "Hello", in: layout)
    #expect(plain.count <= 1, "a garbled duplicate line must never double-report")
    let merged = DuplicateTextHandling.search(
      query: "Hello", in: layout, invisibleRuns: invisible)
    #expect(merged.count == 1)
    // The surviving hit is the visible one: its highlight covers exactly the
    // visible copy's glyphs (the covering range spans the interleaved shadow,
    // which shares the line span glyph-by-glyph).
    #expect(!merged[0].clusterRange.allSatisfy {
      invisible.contains(layout.clusters[$0].runIndex)
    })
    let visibleRun = try #require(
      layout.clusters.indices.map({ layout.clusters[$0].runIndex }).first {
        !invisible.contains($0)
      })
    let expectedBounds = layout.clusters.indices.filter {
      layout.clusters[$0].runIndex == visibleRun
    }.prefix(5).map { layout.clusters[$0].bounds }
    #expect(merged[0].bounds == Array(expectedBounds))
    // Distinct occurrences at different positions are distinct hits and are
    // never merged.
    let two = TextPipelineTests.syntheticSinglePage(content: """
      BT /F1 12 Tf 42 700 Td (Hello) Tj ET
      BT /F1 12 Tf 42 660 Td (Hello) Tj ET
      """ + "\n")
    let parsedTwo = try PDFParser.parse(PDFWriter.write(two))
    let layoutTwo = try PageTextLayout.build(pageID: parsedTwo.pageIDs[0], in: parsedTwo.graph)
    #expect(DuplicateTextHandling.search(
      query: "Hello", in: layoutTwo, invisibleRuns: []).count == 2)
  }

  // MARK: - P16-024 uncertain boundaries

  @Test func selectionBoundariesReportCertainty() throws {
    let (layout, graph, pageID) = try pageLayout(PDFFixtures.textWidthsPages())
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    // Supported widths on both edges: certain.
    let certain = SelectionUncertainty.assess(
      range: 0..<2, layout: layout, runs: runs, in: graph, pageID: pageID)
    #expect(certain.isCertain && certain.reasons.isEmpty)
    // Combining-mark edge: uncertain with a named reason.
    let (combining, combiningGraph, combiningID) = try pageLayout(PDFFixtures.combiningMarkPages())
    let combiningContent = try PageContent.load(pageID: combiningID, in: combiningGraph)
    let combiningRuns = try TextRunIndexer.runs(in: combiningContent, graph: combiningGraph)
    let uncertain = SelectionUncertainty.assess(
      range: 0..<1, layout: combining, runs: combiningRuns, in: combiningGraph,
      pageID: combiningID)
    #expect(!uncertain.isCertain && !uncertain.reasons.isEmpty)
    // Empty selection: uncertain, not a crash.
    #expect(!SelectionUncertainty.assess(
      range: 1..<1, layout: layout, runs: runs, in: graph, pageID: pageID).isCertain)
  }

  // MARK: - P16-026 reading-order verification

  @Test func readingOrderHoldsForColumnsAndTaggedPages() throws {
    let (columns, columnGraph, columnID) = try pageLayout(PDFFixtures.twoColumnPages())
    let order = try TextReadingOrder.orderedClusterIndices(pageID: columnID, in: columnGraph)
    let texts = order.map { columns.clusters[$0].text }.joined()
    // Column-major: every left-column glyph precedes every right-column one.
    let leftEnd = texts.range(of: "Left three")!.upperBound
    let rightStart = texts.range(of: "Right one")!.lowerBound
    #expect(leftEnd <= rightStart)
    // Tagged fixture: structure order matches the paragraph engine's text.
    let (_, taggedGraph, taggedID) = try pageLayout(PDFFixtures.taggedPages())
    let taggedOrder = try TextReadingOrder.orderedClusterIndices(
      pageID: taggedID, in: taggedGraph)
    let taggedLayout = try PageTextLayout.build(pageID: taggedID, in: taggedGraph)
    let orderedText = taggedOrder.map { taggedLayout.clusters[$0].text }.joined()
    #expect(orderedText.contains("Tagged heading"))
    #expect(orderedText.contains("Tagged paragraph"))
    #expect(orderedText.range(of: "Tagged heading")!.lowerBound
      < orderedText.range(of: "Tagged paragraph")!.lowerBound)
  }

  // MARK: - Helpers

  static func syntheticSinglePage(content: String) -> PDFGraph {
    let widths: [PDFValue] = (32...126).map { .integer($0 == 32 ? 250 : 500) as PDFValue }
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("FirstChar"): .integer(32),
          PDFName("LastChar"): .integer(126),
          PDFName("Widths"): .array(widths),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }
}
