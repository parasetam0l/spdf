import Foundation
import PDFCore

// FRM-07: collect form responses from several completed PDFs and form-data files
// into one reviewable table. Collection is strictly read-only: each source is
// parsed from its own bytes, merged into a new table, and the original files are
// never modified. Field-name conflicts, missing/empty values, kind mismatches
// and duplicate submissions stay visible; CSV and XLSX exports are review
// artefacts, not documents.

/// FRM-07: one reviewable response value.
public struct FormResponseValue: Sendable, Equatable {
  /// Human review text (choice selections joined in field order).
  public let displayText: String
  /// Stable comparison form used for duplicate detection.
  public let canonical: String
  /// Field kind when the source format carries one (PDF/JSON); nil for FDF/XFDF.
  public let kind: String?
  public let nonEmpty: Bool
  public let selectedValues: [String]?
  public let buttonState: String?

  public init(
    displayText: String, canonical: String, kind: String?, nonEmpty: Bool,
    selectedValues: [String]? = nil, buttonState: String? = nil
  ) {
    self.displayText = displayText
    self.canonical = canonical
    self.kind = kind
    self.nonEmpty = nonEmpty
    self.selectedValues = selectedValues
    self.buttonState = buttonState
  }

  public static func from(fieldValue value: FormFieldValue) -> Self {
    switch value.kind {
    case "button":
      let state = value.buttonState ?? "Off"
      return Self(
        displayText: state, canonical: "button:" + state, kind: "button",
        nonEmpty: state != "Off", buttonState: state)
    case "choice":
      let selected = value.selectedValues ?? (value.value.map { $0.isEmpty ? [] : [$0] } ?? [])
      let display = selected.isEmpty ? (value.value ?? "") : selected.joined(separator: "; ")
      return Self(
        displayText: display,
        canonical: "choice:" + selected.sorted().joined(separator: "\u{1F}"),
        kind: "choice", nonEmpty: !display.isEmpty,
        selectedValues: value.selectedValues)
    default:
      let text = value.value ?? ""
      return Self(
        displayText: text, canonical: "text:" + text, kind: value.kind, nonEmpty: !text.isEmpty)
    }
  }

  /// FDF/XFDF values carry no field kind; the review table treats the kind as
  /// unknown instead of guessing one.
  public static func fromDataFile(name: String, value: String?) -> Self {
    let text = value ?? ""
    return Self(
      displayText: text, canonical: "data:" + text, kind: nil, nonEmpty: !text.isEmpty)
  }
}

/// FRM-07: one completed form or data file.
public struct FormResponseSource: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case pdfDocument
    case fdf
    case xfdf
    case json
  }

  public let id: String
  public let displayName: String
  public let kind: Kind
  public let pageCount: Int?
  /// Field name to response value.
  public let values: [String: FormResponseValue]
  /// Field order as the source presents it (document order for PDFs).
  public let fieldOrder: [String]

  public init(
    id: String = UUID().uuidString, displayName: String, kind: Kind, pageCount: Int? = nil,
    values: [String: FormResponseValue], fieldOrder: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.pageCount = pageCount
    self.values = values
    self.fieldOrder = fieldOrder
  }

  public var fieldNames: [String] { fieldOrder }
  public var nonEmptyCount: Int { values.values.filter(\.nonEmpty).count }
}

/// FRM-07: how one source answered one column.
public enum FormResponseCellStatus: String, Sendable, Equatable {
  /// Answered with a non-empty value.
  case present
  /// The field exists in this response but has no value.
  case empty
  /// The source does not contain this field at all.
  case missing
}

public struct FormResponseCell: Sendable, Equatable {
  public let sourceID: String
  public let status: FormResponseCellStatus
  public let value: FormResponseValue?
  public init(sourceID: String, status: FormResponseCellStatus, value: FormResponseValue?) {
    self.sourceID = sourceID
    self.status = status
    self.value = value
  }
}

/// FRM-07: one table column (one field name across every source).
public struct FormResponseColumn: Sendable, Equatable {
  public let name: String
  public let kinds: [String]
  public let presentSourceIDs: [String]
  public let missingSourceNames: [String]
  public let emptySourceNames: [String]
  /// True when the same field name carries incompatible field kinds (for
  /// example text in one form and a checkbox in another).
  public let isTypeConflict: Bool

  public init(
    name: String, kinds: [String], presentSourceIDs: [String], missingSourceNames: [String],
    emptySourceNames: [String], isTypeConflict: Bool
  ) {
    self.name = name
    self.kinds = kinds
    self.presentSourceIDs = presentSourceIDs
    self.missingSourceNames = missingSourceNames
    self.emptySourceNames = emptySourceNames
    self.isTypeConflict = isTypeConflict
  }
}

