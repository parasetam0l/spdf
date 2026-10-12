import Foundation
import PDFCore

/// P36-001: how table candidates are detected. `automatic` prefers reliable
/// structure tags, then vector rules, then text geometry; `ruled` and
/// `unruled` restrict detection to one evidence source.
public struct TableDetectionProfile: Sendable, Equatable {
  public enum Mode: String, Sendable, Equatable {
    case automatic
    case ruled
    case unruled
  }

  public var mode: Mode
  /// Minimum rows/columns a candidate must have.
  public var minimumRows: Int
  public var minimumColumns: Int
  /// Minimum cells a geometry candidate must have.
  public var minimumCellCount: Int
  /// Confidence below which a detection is kept but marked for review.
  public var confidenceGate: Double
  /// Maximum tables returned per page.
  public var maximumTablesPerPage: Int
  /// Maximum text candidates considered per page.
  public var maximumCandidates: Int

  public init(
    mode: Mode = .automatic, minimumRows: Int = 2, minimumColumns: Int = 2,
    minimumCellCount: Int = 4, confidenceGate: Double = 0.6,
    maximumTablesPerPage: Int = 32, maximumCandidates: Int = 2_000
  ) {
    self.mode = mode
    self.minimumRows = minimumRows
    self.minimumColumns = minimumColumns
    self.minimumCellCount = minimumCellCount
    self.confidenceGate = confidenceGate
    self.maximumTablesPerPage = maximumTablesPerPage
    self.maximumCandidates = maximumCandidates
  }
}

/// P36-002–P36-008: one extracted table with cell values, inferred spans,
/// detection evidence, and recognition provenance.
public struct ExtractedTable: Sendable, Equatable {
  public enum Detection: String, Sendable, Equatable {
    /// Reliable structure tags (P36-007).
    case tagged
    /// Vector rules (P36-002).
    case ruled
    /// Text geometry only (P36-003).
    case geometry
  }

  public enum Provenance: String, Sendable, Equatable {
    /// Text decoded from the page's own content.
    case text
    /// Text from a generated searchable-text (OCR) layer; recognition
    /// confidence stays with the layer (P36-008).
    case ocr
  }

  public struct Cell: Sendable, Equatable {
    public let row: Int
    public let column: Int
    public let rowSpan: Int
    public let columnSpan: Int
    /// Displayed text with its original characters (leading zeros preserved,
    /// P36-011); multi-line cell text keeps its line order (P36-004).
    public let text: String
    public let bounds: [Double]
    public let provenance: Provenance
    public let confidence: Double

    public init(
      row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, text: String,
      bounds: [Double], provenance: Provenance, confidence: Double
    ) {
      self.row = row
      self.column = column
      self.rowSpan = rowSpan
      self.columnSpan = columnSpan
      self.text = text
      self.bounds = bounds
      self.provenance = provenance
      self.confidence = confidence
    }
  }

  public let pageIndex: Int
  public let detection: Detection
  public let bounds: [Double]
  public let rowCount: Int
  public let columnCount: Int
  public let cells: [Cell]
  public let confidence: Double
  public let limitations: [String]

  public init(
    pageIndex: Int, detection: Detection, bounds: [Double], rowCount: Int, columnCount: Int,
    cells: [Cell], confidence: Double, limitations: [String]
  ) {
    self.pageIndex = pageIndex
    self.detection = detection
    self.bounds = bounds
    self.rowCount = rowCount
    self.columnCount = columnCount
    self.cells = cells
    self.confidence = confidence
    self.limitations = limitations
  }

  public func cell(row: Int, column: Int) -> Cell? {
    cells.first { $0.row == row && $0.column == column }
  }

  /// The cell text as a row-major grid, `nil` for slots covered by a span.
  public func grid() -> [[String?]] {
    var result = Array(
      repeating: Array(repeating: String?.none, count: columnCount), count: rowCount)
    for cell in cells {
      if cell.row < rowCount, cell.column < columnCount {
        result[cell.row][cell.column] = cell.text
      }
      for row in cell.row..<min(cell.row + cell.rowSpan, rowCount) {
        for column in cell.column..<min(cell.column + cell.columnSpan, columnCount) {
          if row != cell.row || column != cell.column {
            result[row][column] = nil  // covered by the span
          }
        }
      }
    }
    return result
  }
}

