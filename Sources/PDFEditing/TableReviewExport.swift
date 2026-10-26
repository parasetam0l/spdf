import Foundation
import PDFCore

/// EXP-02: a reviewed ambiguity that must stay visible in the export report.
/// Ambiguous cells are never silently dropped or converted into invented
/// values; they are exported as their literal (possibly empty) content and
/// listed here.
public struct TableReviewAmbiguity: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    /// The reviewed cell has no text (for example a slot created by a split).
    case emptyText
    /// The extracted cell kept a low-confidence note.
    case lowConfidence
    /// The continuation's repeated header rows did not match the first page,
    /// so all continuation rows were kept unchanged.
    case continuationHeaderMismatch
  }

  public let row: Int
  public let column: Int
  public let kind: Kind
  public let note: String

  public init(row: Int, column: Int, kind: Kind, note: String) {
    self.row = row
    self.column = column
    self.kind = kind
    self.note = note
  }
}

/// EXP-02: one reviewed boundary change, recorded so the review can explain
/// what was edited before export.
public struct TableReviewBoundaryChange: Sendable, Equatable, Codable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case insertRow
    case insertColumn
    case splitCell
    case setCellBounds
    case mergeContinuation
  }

  public let kind: Kind
  public let row: Int
  public let column: Int
  public let note: String

  public init(kind: Kind, row: Int, column: Int, note: String) {
    self.kind = kind
    self.row = row
    self.column = column
    self.note = note
  }
}

/// EXP-02: reviewed tables stay concrete data. Export preserves the reviewed
/// rows, spans and literal values and never invents formulas.
public struct ReviewedTable: Sendable, Equatable {
  public let table: ExtractedTable
  /// Reviewed header rows at the top of the table (0 when none was marked).
  public let headerRowCount: Int
  /// Pages whose rows were folded into this table as a continuation, in order.
  public let continuationPageIndexes: [Int]
  public let valuePolicy: TableValuePolicy
  public let boundaryChanges: [TableReviewBoundaryChange]
  public let ambiguities: [TableReviewAmbiguity]
  public let limitations: [String]

  public init(
    table: ExtractedTable, headerRowCount: Int, continuationPageIndexes: [Int],
    valuePolicy: TableValuePolicy, boundaryChanges: [TableReviewBoundaryChange],
    ambiguities: [TableReviewAmbiguity], limitations: [String]
  ) {
    self.table = table
    self.headerRowCount = max(0, min(headerRowCount, table.rowCount))
    self.continuationPageIndexes = continuationPageIndexes
    self.valuePolicy = valuePolicy
    self.boundaryChanges = boundaryChanges
    self.ambiguities = ambiguities
    self.limitations = limitations
  }

  public var rowCount: Int { table.rowCount }
  public var columnCount: Int { table.columnCount }

  /// EXP-02: CSV output that preserves every reviewed row and every slot; a
  /// span's covered slots stay empty fields (they are not removed) and the
  /// literal values are never turned into executable formulas.
  public func csv(options: CSVExportOptions = .init()) -> String {
    TableCSVExport.text(for: table, options: options)
  }

  /// EXP-02: CSV output with the reviewed locale policy applied to typed mode.
  public func csv(options: CSVExportOptions, useReviewedPolicy: Bool) -> String {
    guard useReviewedPolicy else { return csv(options: options) }
    var copy = options
    copy.valuePolicy = valuePolicy
    return TableCSVExport.text(for: table, options: copy)
  }

  public func csvData(options: CSVExportOptions = .init()) -> Data {
    TableCSVExport.data(for: table, options: options)
  }

  /// EXP-02: one XLSX sheet for this reviewed table. Merged spans become
  /// mergeCell regions; typed values use the reviewed locale policy when the
  /// caller keeps the typed mode.
  public func xlsxData(options: XLSXExportOptions = .init()) throws -> Data {
    var copy = options
    if copy.typedValues { copy.valuePolicy = valuePolicy }
    return try XLSXExport.package(tables: [table], options: copy)
  }
}

