import Foundation
import PDFCore

// MARK: - RED-02 search scope, patterns and reusable term sets

/// Where a redaction search looks. Selection is restricted to the page-space
/// bounds of the current PDF selection on the current page; page is the
/// current page; document visits every page in order.
public enum RedactionSearchScope: String, Sendable, CaseIterable, Equatable {
  case selection
  case page
  case document

  public var title: String {
    switch self {
    case .selection: return "Selection"
    case .page: return "Current page"
    case .document: return "Document"
    }
  }
}

/// A user-defined regular expression that produces redaction candidates. The
/// expression is matched against one text line at a time; matches never cross
/// a line boundary.
public struct RedactionPattern: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var name: String
  public var expression: String
  public var caseSensitive: Bool

  public init(
    id: UUID = UUID(), name: String, expression: String, caseSensitive: Bool = true
  ) {
    self.id = id
    self.name = name
    self.expression = expression
    self.caseSensitive = caseSensitive
  }

  /// Compile and return the expression, reporting a usable error message.
  func compiled() throws -> NSRegularExpression {
    do {
      return try NSRegularExpression(
        pattern: expression, options: caseSensitive ? [] : [.caseInsensitive])
    } catch {
      let reason = name.isEmpty ? "the pattern" : "pattern " + name
      throw PDFError(
        .malformed, "Search pattern \(reason) is not a valid regular expression: \(error.localizedDescription)")
    }
  }

  static func validate(_ pattern: RedactionPattern) throws {
    guard !pattern.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "A redaction search pattern needs an expression")
    }
    _ = try pattern.compiled()
  }
}

/// A reusable, named list of words or phrases applied together. Term sets are
/// plain data and can be saved/loaded as JSON so a review team reuses the same
/// policy instead of retyping it.
public struct RedactionTermSet: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public var name: String
  public var terms: [String]
  public var caseSensitive: Bool
  public var wholeWord: Bool

  public init(
    id: UUID = UUID(), name: String, terms: [String], caseSensitive: Bool = false,
    wholeWord: Bool = false
  ) {
    self.id = id
    self.name = name
    self.terms = terms
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
  }

  public var isEmpty: Bool {
    terms.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  static func validate(_ set: RedactionTermSet) throws {
    guard !set.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "A redaction term set needs a name")
    }
    guard !set.terms.isEmpty else {
      throw PDFError(.malformed, "A redaction term set needs at least one term")
    }
    guard set.terms.count <= 500 else {
      throw PDFError(.limitExceeded, "A redaction term set is limited to 500 terms")
    }
    for term in set.terms {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw PDFError(.malformed, "Redaction term set terms cannot be empty")
      }
      guard trimmed.count <= 500 else {
        throw PDFError(.limitExceeded, "A redaction term is too long")
      }
    }
  }
}

/// Named term sets kept across searches. Codable as JSON for reuse in another
/// session or document; nothing is written into the PDF.
public struct RedactionTermSetLibrary: Codable, Sendable, Equatable {
  public private(set) var sets: [RedactionTermSet]

  public init() {
    self.sets = []
  }

  public func set(named name: String) -> RedactionTermSet? {
    sets.first { $0.name == name }
  }

  /// Add a set, replacing an existing set with the same name so a saved policy
  /// updates in place instead of duplicating.
  public mutating func upsert(_ set: RedactionTermSet) throws {
    try RedactionTermSet.validate(set)
    let deduped = RedactionTermSet(
      id: set.id, name: set.name,
      terms: Self.dedupe(set.terms), caseSensitive: set.caseSensitive,
      wholeWord: set.wholeWord)
    if let index = sets.firstIndex(where: { $0.name == set.name }) {
      sets[index] = deduped
    } else {
      sets.append(deduped)
    }
  }

  @discardableResult
  public mutating func remove(named name: String) -> Bool {
    guard let index = sets.firstIndex(where: { $0.name == name }) else { return false }
    sets.remove(at: index)
    return true
  }

  public func encodedJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  public static func decoded(from data: Data) throws -> RedactionTermSetLibrary {
    do {
      let library = try JSONDecoder().decode(RedactionTermSetLibrary.self, from: data)
      for set in library.sets { try RedactionTermSet.validate(set) }
      return library
    } catch let error as PDFError {
      throw error
    } catch {
      throw PDFError(
        .malformed, "The redaction term set file could not be read: \(error.localizedDescription)")
    }
  }

