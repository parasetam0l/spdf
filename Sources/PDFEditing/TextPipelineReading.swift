import Foundation
import PDFCore

/// P16-005/P16-006/P16-022/P16-023/P16-024: reading order, artifact
/// filtering, duplicate-text handling, and selection-boundary certainty for
/// the owned text pipeline. All helpers are read-only over the current graph.
public enum TextReadingOrder {
  /// P16-005: paragraph candidates with confidence and source relationships.
  /// This is the P16 entry point to the shared reconstruction engine: every
  /// candidate carries its line/run/cluster sources plus a confidence, so
  /// callers can gate edits on certainty. See `ParagraphReconstruction` for
  /// the grouping policy.
  public static func paragraphCandidates(
    pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> [TextParagraphCandidate] {
    try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
  }

  /// P16-006: cluster indices in reading order. When the document is tagged
  /// and the page carries marked-content IDs mapped by the structure tree,
  /// MCID order governs (structure before geometry); otherwise the geometric
  /// layout order (column-aware) is the reading order. Returns layout indices
  /// such that `indices.map { layout.clusters[$0] }` reads in order.
  public static func orderedClusterIndices(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> [Int] {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    guard let structureOrder = structureClusterOrder(
      pageID: pageID, layout: layout, in: graph, limits: limits)
    else {
      return Array(layout.clusters.indices)
    }
    return structureOrder
  }

  /// MCID-driven order, or nil when the page is untagged (geometric order
  /// applies). Clusters whose run has no MCID keep their relative geometric
  /// position after the last tagged cluster.
  static func structureClusterOrder(
    pageID: PDFObjectID, layout: PageTextLayout, in graph: PDFGraph, limits: PDFLimits
  ) -> [Int]? {
    guard let pageIDs = try? PDFPageTree.pageIDs(in: graph),
      pageIDs.contains(pageID),
      let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs),
      inventory.rootObjectID != nil
    else { return nil }
    guard let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits),
      let runs = try? TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    else { return nil }
    let ranges = StructureTaggingAssistant.markedRanges(in: content)
    guard !ranges.isEmpty else { return nil }
    // MCID order from the structure tree for this page.
    var mcidSequence: [Int] = []
    func collect(_ child: PDFStructureChild, pageIndex: Int?) {
      switch child {
      case .content(let childPage, let mcid):
        if childPage == nil || childPage == pageIndex { mcidSequence.append(mcid) }
      case .element(let element):
        for nested in element.children { collect(nested, pageIndex: pageIndex) }
      case .objectReference, .unresolved:
        break
      }
    }
    guard let pageIndex = pageIDs.firstIndex(of: pageID) else { return nil }
    // PDFStructureInventory.elements is a flattened index that also retains
    // nested children. Walk only root children here so each MCID enters the
    // reading-order sequence once.
    for element in inventory.elements where element.parentObjectID == inventory.rootObjectID {
      for child in element.children { collect(child, pageIndex: pageIndex) }
    }
    guard !mcidSequence.isEmpty else { return nil }
    var rank: [Int: Int] = [:]
    for mcid in mcidSequence {
      // Repeated structure-tree references to one MCID make its reading order
      // ambiguous. Treat that as unavailable instead of trapping or guessing.
      guard rank[mcid] == nil else { return nil }
      rank[mcid] = rank.count
    }
    var mcidByRun: [Int: Int] = [:]
    for (index, run) in runs.enumerated() {
      for range in ranges {
        if let mcid = range.mcid, range.instructions.contains(run.instructionIndex) {
          mcidByRun[index] = mcid
          break
        }
      }
    }
    guard !mcidByRun.isEmpty else { return nil }
    // Stable sort: MCID rank first, geometric index breaks ties and orders
    // untagged clusters after tagged ones.
    return layout.clusters.indices.sorted { lhs, rhs in
      let leftMCID = mcidByRun[layout.clusters[lhs].runIndex]
      let rightMCID = mcidByRun[layout.clusters[rhs].runIndex]
      switch (leftMCID.flatMap { rank[$0] }, rightMCID.flatMap { rank[$0] }) {
      case let (left?, right?):
        return left == right ? lhs < rhs : left < right
      case (nil, nil):
        return lhs < rhs
      case (nil, _):
        return false
      case (_, nil):
        return true
      }
    }
  }
}

