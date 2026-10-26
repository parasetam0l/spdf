import CoreGraphics
import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("Advanced print planning")
struct PrintProductionPlanTests {
  private func pageBoxes(_ sizes: [[Double]]) -> [[Double]] {
    sizes.map { [0, 0, $0[0], $0[1]] }
  }

  @Test func singleLayoutPreservesOrderAndMixedSizes() throws {
    let boxes = pageBoxes([[612, 792], [595, 842], [612, 792]])
    var options = PDFAdvancedPrintOptions(layout: .single)
    options.mixedPageSizes = true
    let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: boxes, options: options)
    #expect(plan.outputPageCount == 3)
    #expect(plan.sides.map(\.placements.first?.sourcePageIndex) == [0, 1, 2])
    #expect(plan.sides[0].paperSize == [648, 828])
    #expect(plan.sides[1].paperSize == [631, 878])
    #expect(plan.sides[2].paperSize == [648, 828])
    #expect(plan.sheets.count == 3)
    for side in plan.sides {
      let placement = try #require(side.placements.first)
      #expect(placement.scale > 0)
      #expect(placement.targetRect[0] >= 18 - 0.01)
      #expect(placement.targetRect[1] >= 18 - 0.01)
      #expect(placement.targetRect[0] + placement.targetRect[2] <= 660 + 0.01)
    }
  }

  @Test func nUpIsRowMajorWithGutterAndClippingCells() throws {
    let boxes = pageBoxes(Array(repeating: [612, 792], count: 5))
    let options = PDFAdvancedPrintOptions(
      layout: .nUp(rows: 2, columns: 2), scale: .fit, paperSize: [612, 792],
      margin: 18, gutter: 12)
    let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: boxes, options: options)
    #expect(plan.outputPageCount == 2)
    #expect(plan.sides[0].placements.map(\.sourcePageIndex) == [0, 1, 2, 3])
    #expect(plan.sides[1].placements.map(\.sourcePageIndex) == [4])
    let first = plan.sides[0].placements[0]
    let second = plan.sides[0].placements[1]
    let third = plan.sides[0].placements[2]
    // Row 0 is the top row: first/second are above third/fourth.
    #expect(first.targetRect[1] > third.targetRect[1])
    #expect(first.targetRect[0] < second.targetRect[0])
    let clip = try #require(first.clipRect)
    #expect(abs(clip[2] - (612 - 36 - 12) / 2) < 0.01)
    #expect(abs(clip[3] - (792 - 36 - 12) / 2) < 0.01)
  }

  @Test func bookletOrderAndPaddingAreExplicit() throws {
    let boxes = pageBoxes(Array(repeating: [612, 792], count: 8))
    let options = PDFAdvancedPrintOptions(layout: .booklet, scale: .fit)
    let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: boxes, options: options)
    #expect(plan.outputPageCount == 4)
    #expect(plan.sheets.count == 2)
    #expect(plan.sides[0].placements.map(\.sourcePageIndex) == [7, 0])
    #expect(plan.sides[1].placements.map(\.sourcePageIndex) == [1, 6])
    #expect(plan.sides[2].placements.map(\.sourcePageIndex) == [5, 2])
    #expect(plan.sides[3].placements.map(\.sourcePageIndex) == [3, 4])

    let five = pageBoxes(Array(repeating: [612, 792], count: 5))
    let padded = try PDFAdvancedPrintPlanner.plan(pageBoxes: five, options: options)
    #expect(padded.outputPageCount == 4)
    #expect(padded.sides[0].placements.map(\.sourcePageIndex) == [0])
    #expect(padded.sides[1].placements.map(\.sourcePageIndex) == [1])
    #expect(padded.sides[2].placements.map(\.sourcePageIndex) == [2])
    #expect(padded.sides[3].placements.map(\.sourcePageIndex) == [3, 4])
    #expect(padded.warnings.contains { $0.contains("pads") })
  }

  @Test func posterTilesCoverPageWithDeclaredOverlap() throws {
    let boxes = pageBoxes([[612, 792]])
    let overlap = 20.0
    let options = PDFAdvancedPrintOptions(
      layout: .poster(rows: 2, columns: 2, overlap: overlap), scale: .actual, margin: 10)
    let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: boxes, options: options)
    #expect(plan.outputPageCount == 4)
    #expect(plan.sides.map(\.placements.first?.label) == [
      "tile 1,1", "tile 1,2", "tile 2,1", "tile 2,2",
    ])
    let topLeft = plan.sides[0].placements[0]
    let topRight = plan.sides[1].placements[0]
    let bottomLeft = plan.sides[2].placements[0]
    // Source tile width is (612 + 20) / 2 = 316, step 296.
    #expect(abs(topLeft.clipRect![2] - 316) < 0.01)
    #expect(abs(topRight.clipRect![2] - 316) < 0.01)
    #expect(abs(topLeft.clipRect![3] - 406) < 0.01)
    // Tile 2 starts 296pt into the page: its target rect is shifted left.
    #expect(abs((topRight.targetRect[0] - topLeft.targetRect[0]) + 296) < 0.01)
    #expect(topLeft.targetRect[1] == topRight.targetRect[1])
    #expect(bottomLeft.targetRect[1] > topLeft.targetRect[1])
    #expect(abs((bottomLeft.targetRect[1] - topLeft.targetRect[1]) - 386) < 0.01)
    #expect(plan.warnings.contains { $0.contains("overlap") })
  }

  @Test func actualScaleOverflowIsReportedAsClipped() throws {
    let boxes = pageBoxes([[612, 792]])
    let options = PDFAdvancedPrintOptions(
      layout: .nUp(rows: 2, columns: 2), scale: .actual, paperSize: [400, 400],
      margin: 10, gutter: 0)
    let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: boxes, options: options)
    #expect(plan.warnings.contains { $0.contains("clipped") })
    let placement = try #require(plan.sides.first?.placements.first)
    #expect(placement.targetRect[2] > 100)
  }

  @Test func invalidLayoutsRefuse() throws {
    let boxes = pageBoxes([[612, 792]])
    #expect(throws: PDFError.self) {
      _ = try PDFAdvancedPrintPlanner.plan(
        pageBoxes: [], options: PDFAdvancedPrintOptions())
    }
    #expect(throws: PDFError.self) {
      _ = try PDFAdvancedPrintPlanner.plan(
        pageBoxes: boxes, options: PDFAdvancedPrintOptions(layout: .nUp(rows: 0, columns: 2)))
    }
    #expect(throws: PDFError.self) {
      _ = try PDFAdvancedPrintPlanner.plan(
        pageBoxes: boxes, options: PDFAdvancedPrintOptions(scale: .custom(0)))
    }
    #expect(throws: PDFError.self) {
      _ = try PDFAdvancedPrintPlanner.plan(
        pageBoxes: boxes, options: PDFAdvancedPrintOptions(paperSize: [10, 10], margin: 18))
    }
  }

  @Test func nativePrintAuditDeclaresCustomCoverage() {
    let audit = PDFNativePrintAudit.audit()
    #expect(audit.contains { $0.feature == "Page range" && $0.nativeSupport })
    #expect(audit.contains { $0.feature == "Booklet imposition" && !$0.nativeSupport })
    #expect(audit.contains { $0.feature == "N-up" && !$0.nativeSupport })
    #expect(audit.contains { $0.feature == "Comments/annotations printing" && !$0.nativeSupport })
    #expect(PDFNativePrintAudit.report().contains("no PDF/X"))
  }
}