public enum FormResponseIssueKind: String, Sendable, Equatable {
  /// A source does not contain a field another source has.
  case fieldNameConflict
  /// The same field name has incompatible kinds across sources.
  case typeMismatch
  /// The field exists but the response is empty.
  case missingValue
  /// Two submissions carry an identical response set.
  case duplicateSubmission
  /// The source yields no fields at all.
  case emptySource
}

public struct FormResponseIssue: Sendable, Equatable {
  public let kind: FormResponseIssueKind
  public let fieldName: String?
  public let sourceName: String?
  public let message: String
  public init(
    kind: FormResponseIssueKind, fieldName: String? = nil, sourceName: String? = nil,
    message: String
  ) {
    self.kind = kind
    self.fieldName = fieldName
    self.sourceName = sourceName
    self.message = message
  }
}

public struct FormResponseRow: Sendable, Equatable, Identifiable {
  public let id: String
  public let displayName: String
  public let cells: [FormResponseCell]
  public let fieldCount: Int
  public let fingerprint: String
  /// The first row with the same fingerprint, when this row duplicates it.
  public let duplicateOf: String?

  public init(
    id: String, displayName: String, cells: [FormResponseCell], fieldCount: Int,
    fingerprint: String, duplicateOf: String?
  ) {
    self.id = id
    self.displayName = displayName
    self.cells = cells
    self.fieldCount = fieldCount
    self.fingerprint = fingerprint
    self.duplicateOf = duplicateOf
  }
}

/// FRM-07: the merged, reviewable response table.
public struct FormResponseTable: Sendable, Equatable {
  public let sources: [FormResponseSource]
  public let columns: [FormResponseColumn]
  public let rows: [FormResponseRow]
  public let issues: [FormResponseIssue]

  public init(
    sources: [FormResponseSource], columns: [FormResponseColumn], rows: [FormResponseRow],
    issues: [FormResponseIssue]
  ) {
    self.sources = sources
    self.columns = columns
    self.rows = rows
    self.issues = issues
  }

  public func cell(rowID: String, columnName: String) -> FormResponseCell? {
    guard let columnIndex = columns.firstIndex(where: { $0.name == columnName }),
      let row = rows.first(where: { $0.id == rowID }),
      row.cells.indices.contains(columnIndex)
    else { return nil }
    return row.cells[columnIndex]
  }

  public var typeConflictColumns: [FormResponseColumn] { columns.filter(\.isTypeConflict) }
  public var missingValueCount: Int {
    rows.reduce(0) { total, row in
      total + row.cells.filter { $0.status == .missing || $0.status == .empty }.count
    }
  }
  public var duplicateSubmissionCount: Int { rows.filter { $0.duplicateOf != nil }.count }
  public var sourceCount: Int { sources.count }
  public var isEmpty: Bool { sources.isEmpty }

  public var summary: String {
    guard !sources.isEmpty else { return "No forms have been added yet." }
    var text = String(sources.count) + " submission" + (sources.count == 1 ? "" : "s")
      + ", " + String(columns.count) + " field" + (columns.count == 1 ? "" : "s")
    let missing = missingValueCount
    if missing > 0 { text += ", " + String(missing) + " missing/empty value(s)" }
    if duplicateSubmissionCount > 0 {
      text += ", " + String(duplicateSubmissionCount) + " duplicate submission(s)"
    }
    let conflicts = typeConflictColumns.count
    if conflicts > 0 { text += ", " + String(conflicts) + " field-name conflict(s)" }
    return text + ". Source files are only read; nothing was modified."
  }
}

public struct FormResponseCSVOptions: Sendable, Equatable {
  public var lineEnding: String
  public var includeIssueSummary: Bool
  public var quoteAllText: Bool

  public init(lineEnding: String = "\r\n", includeIssueSummary: Bool = false, quoteAllText: Bool = false) {
    self.lineEnding = lineEnding
    self.includeIssueSummary = includeIssueSummary
    self.quoteAllText = quoteAllText
  }
}

/// FRM-07: read sources and merge them into the review table.
public enum FormResponseCollection {
  // MARK: Reading sources (read-only)