  static func dedupe(_ terms: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for term in terms {
      let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      result.append(trimmed)
    }
    return result
  }
}

// MARK: - Search request and hits

/// One reviewed redaction candidate. A hit is never a mutation: the user
/// selects the hits they want and turns them into pending marks.
public struct RedactionSearchHit: Identifiable, Sendable, Equatable {
  public enum Eligibility: Sendable, Equatable {
    case eligible
    case refused(String)

    public var isEligible: Bool {
      if case .eligible = self { return true }
      return false
    }

    public var reason: String? {
      if case .refused(let reason) = self { return reason }
      return nil
    }
  }

  /// Stable for one preview: page, line and glyph-cluster geometry.
  public let id: String
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let lineIndex: Int
  /// The reviewed match text.
  public let text: String
  /// Context on the same line, before and after the match.
  public let contextBefore: String
  public let contextAfter: String
  /// Page-space bounds of every matched glyph cluster.
  public let bounds: [[Double]]
  public let runIndices: [Int]
  public let sources: [String]
  /// True for an invisible text run or a generated OCR layer match.
  public let isHidden: Bool
  /// True when hidden text was excluded by the request scope rather than being
  /// unremovable.
  public let isExcludedByScope: Bool
  public let eligibility: Eligibility
  /// RED-04: true when the match sits over page raster content. Applying such a
  /// mark also removes the whole intersecting scanned image draw, because
  /// removing only the hidden text layer would leave the visible pixels.
  public let requiresRasterRemoval: Bool
  /// RED-04 review note for a raster-backed match (nil otherwise).
  public let rasterNote: String?

  public init(
    id: String, pageID: PDFObjectID, pageIndex: Int, lineIndex: Int, text: String,
    contextBefore: String, contextAfter: String, bounds: [[Double]], runIndices: [Int],
    sources: [String], isHidden: Bool, isExcludedByScope: Bool,
    eligibility: Eligibility, requiresRasterRemoval: Bool = false,
    rasterNote: String? = nil
  ) {
    self.id = id
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.lineIndex = lineIndex
    self.text = text
    self.contextBefore = contextBefore
    self.contextAfter = contextAfter
    self.bounds = bounds
    self.runIndices = runIndices
    self.sources = sources
    self.isHidden = isHidden
    self.isExcludedByScope = isExcludedByScope
    self.eligibility = eligibility
    self.requiresRasterRemoval = requiresRasterRemoval
    self.rasterNote = rasterNote
  }

  public var pageLabel: String { "Page \(pageIndex + 1)" }
  /// RED-04: applying this hit removes the whole intersecting scan draw too.
  public var removesRasterPaint: Bool { requiresRasterRemoval }
  public var isEligible: Bool { eligibility.isEligible }
  public var refusal: String? { eligibility.reason }

  /// Human-readable context with the match in angle brackets.
  public var context: String {
    let before = contextBefore.isEmpty ? "" : contextBefore + " "
    let after = contextAfter.isEmpty ? "" : " " + contextAfter
    return before + "⟨" + text + "⟩" + after
  }

  public var sourceLabel: String { sources.joined(separator: ", ") }
}

/// The complete, non-mutating search result the review queue is built from.
public struct RedactionSearchPreview: Sendable, Equatable {
  public let hits: [RedactionSearchHit]
  public let includeHiddenText: Bool

  public init(hits: [RedactionSearchHit], includeHiddenText: Bool) {
    self.hits = hits
    self.includeHiddenText = includeHiddenText
  }

  public var eligibleCount: Int { hits.filter(\.isEligible).count }
  public var refusedCount: Int { hits.count - eligibleCount }
  public var hiddenCount: Int { hits.filter(\.isHidden).count }
  public var scopeExcludedCount: Int { hits.filter(\.isExcludedByScope).count }
  /// RED-04: eligible matches that also remove an intersecting scanned image.
  public var rasterRemovalCount: Int {
    hits.filter { $0.isEligible && $0.requiresRasterRemoval }.count
  }