/// EXP-02: the export-side review report. Every export can carry this so the
/// saved worksheet/CSV is paired with what was reviewed, what stayed
/// ambiguous, and which continuation pages were folded in.
public struct TableExportReviewReport: Sendable, Equatable, Codable {
  public struct Entry: Sendable, Equatable, Codable {
    public let pageIndex: Int
    public let pageNumbers: [Int]
    public let headerRowCount: Int
    public let continuationPageIndexes: [Int]
    public let rowCount: Int
    public let columnCount: Int
    public let ambiguousCells: [TableReviewAmbiguity]
    public let limitations: [String]
  }

  public static let truthfulnessStatement =
    "Table export preserves the reviewed rows, spans and literal cell text. "
    + "Formula-looking text stays literal text, no formulas are invented, and "
    + "ambiguous or empty cells are kept in the output and listed here."

  public let entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  public func markdown() -> String {
    var lines = [
      "# Table export review", "", TableExportReviewReport.truthfulnessStatement, "",
      "| Table | Page | Pages folded | Header rows | Rows | Columns | Ambiguous cells |",
      "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for (index, entry) in entries.enumerated() {
      let folded = entry.continuationPageIndexes.isEmpty
        ? "none"
        : entry.continuationPageIndexes.map { String($0 + 1) }.joined(separator: ", ")
      let ambiguous = entry.ambiguousCells.isEmpty
        ? "none"
        : entry.ambiguousCells.map { "R\($0.row)C\($0.column) \($0.kind.rawValue)" }
          .joined(separator: "; ")
      lines.append(
        "| \(index + 1) | \(entry.pageIndex + 1) | \(folded) | \(entry.headerRowCount) | "
        + "\(entry.rowCount) | \(entry.columnCount) | \(ambiguous) |")
    }
    let ambiguousCount = entries.reduce(0) { $0 + $1.ambiguousCells.count }
    lines.append("")
    lines.append("Ambiguous cells kept in the export: \(ambiguousCount).")
    let limitations = entries.flatMap(\.limitations)
    if !limitations.isEmpty {
      lines.append("")
      lines.append("Limitations:")
      for limitation in limitations { lines.append("- \(limitation)") }
    }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}

public enum ReviewedTableExport {
  /// EXP-02: one sheet per reviewed table. The caller can pass the reviewed
  /// tables directly; rows, spans and values are preserved by XLSXExport.
  public static func xlsx(
    tables: [ReviewedTable], options: XLSXExportOptions = .init(),
    zipLimits: ZIPArchiveWriter.Limits = .init()
  ) throws -> Data {
    guard !tables.isEmpty else {
      return try XLSXExport.package(tables: [], options: options, zipLimits: zipLimits)
    }
    // A single XLSX option carries one locale policy; the first reviewed
    // table's policy is used for the workbook and every table is exported with
    // its own literal text. Mixed policies are refused instead of silently
    // re-typing values under another locale.
    if tables.contains(where: { $0.valuePolicy != tables[0].valuePolicy }) {
      throw PDFError(
        .unsupported,
        "Reviewed tables use different locale policies; export them as separate workbooks "
          + "so typed values are not re-interpreted under another locale")
    }
    var copy = options
    if copy.typedValues { copy.valuePolicy = tables[0].valuePolicy }
    return try XLSXExport.package(
      tables: tables.map(\.table), options: copy, zipLimits: zipLimits)
  }

  public static func reviewReport(for tables: [ReviewedTable]) -> TableExportReviewReport {
    TableExportReviewReport(
      entries: tables.map { table in
        TableExportReviewReport.Entry(
          pageIndex: table.table.pageIndex,
          pageNumbers: [table.table.pageIndex] + table.continuationPageIndexes,
          headerRowCount: table.headerRowCount,
          continuationPageIndexes: table.continuationPageIndexes,
          rowCount: table.rowCount,
          columnCount: table.columnCount,
          ambiguousCells: table.ambiguities,
          limitations: table.limitations)
      })
  }
}

/// EXP-02: an editable review session over one extracted table. Boundary
/// edits, headers, locale policy and cross-page continuations are applied to
/// the data only; the PDF is never touched. Nothing is invented: inserted rows
/// and split slots are explicit empty cells (or the caller's reviewed text),
/// and a continuation is only folded in when its column count matches.
public struct TableReviewSession: Sendable, Equatable {
  public private(set) var table: ExtractedTable
  public private(set) var valuePolicy: TableValuePolicy
  public private(set) var headerRowCount: Int
  public private(set) var continuationPageIndexes: [Int]
  public private(set) var boundaryChanges: [TableReviewBoundaryChange]
  public private(set) var ambiguities: [TableReviewAmbiguity]
  public private(set) var limitations: [String]

