import Foundation
import PDFCore

/// P19-020: list reconstruction. Consecutive candidates whose text starts with
/// a bullet or numbering marker form a list; numbering is editable because the
/// marker is parsed and can be regenerated.
public struct ParagraphListStyle: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case bullet
    case ordered
  }

  public enum NumberFormat: String, Sendable, Equatable {
    case arabic
    case lowerAlpha
    case upperAlpha
    case lowerRoman
    case upperRoman
  }

  public let kind: Kind
  /// The bullet character for `.bullet`.
  public let bullet: String?
  public let format: NumberFormat?
  /// The separator after an ordered marker (`.`, `)`, or `:`).
  public let separator: String?
  public let start: Int

  public init(
    kind: Kind, bullet: String? = nil, format: NumberFormat? = nil,
    separator: String? = ".", start: Int = 1
  ) {
    self.kind = kind
    self.bullet = bullet
    self.format = format
    self.separator = separator
    self.start = start
  }

  /// The marker text for item `index` (0-based).
  public func marker(for index: Int) -> String {
    switch kind {
    case .bullet:
      return bullet ?? "•"
    case .ordered:
      let value = start + index
      switch format ?? .arabic {
      case .arabic: return "\(value)"
      case .lowerAlpha: return Self.alpha(value, upper: false)
      case .upperAlpha: return Self.alpha(value, upper: true)
      case .lowerRoman: return Self.roman(value).lowercased()
      case .upperRoman: return Self.roman(value)
      }
    }
  }

  static func alpha(_ value: Int, upper: Bool) -> String {
    var number = max(1, value)
    var result = ""
    while number > 0 {
      let remainder = (number - 1) % 26
      let scalar = UnicodeScalar((upper ? 65 : 97) + remainder)!
      result = String(scalar) + result
      number = (number - 1) / 26
    }
    return result
  }

  static func roman(_ value: Int) -> String {
    let numerals: [(Int, String)] = [
      (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    var number = max(1, min(value, 3_999))
    var result = ""
    for (amount, numeral) in numerals {
      while number >= amount {
        result += numeral
        number -= amount
      }
    }
    return result
  }
}

public struct TextListCandidate: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public let candidate: TextParagraphCandidate
    /// The item text without its marker.
    public let text: String
    public let marker: String

    public init(candidate: TextParagraphCandidate, text: String, marker: String) {
      self.candidate = candidate
      self.text = text
      self.marker = marker
    }
  }

  public let style: ParagraphListStyle
  public let items: [Item]

  /// P19-020: the item texts with regenerated markers, ready for reflow.
  public func renumbered(_ style: ParagraphListStyle? = nil) -> [String] {
    let effective = style ?? self.style
    return items.enumerated().map { index, item in
      "\(effective.marker(for: index))\(effective.kind == .ordered ? (effective.separator ?? ".") : "") \(item.text)"
    }
  }
}

public enum ParagraphListReconstruction {
  /// Parse a leading bullet or numbering marker from a line.
  public static func marker(in text: String) -> (marker: String, rest: String, style: ParagraphListStyle)?
  {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let bullets = ["•", "‣", "◦", "-", "–", "—", "*", "·"]
    for bullet in bullets where trimmed.hasPrefix(bullet + " ") {
      return (
        bullet, String(trimmed.dropFirst(bullet.count + 1)),
        ParagraphListStyle(kind: .bullet, bullet: bullet)
      )
    }
    let separators = [".", ")", ":"]
    let tokens = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard tokens.count == 2 else { return nil }
    let token = String(tokens[0])
    guard let last = token.last, separators.contains(String(last)) else { return nil }
    let numberPart = String(token.dropLast())
    guard !numberPart.isEmpty else { return nil }
    let separator = String(last)
    if let value = Int(numberPart) {
      return (
        token, String(tokens[1]),
        ParagraphListStyle(kind: .ordered, format: .arabic, separator: separator, start: value)
      )
    }
    if numberPart.count <= 4, numberPart.allSatisfy({ $0.isLetter }) {
      let lower = numberPart.lowercased()
      let isRoman = lower.allSatisfy { "ivxlcdm".contains($0) }
      let isAlpha = numberPart.count == 1 && numberPart.first!.isLetter
      guard isRoman || isAlpha else { return nil }
      let format: ParagraphListStyle.NumberFormat = isAlpha
        ? (numberPart.first!.isUppercase ? .upperAlpha : .lowerAlpha)
        : (numberPart == numberPart.uppercased() ? .upperRoman : .lowerRoman)
      let value = isAlpha
        ? Int(numberPart.lowercased().unicodeScalars.first!.value - 96)
        : romanValue(lower)
      return (
        token, String(tokens[1]),
        ParagraphListStyle(
          kind: .ordered, format: format, separator: separator, start: max(1, value))
      )
    }
    return nil
  }

