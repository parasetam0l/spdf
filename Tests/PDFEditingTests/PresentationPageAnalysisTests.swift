import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// EXP-03: page-level reconstruction decisions. Text with a supported
/// transform, image placements and solid rectangle/line vectors become
/// editable plans; everything else is reported as an explicit raster fallback.
@Suite("Presentation page analysis")
struct PresentationPageAnalysisTests {
  private func parse(_ data: Data) throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, parsed.pageIDs)
  }

  private func analyze(_ data: Data, pageIndex: Int = 0) throws -> PresentationPagePlan {
    let parsed = try parse(data)
    return try PresentationPageAnalyzer.analyze(
      pageIndex: pageIndex, pageID: parsed.pageIDs[pageIndex], in: parsed.graph)
  }

  private func textElements(_ plan: PresentationPagePlan) -> [PresentationPlannedText] {
    plan.elements.compactMap { element in
      guard case .text(let text) = element else { return nil }
      return text
    }
  }

  private func imageElements(_ plan: PresentationPagePlan) -> [PresentationPlannedImage] {
    plan.elements.compactMap { element in
      guard case .image(let image) = element else { return nil }
      return image
    }
  }

  private func shapeElements(_ plan: PresentationPagePlan) -> [PresentationPlannedShape] {
    plan.elements.compactMap { element in
      guard case .shape(let shape) = element else { return nil }
      return shape
    }
  }

  /// A one-page graph with the given content stream and the standard Helvetica
  /// font resource, matching the project fixture layout.
  private func graph(content: String) -> PDFGraph {
    let pageID = PDFObjectID(4)
    let contentID = PDFObjectID(5)
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(pageID)]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
        ]),
        contentID: .stream(PDFStream(bytes: Data(content.utf8))),
        pageID: .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([0, 0, 300, 300].map { .integer(Int64($0)) }),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(contentID),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func textOnlyPageBecomesEditableText() throws {
    let plan = try analyze(try PDFFixtures.textEditPages())
    #expect(!plan.requiresRasterFallback)
    let texts = textElements(plan)
    #expect(!texts.isEmpty)
    for text in texts.prefix(3) {
      #expect(!text.text.isEmpty)
      #expect(text.bounds.count == 4)
      #expect(text.bounds[2] > text.bounds[0])
      #expect(text.bounds[3] > text.bounds[1])
      #expect(text.fontSize > 0)
      #expect(!text.fontName.isEmpty)
      #expect(abs(text.rotationDegrees) < 0.001)
    }
    #expect(plan.unsupportedReasons.isEmpty)
  }

  @Test func transformedTextReportsItsRotation() throws {
    let parsed = try parse(try PDFFixtures.transformedTextPages())
    var rotations: [Double] = []
    for (index, pageID) in parsed.pageIDs.enumerated() {
      let plan = try PresentationPageAnalyzer.analyze(
        pageIndex: index, pageID: pageID, in: parsed.graph)
      #expect(!plan.requiresRasterFallback, "\(plan.unsupportedReasons)")
      rotations.append(contentsOf: textElements(plan).map(\.rotationDegrees))
    }
    #expect(!rotations.isEmpty)
    #expect(rotations.contains { abs($0 - 90) < 1 || abs($0 + 90) < 1 || abs(abs($0) - 90) < 1 })
  }

  @Test func imagePlacementsBecomePlannedPictures() throws {
    let plan = try analyze(try PDFFixtures.imagePages())
    #expect(
      !plan.requiresRasterFallback,
      Comment(rawValue: plan.unsupportedReasons.joined(separator: " | ")))
    let images = imageElements(plan)
    #expect(!images.isEmpty)
    for image in images.prefix(3) {
      #expect(!image.encodedData.isEmpty)
      #expect(image.bounds.count == 4)
      #expect(image.bounds[2] > image.bounds[0])
      #expect(!image.note.isEmpty)
    }
  }

  @Test func maskedImagesAreRenderedRegionsNotDirectBytes() throws {
    let plan = try analyze(try PDFFixtures.maskedImagePages())
    #expect(
      !plan.requiresRasterFallback,
      Comment(rawValue: plan.unsupportedReasons.joined(separator: " | ")))
    let images = imageElements(plan)
    #expect(!images.isEmpty)
    #expect(images.contains { !$0.canUseOriginalBytes })
    let rendered = images.filter { !$0.canUseOriginalBytes }
    #expect(rendered.contains { $0.note.contains("Rendered region") })
  }

  @Test func formXObjectAndAnnotationPagesAreFallbacks() throws {
    let formPlan = try analyze(try PDFFixtures.formXObjectPages())
    #expect(formPlan.requiresRasterFallback)
    #expect(formPlan.elements.isEmpty)
    #expect(formPlan.unsupportedReasons.contains { $0.contains("non-image XObject") })

    let annotationPlan = try analyze(try PDFFixtures.annotationPages())
    #expect(annotationPlan.requiresRasterFallback)
    #expect(annotationPlan.unsupportedReasons.contains { $0.contains("annotations") })
  }

  @Test func rotatedPageIsARasterFallback() throws {
    let data = try PDFWriter.write(PDFFixtures.graph(pages: 2, rotatedLastPage: true))
    let parsed = try parse(data)
    let plan = try PresentationPageAnalyzer.analyze(
      pageIndex: 1, pageID: parsed.pageIDs[1], in: parsed.graph)
    #expect(plan.requiresRasterFallback)
    #expect(plan.unsupportedReasons.contains { $0.contains("rotation") })
  }

  @Test func solidRectanglesAndLinesBecomeEditableShapes() throws {
    let plan = try analyze(try PDFFixtures.onePage())
    #expect(!plan.requiresRasterFallback, "\(plan.unsupportedReasons)")
    let shapes = shapeElements(plan)
    #expect(shapes.contains { $0.kind == .rectangle })
    let rectangle = shapes.first { $0.kind == .rectangle }
    #expect(rectangle?.fillColorHex != nil)
    #expect(rectangle?.bounds.count == 4)

    let custom = graph(
      content: "0 0 1 RG 2 w 20 40 m 120 40 l S\n0.5 0.5 0.5 rg 20 80 50 40 re f\n")
    let data = try PDFWriter.write(custom)
    let customPlan = try analyze(data)
    #expect(
      !customPlan.requiresRasterFallback,
      Comment(rawValue: customPlan.unsupportedReasons.joined(separator: " | ")))
    let customShapes = shapeElements(customPlan)
    #expect(customShapes.count == 2)
    #expect(customShapes.contains { $0.kind == .line && $0.strokeColorHex != nil })
    #expect(customShapes.contains { $0.kind == .rectangle && $0.fillColorHex != nil })
  }

  @Test func shearedTextIsAnExplicitRasterFallback() throws {
    let custom = graph(
      content: "BT /F1 12 Tf 1 0 0.4 1 40 40 Tm (Sheared) Tj ET\n")
    let data = try PDFWriter.write(custom)
    let plan = try analyze(data)
    #expect(plan.requiresRasterFallback)
    #expect(plan.unsupportedReasons.contains { $0.contains("skew") },
      Comment(rawValue: plan.unsupportedReasons.joined(separator: " | ")))
  }

  @Test func unknownOperatorsAreReportedNotDropped() throws {
    let custom = graph(content: "q 0 0 m 10 10 l S Q\n")
    let data = try PDFWriter.write(custom)
    let plan = try analyze(data)
    // The path is reconstructed as a line, so a supported page stays editable.
    #expect(!plan.requiresRasterFallback, "\(plan.unsupportedReasons)")
    #expect(plan.elements.contains { element in
      if case .shape(let shape) = element { return shape.kind == .line }
      return false
    })

    let shading = graph(content: "q 0 0 10 10 re W n /Sh1 sh Q\n")
    let shadingData = try PDFWriter.write(shading)
    let shadingPlan = try analyze(shadingData)
    #expect(shadingPlan.requiresRasterFallback)
    #expect(shadingPlan.unsupportedReasons.contains { $0.contains("Shading") })
  }
}
