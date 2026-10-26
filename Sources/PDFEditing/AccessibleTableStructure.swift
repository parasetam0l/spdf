import Foundation
import PDFCore

// A11Y-04: accessible table structure and relationships. The model exposes what
// a screen reader needs: header cells with an explicit scope, row/column spans,
// explicit and inferred header associations, and the table summary. Reading is
// non-destructive; the commands write only Table attribute dictionaries.

public struct AccessibleTableAttributes: Sendable, Equatable {
  public var scope: String?
  public var rowSpan: Int
  public var columnSpan: Int
  public var headerElementIDs: [PDFObjectID]
  public var summary: String?

  public init(
    scope: String? = nil, rowSpan: Int = 1, columnSpan: Int = 1,
    headerElementIDs: [PDFObjectID] = [], summary: String? = nil
  ) {
    self.scope = scope
    self.rowSpan = rowSpan
    self.columnSpan = columnSpan
    self.headerElementIDs = headerElementIDs
    self.summary = summary
  }
}

/// A11Y-04: one table cell with its grid position and header relationships.
public struct AccessibleTableCell: Sendable, Equatable, Identifiable {
  public let elementID: PDFObjectID
  public let row: Int
  public let column: Int
  public let rowSpan: Int
  public let columnSpan: Int
  public let isHeader: Bool
  public let scope: String?
  /// Explicit /Headers references (source element IDs).
  public let explicitHeaderIDs: [PDFObjectID]
  /// Resolved headers (explicit when present, otherwise inferred from scope).
  public let resolvedHeaderIDs: [PDFObjectID]

  public var id: String { String(elementID.number) + "/\(row)/\(column)" }
  public var positionLabel: String {
    "row " + String(row + 1) + ", column " + String(column + 1)
  }
  public var spanLabel: String {
    var parts: [String] = []
    if columnSpan > 1 { parts.append(String(columnSpan) + " columns") }
    if rowSpan > 1 { parts.append(String(rowSpan) + " rows") }
    return parts.joined(separator: ", ")
  }

  public init(
    elementID: PDFObjectID, row: Int, column: Int, rowSpan: Int, columnSpan: Int,
    isHeader: Bool, scope: String?, explicitHeaderIDs: [PDFObjectID],
    resolvedHeaderIDs: [PDFObjectID]
  ) {
    self.elementID = elementID
    self.row = row
    self.column = column
    self.rowSpan = rowSpan
    self.columnSpan = columnSpan
    self.isHeader = isHeader
    self.scope = scope
    self.explicitHeaderIDs = explicitHeaderIDs
    self.resolvedHeaderIDs = resolvedHeaderIDs
  }
}

public struct AccessibleTableRow: Sendable, Equatable {
  public let index: Int
  public let cells: [AccessibleTableCell]
  public init(index: Int, cells: [AccessibleTableCell]) {
    self.index = index
    self.cells = cells
  }
  public var isHeaderRow: Bool { !cells.isEmpty && cells.allSatisfy(\.isHeader) }
}

public struct AccessibleTableIssue: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case noHeaderCells
    case headerWithoutScope
    case headersNotInTable
    case headerReferenceNotHeader
    case spanOutOfBounds
    case overlappingSpans
    case inconsistentRowWidth
    case emptyTable
  }

  public let kind: Kind
  public let cellElementID: PDFObjectID?
  public let message: String
  public var id: String { kind.rawValue + "/" + (cellElementID.map { String($0.number) } ?? "-") }
  public init(kind: Kind, cellElementID: PDFObjectID? = nil, message: String) {
    self.kind = kind
    self.cellElementID = cellElementID
    self.message = message
  }
}

/// A11Y-04: one Table element.
public struct AccessibleTable: Sendable, Equatable, Identifiable {
  public let elementID: PDFObjectID
  public let pageIndex: Int?
  public let summary: String?
  public let rows: [AccessibleTableRow]
  public let issues: [AccessibleTableIssue]