  /// Read a completed PDF from its bytes. The bytes are parsed into a private
  /// graph; the input data and any original file are untouched.
  public static func readPDFSource(
    _ data: Data, displayName: String, identifier: String? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> FormResponseSource {
    let parsed = try PDFParser.parse(data, limits: limits)
    return try readGraphSource(
      parsed.graph, pageIDs: parsed.pageIDs, displayName: displayName, identifier: identifier)
  }

  /// Read a combined or currently open document graph without changing it.
  /// Combined documents produced by page assembly may keep their widget
  /// annotations without an AcroForm; those annotations are read directly so
  /// field identities and values are not lost in the review table.
  public static func readGraphSource(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], displayName: String, identifier: String? = nil
  ) throws -> FormResponseSource {
    var values = try FormValues.values(in: graph, pageIDs: pageIDs)
    if values.isEmpty {
      values = try readWidgetAnnotationValues(in: graph, pageIDs: pageIDs)
    }
    return makeSource(
      values: values.map { ($0.name, FormResponseValue.from(fieldValue: $0)) },
      displayName: displayName, kind: .pdfDocument, pageCount: pageIDs.count,
      identifier: identifier)
  }

  /// Read widget annotations directly (no AcroForm required). Used for combined
  /// documents and for documents whose form tree was dropped by assembly.
  public static func readWidgetAnnotationValues(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> [FormFieldValue] {
    var results: [FormFieldValue] = []
    var seen: Set<String> = []
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let annotations)? = page[PDFName("Annots")]
      else { continue }
      for annotation in annotations {
        guard case .reference(let annotationID) = annotation,
          case .dictionary(let dictionary)? = graph.objects[annotationID]
        else { continue }
        guard dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
          || dictionary[PDFName("FT")] != nil
        else { continue }
        guard let name = annotatedFieldName(dictionary, in: graph), !name.isEmpty,
          seen.insert(name).inserted
        else { continue }
        let type = inheritedName(PDFName("FT"), from: dictionary, in: graph)
        let value = inheritedValue(PDFName("V"), from: dictionary, in: graph)
        if type == PDFName("Tx") {
          results.append(
            FormFieldValue(name: name, kind: "text", value: decodedString(value) ?? ""))
        } else if type == PDFName("Ch") {
          var selected: [String] = []
          if case .array(let array)? = value {
            selected = array.compactMap { decodedString($0) }
          } else if let single = decodedString(value), !single.isEmpty {
            selected = [single]
          }
          results.append(
            FormFieldValue(
              name: name, kind: "choice", value: selected.joined(separator: ", "),
              selectedIndex: nil, selectedValues: selected.isEmpty ? nil : selected))
        } else if type == PDFName("Btn") {
          let state = inheritedName(PDFName("AS"), from: dictionary, in: graph)
            .map { String(decoding: $0.bytes, as: UTF8.self) } ?? "Off"
          results.append(
            FormFieldValue(name: name, kind: "button", buttonState: state))
        }
      }
    }
    return results
  }

  static func annotatedFieldName(_ dictionary: [PDFName: PDFValue], in graph: PDFGraph)
    -> String?
  {
    var parts: [String] = []
    var current: [PDFName: PDFValue]? = dictionary
    var depth = 0
    while let node = current, depth < 64 {
      if let name = decodedString(node[PDFName("T")]), !name.isEmpty, !parts.contains(name) {
        parts.append(name)
      }
      guard case .reference(let parentID)? = node[PDFName("Parent")],
        case .dictionary(let parent)? = graph.objects[parentID]
      else { break }
      current = parent
      depth += 1
    }
    return parts.reversed().joined(separator: ".")
  }

  static func inheritedName(_ key: PDFName, from dictionary: [PDFName: PDFValue], in graph: PDFGraph)
    -> PDFName?
  {
    var current: [PDFName: PDFValue]? = dictionary
    var depth = 0
    while let node = current, depth < 64 {
      if case .name(let name)? = node[key] { return name }
      guard case .reference(let parentID)? = node[PDFName("Parent")],
        case .dictionary(let parent)? = graph.objects[parentID]
      else { return nil }
      current = parent
      depth += 1
    }
    return nil
  }

  static func inheritedValue(_ key: PDFName, from dictionary: [PDFName: PDFValue], in graph: PDFGraph)
    -> PDFValue?
  {
    var current: [PDFName: PDFValue]? = dictionary
    var depth = 0
    while let node = current, depth < 64 {
      if let value = node[key] { return value }
      guard case .reference(let parentID)? = node[PDFName("Parent")],
        case .dictionary(let parent)? = graph.objects[parentID]
      else { return nil }
      current = parent
      depth += 1
    }
    return nil
  }

  static func decodedString(_ value: PDFValue?) -> String? {
    switch value {
    case .string(let data)?:
      return AnnotationText.decode(data)
    case .name(let name)?:
      return String(decoding: name.bytes, as: UTF8.self)
    default:
      return nil
    }
  }

  /// Read an FDF/XFDF form-data file. Data files carry no field kinds.
  public static func readFormDataSource(
    _ data: Data, format: FormDataExchange.Format, displayName: String, identifier: String? = nil
  ) throws -> FormResponseSource {
    let entries = try FormDataExchange.parse(data, format: format)
    var values: [String: FormResponseValue] = [:]
    var order: [String] = []
    for entry in entries {
      if values[entry.name] == nil { order.append(entry.name) }
      values[entry.name] = FormResponseValue.fromDataFile(name: entry.name, value: entry.value)
    }
    let kind: FormResponseSource.Kind = format == .fdf ? .fdf : .xfdf
    return FormResponseSource(
      id: identifier ?? UUID().uuidString, displayName: displayName, kind: kind,
      values: values, fieldOrder: order)
  }

  /// Read the JSON form-value schema written by FormValues.export.
  public static func readJSONSource(
    _ data: Data, displayName: String, identifier: String? = nil
  ) throws -> FormResponseSource {
    let values = try FormValues.parse(data)
    return makeSource(
      values: values.map { ($0.name, FormResponseValue.from(fieldValue: $0)) },
      displayName: displayName, kind: .json, pageCount: nil, identifier: identifier)
  }

  static func makeSource(
    values: [(name: String, value: FormResponseValue)], displayName: String,
    kind: FormResponseSource.Kind, pageCount: Int?, identifier: String?
  ) -> FormResponseSource {
    var mapped: [String: FormResponseValue] = [:]
    var order: [String] = []
    for entry in values {
      if mapped[entry.name] == nil { order.append(entry.name) }
      mapped[entry.name] = entry.value
    }
    return FormResponseSource(
      id: identifier ?? UUID().uuidString, displayName: displayName, kind: kind,
      pageCount: pageCount, values: mapped, fieldOrder: order)
  }

  // MARK: Merging

  /// Merge sources in the given order into one reviewable table. Columns follow
  /// first appearance; rows keep source order.
  public static func merge(_ sources: [FormResponseSource]) -> FormResponseTable {
    // Column order: source order, then each source's own field order.
    var columnOrder: [String] = []
    var seen: Set<String> = []
    for source in sources {
      for name in source.fieldOrder where !seen.contains(name) {
        seen.insert(name)
        columnOrder.append(name)
      }
      for name in source.values.keys.sorted() where !seen.contains(name) {
        seen.insert(name)
        columnOrder.append(name)
      }
    }
    var columns: [FormResponseColumn] = []
    var issues: [FormResponseIssue] = []
    for name in columnOrder {
      let present = sources.filter { $0.values[name] != nil }
      var kinds: [String] = []
      for source in present {
        guard let value = source.values[name], let kind = value.kind, !kinds.contains(kind)
        else { continue }
        kinds.append(kind)
      }
      let isTypeConflict = kinds.count > 1
      let missing = sources.filter { $0.values[name] == nil }.map(\.displayName)
      let empty = sources.filter {
        guard let value = $0.values[name] else { return false }
        return !value.nonEmpty
      }.map(\.displayName)
      columns.append(
        FormResponseColumn(
          name: name, kinds: kinds, presentSourceIDs: present.map(\.id),
          missingSourceNames: missing, emptySourceNames: empty, isTypeConflict: isTypeConflict))
      if isTypeConflict {
        issues.append(
          FormResponseIssue(
            kind: .typeMismatch, fieldName: name,
            message: "The field name " + name + " is used with different kinds: "
              + kinds.joined(separator: ", ") + "."))
      }
      if !missing.isEmpty {
        issues.append(
          FormResponseIssue(
            kind: .fieldNameConflict, fieldName: name,
            message: name + " is missing from: " + missing.joined(separator: ", ")
              + ". Those forms use a different field set."))
      }
      for sourceName in empty {
        issues.append(
          FormResponseIssue(
            kind: .missingValue, fieldName: name, sourceName: sourceName,
            message: sourceName + " left " + name + " empty."))
      }
    }
    var rows: [FormResponseRow] = []
    var fingerprints: [String: String] = [:]
    for source in sources {
      var cells: [FormResponseCell] = []
      for column in columns {
        if let value = source.values[column.name] {
          cells.append(
            FormResponseCell(
              sourceID: source.id, status: value.nonEmpty ? .present : .empty, value: value))
        } else {
          cells.append(FormResponseCell(sourceID: source.id, status: .missing, value: nil))
        }
      }
      let fingerprint = responseFingerprint(source)
      let duplicateOf = fingerprints[fingerprint]
      if duplicateOf == nil { fingerprints[fingerprint] = source.id }
      rows.append(
        FormResponseRow(
          id: source.id, displayName: source.displayName, cells: cells,
          fieldCount: source.values.values.filter(\.nonEmpty).count,
          fingerprint: fingerprint, duplicateOf: duplicateOf))
      if source.values.isEmpty {
        issues.append(
          FormResponseIssue(
            kind: .emptySource, sourceName: source.displayName,
            message: source.displayName + " has no readable form fields."))
      }
    }
    for row in rows {
      guard let originalID = row.duplicateOf,
        let original = sources.first(where: { $0.id == originalID })
      else { continue }
      issues.append(
        FormResponseIssue(
          kind: .duplicateSubmission, sourceName: row.displayName,
          message: row.displayName + " is an identical duplicate submission of "
            + original.displayName + "."))
    }
    return FormResponseTable(sources: sources, columns: columns, rows: rows, issues: issues)
  }

  /// Stable FNV-1a fingerprint of the non-empty response set.
  public static func responseFingerprint(_ source: FormResponseSource) -> String {
    let payload = source.values
      .filter { $0.value.nonEmpty }
      .map { $0.key + "\u{1F}" + $0.value.canonical }
      .sorted()
      .joined(separator: "\u{1E}")
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in payload.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return String(format: "%016llx", hash)
  }
}

