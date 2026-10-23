import Foundation
import PDFCore

/// P16-001/P14-016: one glyph in reading order, decoded with its run's font
/// and carrying its source run/glyph indices plus axis-aligned bounds
/// (the conservative size estimate, extended by the embedded program's ink
/// box when one is available). Page-content graphics transforms are
/// composed; nested-form transforms and page rotation remain separate.
public struct TextCluster: Sendable, Equatable {
  public let runIndex: Int
  public let glyphIndex: Int
  public let text: String
  public let code: UInt8?
  public let origin: [Double]
  public let advance: Double?
  public let fontSize: Double
  public let bounds: [Double]

  public var isWhitespace: Bool { !text.isEmpty && text.allSatisfy { $0.isWhitespace } }

  /// P14-018: true when the cluster's text begins with a combining mark, so
  /// ordering and word grouping can keep it with its base character.
  public var isCombiningMark: Bool {
    guard let first = text.unicodeScalars.first else { return false }
    return CharacterSet.nonBaseCharacters.contains(first)
  }
}

/// P16-003/P16-004: line and word structure over a page's clusters, built
/// from baselines and inter-glyph gaps (not only literal spaces).
public struct PageTextLayout: Sendable {
  public let pageID: PDFObjectID
  public let clusters: [TextCluster]
  public let lines: [Range<Int>]
  public let words: [Range<Int>]

