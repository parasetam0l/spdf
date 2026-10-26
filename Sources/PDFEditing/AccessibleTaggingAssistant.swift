import Foundation
import PDFCore

// A11Y-03: extended reviewed tagging suggestions. Suggestions are produced from
// visual analysis only. Nothing enters the document's reading order until a
// reviewer accepts it, and accepting a suggestion never claims accessibility
// conformance: the checklist and disclosure below stay explicit.

/// A11Y-03: one reviewable suggestion. This extends the earlier assistant with
/// lists, multicolumn paragraphs, captions and an explicit untagged-content
/// accounting.
public struct AccessibleTaggingSuggestion: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case heading(level: Int)
    case paragraph
    /// A paragraph inside one column of a multi-column page.
    case multicolumnParagraph(column: Int, columnCount: Int)
    /// A run of list items. Each item keeps the run indices of its own line so
    /// acceptance can build L/LI structure instead of one flat element.
    case list(ordered: Bool, itemRunIndices: [[Int]], itemSnippets: [String])
    /// A figure that needs reviewer-supplied alternate text.
    case figure(altText: String?)
    /// Text directly under (or above) an untagged figure.
    case caption
    case artifact(headerFooter: Bool)
  }

  public enum Origin: Sendable, Equatable {
    case visualOrderGuess
    /// The reviewer changed the proposed kind before accepting.
    case reviewerCorrection
  }

  public let id: UUID
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let kind: Kind
  /// Text runs (indices into the page run list) in visual order.
  public let runIndices: [Int]
  /// Item run groups for list suggestions; empty for other kinds.
  public let itemRunIndices: [[Int]]
  public let itemSnippets: [String]
  public let imageNames: [String]
  public let bounds: [Double]
  public let confidence: Double
  public let reason: String
  public let snippet: String
  public let origin: Origin

  public init(
    id: UUID = UUID(), pageIndex: Int, pageID: PDFObjectID, kind: Kind,
    runIndices: [Int], itemRunIndices: [[Int]] = [], itemSnippets: [String] = [],
    imageNames: [String] = [], bounds: [Double], confidence: Double, reason: String,
    snippet: String, origin: Origin = .visualOrderGuess
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.kind = kind
    self.runIndices = runIndices
    self.itemRunIndices = itemRunIndices
    self.itemSnippets = itemSnippets
    self.imageNames = imageNames
    self.bounds = bounds
    self.confidence = confidence
    self.reason = reason
    self.snippet = snippet
    self.origin = origin
  }

  public var proposedRole: String {
    switch kind {
    case .heading(let level): return "H" + String(min(max(level, 1), 6))
    case .paragraph: return "P"
    case .multicolumnParagraph: return "P"
    case .list: return "L"
    case .figure: return "Figure"
    case .caption: return "Caption"
    case .artifact: return "Artifact"
    }
  }

  public var label: String {
    switch kind {
    case .heading(let level): return "Heading " + String(level)
    case .paragraph: return "Paragraph"
    case .multicolumnParagraph(let column, let columnCount):
      return "Paragraph (column " + String(column + 1) + " of " + String(columnCount) + ")"
    case .list(let ordered, _, let items):
      return (ordered ? "Numbered list" : "Bulleted list") + " (" + String(items.count)
        + " item" + (items.count == 1 ? "" : "s") + ")"
    case .figure: return "Figure"
    case .caption: return "Caption"
    case .artifact(let headerFooter):
      return headerFooter ? "Artifact (running header/footer)" : "Artifact"
    }
  }

  /// A copy with a reviewer-corrected kind and the correction origin.
  public func corrected(to kind: Kind) -> Self {
    Self(
      id: id, pageIndex: pageIndex, pageID: pageID, kind: kind, runIndices: runIndices,
      itemRunIndices: itemRunIndices, itemSnippets: itemSnippets,
      imageNames: imageNames, bounds: bounds, confidence: confidence,
      reason: reason + " (kind corrected by the reviewer)", snippet: snippet,
      origin: .reviewerCorrection)
  }
}

