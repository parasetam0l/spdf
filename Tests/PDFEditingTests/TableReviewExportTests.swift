import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// EXP-02: reviewed cell boundaries, split slots, multipage continuation and
/// headers, plus CSV/XLSX preservation of reviewed rows, spans and literal
/// values (no invented formulas, no dropped ambiguous cells).
@Suite("Table review export")
struct TableReviewExportTests {
  private func table(
    rows: [[String?]], pageIndex: Int = 0,
    spans: [(row: Int, column: Int, rowSpan: Int, columnSpan: Int)] = []
  ) -> ExtractedTable {
    var cells: [ExtractedTable.Cell] = []
    for (row, values) in rows.enumerated() {
      for (column, value) in values.enumerated() {
        guard let value else { continue }
        let span = spans.first { $0.row == row && $0.column == column }
        cells.append(
          ExtractedTable.Cell(
            row: row, column: column, rowSpan: span?.rowSpan ?? 1,
            columnSpan: span?.columnSpan ?? 1, text: value,
            bounds: [Double(column) * 10, Double(row) * 20, Double(column + 1) * 10,
              Double(row + 1) * 20],
            provenance: .text, confidence: 0.8))
      }
    }
    return ExtractedTable(
      pageIndex: pageIndex, detection: .geometry,
      bounds: [0, 0, Double(rows.first?.count ?? 1) * 10, Double(rows.count) * 20],
      rowCount: rows.count, columnCount: rows.first?.count ?? 0, cells: cells,
      confidence: 0.6, limitations: [])
  }

