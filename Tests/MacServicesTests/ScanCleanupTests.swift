import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import PDFFixtures
import Testing

@Suite("Scan cleanup")
struct ScanCleanupTests {
  func skewedRaster() throws -> ScanRaster {
    try ScanTestSupport.raster(
      lines: [
        .init(text: "SCAN TEXT", baseline: 560, x: 48),
        .init(text: "SECOND LINE", baseline: 480, x: 48),
        .init(text: "THIRD LINE", baseline: 400, x: 48),
      ], skewDegrees: 3.5, background: 228)
  }

  func uniformOrientation(_ raster: ScanRaster) -> Int? { 0 }

  func refusalMessage(_ refusal: ScanCleanupRefusal?) -> String {
    refusal?.message ?? "supported"
  }

  @Test func previewDetectsSkewWithoutMutating() throws {
    let raster = try skewedRaster()
    let fixture = try ScanTestSupport.graph(scans: [raster])
    let before = try ScanTestSupport.savedBytes(fixture.graph)
    let preview = ScanCleanupService.preview(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph,
      options: ScanCleanupOptions(), orientationDetector: uniformOrientation)
    #expect(preview.isSupported)
    let detection = try #require(preview.detection)
    #expect(abs(abs(detection.skewDegrees) - 3.5) <= 1.2, "detected \(detection.skewDegrees)")
    #expect(preview.beforePNG != nil)
    #expect(preview.afterPNG != nil)
    #expect(preview.cleanedRaster != nil)
    // A preview must never mutate the document graph.
    #expect(try ScanTestSupport.savedBytes(fixture.graph) == before)
  }

  @Test func appliedCleanupMatchesPreviewAndPreservesInk() throws {
    let raster = try skewedRaster()
    let fixture = try ScanTestSupport.graph(scans: [raster])
    let plan = ScanCleanupService.plan(
      pageIndices: [0], in: fixture.graph, options: ScanCleanupOptions(),
      orientationDetector: uniformOrientation)
    #expect(plan.refusals.isEmpty)
    let transaction = try #require(plan.transaction)
    let preview = try #require(plan.previews.first)
    let expected = try #require(preview.cleanedRaster)
    let cleanedGraph = try PDFEditingEngine.commit(transaction, to: fixture.graph)
    let reopened = try ScanTestSupport.reopened(cleanedGraph)
    let saved = try ScanTestSupport.firstRaster(
      pageID: fixture.pageIDs[0], in: reopened)
    // The saved scan is byte-identical to the previewed raster.
    #expect(saved.width == expected.width && saved.height == expected.height)
    #expect(saved.rgb8 == expected.rgb8)
    // Deskew actually straightened the content.
    #expect(abs(ScanInkAnalysis.estimateSkewDegrees(saved)) <= 0.8)
    // Ink is preserved while light scanner background becomes paper white.
    let beforeInk = ScanInkAnalysis.inkPixelCount(raster)
    let afterInk = ScanInkAnalysis.inkPixelCount(saved)
    #expect(afterInk >= Int(Double(beforeInk) * 0.55))
    func whiteFraction(_ raster: ScanRaster) -> Double {
      var count = 0
      for y in 0..<raster.height {
        for x in 0..<raster.width where raster.luminance(x: x, y: y) >= 250 {
          count += 1
        }
      }
      return Double(count) / Double(raster.pixelCount)
    }
    #expect(whiteFraction(saved) > whiteFraction(raster))
    // The cached image draw keeps the page placement aspect ratio.
    let aspect = Double(saved.width) / Double(saved.height)
    #expect(abs(aspect - 1.0) < 0.02)
    let report = try #require(plan.reports.first)
    #expect(report.searchableTextInvalidated == false)
    #expect(report.originalImageBytesHash.count == 64)
    #expect(report.originalImageID == fixture.imageIDs[0])
    #expect(plan.cleanedPageIndices == [0])
  }

