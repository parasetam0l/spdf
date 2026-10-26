import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PRE-09 evidence: quality-preset planning, measured downsampling/lossy
/// behavior, resource reports and preservation of forms/OCR/tags/masks/fonts.
@Suite("Quality optimization (PRE-09)")
struct QualityOptimizationTests {
  private func large() throws -> ParsedPDF {
    try PDFParser.parse(OptimizationQualityFixture.largeRGBImagePages())
  }

  @Test func plansAndMeasuresWebDownsampling() throws {
    let parsed = try large()
    let plan = try QualityOptimizer.plan(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .web)
    #expect(plan.isUsable, Comment(rawValue: plan.summary))
    #expect(plan.changes.count == 1)
    let change = try #require(plan.changes.first)
    #expect(change.kind == "image")
    #expect(change.before.contains("1200x900"))
    #expect(change.before.contains("864 dpi"))
    #expect(change.after.contains("208x156"))
    #expect(change.after.contains("150 dpi"))
    let applied = try QualityOptimizer.optimize(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .web)
    #expect(applied.report.measuredDPI["Im1"].map { abs($0 - 150) < 3 } == true)
    #expect(applied.report.optimizedBytes < applied.report.originalBytes)
    let output = try PDFParser.parse(applied.data)
    let image = try #require(
      try PDFImageInventory.images(in: output.graph, pageIDs: output.pageIDs).first)
    #expect(image.width == 208)
  }

  @Test func printPresetTargetsThreeHundredDPI() throws {
    let parsed = try large()
    let plan = try QualityOptimizer.plan(parsed.graph, pageIDs: parsed.pageIDs, preset: .print)
    #expect(plan.changes.first?.after.contains("417x313") == true)
    let applied = try QualityOptimizer.optimize(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .print)
    #expect(applied.report.measuredDPI["Im1"].map { abs($0 - 300) < 5 } == true)
  }

  @Test func smallestPresetIsExplicitlyLossyAndMeasured() throws {
    let parsed = try large()
    let plan = try QualityOptimizer.plan(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .smallest)
    #expect(plan.preset.isLossy)
    let applied = try QualityOptimizer.optimize(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .smallest)
    #expect(applied.report.preset.isLossy)
    #expect(applied.report.preservation.passed)
    let output = try PDFParser.parse(applied.data)
    let image = try #require(
      try PDFImageInventory.images(in: output.graph, pageIDs: output.pageIDs).first)
    #expect(image.width < 208)
    #expect(applied.report.optimizedBytes < applied.report.originalBytes)
  }

  @Test func losslessPresetKeepsPixelsIdentical() throws {
    let parsed = try large()
    let sourceImage = try #require(
      try PDFImageInventory.images(in: parsed.graph, pageIDs: parsed.pageIDs).first)
    let sourceObject = try #require(sourceImage.objectID)
    let sourceStream = try #require(parsed.graph.objects[sourceObject])
    guard case .stream(let stream) = sourceStream else { Issue.record("stream"); return }
    let sourcePixels = try PDFFilters.decoded(stream)
    let plan = try QualityOptimizer.plan(parsed.graph, pageIDs: parsed.pageIDs, preset: .lossless)
    #expect(plan.changes.isEmpty)
    let applied = try QualityOptimizer.optimize(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .lossless)
    let output = try PDFParser.parse(applied.data)
    let outputImage = try #require(
      try PDFImageInventory.images(in: output.graph, pageIDs: output.pageIDs).first)
    let outputObject = try #require(outputImage.objectID)
    guard case .stream(let outputStream)? = output.graph.objects[outputObject] else {
      Issue.record("stream"); return
    }
    #expect(try PDFFilters.decoded(outputStream) == sourcePixels)
    #expect(applied.report.losslessBytes != nil)
  }

  @Test func maskedImagesAreRefusedNotFlattened() throws {
    let parsed = try PDFParser.parse(PDFFixtures.maskedImagePages())
    let plan = try QualityOptimizer.plan(
      parsed.graph, pageIDs: parsed.pageIDs, preset: .web)
    #expect(!plan.isUsable)
    #expect(plan.refusals.contains { $0.contains("masked") })
    #expect(throws: PDFError.self) {
      _ = try QualityOptimizer.apply(plan, to: parsed.graph, pageIDs: parsed.pageIDs)
    }
  }

  @Test func formsTagsAndFontsRemainValid() throws {
    let form = try PDFParser.parse(PDFFixtures.formPages())
    let formPlan = try QualityOptimizer.plan(form.graph, pageIDs: form.pageIDs, preset: .web)
    #expect(formPlan.preservation.formsIntact)
    #expect(formPlan.preservation.fontsIntact)
    let tagged = try PDFParser.parse(PDFFixtures.taggedPages())
    let taggedPlan = try QualityOptimizer.plan(
      tagged.graph, pageIDs: tagged.pageIDs, preset: .web)
    #expect(taggedPlan.preservation.tagsIntact)
    let font = try PDFParser.parse(PDFFixtures.fontEmbeddedPages())
    let fontPlan = try QualityOptimizer.plan(font.graph, pageIDs: font.pageIDs, preset: .web)
    #expect(fontPlan.preservation.fontsIntact)
    #expect(fontPlan.preservation.passed)
  }

  @Test func ocrLayerSurvivesOptimization() throws {
    let parsed = try PDFParser.parse(PDFFixtures.scannedPages())
    let pageID = try #require(parsed.pageIDs.first)
    let withLayer = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "OCR text", rect: [100, 600, 300, 640])])
      ]), to: parsed.graph)
    let plan = try QualityOptimizer.plan(withLayer, pageIDs: parsed.pageIDs, preset: .web)
    #expect(plan.preservation.ocrLayersIntact)
    let applied = try QualityOptimizer.apply(plan, to: withLayer, pageIDs: parsed.pageIDs)
    #expect(applied.report.preservation.ocrLayersIntact)
    #expect(OCRLayer.hasGeneratedLayer(in: applied.graph, pageID: pageID))
  }
}