  public var id: String { String(elementID.number) }
  public var cells: [AccessibleTableCell] { rows.flatMap(\.cells) }
  public var headerCells: [AccessibleTableCell] { cells.filter(\.isHeader) }
  public var dataCells: [AccessibleTableCell] { cells.filter { !$0.isHeader } }
  public var columnCount: Int { cells.map { $0.column + $0.columnSpan }.max() ?? 0 }
  public var rowCount: Int { rows.count }
  public var dataCellCount: Int { dataCells.count }
  public var headerCellCount: Int { headerCells.count }
  public var hasExplicitAssociations: Bool {
    dataCells.contains { !$0.explicitHeaderIDs.isEmpty }
  }
  public var hasSpans: Bool { cells.contains { $0.rowSpan > 1 || $0.columnSpan > 1 } }
  public var describedHeaderScopes: [String] {
    headerCells.compactMap(\.scope)
  }

  public init(
    elementID: PDFObjectID, pageIndex: Int?, summary: String?,
    rows: [AccessibleTableRow], issues: [AccessibleTableIssue]
  ) {
    self.elementID = elementID
    self.pageIndex = pageIndex
    self.summary = summary
    self.rows = rows
    self.issues = issues
  }

  /// A11Y-04: screen-reader-shaped description of the table relationships.
  public func narrationLines(tableNumber: Int) -> [String] {
    var lines: [String] = []
    var header = "Table " + String(tableNumber)
    if let pageIndex { header += ", page " + String(pageIndex + 1) }
    header += ": " + String(columnCount) + " column"
      + (columnCount == 1 ? "" : "s") + " and " + String(rowCount) + " row"
      + (rowCount == 1 ? "" : "s")
    if let summary, !summary.isEmpty { header += ", summary: \"" + summary + "\"" }
    lines.append(header + ".")
    for cell in cells {
      if cell.isHeader {
        let scope = cell.scope ?? "inferred"
        var text = "Header at " + cell.positionLabel + ", scope " + scope
        if !cell.spanLabel.isEmpty { text += ", spans " + cell.spanLabel }
        let labels = dataCells.filter { $0.resolvedHeaderIDs.contains(cell.elementID) }
        if !labels.isEmpty {
          text += ", labels " + labels.map(\.positionLabel).joined(separator: ", ")
        }
        lines.append(text + ".")
      } else {
        var text = "Data cell at " + cell.positionLabel
        if !cell.spanLabel.isEmpty { text += ", spans " + cell.spanLabel }
        let headers = headerCells.filter { cell.resolvedHeaderIDs.contains($0.elementID) }
        if headers.isEmpty {
          text += ", no associated header"
        } else {
          text += ", headers " + headers.map { cell in
            cell.scope.map { scope in
              scope + " header at " + cell.positionLabel
            } ?? ("header at " + cell.positionLabel)
          }.joined(separator: " and ")
        }
        lines.append(text + ".")
      }
    }
    for issue in issues { lines.append("Issue: " + issue.message) }
    return lines
  }
}