  private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-exp02-\(UUID().uuidString)-\(name)")
  }

  private func unzipEntry(_ archive: URL, _ path: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archive.path, path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }

  @Test func insertedBoundariesShiftRowsAndGrowSpans() throws {
    var session = TableReviewSession(table: table(rows: [["A", "B"], ["1", "2"], ["3", "4"]]))
    try session.insertRow(after: 0, texts: ["Reviewed", "Header"])
    #expect(session.table.rowCount == 4)
    #expect(session.table.cell(row: 1, column: 0)?.text == "Reviewed")
    #expect(session.table.cell(row: 1, column: 1)?.text == "Header")
    #expect(session.table.cell(row: 2, column: 0)?.text == "1")
    #expect(session.table.cell(row: 3, column: 1)?.text == "4")
    #expect(session.boundaryChanges == [
      TableReviewBoundaryChange(
        kind: .insertRow, row: 1, column: 0,
        note: "Inserted a row boundary after row 0.")
    ])
    #expect(throws: PDFError.self) { try session.insertRow(after: 99) }

    // Inserting inside a span grows it rather than splitting it.
    var spanning = TableReviewSession(
      table: table(rows: [["Wide", nil], ["c", "d"], ["e", "f"]], spans: [(0, 0, 3, 1)]))
    try spanning.insertRow(after: 0)
    #expect(spanning.table.cell(row: 0, column: 0)?.rowSpan == 4)
    #expect(spanning.ambiguities.count == 2)
    #expect(spanning.ambiguities.allSatisfy { $0.kind == .emptyText })

    // Column boundaries have the same shift/grow behavior.
    var columns = TableReviewSession(
      table: table(rows: [["Wide", nil], ["c", "d"]], spans: [(0, 0, 1, 2)]))
    try columns.insertColumn(after: 0, texts: ["n1", "n2"])
    #expect(columns.table.columnCount == 3)
    #expect(columns.table.cell(row: 0, column: 0)?.columnSpan == 3)
    #expect(columns.table.cell(row: 0, column: 1)?.text == "n1")
    #expect(columns.table.cell(row: 1, column: 2)?.text == "d")
  }

  @Test func splitCellCreatesExplicitEmptySlotsOnly() throws {
    var session = TableReviewSession(
      table: table(rows: [["Merged", nil], [nil, nil]], spans: [(0, 0, 2, 2)]))
    try session.setHeaderRowCount(1)
    try session.splitCell(row: 0, column: 0, rows: 2, columns: 2)
    #expect(session.table.cell(row: 0, column: 0)?.text == "Merged")
    #expect(session.table.cell(row: 0, column: 1)?.text == "")
    #expect(session.table.cell(row: 1, column: 0)?.text == "")
    #expect(session.table.cell(row: 1, column: 1)?.text == "")
    #expect(session.ambiguities.count == 3)
    #expect(session.ambiguities.allSatisfy { $0.kind == .emptyText })
    let reviewed = session.reviewed()
    let csv = reviewed.csv()
    #expect(csv == "Merged,\n,\n")
  }

  @Test func continuationHeadersAreDroppedOrMismatchIsReported() throws {
    var session = TableReviewSession(
      table: table(rows: [["Name", "Value"], ["A", "1"]], pageIndex: 0))
    try session.setHeaderRowCount(1)
    let continuation = table(
      rows: [["Name", "Value"], ["B", "2"], ["C", "3"]], pageIndex: 1)
    try session.mergeContinuation(continuation)
    #expect(session.table.rowCount == 4)
    #expect(session.table.cell(row: 2, column: 0)?.text == "B")
    #expect(session.table.cell(row: 3, column: 1)?.text == "3")
    #expect(session.continuationPageIndexes == [1])
    #expect(session.limitations.contains { $0.contains("repeated 1 header row") })
    let reviewed = session.reviewed()
    #expect(reviewed.continuationPageIndexes == [1])
    #expect(reviewed.csv().split(separator: "\n").count == 4)

    // A different header keeps every row and records the mismatch.
    var mismatch = TableReviewSession(
      table: table(rows: [["Name", "Value"], ["A", "1"]]))
    try mismatch.setHeaderRowCount(1)
    try mismatch.mergeContinuation(
      table(rows: [["Other", "Value"], ["B", "2"]], pageIndex: 2))
    #expect(mismatch.table.rowCount == 4)
    #expect(mismatch.ambiguities.contains { $0.kind == .continuationHeaderMismatch })
    #expect(
      mismatch.table.cell(row: 2, column: 0)?.text == "Other",
      "The mismatching header row is kept, not guessed or dropped")

    // A different column count is refused explicitly.
    var refused = TableReviewSession(table: table(rows: [["A", "B"]]))
    #expect(throws: PDFError.self) {
      try refused.mergeContinuation(table(rows: [["A"], ["B"]], pageIndex: 1))
    }
  }

  @Test func csvKeepsRowsSpansAndAmbiguousCells() {
    let reviewed = TableReviewSession(
      table: table(rows: [["Wide", nil], ["", "=SUM(A1:A2)"], ["3", "4"]],
        spans: [(0, 0, 1, 2)])
    ).reviewed()
    let csv = reviewed.csv()
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 4)  // three rows plus the trailing newline
    #expect(lines[0] == "Wide,")
    #expect(lines[1] == ",'=SUM(A1:A2)")
    // The empty reviewed cell is preserved as an empty field, not dropped.
    #expect(lines[1].hasPrefix(","))
    // No formula-looking value is exported as a live formula.
    #expect(!csv.contains("\n=SUM"))
    // The reviewed locale policy types values in typed mode.
    let german = CSVExportOptions(
      valueMode: .typed, valuePolicy: TableValuePolicy(locale: .german))
    let germanReviewed = TableReviewSession(
      table: table(rows: [["1.234,5", "01"]]),
      valuePolicy: TableValuePolicy(locale: .german)
    ).reviewed()
    #expect(germanReviewed.csv(options: german, useReviewedPolicy: false) == "1234.5,01\n")
    #expect(
      germanReviewed.csv(
        options: CSVExportOptions(valueMode: .typed), useReviewedPolicy: true)
        == "1234.5,01\n")
    // A reviewed POSIX policy keeps a value that is not a POSIX number literal.
    let posixReviewed = TableReviewSession(
      table: table(rows: [["1,5", "01"]])
    ).reviewed()
    #expect(
      posixReviewed.csv(
        options: CSVExportOptions(valueMode: .typed), useReviewedPolicy: true)
        == "\"1,5\",01\n")
  }

  @Test func xlsxPreservesSpansValuesAndEmptyAmbiguousCells() throws {
    var session = TableReviewSession(
      table: table(rows: [["Wide", nil], ["1.234,5", ""], ["=SUM(A1:A2)", "4"]],
        spans: [(0, 0, 1, 2)]),
      valuePolicy: TableValuePolicy(locale: .german))
    session.markAmbiguous(
      row: 1, column: 1, kind: .emptyText,
      note: "The reviewed cell has no text; it is exported empty, not dropped.")
    let reviewed = session.reviewed()
    let archive = try reviewed.xlsxData()
    let url = temporaryFile("reviewed.xlsx")
    defer { try? FileManager.default.removeItem(at: url) }
    try archive.write(to: url)

    let sheet = try unzipEntry(url, "xl/worksheets/sheet1.xml")
    #expect(sheet.contains("<mergeCell ref=\"A1:B1\"/>"))
    #expect(!sheet.contains("<f>"))
    // Every non-span cell is written; the empty reviewed cell is present as an
    // empty shared string and the formula-looking text is a shared string.
    let cellCount = sheet.components(separatedBy: "<c ").count - 1
    #expect(cellCount == 5, "cells: span top-left + 4 remaining slots")
    let shared = try unzipEntry(url, "xl/sharedStrings.xml")
    #expect(shared.contains("=SUM(A1:A2)"))
    #expect(shared.contains("<t xml:space=\"preserve\"></t>"))
    // Typed mode under the reviewed German policy writes the number, not text.
    #expect(sheet.contains("<v>1234.5</v>"))

    let report = ReviewedTableExport.reviewReport(for: [reviewed])
    let markdown = report.markdown()
    #expect(markdown.contains(TableExportReviewReport.truthfulnessStatement))
    #expect(markdown.contains("Ambiguous cells kept in the export: 1"))
    #expect(markdown.contains("R1C1 emptyText"))
    guard let data = try? report.jsonData(),
      let decoded = try? JSONDecoder().decode(TableExportReviewReport.self, from: data)
    else {
      Issue.record("The review report must encode and decode")
      return
    }
    #expect(decoded == report)
    // The unzip entry is a valid OPC part and contains a worksheet element.
    #expect(sheet.contains("<worksheet"))
  }

  @Test func mixedLocaleWorkbooksAreRefused() {
    let german = TableReviewSession(
      table: table(rows: [["1.234,5"]]),
      valuePolicy: TableValuePolicy(locale: .german)
    ).reviewed()
    let posix = TableReviewSession(
      table: table(rows: [["1234.5"]]),
      valuePolicy: TableValuePolicy(locale: .posix)
    ).reviewed()
    #expect(throws: PDFError.self) {
      _ = try ReviewedTableExport.xlsx(tables: [german, posix])
    }
    // A single policy workbook succeeds.
    #expect((try? ReviewedTableExport.xlsx(tables: [german, german])) != nil)
  }
}