public enum TableExtraction {
  public static let maxSegmentsPerPage = 20_000

  /// P36-002–P36-008: extract tables from the given pages. `recognizedLines`
  /// carries OCR results per page index (from the recognition job); cells whose
  /// boxes overlap a recognized line take that line's text and keep `.ocr`
  /// provenance. No OCR text is ever invented locally.
  public static func tables(
    pageIDs: [PDFObjectID], in graph: PDFGraph, profile: TableDetectionProfile = .init(),
    recognizedLines: [Int: [SearchableTextLine]] = [:]
  ) throws -> [ExtractedTable] {
    var result: [ExtractedTable] = []
    let rolesByPage = ParagraphReconstruction.structureRolesByPage(
      in: graph, pageIDs: pageIDs)
    for (pageIndex, pageID) in pageIDs.enumerated() {
      try Task.checkCancellation()
      let candidates = try ParagraphReconstruction.candidates(
        pageID: pageID, in: graph, roles: rolesByPage[pageID] ?? [:]
      ).prefix(profile.maximumCandidates)
      let candidateList = Array(candidates)
      let lines = recognizedLines[pageIndex] ?? []
      let layout = profile.mode == .unruled ? nil : try? PageTextLayout.build(pageID: pageID, in: graph)
      var pageTables: [ExtractedTable] = []

      if profile.mode != .unruled {
        pageTables += taggedTables(
          pageIndex: pageIndex, pageID: pageID, in: graph, pageIDs: pageIDs,
          candidates: candidateList, profile: profile)
      }
      if profile.mode != .unruled {
        pageTables += ruledTables(
          pageIndex: pageIndex, pageID: pageID, in: graph, candidates: candidateList,
          profile: profile, recognizedLines: lines, layout: layout)
      }
      if profile.mode != .ruled {
        if let geometry = geometryTable(
          pageIndex: pageIndex, candidates: candidateList, profile: profile)
        {
          pageTables.append(geometry)
        }
      }
      if !lines.isEmpty {
        pageTables = pageTables.map { table in
          ExtractedTable(
            pageIndex: table.pageIndex, detection: table.detection, bounds: table.bounds,
            rowCount: table.rowCount, columnCount: table.columnCount,
            cells: applyingRecognizedLines(table.cells, lines: lines),
            confidence: table.confidence, limitations: table.limitations)
        }
      }

      // Evidence priority: tagged > ruled > geometry. Overlapping lower-priority
      // detections are dropped rather than duplicated.
      var accepted: [ExtractedTable] = []
      for table in pageTables {
        let overlaps = accepted.contains { existing in
          overlapRatio(existing.bounds, table.bounds) >= 0.5
        }
        if !overlaps {
          accepted.append(table)
        }
      }
      result += accepted.prefix(profile.maximumTablesPerPage)
    }
    return result
  }

  // MARK: - Tagged tables (P36-007)