  /// Public entry point: build the layout for a page in a graph.
  public static func build(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PageTextLayout {
    try build(
      in: PageContent.load(pageID: pageID, in: graph, limits: limits), graph: graph,
      limits: limits)
  }

  /// Paragraph editing needs verified Standard-14 metrics to recover source
  /// positions after its own tagged per-glyph rewrites. General layout keeps
  /// the conservative missing-width behavior of the public entry point.
  static func buildForParagraphEditing(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PageTextLayout {
    try build(
      in: PageContent.load(pageID: pageID, in: graph, limits: limits), graph: graph,
      limits: limits, allowStandard14MetricFallback: true)
  }

  static func build(
    in content: PageContent, graph: PDFGraph, limits: PDFLimits = PDFLimits(),
    resources: [PDFName: PDFValue]? = nil, allowStandard14MetricFallback: Bool = false
  ) throws -> PageTextLayout {
    guard case .dictionary(let page)? = graph.objects[content.pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let effectivePage: [PDFName: PDFValue]
    if let resources {
      // P18-017: form-local layout resolves fonts against the form's own
      // resources; bounds stay in the form's coordinate space.
      effectivePage = [PDFName("Resources"): .dictionary(resources)]
    } else {
      effectivePage = page
    }
    let runs = try TextRunIndexer.runs(
      in: content, graph: graph, limits: limits, resources: resources,
      allowStandard14MetricFallback: allowStandard14MetricFallback)
    // P14-016: parse each embedded program once per build; misses are
    // cached too so a missing program is not re-resolved per glyph.
    var metricsCache: [PDFObjectID: TrueTypeOutlineMetrics?] = [:]
    var fonts: [PDFName: IndexedTextFont] = [:]
    var glyphs: [TextCluster] = []
    for (runIndex, run) in runs.enumerated() {
      let matrix = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      if fonts[run.fontResource] == nil {
        fonts[run.fontResource] = IndexedTextFont.resolve(resource: run.fontResource, page: effectivePage, in: graph)
      }
      guard let font = fonts[run.fontResource],
        font.isSupported
      else { continue }
      let metrics: TrueTypeOutlineMetrics?
      if let cached = metricsCache[font.fontID] {
        metrics = cached
      } else {
        let resolved = Self.outlineMetrics(fontID: font.fontID, in: graph)
        metricsCache[font.fontID] = resolved
        metrics = resolved
      }
      var position = 0.0
      for (glyphIndex, glyph) in (font.glyphs(run.rawCodes) ?? []).enumerated() {
        let code = glyph.codes.count == 1 ? glyph.codes.first : nil
        let decoded = glyph.text
        let advance = font.advance(
          of: glyph.codes, fontSize: run.fontSize, charSpacing: run.charSpacing,
          wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale)
          ?? (allowStandard14MetricFallback
            ? font.standard14Advance(of: glyph.codes, fontSize: run.fontSize,
              charSpacing: run.charSpacing, wordSpacing: run.wordSpacing,
              horizontalScale: run.horizontalScale)
            : nil)
        let base = run.hasKnownOffset ? run.textSpaceOffset : 0
        let origin = [
          matrix[4] + (base + position) * matrix[0] + run.rise * matrix[2],
          matrix[5] + (base + position) * matrix[1] + run.rise * matrix[3],
        ]
        // The glyph's own pen position (before this glyph's advance is
        // accumulated), used for both the estimate and the ink box.
        let glyphPosition = base + position
        var bounds: [Double]
        if let advance {
          // P16-008: the text-space box (baseline start to baseline end, one
          // em high) maps through the run matrix, so rotated and scaled runs
          // get bounds that follow their real orientation instead of an
          // axis-aligned guess. The identity matrix reproduces the old
          // estimate exactly.
          bounds = Self.composedBounds(
            matrix: matrix, position: glyphPosition, advance: advance,
            em: run.fontSize, descent: 0, rise: run.rise)
          position += advance
        } else {
          // Unknown metrics: keep the source order but a zero-width marker.
          bounds = Self.composedBounds(
            matrix: matrix, position: glyphPosition, advance: 0,
            em: run.fontSize, descent: 0, rise: run.rise)
        }
        if let metrics {
          // P14-016: union the estimate with the program's ink box (scaled
          // from font units), so descenders below the baseline are inside
          // the hit box. The union is conservative: it never shrinks the
          // existing estimate.
          var ink: [Double]?
          for scalar in decoded.unicodeScalars {
            guard let box = metrics.bounds(scalar: Int(scalar.value)) else { continue }
            let pointScale = run.fontSize / Double(metrics.inspector.unitsPerEm)
            let horizontal =
              pointScale * max(0.01, min(1000, run.horizontalScale)) / 100
            let inkBounds = Self.composedBounds(
              matrix: matrix, position: glyphPosition,
              advance: Double(box[2] - box[0]) * horizontal,
              em: Double(box[3]) * pointScale,
              descent: Double(box[1]) * pointScale,
              xOffset: Double(box[0]) * horizontal, rise: run.rise)
            ink =
              ink.map {
                [
                  min($0[0], inkBounds[0]), min($0[1], inkBounds[1]),
                  max($0[2], inkBounds[2]), max($0[3], inkBounds[3]),
                ]
              }
              ?? inkBounds
          }
          if let ink {
            bounds = [
              min(bounds[0], ink[0]), min(bounds[1], ink[1]),
              max(bounds[2], ink[2]), max(bounds[3], ink[3]),
            ]
          }
        }
        glyphs.append(
          TextCluster(
            runIndex: runIndex, glyphIndex: glyphIndex, text: decoded, code: code,
            origin: origin, advance: advance, fontSize: run.fontSize, bounds: bounds))
      }
    }

    // Rotated shows form their own lines in source glyph order. Grouping
    // diagonal glyphs by page Y would reverse/split a watermark into letters.
    let rotatedRuns = Set(
      runs.indices.filter { index in
        let matrix = TextCanvasSupport.concatenate(runs[index].ctm, runs[index].matrix)
        return abs(matrix[1]) > 0.00001 || matrix[0] < 0
      })
    // Greedy line grouping by compatible horizontal baselines, then left-to-right.
    var pending: [(baseline: Double, tolerance: Double, items: [TextCluster])] = []
    for glyph in glyphs.filter({ !rotatedRuns.contains($0.runIndex) }).sorted(by: {
      $0.origin[1] > $1.origin[1]
    }) {
      let tolerance = max(1.0, 0.3 * glyph.fontSize)
      if let index = pending.firstIndex(where: {
        abs($0.baseline - glyph.origin[1]) <= max($0.tolerance, tolerance)
      }) {
        pending[index].items.append(glyph)
      } else {
        pending.append((baseline: glyph.origin[1], tolerance: tolerance, items: [glyph]))
      }
    }
    // P16-007: split each baseline into column segments at large horizontal
    // gaps, detect a shared gutter across lines, and order column-major so
    // multi-column pages never interleave unrelated text. Single-column
    // pages keep exactly the previous behavior (one segment per baseline).
    struct Segment {
      let column: Int
      let baseline: Double
      let items: [TextCluster]
    }
    var segments: [Segment] = []
    var gutters: [(Double, Double)] = []
    for line in pending.sorted(by: { $0.baseline > $1.baseline }) {
      // P14-018: base characters sort before a combining mark at the same
      // left edge (a mark can never precede its base), then by original
      // source order; a mark drawn first at line start is swapped after a
      // nearby base.
      var ordered = line.items.sorted { lhs, rhs in
        if lhs.bounds[0] != rhs.bounds[0] { return lhs.bounds[0] < rhs.bounds[0] }
        if lhs.isCombiningMark != rhs.isCombiningMark { return !lhs.isCombiningMark }
        if lhs.runIndex != rhs.runIndex { return lhs.runIndex < rhs.runIndex }
        return lhs.glyphIndex < rhs.glyphIndex
      }
      if ordered.count >= 2, ordered[0].isCombiningMark, !ordered[1].isCombiningMark,
        ordered[1].bounds[0] - ordered[0].bounds[0]
          < max(1.0, 0.5 * ordered[1].fontSize)
      {
        ordered.swapAt(0, 1)
      }
      var currentItems: [TextCluster] = []
      var previousEnd: Double?
      for cluster in ordered {
        // A three-em cutoff can swallow narrow but real column gutters (for
        // example, 26.85 pt beside 10 pt body text). Keep the 24 pt floor,
        // but split at two em so adjacent columns remain separate.
        let threshold = max(2.0 * cluster.fontSize, 24)
        if let previousEnd, cluster.bounds[0] - previousEnd > threshold {
          gutters.append((previousEnd, cluster.bounds[0]))
          segments.append(Segment(column: 0, baseline: line.baseline, items: currentItems))
          currentItems = []
        }
        currentItems.append(cluster)
        previousEnd = max(previousEnd ?? cluster.bounds[2], cluster.bounds[2])
      }
      if !currentItems.isEmpty {
        segments.append(Segment(column: 0, baseline: line.baseline, items: currentItems))
      }
    }
    let rotated = Dictionary(
      grouping: glyphs.filter { rotatedRuns.contains($0.runIndex) },
      by: { runs[$0.runIndex].instructionIndex })
    for instruction in rotated.keys.sorted() {
      let items = rotated[instruction] ?? []
      let ordered = items.sorted {
        $0.runIndex == $1.runIndex ? $0.glyphIndex < $1.glyphIndex : $0.runIndex < $1.runIndex
      }
      segments.append(
        Segment(column: 0, baseline: items.map { $0.bounds[3] }.max() ?? 0, items: ordered))
    }
    if !rotated.isEmpty {
      segments.sort {
        if $0.baseline != $1.baseline { return $0.baseline > $1.baseline }
        return ($0.items.first?.runIndex ?? 0) < ($1.items.first?.runIndex ?? 0)
      }
    }
    // A gutter is credible when at least half the lines leave it clear; its
    // position is the midpoint of the clear interval.
    var cutPositions: [Double] = []
    if !gutters.isEmpty, pending.count >= 2 {
      let candidates = Set(gutters.map { ($0.0 + $0.1) / 2 })
      for candidate in candidates.sorted() {
        let clearing = gutters.filter { $0.0 <= candidate && candidate <= $0.1 }.count
        if clearing * 2 >= pending.count {
          if let last = cutPositions.last, candidate - last < 8 { continue }
          cutPositions.append(candidate)
        }
      }
    }
    let orderedSegments: [Segment]
    if cutPositions.isEmpty {
      orderedSegments = segments
    } else {
      var withColumns = segments
      for index in withColumns.indices {
        let left = withColumns[index].items.first?.bounds[0] ?? 0
        withColumns[index] = Segment(
          column: cutPositions.filter { $0 <= left }.count,
          baseline: withColumns[index].baseline, items: withColumns[index].items)
      }
      orderedSegments = withColumns.sorted { lhs, rhs in
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        if lhs.baseline != rhs.baseline { return lhs.baseline > rhs.baseline }
        return (lhs.items.first?.bounds[0] ?? 0) < (rhs.items.first?.bounds[0] ?? 0)
      }
    }
    var clusters: [TextCluster] = []
    var lines: [Range<Int>] = []
    for segment in orderedSegments {
      let start = clusters.count
      clusters.append(contentsOf: segment.items)
      lines.append(start..<clusters.count)
    }

    var words: [Range<Int>] = []
    for line in lines {
      var current: Range<Int>?
      var previousEnd: Double?
      func flush() {
        if let current { words.append(current) }
        current = nil
      }
      for index in line {
        let cluster = clusters[index]
        if cluster.isWhitespace {
          flush()
          previousEnd = nil
          continue
        }
        // P14-018: a combining mark never starts a word; attach it to the
        // current word regardless of its positional gap.
        if cluster.isCombiningMark, let open = current {
          current = open.lowerBound..<(index + 1)
          previousEnd = cluster.bounds[2]
          continue
        }
        let gap = previousEnd.map { cluster.bounds[0] - $0 } ?? 0
        let threshold = max(1.0, 0.25 * cluster.fontSize)
        if current == nil || gap > threshold {
          flush()
          current = index..<(index + 1)
        } else {
          current = current!.lowerBound..<(index + 1)
        }
        previousEnd = cluster.bounds[2]
      }
      flush()
    }
    return PageTextLayout(pageID: content.pageID, clusters: clusters, lines: lines, words: words)
  }

  /// P16-008: map a text-space box through a run matrix and return its
  /// axis-aligned page-space bounds. `position`/`advance`/`xOffset` and the
  /// vertical `descent`/`em`/`rise` are text-space distances; with the
  /// identity matrix the result is the historical estimate.
  static func composedBounds(
    matrix: [Double], position: Double, advance: Double, em: Double, descent: Double,
    xOffset: Double = 0, rise: Double = 0
  ) -> [Double] {
    let x0 = position + xOffset
    let x1 = x0 + advance
    let y0 = rise + descent
    let y1 = rise + em
    var minX = Double.greatestFiniteMagnitude
    var minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] {
      let pageX = matrix[4] + x * matrix[0] + y * matrix[2]
      let pageY = matrix[5] + x * matrix[1] + y * matrix[3]
      minX = min(minX, pageX)
      minY = min(minY, pageY)
      maxX = max(maxX, pageX)
      maxY = max(maxY, pageY)
    }
    return [minX, minY, maxX, maxY]
  }

  /// P14-016: resolve a simple font's embedded TrueType program (through the
  /// descriptor's FontFile2, decoded through its filters) for per-glyph ink
  /// bounds. Returns nil for unembedded, CFF-flavored, or unreadable
  /// programs; callers then keep the conservative size estimate.
  static func outlineMetrics(fontID: PDFObjectID, in graph: PDFGraph) -> TrueTypeOutlineMetrics? {
    guard case .dictionary(let font)? = graph.objects[fontID] else { return nil }
    let descriptor: [PDFName: PDFValue]?
    switch font[PDFName("FontDescriptor")] {
    case .reference(let id)?:
      if case .dictionary(let value)? = graph.objects[id] {
        descriptor = value
      } else {
        descriptor = nil
      }
    case .dictionary(let value)?:
      descriptor = value
    default:
      descriptor = nil
    }
    guard let descriptor else { return nil }
    let file: PDFStream?
    switch descriptor[PDFName("FontFile2")] {
    case .reference(let id)?:
      if case .stream(let value)? = graph.objects[id] {
        file = value
      } else {
        file = nil
      }
    case .stream(let value)?:
      file = value
    default:
      file = nil
    }
    guard let file, let data = try? PDFFilters.decoded(file) else { return nil }
    return try? TrueTypeOutlineMetrics(program: data)
  }

  public func lineIndex(containing clusterIndex: Int) -> Int? {
    lines.firstIndex { $0.contains(clusterIndex) }
  }

  public func wordRange(containing clusterIndex: Int) -> Range<Int>? {
    words.first { $0.contains(clusterIndex) }
  }

  /// P16-009: map a point in page space to a text cluster via its bounds,
  /// choosing the closest baseline when several overlap.
  public func clusterIndex(at point: [Double]) -> Int? {
    let containing = clusters.indices.filter { contains(clusters[$0].bounds, point) }
    return containing.min {
      let left = abs(clusters[$0].origin[1] - point[1])
      let right = abs(clusters[$1].origin[1] - point[1])
      return left == right ? $0 < $1 : left < right
    }
  }

  /// P16-010: character, word, and line selections from a hit test.
  public func characterSelection(at point: [Double]) -> Range<Int>? {
    clusterIndex(at: point).map { $0..<($0 + 1) }
  }

  public func wordSelection(at point: [Double]) -> Range<Int>? {
    clusterIndex(at: point).flatMap(wordRange(containing:))
  }

  public func lineSelection(at point: [Double]) -> Range<Int>? {
    clusterIndex(at: point).flatMap(lineIndex(containing:)).map { lines[$0] }
  }

  /// P16-013: copy text in reading order for a cluster range.
  public func text(in range: Range<Int>) -> String {
    guard range.lowerBound >= 0, range.upperBound <= clusters.count else { return "" }
    return clusters[range].map(\.text).joined()
  }

  private func contains(_ bounds: [Double], _ point: [Double]) -> Bool {
    bounds[0] <= point[0] && point[0] <= bounds[2] && bounds[1] <= point[1]
      && point[1] <= bounds[3]
  }
}

public struct TextSearchOptions: Sendable, Equatable {
  public var caseSensitive: Bool
  public var wholeWord: Bool
  public var diacriticInsensitive: Bool

  public init(
    caseSensitive: Bool = false, wholeWord: Bool = false, diacriticInsensitive: Bool = false
  ) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
    self.diacriticInsensitive = diacriticInsensitive
  }
}

public struct TextMatch: Sendable, Equatable {
  public let clusterRange: Range<Int>
  public let lineIndex: Int
  /// P16-017: per-cluster bounds for highlight rendering.
  public let bounds: [[Double]]
}

/// P16-015/P16-016: Unicode-normalized search within a line, with case,
/// whole-word, and diacritic options. Matches never cross line boundaries in
/// this profile; `onMatch` returning false stops the search early and keeps
/// the delivered partial results.
public enum TextSearch {
  @discardableResult
  public static func search(
    query: String, in layout: PageTextLayout, options: TextSearchOptions = TextSearchOptions(),
    onMatch: ((TextMatch) -> Bool)? = nil
  ) -> [TextMatch] {
    guard !query.isEmpty else { return [] }
    var folding: String.CompareOptions = []
    if !options.caseSensitive { folding.insert(.caseInsensitive) }
    if options.diacriticInsensitive { folding.insert(.diacriticInsensitive) }
    // P14-018: canonical composition so a precomposed query matches
    // decomposed document text (and vice versa).
    let needle = Array(
      query.folding(options: folding, locale: Locale(identifier: "en_US_POSIX"))
        .precomposedStringWithCanonicalMapping)
    guard !needle.isEmpty else { return [] }

    var results: [TextMatch] = []
    for (lineIndex, line) in layout.lines.enumerated() {
      if Task.isCancelled { break }
      var haystack: [Character] = []
      // Each haystack character maps back to the cluster span it came from;
      // a combining mark folds together with its base, so a composed
      // character maps to both clusters and highlights cover both.
      var map: [(first: Int, last: Int)] = []
      var index = line.lowerBound
      while index < line.upperBound {
        var next = index + 1
        var unit = layout.clusters[index].text
        while next < line.upperBound, layout.clusters[next].isCombiningMark {
          unit += layout.clusters[next].text
          next += 1
        }
        let folded = unit.folding(options: folding, locale: Locale(identifier: "en_US_POSIX"))
          .precomposedStringWithCanonicalMapping
        for character in folded {
          haystack.append(character)
          map.append((index, next - 1))
        }
        index = next
      }
      guard haystack.count >= needle.count else { continue }
      var position = 0
      while position + needle.count <= haystack.count {
        if Task.isCancelled { break }
        let end = position + needle.count
        if Array(haystack[position..<end]) == needle {
          let first = map[position].first
          let last = map[end - 1].last
          var accepted = true
          if options.wholeWord {
            accepted = layout.words.contains {
              $0.lowerBound == first && $0.upperBound == last + 1
            }
          }
          if accepted {
            let match = TextMatch(
              clusterRange: first..<(last + 1), lineIndex: lineIndex,
              bounds: Array(layout.clusters[first..<(last + 1)].map(\.bounds)))
            results.append(match)
            if let onMatch, onMatch(match) == false { return results }
          }
          position = end
        } else {
          position += 1
        }
      }
    }
    return results
  }
}
