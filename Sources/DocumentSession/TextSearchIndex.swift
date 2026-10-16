import Foundation
import PDFCore
import PDFEditing

/// P16-019/P16-020/P16-021: a lazy, revision-aware text search index.
/// Per-page layouts are built on demand (never when the index is created),
/// cached per page, and invalidated exactly for the pages each committed
/// mutation reported — the session's bounded change history answers "what
/// changed since revision R" even across several edits. Matches carry their
/// provenance: text drawn by a generated OCR layer is `recognizedText`,
/// everything else is `documentText`.
public final class TextSearchIndex: @unchecked Sendable {
  public enum Provenance: String, Sendable, Equatable {
    case documentText
    case recognizedText
  }

  public struct Match: Sendable, Equatable {
    public let pageID: PDFObjectID
    public let pageIndex: Int
    public let clusterRange: Range<Int>
    public let bounds: [[Double]]
    public let provenance: Provenance
  }

  public struct Statistics: Sendable, Equatable {
    public let cachedPages: Int
    /// Layouts built since the index was created (the laziness measure).
    public let builtPages: Int
    public let cacheHits: Int
    public let invalidatedPages: Int
  }

  private struct Entry {
    let layout: PageTextLayout
    /// Run indices whose source stream belongs to a generated OCR layer.
    let recognizedRuns: Set<Int>
    /// P16-021: the generated layer's own text, when the page has one.
    let recognizedText: String?
  }

  private let session: DocumentEditSession
  private let limits: PDFLimits
  private let lock = NSLock()
  private var entries: [PDFObjectID: Entry] = [:]
  private var seenRevision: UInt64?
  private var builtPages = 0
  private var cacheHits = 0
  private var invalidatedPages = 0

  public init(session: DocumentEditSession, limits: PDFLimits = PDFLimits()) {
    self.session = session
    self.limits = limits
  }

  /// Search every page in document order. Pages are laid out on first use
  /// and reused until a committed change touches them; `Task` cancellation
  /// stops the scan with partial results delivered so far.
  public func search(
    _ query: String, options: TextSearchOptions = TextSearchOptions(),
    onMatch: ((Match) -> Bool)? = nil
  ) throws -> [Match] {
    var results: [Match] = []
    guard !query.isEmpty else { return results }
    synchronize()
    let pageIDs = session.pageIDs
    guard let graph = session.currentGraph else { return results }
    for (index, pageID) in pageIDs.enumerated() {
      if Task.isCancelled { break }
      let entry = try entry(for: pageID, in: graph)
      for match in TextSearch.search(query: query, in: entry.layout, options: options) {
        guard match.clusterRange.lowerBound < entry.layout.clusters.count else { continue }
        let runIndex = entry.layout.clusters[match.clusterRange.lowerBound].runIndex
        // CID indexing can now see generated OCR glyphs too. Keep layer
        // results on the provenance-aware path below instead of duplicating
        // them as geometry-owned document text.
        if entry.recognizedRuns.contains(runIndex) { continue }
        let result = Match(
          pageID: pageID, pageIndex: index, clusterRange: match.clusterRange,
          bounds: match.bounds,
          provenance: entry.recognizedRuns.contains(runIndex)
            ? .recognizedText : .documentText)
        results.append(result)
        // P16-018: incremental delivery — a consumer can stop the scan and
        // keep the partial results.
        if let onMatch, onMatch(result) == false { return results }
      }
      // P16-021: a layer hit is reported with its provenance
      // and no owned geometry; the independent renderer supplies highlights.
      if let layerText = entry.recognizedText,
        Self.matches(query: query, in: layerText, options: options)
      {
        let result = Match(
          pageID: pageID, pageIndex: index, clusterRange: 0..<0, bounds: [],
          provenance: .recognizedText)
        results.append(result)
        if let onMatch, onMatch(result) == false { return results }
      }
    }
    return results
  }

  /// Case/diacritic folding consistent with `TextSearch` options.
  private static func matches(
    query: String, in text: String, options: TextSearchOptions
  ) -> Bool {
    var folding: String.CompareOptions = []
    if !options.caseSensitive { folding.insert(.caseInsensitive) }
    if options.diacriticInsensitive { folding.insert(.diacriticInsensitive) }
    let needle = query.folding(options: folding, locale: Locale(identifier: "en_US_POSIX"))
    let haystack = text.folding(options: folding, locale: Locale(identifier: "en_US_POSIX"))
    return haystack.contains(needle)
  }

  public func statistics() -> Statistics {
    lock.withLock {
      Statistics(
        cachedPages: entries.count, builtPages: builtPages, cacheHits: cacheHits,
        invalidatedPages: invalidatedPages)
    }
  }

  /// Drop everything (for example when the document is closed).
  public func invalidateAll() {
    lock.withLock {
      invalidatedPages += entries.count
      entries.removeAll()
      seenRevision = nil
    }
  }

  // MARK: - Internals

  /// P16-020: drop only the caches the session reports as changed since the
  /// last synchronization.
  private func synchronize() {
    let current = session.documentRevision
    lock.lock()
    defer { lock.unlock() }
    guard let seen = seenRevision else {
      seenRevision = current
      return
    }
    guard seen != current else { return }
    let history = session.changes(since: seen)
    seenRevision = history.revision
    if let changed = history.changedPageIDs {
      for pageID in changed {
        if entries.removeValue(forKey: pageID) != nil { invalidatedPages += 1 }
      }
    } else {
      // Unknown history or an all-pages change: invalidate everything.
      invalidatedPages += entries.count
      entries.removeAll()
    }
  }

  private func entry(for pageID: PDFObjectID, in graph: PDFGraph) throws -> Entry {
    lock.lock()
    if let cached = entries[pageID] {
      cacheHits += 1
      lock.unlock()
      return cached
    }
    lock.unlock()
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    let recognized = Self.recognizedRuns(pageID: pageID, in: graph, limits: limits)
    let layerText = TextProvenance.recognizedLayerText(pageID: pageID, in: graph, limits: limits)
    let entry = Entry(layout: layout, recognizedRuns: recognized, recognizedText: layerText)
    lock.lock()
    entries[pageID] = entry
    builtPages += 1
    lock.unlock()
    return entry
  }

  /// P16-021: which runs came from a generated OCR layer (the provenance
  /// helper lives in PDFEditing where the run/stream mapping is available).
  private static func recognizedRuns(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits
  ) -> Set<Int> {
    TextProvenance.recognizedRunIndices(pageID: pageID, in: graph, limits: limits)
  }
}