/// P16-022: non-content artifacts excluded from reading order when structure
/// exists. A run is artifactual when its instruction sits inside an
/// `/Artifact` marked-content span; when the document has no structure root,
/// nothing is excluded (there is no applicable structure to honor).
public enum ArtifactFiltering {
  /// Run indices drawn inside `/Artifact` marked content.
  public static func artifactRunIndices(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> Set<Int> {
    guard let pageIDs = try? PDFPageTree.pageIDs(in: graph),
      let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs),
      inventory.rootObjectID != nil
    else { return [] }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    var artifactSpans: [Range<Int>] = []
    var stack: [(start: Int, isArtifact: Bool)] = []
    for (index, instruction) in content.instructions.enumerated() {
      switch instruction.operatorName {
      case "BDC", "BMC":
        // The tag is the first operand for BMC (`/Artifact BMC`) and either
        // operand shape for BDC (`/Artifact <</Type ...>> BDC`).
        var isArtifact = false
        for operand in instruction.operands {
          if case .name(let name) = operand.value,
            String(decoding: name.bytes, as: UTF8.self) == "Artifact"
          {
            isArtifact = true
          }
        }
        stack.append((index, isArtifact))
      case "EMC":
        if let top = stack.popLast(), top.isArtifact {
          artifactSpans.append(top.start..<(index + 1))
        }
      default:
        break
      }
    }
    guard !artifactSpans.isEmpty else { return [] }
    var result: Set<Int> = []
    for (index, run) in runs.enumerated() {
      if artifactSpans.contains(where: { $0.contains(run.instructionIndex) }) {
        result.insert(index)
      }
    }
    return result
  }

  /// Layout cluster indices with artifact-run clusters removed.
  public static func contentClusterIndices(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> [Int] {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    let artifacts = try artifactRunIndices(pageID: pageID, in: graph, limits: limits)
    guard !artifacts.isEmpty else { return Array(layout.clusters.indices) }
    return layout.clusters.indices.filter { !artifacts.contains(layout.clusters[$0].runIndex) }
  }
}

/// P16-023: duplicated invisible/visible text without search duplication.
///
/// Scanned workflows paint visible text plus an invisible (rendering mode 3)
/// copy at the same position (or vice versa). Two failures follow: the same
/// baseline interleaves both copies glyph-by-glyph so a plain search misses
/// (the line reads "HHeelllloo..."), or offset copies report twice. `search`
/// fixes both: every line is searched whole, and lines mixing visible and
/// invisible runs are additionally searched through their visible-only
/// projection (mapped back to the original clusters); overlapping matches
/// with equal text then keep the visible hit. Matches at disjoint positions
/// are distinct occurrences and are never merged.
public enum DuplicateTextHandling {
  /// Run indices painted with an invisible text rendering mode (Tr 3/7).
  public static func invisibleRunIndices(
    pageID: PDFObjectID, in graph: PDFGraph,
    limits: ContentInterpreter.Limits = ContentInterpreter.Limits()
  ) throws -> Set<Int> {
    let trace = try ContentInterpreter.trace(pageID: pageID, in: graph, limits: limits)
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    var invisibleInstructions = Set<Int>()
    for draw in trace.draws where draw.kind == .text && draw.isInvisibleText {
      invisibleInstructions.insert(draw.instructionIndex)
    }
    guard !invisibleInstructions.isEmpty else { return [] }
    return Set(
      runs.indices.filter { invisibleInstructions.contains(runs[$0].instructionIndex) })
  }

