import Foundation
import PDFCore

/// P19-001–P19-006: editable paragraph candidates reconstructed from
/// source-linked text runs. Analysis is read-only and bounded; every candidate
/// carries the runs and clusters it came from plus a confidence, so nothing is
/// rewritten before the user confirms a region.
/// P19-010: the style facts of one run, so reflow can preserve inline
/// differences (font resource, size, fill color).
public struct ParagraphStyle: Sendable, Equatable {
  public let fontResource: String
  public let fontSize: Double
  public let fillColor: [Double]
  /// The font's base name (for example `Helvetica-Bold`), used for bold and
  /// italic inference.
  public let baseFont: String

  public init(
    fontResource: String, fontSize: Double, fillColor: [Double], baseFont: String = ""
  ) {
    self.fontResource = fontResource
    self.fontSize = fontSize
    self.fillColor = fillColor
    self.baseFont = baseFont
  }
}

public struct TextParagraphCandidate: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    /// Multi-line body text.
    case flowing
    /// Single line, larger than the body size (or a heading tag).
    case heading
    /// Isolated short line (a positioned label).
    case label
    /// Narrow column of lines (a table-cell-shaped region).
    case tableCell
    case unknown
  }

  public enum Alignment: String, Sendable, Equatable {
    case left
    case center
    case right
    case justified
  }

  public let kind: Kind
  public let lineIndices: [Int]
  public let runIndices: [Int]
  /// Runs per line, parallel to `lineIndices` (P19-024 source maps).
  public let lineRunIndices: [[Int]]
  /// Styles parallel to `runIndices` (P19-010).
  public let runStyles: [ParagraphStyle]
  public let clusterRange: Range<Int>
  public let text: String
  public let bounds: [Double]
  public let fontSize: Double
  public let alignment: Alignment
  public let firstLineIndent: Double
  public let lineSpacing: Double
  public let confidence: Double
  /// The structure role that confirmed this boundary, when the document is
  /// tagged (P19-002).
  public let structureRole: String?
}

public enum ParagraphReconstruction {
  public struct Limits: Sendable {
    public var maxLines: Int
    public var maxCandidates: Int

    public init(maxLines: Int = 4_000, maxCandidates: Int = 500) {
      self.maxLines = maxLines
      self.maxCandidates = maxCandidates
    }
  }

