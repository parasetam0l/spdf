import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P36-011/P36-014/P36-015/P36-016: CSV quoting, delimiters, newlines,
/// encodings, literal-text handling for formula-looking values, and selected
/// or multi-table exports.
@Suite("Table CSV export")
struct TableCSVExportTests {
  private func table(
    rows: [[String?]], pageIndex: Int = 0, spans: [(Int, Int, Int, Int)] = []
  ) -> ExtractedTable {
    var cells: [ExtractedTable.Cell] = []
    for (row, values) in rows.enumerated() {
      for (column, value) in values.enumerated() {
        guard let value else { continue }
        let span = spans.first { $0.0 == row && $0.1 == column }
        cells.append(
          ExtractedTable.Cell(
            row: row, column: column, rowSpan: span?.2 ?? 1, columnSpan: span?.3 ?? 1,
            text: value, bounds: [0, 0, 10, 10], provenance: .text, confidence: 0.9))
      }
    }
    return ExtractedTable(
      pageIndex: pageIndex, detection: .geometry, bounds: [0, 0, 100, 100],
      rowCount: rows.count, columnCount: rows.first?.count ?? 0, cells: cells,
      confidence: 0.8, limitations: [])
  }

  @Test func quotingDelimitersAndLineEndings() {
    let grid = self.table(rows: [["plain", "with,comma"], ["with\"quote", "with\nnewline"]])
    let csv = TableCSVExport.text(for: grid)
    #expect(csv == "plain,\"with,comma\"\n\"with\"\"quote\",\"with\nnewline\"\n")

    // Semicolon delimiter and CRLF endings: a comma no longer needs quoting.
    let semicolon = TableCSVExport.text(
      for: grid, options: CSVExportOptions(delimiter: ";", lineEnding: "\r\n"))
    #expect(semicolon.contains("plain;with,comma\r\n"))
    #expect(!semicolon.contains("plain,\"with"))
    // A value containing the chosen delimiter is quoted.
    let semicolonTable = self.table(rows: [["a;b"]])
    let semicolonQuoted = TableCSVExport.text(
      for: semicolonTable, options: CSVExportOptions(delimiter: ";"))
    #expect(semicolonQuoted == "\"a;b\"\n")

    // quoteAll quotes every field.
    let quoted = TableCSVExport.text(
      for: grid, options: CSVExportOptions(quoteAll: true))
    #expect(quoted.hasPrefix("\"plain\",\"with,comma\"\r\n".replacingOccurrences(of: "\r\n", with: "\n")))
  }

  @Test func encodingsCarryTheDeclaredBOM() {
    let table = table(rows: [["Grüße"]])
    let utf8 = TableCSVExport.data(for: table)
    #expect(!utf8.starts(with: [0xEF, 0xBB, 0xBF]))
    #expect(String(decoding: utf8, as: UTF8.self).contains("Grüße"))
    let bom = TableCSVExport.data(
      for: table, options: CSVExportOptions(encoding: .utf8BOM))
    #expect(bom.starts(with: [0xEF, 0xBB, 0xBF]))
    let utf16 = TableCSVExport.data(
      for: table, options: CSVExportOptions(encoding: .utf16))
    #expect(utf16.starts(with: [0xFF, 0xFE]))
    #expect(String(data: utf16.dropFirst(2), encoding: .utf16LittleEndian)?.contains("Grüße") == true)
  }

  @Test func formulaLookingValuesStayLiteral() {
    let table = table(rows: [["=SUM(A1:A2)"], ["+cmd"], ["-5"], ["@import"], ["007"]])
    let safe = TableCSVExport.text(for: table)
    #expect(safe.contains("'=SUM(A1:A2)"))
    #expect(safe.contains("'+cmd"))
    #expect(safe.contains("'@import"))
    // Plain numbers are not formulas and are untouched.
    #expect(safe.contains("-5\n"))
    // Leading zeros are preserved by default (P36-011).
    #expect(safe.contains("007"))
    #expect(!safe.contains("'007"))

    let none = TableCSVExport.text(
      for: table, options: CSVExportOptions(formulaPolicy: .none))
    #expect(none.contains("=SUM(A1:A2)"))
    #expect(!none.contains("'=SUM"))
    let quoteOnly = TableCSVExport.text(
      for: table, options: CSVExportOptions(formulaPolicy: .quoteOnly))
    #expect(quoteOnly.contains("=SUM(A1:A2)"))
  }

  @Test func selectedAndMultiTableExports() throws {
    let first = table(rows: [["A1", "B1"]], pageIndex: 0)
    let second = table(rows: [["A2", "B2"]], pageIndex: 1)
    let all = TableCSVExport.data(for: [first, second])
    let allText = String(decoding: all, as: UTF8.self)
    #expect(allText == "A1,B1\n\nA2,B2\n")

    let selected = TableCSVExport.data(for: [first, second], tableIndex: 1)
    #expect(String(decoding: selected, as: UTF8.self) == "A2,B2\n")
    // An out-of-range selection writes nothing rather than guessing.
    let missing = TableCSVExport.data(for: [first, second], tableIndex: 9)
    #expect(missing.isEmpty)

    // One file per table with deterministic names.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-csv-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = try TableCSVExport.write(
      tables: [first, second], to: directory, baseName: "doc")
    #expect(urls.count == 2)
    #expect(urls[0].lastPathComponent == "doc-page-0001-table-0001.csv")
    #expect(urls[1].lastPathComponent == "doc-page-0002-table-0001.csv")
    #expect(FileManager.default.fileExists(atPath: urls[1].path))
  }

  @Test func csvRoundTripsThroughAnIndependentParser() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let grid = table(rows: [
      ["plain", "with,comma"],
      ["with\"quote", "007"],
      ["=SUM(A1)"],
      ["line\nbreak", "Grüße"],
    ])
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-csv-roundtrip-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: url) }
    try TableCSVExport.data(for: grid).write(to: url)

    let script = """
      import csv, sys
      with open(sys.argv[1], newline='', encoding='utf-8') as handle:
          rows = list(csv.reader(handle))
      print(len(rows))
      print(rows[0][1])
      print(rows[1][0])
      print(rows[1][1])
      print(rows[2][0])
      print(rows[3][0].replace('\\n', '|'))
      """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "python3: \(output)")
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.first == "4")
    #expect(lines.count > 5)
    #expect(lines[1] == "with,comma")
    #expect(lines[2] == "with\"quote")
    #expect(lines[3] == "007")
    #expect(lines[4] == "'=SUM(A1)")
    #expect(lines[5] == "line|break")
  }

  @Test func spannedSlotsRenderAsEmptyFields() {
    // A 2×2 grid whose top cell spans both columns.
    let table = table(rows: [["Merged", nil], ["Left", "Right"]], spans: [(0, 0, 1, 2)])
    let csv = TableCSVExport.text(for: table)
    #expect(csv == "Merged,\nLeft,Right\n")
  }
}