  public init(table: ExtractedTable, valuePolicy: TableValuePolicy = .init()) {
    self.table = table
    self.valuePolicy = valuePolicy
    self.headerRowCount = 0
    self.continuationPageIndexes = []
    self.boundaryChanges = []
    self.ambiguities = []
    self.limitations = table.limitations
  }

  /// Mark the first rows as reviewed column headers. They are preserved by
  /// export and are the rows a continuation must repeat.
  public mutating func setHeaderRowCount(_ count: Int) throws {
    guard count >= 0, count <= table.rowCount else {
      throw PDFError(.malformed, "The header row count is outside the table")
    }
    headerRowCount = count
  }

  /// Insert a reviewed row boundary after the given row. Existing cells shift
  /// down; a span that crosses the new boundary grows instead of splitting
  /// silently. Only the caller-provided texts are written.
  public mutating func insertRow(after row: Int, texts: [String] = []) throws {
    guard row >= -1, row < table.rowCount else {
      throw PDFError(.malformed, "There is no row boundary after row \(row)")
    }
    let index = row + 1
    var cells: [ExtractedTable.Cell] = []
    for cell in table.cells {
      if cell.row >= index {
        cells.append(copied(cell, row: cell.row + 1))
        continue
      }
      if cell.row + cell.rowSpan > index {
        cells.append(
          ExtractedTable.Cell(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan + 1,
            columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence))
      } else {
        cells.append(cell)
      }
    }
    for column in 0..<table.columnCount {
      let text = column < texts.count ? texts[column] : ""
      cells.append(
        ExtractedTable.Cell(
          row: index, column: column, text: text, bounds: [0, 0, 0, 0],
          provenance: .text, confidence: text.isEmpty ? 0 : 1))
      if text.isEmpty {
        ambiguities.append(
          TableReviewAmbiguity(
            row: index, column: column, kind: .emptyText,
            note: "The inserted row slot has no reviewed text."))
      }
    }
    table = replaced(cells: cells, rowCount: table.rowCount + 1)
    boundaryChanges.append(
      TableReviewBoundaryChange(
        kind: .insertRow, row: index, column: 0,
        note: "Inserted a row boundary after row \(row)."))
  }

  /// Insert a reviewed column boundary after the given column, with the same
  /// shift/grow semantics as a row boundary.
  public mutating func insertColumn(after column: Int, texts: [String] = []) throws {
    guard column >= -1, column < table.columnCount else {
      throw PDFError(.malformed, "There is no column boundary after column \(column)")
    }
    let index = column + 1
    var cells: [ExtractedTable.Cell] = []
    for cell in table.cells {
      if cell.column >= index {
        cells.append(copied(cell, column: cell.column + 1))
        continue
      }
      if cell.column + cell.columnSpan > index {
        cells.append(
          ExtractedTable.Cell(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
            columnSpan: cell.columnSpan + 1, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence))
      } else {
        cells.append(cell)
      }
    }
    for row in 0..<table.rowCount {
      let text = row < texts.count ? texts[row] : ""
      cells.append(
        ExtractedTable.Cell(
          row: row, column: index, text: text, bounds: [0, 0, 0, 0],
          provenance: .text, confidence: text.isEmpty ? 0 : 1))
      if text.isEmpty {
        ambiguities.append(
          TableReviewAmbiguity(
            row: row, column: index, kind: .emptyText,
            note: "The inserted column slot has no reviewed text."))
      }
    }
    table = replaced(cells: cells, columnCount: table.columnCount + 1)
    boundaryChanges.append(
      TableReviewBoundaryChange(
        kind: .insertColumn, row: 0, column: index,
        note: "Inserted a column boundary after column \(column)."))
  }

