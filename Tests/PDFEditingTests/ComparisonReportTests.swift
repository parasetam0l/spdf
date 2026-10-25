import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// REV-07 evidence: a portable comparison report carrying page images/regions,
/// change summaries, chosen options and mapping/uncertainty records.
@Suite("Comparison report (REV-07)")
struct ComparisonReportTests {
  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private struct Fixture {
    let left: (graph: PDFGraph, source: Data)
    let right: (graph: PDFGraph, source: Data)
    let result: PDFComparisonResult
    let comparisonOptions: PDFComparisonOptions
  }

  private func makeFixture() throws -> Fixture {
    let leftParsed = try PDFParser.parse(PDFFixtures.threePages())
    let leftData = try PDFWriter.write(leftParsed.graph)
    let leftPageIDs = try PDFPageTree.pageIDs(in: leftParsed.graph)
    var rightGraph = leftParsed.graph
    rightGraph = try commit(
      [
        ReplaceTextCommand(
          pageID: leftPageIDs[0], runIndex: 0, replacement: "Changed heading")
      ], to: rightGraph)
    rightGraph = try commit(
      [ReorderPagesCommand(pageID: leftPageIDs[2], toIndex: 0)], to: rightGraph)
    let rightData = try PDFWriter.write(rightGraph)
    let options = PDFComparisonOptions(includeOCRText: true, visualTolerance: 3)
    let result = try PDFComparison.compare(
      left: (leftParsed.graph, leftData), right: (rightGraph, rightData),
      options: options)
    return Fixture(
      left: (leftParsed.graph, leftData), right: (rightGraph, rightData),
      result: result, comparisonOptions: options)
  }

  private func raster(
    width: Int = 6, height: Int = 4, color: UInt8 = 160
  ) -> ReportRasterImage {
    ReportRasterImage(
      width: width, height: height,
      rgb8: Data(repeating: color, count: width * height * 3))
  }

  private func reportText(_ data: Data) throws -> String {
    let parsed = try PDFParser.parse(data)
    var lines: [String] = []
    for pageID in parsed.pageIDs {
      let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
      lines.append(layout.lines.map { layout.text(in: $0) }.joined(separator: "\n"))
    }
    return lines.joined(separator: "\n")
  }

  // MARK: Tests