  /// P19-001/P19-002: paragraph candidates in reading order, guided by
  /// structure tags when the document has them.
  public static func candidates(
    pageID: PDFObjectID, in graph: PDFGraph, limits: Limits = Limits(),
    roles: [Int: String]? = nil
  ) throws -> [TextParagraphCandidate] {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    guard !layout.clusters.isEmpty else { return [] }
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    // P35-029: callers reconstructing many pages compute the role map once and
    // pass it in; a single call still computes it lazily.
    let roleByMCID = roles ?? structureRoles(pageID: pageID, in: graph)
    let mcidByCluster = clusterMCIDs(in: content, layout: layout, runs: runs)

    let bodySize = bodyFontSize(of: layout)
    var lineInfo: [LineInfo] = []
    for (lineIndex, range) in layout.lines.prefix(limits.maxLines).enumerated() {
      let clusters = range.map { layout.clusters[$0] }.filter { !$0.isWhitespace }
      guard !clusters.isEmpty else { continue }
      // P19-017: split a layout line at large horizontal gaps so columns that
      // share a baseline never become one paragraph.
      let indexed = range.map { (index: $0, cluster: layout.clusters[$0]) }
        .filter { !$0.cluster.isWhitespace }
      var segments: [[(index: Int, cluster: TextCluster)]] = []
      var currentSegment: [(index: Int, cluster: TextCluster)] = []
      for entry in indexed {
        if let last = currentSegment.last {
          let gap = entry.cluster.bounds[0] - last.cluster.bounds[2]
          if gap > max(30, 3 * entry.cluster.fontSize) {
            segments.append(currentSegment)
            currentSegment = []
          }
        }
        currentSegment.append(entry)
      }
      segments.append(currentSegment)
      for segment in segments where !segment.isEmpty {
        lineInfo.append(makeLineInfo(
          segment: segment, lineIndex: lineIndex, bodySize: bodySize,
          mcidByCluster: mcidByCluster))
      }
    }
    guard !lineInfo.isEmpty else { return [] }

    let pageWidth = pageWidth(of: pageID, in: graph)
    let widest = lineInfo.map { $0.bounds[2] - $0.bounds[0] }.max() ?? 1


    // Group segments into blocks by extending the best horizontally
    // overlapping block (P19-017), so columns that share baselines stay apart
    // while a column's own lines join.
    var blocks: [[LineInfo]] = []
    let ordered = lineInfo.sorted {
      $0.baseline == $1.baseline ? $0.bounds[0] < $1.bounds[0] : $0.baseline > $1.baseline
    }
    for line in ordered {
      var best: (index: Int, score: Double)?
      for (index, block) in blocks.enumerated() {
        guard let previous = block.last else { continue }
        let gap = previous.baseline - line.baseline
        guard gap >= 0, gap <= 1.8 * max(previous.maxFontSize, line.maxFontSize) else {
          continue
        }
        guard abs(previous.maxFontSize - line.maxFontSize)
          <= max(0.5, 0.15 * previous.maxFontSize)
        else { continue }
        guard previous.mcid == nil || line.mcid == nil || previous.mcid == line.mcid else {
          continue
        }
        let overlap = min(previous.bounds[2], line.bounds[2])
          - max(previous.bounds[0], line.bounds[0])
        guard overlap > 0 else { continue }
        let score = overlap - gap
        if best == nil || score > best!.score { best = (index, score) }
      }
      if let best {
        blocks[best.index].append(line)
      } else {
        blocks.append([line])
      }
    }

    var candidates: [TextParagraphCandidate] = []
    for block in blocks.prefix(limits.maxCandidates) {
      guard let first = block.first, let last = block.last else { continue }
      var bounds = first.bounds
      for line in block {
        bounds[0] = min(bounds[0], line.bounds[0])
        bounds[1] = min(bounds[1], line.bounds[1])
        bounds[2] = max(bounds[2], line.bounds[2])
        bounds[3] = max(bounds[3], line.bounds[3])
      }
      let lineRuns = block.map(\.runIndices)
      let runStyleList = unique(block.flatMap(\.runIndices)).map { runIndex -> ParagraphStyle in
        let run = runs[runIndex]
        var baseFont = ""
        if case .dictionary(let font)? = graph.objects[run.fontID],
          case .name(let name)? = font[PDFName("BaseFont")]
        {
          baseFont = String(decoding: name.bytes, as: UTF8.self)
        }
        return ParagraphStyle(
          fontResource: String(decoding: run.fontResource.bytes, as: UTF8.self),
          fontSize: run.fontSize, fillColor: run.fillColor, baseFont: baseFont)
      }
      let text = block.map { layout.text(in: $0.range) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      guard !text.isEmpty else { continue }
      let maxFont = block.map(\.maxFontSize).max() ?? bodySize
      let role = first.mcid.flatMap { roleByMCID[$0] }
      let width = bounds[2] - bounds[0]
      let kind: TextParagraphCandidate.Kind
      if let role, role.hasPrefix("H"), role != "H" {
        kind = .heading
      } else if block.count == 1, maxFont >= max(12, bodySize * 1.15) {
        kind = .heading
      } else if block.count == 1 {
        kind = width < 0.6 * widest ? .label : .flowing
      } else if width < 0.45 * max(widest, 1) {
        kind = .tableCell
      } else {
        kind = .flowing
      }
      let alignment = inferAlignment(block)
      let indent = block.count > 1
        ? max(0, first.bounds[0] - block.dropFirst().map { $0.bounds[0] }.min()!)
        : 0
      let spacing: Double
      if block.count > 1 {
        let deltas = zip(block, block.dropFirst()).map { $0.baseline - $1.baseline }
        spacing = deltas.sorted()[deltas.count / 2]
      } else {
        spacing = maxFont * 1.2
      }
      var confidence = 0.7
      switch kind {
      case .heading: confidence = role != nil ? 0.9 : 0.65
      case .flowing: confidence = block.count >= 2 ? 0.8 : 0.55
      case .label: confidence = 0.5
      case .tableCell: confidence = 0.45
      case .unknown: confidence = 0.3
      }
      if role != nil { confidence = min(0.95, confidence + 0.1) }
      candidates.append(
        TextParagraphCandidate(
          kind: kind, lineIndices: block.map(\.lineIndex),
          runIndices: unique(block.flatMap(\.runIndices)), lineRunIndices: lineRuns,
          runStyles: runStyleList,
          clusterRange: first.range.lowerBound..<last.range.upperBound, text: text,
          bounds: bounds, fontSize: maxFont, alignment: alignment, firstLineIndent: indent,
          lineSpacing: spacing, confidence: min(0.95, confidence), structureRole: role))
    }
    return candidates
  }

  private static func makeLineInfo(
    segment: [(index: Int, cluster: TextCluster)], lineIndex: Int, bodySize: Double,
    mcidByCluster: [Int: Int]
  ) -> LineInfo {
    var bounds = [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                  -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude]
    // Fonts without /Widths carry zero-width markers; estimate their advance
    // from the font size and carry a cursor so widths accumulate instead of
    // collapsing to one character.
    var cursor: Double?
    for entry in segment {
      let cluster = entry.cluster
      let estimatedWidth =
        cluster.advance
        ?? (0.5 * cluster.fontSize * Double(max(cluster.text.count, 1)))
      let start = max(cluster.bounds[0], cursor ?? cluster.bounds[0])
      let end = max(cluster.bounds[2], start + estimatedWidth)
      cursor = end
      bounds[0] = min(bounds[0], cluster.bounds[0])
      bounds[1] = min(bounds[1], cluster.bounds[1])
      bounds[2] = max(bounds[2], end)
      bounds[3] = max(bounds[3], cluster.bounds[3])
    }
    let baseline = segment.map { $0.cluster.origin[1] }.reduce(0, +) / Double(segment.count)
    let firstIndex = segment.first?.index ?? 0
    let lastIndex = segment.last?.index ?? firstIndex
    return LineInfo(
      lineIndex: lineIndex, range: firstIndex..<(lastIndex + 1), bounds: bounds,
      baseline: baseline, maxFontSize: segment.map { $0.cluster.fontSize }.max() ?? bodySize,
      runIndices: unique(segment.map { $0.cluster.runIndex }),
      mcid: mcidByCluster[firstIndex])
  }

  private struct LineInfo {
    let lineIndex: Int
    let range: Range<Int>
    let bounds: [Double]
    let baseline: Double
    let maxFontSize: Double
    let runIndices: [Int]
    let mcid: Int?
  }

  /// MCID -> structure role for a page (P19-002).
  /// P35-029: roles per page from one structure inspection, for multi-page
  /// reconstruction (the inspector walks every page, so calling it per page is
  /// quadratic).
  public static func structureRolesByPage(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> [PDFObjectID: [Int: String]] {
    guard let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs)
    else { return [:] }
    var result: [PDFObjectID: [Int: String]] = [:]
    for element in inventory.elements {
      for child in element.children {
        if case .content(let pageIndex?, let mcid) = child, pageIndex >= 0,
          pageIndex < pageIDs.count
        {
          result[pageIDs[pageIndex], default: [:]][mcid] = element.role
        }
      }
    }
    return result
  }

  static func structureRoles(pageID: PDFObjectID, in graph: PDFGraph) -> [Int: String] {
    guard let pageIDs = try? PageTreeView(graph: graph).pages,
      let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs),
      let pageIndex = pageIDs.firstIndex(of: pageID)
    else { return [:] }
    var roles: [Int: String] = [:]
    for element in inventory.elements {
      for child in element.children {
        if case .content(let childPage, let mcid) = child, childPage == pageIndex {
          roles[mcid] = element.role
        }
      }
    }
    return roles
  }

