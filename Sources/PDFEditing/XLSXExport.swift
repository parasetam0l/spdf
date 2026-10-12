import Foundation
import PDFCore

/// P36-017–P36-024: XLSX packaging options. Values are literal unless typed
/// mode is chosen; formulas are never emitted as executable expressions.
public struct XLSXExportOptions: Sendable, Equatable {
  public var sheetNamePrefix: String
  /// P36-024: add a trailing `Source` column with `Page N` only when asked.
  public var includeSourcePage: Bool
  /// Use the typed-value policy for number/date cells (P36-020).
  public var typedValues: Bool
  public var valuePolicy: TableValuePolicy

  public init(
    sheetNamePrefix: String = "Table", includeSourcePage: Bool = false,
    typedValues: Bool = true, valuePolicy: TableValuePolicy = .init()
  ) {
    self.sheetNamePrefix = sheetNamePrefix
    self.includeSourcePage = includeSourcePage
    self.typedValues = typedValues
    self.valuePolicy = valuePolicy
  }
}

/// P36-017–P36-025: a deterministic, bounded XLSX (SpreadsheetML) package.
/// References: ECMA-376 Part 1 (SpreadsheetML) and the OPC relationship rules;
/// the ZIP container is the project's own writer. No macros, no external
/// relationships, and no `<f>` elements — formula-looking text stays literal.
public enum XLSXExport {
  public static let contentTypesPart = "[Content_Types].xml"
  public static let packageRelationshipsPart = "_rels/.rels"
  public static let workbookPart = "xl/workbook.xml"
  public static let workbookRelationshipsPart = "xl/_rels/workbook.xml.rels"
  public static let stylesPart = "xl/styles.xml"
  public static let sharedStringsPart = "xl/sharedStrings.xml"

  public static func worksheetPart(index: Int) -> String {
    "xl/worksheets/sheet\(index).xml"
  }

  /// Bounds: sheets, cells per sheet, and string length (Excel's own limits).
  public static let maxSheets = 128
  public static let maxCellsPerSheet = 250_000
  public static let maxStringCharacters = 32_767
  public static let dateNumberFormatID = 164

  /// P36-017–P36-024: package the extracted tables as one sheet each.
  public static func package(
    tables: [ExtractedTable], options: XLSXExportOptions = .init(),
    zipLimits: ZIPArchiveWriter.Limits = .init()
  ) throws -> Data {
    guard tables.count <= maxSheets else {
      throw PDFError(.limitExceeded, "The document exceeds the sheet limit")
    }
    for table in tables {
      guard table.rowCount * table.columnCount <= maxCellsPerSheet else {
        throw PDFError(.limitExceeded, "A table exceeds the cell limit")
      }
    }

    // P36-019: shared strings in first-appearance order, deduplicated.
    var sharedStrings: [String] = []
    var sharedIndex: [String: Int] = [:]
    func intern(_ value: String) -> Int {
      let bounded = String(value.prefix(maxStringCharacters))
      if let index = sharedIndex[bounded] { return index }
      let index = sharedStrings.count
      sharedStrings.append(bounded)
      sharedIndex[bounded] = index
      return index
    }

    var sheets: [String] = []
    var sheetNames: [String] = []
    for (index, table) in tables.enumerated() {
      let name = sheetName(options.sheetNamePrefix, index: index)
      sheetNames.append(name)
      sheets.append(
        try worksheet(table: table, options: options, intern: intern))
    }
    if sheets.isEmpty {
      // A workbook needs at least one sheet; an empty document exports empty.
      sheetNames.append(sheetName(options.sheetNamePrefix, index: 0))
      sheets.append(
        worksheetXML(rows: [], columnWidths: [], merges: [], dimension: "A1"))
    }

    var zip = ZIPArchiveWriter(limits: zipLimits)
    try zip.add(
      name: contentTypesPart,
      data: contentTypes(sheetCount: sheets.count, hasSharedStrings: !sharedStrings.isEmpty))
    try zip.add(name: packageRelationshipsPart, data: packageRelationships())
    try zip.add(name: workbookPart, data: workbook(sheetNames: sheetNames))
    try zip.add(
      name: workbookRelationshipsPart,
      data: workbookRelationships(
        sheetCount: sheets.count, hasSharedStrings: !sharedStrings.isEmpty))
    try zip.add(name: stylesPart, data: styles())
    if !sharedStrings.isEmpty {
      try zip.add(name: sharedStringsPart, data: sharedStringsXML(sharedStrings))
    }
    for (index, sheet) in sheets.enumerated() {
      try zip.add(name: worksheetPart(index: index + 1), data: Data(sheet.utf8))
    }
    return try zip.archive()
  }