  @Test func originalScanStaysRecoverableAfterCleanup() throws {
    let raster = try skewedRaster()
    let fixture = try ScanTestSupport.graph(scans: [raster])
    let plan = ScanCleanupService.plan(
      pageIndices: [0], in: fixture.graph, options: ScanCleanupOptions(),
      orientationDetector: uniformOrientation)
    let cleaned = try PDFEditingEngine.commit(
      try #require(plan.transaction), to: fixture.graph)
    // The source image object is untouched: cleanup attaches a new instance.
    if case .stream(let stream)? = cleaned.objects[fixture.imageIDs[0]] {
      #expect(stream.bytes == raster.rgb8)
    } else {
      Issue.record("The original scan image object was removed")
    }
    // The page draw points at a different image instance than the original.
    let placements = try ImageInventory.placements(
      in: cleaned, pageID: fixture.pageIDs[0])
    #expect(placements.count == 1)
    #expect(placements[0].imageID != fixture.imageIDs[0])
  }

  @Test func jpegScanDecodesAndCleansUp() throws {
    let raster = try skewedRaster()
    let fixture = try ScanTestSupport.jpegGraph(scans: [raster])
    let preview = ScanCleanupService.preview(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph,
      options: ScanCleanupOptions(), orientationDetector: uniformOrientation)
    #expect(preview.isSupported)
    #expect(preview.cleanedRaster != nil)
    let plan = ScanCleanupService.plan(
      pageIndices: [0], in: fixture.graph, options: ScanCleanupOptions(),
      orientationDetector: uniformOrientation)
    let cleaned = try PDFEditingEngine.commit(
      try #require(plan.transaction), to: fixture.graph)
    let reopened = try ScanTestSupport.reopened(cleaned)
    let saved = try ScanTestSupport.firstRaster(
      pageID: fixture.pageIDs[0], in: reopened)
    #expect(abs(ScanInkAnalysis.estimateSkewDegrees(saved)) <= 1.0)
    #expect(ScanInkAnalysis.inkPixelCount(saved) > 0)
    let aspect = Double(saved.width) / Double(saved.height)
    #expect(abs(aspect - 1.0) < 0.02)
  }

  @Test func selectiveApplicationLeavesOtherPagesUntouched() throws {
    let first = try skewedRaster()
    let second = try ScanTestSupport.raster(
      lines: [.init(text: "OTHER PAGE", baseline: 500, x: 48)], background: 238)
    let fixture = try ScanTestSupport.graph(scans: [first, second])
    let plan = ScanCleanupService.plan(
      pageIndices: [0], in: fixture.graph, options: ScanCleanupOptions(),
      orientationDetector: uniformOrientation)
    let transaction = try #require(plan.transaction)
    let cleanedGraph = try PDFEditingEngine.commit(transaction, to: fixture.graph)
    let reopened = try ScanTestSupport.reopened(cleanedGraph)
    let untouched = try ScanTestSupport.firstRaster(
      pageID: fixture.pageIDs[1], in: reopened)
    #expect(untouched.rgb8 == second.rgb8)
    #expect(plan.reports.count == 1)
    #expect(plan.cleanedPageIndices == [0])
  }

  @Test func explicitCropThatCutsInkRefuses() throws {
    let raster = try skewedRaster()
    let fixture = try ScanTestSupport.graph(scans: [raster])
    // Crop the top of the scan only; the lower text lines would be cut.
    let options = ScanCleanupOptions(crop: .pageRect([0, 560, 400, 650]))
    let preview = ScanCleanupService.preview(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph,
      options: options, orientationDetector: uniformOrientation)
    #expect(!preview.isSupported)
    #expect(preview.refusal?.message.lowercased().contains("crop") == true)
  }

  @Test func automaticOrientationRefusesWithoutDetector() throws {
    let raster = try skewedRaster()
    let fixture = try ScanTestSupport.graph(scans: [raster])
    let options = ScanCleanupOptions(orientation: .automatic)
    let refused = ScanCleanupService.preview(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph,
      options: options, orientationDetector: { _ in nil })
    #expect(!refused.isSupported)
    #expect(refused.refusal?.message.lowercased().contains("orientation") == true)
    let rotated = ScanCleanupService.preview(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph,
      options: options, orientationDetector: { _ in 1 })
    #expect(rotated.isSupported)
    #expect(rotated.report?.appliedOrientationQuarterTurns == 1)
  }

  @Test func refusalsForNoImageAmbiguousAndMasked() throws {
    let blank = try PDFParser.parse(PDFFixtures.onePage()).graph
    let blankPages = try PDFPageTree.pageIDs(in: blank)
    let missing = ScanCleanupService.preview(
      pageIndex: 0, pageID: blankPages[0], in: blank,
      options: ScanCleanupOptions(), orientationDetector: { _ in 0 })
    #expect(!missing.isSupported)
    #expect(missing.refusal?.message.lowercased().contains("no scanned image") == true)

    let raster = try skewedRaster()
    let ambiguous = try ScanTestSupport.ambiguousGraph(
      first: raster, second: try ScanTestSupport.raster(
        lines: [.init(text: "SECOND", baseline: 400, x: 48)]))
    let ambiguousPages = try PDFPageTree.pageIDs(in: ambiguous)
    let ambiguousPreview = ScanCleanupService.preview(
      pageIndex: 0, pageID: ambiguousPages[0], in: ambiguous,
      options: ScanCleanupOptions(), orientationDetector: { _ in 0 })
    #expect(!ambiguousPreview.isSupported)
    #expect(
      ambiguousPreview.refusal?.message.lowercased().contains("unambiguous scan") == true)

    var fixture = try ScanTestSupport.graph(scans: [raster])
    if case .stream(var stream)? = fixture.graph.objects[fixture.imageIDs[0]] {
      stream.dictionary[PDFName("SMask")] = .dictionary([:])
      fixture.graph.objects[fixture.imageIDs[0]] = .stream(stream)
    } else {
      Issue.record("The synthetic scan image is missing")
    }
    let masked = ScanCleanupService.preview(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph,
      options: ScanCleanupOptions(), orientationDetector: { _ in 0 })
    #expect(!masked.isSupported)
    #expect(masked.refusal?.message.lowercased().contains("mask") == true)
  }
}