/// A11Y-03: review state with acceptance, rejection and reviewer correction.
public struct AccessibleTaggingReview: Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case pending
    case accepted
    case rejected
  }

  public private(set) var suggestions: [AccessibleTaggingSuggestion]
  public private(set) var statuses: [UUID: Status]
  public private(set) var corrections: [UUID: AccessibleTaggingSuggestion.Kind]

  public init(suggestions: [AccessibleTaggingSuggestion]) {
    self.suggestions = suggestions
    self.statuses = [:]
    self.corrections = [:]
  }

  public func status(of id: UUID) -> Status { statuses[id] ?? .pending }
  public mutating func accept(_ id: UUID) { statuses[id] = .accepted }
  public mutating func reject(_ id: UUID) { statuses[id] = .rejected }
  public mutating func acceptAllPending() {
    for suggestion in suggestions where status(of: suggestion.id) == .pending {
      statuses[suggestion.id] = .accepted
    }
  }

  /// Reviewer correction: the proposed kind (or heading level, list kind) can
  /// be changed before accepting. The original suggestion is kept for evidence.
  public mutating func correct(_ id: UUID, to kind: AccessibleTaggingSuggestion.Kind) {
    corrections[id] = kind
  }

  public func effectiveKind(of suggestion: AccessibleTaggingSuggestion)
    -> AccessibleTaggingSuggestion.Kind
  {
    corrections[suggestion.id] ?? suggestion.kind
  }

  public func effectiveSuggestion(of suggestion: AccessibleTaggingSuggestion)
    -> AccessibleTaggingSuggestion
  {
    guard let corrected = corrections[suggestion.id] else { return suggestion }
    return suggestion.corrected(to: corrected)
  }

  public mutating func remove(_ ids: Set<UUID>) {
    suggestions.removeAll { ids.contains($0.id) }
    for id in ids {
      statuses.removeValue(forKey: id)
      corrections.removeValue(forKey: id)
    }
  }

  public var pending: [AccessibleTaggingSuggestion] {
    suggestions.filter { status(of: $0.id) == .pending }
  }
  public var accepted: [AccessibleTaggingSuggestion] {
    suggestions.filter { status(of: $0.id) == .accepted }
  }
  public var rejected: [AccessibleTaggingSuggestion] {
    suggestions.filter { status(of: $0.id) == .rejected }
  }
  public var correctedCount: Int { corrections.count }

  /// The acceptance command for an accepted (and possibly corrected)
  /// suggestion. Figures need reviewer alt text; list items need runs.
  public func command(
    for suggestion: AccessibleTaggingSuggestion, altText: String? = nil
  ) -> (any PDFEditCommand)? {
    let effective = effectiveSuggestion(of: suggestion)
    switch effective.kind {
    case .heading(let level):
      return ApplyTaggingSuggestionCommand(
        pageID: effective.pageID, role: PDFName("H" + String(min(max(level, 1), 6))),
        altText: nil, content: .text(runIndices: effective.runIndices))
    case .paragraph, .multicolumnParagraph:
      return ApplyTaggingSuggestionCommand(
        pageID: effective.pageID, role: PDFName("P"), altText: nil,
        content: .text(runIndices: effective.runIndices))
    case .caption:
      return ApplyTaggingSuggestionCommand(
        pageID: effective.pageID, role: PDFName("Caption"), altText: nil,
        content: .text(runIndices: effective.runIndices))
    case .figure(let proposed):
      let text = altText ?? proposed
      guard let text, !text.isEmpty else { return nil }
      return ApplyTaggingSuggestionCommand(
        pageID: effective.pageID, role: PDFName("Figure"), altText: text,
        content: .image(name: effective.imageNames.first ?? ""))
    case .artifact(let headerFooter):
      return ApplyTaggingSuggestionCommand(
        pageID: effective.pageID, role: PDFName("Artifact"), altText: nil,
        content: .artifact(runIndices: effective.runIndices, headerFooter: headerFooter))
    case .list(_, let itemRunIndices, _):
      guard !itemRunIndices.isEmpty else { return nil }
      return ApplyAccessibleListSuggestionCommand(
        pageID: effective.pageID, itemRunIndices: itemRunIndices)
    }
  }
}