  public static func deduplicated(
    _ matches: [TextMatch], in layout: PageTextLayout, invisibleRuns: Set<Int>
  ) -> [TextMatch] {    var kept: [TextMatch] = []
    for match in matches {
      let text = layout.text(in: match.clusterRange)
        .precomposedStringWithCanonicalMapping
        .lowercased()
      let isInvisible = match.clusterRange.allSatisfy { index in
        index < layout.clusters.count && invisibleRuns.contains(layout.clusters[index].runIndex)
      }
      var absorbed = false
      for existing in kept {
        let existingText = layout.text(in: existing.clusterRange)
          .precomposedStringWithCanonicalMapping
          .lowercased()
        guard existingText == text, existing.lineIndex == match.lineIndex,
          overlaps(existing.bounds, match.bounds)
        else { continue }
        let existingInvisible = existing.clusterRange.allSatisfy { index in
          index < layout.clusters.count && invisibleRuns.contains(layout.clusters[index].runIndex)
        }
        if isInvisible, !existingInvisible {
          absorbed = true
          break
        }
        if !isInvisible, existingInvisible {
          // Visible match displaces the invisible duplicate already kept.
          kept.removeAll { $0 == existing }
          break
        }
        absorbed = true
        break
      }
      if !absorbed { kept.append(match) }
    }
    return kept
  }

  /// Search with invisible-duplicate handling: whole-line matches plus
  /// visible-projection matches for mixed lines, deduplicated so an
  /// invisible shadow never doubles (or garbles away) a visible hit.
  /// A projected hit maps back to the minimal covering cluster range while
  /// its `bounds` cover only the visible copy, because interleaved exact
  /// duplicates share one line span glyph-by-glyph.
  /// Deliver `onMatch` returning false stops with the matches so far.
  @discardableResult
  public static func search(
    query: String, in layout: PageTextLayout, invisibleRuns: Set<Int>,
    options: TextSearchOptions = TextSearchOptions(),
    onMatch: ((TextMatch) -> Bool)? = nil
  ) -> [TextMatch] {
    var collected = TextSearch.search(query: query, in: layout, options: options)
    for (lineIndex, line) in layout.lines.enumerated() {
      if Task.isCancelled { break }
      let visible = line.filter { !invisibleRuns.contains(layout.clusters[$0].runIndex) }
      guard visible.count != line.count, !visible.isEmpty else { continue }
      guard let projection = visibleProjection(
        visible: visible, pageID: layout.pageID, layout: layout)
      else { continue }
      for match in TextSearch.search(query: query, in: projection.layout, options: options) {
        if Task.isCancelled { break }
        let first = projection.map[match.clusterRange.lowerBound]
        let last = projection.map[match.clusterRange.upperBound - 1]
        // Bounds cover the visible copy only; the range is the minimal
        // cover (exact duplicates interleave, so no contiguous range holds
        // only the visible glyphs).
        let visibleBounds = match.clusterRange.map { projection.layout.clusters[$0].bounds }
        collected.append(
          TextMatch(
            clusterRange: min(first, last)..<(max(first, last) + 1), lineIndex: lineIndex,
            bounds: visibleBounds))
      }
    }
    let merged = deduplicated(collected, in: layout, invisibleRuns: invisibleRuns)
    guard let onMatch else { return merged }
    var delivered: [TextMatch] = []
    for match in merged {
      delivered.append(match)
      if onMatch(match) == false { break }
    }
    return delivered
  }

  struct Projection {
    let layout: PageTextLayout
    /// Projected cluster index to original cluster index.
    let map: [Int]
  }