  static func sheetName(_ prefix: String, index: Int) -> String {
    let bounded = String(prefix.prefix(24))
    return "\(bounded.isEmpty ? "Table" : bounded) \(index + 1)"
  }

  // MARK: - Parts

  static func contentTypes(sheetCount: Int, hasSharedStrings: Bool) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>

      """
    if hasSharedStrings {
      xml += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>\n"
    }
    for index in 1...max(sheetCount, 1) {
      xml += "<Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n"
    }
    xml += "</Types>\n"
    return Data(xml.utf8)
  }

  static func packageRelationships() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>

      """.utf8)
  }

  static func workbook(sheetNames: [String]) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>

      """
    for (index, name) in sheetNames.enumerated() {
      xml +=
        "<sheet name=\"\(DOCXXML.escape(name))\" sheetId=\"\(index + 1)\" r:id=\"rIdSheet\(index + 1)\"/>\n"
    }
    xml += "</sheets>\n</workbook>\n"
    return Data(xml.utf8)
  }

  static func workbookRelationships(sheetCount: Int, hasSharedStrings: Bool) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>

      """
    if hasSharedStrings {
      xml += "<Relationship Id=\"rIdSharedStrings\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>\n"
    }
    for index in 1...max(sheetCount, 1) {
      xml +=
        "<Relationship Id=\"rIdSheet\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index).xml\"/>\n"
    }
    xml += "</Relationships>\n"
    return Data(xml.utf8)
  }

  /// P36-023: one border style for table cells, one date number format, and
  /// top-aligned wrapped text. Built-in formats only otherwise.
  static func styles() -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <numFmts count="1"><numFmt numFmtId="\(dateNumberFormatID)" formatCode="yyyy\\-mm\\-dd"/></numFmts>
      <fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/></font></fonts>
      <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
      <borders count="2">
      <border><left/><right/><top/><bottom/><diagonal/></border>
      <border><left style="thin"><color rgb="FF9E9E9E"/></left><right style="thin"><color rgb="FF9E9E9E"/></right><top style="thin"><color rgb="FF9E9E9E"/></top><bottom style="thin"><color rgb="FF9E9E9E"/></bottom><diagonal/></border>
      </borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="2">
      <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
      <xf numFmtId="\(dateNumberFormatID)" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
      </cellXfs>
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
      </styleSheet>

      """.utf8)
  }

  static func sharedStringsXML(_ strings: [String]) -> Data {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(strings.count)" uniqueCount="\(strings.count)">

      """
    for value in strings {
      xml += "<si><t xml:space=\"preserve\">\(DOCXXML.escape(value))</t></si>\n"
    }
    xml += "</sst>\n"
    return Data(xml.utf8)
  }

  // MARK: - Worksheets

  static func worksheet(
    table: ExtractedTable, options: XLSXExportOptions, intern: (String) -> Int
  ) throws -> String {
    let extraColumns = options.includeSourcePage ? 1 : 0
    let columnCount = table.columnCount + extraColumns
    var rows: [String] = []
    var merges: [String] = []
    var cellCount = 0
    for row in 0..<table.rowCount {
      var cells: [String] = []
      for column in 0..<columnCount {
        guard column < table.columnCount else {
          // P36-024: the optional provenance column.
          let reference = cellReference(row: row + 1, column: column)
          let index = intern("Page \(table.pageIndex + 1)")
          cells.append("<c r=\"\(reference)\" s=\"0\" t=\"s\"><v>\(index)</v></c>")
          continue
        }
        guard let cell = table.cell(row: row, column: column) else { continue }
        cellCount += 1
        cells.append(
          cellXML(cell, row: row, column: column, options: options, intern: intern))
        if cell.rowSpan > 1 || cell.columnSpan > 1 {
          let start = cellReference(row: row + 1, column: column)
          let end = cellReference(
            row: min(row + cell.rowSpan, table.rowCount), column: column + cell.columnSpan - 1)
          merges.append("<mergeCell ref=\"\(start):\(end)\"/>")
        }
      }
      guard !cells.isEmpty else { continue }
      let height = rowHeight(table: table, row: row)
      let attributes = height.map { " ht=\"\(rounded($0))\" customHeight=\"1\"" } ?? ""
      rows.append("<row r=\"\(row + 1)\"\(attributes)>\(cells.joined())</row>")
    }
    guard cellCount <= maxCellsPerSheet else {
      throw PDFError(.limitExceeded, "A table exceeds the cell limit")
    }
    let widths = (0..<table.columnCount).map { column in
      columnWidth(table: table, column: column)
    } + (options.includeSourcePage ? [12.0] : [])
    let dimensionEnd = cellReference(
      row: max(table.rowCount, 1), column: max(columnCount, 1) - 1)
    return worksheetXML(
      rows: rows, columnWidths: widths, merges: merges,
      dimension: "A1:\(dimensionEnd)")
  }

  static func worksheetXML(
    rows: [String], columnWidths: [Double], merges: [String], dimension: String
  ) -> String {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <dimension ref="\(dimension)"/>
      <sheetViews><sheetView workbookViewId="0"/></sheetViews>
      <sheetFormatPr defaultRowHeight="15"/>

      """
    if !columnWidths.isEmpty {
      xml += "<cols>"
      for (index, width) in columnWidths.enumerated() {
        xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(rounded(max(8, width)))\" customWidth=\"1\"/>"
      }
      xml += "</cols>\n"
    }
    xml += "<sheetData>\n"
    for row in rows { xml += row + "\n" }
    xml += "</sheetData>\n"
    if !merges.isEmpty {
      xml += "<mergeCells count=\"\(merges.count)\">\(merges.joined())</mergeCells>\n"
    }
    xml += "</worksheet>\n"
    return xml
  }

  /// P36-020/P36-021/P36-023: one cell with an explicit type. Text (including
  /// formula-looking values) is a shared string; numbers are numeric; dates are
  /// serial numbers with the date style. `<f>` is never emitted.
  static func cellXML(
    _ cell: ExtractedTable.Cell, row: Int, column: Int, options: XLSXExportOptions,
    intern: (String) -> Int
  ) -> String {
    let reference = cellReference(row: row + 1, column: column)
    let typed =
      options.typedValues
      ? TableValueParser.typedValue(for: cell.text, policy: options.valuePolicy)
      : TableTypedValue(displayText: cell.text, kind: .text)
    switch typed.kind {
    case .number(let number):
      let value = number == number.rounded() && abs(number) < 1e15
        ? String(Int64(number)) : String(number)
      return "<c r=\"\(reference)\" s=\"0\"><v>\(value)</v></c>"
    case .date(let iso):
      let serial = dateSerial(iso)
      return "<c r=\"\(reference)\" s=\"1\"><v>\(serial)</v></c>"
    case .text:
      let index = intern(cell.text)
      return "<c r=\"\(reference)\" s=\"0\" t=\"s\"><v>\(index)</v></c>"
    }
  }

  /// Excel's 1900 date system serial (1899-12-30 epoch).
  static func dateSerial(_ iso: String) -> Int {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: iso) else { return 0 }
    let days = date.timeIntervalSince1970 / 86_400 + 25_569
    return Int(days.rounded())
  }

  /// P36-022: row height from the row's tallest cell (points).
  static func rowHeight(table: ExtractedTable, row: Int) -> Double? {
    let heights = table.cells.filter { $0.row == row }.map { $0.bounds[3] - $0.bounds[1] }
    guard let height = heights.max(), height > 0 else { return nil }
    return max(15, height + 2)
  }

  /// P36-022: column width from the column's widest cell, converted from points
  /// to Excel character units (~7 px per character at 96 dpi).
  static func columnWidth(table: ExtractedTable, column: Int) -> Double {
    let widths = table.cells.filter { $0.column == column }.map { $0.bounds[2] - $0.bounds[0] }
    let points = widths.max() ?? 60
    return max(8, min(120, points * 96 / 72 / 7))
  }

  /// A1-style reference; column 0 is `A`.
  public static func cellReference(row: Int, column: Int) -> String {
    var index = max(column, 0)
    var letters = ""
    repeat {
      letters = String(UnicodeScalar(UInt8(65 + index % 26))) + letters
      index = index / 26 - 1
    } while index >= 0
    return letters + String(max(row, 1))
  }

  static func rounded(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    return String(rounded)
  }
}
