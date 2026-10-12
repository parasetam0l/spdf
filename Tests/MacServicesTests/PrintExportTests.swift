import AppKit
import CoreGraphics
import Foundation
import PDFCore
import PDFFixtures
import Testing
@testable import MacServices

/// P34-021–P34-024: print-to-PDF page selection, page-box and rotation
/// geometry, and non-blank rendered output.
@Suite("Print export")
@MainActor
struct PrintExportTests {
  private func document(from data: Data) throws -> CGPDFDocument {
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider)
    else { throw PageImageExport.ExportError.cannotOpenDocument }
    return document
  }

  private func pageSize(_ page: CGPDFPage) -> CGSize {
    let box = page.getBoxRect(.mediaBox)
    return box.size
  }

  /// Fraction of non-white pixels in a rendered page (blank detection).
  private func nonWhiteFraction(of page: CGPDFPage) -> Double {
    let width = 200
    let height = 260
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return 0 }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: CGFloat(width) / 612, y: CGFloat(height) / 792)
    context.concatenate(
      page.getDrawingTransform(
        .cropBox, rect: CGRect(x: 0, y: 0, width: 612, height: 792), rotate: 0,
        preserveAspectRatio: true))
    context.drawPDFPage(page)
    guard let image = context.makeImage(), let data = image.dataProvider?.data,
      let bytes = CFDataGetBytePtr(data)
    else { return 0 }
    var nonWhite = 0
    let count = image.bytesPerRow * image.height
    var index = 0
    while index + 3 < count {
      if bytes[index] < 250 || bytes[index + 1] < 250 || bytes[index + 2] < 250 { nonWhite += 1 }
      index += 4
    }
    return Double(nonWhite) / Double(width * height)
  }

  @Test func printPDFWritesSelectedPagesWithPageBoxes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-print-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try PDFPrintExport.writePDF(pageIDs: parsed.pageIDs, in: parsed.graph, to: url)
    let data = try Data(contentsOf: url)
    let printed = try document(from: data)
    #expect(printed.numberOfPages == 1)
    let page = try #require(printed.page(at: 1))
    #expect(pageSize(page) == CGSize(width: 612, height: 792))
    #expect(nonWhiteFraction(of: page) > 0.001)

    // Selecting a subset writes only that subset.
    let twoPages = try PDFParser.parse(PDFWriter.write(PDFFixtures.graph(pages: 2)))
    let subsetURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-print-subset-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: subsetURL) }
    try PDFPrintExport.writePDF(
      pageIDs: [twoPages.pageIDs[1]], in: twoPages.graph, to: subsetURL)
    let subset = try document(from: Data(contentsOf: subsetURL))
    #expect(subset.numberOfPages == 1)
  }

  @Test func printPDFMatchesRotationGeometry() throws {
    // The second page carries /Rotate 90; the print paper covers the largest
    // display box (842 x 792 here) and both pages are letterboxed into it.
    let parsed = try PDFParser.parse(
      PDFWriter.write(PDFFixtures.graph(pages: 2, rotatedLastPage: true)))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-print-rot-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try PDFPrintExport.writePDF(pageIDs: parsed.pageIDs, in: parsed.graph, to: url)
    let printed = try document(from: Data(contentsOf: url))
    #expect(printed.numberOfPages == 2)
    let first = try #require(printed.page(at: 1))
    let second = try #require(printed.page(at: 2))
    #expect(pageSize(first) == CGSize(width: 842, height: 792))
    #expect(pageSize(second) == CGSize(width: 842, height: 792))
    #expect(nonWhiteFraction(of: first) > 0.0005)
    #expect(nonWhiteFraction(of: second) > 0.0005)
  }

  @Test func pageViewExposesPaginatedRange() throws {
    let parsed = try PDFParser.parse(PDFWriter.write(PDFFixtures.graph(pages: 3)))
    let view = try PDFPrintExport.pageView(pageIDs: parsed.pageIDs, in: parsed.graph)
    var range = NSRange()
    #expect(view.knowsPageRange(&range))
    #expect(range.location == 1 && range.length == 3)
    #expect(view.rectForPage(1) == view.bounds)
    // The three-page fixture mixes 612x792 and 595x842 pages, so the paper
    // covers the largest display box.
    #expect(view.frame.size == CGSize(width: 612, height: 842))
    let single = try PDFParser.parse(PDFFixtures.onePage())
    let singleView = try PDFPrintExport.pageView(pageIDs: single.pageIDs, in: single.graph)
    #expect(singleView.frame.size == CGSize(width: 612, height: 792))
  }
}