  @Test func reportRecordsChangesMappingAndOptions() throws {
    let fixture = try makeFixture()
    #expect(!fixture.result.changes.isEmpty)
    #expect(fixture.result.changes.contains { $0.kind == .pageReordered })
    var pairImages: [Int: ComparisonReportPairImages] = [:]
    for pairIndex in 0..<min(2, fixture.result.pageMapping.count) {
      pairImages[pairIndex] = ComparisonReportPairImages(
        left: raster(color: 120), right: raster(color: 220))
    }
    let regionImage = raster(width: 8, height: 5, color: 200)
    let request = ComparisonReportRequest(
      result: fixture.result,
      comparisonOptions: fixture.comparisonOptions,
      options: ComparisonReportOptions(
        title: "Client Comparison", leftLabel: "before.pdf",
        rightLabel: "after.pdf", generatedOn: "2026-10-25 12:00"),
      pairImages: pairImages,
      regionImages: [0: regionImage])
    let report = try ComparisonReportBuilder.build(request)
    #expect(report.changeRecords.count == fixture.result.changes.count)
    #expect(report.mappingRecords.count == fixture.result.pageMapping.count)
    #expect(report.mappingRecords.contains { $0.status == "reordered" })
    #expect(report.changeRecords.contains { $0.kind == "pageReordered" })
    let textKinds: Set<String> = ["textChanged", "textAdded", "textRemoved"]
    #expect(report.changeRecords.contains { textKinds.contains($0.kind) })
    #expect(report.changeRecords[0].hasRegionImage)
    #expect(report.changeCounts["pageReordered"] == 1)
    #expect(report.optionLines.contains("visualTolerance=3"))
    #expect(report.optionLines.contains("report.mappingSource=automatic"))
    #expect(report.uncertaintyRecords.contains {
      $0.contains("Rendered-difference tolerance: 3")
    })
    #expect(try PDFParser.parse(report.data).pageIDs.count == report.pageCount)
    let text = try reportText(report.data)
    #expect(text.contains("Client Comparison"))
    #expect(text.contains("before.pdf"))
    #expect(text.contains("after.pdf"))
    #expect(text.contains("Chosen options"))
    #expect(text.contains("visualTolerance=3"))
    #expect(text.contains("Page mapping"))
    #expect(text.contains("Pair 1"))
    #expect(text.contains("pageReordered"))
    #expect(textKinds.contains { kind in
      fixture.result.changes.contains { $0.kind.rawValue == kind } && text.contains(kind)
    })
    #expect(text.contains("Left page"))
    #expect(text.contains("Right page"))
    #expect(text.contains("Uncertainty and mapping records"))
    #expect(text.contains("self-contained"))
    #expect(text.contains("Generated locally"))
  }

  @Test func deterministicBytesForTheSameInputs() throws {
    let fixture = try makeFixture()
    let request = ComparisonReportRequest(
      result: fixture.result, comparisonOptions: fixture.comparisonOptions,
      options: ComparisonReportOptions(
        title: "Deterministic", leftLabel: "L", rightLabel: "R"))
    let first = try ComparisonReportBuilder.build(request)
    let second = try ComparisonReportBuilder.build(request)
    #expect(first.data == second.data)
    #expect(first.pageCount == second.pageCount)
    #expect(try PDFWriter.write(fixture.right.graph) == fixture.right.source)
  }

  @Test func manualMappingAndUncertaintyAreRecorded() throws {
    let fixture = try makeFixture()
    let override = fixture.result.pageMapping.map { pair in
      PDFComparisonResult.PagePair(
        leftIndex: pair.leftIndex, rightIndex: pair.rightIndex,
        status: pair.status == .reordered ? .matched : pair.status)
    }
    let corrected = try PDFComparison.compare(
      left: fixture.left, right: fixture.right,
      options: fixture.comparisonOptions, mappingOverride: override)
    let report = try ComparisonReportBuilder.build(
      ComparisonReportRequest(
        result: corrected, comparisonOptions: fixture.comparisonOptions,
        options: ComparisonReportOptions(mappingWasEdited: true)))
    #expect(report.optionLines.contains("report.mappingSource=manually corrected"))
    #expect(report.uncertaintyRecords.contains {
      $0.contains("manually corrected")
    })
    let text = try reportText(report.data)
    #expect(text.contains("manually corrected"))
    #expect(text.contains("UNCERTAIN") == false
      || report.mappingRecords.contains { $0.isUncertain })
  }

  @Test func identicalDocumentsProduceAValidNoDifferenceReport() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let data = try PDFWriter.write(parsed.graph)
    let result = try PDFComparison.compare(
      left: (parsed.graph, data), right: (parsed.graph, data))
    #expect(result.changes.filter { $0.kind != .signatureStatus && $0.kind != .encryptionStatus }.isEmpty)
    let report = try ComparisonReportBuilder.build(
      ComparisonReportRequest(
        result: result, options: ComparisonReportOptions(includeUnchangedPairs: true)))
    #expect(report.mappingRecords.count == parsed.pageIDs.count)
    #expect(report.changeRecords.isEmpty)
    // The default rendered-difference tolerance is always recorded as an
    // explicit uncertainty/limits note.
    #expect(report.uncertaintyRecords.contains { $0.contains("tolerance") })
    let text = try reportText(report.data)
    #expect(text.contains("No differences were detected"))
    #expect(text.contains("Page mapping"))
    #expect(try PDFParser.parse(report.data).pageIDs.count == report.pageCount)
  }

  @Test func regionImagesAndPairImagesAreBoundedRefusals() throws {
    let fixture = try makeFixture()
    #expect(throws: PDFError.self) {
      _ = try ComparisonReportBuilder.build(
        ComparisonReportRequest(
          result: fixture.result,
          pairImages: [
            fixture.result.pageMapping.count: ComparisonReportPairImages(
              left: raster(), right: raster())
          ]))
    }
    #expect(throws: PDFError.self) {
      _ = try ComparisonReportBuilder.build(
        ComparisonReportRequest(
          result: fixture.result,
          regionImages: [fixture.result.changes.count: raster()]))
    }
    let invalid = ReportRasterImage(width: 2, height: 2, rgb8: Data([1, 2, 3]))
    #expect(throws: PDFError.self) {
      _ = try ComparisonReportBuilder.build(
        ComparisonReportRequest(result: fixture.result, regionImages: [0: invalid]))
    }
  }

  @Test func changeFocusOptionsAreRecorded() {
    let lines = ComparisonReportBuilder.describe(
      comparisonOptions: PDFComparisonOptions(
        ignoreWhitespace: false, includeText: true, includeImages: false,
        includeAnnotations: false, includeForms: false, includeMetadata: false,
        includeOCRText: true, visualTolerance: 7))
    #expect(lines.contains("ignoreWhitespace=false"))
    #expect(lines.contains("includeImages=false"))
    #expect(lines.contains("includeOCRText=true"))
    #expect(lines.contains("visualTolerance=7"))
  }
}