  /// Cluster start index -> MCID, from the marked-content instruction ranges.
  static func clusterMCIDs(
    in content: PageContent, layout: PageTextLayout, runs: [TextRun]
  ) -> [Int: Int] {
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
    for range in layout.lines {
      if let mcid = mcidByRun[layout.clusters[range.lowerBound].runIndex] {
        result[range.lowerBound] = mcid
      }
    }
    return result
  }

  static func bodyFontSize(of layout: PageTextLayout) -> Double {
    var counts: [Int: Int] = [:]
    for cluster in layout.clusters where !cluster.isWhitespace {
      counts[Int(cluster.fontSize.rounded()), default: 0] += 1
    }
    guard let best = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else {
      return 12
    }
    return Double(best.key)
  }

  private static func inferAlignment(_ block: [LineInfo]) -> TextParagraphCandidate.Alignment {
    guard block.count > 1 else { return .left }
    // Alignment is inferred from the continuation lines so a first-line
    // indent does not read as centered text.
    let lines = block.count > 2 ? Array(block.dropFirst()) : block
    let lefts = lines.map { $0.bounds[0] }
    let rights = lines.map { $0.bounds[2] }
    let centers = lines.map { ($0.bounds[0] + $0.bounds[2]) / 2 }
    func spread(_ values: [Double]) -> Double {
      (values.max() ?? 0) - (values.min() ?? 0)
    }
    let leftSpread = spread(lefts)
    let rightSpread = spread(rights)
    let centerSpread = spread(centers)
    if leftSpread <= 2 { return .left }
    if centerSpread <= 2, centerSpread < leftSpread { return .center }
    if rightSpread <= 2 { return .right }
    if rightSpread < leftSpread { return .justified }
    return .left
  }

  static func unique(_ values: [Int]) -> [Int] {
    var seen: Set<Int> = []
    var result: [Int] = []
    for value in values where seen.insert(value).inserted { result.append(value) }
    return result
  }

  static func pageWidth(of pageID: PDFObjectID, in graph: PDFGraph) -> Double {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return 612 }
    for key in ["CropBox", "MediaBox"] {
      if case .array(let values)? = page[PDFName(key)], values.count == 4 {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers[2] - numbers[0] }
      }
    }
    return 612
  }
}