  static func taggedTables(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph, pageIDs: [PDFObjectID],
    candidates: [TextParagraphCandidate], profile: TableDetectionProfile
  ) -> [ExtractedTable] {
    guard let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    else { return [] }
    let mcidByCandidate = candidateMCIDs(
      pageID: pageID, in: graph, candidates: candidates)
    var candidateByMCID: [Int: Int] = [:]
    for (index, mcid) in mcidByCandidate where candidateByMCID[mcid] == nil {
      candidateByMCID[mcid] = index
    }
    var tables: [ExtractedTable] = []
    for element in inventory.elements where element.role == "Table" {
      var cells: [ExtractedTable.Cell] = []
      var rowIndex = 0
      for rowChild in element.children {
        guard case .element(let row) = rowChild,
          ["TR", "THead", "TBody", "TFoot"].contains(row.role)
        else { continue }
        var columnIndex = 0
        for cellChild in row.children {
          let cellElement: PDFStructureElement?
          if case .element(let nested) = cellChild { cellElement = nested } else { cellElement = nil }
          if let cellElement, !["TD", "TH"].contains(cellElement.role) {
            if cellElement.role == "TR" || cellElement.role == "Table" { continue }
          }
          let contentChildren: [PDFStructureChild]
          if let cellElement {
            contentChildren = cellElement.children
          } else if case .content = cellChild {
            contentChildren = [cellChild]
          } else {
            continue
          }
          var texts: [String] = []
          var bounds: [Double] = []
          var confidence = 1.0
          let provenance = ExtractedTable.Provenance.text
          for contentChild in contentChildren {
            guard case .content(let contentPage, let mcid) = contentChild,
              contentPage == nil || contentPage == pageIndex,
              let candidateIndex = candidateByMCID[mcid]
            else { continue }
            let candidate = candidates[candidateIndex]
            texts.append(candidate.text)
            bounds = unionBounds(bounds.isEmpty ? [candidate.bounds] : [bounds, candidate.bounds])
            confidence = min(confidence, candidate.confidence)

          }
          if !texts.isEmpty {
            cells.append(
              ExtractedTable.Cell(
                row: rowIndex, column: columnIndex,
                text: texts.joined(separator: "\n"), bounds: bounds, provenance: provenance,
                confidence: 0.95))
          }
          columnIndex += 1
        }
        if !cells.isEmpty || columnIndex > 0 { rowIndex += 1 }
      }
      guard !cells.isEmpty else { continue }
      let rowCount = (cells.map(\.row).max() ?? 0) + 1
      let columnCount = (cells.map(\.column).max() ?? 0) + 1
      guard rowCount >= profile.minimumRows, columnCount >= profile.minimumColumns else {
        continue
      }
      tables.append(
        ExtractedTable(
          pageIndex: pageIndex, detection: .tagged,
          bounds: unionBounds(cells.map(\.bounds)), rowCount: rowCount, columnCount: columnCount,
          cells: cells, confidence: 0.95, limitations: []))
    }
    return tables
  }

  /// Candidate index -> the MCID of its first run.
  static func candidateMCIDs(
    pageID: PDFObjectID, in graph: PDFGraph, candidates: [TextParagraphCandidate]
  ) -> [Int: Int] {
    guard let content = try? PageContent.load(pageID: pageID, in: graph),
      let runs = try? TextRunIndexer.runs(in: content, graph: graph)
    else { return [:] }
    let ranges = StructureTaggingAssistant.markedRanges(in: content)
    guard !ranges.isEmpty else { return [:] }
    var mcidByRun: [Int: Int] = [:]
    for (index, run) in runs.enumerated() {
      for range in ranges {
        if let mcid = range.mcid, range.instructions.contains(run.instructionIndex) {
          mcidByRun[index] = mcid
          break
        }
      }
    }
    var result: [Int: Int] = [:]
    for (index, candidate) in candidates.enumerated() {
      if let firstRun = candidate.runIndices.first, let mcid = mcidByRun[firstRun] {
        result[index] = mcid
      }
    }
    return result
  }

  // MARK: - Ruled tables (P36-002)

  /// One horizontal or vertical vector rule in page space.
  struct Rule: Sendable, Equatable {
    let x0: Double
    let y0: Double
    let x1: Double
    let y1: Double

    var isHorizontal: Bool { abs(y1 - y0) <= 0.75 && abs(x1 - x0) >= 4 }
    var isVertical: Bool { abs(x1 - x0) <= 0.75 && abs(y1 - y0) >= 4 }
    var y: Double { (y0 + y1) / 2 }
    var x: Double { (x0 + x1) / 2 }
  }

  /// P36-002: vector rules from path construction (`re`, `m`/`l`) flushed at
  /// paint operators. The page CTM is assumed to be identity, matching the
  /// layout profile; transformed tables are not detected here.
  static func vectorRules(in content: PageContent) -> [Rule] {
    var pending: [Rule] = []
    var rules: [Rule] = []
    var current: (x: Double, y: Double)?
    var visited = 0
    func flush(paint: Bool) {
      if paint { rules.append(contentsOf: pending) }
      pending.removeAll(keepingCapacity: true)
    }
    for instruction in content.instructions {
      visited += 1
      if visited > 200_000 { break }
      switch instruction.operatorName {
      case "re":
        if let values = numbers(instruction.operands), values.count == 4 {
          let x = values[0], y = values[1], width = values[2], height = values[3]
          pending.append(Rule(x0: x, y0: y, x1: x + width, y1: y))
          pending.append(Rule(x0: x, y0: y + height, x1: x + width, y1: y + height))
          pending.append(Rule(x0: x, y0: y, x1: x, y1: y + height))
          pending.append(Rule(x0: x + width, y0: y, x1: x + width, y1: y + height))
        }
      case "m":
        if let values = numbers(instruction.operands), values.count == 2 {
          current = (values[0], values[1])
        }
      case "l":
        if let values = numbers(instruction.operands), values.count == 2, let start = current {
          pending.append(Rule(x0: start.x, y0: start.y, x1: values[0], y1: values[1]))
          current = (values[0], values[1])
        }
      case "S", "s", "B", "B*", "b", "b*", "f", "F", "f*":
        flush(paint: true)
        current = nil
      case "n":
        flush(paint: false)
        current = nil
      default:
        break
      }
      if rules.count > maxSegmentsPerPage { break }
    }
    flush(paint: false)
    return rules
  }

