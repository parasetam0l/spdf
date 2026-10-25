import CoreGraphics
import Foundation
import PDFCore
import PDFEditing

/// OCR-03: one reviewable recognized word with its confidence, provenance and
/// page-space bounds. Words are suspects when recognition confidence is below
/// the chosen threshold; a correction replaces the word token in the committed
/// searchable layer without moving or resizing the recognized line.
public struct OCRReviewWord: Sendable, Equatable, Identifiable {
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let lineIndex: Int
  public let wordIndex: Int
  public let text: String
  public let rect: [Double]
  public let confidence: Double?
  public let provenance: OCRTextProvenance
  public let usedFastFallback: Bool

  public init(
    pageID: PDFObjectID, pageIndex: Int, lineIndex: Int, wordIndex: Int, text: String,
    rect: [Double], confidence: Double?, provenance: OCRTextProvenance,
    usedFastFallback: Bool
  ) {
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.lineIndex = lineIndex
    self.wordIndex = wordIndex
    self.text = text
    self.rect = rect
    self.confidence = confidence
    self.provenance = provenance
    self.usedFastFallback = usedFastFallback
  }

  public var id: String { "\(pageIndex):\(lineIndex):\(wordIndex)" }
  public var confidenceLabel: String {
    guard let confidence else { return "unknown" }
    return String(format: "%.0f%%", confidence * 100)
  }
}

/// OCR-03: one page of recognition input for the review queue.
public struct OCRReviewPageSeed: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let lines: [SearchableTextLine]
  /// Per-line word boxes, empty when the recognizer supplied none.
  public let wordBoxes: [[[Double]]]
  public let usedFastFallback: Bool

  public init(
    pageID: PDFObjectID, pageIndex: Int, lines: [SearchableTextLine],
    wordBoxes: [[[Double]]] = [], usedFastFallback: Bool = false
  ) {
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.lines = lines
    self.wordBoxes = wordBoxes
    self.usedFastFallback = usedFastFallback
  }
}

public struct OCRReviewPageSummary: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let lineCount: Int
  public let suspectCount: Int
}

/// OCR-03: the page seeds for a review run, built from the OCR job results.
public enum OCRReviewBuilder {
  public static func seeds(
    from results: [OCRPageResult], pageIDs: [PDFObjectID]
  ) -> [OCRReviewPageSeed] {
    results.compactMap { result -> OCRReviewPageSeed? in
      guard pageIDs.indices.contains(result.pageIndex), !result.lines.isEmpty else {
        return nil
      }
      let lines = result.lines.map {
        SearchableTextLine(text: $0.text, rect: $0.rect, confidence: $0.confidence)
      }
      let wordBoxes = result.lines.map { line -> [[Double]] in
        let tokens = OCRReviewTokenizer.words(line.text)
        guard line.words.count == tokens.count else { return [] }
        return line.words.map(\.rect)
      }
      return OCRReviewPageSeed(
        pageID: pageIDs[result.pageIndex], pageIndex: result.pageIndex, lines: lines,
        wordBoxes: wordBoxes, usedFastFallback: result.usedFastFallback)
    }.sorted { $0.pageIndex < $1.pageIndex }
  }

  /// OCR-01 disclosure survives into the review metadata.
  public static func quality(
    level: OCRRecognitionLevel, results: [OCRPageResult]
  ) -> String {
    results.contains(where: \.usedFastFallback) ? "fastFallback" : level.rawValue
  }

  /// A review record suitable for RecordOCRReviewCommand, so a finished
  /// recognition run can be reviewed immediately or after reopening.
  public static func record(
    for seed: OCRReviewPageSeed, threshold: Double, quality: String
  ) -> OCRReviewPageRecord {
    OCRReviewPageRecord.build(
      lines: seed.lines, threshold: threshold, quality: quality,
      wordBoxes: seed.wordBoxes.isEmpty ? nil : seed.wordBoxes)
  }
}