  /// Split a spanning cell into an explicit reviewed sub-grid. Only the
  /// original text stays in the top-left slot; every other slot becomes an
  /// explicit empty cell (listed as ambiguous), not invented content.
  public mutating func splitCell(
    row: Int, column: Int, rows: Int = 1, columns: Int = 1
  ) throws {
    guard let index = table.cells.firstIndex(where: {
      $0.row == row && $0.column == column
    }) else {
      throw PDFError(.malformed, "There is no cell at row \(row), column \(column)")
    }
    let cell = table.cells[index]
    let rowSlots = max(1, min(rows, cell.rowSpan))
    let columnSlots = max(1, min(columns, cell.columnSpan))
    guard rowSlots > 1 || columnSlots > 1 || cell.rowSpan > 1 || cell.columnSpan > 1
    else {
      throw PDFError(.malformed, "The cell has no span to split")
    }
    var cells = table.cells
    cells[index] = ExtractedTable.Cell(
      row: cell.row, column: cell.column, text: cell.text, bounds: cell.bounds,
      provenance: cell.provenance, confidence: cell.confidence)
    let rowHeight = (cell.bounds.count == 4 ? cell.bounds[3] - cell.bounds[1] : 0)
      / Double(rowSlots)
    let columnWidth = (cell.bounds.count == 4 ? cell.bounds[2] - cell.bounds[0] : 0)
      / Double(columnSlots)
    for slotRow in 0..<rowSlots {
      for slotColumn in 0..<columnSlots {
        if slotRow == 0 && slotColumn == 0 { continue }
        let bounds: [Double] = cell.bounds.count == 4
          ? [
            cell.bounds[0] + Double(slotColumn) * columnWidth,
            cell.bounds[1] + Double(slotRow) * rowHeight,
            cell.bounds[0] + Double(slotColumn + 1) * columnWidth,
            cell.bounds[1] + Double(slotRow + 1) * rowHeight,
          ]
          : [0, 0, 0, 0]
        cells.append(
          ExtractedTable.Cell(
            row: cell.row + slotRow, column: cell.column + slotColumn, text: "",
            bounds: bounds, provenance: cell.provenance, confidence: 0))
        ambiguities.append(
          TableReviewAmbiguity(
            row: cell.row + slotRow, column: cell.column + slotColumn,
            kind: .emptyText,
            note: "Split slot has no reviewed text; the original cell text stays in "
              + "the top-left slot."))
      }
    }
    table = replaced(cells: cells)
    boundaryChanges.append(
      TableReviewBoundaryChange(
        kind: .splitCell, row: row, column: column,
        note: "Split the cell into \(rowSlots) row(s) by \(columnSlots) column(s)."))
  }

  /// Record a reviewed page-space boundary for a cell. Bounds drive worksheet
  /// row height and column width; they never invent cell content.
  public mutating func setCellBounds(row: Int, column: Int, bounds: [Double]) throws {
    guard let index = table.cells.firstIndex(where: {
      $0.row == row && $0.column == column
    }) else {
      throw PDFError(.malformed, "There is no cell at row \(row), column \(column)")
    }
    guard bounds.count == 4, bounds.allSatisfy(\.isFinite),
      bounds[2] >= bounds[0], bounds[3] >= bounds[1]
    else {
      throw PDFError(.malformed, "The reviewed cell bounds are not a valid rectangle")
    }
    let cell = table.cells[index]
    var cells = table.cells
    cells[index] = ExtractedTable.Cell(
      row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
      columnSpan: cell.columnSpan, text: cell.text, bounds: bounds,
      provenance: cell.provenance, confidence: cell.confidence)
    table = replaced(cells: cells)
    boundaryChanges.append(
      TableReviewBoundaryChange(
        kind: .setCellBounds, row: row, column: column,
        note: "Set the reviewed cell boundary."))
  }