  /// P36-004: one line of a candidate with its own bounds, so tight table rows
  /// receive the lines that belong to them even when the analysis merged the
  /// cell's (or column's) lines into one candidate.
  struct LineEntry: Sendable, Equatable {
    let text: String
    let bounds: [Double]
    let confidence: Double
  }

  static func lineEntries(
    candidates: [TextParagraphCandidate], layout: PageTextLayout?
  ) -> [LineEntry] {
    guard let layout else {
      return candidates.map {
        LineEntry(text: $0.text, bounds: $0.bounds, confidence: $0.confidence)
      }
    }
    var entries: [LineEntry] = []
    for candidate in candidates {
      let runSet = Set(candidate.runIndices)
      // The candidate's own text keeps word spacing (glyph clusters would lose
      // whitespace for fonts without metrics).
      let candidateLines = candidate.text.components(separatedBy: "\n")
      let canSplitText = candidateLines.count == candidate.lineIndices.count
      var added = false
      for (position, lineIndex) in candidate.lineIndices.enumerated() {
        guard lineIndex >= 0, lineIndex < layout.lines.count else { continue }
        let clusters = layout.lines[lineIndex].compactMap { index -> TextCluster? in
          let cluster = layout.clusters[index]
          return runSet.contains(cluster.runIndex) ? cluster : nil
        }
        let visible = clusters.filter { !$0.isWhitespace }
        guard !visible.isEmpty else { continue }
        let lineText =
          canSplitText ? candidateLines[position] : visible.map(\.text).joined()
        let union = unionBounds(visible.map(\.bounds))
        // Fonts without metrics report zero-width markers; keep the
        // candidate's horizontal extent and the line's vertical extent.
        let bounds: [Double] =
          union[2] - union[0] > 0.5
          ? union : [candidate.bounds[0], union[1], candidate.bounds[2], union[3]]
        entries.append(
          LineEntry(text: lineText, bounds: bounds, confidence: candidate.confidence))
        added = true
      }
      if !added {
        entries.append(
          LineEntry(text: candidate.text, bounds: candidate.bounds, confidence: candidate.confidence))
      }
    }
    return entries
  }