  static func romanValue(_ text: String) -> Int {
    let values: [Character: Int] = [
      "i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000,
    ]
    var total = 0
    var previous = 0
    for character in text.reversed() {
      let value = values[character] ?? 0
      if value < previous {
        total -= value
      } else {
        total += value
        previous = value
      }
    }
    return total
  }

  /// P19-020: split candidates whose every line carries a marker into one
  /// candidate per item, so numbering stays editable per item.
  public static func itemCandidates(
    from candidates: [TextParagraphCandidate]
  ) -> [TextParagraphCandidate] {
    var result: [TextParagraphCandidate] = []
    for candidate in candidates {
      let lines = candidate.text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      let allMarked = lines.count > 1 && lines.allSatisfy { marker(in: $0) != nil }
      guard allMarked else {
        result.append(candidate)
        continue
      }
      for (index, line) in lines.enumerated() {
        guard index < candidate.lineIndices.count,
          index < candidate.lineRunIndices.count
        else { continue }
        let lineRuns = candidate.lineRunIndices[index]
        let styles = lineRuns.compactMap { run -> ParagraphStyle? in
          guard let position = candidate.runIndices.firstIndex(of: run),
            candidate.runStyles.indices.contains(position)
          else { return nil }
          return candidate.runStyles[position]
        }
        let spacing = candidate.lineSpacing
        let top = candidate.bounds[3] - Double(index) * spacing
        result.append(
          TextParagraphCandidate(
            kind: .label, lineIndices: [candidate.lineIndices[index]],
            runIndices: lineRuns, lineRunIndices: [lineRuns],
            runStyles: styles.isEmpty ? candidate.runStyles : styles,
            clusterRange: candidate.clusterRange, text: line,
            bounds: [candidate.bounds[0], top - spacing, candidate.bounds[2], top],
            fontSize: candidate.fontSize, alignment: candidate.alignment,
            firstLineIndent: 0, lineSpacing: spacing,
            confidence: min(0.5, candidate.confidence),
            structureRole: candidate.structureRole))
      }
    }
    return result
  }

  /// Group consecutive marked candidates into lists.
  public static func lists(from candidates: [TextParagraphCandidate]) -> [TextListCandidate] {
    var result: [TextListCandidate] = []
    var current: [TextListCandidate.Item] = []
    var currentStyle: ParagraphListStyle?
    func flush() {
      guard let style = currentStyle, current.count >= 1 else {
        current = []
        currentStyle = nil
        return
      }
      result.append(TextListCandidate(style: style, items: current))
      current = []
      currentStyle = nil
    }
    for candidate in itemCandidates(from: candidates) {
      guard let parsed = marker(in: candidate.text) else {
        flush()
        continue
      }
      if let style = currentStyle {
        let sameKind = style.kind == parsed.style.kind
        let sameFormat =
          style.kind == .bullet || style.format == parsed.style.format
        let similarIndent = abs((current.last?.candidate.bounds[0] ?? 0) - candidate.bounds[0])
          <= 12
        let previousBottom = current.last?.candidate.bounds[1] ?? candidate.bounds[1]
        let verticalGap = previousBottom - candidate.bounds[3]
        let maximumGap = max(
          12,
          1.8 * max(
            current.last?.candidate.lineSpacing ?? candidate.lineSpacing,
            candidate.lineSpacing))
        guard sameKind, sameFormat, similarIndent, verticalGap <= maximumGap else {
          flush()
          // Reconsider this candidate as the start of a new list below.
          if let parsed = marker(in: candidate.text) {
            currentStyle = parsed.style
            current = [TextListCandidate.Item(
              candidate: candidate, text: parsed.rest, marker: parsed.marker)]
          }
          continue
        }
      }
      if currentStyle == nil { currentStyle = parsed.style }
      current.append(
        TextListCandidate.Item(candidate: candidate, text: parsed.rest, marker: parsed.marker))
    }
    flush()
    return result
  }
}