/// A11Y-03: analysis result with the untagged-content accounting. The counts are
/// descriptive; nothing here is a conformance claim.
public struct AccessibleTaggingAnalysis: Sendable, Equatable {
  public let suggestions: [AccessibleTaggingSuggestion]
  public let pagesAnalyzed: Int
  /// Text blocks and figures with no marked content at all.
  public let untaggedTextBlocks: Int
  public let untaggedFigures: Int
  /// Blocks that already carry marked content and were therefore not suggested.
  public let taggedBlocksSkipped: Int
  /// Pages whose content carries no MCID-tagged marked content.
  public let pagesWithoutTaggedContent: Int
  public let notes: [String]

  public init(
    suggestions: [AccessibleTaggingSuggestion], pagesAnalyzed: Int,
    untaggedTextBlocks: Int, untaggedFigures: Int, taggedBlocksSkipped: Int,
    pagesWithoutTaggedContent: Int, notes: [String]
  ) {
    self.suggestions = suggestions
    self.pagesAnalyzed = pagesAnalyzed
    self.untaggedTextBlocks = untaggedTextBlocks
    self.untaggedFigures = untaggedFigures
    self.taggedBlocksSkipped = taggedBlocksSkipped
    self.pagesWithoutTaggedContent = pagesWithoutTaggedContent
    self.notes = notes
  }

  public var summary: String {
    var text = String(untaggedTextBlocks) + " untagged text block"
      + (untaggedTextBlocks == 1 ? "" : "s") + ", " + String(untaggedFigures)
      + " untagged figure" + (untaggedFigures == 1 ? "" : "s") + " on "
      + String(pagesAnalyzed) + " page" + (pagesAnalyzed == 1 ? "" : "s")
    if taggedBlocksSkipped > 0 {
      text += "; " + String(taggedBlocksSkipped) + " already-tagged block(s) skipped"
    }
    if pagesWithoutTaggedContent > 0 {
      text += "; " + String(pagesWithoutTaggedContent) + " page(s) have no tagged content"
    }
    return text + "."
  }
}

public enum AccessibleTaggingAssistant {
  public struct Limits: Sendable {
    public var maxPages: Int
    public var maxSuggestionsPerPage: Int
    public var maxBlocksPerPage: Int
    public init(maxPages: Int = 64, maxSuggestionsPerPage: Int = 200, maxBlocksPerPage: Int = 500) {
      self.maxPages = maxPages
      self.maxSuggestionsPerPage = maxSuggestionsPerPage
      self.maxBlocksPerPage = maxBlocksPerPage
    }
  }

  /// A11Y-03: the explicit non-conformance statement shown with every review.
  public static let conformanceDisclaimer =
    "Assisted suggestions are visual guesses approved by a reviewer. Accepting them does not "
    + "make a document accessible and is not an accessibility-conformance claim; reading order, "
    + "alternate-text quality, contrast and form behaviour still need human review."

  public static let reviewChecklist = [
    "Confirm each heading level against the document's visual outline.",
    "Confirm list items and their order; correct a bulleted/numbered guess explicitly.",
    "Confirm multicolumn reading order column by column, not row by row.",
    "Write meaningful alternate text for every figure and keep its caption tagged Caption.",
    "Treat running headers/footers as artifacts only when they are not content.",
    "Untagged content counts are descriptive; they are not a conformance score.",
  ]