  static func ruledTables(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph,
    candidates: [TextParagraphCandidate], profile: TableDetectionProfile,
    recognizedLines: [SearchableTextLine] = [], layout: PageTextLayout? = nil
  ) -> [ExtractedTable] {
    guard let content = try? PageContent.load(pageID: pageID, in: graph) else { return [] }
    let rules = vectorRules(in: content)
    let horizontals = rules.filter(\.isHorizontal).sorted { $0.y > $1.y }
    let verticals = rules.filter(\.isVertical)
    guard horizontals.count >= 3, verticals.count >= 3 else { return [] }

    // Group horizontal rules that share an extent and are vertically adjacent
    // (a generous row-height bound; stacked tables are split later when their
    // vertical rules do not span the merged group).
    var groups: [[Rule]] = []
    for rule in horizontals {
      var attached = false
      if var last = groups.last {
        let extent = (last.map(\.x0).min() ?? 0, last.map(\.x1).max() ?? 0)
        let ruleExtent = (rule.x0, rule.x1)
        let overlap = min(extent.1, ruleExtent.1) - max(extent.0, ruleExtent.0)
        let union = max(extent.1, ruleExtent.1) - min(extent.0, ruleExtent.0)
        let shares = union > 0 && overlap / union >= 0.5
        let gap = (last.last?.y ?? 0) - rule.y
        if shares, gap >= 0, gap <= 96 {
          last.append(rule)
          groups[groups.count - 1] = last
          attached = true
        }
      }
      if !attached { groups.append([rule]) }
    }

    var tables: [ExtractedTable] = []
    var pendingGroups = groups.filter { $0.count >= profile.minimumRows + 1 }
    var attempts = 0
    while let group = pendingGroups.popLast(), attempts < 64 {
      attempts += 1
      if let table = ruledTable(
        from: group, pageIndex: pageIndex, verticals: verticals, candidates: candidates,
        profile: profile, recognizedLines: recognizedLines, layout: layout)
      {
        tables.append(table)
        continue
      }
      // A merged group may contain stacked tables: split at the largest gap
      // between distinct row lines and retry each part.
      let uniqueY = group.map(\.y).sorted(by: >).reduce(into: [Double]()) { result, y in
        if result.last.map({ abs($0 - y) > 1.5 }) ?? true { result.append(y) }
      }
      guard uniqueY.count >= 4 else { continue }
      var splitIndex = 1
      var largestGap = 0.0
      for index in 1..<uniqueY.count {
        let gap = uniqueY[index - 1] - uniqueY[index]
        if gap > largestGap {
          largestGap = gap
          splitIndex = index
        }
      }
      guard largestGap > 0 else { continue }
      let top = uniqueY[splitIndex - 1]
      let bottom = uniqueY[splitIndex]
      let upper = group.filter { $0.y >= top - 1 }
      let lower = group.filter { $0.y <= bottom + 1 }
      if upper.count >= profile.minimumRows + 1 { pendingGroups.append(upper) }
      if lower.count >= profile.minimumRows + 1 { pendingGroups.append(lower) }
    }
    return tables
  }