// MARK: - Review exports

extension FormResponseTable {
  /// RFC 4180 CSV of the review table (submission name + one column per field).
  public func exportCSV(options: FormResponseCSVOptions = FormResponseCSVOptions()) -> Data {
    var rowsText: [String] = []
    var header = ["Submission"]
    header += columns.map(\.name)
    rowsText.append(header.map { csvField($0, options: options) }.joined(separator: ","))
    for row in self.rows {
      var fields = [row.displayName]
      fields += row.cells.map { cell in
        switch cell.status {
        case .present: return cell.value?.displayText ?? ""
        case .empty: return ""
        case .missing: return ""
        }
      }
      rowsText.append(fields.map { csvField($0, options: options) }.joined(separator: ","))
    }
    if options.includeIssueSummary {
      rowsText.append("")
      rowsText.append(csvField("Issues", options: options))
      for issue in issues {
        rowsText.append(
          csvField(issue.kind.rawValue, options: options) + ","
            + csvField(issue.message, options: options))
      }
    }
    return Data((rowsText.joined(separator: options.lineEnding) + options.lineEnding).utf8)
  }

  /// XLSX workbook with one sheet: header row then one row per submission. Uses
  /// the existing owned XLSX writer and a synthetic table description (this is a
  /// review workbook, not a page-table extraction claim).
  public func exportXLSX() throws -> Data {
    var cells: [ExtractedTable.Cell] = []
    let limit = XLSXExport.maxStringCharacters
    func add(row: Int, column: Int, text: String) {
      cells.append(
        ExtractedTable.Cell(
          row: row, column: column, text: String(text.prefix(limit)), bounds: [0, 0, 0, 0],
          provenance: .text, confidence: 1.0))
    }
    var header = ["Submission"]
    header += columns.map(\.name)
    for (column, name) in header.enumerated() { add(row: 0, column: column, text: name) }
    for (rowIndex, row) in rows.enumerated() {
      add(row: rowIndex + 1, column: 0, text: row.displayName)
      for (columnIndex, cell) in row.cells.enumerated() {
        let text: String
        switch cell.status {
        case .present: text = cell.value?.displayText ?? ""
        case .empty, .missing: text = ""
        }
        add(row: rowIndex + 1, column: columnIndex + 1, text: text)
      }
    }
    let table = ExtractedTable(
      pageIndex: 0, detection: .geometry, bounds: [0, 0, 0, 0], rowCount: rows.count + 1,
      columnCount: header.count, cells: cells, confidence: 1.0,
      limitations: ["Form response review workbook; values are collected from completed forms."])
    return try XLSXExport.package(tables: [table])
  }
}

func csvField(_ value: String, options: FormResponseCSVOptions) -> String {
  let needsQuoting =
    options.quoteAllText || value.contains(",") || value.contains("\"") || value.contains("\n")
    || value.contains("\r")
  guard needsQuoting else { return value }
  return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
