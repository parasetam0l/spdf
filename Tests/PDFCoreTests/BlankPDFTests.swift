import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite("Blank PDF")
struct BlankPDFTests {
  @Test(arguments: BlankPageFormat.allCases, [false, true])
  func newDocumentHasOneEmptyPageWithSelectedPaper(
    format: BlankPageFormat, landscape: Bool
  ) throws {
    let data = try BlankPDF.data(format: format, landscape: landscape)
    let provider = try #require(CGDataProvider(data: data as CFData))
    let independent = try #require(CGPDFDocument(provider))
    #expect(independent.numberOfPages == 1)
    let page = try #require(independent.page(at: 1))
    let box = page.getBoxRect(.mediaBox)
    let portrait = format == .a4 ? (595.276, 841.89) : (612.0, 792.0)
    #expect(abs(Double(box.width) - (landscape ? portrait.1 : portrait.0)) < 0.001)
    #expect(abs(Double(box.height) - (landscape ? portrait.0 : portrait.1)) < 0.001)
    #expect(page.rotationAngle == 0)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageIDs.count == 1)
    #expect(parsed.graph.trailer[PDFName("Info")] == nil)
    if case .dictionary(let dictionary) = parsed.graph.objects[parsed.pageIDs[0]] {
      #expect(dictionary[PDFName("Contents")] == nil)
      #expect(dictionary[PDFName("Annots")] == nil)
    } else { Issue.record("Missing blank page dictionary") }
  }
}