  public var summary: String {
    if hits.isEmpty { return "No matches." }
    var summary = "\(hits.count) match(es)"
    summary += ": \(eligibleCount) can be marked"
    if refusedCount > 0 { summary += ", \(refusedCount) refused" }
    if scopeExcludedCount > 0 {
      summary += ", \(scopeExcludedCount) hidden match(es) excluded by the scope"
    }
    return summary + "."
  }
}

/// One complete search request. Words and phrases are literal queries; term
/// sets expand to their terms; patterns are regular expressions. Nothing is
/// applied automatically: the caller reviews the hits and selects them.
public struct RedactionSearchRequest: Sendable, Equatable {
  public let scope: RedactionSearchScope
  /// All document page IDs in order.
  public let pageIDs: [PDFObjectID]
  /// Zero-based page currently shown in the viewer.
  public let currentPageIndex: Int
  /// Page-space rectangles of the current selection on the current page.
  public let selectionRects: [[Double]]?
  public let queries: [String]
  public let patterns: [RedactionPattern]
  public let termSets: [RedactionTermSet]
  public let options: TextSearchOptions
  /// When false, hidden/OCR matches are listed as refused so the scope is
  /// explicit instead of silently hiding them.
  public let includeHiddenText: Bool

  public init(
    scope: RedactionSearchScope, pageIDs: [PDFObjectID], currentPageIndex: Int,
    selectionRects: [[Double]]? = nil, queries: [String] = [],
    patterns: [RedactionPattern] = [], termSets: [RedactionTermSet] = [],
    options: TextSearchOptions = TextSearchOptions(), includeHiddenText: Bool = false
  ) {
    self.scope = scope
    self.pageIDs = pageIDs
    self.currentPageIndex = currentPageIndex
    self.selectionRects = selectionRects
    self.queries = queries
    self.patterns = patterns
    self.termSets = termSets
    self.options = options
    self.includeHiddenText = includeHiddenText
  }

  public var isEmpty: Bool {
    queries.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      && patterns.isEmpty && termSets.allSatisfy(\.isEmpty)
  }
}

// MARK: - Search