/// P19-021: table-cell text editing support. Cells are the narrow multi-line
/// blocks the analysis already classifies, grouped into rows and columns so a
/// single cell can be edited without treating the table as one paragraph.
public struct TableGrid: Sendable, Equatable {
  public let cells: [TextParagraphCandidate]
  /// Parallel to `cells`: the row and column index of each cell.
  public let rowIndices: [Int]
  public let columnIndices: [Int]

  public var rowCount: Int { (rowIndices.max() ?? -1) + 1 }
  public var columnCount: Int { (columnIndices.max() ?? -1) + 1 }

  public func cell(row: Int, column: Int) -> TextParagraphCandidate? {
    guard let index = cells.indices.first(where: {
      rowIndices[$0] == row && columnIndices[$0] == column
    }) else { return nil }
    return cells[index]
  }
}

public enum TableCellReconstruction {
  /// Group table-cell-shaped candidates into a row/column grid.
  public static func grid(from candidates: [TextParagraphCandidate]) -> TableGrid {
    let cells = candidates.filter { $0.kind == .tableCell }
    guard !cells.isEmpty else { return TableGrid(cells: [], rowIndices: [], columnIndices: []) }
    // Columns: cluster by left edge (within 12 pt).
    var columnCenters: [Double] = []
    var columnIndices: [Int] = []
    for cell in cells {
      let left = cell.bounds[0]
      if let index = columnCenters.firstIndex(where: { abs($0 - left) <= 12 }) {
        columnIndices.append(index)
      } else {
        columnCenters.append(left)
        columnIndices.append(columnCenters.count - 1)
      }
    }
    // Rows: cluster by vertical center (within 8 pt), ordered top to bottom.
    let centers = cells.map { ($0.bounds[1] + $0.bounds[3]) / 2 }
    var rowCenters: [Double] = []
    var rowIndices = Array(repeating: 0, count: cells.count)
    for (index, center) in centers.enumerated() {
      if let row = rowCenters.firstIndex(where: { abs($0 - center) <= 8 }) {
        rowIndices[index] = row
      } else {
        rowCenters.append(center)
        rowIndices[index] = rowCenters.count - 1
      }
    }
    // Normalize row order top to bottom.
    let order = rowCenters.indices.sorted { rowCenters[$0] > rowCenters[$1] }
    var normalized = Array(repeating: 0, count: rowCenters.count)
    for (rank, row) in order.enumerated() { normalized[row] = rank }
    return TableGrid(
      cells: cells, rowIndices: rowIndices.map { normalized[$0] }, columnIndices: columnIndices)
  }
}

/// P19-022: manual grouping and splitting overrides for ambiguous detection.
public struct ParagraphGrouping: Sendable, Equatable {
  /// Run-index sets to merge into one paragraph.
  public var merges: [Set<Int>]
  /// Run index -> line index to split at (the line and later start the new
  /// paragraph).
  public var splits: [Int: Int]

  public init(merges: [Set<Int>] = [], splits: [Int: Int] = [:]) {
    self.merges = merges
    self.splits = splits
  }
}