/// A11Y-04: read the table relationships from the structure tree.
public enum AccessibleTableStructure {
  public static func tables(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> [AccessibleTable] {
    guard let inventory = try? PDFStructureInspector.inspect(
      in: graph, pageIDs: pageIDs)
    else { return [] }
    var tables: [AccessibleTable] = []
    for element in inventory.elements where element.role == "Table" {
      tables.append(table(from: element, in: graph, pageIDs: pageIDs))
    }
    return tables
  }

  /// A11Y-04: only tables with at least one cell are described; the first
  /// tables are ordered by page and structure order.
  struct PlacedCell {
    let element: PDFStructureElement
    let attributes: AccessibleTableAttributes
    let row: Int
    let column: Int
    let rowSpan: Int
    let columnSpan: Int
  }

  /// A11Y-04: build the accessible table model from one Table element.
  public static func table(
    from element: PDFStructureElement, in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> AccessibleTable {
    var issues: [AccessibleTableIssue] = []
    var rowCells: [[PDFStructureElement]] = []
    var looseCells: [PDFStructureElement] = []
    func appendRow(_ row: PDFStructureElement) {
      var cells: [PDFStructureElement] = []
      for child in row.children {
        guard case .element(let cell) = child else { continue }
        if cell.role == "TH" || cell.role == "TD" { cells.append(cell) }
      }
      rowCells.append(cells)
    }
    for child in element.children {
      guard case .element(let childElement) = child else { continue }
      switch childElement.role {
      case "TR":
        appendRow(childElement)
      case "TH", "TD":
        looseCells.append(childElement)
      case "THead", "TBody", "TFoot":
        for grandchild in childElement.children {
          guard case .element(let row) = grandchild, row.role == "TR" else { continue }
          appendRow(row)
        }
      default:
        break
      }
    }
    if rowCells.isEmpty, !looseCells.isEmpty { rowCells = [looseCells] }

    var placed: [PlacedCell] = []
    var occupancy: [Int: Set<Int>] = [:]
    var maxColumn = 0
    for (rowIndex, cellElements) in rowCells.enumerated() {
      var column = 0
      let occupied = occupancy[rowIndex] ?? []
      for cellElement in cellElements {
        guard let objectID = cellElement.objectID else { continue }
        let attrs = attributes(of: objectID, in: graph)
        while occupied.contains(column) { column += 1 }
        let rowSpan = max(attrs.rowSpan, 1)
        let columnSpan = max(attrs.columnSpan, 1)
        for row in rowIndex..<(rowIndex + rowSpan) {
          for offset in 0..<columnSpan {
            occupancy[row, default: []].insert(column + offset)
          }
        }
        maxColumn = max(maxColumn, column + columnSpan)
        placed.append(
          PlacedCell(
            element: cellElement, attributes: attrs, row: rowIndex, column: column,
            rowSpan: rowSpan, columnSpan: columnSpan))
        column += columnSpan
      }
    }

    var cells: [AccessibleTableCell] = []
    for entry in placed {
      guard let objectID = entry.element.objectID else { continue }
      let isHeader = entry.element.role == "TH"
      var resolved: [PDFObjectID] = []
      if !isHeader {
        if !entry.attributes.headerElementIDs.isEmpty {
          for headerID in entry.attributes.headerElementIDs {
            if placed.contains(where: {
              $0.element.objectID == headerID && $0.element.role == "TH"
            }) {
              resolved.append(headerID)
            } else {
              issues.append(
                AccessibleTableIssue(
                  kind: .headerReferenceNotHeader, cellElementID: objectID,
                  message: "A data cell references a header that is not a TH cell in this table."))
            }
          }
        } else {
          resolved = inferredHeaders(for: entry, placed: placed)
        }
      } else if entry.attributes.scope == nil {
        issues.append(
          AccessibleTableIssue(
            kind: .headerWithoutScope, cellElementID: objectID,
            message: "A header cell has no Scope attribute; associations are inferred from its "
              + "position and should be reviewed."))
      }
      cells.append(
        AccessibleTableCell(
          elementID: objectID, row: entry.row, column: entry.column,
          rowSpan: entry.rowSpan, columnSpan: entry.columnSpan, isHeader: isHeader,
          scope: entry.attributes.scope,
          explicitHeaderIDs: entry.attributes.headerElementIDs,
          resolvedHeaderIDs: resolved))
    }

    for entry in placed {
      guard let objectID = entry.element.objectID else { continue }
      if entry.row + entry.rowSpan > rowCells.count {
        issues.append(
          AccessibleTableIssue(
            kind: .spanOutOfBounds, cellElementID: objectID,
            message: "A cell spans beyond the table's last row."))
      }
      if entry.column + entry.columnSpan > maxColumn {
        issues.append(
          AccessibleTableIssue(
            kind: .spanOutOfBounds, cellElementID: objectID,
            message: "A cell spans beyond the table's last column."))
      }
    }
    for outer in placed where outer.rowSpan > 1 || outer.columnSpan > 1 {
      for inner in placed where inner.element.objectID != outer.element.objectID {
        let rowsOverlap = inner.row >= outer.row && inner.row < outer.row + outer.rowSpan
        let columnsOverlap =
          inner.column >= outer.column && inner.column < outer.column + outer.columnSpan
        if rowsOverlap, columnsOverlap {
          if let id = inner.element.objectID {
            issues.append(
              AccessibleTableIssue(
                kind: .overlappingSpans, cellElementID: id,
                message: "A cell starts inside another cell's row/column span."))
          }
        }
      }
    }
    if !rowCells.isEmpty {
      for rowIndex in 0..<rowCells.count {
        let width = placed.filter { $0.row == rowIndex }
          .map { $0.column + $0.columnSpan }.max() ?? 0
        if width != maxColumn {
          issues.append(
            AccessibleTableIssue(
              kind: .inconsistentRowWidth,
              message: "Row " + String(rowIndex + 1)
                + " has a different cell width than the table."))
        }
      }
    }
    let headerRows = Set(placed.filter { $0.element.role == "TH" }.map(\.row))
    if cells.isEmpty {
      issues.append(
        AccessibleTableIssue(kind: .emptyTable, message: "The table has no TH/TD cells."))
    } else if headerRows.isEmpty {
      issues.append(
        AccessibleTableIssue(kind: .noHeaderCells, message: "The table has no header (TH) cells."))
    }

    let sortedCells = cells.sorted {
      $0.row != $1.row ? $0.row < $1.row : $0.column < $1.column
    }
    let rowCount = max(rowCells.count, (sortedCells.map(\.row).max() ?? -1) + 1)
    var rows: [AccessibleTableRow] = []
    for rowIndex in 0..<rowCount {
      rows.append(
        AccessibleTableRow(
          index: rowIndex, cells: sortedCells.filter { $0.row == rowIndex }))
    }
    let summaryText = summary(of: element.objectID, in: graph)
    return AccessibleTable(
      elementID: element.objectID ?? PDFObjectID(0), pageIndex: element.pageIndex,
      summary: summaryText, rows: rows, issues: issues)
  }

  /// Inferred associations from a header's scope (or position when no scope is
  /// present). Explicit /Headers always wins; this is what a reader uses when
  /// the document has no explicit associations.
  static func inferredHeaders(
    for entry: PlacedCell, placed: [PlacedCell]
  ) -> [PDFObjectID] {
    var result: [PDFObjectID] = []
    let cellColumns = entry.column..<(entry.column + entry.columnSpan)
    let cellRows = entry.row..<(entry.row + entry.rowSpan)
    for header in placed where header.element.role == "TH" {
      guard let id = header.element.objectID else { continue }
      let columnsOverlap =
        header.column < cellColumns.upperBound
        && header.column + header.columnSpan > cellColumns.lowerBound
      let rowsOverlap =
        header.row < cellRows.upperBound
        && header.row + header.rowSpan > cellRows.lowerBound
      let scope = header.attributes.scope
      let isColumnHeader = scope == "Column" || (scope == nil && header.row == 0)
      let isRowHeader = scope == "Row" || (scope == nil && header.column == 0)
      if scope == "Both" {
        if columnsOverlap || rowsOverlap { result.append(id) }
      } else if isColumnHeader, columnsOverlap {
        result.append(id)
      } else if isRowHeader, rowsOverlap {
        result.append(id)
      }
    }
    return result
  }

  static func summary(of elementID: PDFObjectID?, in graph: PDFGraph) -> String? {
    guard let elementID = elementID,
      case .dictionary(let dictionary)? = graph.objects[elementID]
    else { return nil }
    guard let attributes = attributesDictionary(dictionary, in: graph) else { return nil }
    guard case .string(let data)? = attributes[PDFName("Summary")] else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// Read a cell's Table attribute dictionary, resolving an indirect /A.
  public static func attributes(
    of elementID: PDFObjectID?, in graph: PDFGraph
  ) -> AccessibleTableAttributes {
    guard let elementID = elementID,
      case .dictionary(let dictionary)? = graph.objects[elementID],
      let attributes = attributesDictionary(dictionary, in: graph)
    else { return AccessibleTableAttributes() }
    var result = AccessibleTableAttributes()
    switch attributes[PDFName("Scope")] {
    case .name(let name)?:
      result.scope = String(decoding: name.bytes, as: UTF8.self)
    case .string(let data)?:
      result.scope = String(decoding: data, as: UTF8.self)
    default:
      break
    }
    if case .integer(let value)? = attributes[PDFName("RowSpan")] {
      result.rowSpan = max(Int(exactly: value) ?? 1, 1)
    }
    if case .integer(let value)? = attributes[PDFName("ColSpan")] {
      result.columnSpan = max(Int(exactly: value) ?? 1, 1)
    }
    if case .string(let data)? = attributes[PDFName("Summary")] {
      result.summary = String(decoding: data, as: UTF8.self)
    }
    if case .array(let values)? = attributes[PDFName("Headers")] {
      result.headerElementIDs = values.compactMap {
        guard case .reference(let id) = $0 else { return nil }
        return id
      }
    }
    return result
  }

  static func attributesDictionary(
    _ element: [PDFName: PDFValue], in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    switch element[PDFName("A")] {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
      return dictionary
    default:
      return nil
    }
  }
}

// MARK: - Attribute commands

/// Shared read/modify helper for a Table attribute dictionary, preserving other
/// Table attributes and any non-Table /A entries.
enum AccessibleTableAttributeSupport {
  static let tableKeys: Set<PDFName> = [
    PDFName("Scope"), PDFName("Headers"), PDFName("RowSpan"), PDFName("ColSpan"),
    PDFName("Summary"), PDFName("O"),
  ]

  static func write(
    _ transform: (inout [PDFName: PDFValue]) -> Void, elementID: PDFObjectID,
    in graph: inout PDFGraph
  ) throws {
    var element = try StructureEditSupport.element(elementID, in: graph)
    switch element[PDFName("A")] {
    case .reference(let attributesID)?:
      guard case .dictionary(var attributes)? = graph.objects[attributesID] else {
        throw PDFError(.malformed, "The attribute object is missing")
      }
      var table = tableAttributes(attributes)
      transform(&table)
      // Replace the Table-owned keys completely: a removed association must not
      // survive in the attribute dictionary.
      attributes = attributes.filter { !tableKeys.contains($0.key) }
      attributes[PDFName("O")] = .name(PDFName("Table"))
      for (key, value) in table { attributes[key] = value }
      graph.objects[attributesID] = .dictionary(attributes)
    case .dictionary(var attributes)?:
      var table = tableAttributes(attributes)
      transform(&table)
      attributes = attributes.filter { !tableKeys.contains($0.key) }
      attributes[PDFName("O")] = .name(PDFName("Table"))
      for (key, value) in table { attributes[key] = value }
      element[PDFName("A")] = .dictionary(attributes)
      graph.objects[elementID] = .dictionary(element)
    default:
      var table: [PDFName: PDFValue] = [:]
      transform(&table)
      guard !table.isEmpty else {
        element.removeValue(forKey: PDFName("A"))
        graph.objects[elementID] = .dictionary(element)
        return
      }
      element[PDFName("A")] = .dictionary([
        PDFName("O"): .name(PDFName("Table"))
      ].merging(table) { _, new in new })
      graph.objects[elementID] = .dictionary(element)
    }
  }

  /// All Table-owned attributes (everything except the /O owner marker).
  static func tableAttributes(_ attributes: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
    var table: [PDFName: PDFValue] = [:]
    if case .name(let owner)? = attributes[PDFName("O")], owner == PDFName("Table") {
      for (key, value) in attributes where key != PDFName("O") {
        table[key] = value
      }
    }
    return table
  }
}

/// A11Y-04: explicit header associations for a data cell (/Headers).
public struct SetTableCellHeadersCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let headerElementIDs: [PDFObjectID]

  public init(elementID: PDFObjectID, headerElementIDs: [PDFObjectID]) {
    self.elementID = elementID
    self.headerElementIDs = headerElementIDs
  }

  public var name: String { "Set Cell Header Associations" }

  public func validate(in graph: PDFGraph) throws {
    let element = try StructureEditSupport.element(elementID, in: graph)
    let role = StructureEditSupport.resolvedRole(of: element, in: graph)
    guard role == "TD" || role == "TH" else {
      throw PDFError(.unsupported, "Header associations apply to TD/TH cells")
    }
    guard Set(headerElementIDs).count == headerElementIDs.count else {
      throw PDFError(.malformed, "A header association list repeats a cell")
    }
    let tableID = ancestorTableID(of: element, in: graph)
    for headerID in headerElementIDs {
      let header = try StructureEditSupport.element(headerID, in: graph)
      guard StructureEditSupport.resolvedRole(of: header, in: graph) == "TH" else {
        throw PDFError(.malformed, "A header association must reference a TH cell")
      }
      guard ancestorTableID(of: header, in: graph) == tableID else {
        throw PDFError(.malformed, "A header association must reference a TH cell in the same table")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    try AccessibleTableAttributeSupport.write({ table in
      if headerElementIDs.isEmpty {
        table.removeValue(forKey: PDFName("Headers"))
      } else {
        table[PDFName("Headers")] = .array(headerElementIDs.map { .reference($0) })
      }
    }, elementID: elementID, in: &graph)
    return graph
  }

  func ancestorTableID(
    of element: [PDFName: PDFValue], in graph: PDFGraph
  ) -> PDFObjectID? {
    var current = element
    var depth = 0
    while depth < 32 {
      guard case .reference(let parentID)? = current[PDFName("P")],
        case .dictionary(let parent)? = graph.objects[parentID]
      else { return nil }
      if StructureEditSupport.resolvedRole(of: parent, in: graph) == "Table" {
        return parentID
      }
      current = parent
      depth += 1
    }
    return nil
  }
}

/// A11Y-04: row/column spans (/RowSpan, /ColSpan on Table attributes).
public struct SetTableCellSpanCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let rowSpan: Int
  public let columnSpan: Int

  public init(elementID: PDFObjectID, rowSpan: Int, columnSpan: Int) {
    self.elementID = elementID
    self.rowSpan = rowSpan
    self.columnSpan = columnSpan
  }

  public var name: String { "Set Cell Spans" }

  public func validate(in graph: PDFGraph) throws {
    let element = try StructureEditSupport.element(elementID, in: graph)
    let role = StructureEditSupport.resolvedRole(of: element, in: graph)
    guard role == "TD" || role == "TH" else {
      throw PDFError(.unsupported, "Spans apply to TD/TH cells")
    }
    guard rowSpan >= 1, columnSpan >= 1 else {
      throw PDFError(.malformed, "Spans are at least one row/column")
    }
    guard rowSpan <= 1_000, columnSpan <= 1_000 else {
      throw PDFError(.limitExceeded, "A span is too large")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    try AccessibleTableAttributeSupport.write({ table in
      if rowSpan <= 1 { table.removeValue(forKey: PDFName("RowSpan")) } else {
        table[PDFName("RowSpan")] = .integer(Int64(rowSpan))
      }
      if columnSpan <= 1 { table.removeValue(forKey: PDFName("ColSpan")) } else {
        table[PDFName("ColSpan")] = .integer(Int64(columnSpan))
      }
    }, elementID: elementID, in: &graph)
    return graph
  }
}

/// A11Y-04: table summary (/Summary in Table attributes).
public struct SetTableSummaryCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let summary: String?

  public init(elementID: PDFObjectID, summary: String?) {
    self.elementID = elementID
    self.summary = summary
  }

  public var name: String { "Set Table Summary" }

  public func validate(in graph: PDFGraph) throws {
    let element = try StructureEditSupport.element(elementID, in: graph)
    guard StructureEditSupport.resolvedRole(of: element, in: graph) == "Table" else {
      throw PDFError(.unsupported, "A summary applies to a Table element")
    }
    if let summary {
      guard summary.count <= 2_000 else {
        throw PDFError(.limitExceeded, "The table summary is too long")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    try AccessibleTableAttributeSupport.write({ table in
      if let summary, !summary.isEmpty {
        table[PDFName("Summary")] = .string(Data(summary.utf8))
      } else {
        table.removeValue(forKey: PDFName("Summary"))
      }
    }, elementID: elementID, in: &graph)
    return graph
  }
}
