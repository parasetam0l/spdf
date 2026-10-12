import Foundation
import PDFCore

/// P36-010: manual corrections over an extracted table. Corrections rewrite the
/// extracted data only — the source PDF is never touched — and each change is
/// recorded so a review can see what was adjusted.
public struct TableReview: Sendable, Equatable {
  public enum Correction: String, Sendable, Equatable {
    case setCellText
    case deleteRow
    case deleteColumn
    case merge
    case split
    case accept
    case reject
  }

  public private(set) var table: ExtractedTable
  public private(set) var isAccepted: Bool
  public private(set) var isRejected: Bool
  public private(set) var corrections: [Correction]

  public init(table: ExtractedTable) {
    self.table = table
    self.isAccepted = false
    self.isRejected = false
    self.corrections = []
  }

  /// P36-010: replace a cell's displayed text.
  public mutating func setCellText(row: Int, column: Int, text: String) throws {
    guard let index = table.cells.firstIndex(where: {
      $0.row == row && $0.column == column
    }) else {
      throw PDFError(.malformed, "There is no cell at row \(row), column \(column)")
    }
    let cell = table.cells[index]
    var cells = table.cells
    cells[index] = ExtractedTable.Cell(
      row: cell.row, column: cell.column, rowSpan: cell.rowSpan, columnSpan: cell.columnSpan,
      text: String(text.prefix(XLSXExport.maxStringCharacters)), bounds: cell.bounds,
      provenance: cell.provenance, confidence: cell.confidence)
    table = replaced(cells: cells)
    corrections.append(.setCellText)
  }

  /// P36-010: delete a row and shift the rest up, shrinking any span that
  /// covered it.
  public mutating func deleteRow(_ row: Int) throws {
    guard row >= 0, row < table.rowCount else {
      throw PDFError(.malformed, "There is no row \(row)")
    }
    var cells: [ExtractedTable.Cell] = []
    for cell in table.cells {
      if cell.row == row { continue }
      if cell.row > row {
        cells.append(
          ExtractedTable.Cell(
            row: cell.row - 1, column: cell.column, rowSpan: cell.rowSpan,
            columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence))
      } else if cell.row + cell.rowSpan > row {
        cells.append(
          ExtractedTable.Cell(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan - 1,
            columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence))
      } else {
        cells.append(cell)
      }
    }
    table = replaced(cells: cells, rowCount: table.rowCount - 1)
    corrections.append(.deleteRow)
  }

  /// P36-010: delete a column and shift the rest left, shrinking any span that
  /// covered it.
  public mutating func deleteColumn(_ column: Int) throws {
    guard column >= 0, column < table.columnCount else {
      throw PDFError(.malformed, "There is no column \(column)")
    }
    var cells: [ExtractedTable.Cell] = []
    for cell in table.cells {
      if cell.column == column { continue }
      if cell.column > column {
        cells.append(
          ExtractedTable.Cell(
            row: cell.row, column: cell.column - 1, rowSpan: cell.rowSpan,
            columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence))
      } else if cell.column + cell.columnSpan > column {
        cells.append(
          ExtractedTable.Cell(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
            columnSpan: cell.columnSpan - 1, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence))
      } else {
        cells.append(cell)
      }
    }
    table = replaced(cells: cells, columnCount: table.columnCount - 1)
    corrections.append(.deleteColumn)
  }

  /// P36-010: mark a cell as spanning more slots. Refused when another cell
  /// starts inside the covered area.
  public mutating func merge(
    row: Int, column: Int, rowSpan: Int, columnSpan: Int
  ) throws {
    guard let index = table.cells.firstIndex(where: {
      $0.row == row && $0.column == column
    }) else {
      throw PDFError(.malformed, "There is no cell at row \(row), column \(column)")
    }
    let boundedRowSpan = max(1, min(rowSpan, table.rowCount - row))
    let boundedColumnSpan = max(1, min(columnSpan, table.columnCount - column))
    let covered = (row..<(row + boundedRowSpan)).flatMap { coveredRow in
      (column..<(column + boundedColumnSpan)).map { (coveredRow, $0) }
    }
    for (coveredRow, coveredColumn) in covered {
      if let other = table.cells.firstIndex(where: {
        $0.row == coveredRow && $0.column == coveredColumn
      }), other != index {
        throw PDFError(.malformed, "The merge would cover another cell")
      }
    }
    let cell = table.cells[index]
    var cells = table.cells
    cells[index] = ExtractedTable.Cell(
      row: cell.row, column: cell.column, rowSpan: boundedRowSpan,
      columnSpan: boundedColumnSpan, text: cell.text, bounds: cell.bounds,
      provenance: cell.provenance, confidence: cell.confidence)
    table = replaced(cells: cells)
    corrections.append(.merge)
  }

  /// P36-010: clear a cell's spans. Covered slots become empty; content is
  /// never invented.
  public mutating func split(row: Int, column: Int) throws {
    guard let index = table.cells.firstIndex(where: {
      $0.row == row && $0.column == column
    }) else {
      throw PDFError(.malformed, "There is no cell at row \(row), column \(column)")
    }
    let cell = table.cells[index]
    var cells = table.cells
    cells[index] = ExtractedTable.Cell(
      row: cell.row, column: cell.column, rowSpan: 1, columnSpan: 1, text: cell.text,
      bounds: cell.bounds, provenance: cell.provenance, confidence: cell.confidence)
    table = replaced(cells: cells)
    corrections.append(.split)
  }

  /// P36-010: accept the (possibly corrected) detection.
  public mutating func accept() {
    isAccepted = true
    isRejected = false
    corrections.append(.accept)
  }

  /// P36-010: reject the detection so it is not exported.
  public mutating func reject() {
    isRejected = true
    isAccepted = false
    corrections.append(.reject)
  }

  /// The reviewed table: rejected detections are excluded, accepted ones lose
  /// their low-confidence note and carry full confidence.
  public func reviewedTable() -> ExtractedTable? {
    guard !isRejected else { return nil }
    let limitations = table.limitations.filter { !$0.contains("Low-confidence detection") }
    let confidence = isAccepted ? 1.0 : table.confidence
    return ExtractedTable(
      pageIndex: table.pageIndex, detection: table.detection, bounds: table.bounds,
      rowCount: table.rowCount, columnCount: table.columnCount, cells: table.cells,
      confidence: confidence, limitations: isAccepted ? limitations : table.limitations)
  }

  /// P36-010: the exportable tables of a review set.
  public static func exportable(_ reviews: [TableReview]) -> [ExtractedTable] {
    reviews.compactMap { $0.reviewedTable() }
  }

  private func replaced(
    cells: [ExtractedTable.Cell], rowCount: Int? = nil, columnCount: Int? = nil
  ) -> ExtractedTable {
    ExtractedTable(
      pageIndex: table.pageIndex, detection: table.detection, bounds: table.bounds,
      rowCount: rowCount ?? table.rowCount, columnCount: columnCount ?? table.columnCount,
      cells: cells, confidence: table.confidence, limitations: table.limitations)
  }
}
