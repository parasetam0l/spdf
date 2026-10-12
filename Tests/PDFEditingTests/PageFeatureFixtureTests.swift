import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P03-012–P03-016/P03-021: page-feature fixtures — crop boxes, transformed
/// baselines, image masks, form placements, annotation relationships, and
/// the scanned page with its documented transcription.
@Suite("Page feature fixtures")
struct PageFeatureFixtureTests {
  private func layout(of data: Data, pageIndex: Int = 0) throws -> PageTextLayout {
    let parsed = try PDFParser.parse(data)
    let content = try PageContent.load(pageID: parsed.pageIDs[pageIndex], in: parsed.graph)
    return try PageTextLayout.build(in: content, graph: parsed.graph)
  }

  @Test func croppedAndRotatedPagesResolve() throws {
    let parsed = try PDFParser.parse(PDFFixtures.croppedPages())
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(attributes[0].cropBox == [10, 20, 602, 772])
    #expect(attributes[0].displayBox == [10, 20, 602, 772])
    #expect(attributes[1].rotation == 90)
    let page = try layout(of: PDFFixtures.croppedPages())
    #expect(page.text(in: page.lines[0]) == "Cropped fixture")
  }

  @Test func transformedBaselinesKeepTextReadable() throws {
    let page = try layout(of: PDFFixtures.transformedTextPages())
    #expect(page.lines.count == 2)
    let texts = page.lines.map { page.text(in: $0) }.sorted()
    #expect(texts == ["Rotated line", "Scaled line"])
    // The scaled line advances twice as fast per glyph.
    let scaled = page.clusters.filter { $0.text == "S" }
    #expect(!scaled.isEmpty)
  }

  @Test func maskedImagesInventoryWithProvenance() throws {
    let parsed = try PDFParser.parse(PDFFixtures.maskedImagePages())
    let placements = try PDFImageInventory.images(in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(placements.count == 2)
    #expect(placements.map(\.name).sorted() == ["Mask1", "Photo1"])
    let mask = placements.first { $0.name == "Mask1" }
    #expect(mask?.isImageMask == true)
    let photo = placements.first { $0.name == "Photo1" }
    #expect(photo?.hasSMask == true)
  }

  @Test func formXObjectsPlaceRepeatedly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formXObjectPages())
    #expect(parsed.pageIDs.count == 2)
    let first = try ContentInterpreter.trace(
      pageID: parsed.pageIDs[0], in: parsed.graph)
    let second = try ContentInterpreter.trace(
      pageID: parsed.pageIDs[1], in: parsed.graph)
    #expect(first.draws.filter { $0.kind == .form }.count == 2)
    #expect(second.draws.filter { $0.kind == .form }.count == 1)
    let formDraws = (first.draws + second.draws).filter { $0.kind == .form }
    #expect(formDraws.count == 3)
    #expect(Set(formDraws.map(\.resourceName)) == Set(["Fm1"]))
    // The form's own vector content is interpreted inline (paths without a
    // placement name) rather than skipped as an opaque resource.
    #expect(first.draws.contains { $0.kind == .path && $0.resourceName == nil })
  }

  @Test func annotationRepliesAndAppearancesResolve() throws {
    let parsed = try PDFParser.parse(PDFFixtures.annotationPages())
    let first = try AnnotationInventory.annotations(
      in: parsed.graph, pageID: parsed.pageIDs[0])
    #expect(first.count == 2)
    let reply = first.first { $0.dictionary[PDFName("IRT")] != nil }
    #expect(reply?.dictionary[PDFName("Contents")] == .string(Data("Reply note".utf8)))
    let parent = first.first { $0.dictionary[PDFName("AP")] != nil }
    #expect(parent?.dictionary[PDFName("Contents")] == .string(Data("Parent note".utf8)))
    // The rotated page carries its own annotation.
    let rotated = try AnnotationInventory.annotations(
      in: parsed.graph, pageID: parsed.pageIDs[1])
    #expect(rotated.count == 1)
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(attributes[1].rotation == 90)
  }

  @Test func scannedPageAcceptsDocumentedTranscription() throws {
    let parsed = try PDFParser.parse(PDFFixtures.scannedPages())
    let pageID = parsed.pageIDs[0]
    // Image-only: no text operators, one image placement.
    #expect(OCRLayer.pageShowsText(pageID, in: parsed.graph) == false)
    let placements = try PDFImageInventory.images(in: parsed.graph, pageIDs: [pageID])
    #expect(placements.count == 1)
    // The manifest's known transcription feeds the searchable-layer
    // pipeline as explicitly supplied recognized input.
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [
            SearchableTextLine(
              text: "SCANNED INVOICE 0042", rect: [72, 680, 400, 704],
              confidence: 0.93)
          ])
      ]), to: parsed.graph)
    #expect(OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID))
    // The documented transcription lands in the invisible layer stream as
    // UTF-16BE CIDs (our layout engine does not decode Type0 text yet; the
    // independent-reader suite covers extraction of generated layers).
    let streamIDs = OCRLayer.layerStreamIDs(in: graph, pageID: pageID)
    #expect(streamIDs.count == 1)
    guard let streamID = streamIDs.first,
      case .stream(let stream)? = graph.objects[streamID]
    else {
      Issue.record("OCR layer stream is missing")
      return
    }
    let layered = String(decoding: stream.bytes, as: UTF8.self)
    #expect(layered.contains("3 Tr"))
    #expect(layered.contains("<005300430041004E004E0045004400200049004E0056004F00490043004500200030003000340032>"))
  }
}