  /// Assemble one ruled table from a group of horizontal rules, or nil when the
  /// group is not a coherent grid.
  static func ruledTable(
    from group: [Rule], pageIndex: Int, verticals: [Rule],
    candidates: [TextParagraphCandidate], profile: TableDetectionProfile,
    recognizedLines: [SearchableTextLine] = [], layout: PageTextLayout? = nil
  ) -> ExtractedTable? {
      let minimumY = group.map(\.y).min() ?? 0
      let maximumY = group.map(\.y).max() ?? 0
      guard maximumY - minimumY >= 4 else { return nil }
      let minimumX = group.map(\.x0).min() ?? 0
      let maximumX = group.map(\.x1).max() ?? 0
      var rowY: [Double] = []
      for rule in group {
        if !rowY.contains(where: { abs($0 - rule.y) <= 1.5 }) { rowY.append(rule.y) }
      }
      rowY.sort(by: >)
      guard rowY.count >= profile.minimumRows + 1 else { return nil }
      let rowBands = (0..<(rowY.count - 1)).map { (top: rowY[$0], bottom: rowY[$0 + 1]) }

      // Column boundaries: x positions whose vertical rules cover at least one
      // full row band (a merged row splits a column line into segments).
      var xGroups: [(x: Double, minY: Double, maxY: Double)] = []
      for rule in verticals.sorted(by: { $0.x < $1.x }) {
        let low = min(rule.y0, rule.y1)
        let high = max(rule.y0, rule.y1)
        if let index = xGroups.firstIndex(where: { abs($0.x - rule.x) <= 1.5 }) {
          xGroups[index].minY = min(xGroups[index].minY, low)
          xGroups[index].maxY = max(xGroups[index].maxY, high)
        } else {
          xGroups.append((rule.x, low, high))
        }
      }
      var columnX: [Double] = []
      for group in xGroups
      where group.x >= minimumX - 2 && group.x <= maximumX + 2
        && rowBands.contains(where: { group.minY <= $0.bottom + 1 && group.maxY >= $0.top - 1 })
      {
        if !columnX.contains(where: { abs($0 - group.x) <= 1.5 }) {
          columnX.append(group.x)
        }
      }
      columnX.sort()
      guard columnX.count >= profile.minimumColumns + 1 else { return nil }

      let rowCount = rowY.count - 1
      let columnCount = columnX.count - 1
      let entries = lineEntries(candidates: candidates, layout: layout)
      var cells: [ExtractedTable.Cell] = []
      var emptySlots = 0
      for row in 0..<rowCount {
        let top = rowY[row]
        let bottom = rowY[row + 1]
        for column in 0..<columnCount {
          let left = columnX[column]
          let right = columnX[column + 1]
          let slot = [left, bottom, right, top]
          let inside = entries.filter { entry in
            let center = [
              (entry.bounds[0] + entry.bounds[2]) / 2,
              (entry.bounds[1] + entry.bounds[3]) / 2,
            ]
            return center[0] >= slot[0] - 1 && center[0] <= slot[2] + 1
              && center[1] >= slot[1] - 1 && center[1] <= slot[3] + 1
          }
          // P36-008: recognized lines in the slot are the cell's text source
          // (with their provenance and confidence) when present.
          let insideLines = recognizedLines.filter { line in
            let center = [(line.rect[0] + line.rect[2]) / 2, (line.rect[1] + line.rect[3]) / 2]
            return center[0] >= slot[0] - 1 && center[0] <= slot[2] + 1
              && center[1] >= slot[1] - 1 && center[1] <= slot[3] + 1
          }
          guard !inside.isEmpty || !insideLines.isEmpty else {
            emptySlots += 1
            continue
          }
          let text =
            insideLines.isEmpty
            ? inside.map(\.text).joined(separator: "\n")
            : insideLines.sorted { $0.rect[3] > $1.rect[3] }.map(\.text).joined(separator: "\n")
          let bounds =
            insideLines.isEmpty
            ? unionBounds(inside.map(\.bounds)) : unionBounds(insideLines.map(\.rect))
          let provenance: ExtractedTable.Provenance = insideLines.isEmpty ? .text : .ocr
          let rawConfidence =
            insideLines.compactMap(\.confidence).min() ?? inside.map(\.confidence).min() ?? 0.7
          // Recognition confidence is preserved; heuristic text confidence is
          // capped at the ruled-detection ceiling.
          let confidence = provenance == .ocr ? rawConfidence : min(0.85, rawConfidence)
          cells.append(
            ExtractedTable.Cell(
              row: row, column: column, text: text, bounds: bounds, provenance: provenance,
              confidence: confidence))
        }
      }
      guard !cells.isEmpty else { return nil }
      // Merge spans: a cell whose bounds cover neighbouring boundaries.
      cells = inferSpans(
        cells, rowY: rowY, columnX: columnX, rowCount: rowCount, columnCount: columnCount)
      // A slot that stays empty is explained by the nearest filled cell to its
      // left (horizontal merge) or above (vertical merge) when that cell's
      // content reaches into the slot.
      cells = mergeEmptySlots(
        cells, rowY: rowY, columnX: columnX, rowCount: rowCount, columnCount: columnCount)
      // Slots explained by a span are not "empty"; only uncovered slots are.
      emptySlots = emptySlotCount(
        cells, rowCount: rowCount, columnCount: columnCount)
      var confidence = 0.85 - 0.05 * Double(emptySlots)
      var limitations: [String] = []
      if cells.contains(where: { $0.rowSpan > 1 || $0.columnSpan > 1 }) {
        limitations.append("Merged cells inferred from missing internal rules.")
        confidence -= 0.1
      }
      if emptySlots > 0 {
        limitations.append(
          "\(emptySlots) empty slot\(emptySlots == 1 ? "" : "s") inside the ruled grid.")
      }
      confidence = max(0.4, min(0.9, confidence))
      if confidence < profile.confidenceGate {
        limitations.append("Low-confidence detection; review before export.")
      }
      return ExtractedTable(
        pageIndex: pageIndex, detection: .ruled,
        bounds: [minimumX, minimumY, maximumX, maximumY], rowCount: rowCount,
        columnCount: columnCount, cells: cells, confidence: confidence,
        limitations: limitations)
  }

  // MARK: - Geometry tables (P36-003–P36-006)