  public static func analyze(
    pageIDs: [PDFObjectID], in graph: PDFGraph, limits: Limits = Limits()
  ) throws -> AccessibleTaggingAnalysis {
    var suggestions: [AccessibleTaggingSuggestion] = []
    var untaggedTextBlocks = 0
    var untaggedFigures = 0
    var taggedBlocksSkipped = 0
    var pagesWithoutTaggedContent = 0
    var bandTexts: [String: [AccessibleTaggingSuggestion]] = [:]

    for (pageIndex, pageID) in pageIDs.prefix(limits.maxPages).enumerated() {
      try Task.checkCancellation()
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      let pageBounds = pageBounds(of: page)
      let height = max(1, pageBounds[3] - pageBounds[1])
      let topBand = pageBounds[3] - 0.08 * height
      let bottomBand = pageBounds[1] + 0.08 * height

      let content = try PageContent.load(pageID: pageID, in: graph)
      let taggedRanges = StructureTaggingAssistant.markedRanges(in: content)
      let hasTaggedContent = taggedRanges.contains { $0.mcid != nil }
      if !hasTaggedContent { pagesWithoutTaggedContent += 1 }
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      let runs = try TextRunIndexer.runs(in: content, graph: graph)
      let bodySize = StructureTaggingAssistant.bodyFontSize(of: layout)
      let lines = layoutLines(of: layout, runs: runs)
      let columns = detectColumns(lines: lines, pageBounds: pageBounds)

      var pageSuggestions: [AccessibleTaggingSuggestion] = []
      let blocks = buildBlocks(lines: lines, columns: columns, maxBlocks: limits.maxBlocksPerPage)
      for block in blocks {
        try Task.checkCancellation()
        let isTagged = block.runIndices.contains { runIndex in
          guard runIndex < runs.count else { return false }
          return StructureTaggingAssistant.isTagged(
            instruction: runs[runIndex].instructionIndex, in: taggedRanges)
        }
        if isTagged {
          taggedBlocksSkipped += 1
          continue
        }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        untaggedTextBlocks += 1
        let centerY = (block.bounds[1] + block.bounds[3]) / 2
        if centerY > topBand || centerY < bottomBand {
          let suggestion = AccessibleTaggingSuggestion(
            pageIndex: pageIndex, pageID: pageID, kind: .artifact(headerFooter: true),
            runIndices: block.runIndices, bounds: block.bounds, confidence: 0.55,
            reason: "text inside the running header/footer band", snippet: text)
          pageSuggestions.append(suggestion)
          bandTexts[text, default: []].append(suggestion)
          continue
        }
        // Lists: two or more consecutive lines with a bullet/number marker.
        if let list = listSuggestion(
          block: block, pageIndex: pageIndex, pageID: pageID, bodySize: bodySize)
        {
          pageSuggestions.append(list)
          continue
        }
        if block.lineCount == 1, block.maxFontSize >= max(14, bodySize * 1.2),
          text.count <= 120
        {
          let ratio = block.maxFontSize / max(bodySize, 1)
          let level = ratio >= 1.8 ? 1 : (ratio >= 1.5 ? 2 : 3)
          pageSuggestions.append(
            AccessibleTaggingSuggestion(
              pageIndex: pageIndex, pageID: pageID, kind: .heading(level: level),
              runIndices: block.runIndices, bounds: block.bounds,
              confidence: min(0.95, 0.5 + 0.25 * (ratio - 1.2)),
              reason: "single line at " + formatted(block.maxFontSize) + " pt versus "
                + formatted(bodySize) + " pt body text",
              snippet: text))
        } else if let column = block.columnIndex, let count = block.columnCount, count > 1 {
          pageSuggestions.append(
            AccessibleTaggingSuggestion(
              pageIndex: pageIndex, pageID: pageID,
              kind: .multicolumnParagraph(column: column, columnCount: count),
              runIndices: block.runIndices, bounds: block.bounds, confidence: 0.6,
              reason: "paragraph in column " + String(column + 1) + " of " + String(count),
              snippet: text))
        } else {
          let bodyLike = block.maxFontSize <= bodySize * 1.2
          pageSuggestions.append(
            AccessibleTaggingSuggestion(
              pageIndex: pageIndex, pageID: pageID, kind: .paragraph,
              runIndices: block.runIndices, bounds: block.bounds,
              confidence: bodyLike ? (block.lineCount > 1 ? 0.7 : 0.6) : 0.5,
              reason: "text block of " + String(block.lineCount) + " line"
                + (block.lineCount == 1 ? "" : "s") + " at " + formatted(block.maxFontSize)
                + " pt",
              snippet: text))
        }
      }

      // Figures without marked content, plus captions directly underneath them.
      let placements = try StructureTaggingAssistant.imagePlacements(
        in: content, graph: graph)
      var figureBounds: [[Double]] = []
      for placement in placements {
        try Task.checkCancellation()
        if StructureTaggingAssistant.isTagged(
          instruction: placement.instructionIndex, in: taggedRanges)
        { continue }
        untaggedFigures += 1
        figureBounds.append(placement.bounds)
        pageSuggestions.append(
          AccessibleTaggingSuggestion(
            pageIndex: pageIndex, pageID: pageID, kind: .figure(altText: nil),
            runIndices: [], imageNames: [placement.name], bounds: placement.bounds,
            confidence: 0.5, reason: "image without marked content or alternate text",
            snippet: placement.name))
      }
      for block in blocks where !block.runIndices.isEmpty {
        guard let captionText = captionText(
          below: figureBounds, block: block, bodySize: bodySize)
        else { continue }
        // A caption candidate was first suggested as a paragraph; replace that
        // weaker guess instead of listing the same content twice.
        if let index = pageSuggestions.firstIndex(where: { suggestion in
          suggestion.pageID == pageID && suggestion.runIndices == block.runIndices
            && !block.runIndices.isEmpty
        }) {
          pageSuggestions.remove(at: index)
        }
        pageSuggestions.append(
          AccessibleTaggingSuggestion(
            pageIndex: pageIndex, pageID: pageID, kind: .caption,
            runIndices: block.runIndices, bounds: block.bounds, confidence: 0.55,
            reason: "short text directly under an untagged figure", snippet: captionText))
      }

      suggestions.append(
        contentsOf: pageSuggestions.sorted { $0.bounds[3] > $1.bounds[3] }
          .prefix(limits.maxSuggestionsPerPage))
    }

    // Repeated running headers/footers across pages are strong artifact
    // candidates; single-page band text keeps the weaker artifact suggestion.
    var crossPage: [AccessibleTaggingSuggestion] = []
    for (_, occurrences) in bandTexts where occurrenceCount(occurrences) >= 2 {
      for suggestion in occurrences {
        crossPage.append(
          AccessibleTaggingSuggestion(
            pageIndex: suggestion.pageIndex, pageID: suggestion.pageID,
            kind: .artifact(headerFooter: true), runIndices: suggestion.runIndices,
            bounds: suggestion.bounds,
            confidence: min(0.9, 0.5 + 0.1 * Double(min(occurrences.count, 4))),
            reason: "same text repeats at the same position across pages",
            snippet: suggestion.snippet))
      }
    }
    if !crossPage.isEmpty {
      let keys = Set(crossPage.map { "\($0.pageID.number)/\($0.snippet)" })
      suggestions.removeAll { suggestion in
        guard case .artifact = suggestion.kind else { return false }
        return keys.contains("\(suggestion.pageID.number)/\(suggestion.snippet)")
      }
      suggestions.append(contentsOf: crossPage)
    }
    suggestions.sort {
      $0.pageIndex != $1.pageIndex ? $0.pageIndex < $1.pageIndex : $0.bounds[3] > $1.bounds[3]
    }

    var notes = [
      conformanceDisclaimer,
      "Untagged counts are descriptive: some content may be decorative and some may need "
        + "manual review instead of tagging.",
    ]
    if pagesWithoutTaggedContent > 0 {
      notes.append(
        String(pagesWithoutTaggedContent) + " page(s) have no tagged content at all; review "
          + "reading order after accepting suggestions.")
    }
    return AccessibleTaggingAnalysis(
      suggestions: suggestions, pagesAnalyzed: min(pageIDs.count, limits.maxPages),
      untaggedTextBlocks: untaggedTextBlocks, untaggedFigures: untaggedFigures,
      taggedBlocksSkipped: taggedBlocksSkipped,
      pagesWithoutTaggedContent: pagesWithoutTaggedContent, notes: notes)
  }