/// OCR-03: the keyboard review queue and correction staging for one document.
/// Nothing mutates the PDF until the caller applies the commands through the
/// edit session; staged corrections are kept separate from committed ones.
public struct OCRReviewSession: Sendable {
  public let threshold: Double
  public let quality: String
  private let pageOrder: [(pageID: PDFObjectID, pageIndex: Int)]
  private var records: [PDFObjectID: OCRReviewPageRecord]
  private var suspects: [OCRReviewWord]
  private var currentIndex: Int?
  private var staged: [PDFObjectID: [OCRWordCorrection]]
  private var stagedWords: [(pageID: PDFObjectID, word: OCRReviewWord, correction: OCRWordCorrection)]
  private var skippedIDs: Set<String>
  /// Corrections already committed in previous review runs.
  public private(set) var appliedCorrectionCount: Int
  public let pages: [OCRReviewPageSummary]

  private init(
    threshold: Double, quality: String,
    pageOrder: [(pageID: PDFObjectID, pageIndex: Int)],
    records: [PDFObjectID: OCRReviewPageRecord], suspects: [OCRReviewWord],
    skippedIDs: Set<String>, appliedCorrectionCount: Int
  ) {
    self.threshold = threshold
    self.quality = quality
    self.pageOrder = pageOrder
    self.records = records
    self.suspects = suspects
    self.currentIndex = suspects.isEmpty ? nil : 0
    self.staged = [:]
    self.stagedWords = []
    self.skippedIDs = skippedIDs
    self.appliedCorrectionCount = appliedCorrectionCount
    self.pages = pageOrder.map { entry in
      OCRReviewPageSummary(
        pageID: entry.pageID, pageIndex: entry.pageIndex,
        lineCount: records[entry.pageID]?.lines.count ?? 0,
        suspectCount: suspects.filter { $0.pageID == entry.pageID }.count)
    }
  }

  /// Build a fresh review from recognition results.
  public static func build(
    seeds: [OCRReviewPageSeed], threshold: Double, quality: String
  ) throws -> OCRReviewSession {
    guard threshold.isFinite, (0...1).contains(threshold) else {
      throw PDFError(.malformed, "The OCR review confidence threshold must be within 0...1")
    }
    guard !seeds.isEmpty else {
      throw PDFError(.unsupported, "No recognized lines are available to review")
    }
    var pageOrder: [(pageID: PDFObjectID, pageIndex: Int)] = []
    var records: [PDFObjectID: OCRReviewPageRecord] = [:]
    var suspects: [OCRReviewWord] = []
    for seed in seeds.sorted(by: { $0.pageIndex < $1.pageIndex }) {
      let record = try OCRReviewBuilder.record(
        for: seed, threshold: threshold, quality: quality).validated()
      records[seed.pageID] = record
      pageOrder.append((seed.pageID, seed.pageIndex))
      for word in record.suspectWords {
        suspects.append(
          OCRReviewWord(
            pageID: seed.pageID, pageIndex: seed.pageIndex,
            lineIndex: word.lineIndex, wordIndex: word.wordIndex, text: word.text,
            rect: word.rect, confidence: word.confidence,
            provenance: OCRConfidence.classify(
              isGenerated: true, confidence: word.confidence, threshold: threshold),
            usedFastFallback: seed.usedFastFallback))
      }
    }
    return OCRReviewSession(
      threshold: threshold, quality: quality, pageOrder: pageOrder, records: records,
      suspects: suspects, skippedIDs: [], appliedCorrectionCount: 0)
  }