  static func geometryTable(
    pageIndex: Int, candidates: [TextParagraphCandidate], profile: TableDetectionProfile
  ) -> ExtractedTable? {
    let cells = candidates.filter { $0.kind == .tableCell }
    guard cells.count >= profile.minimumCellCount else { return nil }
    let grid = TableCellReconstruction.grid(from: candidates)
    guard grid.columnCount >= profile.minimumColumns, grid.rowCount >= profile.minimumRows
    else { return nil }

    // P36-006: a two-column grid of multi-line, wordy cells is multi-column
    // prose, not a table (no rules confirmed it above).
    if grid.columnCount == 2 {
      let multiLine = grid.cells.filter { $0.lineIndices.count >= 2 }.count
      let words = grid.cells.map { $0.text.split(separator: " ").count }
      let averageWords = words.reduce(0, +) / max(words.count, 1)
      if multiLine * 2 >= grid.cells.count, averageWords >= 6 { return nil }
    }

    let columnCenters = centers(
      count: grid.columnCount, indices: grid.columnIndices,
      bounds: grid.cells.map { ($0.bounds[0], $0.bounds[2]) })
    let rowCenters = centers(
      count: grid.rowCount, indices: grid.rowIndices,
      bounds: grid.cells.map { ($0.bounds[1], $0.bounds[3]) })

    var tableCells: [ExtractedTable.Cell] = []
    for (offset, candidate) in grid.cells.enumerated() {
      let row = grid.rowIndices[offset]
      let column = grid.columnIndices[offset]
      let columnSpan = max(
        1, min(grid.columnCount - column, columnCenters.filter {
          $0 >= candidate.bounds[0] - 1 && $0 <= candidate.bounds[2] + 1
        }.count))
      let rowSpan = max(
        1, min(grid.rowCount - row, rowCenters.filter {
          $0 >= candidate.bounds[1] - 1 && $0 <= candidate.bounds[3] + 1
        }.count))
      let provenance = ExtractedTable.Provenance.text
      tableCells.append(
        ExtractedTable.Cell(
          row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan,
          text: candidate.text, bounds: candidate.bounds, provenance: provenance,
          confidence: candidate.confidence))
    }
    guard !tableCells.isEmpty else { return nil }

    var confidence = 0.7
    var limitations: [String] = []
    if grid.rowCount >= 2, grid.columnCount >= 2 { confidence += 0.1 }
    if tableCells.contains(where: { $0.rowSpan > 1 || $0.columnSpan > 1 }) {
      limitations.append("Merged cells inferred from geometry.")
      confidence -= 0.1
    }
    confidence = max(0.3, min(0.85, confidence))
    if confidence < profile.confidenceGate {
      limitations.append("Low-confidence detection; review before export.")
    }
    return ExtractedTable(
      pageIndex: pageIndex, detection: .geometry,
      bounds: unionBounds(grid.cells.map(\.bounds)), rowCount: grid.rowCount,
      columnCount: grid.columnCount, cells: tableCells, confidence: confidence,
      limitations: limitations)
  }

  /// P36-008: cells overlapping a recognized line take its text and carry
  /// `.ocr` provenance with the recognition confidence.
  static func applyingRecognizedLines(
    _ cells: [ExtractedTable.Cell], lines: [SearchableTextLine]
  ) -> [ExtractedTable.Cell] {
    cells.map { cell in
      let matching = lines.filter { overlapRatio(cell.bounds, $0.rect) >= 0.5 }
      guard !matching.isEmpty else { return cell }
      let text = matching.sorted { $0.rect[3] > $1.rect[3] }.map(\.text).joined(separator: "\n")
      let confidence = matching.compactMap(\.confidence).min() ?? cell.confidence
      return ExtractedTable.Cell(
        row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
        columnSpan: cell.columnSpan, text: text, bounds: cell.bounds, provenance: .ocr,
        confidence: min(cell.confidence, confidence))
    }
  }

