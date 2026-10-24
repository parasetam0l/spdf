import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// PAG-08: image-only PDF creation.
@Suite("Image PDF creation")
struct ImagePDFCreationTests {
  private func source(width: Int, height: Int, value: UInt8) -> ImagePDFCreation.Source {
    ImagePDFCreation.Source(
      width: width, height: height,
      rgb8: Data(repeating: value, count: width * height * 3))
  }

  @Test func originalLayoutCreatesOnePagePerImage() throws {
    let data = try ImagePDFCreation.make(
      sources: [
        source(width: 4, height: 2, value: 255),
        source(width: 2, height: 3, value: 0),
      ], layout: .original)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageCount == 2)
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(attributes[0].mediaBox == [0, 0, 4, 2])
    #expect(attributes[1].mediaBox == [0, 0, 2, 3])
    for pageID in parsed.pageIDs {
      #expect(try ImageInventory.placements(in: parsed.graph, pageID: pageID).count == 1)
    }
  }

  @Test func letterLayoutFitsImagesInsideMargins() throws {
    let data = try ImagePDFCreation.make(
      sources: [source(width: 400, height: 200, value: 128)], layout: .letter)
    let parsed = try PDFParser.parse(data)
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(attributes[0].mediaBox == [0, 0, 612, 792])
    let placement = try #require(
      ImageInventory.placements(in: parsed.graph, pageID: parsed.pageIDs[0]).first)
    #expect(placement.bounds[0] >= 36)
    #expect(placement.bounds[1] >= 36)
    #expect(placement.bounds[2] <= 576)
    #expect(placement.bounds[3] <= 756)
    #expect(abs((placement.bounds[2] - placement.bounds[0]) - 540) < 0.01)
  }

  @Test func emptySourcesAndInvalidSamplesAreRefused() throws {
    #expect(throws: PDFError.self) {
      _ = try ImagePDFCreation.make(sources: [])
    }
    #expect(throws: PDFError.self) {
      _ = try ImagePDFCreation.make(
        sources: [ImagePDFCreation.Source(width: 2, height: 2, rgb8: Data([1, 2]))])
    }
  }
}
