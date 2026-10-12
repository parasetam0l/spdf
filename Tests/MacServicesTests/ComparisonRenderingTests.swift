import AppKit
import Foundation
@testable import MacServices
import PDFCore
import PDFFixtures
import Testing

/// P32-006/P32-007/P32-027 evidence: rendered-page difference images with an
/// explicit per-channel tolerance, and tolerance settings that cannot hide
/// known content changes.
@Suite("Comparison rendering")
struct ComparisonRenderingTests {
  @Test func renderedDifferencesRespectTolerance() throws {
    let width = 4
    let height = 4
    let bytesPerRow = width * 4
    let samples = 4
    var left = [UInt8](repeating: 100, count: bytesPerRow * height)
    left[3] = 255
    var subtle = left
    subtle[0] = 101  // one-unit red shift
    subtle[3] = 255

    let ignored = try #require(
      PageDifferenceRenderer.difference(
        leftPixels: left, rightPixels: subtle, width: width, height: height,
        bytesPerRow: bytesPerRow, samplesPerPixel: samples, tolerance: 2))
    #expect(ignored.changedPixelRatio == 0)
    #expect(ignored.maximumDifference == 1)

    let strict = try #require(
      PageDifferenceRenderer.difference(
        leftPixels: left, rightPixels: subtle, width: width, height: height,
        bytesPerRow: bytesPerRow, samplesPerPixel: samples, tolerance: 0))
    #expect(strict.changedPixelRatio > 0)

    // P32-027: a substantive change is reported even at the default tolerance.
    var substantive = left
    substantive[4] = 250
    let flagged = try #require(
      PageDifferenceRenderer.difference(
        leftPixels: left, rightPixels: substantive, width: width, height: height,
        bytesPerRow: bytesPerRow, samplesPerPixel: samples, tolerance: 2))
    #expect(flagged.changedPixelRatio == 1.0 / Double(width * height))
    #expect(flagged.maximumDifference == 150)

    let identical = try #require(
      PageDifferenceRenderer.difference(
        leftPixels: left, rightPixels: left, width: width, height: height,
        bytesPerRow: bytesPerRow, samplesPerPixel: samples, tolerance: 2))
    #expect(identical.changedPixelRatio == 0)
    #expect(identical.maximumDifference == 0)
  }

  @Test func pageDifferenceImagesMarkChangedContent() throws {
    let size = NSSize(width: 300, height: 400)
    let document = try PDFFixtures.threePages()

    let same = try #require(
      PageDifferenceRenderer.difference(
        left: document, right: document, pageIndex: 0, size: size, tolerance: 2))
    #expect(same.changedPixelRatio == 0)
    #expect(same.maximumDifference == 0)

    // formPages page 1 carries different text at the same page size.
    let changed = try #require(
      PageDifferenceRenderer.difference(
        left: document, right: try PDFFixtures.formPages(), pageIndex: 0, size: size,
        tolerance: 2))
    #expect(changed.changedPixelRatio > 0)
    #expect(changed.maximumDifference > 2)
    #expect(changed.tolerance == 2)
  }
}