  /// Fill empty slots from the nearest filled neighbour whose content reaches
  /// into them (merged cells in ruled grids, P36-005).
  static func mergeEmptySlots(
    _ cells: [ExtractedTable.Cell], rowY: [Double], columnX: [Double], rowCount: Int,
    columnCount: Int
  ) -> [ExtractedTable.Cell] {
    var result = cells
    var covered = coverage(result, rowCount: rowCount, columnCount: columnCount)
    for row in 0..<rowCount {
      for column in 0..<columnCount where !covered[row][column] {
        let slotLeft = columnX[column]
        let slotRight = columnX[column + 1]
        let slotBottom = rowY[row + 1]
        let slotTop = rowY[row]
        if let index = result.firstIndex(where: {
          $0.row == row && $0.column < column && $0.rowSpan == 1
            && $0.column + $0.columnSpan == column
        }), result[index].bounds[2] >= slotLeft + 8 {
          let cell = result[index]
          result[index] = ExtractedTable.Cell(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan,
            columnSpan: cell.columnSpan + 1, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence)
          covered = coverage(result, rowCount: rowCount, columnCount: columnCount)
          continue
        }
        if let index = result.firstIndex(where: {
          $0.column == column && $0.row < row && $0.columnSpan == 1
            && $0.row + $0.rowSpan == row
        }), result[index].bounds[1] <= slotTop - 8 {
          let cell = result[index]
          result[index] = ExtractedTable.Cell(
            row: cell.row, column: cell.column, rowSpan: cell.rowSpan + 1,
            columnSpan: cell.columnSpan, text: cell.text, bounds: cell.bounds,
            provenance: cell.provenance, confidence: cell.confidence)
          covered = coverage(result, rowCount: rowCount, columnCount: columnCount)
        }
      }
    }
    return result
  }

  static func coverage(
    _ cells: [ExtractedTable.Cell], rowCount: Int, columnCount: Int
  ) -> [[Bool]] {
    var covered = Array(
      repeating: Array(repeating: false, count: columnCount), count: rowCount)
    for cell in cells {
      for row in cell.row..<min(cell.row + cell.rowSpan, rowCount) {
        for column in cell.column..<min(cell.column + cell.columnSpan, columnCount) {
          covered[row][column] = true
        }
      }
    }
    return covered
  }

  static func emptySlotCount(
    _ cells: [ExtractedTable.Cell], rowCount: Int, columnCount: Int
  ) -> Int {
    coverage(cells, rowCount: rowCount, columnCount: columnCount)
      .flatMap { $0 }.filter { !$0 }.count
  }

  /// Span inference: how many row/column centers a cell's bounds cover.
  static func inferSpans(
    _ cells: [ExtractedTable.Cell], rowY: [Double], columnX: [Double], rowCount: Int,
    columnCount: Int
  ) -> [ExtractedTable.Cell] {
    cells.map { cell in
      let columnSpan = max(
        1,
        min(
          columnCount - cell.column,
          columnX.filter { $0 >= cell.bounds[0] - 1 && $0 <= cell.bounds[2] + 1 }.count))
      let rowSpan = max(
        1,
        min(
          rowCount - cell.row,
          rowY.filter { $0 >= cell.bounds[1] - 1 && $0 <= cell.bounds[3] + 1 }.count))
      return ExtractedTable.Cell(
        row: cell.row, column: cell.column, rowSpan: rowSpan, columnSpan: columnSpan,
        text: cell.text, bounds: cell.bounds, provenance: cell.provenance,
        confidence: cell.confidence)
    }
  }

  // MARK: - Helpers

  static func centers(
    count: Int, indices: [Int], bounds: [(Double, Double)]
  ) -> [Double] {
    (0..<count).map { column in
      let values = indices.enumerated().filter { $0.element == column }.map { bounds[$0.offset] }
      let low = values.map(\.0).min() ?? 0
      let high = values.map(\.1).max() ?? 0
      return (low + high) / 2
    }
  }

  static func unionBounds(_ boxes: [[Double]]) -> [Double] {
    guard var result = boxes.first else { return [0, 0, 0, 0] }
    for box in boxes.dropFirst() {
      result = [
        min(result[0], box[0]), min(result[1], box[1]), max(result[2], box[2]),
        max(result[3], box[3]),
      ]
    }
    return result
  }

  static func overlapRatio(_ left: [Double], _ right: [Double]) -> Double {
    let width = min(left[2], right[2]) - max(left[0], right[0])
    let height = min(left[3], right[3]) - max(left[1], right[1])
    guard width > 0, height > 0 else { return 0 }
    let intersection = width * height
    let smaller = min(
      (left[2] - left[0]) * (left[3] - left[1]),
      (right[2] - right[0]) * (right[3] - right[1]))
    guard smaller > 0 else { return 0 }
    return intersection / smaller
  }

  static func numbers(_ operands: [ContentOperand]) -> [Double]? {
    var result: [Double] = []
    for operand in operands {
      switch operand.value {
      case .integer(let value): result.append(Double(value))
      case .real(let value): result.append(value)
      default: return nil
      }
    }
    return result
  }
}
