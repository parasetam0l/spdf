import Foundation

/// P36-014/P36-015: CSV output controls. Values are written as literal text by
/// default (leading zeros preserved, P36-011) and formula-looking values are
/// neutralized rather than exported as executable expressions.
public struct CSVExportOptions: Sendable, Equatable {
  public enum Encoding: String, Sendable, Equatable {
    case utf8
    case utf8BOM
    case utf16
  }

  /// What happens to a value that starts with `=`, `+`, `-`, or `@` (the
  /// spreadsheet formula triggers). Numeric values such as `-5` are not
  /// affected.
  public enum FormulaPolicy: String, Sendable, Equatable {
    /// Prefix the value with an apostrophe so spreadsheets keep it literal
    /// (the safe default; P36-015).
    case prefixApostrophe
    /// Only ensure quoting; some spreadsheets still interpret it.
    case quoteOnly
    /// Leave the value untouched (explicit opt-out).
    case none
  }

  /// P36-013: what CSV cells contain — the displayed text (default, literal)
  /// or the canonically typed value under the explicit locale policy.
  public enum ValueMode: String, Sendable, Equatable {
    case displayedText
    case typed
  }

  public var delimiter: String
  public var lineEnding: String
  public var encoding: Encoding
  public var quoteAll: Bool
  public var formulaPolicy: FormulaPolicy
  public var valueMode: ValueMode
  public var valuePolicy: TableValuePolicy

  public init(
    delimiter: String = ",", lineEnding: String = "\n", encoding: Encoding = .utf8,
    quoteAll: Bool = false, formulaPolicy: FormulaPolicy = .prefixApostrophe,
    valueMode: ValueMode = .displayedText, valuePolicy: TableValuePolicy = .init()
  ) {
    self.delimiter = delimiter
    self.lineEnding = lineEnding
    self.encoding = encoding
    self.quoteAll = quoteAll
    self.formulaPolicy = formulaPolicy
    self.valueMode = valueMode
    self.valuePolicy = valuePolicy
  }
}

public enum TableCSVExport {
  /// Bounds: one cell's text (1,048,576 characters) and one table's rows.
  public static let maxCellCharacters = 1_048_576
  public static let maxRows = 20_000

  /// P36-016: deterministic multi-table names.
  public static func filename(
    baseName: String, pageNumber: Int, tableNumber: Int
  ) -> String {
    String(format: "%@-page-%04d-table-%04d.csv", baseName, pageNumber, tableNumber)
  }

  /// P36-014/P36-015: one table as CSV text.
  public static func text(
    for table: ExtractedTable, options: CSVExportOptions = .init()
  ) -> String {
    let rows = table.grid().prefix(maxRows)
    var lines: [String] = []
    for row in rows {
      let fields = row.map { value in
        field(value ?? "", options: options)
      }
      lines.append(fields.joined(separator: options.delimiter))
    }
    return lines.joined(separator: options.lineEnding)
      + (lines.isEmpty ? "" : options.lineEnding)
  }

  /// One table as encoded bytes.
  public static func data(
    for table: ExtractedTable, options: CSVExportOptions = .init()
  ) -> Data {
    encode(text(for: table, options: options), options: options)
  }

  /// P36-016: a selected table by index (page-major order), or all tables with
  /// a blank line between them.
  public static func data(
    for tables: [ExtractedTable], tableIndex: Int? = nil, options: CSVExportOptions = .init()
  ) -> Data {
    let selected: [ExtractedTable]
    if let tableIndex, tableIndex >= 0, tableIndex < tables.count {
      selected = [tables[tableIndex]]
    } else if tableIndex == nil {
      selected = tables
    } else {
      selected = []
    }
    let combinedText = selected.map { Self.text(for: $0, options: options) }
      .joined(separator: options.lineEnding)
    return encode(combinedText, options: options)
  }

  /// One CSV file per table, written with deterministic names.
  public static func write(
    tables: [ExtractedTable], to directory: URL, baseName: String,
    options: CSVExportOptions = .init()
  ) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var countsByPage: [Int: Int] = [:]
    var urls: [URL] = []
    for table in tables {
      let number = (countsByPage[table.pageIndex] ?? 0) + 1
      countsByPage[table.pageIndex] = number
      let name = filename(
        baseName: baseName, pageNumber: table.pageIndex + 1, tableNumber: number)
      let url = directory.appendingPathComponent(name)
      try data(for: table, options: options).write(to: url, options: .atomic)
      urls.append(url)
    }
    return urls
  }

  /// P36-015: neutralize formula-looking values and quote when required.
  static func field(_ value: String, options: CSVExportOptions) -> String {
    let bounded = String(
      value.prefix(maxCellCharacters))
    var text =
      options.valueMode == .typed
      ? canonical(bounded, policy: options.valuePolicy) : bounded
    if let first = text.first, ["=", "+", "-", "@", "\t", "\r"].contains(first),
      options.formulaPolicy == .prefixApostrophe,
      Double(text) == nil
    {
      text = "'" + text
    }
    let needsQuotes =
      options.quoteAll || text.contains(options.delimiter)
      || text.contains("\"") || text.contains("\n") || text.contains("\r")
    guard needsQuotes else { return text }
    let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"" + escaped + "\""
  }

  /// The canonical text of an inferred typed value; text stays untouched.
  static func canonical(_ value: String, policy: TableValuePolicy) -> String {
    let typed = TableValueParser.typedValue(for: value, policy: policy)
    switch typed.kind {
    case .text:
      return value
    case .number(let number):
      if number == number.rounded(), abs(number) < 1e15 {
        return String(Int64(number))
      }
      return String(number)
    case .date(let iso):
      return iso
    }
  }

  static func encode(_ text: String, options: CSVExportOptions) -> Data {
    switch options.encoding {
    case .utf8:
      return Data(text.utf8)
    case .utf8BOM:
      var data = Data([0xEF, 0xBB, 0xBF])
      data.append(Data(text.utf8))
      return data
    case .utf16:
      var data = Data([0xFF, 0xFE])
      data.append(text.data(using: .utf16LittleEndian) ?? Data())
      return data
    }
  }
}