  /// Reload a review from the pages' persisted review records. Nil when no page
  /// carries a record or the records disagree on their settings.
  public static func load(
    pageIDs: [PDFObjectID], in graph: PDFGraph
  ) -> OCRReviewSession? {
    var pageOrder: [(pageID: PDFObjectID, pageIndex: Int)] = []
    var records: [PDFObjectID: OCRReviewPageRecord] = [:]
    var threshold: Double?
    var quality: String?
    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard let record = OCRReviewStore.read(pageID: pageID, in: graph) else { continue }
      if let threshold, abs(threshold - record.threshold) > 1e-9 { return nil }
      if let quality, quality != record.quality { return nil }
      threshold = record.threshold
      quality = record.quality
      records[pageID] = record
      pageOrder.append((pageID, pageIndex))
    }
    guard !records.isEmpty, let threshold, let quality else { return nil }
    var suspects: [OCRReviewWord] = []
    var applied = 0
    for entry in pageOrder {
      guard let record = records[entry.pageID] else { continue }
      applied += record.corrections.count
      for word in record.suspectWords {
        suspects.append(
          OCRReviewWord(
            pageID: entry.pageID, pageIndex: entry.pageIndex,
            lineIndex: word.lineIndex, wordIndex: word.wordIndex, text: word.text,
            rect: word.rect, confidence: word.confidence,
            provenance: OCRConfidence.classify(
              isGenerated: true, confidence: word.confidence, threshold: threshold),
            usedFastFallback: record.quality == "fastFallback"))
      }
    }
    return OCRReviewSession(
      threshold: threshold, quality: quality, pageOrder: pageOrder, records: records,
      suspects: suspects, skippedIDs: [], appliedCorrectionCount: applied)
  }

  // MARK: - Queue state

  public var remainingSuspectCount: Int { suspects.count }
  public var current: OCRReviewWord? {
    guard let currentIndex, suspects.indices.contains(currentIndex) else { return nil }
    return suspects[currentIndex]
  }
  public var currentPositionLabel: String {
    guard let currentIndex, !suspects.isEmpty else { return "No suspect words" }
    return "\(currentIndex + 1) of \(suspects.count)"
  }
  public var hasStagedCorrections: Bool { !stagedWords.isEmpty }
  public var stagedCorrectionCount: Int { stagedWords.count }
  public var appliedCorrections: Int { appliedCorrectionCount }
  public var skippedCount: Int { skippedIDs.count }

  public func suspects(onPageIndex pageIndex: Int) -> [OCRReviewWord] {
    suspects.filter { $0.pageIndex == pageIndex }
  }

  public func pageSummary(pageIndex: Int) -> OCRReviewPageSummary? {
    pages.first { $0.pageIndex == pageIndex }
  }

  private mutating func moveToFirstSuspect() -> OCRReviewWord? {
    currentIndex = suspects.isEmpty ? nil : 0
    return current
  }

  /// Select the first remaining suspect.
  @discardableResult
  public mutating func selectFirst() -> OCRReviewWord? { moveToFirstSuspect() }

  /// Move to the next remaining suspect. Nil when the queue is at its end.
  @discardableResult
  public mutating func selectNext() -> OCRReviewWord? {
    guard !suspects.isEmpty else {
      currentIndex = nil
      return nil
    }
    guard let currentIndex else { return moveToFirstSuspect() }
    let next = currentIndex + 1
    guard next < suspects.count else { return self.current }
    self.currentIndex = next
    return current
  }

  /// Move to the previous remaining suspect. Nil when already at the start.
  @discardableResult
  public mutating func selectPrevious() -> OCRReviewWord? {
    guard let currentIndex else { return moveToFirstSuspect() }
    let previous = currentIndex - 1
    guard previous >= 0 else { return current }
    self.currentIndex = previous
    return current
  }

  @discardableResult
  public mutating func select(id: String) -> OCRReviewWord? {
    guard let index = suspects.firstIndex(where: { $0.id == id }) else { return nil }
    currentIndex = index
    return suspects[index]
  }

  /// Jump to the first remaining suspect on one page.
  @discardableResult
  public mutating func jumpToPage(_ pageIndex: Int) -> OCRReviewWord? {
    guard let index = suspects.firstIndex(where: { $0.pageIndex == pageIndex }) else {
      return nil
    }
    currentIndex = index
    return suspects[index]
  }

  /// Skip the current suspect without changing the document. Skipped words stay
  /// in the layer untouched and are not asked about again in this session.
  @discardableResult
  public mutating func skipCurrent() -> OCRReviewWord? {
    guard let currentIndex, suspects.indices.contains(currentIndex) else { return nil }
    let word = suspects.remove(at: currentIndex)
    skippedIDs.insert(word.id)
    self.currentIndex =
      suspects.isEmpty ? nil : min(currentIndex, suspects.count - 1)
    return word
  }

  // MARK: - Corrections

  /// Stage a correction for the current suspect word. The queue advances to the
  /// next suspect. Nothing is written until commands() is committed.
  @discardableResult
  public mutating func stageCorrection(_ replacement: String) throws -> OCRReviewWord {
    guard let currentIndex, suspects.indices.contains(currentIndex) else {
      throw PDFError(.unsupported, "No OCR suspect word is selected")
    }
    let word = suspects[currentIndex]
    let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != word.text else {
      throw PDFError(.malformed, "The replacement matches the recognized word")
    }
    let correction = OCRWordCorrection(
      lineIndex: word.lineIndex, wordIndex: word.wordIndex,
      originalWord: word.text, replacement: trimmed)
    try OCRReviewTokenizer.validateCorrection(correction)
    staged[word.pageID, default: []].removeAll {
      $0.lineIndex == correction.lineIndex && $0.wordIndex == correction.wordIndex
    }
    staged[word.pageID, default: []].append(correction)
    stagedWords.append((word.pageID, word, correction))
    if var record = records[word.pageID] {
      let remaining = record.suspectWords.filter {
        !($0.lineIndex == word.lineIndex && $0.wordIndex == word.wordIndex)
      }
      record = record.replacingSuspects(remaining)
      records[word.pageID] = record
    }
    suspects.remove(at: currentIndex)
    self.currentIndex = suspects.isEmpty ? nil : min(currentIndex, suspects.count - 1)
    return word
  }

  /// Undo the most recently staged correction and reselect its word.
  @discardableResult
  public mutating func undoLastStagedCorrection() -> OCRReviewWord? {
    guard let last = stagedWords.popLast() else { return nil }
    staged[last.pageID, default: []].removeAll {
      $0.lineIndex == last.correction.lineIndex && $0.wordIndex == last.correction.wordIndex
    }
    if staged[last.pageID]?.isEmpty == true { staged[last.pageID] = nil }
    if var record = records[last.pageID] {
      var words = record.suspectWords
      words.append(
        OCRReviewWordRecord(
          lineIndex: last.word.lineIndex, wordIndex: last.word.wordIndex,
          text: last.word.text, rect: last.word.rect,
          confidence: last.word.confidence ?? 0))
      words.sort {
        if $0.lineIndex != $1.lineIndex { return $0.lineIndex < $1.lineIndex }
        return $0.wordIndex < $1.wordIndex
      }
      record = record.replacingSuspects(words)
      records[last.pageID] = record
    }
    let word = last.word
    let insertion = suspects.firstIndex {
      ($0.pageIndex, $0.lineIndex, $0.wordIndex)
        > (word.pageIndex, word.lineIndex, word.wordIndex)
    } ?? suspects.count
    suspects.insert(word, at: insertion)
    currentIndex = insertion
    return word
  }

  /// The commands that persist every staged correction. Empty when nothing is
  /// staged; the caller applies them as one transaction (one undo step).
  public func commands() throws -> [ApplyOCRCorrectionsCommand] {
    var commands: [ApplyOCRCorrectionsCommand] = []
    for entry in pageOrder {
      guard let corrections = staged[entry.pageID], !corrections.isEmpty,
        let record = records[entry.pageID]
      else { continue }
      commands.append(
        ApplyOCRCorrectionsCommand(
          pageID: entry.pageID, corrections: corrections, record: record))
    }
    return commands
  }

  /// Tests and the panel use this to show the current persisted record.
  public func record(pageID: PDFObjectID) -> OCRReviewPageRecord? {
    records[pageID]
  }
}