  // MARK: - Layout blocks

  struct Line {
    let baseline: Double
    let maxFontSize: Double
    let runIndices: [Int]
    let bounds: [Double]
    let text: String
  }

  struct Block {
    let lines: [Line]
    var bounds: [Double] = [0, 0, 0, 0]
    var runIndices: [Int] = []
    var text: String = ""
    var maxFontSize: Double = 0
    var columnIndex: Int?
    var columnCount: Int?
    var lineCount: Int { lines.count }
  }

  static func layoutLines(of layout: PageTextLayout, runs: [TextRun]) -> [Line] {
    _ = runs
    var lines: [Line] = []
    for range in layout.lines {
      let clusters = range.map { layout.clusters[$0] }.filter { !$0.isWhitespace }
      guard !clusters.isEmpty else { continue }
      let all = range.map { layout.clusters[$0] }
      var bounds = [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                    -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude]
      var runIndices: [Int] = []
      for cluster in clusters {
        bounds[0] = min(bounds[0], cluster.bounds[0])
        bounds[1] = min(bounds[1], cluster.bounds[1])
        bounds[2] = max(bounds[2], cluster.bounds[2])
        bounds[3] = max(bounds[3], cluster.bounds[3])
        if runIndices.last != cluster.runIndex { runIndices.append(cluster.runIndex) }
      }
      lines.append(
        Line(
          baseline: clusters.map { $0.origin[1] }.reduce(0, +) / Double(clusters.count),
          maxFontSize: clusters.map(\.fontSize).max() ?? 12, runIndices: runIndices,
          bounds: bounds,
          text: all.map(\.text).joined().trimmingCharacters(in: .whitespaces)))
    }
    lines.sort { $0.baseline > $1.baseline }
    return lines
  }