public enum RedactionSearch {
  /// Find every reviewed candidate without changing the graph.
  public static func preview(
    _ request: RedactionSearchRequest, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> RedactionSearchPreview {
    guard !request.isEmpty else {
      throw PDFError(.malformed, "Enter a word, phrase, term set or pattern to search for")
    }
    guard !request.pageIDs.isEmpty else {
      throw PDFError(.malformed, "The document has no pages to search")
    }
    guard request.pageIDs.indices.contains(request.currentPageIndex) else {
      throw PDFError(.malformed, "The current page is outside the document")
    }
    guard request.scope != .selection || !(request.selectionRects ?? []).isEmpty else {
      throw PDFError(.unsupported, "Select text on the page before using selection scope")
    }
    for pattern in request.patterns { try RedactionPattern.validate(pattern) }
    for set in request.termSets { try RedactionTermSet.validate(set) }

    let pageIndices: [Int]
    switch request.scope {
    case .document: pageIndices = Array(request.pageIDs.indices)
    case .page, .selection: pageIndices = [request.currentPageIndex]
    }
    let queries = request.queries
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var collected: [Candidate] = []
    for pageIndex in pageIndices {
      let pageID = request.pageIDs[pageIndex]
      let layout = try PageTextLayout.buildForParagraphEditing(
        pageID: pageID, in: graph, limits: limits)
      let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
      let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
      let hiddenInfo = try RedactionHiddenText.hiddenInfo(
        pageID: pageID, in: graph, content: content, runs: runs, limits: limits)
      let imageBounds = ((try? StructureTaggingAssistant.imagePlacements(
        in: content, graph: graph)) ?? []).map(\.bounds)
      var matches: [Match] = []
      for query in queries {
        for match in TextSearch.search(
          query: query, in: layout, options: request.options)
        {
          matches.append(
            Match(
              clusterRange: match.clusterRange, lineIndex: match.lineIndex,
              source: "Text: " + query))
        }
      }
      for set in request.termSets {
        let termOptions = TextSearchOptions(
          caseSensitive: request.options.caseSensitive || set.caseSensitive,
          wholeWord: request.options.wholeWord || set.wholeWord,
          diacriticInsensitive: request.options.diacriticInsensitive)
        for term in set.terms {
          let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { continue }
          for match in TextSearch.search(
            query: trimmed, in: layout, options: termOptions)
          {
            matches.append(
              Match(
                clusterRange: match.clusterRange, lineIndex: match.lineIndex,
                source: "Term set: " + set.name))
          }
        }
      }
      for pattern in request.patterns {
        for match in try patternMatches(pattern: pattern, layout: layout) {
          matches.append(
            Match(
              clusterRange: match, lineIndex: layout.lineIndex(containing: match.lowerBound) ?? 0,
              source: "Pattern: " + pattern.name))
        }
      }
      let filtered = matches.filter { match in
        guard request.scope == .selection else { return true }
        let bounds = layout.clusters[match.clusterRange].map(\.bounds)
        return selectionAccepts(bounds, rects: request.selectionRects ?? [])
      }
      let grouped = Dictionary(grouping: filtered, by: \.clusterRange)
      for clusterRange in grouped.keys.sorted(by: {
        ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
      }) {
        let group = grouped[clusterRange] ?? []
        guard let first = group.first,
          clusterRange.lowerBound >= 0, clusterRange.upperBound <= layout.clusters.count
        else { continue }
        let clusters = Array(layout.clusters[clusterRange])
        guard !clusters.isEmpty else { continue }
        let runIndices = clusters.map(\.runIndex)
        let runSet = Set(runIndices)
        let layerRuns = runSet.intersection(hiddenInfo.layerRunIndices)
        let hiddenRuns = runSet.intersection(hiddenInfo.hiddenRunIndices)
        let isLayer = !layerRuns.isEmpty && layerRuns.count == runSet.count
        let isHiddenText = !hiddenRuns.isEmpty && hiddenRuns.count == runSet.count
        let mixed = (!layerRuns.isEmpty || !hiddenRuns.isEmpty) && !isLayer && !isHiddenText
        let isHidden = isLayer || isHiddenText
        let bounds = clusters.map(\.bounds)
        let context = lineContext(layout: layout, lineIndex: first.lineIndex, clusterRange: clusterRange)
        var eligibility: RedactionSearchHit.Eligibility = .eligible
        var excludedByScope = false
        var requiresRasterRemoval = false
        var rasterNote: String?
        if mixed {
          eligibility = .refused(
            "The match crosses visible and hidden text; review each appearance separately.")
        } else if isHidden, !request.includeHiddenText {
          excludedByScope = true
          eligibility = .refused(
            "Hidden/OCR text is excluded by the selected scope. Enable hidden and OCR text to review and remove it.")
        } else if isHidden {
          // RED-04: OCR/text over a scan is now reviewable. Applying the mark
          // removes the whole intersecting image draw so pixels cannot retain
          // the text; the review note says so before anything is staged.
          if let note = rasterRemovalNote(bounds: bounds, imageBounds: imageBounds) {
            requiresRasterRemoval = true
            rasterNote = note
          }
          do {
            _ = try RedactionTextPrecision.analyze(
              pageID: pageID, rects: bounds, hiddenOnly: true, in: graph, limits: limits)
          } catch {
            eligibility = .refused(error.localizedDescription)
          }
        } else {
          do {
            _ = try RedactionTextPrecision.analyze(
              pageID: pageID, rects: bounds, hiddenOnly: false, in: graph, limits: limits)
          } catch {
            eligibility = .refused(error.localizedDescription)
          }
        }
        let label = first.source
        collected.append(
          Candidate(
            key: "\(pageID.number)-\(clusterRange.lowerBound)-\(clusterRange.upperBound)",
            pageID: pageID, pageIndex: pageIndex, lineIndex: first.lineIndex,
            text: layout.text(in: clusterRange),
            contextBefore: context.before, contextAfter: context.after, bounds: bounds,
            runIndices: runIndices, sources: [label], isHidden: isHidden,
            isExcludedByScope: excludedByScope, eligibility: eligibility,
            requiresRasterRemoval: requiresRasterRemoval, rasterNote: rasterNote))
      }
    }
    // Merge identical geometry found by several sources.
    var merged: [String: Candidate] = [:]
    var order: [String] = []
    for candidate in collected {
      if var existing = merged[candidate.key] {
        if !existing.sources.contains(candidate.pendingSource) {
          existing.sources.append(candidate.pendingSource)
        }
        merged[candidate.key] = existing
      } else {
        merged[candidate.key] = candidate
        order.append(candidate.key)
      }
    }
    let hits = order.compactMap { merged[$0] }.map { candidate in
      RedactionSearchHit(
        id: candidate.key, pageID: candidate.pageID, pageIndex: candidate.pageIndex,
        lineIndex: candidate.lineIndex, text: candidate.text,
        contextBefore: candidate.contextBefore, contextAfter: candidate.contextAfter,
        bounds: candidate.bounds, runIndices: candidate.runIndices,
        sources: candidate.sources.sorted(), isHidden: candidate.isHidden,
        isExcludedByScope: candidate.isExcludedByScope, eligibility: candidate.eligibility,
        requiresRasterRemoval: candidate.requiresRasterRemoval,
        rasterNote: candidate.rasterNote)
    }
    return RedactionSearchPreview(hits: hits, includeHiddenText: request.includeHiddenText)
  }

  private struct Match {
    let clusterRange: Range<Int>
    let lineIndex: Int
    let source: String
  }

  private struct Candidate {
    let key: String
    let pageID: PDFObjectID
    let pageIndex: Int
    let lineIndex: Int
    let text: String
    let contextBefore: String
    let contextAfter: String
    let bounds: [[Double]]
    let runIndices: [Int]
    var sources: [String]
    let isHidden: Bool
    let isExcludedByScope: Bool
    let eligibility: RedactionSearchHit.Eligibility
    /// RED-04: the match sits over scanned raster content.
    let requiresRasterRemoval: Bool
    let rasterNote: String?

    /// The source carrying this candidate into the merge step.
    var pendingSource: String { sources.first ?? "" }
  }

  static func patternMatches(
    pattern: RedactionPattern, layout: PageTextLayout
  ) throws -> [Range<Int>] {
    let regex = try pattern.compiled()
    var results: [Range<Int>] = []
    for line in layout.lines {
      var text = ""
      var map: [Int] = []
      for clusterIndex in line {
        let clusterText = layout.clusters[clusterIndex].text
        for _ in 0..<clusterText.utf16.count { map.append(clusterIndex) }
        text += clusterText
      }
      let nsText = text as NSString
      guard nsText.length > 0 else { continue }
      regex.enumerateMatches(
        in: text, range: NSRange(location: 0, length: nsText.length)
      ) { result, _, _ in
        guard let result, result.range.length > 0, result.range.location >= 0,
          NSMaxRange(result.range) <= map.count
        else { return }
        let first = map[result.range.location]
        let last = map[NSMaxRange(result.range) - 1]
        if first <= last { results.append(first..<(last + 1)) }
      }
    }
    return results
  }

  static func selectionAccepts(_ bounds: [[Double]], rects: [[Double]]) -> Bool {
    guard !rects.isEmpty else { return false }
    return bounds.contains { bound in
      rects.contains { rect in
        bound.count == 4 && rect.count == 4
          && bound[0] <= rect[2] && bound[2] >= rect[0]
          && bound[1] <= rect[3] && bound[3] >= rect[1]
      }
    }
  }

  /// RED-04: a hidden/OCR match over an image draw is markable; applying it
  /// removes the whole intersecting scan so the pixels do not retain the text.
  /// Returns the review note when raster paint backs the match.
  static func rasterRemovalNote(
    bounds: [[Double]], imageBounds: [[Double]]
  ) -> String? {
    let covering = imageBounds.contains { placementBounds in
      RedactRegionsCommand.intersects(placementBounds, anyRegion: bounds)
    }
    guard covering else { return nil }
    return
      "This OCR/text match sits over scanned page content. Applying it removes the whole "
      + "intersecting scanned image draw so the pixels do not retain the text."
  }

  static func lineContext(
    layout: PageTextLayout, lineIndex: Int, clusterRange: Range<Int>
  ) -> (before: String, after: String) {
    guard layout.lines.indices.contains(lineIndex) else { return ("", "") }
    let line = layout.lines[lineIndex]
    var lineText = ""
    var offsets: [Int: Int] = [:]
    var cursor = 0
    for clusterIndex in line {
      offsets[clusterIndex] = cursor
      let text = layout.clusters[clusterIndex].text
      lineText += text
      cursor += text.utf16.count
    }
    let start = offsets[clusterRange.lowerBound] ?? 0
    let lastCluster = clusterRange.upperBound - 1
    let lastLength = layout.clusters.indices.contains(lastCluster)
      ? layout.clusters[lastCluster].text.utf16.count : 0
    let end = (offsets[lastCluster] ?? start) + lastLength
    let ns = lineText as NSString
    let before = ns.substring(to: min(max(start, 0), ns.length))
    let after = ns.substring(from: min(max(end, 0), ns.length))
    return (trimmedTail(before), trimmedHead(after))
  }

  private static func trimmedTail(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(
      of: " +", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    guard collapsed.count > 64 else { return collapsed }
    let tail = String(collapsed.suffix(64))
    if let space = tail.firstIndex(of: " ") {
      return "…" + String(tail[tail.index(after: space)...])
    }
    return "…" + tail
  }

  private static func trimmedHead(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(
      of: " +", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    guard collapsed.count > 64 else { return collapsed }
    let head = String(collapsed.prefix(64))
    if let space = head.lastIndex(of: " ") {
      return String(head[..<space]) + "…"
    }
    return head + "…"
  }
}

// MARK: - Per-hit review queue

/// The reviewed selection of search hits. Only selected eligible hits become
/// pending marks, so a user can review the actual matches before anything is
/// staged or applied.
public struct RedactionReviewQueue: Sendable, Equatable {
  public private(set) var hits: [RedactionSearchHit]
  public private(set) var selectedHitIDs: Set<String>

  public init(hits: [RedactionSearchHit], selectEligibleByDefault: Bool = true) {
    self.hits = hits
    self.selectedHitIDs = selectEligibleByDefault
      ? Set(hits.filter(\.isEligible).map(\.id)) : []
  }

  public var eligibleHits: [RedactionSearchHit] { hits.filter(\.isEligible) }
  public var selectedHits: [RedactionSearchHit] {
    hits.filter { selectedHitIDs.contains($0.id) && $0.isEligible }
  }

  public var selectedCount: Int { selectedHits.count }
  public var eligibleCount: Int { eligibleHits.count }
  public var allEligibleSelected: Bool {
    !eligibleHits.isEmpty && eligibleHits.allSatisfy { selectedHitIDs.contains($0.id) }
  }

  public func isSelected(_ id: String) -> Bool { selectedHitIDs.contains(id) }

  public mutating func setSelected(_ selected: Bool, hitID: String) {
    guard let hit = hits.first(where: { $0.id == hitID }), hit.isEligible else { return }
    if selected { selectedHitIDs.insert(hitID) } else { selectedHitIDs.remove(hitID) }
  }

  public mutating func toggle(hitID: String) {
    setSelected(!selectedHitIDs.contains(hitID), hitID: hitID)
  }

  public mutating func selectAllEligible() {
    selectedHitIDs = Set(eligibleHits.map(\.id))
  }

  public mutating func clearSelection() {
    selectedHitIDs.removeAll()
  }

  public var summary: String {
    if hits.isEmpty { return "No matches." }
    if eligibleCount == 0 { return "\(hits.count) match(es); none can be marked." }
    return "\(selectedCount) of \(eligibleCount) markable match(es) selected."
  }

  /// Turn the selected hits into pending text marks. Returns the number of
  /// marks staged; nothing is applied here.
  @discardableResult
  public mutating func addSelectedHits(
    to store: inout RedactionMarkStore, reason: String? = nil
  ) throws -> Int {
    var added = 0
    for hit in selectedHits {
      let pageIndex = hit.pageIndex
      let mark = try store.add(
        kind: .text, pageID: hit.pageID, pageIndex: pageIndex, rects: hit.bounds,
        reason: reason, matchedText: hit.text, sources: hit.sources,
        isHiddenText: hit.isHidden, removesRasterPaint: hit.requiresRasterRemoval)
      added += 1
      selectedHitIDs.remove(hit.id)
      _ = mark
    }
    return added
  }
}