  /// The visible-only subsequence of one line as a searchable layout, with
  /// words remapped to maximal contiguous projected runs.
  static func visibleProjection(
    visible: [Int], pageID: PDFObjectID, layout: PageTextLayout
  ) -> Projection? {
    guard !visible.isEmpty else { return nil }
    let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1, $0) })
    var words: [Range<Int>] = []
    for word in layout.words {
      var run: [Int] = []
      func flush() {
        if let first = run.first, let last = run.last { words.append(first..<(last + 1)) }
        run = []
      }
      // Projected indices in ascending order keep contiguity meaningful.
      for projected in word.compactMap({ positions[$0] }).sorted() {
        if let last = run.last, projected == last + 1 {
          run.append(projected)
        } else {
          flush()
          run = [projected]
        }
      }
      flush()
    }
    let projected = PageTextLayout(
      pageID: pageID, clusters: visible.map { layout.clusters[$0] },
      lines: [0..<visible.count], words: words)
    return Projection(layout: projected, map: visible)
  }

  private static func overlaps(_ left: [[Double]], _ right: [[Double]]) -> Bool {    func union(_ bounds: [[Double]]) -> [Double]? {
      guard !bounds.isEmpty else { return nil }
      let xs = bounds.flatMap { [$0[0], $0[2]] }
      let ys = bounds.flatMap { [$0[1], $0[3]] }
      return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
    }
    guard let left = union(left), let right = union(right) else { return false }
    return left[0] < right[2] && right[0] < left[2] && left[1] < right[3] && right[1] < left[3]
  }
}

/// P16-024: uncertain selection boundaries surfaced before unsupported edits.
///
/// A selection edge is certain when both boundary clusters come from decodable
/// supported runs with real metrics. It is uncertain — and the reasons name
/// why — when an edge touches a combining mark, a zero-width (metrics-less)
/// cluster, an invisible duplicate, an artifact run, or a gap left by an
/// undecodable (skipped) run between two selected runs.
public struct SelectionBoundaryAssessment: Sendable, Equatable {
  public let isCertain: Bool
  public let reasons: [String]

  public init(isCertain: Bool, reasons: [String]) {
    self.isCertain = isCertain
    self.reasons = reasons
  }
}

public enum SelectionUncertainty {
  static func assess(
    range: Range<Int>, layout: PageTextLayout, runs: [TextRun], in graph: PDFGraph,
    pageID: PDFObjectID, invisibleRuns: Set<Int> = [], artifactRuns: Set<Int> = []
  ) -> SelectionBoundaryAssessment {
    guard !range.isEmpty, range.lowerBound >= 0,
      range.upperBound <= layout.clusters.count
    else {
      return SelectionBoundaryAssessment(
        isCertain: false, reasons: ["The selection is empty or outside the page text"])
    }
    var reasons: [String] = []
    let edges = [range.lowerBound, range.upperBound - 1]
    for edge in edges {
      let cluster = layout.clusters[edge]
      if cluster.isCombiningMark {
        reasons.append("The selection edge touches a combining mark kept with its base character")
      }
      if cluster.advance == nil {
        reasons.append("The selection edge has no width data; its boundary is estimated")
      }
      if invisibleRuns.contains(cluster.runIndex) {
        reasons.append("The selection edge touches invisible duplicate text")
      }
      if artifactRuns.contains(cluster.runIndex) {
        reasons.append("The selection edge touches non-content artifact text")
      }
    }
    // A gap in run indices means undecodable runs were skipped mid-selection.
    let runIndices = range.map { layout.clusters[$0].runIndex }
    if let minRun = runIndices.min(), let maxRun = runIndices.max(),
      maxRun - minRun + 1 != Set(runIndices).count
    {
      _ = minRun
      reasons.append("Unsupported text inside the selection is skipped; the boundary is approximate")
    }
    // Combining sequences must not be split: an edge inside base+mark warns.
    for edge in [range.lowerBound, range.upperBound] where edge > 0 && edge < layout.clusters.count {
      let before = layout.clusters[edge - 1]
      let after = layout.clusters[edge]
      if after.isCombiningMark, before.runIndex == after.runIndex {
        reasons.append("The selection splits a base character from its combining mark")
        break
      }
    }
    _ = runs
    _ = graph
    _ = pageID
    var seen: [String] = []
    for reason in reasons where !seen.contains(reason) { seen.append(reason) }
    return SelectionBoundaryAssessment(isCertain: seen.isEmpty, reasons: seen)
  }
}
