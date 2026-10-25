import Foundation
import PDFCore

/// TXT-07: scope of a find-and-replace operation. Selection is restricted to
/// the page-space bounds of the current PDF selection; page is the current
/// page; document visits every page in order.
public enum FindReplaceScope: String, Sendable, CaseIterable, Equatable {
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

public struct FindReplaceRequest: Sendable, Equatable {
  public let scope: FindReplaceScope
  /// All document page IDs in order. The engine selects the scope from these.
  public let pageIDs: [PDFObjectID]
  /// Zero-based page currently shown in the viewer.
  public let currentPageIndex: Int
  /// Page-space rectangles for the current selection, when selection scope is
  /// requested. Only the current page is supported by this profile.
  public let selectionRects: [[Double]]?
  public let query: String
  public let replacement: String
  public let options: TextSearchOptions

  public init(
    scope: FindReplaceScope, pageIDs: [PDFObjectID], currentPageIndex: Int,
    selectionRects: [[Double]]? = nil, query: String, replacement: String,
    options: TextSearchOptions = TextSearchOptions()
  ) {
    self.scope = scope
    self.pageIDs = pageIDs
    self.currentPageIndex = currentPageIndex
    self.selectionRects = selectionRects
    self.query = query
    self.replacement = replacement
    self.options = options
  }
}

public enum FindReplaceEligibility: Sendable, Equatable {
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

public struct FindReplaceMatch: Sendable, Equatable, Identifiable {
  public let id: String
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let lineIndex: Int
  public let text: String
  public let replacement: String
  /// Page-space bounds of the matched clusters. Empty for a refused match
  /// detected across a line boundary.
  public let bounds: [[Double]]
  public let eligibility: FindReplaceEligibility

  public init(
    id: String, pageID: PDFObjectID, pageIndex: Int, lineIndex: Int, text: String,
    replacement: String, bounds: [[Double]], eligibility: FindReplaceEligibility
  ) {
    self.id = id
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.lineIndex = lineIndex
    self.text = text
    self.replacement = replacement
    self.bounds = bounds
    self.eligibility = eligibility
  }
}

/// A non-mutating preview. `command` is nil when no match is eligible.
public struct FindReplacePreview: Sendable, Equatable {
  public let matches: [FindReplaceMatch]
  public let eligibleCount: Int
  public let refusedCount: Int
  public let command: FindReplaceCommand?

  public init(
    matches: [FindReplaceMatch], eligibleCount: Int, refusedCount: Int,
    command: FindReplaceCommand?
  ) {
    self.matches = matches
    self.eligibleCount = eligibleCount
    self.refusedCount = refusedCount
    self.command = command
  }

  public var summary: String {
    if matches.isEmpty { return "No matches." }
    let total = matches.count
    if refusedCount == 0 {
      return "\(total) \(total == 1 ? "match" : "matches") can be replaced."
    }
    if eligibleCount == 0 {
      return "\(total) \(total == 1 ? "match" : "matches"); none can be replaced."
    }
    return "\(eligibleCount) of \(total) \(total == 1 ? "match" : "matches") can be replaced; "
      + "\(refusedCount) refused."
  }
}

public struct FindReplaceResult: Sendable, Equatable {
  public let replacedCount: Int
  public let refusedCount: Int
  public let pageCount: Int
  public let summary: String

  public init(replacedCount: Int, refusedCount: Int, pageCount: Int) {
    self.replacedCount = replacedCount
    self.refusedCount = refusedCount
    self.pageCount = pageCount
    var summary = "Replaced \(replacedCount) \(replacedCount == 1 ? "match" : "matches")"
    if refusedCount > 0 { summary += "; \(refusedCount) refused" }
    summary += "."
    self.summary = summary
  }
}

/// One undoable command for every eligible replacement. Replacements are
/// applied run-by-run in descending index order so earlier run indices stay
/// valid; each inner edit uses the ordinary source-writing command.
public struct FindReplaceCommand: PDFEditCommand, Equatable, Sendable {
  public let replacements: [PDFObjectID: [Int: String]]

  public init(replacements: [PDFObjectID: [Int: String]]) {
    self.replacements = replacements
  }

  public var name: String { "Replace Text" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] {
    replacements.keys.sorted { $0.number < $1.number }
  }