  /// Detect two balanced columns from a vertical gutter in line bounds.
  static func detectColumns(lines: [Line], pageBounds: [Double]) -> [ClosedRange<Double>] {
    guard lines.count >= 6 else { return [] }
    let width = pageBounds[2] - pageBounds[0]
    guard width > 0 else { return [] }
    let origins = lines.map { $0.bounds[0] }.sorted()
    var bestGap = 0.0
    var boundary = 0.0
    if origins.count >= 2 {
      for index in 1..<origins.count {
        let gap = origins[index] - origins[index - 1]
        if gap > bestGap {
          bestGap = gap
          boundary = (origins[index - 1] + origins[index]) / 2
        }
      }
    }
    guard bestGap > width * 0.2 else { return [] }
    let left = lines.filter { $0.bounds[0] < boundary }
    let right = lines.filter { $0.bounds[0] >= boundary }
    guard left.count >= 2, right.count >= 2 else { return [] }
    // A real two-column page has a clean gutter: no line may start just left of
    // the boundary while ending far past it (that would be a full-width line).
    let straddlers = lines.filter { $0.bounds[2] > boundary && $0.bounds[0] < boundary }
    guard straddlers.count <= max(1, lines.count / 10) else { return [] }
    return [pageBounds[0]...boundary, boundary...pageBounds[2]]
  }

  static func buildBlocks(
    lines: [Line], columns: [ClosedRange<Double>], maxBlocks: Int
  ) -> [Block] {
    var result: [Block] = []
    func flush(_ current: inout [Line], _ column: Int?, _ count: Int?) {
      guard !current.isEmpty else { return }
      var block = Block(lines: current, columnIndex: column, columnCount: count)
      var bounds = [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                    -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude]
      var indices: [Int] = []
      var text = ""
      for line in current {
        bounds[0] = min(bounds[0], line.bounds[0])
        bounds[1] = min(bounds[1], line.bounds[1])
        bounds[2] = max(bounds[2], line.bounds[2])
        bounds[3] = max(bounds[3], line.bounds[3])
        for index in line.runIndices where !indices.contains(index) { indices.append(index) }
        text += text.isEmpty ? line.text : "\n" + line.text
        block.maxFontSize = max(block.maxFontSize, line.maxFontSize)
      }
      block.bounds = bounds
      block.runIndices = indices
      block.text = text
      result.append(block)
      current = []
    }
    if columns.count <= 1 {
      var current: [Line] = []
      for line in lines {
        if let previous = current.last {
          let gap = previous.baseline - line.baseline
          if gap > 1.6 * max(previous.maxFontSize, line.maxFontSize) { flush(&current, nil, nil) }
        }
        current.append(line)
        if result.count >= maxBlocks { current = []; break }
      }
      flush(&current, nil, nil)
      return result
    }
    for (column, range) in columns.enumerated() {
      let columnLines = lines.filter { range.contains(($0.bounds[0] + $0.bounds[2]) / 2) }
        .sorted { $0.baseline > $1.baseline }
      var current: [Line] = []
      for line in columnLines {
        if let previous = current.last {
          let gap = previous.baseline - line.baseline
          if gap > 1.6 * max(previous.maxFontSize, line.maxFontSize) {
            flush(&current, column, columns.count)
          }
        }
        current.append(line)
        if result.count >= maxBlocks { current = []; break }
      }
      flush(&current, column, columns.count)
    }
    return result
  }

