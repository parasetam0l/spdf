import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P36-010: manual cell, row, column, merge/split corrections and
/// accept/reject review over an extracted table.
@Suite("Table review")
struct TableReviewTests {
  private func table(spans: [(Int, Int, Int, Int)] = []) -> ExtractedTable {
    var cells: [ExtractedTable.Cell] = []
    for row in 0..<3 {
      for column in 0..<2 {
        let span = spans.first { $0.0 == row && $0.1 == column }
        cells.append(
          ExtractedTable.Cell(
            row: row, column: column, rowSpan: span?.2 ?? 1, columnSpan: span?.3 ?? 1,
            text: "R\(row)C\(column)", bounds: [0, 0, 10, 10], provenance: .text,
            confidence: 0.7))
      }
    }
    return ExtractedTable(
      pageIndex: 0, detection: .geometry, bounds: [0, 0, 20, 30], rowCount: 3, columnCount: 2,
      cells: cells, confidence: 0.5,
      limitations: ["Low-confidence detection; review before export."])
  }

  @Test func cellTextCorrectionsAreRecorded() throws {
    var review = TableReview(table: table())
    try review.setCellText(row: 1, column: 0, text: "Corrected")
    #expect(review.table.cell(row: 1, column: 0)?.text == "Corrected")
    #expect(review.corrections == [.setCellText])
    // Bounds, provenance, and confidence stay with the cell.
    #expect(review.table.cell(row: 1, column: 0)?.provenance == .text)
    #expect(review.table.cell(row: 1, column: 0)?.confidence == 0.7)
    // An invalid cell is refused.
    #expect(throws: PDFError.self) {
      try review.setCellText(row: 9, column: 0, text: "nope")
    }
  }

  @Test func rowAndColumnDeletionsShiftAndShrinkSpans() throws {
    var review = TableReview(table: table(spans: [(0, 0, 3, 1)]))
    #expect(review.table.cell(row: 0, column: 0)?.rowSpan == 3)
    try review.deleteRow(2)
    #expect(review.table.rowCount == 2)
    // The spanning cell shrank because the deleted row was covered.
    #expect(review.table.cell(row: 0, column: 0)?.rowSpan == 2)
    #expect(review.table.cell(row: 1, column: 1)?.text == "R1C1")
    try review.deleteColumn(0)
    #expect(review.table.columnCount == 1)
    #expect(review.table.cell(row: 0, column: 0)?.text == "R0C1")
    #expect(review.corrections == [.deleteRow, .deleteColumn])
    #expect(throws: PDFError.self) { try review.deleteRow(5) }
    #expect(throws: PDFError.self) { try review.deleteColumn(5) }
  }

  @Test func mergesRefuseToCoverOtherCellsAndSplitsClearSpans() throws {
    var review = TableReview(table: table())
    // Merging across R0C1 is refused because that cell exists.
    #expect(throws: PDFError.self) {
      try review.merge(row: 0, column: 0, rowSpan: 1, columnSpan: 2)
    }
    // Merging down over R1C0 is refused too.
    #expect(throws: PDFError.self) {
      try review.merge(row: 0, column: 0, rowSpan: 2, columnSpan: 1)
    }
    // Merging an empty neighbourhood succeeds.
    var empty = TableReview(
      table: ExtractedTable(
        pageIndex: 0, detection: .ruled, bounds: [0, 0, 20, 30], rowCount: 2, columnCount: 2,
        cells: [
          ExtractedTable.Cell(
            row: 0, column: 0, text: "Header", bounds: [0, 0, 20, 10], provenance: .text,
            confidence: 0.9)
        ], confidence: 0.8, limitations: []))
    try empty.merge(row: 0, column: 0, rowSpan: 1, columnSpan: 2)
    #expect(empty.table.cell(row: 0, column: 0)?.columnSpan == 2)
    try empty.split(row: 0, column: 0)
    #expect(empty.table.cell(row: 0, column: 0)?.columnSpan == 1)
    #expect(empty.corrections == [.merge, .split])
  }

  @Test func acceptAndRejectControlExport() throws {
    let low = table()
    var accepted = TableReview(table: low)
    accepted.accept()
    let reviewed = try #require(accepted.reviewedTable())
    #expect(reviewed.confidence == 1.0)
    #expect(!reviewed.limitations.contains { $0.contains("Low-confidence") })

    var rejected = TableReview(table: low)
    rejected.reject()
    #expect(rejected.reviewedTable() == nil)
    #expect(TableReview.exportable([accepted, rejected]).count == 1)

    // An un-reviewed low-confidence table keeps its note and confidence.
    let untouched = TableReview(table: low)
    #expect(untouched.reviewedTable()?.limitations.count == 1)
    #expect(untouched.reviewedTable()?.confidence == 0.5)
  }
}