  public func validate(in graph: PDFGraph) throws {
    for pageID in replacements.keys.sorted(by: { $0.number < $1.number }) {
      guard let runs = replacements[pageID] else { continue }
      for runIndex in runs.keys.sorted() {
        try ReplaceTextCommand(
          pageID: pageID, runIndex: runIndex, replacement: runs[runIndex] ?? "",
          overflowPolicy: .allow
        ).validate(in: graph)
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var result = graph
    for pageID in replacements.keys.sorted(by: { $0.number < $1.number }) {
      guard let runs = replacements[pageID] else { continue }
      for runIndex in runs.keys.sorted(by: >) {
        let command = ReplaceTextCommand(
          pageID: pageID, runIndex: runIndex, replacement: runs[runIndex] ?? "",
          overflowPolicy: .allow)
        result = try command.apply(to: result)
      }
    }
    return result
  }
}

public enum FindReplace {
  private struct Candidate {
    let id: String
    let pageID: PDFObjectID
    let pageIndex: Int
    let lineIndex: Int
    let match: TextMatch
    let matchedText: String
    let runIndex: Int?
    let runRange: NSRange?
    let originalRunText: String
    var eligibility: FindReplaceEligibility
    let replacement: String
  }

  /// Build a preview without changing the graph. A match is eligible only when
  /// it is wholly inside one editable run, contains no ligature cluster, and
  /// the resulting full-run replacement passes the ordinary font/overflow
  /// rewrite checks. Cross-run and cross-line matches are reported as refused
  /// rather than silently skipped.
  public static func preview(
    _ request: FindReplaceRequest, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> FindReplacePreview {
    guard !request.query.isEmpty else {
      return FindReplacePreview(matches: [], eligibleCount: 0, refusedCount: 0, command: nil)
    }
    guard request.pageIDs.indices.contains(request.currentPageIndex) else {
      throw PDFError(.malformed, "The find page is outside the document")
    }
    guard request.scope != .selection || !(request.selectionRects ?? []).isEmpty else {
      throw PDFError(.unsupported, "Select text in the page before using selection replace.")
    }

    let pageIndices: [Int]
    switch request.scope {
    case .document: pageIndices = Array(request.pageIDs.indices)
    case .page, .selection: pageIndices = [request.currentPageIndex]
    }
    var candidates: [Candidate] = []
    var seenCrossLine = Set<String>()
    for pageIndex in pageIndices {
      let pageID = request.pageIDs[pageIndex]
      let layout = try PageTextLayout.buildForParagraphEditing(
        pageID: pageID, in: graph, limits: limits)
      let sourceRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: graph)
      let runText = Dictionary(uniqueKeysWithValues: sourceRuns.map { ($0.index, $0.text) })
      let runFormats = Dictionary(uniqueKeysWithValues: sourceRuns.map { ($0.index, $0.format) })
      let matches = TextSearch.search(
        query: request.query, in: layout, options: request.options)
      for (ordinal, match) in matches.enumerated() {
        guard match.clusterRange.lowerBound < match.clusterRange.upperBound else { continue }
        let clusters = Array(layout.clusters[match.clusterRange])
        guard !clusters.isEmpty else { continue }
        let matchBounds = clusters.map(\.bounds)
        guard selectionAccepts(
          matchBounds, rects: request.scope == .selection ? request.selectionRects ?? [] : nil)
        else { continue }
        let matchedText = layout.text(in: match.clusterRange)
        let runIndices = Set(clusters.map(\.runIndex))
        let id = "\(pageID.number)-\(ordinal)-\(match.lineIndex)"
        if runIndices.count > 1 {
          let formats = runIndices.compactMap { runFormats[$0] }
          let reason = formats.count > 1
            ? "Match crosses a font or text-run boundary; replace each run in the paragraph editor."
            : "Match crosses a text-run boundary; replace it in the paragraph editor."
          candidates.append(
            Candidate(
              id: id, pageID: pageID, pageIndex: pageIndex, lineIndex: match.lineIndex,
              match: match, matchedText: matchedText, runIndex: nil, runRange: nil,
              originalRunText: "", eligibility: .refused(reason),
              replacement: request.replacement))
          continue
        }
        guard let runIndex = runIndices.first, let fullRunText = runText[runIndex] else {
          candidates.append(
            Candidate(
              id: id, pageID: pageID, pageIndex: pageIndex, lineIndex: match.lineIndex,
              match: match, matchedText: matchedText, runIndex: nil, runRange: nil,
              originalRunText: "",
              eligibility: .refused("Match uses a text run outside the inline writing profile."),
              replacement: request.replacement))
          continue
        }
        // Map the matched layout clusters back to UTF-16 offsets in the run.
        let runClusterIndices = layout.clusters.indices.filter {
          layout.clusters[$0].runIndex == runIndex
        }
        let joined = runClusterIndices.map { layout.clusters[$0].text }.joined()
        guard joined == fullRunText else {
          candidates.append(
            Candidate(
              id: id, pageID: pageID, pageIndex: pageIndex, lineIndex: match.lineIndex,
              match: match, matchedText: matchedText, runIndex: nil, runRange: nil,
              originalRunText: fullRunText,
              eligibility: .refused("Match cannot be mapped to one complete text run."),
              replacement: request.replacement))
          continue
        }
        let before = runClusterIndices.prefix {
          $0 < match.clusterRange.lowerBound
        }.map { layout.clusters[$0].text }.joined()
        let matched = clusters.map(\.text).joined()
        let start = (before as NSString).length
        let range = NSRange(location: start, length: (matched as NSString).length)
        let runLength = (fullRunText as NSString).length
        guard runLength == (joined as NSString).length,
          range.location >= 0, NSMaxRange(range) <= runLength
        else {
          candidates.append(
            Candidate(
              id: id, pageID: pageID, pageIndex: pageIndex, lineIndex: match.lineIndex,
              match: match, matchedText: matchedText, runIndex: nil, runRange: nil,
              originalRunText: fullRunText,
              eligibility: .refused("Match offsets do not align with the source text run."),
              replacement: request.replacement))
          continue
        }
        let eligibility: FindReplaceEligibility
        if clusters.contains(where: { $0.text.unicodeScalars.count > 1 }) {
          eligibility = .refused(
            "Match includes a ligature or combined glyph; edit the whole run or paragraph.")
        } else {
          eligibility = .eligible
        }
        candidates.append(
          Candidate(
            id: id, pageID: pageID, pageIndex: pageIndex, lineIndex: match.lineIndex,
            match: match, matchedText: matchedText, runIndex: runIndex, runRange: range,
            originalRunText: fullRunText, eligibility: eligibility,
            replacement: request.replacement))
      }
      addCrossLineRefusals(
        request: request, pageID: pageID, pageIndex: pageIndex, layout: layout,
        seen: &seenCrossLine, candidates: &candidates)
    }

    // Group single-run matches. Several occurrences in one run become one
    // replacement string, so repeated matches are handled atomically.
    var replacements: [PDFObjectID: [Int: String]] = [:]
    var grouped: [PDFObjectID: [Int: [Int]]] = [:]
    for index in candidates.indices where candidates[index].eligibility.isEligible {
      guard let runIndex = candidates[index].runIndex else { continue }
      grouped[candidates[index].pageID, default: [:]][runIndex, default: []].append(index)
    }
    for pageID in grouped.keys.sorted(by: { $0.number < $1.number }) {
      guard let runs = grouped[pageID] else { continue }
      for runIndex in runs.keys.sorted() {
        let indices = runs[runIndex] ?? []
        let ranges = indices.compactMap { candidates[$0].runRange }
        let descending = ranges.sorted { $0.location > $1.location }
        guard !hasOverlap(descending) else {
          markRefused(
            &candidates, indices: indices,
            reason: "Repeated matches overlap; replace a smaller region instead.")
          continue
        }
        let mutable = NSMutableString(string: candidates[indices[0]].originalRunText)
        for range in descending {
          mutable.replaceCharacters(in: range, with: candidates[indices[0]].replacement)
        }
        let newText = mutable as String
        let command = ReplaceTextCommand(
          pageID: pageID, runIndex: runIndex, replacement: newText,
          overflowPolicy: .allow)
        do {
          try command.validate(in: graph)
          let overflow = try command.previewOverflow(in: graph)
          guard !overflow.overlapsFollowingText else {
            markRefused(
              &candidates, indices: indices,
              reason: "Replacement would overlap following text; shorten it or replace a smaller region.")
            continue
          }
          replacements[pageID, default: [:]][runIndex] = newText
        } catch {
          markRefused(
            &candidates, indices: indices,
            reason: error.localizedDescription)
        }
      }
    }

    let matches = candidates.map { candidate in
      FindReplaceMatch(
        id: candidate.id, pageID: candidate.pageID, pageIndex: candidate.pageIndex,
        lineIndex: candidate.lineIndex, text: candidate.matchedText,
        replacement: candidate.replacement, bounds: candidate.match.bounds,
        eligibility: candidate.eligibility)
    }
    let eligible = matches.filter(\.eligibility.isEligible).count
    let refused = matches.count - eligible
    let command = replacements.isEmpty ? nil : FindReplaceCommand(replacements: replacements)
    return FindReplacePreview(
      matches: matches, eligibleCount: eligible, refusedCount: refused, command: command)
  }

  private static func markRefused(
    _ candidates: inout [Candidate], indices: [Int], reason: String
  ) {
    for index in indices { candidates[index].eligibility = .refused(reason) }
  }

  private static func hasOverlap(_ ranges: [NSRange]) -> Bool {
    let ascending = ranges.sorted { $0.location < $1.location }
    for (lhs, rhs) in zip(ascending, ascending.dropFirst()) {
      if NSMaxRange(lhs) > rhs.location { return true }
    }
    return false
  }

  private static func selectionAccepts(
    _ bounds: [[Double]], rects: [[Double]]?
  ) -> Bool {
    guard let rects else { return true }
    guard !rects.isEmpty else { return false }
    return bounds.contains { bound in
      rects.contains { rect in
        bound.count == 4 && rect.count == 4
          && bound[0] <= rect[2] && bound[2] >= rect[0]
          && bound[1] <= rect[3] && bound[3] >= rect[1]
      }
    }
  }

  /// TextSearch intentionally never crosses a line. Surface a refused entry
  /// when the same query can be found across adjacent lines, so the UI does
  /// not silently claim that no such match exists.
  private static func addCrossLineRefusals(
    request: FindReplaceRequest, pageID: PDFObjectID, pageIndex: Int,
    layout: PageTextLayout, seen: inout Set<String>, candidates: inout [Candidate]
  ) {
    guard request.scope != .selection else { return }
    let lineTexts = layout.lines.map { layout.text(in: $0) }
    guard lineTexts.count > 1 else { return }
    func scan(_ text: String, separator: String) {
      guard !separator.isEmpty else { return }
      let ns = text as NSString
      var boundary = 0
      var boundaries = Set<Int>()
      for (index, line) in lineTexts.enumerated() {
        boundary += (line as NSString).length
        boundaries.insert(boundary)
        if index + 1 < lineTexts.count { boundary += (separator as NSString).length }
      }
      var start = 0
      while start < ns.length {
        let range = ns.range(
          of: request.query,
          options: request.options.caseSensitive ? [] : [.caseInsensitive],
          range: NSRange(location: start, length: ns.length - start))
        guard range.location != NSNotFound else { break }
        let crosses = boundaries.contains { $0 > range.location && $0 < NSMaxRange(range) }
        if crosses {
          let matched = ns.substring(with: range)
          let key = "\(pageID.number)|\(pageIndex)|\(matched)"
          if seen.insert(key).inserted {
            candidates.append(
              Candidate(
                id: "cross-\(pageID.number)-\(pageIndex)-\(matched)", pageID: pageID,
                pageIndex: pageIndex, lineIndex: 0,
                match: TextMatch(clusterRange: 0..<0, lineIndex: 0, bounds: []),
                matchedText: matched, runIndex: nil, runRange: nil, originalRunText: "",
                eligibility: .refused(
                  "Match crosses a line boundary; edit the paragraph to replace it."),
                replacement: request.replacement))
          }
        }
        start = NSMaxRange(range)
      }
    }
    scan(lineTexts.joined(separator: "\n"), separator: "\n")
    scan(lineTexts.joined(separator: " "), separator: " ")
  }
}