  static func listSuggestion(
    block: Block, pageIndex: Int, pageID: PDFObjectID, bodySize: Double
  ) -> AccessibleTaggingSuggestion? {
    guard block.lines.count >= 2 else { return nil }
    var ordered = 0
    var unordered = 0
    var itemRuns: [[Int]] = []
    var snippets: [String] = []
    for line in block.lines {
      let text = line.text.trimmingCharacters(in: .whitespaces)
      guard let marker = listMarker(of: text) else { return nil }
      if marker.isNumbered { ordered += 1 } else { unordered += 1 }
      itemRuns.append(line.runIndices)
      snippets.append(text)
    }
    guard ordered + unordered >= 2 else { return nil }
    let isOrdered = ordered > unordered
    return AccessibleTaggingSuggestion(
      pageIndex: pageIndex, pageID: pageID,
      kind: .list(ordered: isOrdered, itemRunIndices: itemRuns, itemSnippets: snippets),
      runIndices: block.runIndices, itemRunIndices: itemRuns, itemSnippets: snippets,
      bounds: block.bounds, confidence: 0.65,
      reason: "consecutive lines with " + (isOrdered ? "numbered" : "bulleted")
        + " markers at body size " + formatted(bodySize) + " pt",
      snippet: block.text)
  }

  struct ListMarker {
    let isNumbered: Bool
  }

  static func listMarker(of text: String) -> ListMarker? {
    guard !text.isEmpty else { return nil }
    let scalars = Array(text.unicodeScalars)
    guard let first = scalars.first else { return nil }
    if first.value == 0x2022 || first.value == 0x25AA || first.value == 0x25CF
      || first.value == 0x25E6 || first.value == 0x2013 || first.value == 0x2014
      || first.value == 0x002A || first.value == 0x002D
    {
      let rest = String(String.UnicodeScalarView(scalars.dropFirst()))
        .trimmingCharacters(in: .whitespaces)
      return rest.isEmpty ? nil : ListMarker(isNumbered: false)
    }
    var index = 0
    while index < scalars.count, scalars[index].properties.numericValue != nil { index += 1 }
    guard index > 0, index < scalars.count else { return nil }
    let terminator = scalars[index]
    guard terminator.value == 0x002E || terminator.value == 0x0029 else { return nil }
    let rest = String(String.UnicodeScalarView(scalars.dropFirst(index + 1)))
      .trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : ListMarker(isNumbered: true)
  }

  static func captionText(
    below figures: [[Double]], block: Block, bodySize: Double
  ) -> String? {
    guard block.lines.count == 1, block.maxFontSize <= bodySize * 1.15 else { return nil }
    let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 160 else { return nil }
    // Some fonts expose no advances, so a run's right edge can equal its left
    // edge. Estimate the painted width for the horizontal overlap test.
    let estimatedWidth = max(
      block.bounds[2] - block.bounds[0],
      Double(text.count) * 0.5 * max(block.maxFontSize, 1))
    let right = block.bounds[0] + estimatedWidth
    for figure in figures {
      let gap = block.bounds[3] - figure[1]
      let overlaps = block.bounds[0] < figure[2] && right > figure[0]
      if overlaps, gap >= -4, gap <= 40 { return text }
    }
    return nil
  }

  static func formatted(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }

  static func pageBounds(of page: [PDFName: PDFValue]) -> [Double] {
    if case .array(let box)? = page[PDFName("MediaBox")], box.count == 4 {
      let values: [Double] = box.compactMap { value in
        switch value {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
      if values.count == 4 { return values }
    }
    return [0, 0, 612, 792]
  }

  static func occurrenceCount(_ suggestions: [AccessibleTaggingSuggestion]) -> Int {
    Set(suggestions.map(\.pageID)).count
  }
}