extension ParagraphReconstruction {
  /// P19-022: apply manual grouping/splitting overrides to the analysis.
  public static func candidates(
    pageID: PDFObjectID, in graph: PDFGraph, grouping: ParagraphGrouping,
    limits: Limits = Limits()
  ) throws -> [TextParagraphCandidate] {
    var result = try candidates(pageID: pageID, in: graph, limits: limits)
    // Merges: candidates sharing any run index with a group join it.
    for group in grouping.merges {
      let matching = result.filter { !$0.runIndices.filter(group.contains).isEmpty }
      guard matching.count >= 2 else { continue }
      result.removeAll { matching.contains($0) }
      let ordered = matching.sorted { $0.bounds[3] > $1.bounds[3] }
      var bounds = ordered[0].bounds
      var lineIndices: [Int] = []
      var runIndices: [Int] = []
      var lineRuns: [[Int]] = []
      var styles: [ParagraphStyle] = []
      var clusterRange = ordered[0].clusterRange
      for candidate in ordered {
        bounds[0] = min(bounds[0], candidate.bounds[0])
        bounds[1] = min(bounds[1], candidate.bounds[1])
        bounds[2] = max(bounds[2], candidate.bounds[2])
        bounds[3] = max(bounds[3], candidate.bounds[3])
        lineIndices.append(contentsOf: candidate.lineIndices)
        for run in candidate.runIndices where !runIndices.contains(run) {
          let styleIndex = candidate.runIndices.firstIndex(of: run) ?? 0
          runIndices.append(run)
          if candidate.runStyles.indices.contains(styleIndex) {
            styles.append(candidate.runStyles[styleIndex])
          } else if let fallback = ordered.first?.runStyles.first {
            styles.append(fallback)
          }
        }
        lineRuns.append(contentsOf: candidate.lineRunIndices)
        clusterRange =
          min(clusterRange.lowerBound, candidate.clusterRange.lowerBound)
          ..< max(clusterRange.upperBound, candidate.clusterRange.upperBound)
      }
      let text = ordered.map(\.text).joined(separator: "\n")
      result.append(
        TextParagraphCandidate(
          kind: .flowing, lineIndices: lineIndices, runIndices: runIndices,
          lineRunIndices: lineRuns, runStyles: styles.isEmpty ? ordered[0].runStyles : styles,
          clusterRange: clusterRange, text: text, bounds: bounds,
          fontSize: ordered.map(\.fontSize).max() ?? ordered[0].fontSize,
          alignment: ordered[0].alignment, firstLineIndent: ordered[0].firstLineIndent,
          lineSpacing: ordered[0].lineSpacing,
          confidence: min(0.55, ordered.map(\.confidence).min() ?? 0.5),
          structureRole: ordered[0].structureRole))
    }
    // Splits: split the candidate containing the run at the given line offset.
    for (run, splitLine) in grouping.splits {
      guard let index = result.firstIndex(where: { $0.runIndices.contains(run) }),
        result[index].lineIndices.count > splitLine + 1, splitLine >= 1
      else { continue }
      let candidate = result[index]
      let headLineCount = splitLine
      let headLines = Array(candidate.lineIndices.prefix(headLineCount))
      let tailLines = Array(candidate.lineIndices.dropFirst(headLineCount))
      let headRuns = Array(candidate.lineRunIndices.prefix(headLineCount)).flatMap { $0 }
      let tailRuns = Array(candidate.lineRunIndices.dropFirst(headLineCount)).flatMap { $0 }
      let splitY = candidate.bounds[3] - Double(headLineCount) * candidate.lineSpacing
      let head = TextParagraphCandidate(
        kind: candidate.kind, lineIndices: headLines, runIndices: headRuns,
        lineRunIndices: Array(candidate.lineRunIndices.prefix(headLineCount)),
        runStyles: candidate.runStyles, clusterRange: candidate.clusterRange,
        text: candidate.text.split(separator: "\n").prefix(headLineCount).joined(separator: "\n"),
        bounds: [candidate.bounds[0], splitY, candidate.bounds[2], candidate.bounds[3]],
        fontSize: candidate.fontSize, alignment: candidate.alignment,
        firstLineIndent: candidate.firstLineIndent, lineSpacing: candidate.lineSpacing,
        confidence: candidate.confidence, structureRole: candidate.structureRole)
      let tail = TextParagraphCandidate(
        kind: candidate.kind, lineIndices: tailLines, runIndices: tailRuns,
        lineRunIndices: Array(candidate.lineRunIndices.dropFirst(headLineCount)),
        runStyles: candidate.runStyles, clusterRange: candidate.clusterRange,
        text: candidate.text.split(separator: "\n").dropFirst(headLineCount).joined(separator: "\n"),
        bounds: [candidate.bounds[0], candidate.bounds[1], candidate.bounds[2], splitY],
        fontSize: candidate.fontSize, alignment: candidate.alignment,
        firstLineIndent: candidate.firstLineIndent, lineSpacing: candidate.lineSpacing,
        confidence: candidate.confidence, structureRole: candidate.structureRole)
      result[index] = head
      result.append(tail)
    }
    return result.sorted {
      $0.bounds[3] == $1.bounds[3] ? $0.bounds[0] < $1.bounds[0] : $0.bounds[3] > $1.bounds[3]
    }
  }
}