  /// Fold a continuation table (the same table on a later page) into this
  /// one. The continuation must have the same column count. When the reviewed
  /// header rows repeat at the top of the continuation they are dropped and
  /// recorded; otherwise every continuation row is kept and the mismatch is
  /// listed as an ambiguity instead of guessing.
  public mutating func mergeContinuation(_ continuation: ExtractedTable) throws {
    guard continuation.columnCount == table.columnCount else {
      throw PDFError(
        .unsupported,
        "The continuation has \(continuation.columnCount) columns but the reviewed table has "
          + "\(table.columnCount); it is not folded in and no column is invented or dropped")
    }
    let repeatedHeaderRows: Int
    if headerRowCount > 0, continuation.rowCount >= headerRowCount,
      continuationRowsMatchHeader(continuation, headerRows: headerRowCount)
    {
      repeatedHeaderRows = headerRowCount
    } else {
      repeatedHeaderRows = 0
      if headerRowCount > 0 {
        ambiguities.append(
          TableReviewAmbiguity(
            row: table.rowCount, column: 0, kind: .continuationHeaderMismatch,
            note: "The continuation does not repeat the reviewed header rows; all of its "
              + "rows are kept unchanged."))
      }
    }
    let offset = table.rowCount
    var cells = table.cells
    for cell in continuation.cells {
      guard cell.row >= repeatedHeaderRows else { continue }
      let newRow = cell.row - repeatedHeaderRows + offset
      cells.append(
        ExtractedTable.Cell(
          row: newRow, column: cell.column, rowSpan: cell.rowSpan,
          columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
          provenance: cell.provenance, confidence: cell.confidence))
    }
    let addedRows = continuation.rowCount - repeatedHeaderRows
    let limitation =
      "Rows folded from page \(continuation.pageIndex + 1)"
      + (repeatedHeaderRows > 0
        ? "; its repeated \(repeatedHeaderRows) header row(s) were dropped."
        : ".")
    table = ExtractedTable(
      pageIndex: table.pageIndex, detection: table.detection, bounds: table.bounds,
      rowCount: table.rowCount + addedRows, columnCount: table.columnCount, cells: cells,
      confidence: min(table.confidence, continuation.confidence),
      limitations: table.limitations + [limitation])
    limitations = table.limitations
    continuationPageIndexes.append(continuation.pageIndex)
    boundaryChanges.append(
      TableReviewBoundaryChange(
        kind: .mergeContinuation, row: offset, column: 0,
        note: "Folded the continuation from page \(continuation.pageIndex + 1)"
          + (repeatedHeaderRows > 0 ? " after dropping repeated header rows." : ".")))
  }

  public mutating func markAmbiguous(
    row: Int, column: Int, kind: TableReviewAmbiguity.Kind, note: String
  ) {
    ambiguities.append(TableReviewAmbiguity(row: row, column: column, kind: kind, note: note))
  }

  /// EXP-02: the reviewed table ready for CSV/XLSX export.
  public func reviewed() -> ReviewedTable {
    ReviewedTable(
      table: table, headerRowCount: headerRowCount,
      continuationPageIndexes: continuationPageIndexes, valuePolicy: valuePolicy,
      boundaryChanges: boundaryChanges, ambiguities: ambiguities,
      limitations: table.limitations)
  }

  private func copied(
    _ cell: ExtractedTable.Cell, row: Int? = nil, column: Int? = nil
  ) -> ExtractedTable.Cell {
    ExtractedTable.Cell(
      row: row ?? cell.row, column: column ?? cell.column, rowSpan: cell.rowSpan,
      columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
      provenance: cell.provenance, confidence: cell.confidence)
  }

  private func continuationRowsMatchHeader(
    _ continuation: ExtractedTable, headerRows: Int
  ) -> Bool {
    for row in 0..<headerRows {
      for column in 0..<table.columnCount {
        let header = table.cell(row: row, column: column)?.text
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let repeated = continuation.cell(row: row, column: column)?.text
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if header != repeated { return false }
      }
    }
    return true
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
