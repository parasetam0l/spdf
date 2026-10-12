import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P36-012/P36-013: explicit locale policies for optional number/date typing,
/// with displayed text always distinct from the inferred value.
@Suite("Table value parsing")
struct TableValueParserTests {
  @Test func numbersFollowTheExplicitLocalePolicy() {
    // POSIX: dot decimal, comma grouping.
    let posix = TableValuePolicy(locale: .posix)
    #expect(TableValueParser.typedValue(for: "1234.56", policy: posix).kind == .number(1234.56))
    #expect(TableValueParser.typedValue(for: "1,234.56", policy: posix).kind == .number(1234.56))
    #expect(TableValueParser.typedValue(for: "-5", policy: posix).kind == .number(-5))
    #expect(TableValueParser.typedValue(for: "+0.5", policy: posix).kind == .number(0.5))

    // German: comma decimal, dot grouping.
    let german = TableValuePolicy(locale: .german)
    #expect(TableValueParser.typedValue(for: "1.234,56", policy: german).kind == .number(1234.56))
    #expect(TableValueParser.typedValue(for: "0,5", policy: german).kind == .number(0.5))
    // The same text under POSIX is not a number (dot grouping without a comma
    // decimal is ambiguous and stays text only when invalid).
    #expect(TableValueParser.typedValue(for: "abc", policy: german).kind == .text)
    #expect(TableValueParser.typedValue(for: "1.2.3", policy: german).kind == .text)

    // French: space grouping, comma decimal.
    let french = TableValuePolicy(locale: .french)
    #expect(TableValueParser.typedValue(for: "1 234,56", policy: french).kind == .number(1234.56))
  }

  @Test func leadingZerosAndDisplayTextArePreserved() {
    let policy = TableValuePolicy(locale: .posix)
    // Leading zeros stay text by default (P36-011).
    let zeroed = TableValueParser.typedValue(for: "007", policy: policy)
    #expect(zeroed.isText)
    #expect(zeroed.displayText == "007")
    // Zero itself is a number, and the display text never changes.
    let zero = TableValueParser.typedValue(for: "0", policy: policy)
    #expect(zero.kind == .number(0))
    #expect(zero.displayText == "0")
    // Opting out types "007" but still keeps the display text.
    let typed = TableValueParser.typedValue(
      for: "007", policy: TableValuePolicy(locale: .posix, treatLeadingZerosAsText: false))
    #expect(typed.kind == .number(7))
    #expect(typed.displayText == "007")
    // Over-long values are never typed.
    let long = String(repeating: "1", count: TableValueParser.maxCharacters + 1)
    #expect(TableValueParser.typedValue(for: long, policy: policy).isText)
  }

  @Test func datesUseTheLocaleFormatsPlusISO() {
    let posix = TableValuePolicy(locale: .posix)
    #expect(TableValueParser.typedValue(for: "2024-12-31", policy: posix).kind == .date("2024-12-31"))
    #expect(TableValueParser.typedValue(for: "12/31/2024", policy: posix).kind == .date("2024-12-31"))
    let german = TableValuePolicy(locale: .german)
    #expect(TableValueParser.typedValue(for: "31.12.2024", policy: german).kind == .date("2024-12-31"))
    let french = TableValuePolicy(locale: .french)
    #expect(TableValueParser.typedValue(for: "31/12/2024", policy: french).kind == .date("2024-12-31"))
    // A POSIX date is not parsed under the German policy (explicit locale).
    #expect(TableValueParser.typedValue(for: "12/31/2024", policy: german).isText)
    // Impossible dates and partial strings stay text.
    #expect(TableValueParser.typedValue(for: "31.02.2024", policy: german).isText)
    #expect(TableValueParser.typedValue(for: "2024-12", policy: posix).isText)
    // Disabling typing leaves everything as text.
    #expect(
      TableValueParser.typedValue(
        for: "12/31/2024", policy: TableValuePolicy(locale: .posix, parseDates: false)
      ).isText)
  }

  @Test func csvTypedModeUsesCanonicalValuesOnly() {
    let grid = ExtractedTable(
      pageIndex: 0, detection: .geometry, bounds: [0, 0, 1, 1], rowCount: 4, columnCount: 1,
      cells: [
        ExtractedTable.Cell(
          row: 0, column: 0, text: "1.234,56", bounds: [0, 0, 1, 1], provenance: .text,
          confidence: 0.9),
        ExtractedTable.Cell(
          row: 1, column: 0, text: "007", bounds: [0, 0, 1, 1], provenance: .text, confidence: 0.9),
        ExtractedTable.Cell(
          row: 2, column: 0, text: "31.12.2024", bounds: [0, 0, 1, 1], provenance: .text,
          confidence: 0.9),
        ExtractedTable.Cell(
          row: 3, column: 0, text: "hello", bounds: [0, 0, 1, 1], provenance: .text,
          confidence: 0.9),
      ], confidence: 0.8, limitations: [])
    // Displayed text by default; the German-formatted number contains the
    // comma delimiter, so it is quoted (correct CSV).
    #expect(TableCSVExport.text(for: grid) == "\"1.234,56\"\n007\n31.12.2024\nhello\n")
    // Typed mode under the German policy canonicalizes numbers and dates.
    let typed = TableCSVExport.text(
      for: grid,
      options: CSVExportOptions(
        valueMode: .typed, valuePolicy: TableValuePolicy(locale: .german)))
    #expect(typed == "1234.56\n007\n2024-12-31\nhello\n")
  }
}
