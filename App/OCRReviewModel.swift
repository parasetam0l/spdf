import AppKit
import Combine
import Foundation
import MacServices
import PDFCore
import PDFEditing

/// OCR-03: the document-facing services the review model needs. The document
/// extension supplies these closures so the model and panel stay independent of
/// SPDFDocument and are testable in isolation.
@MainActor
struct OCRReviewHost {
  var pageIDs: @MainActor () -> [PDFObjectID]
  var graph: @MainActor () -> PDFGraph?
  var apply: @MainActor ([ApplyOCRCorrectionsCommand]) -> Bool
  var refresh: @MainActor (Int) -> Void
  var goToPage: @MainActor (Int) -> Void
  var pageCount: @MainActor () -> Int
}

/// OCR-03: the review panel model. It owns the queue and staged corrections,
/// keeps the page overlay current, and only touches the document when the user
/// applies staged corrections (one undoable transaction).
@MainActor
final class OCRReviewModel: ObservableObject {
  @Published private(set) var session: OCRReviewSession?
  @Published private(set) var currentWord: OCRReviewWord?
  @Published private(set) var remainingCount = 0
  @Published private(set) var stagedCount = 0
  @Published private(set) var positionLabel = "No suspect words"
  @Published private(set) var message: String?
  @Published var draft = ""
  @Published private(set) var pageIndex = 0
  @Published private(set) var pageCount = 0
  @Published private(set) var confidenceLabel = ""
  @Published private(set) var provenanceLabel = ""
  @Published private(set) var pageSuspects: [OCRReviewWord] = []
  @Published private(set) var qualityNote = ""
  @Published private(set) var isApplying = false

  let host: OCRReviewHost
  /// Redraw hook for the page overlay.
  var overlayChanged: (() -> Void)?
  /// Set by the panel controller so the Close button can close its window.
  var requestClose: (() -> Void)?

  init(host: OCRReviewHost) {
    self.host = host
    pageCount = host.pageCount()
  }

  var hasSession: Bool { session != nil }
  var canApply: Bool { stagedCount > 0 && !isApplying }
  var canCorrect: Bool { currentWord != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// Load the persisted review queue for the document's OCR pages.
  func reloadFromDocument() {
    guard let graph = host.graph() else {
      session = nil
      refreshPresentation()
      message = "This document is not editable by the owned core."
      return
    }
    let pageIDs = host.pageIDs()
    guard let loaded = OCRReviewSession.load(pageIDs: pageIDs, in: graph) else {
      session = nil
      refreshPresentation()
      message = "No OCR review data is available. Run Recognize Text with review or open a document with a generated OCR layer created by this app."
      return
    }
    session = loaded
    message = nil
    refreshPresentation()
  }

  /// Start a fresh review from the results of a recognition run. The layers
  /// must already be committed by the OCR route; the records carry confidence
  /// and provenance for the queue.
  func begin(
    results: [OCRPageResult], level: OCRRecognitionLevel, threshold: Double
  ) {
    let pageIDs = host.pageIDs()
    let seeds = OCRReviewBuilder.seeds(from: results, pageIDs: pageIDs)
    let quality = OCRReviewBuilder.quality(level: level, results: results)
    do {
      let built = try OCRReviewSession.build(
        seeds: seeds, threshold: threshold, quality: quality)
      session = built
      message = nil
      refreshPresentation()
    } catch {
      session = nil
      refreshPresentation()
      message = error.localizedDescription
    }
  }

  // MARK: - Keyboard queue

  func next() {
    guard var session else { return }
    _ = session.selectNext()
    self.session = session
    syncDraft()
    refreshPresentation()
  }

  func previous() {
    guard var session else { return }
    _ = session.selectPrevious()
    self.session = session
    syncDraft()
    refreshPresentation()
  }

  func skip() {
    guard var session else { return }
    _ = session.skipCurrent()
    self.session = session
    syncDraft()
    refreshPresentation()
  }

  func select(_ word: OCRReviewWord) {
    guard var session else { return }
    _ = session.select(id: word.id)
    self.session = session
    syncDraft()
    refreshPresentation()
  }

  func jumpToPage(_ index: Int) {
    guard var session, let word = session.jumpToPage(index) else { return }
    self.session = session
    select(word)
  }

  // MARK: - Corrections

  /// Stage the replacement in the draft for the current word.
  @discardableResult
  func stageCurrentCorrection() -> Bool {
    guard var session, currentWord != nil else { return false }
    let replacement = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !replacement.isEmpty else {
      message = "Type the corrected word first."
      return false
    }
    do {
      _ = try session.stageCorrection(replacement)
      self.session = session
      message = nil
      syncDraft()
      refreshPresentation()
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func undoLastCorrection() -> Bool {
    guard var session, session.hasStagedCorrections else { return false }
    _ = session.undoLastStagedCorrection()
    self.session = session
    message = nil
    syncDraft()
    refreshPresentation()
    return true
  }

  /// Apply every staged correction as one undoable document transaction.
  @discardableResult
  func applyStagedCorrections() -> Bool {
    guard let session, let graph = host.graph() else { return false }
    let commands: [ApplyOCRCorrectionsCommand]
    do {
      commands = try session.commands()
      guard !commands.isEmpty else {
        message = "No corrections are staged."
        return false
      }
      for command in commands { try command.validate(in: graph) }
    } catch {
      message = error.localizedDescription
      return false
    }
    isApplying = true
    defer { isApplying = false }
    guard host.apply(commands) else {
      message = "The corrections could not be applied to the document."
      return false
    }
    let page = (currentWord?.pageIndex ?? 0) + 1
    reloadFromDocument()
    host.refresh(page)
    message = "Corrections applied as one undoable step."
    return true
  }

  func close() {
    overlayChanged?()
  }

  // MARK: - Presentation

  private func syncDraft() {
    draft = currentWord?.text ?? ""
  }

  private func refreshPresentation() {
    currentWord = session?.current
    if draft.isEmpty { draft = currentWord?.text ?? "" }
    remainingCount = session?.remainingSuspectCount ?? 0
    stagedCount = session?.stagedCorrectionCount ?? 0
    positionLabel = session?.currentPositionLabel ?? "No suspect words"
    confidenceLabel = currentWord?.confidenceLabel ?? ""
    provenanceLabel = provenanceText(for: currentWord)
    qualityNote = qualityText(session?.quality)
    pageIndex = currentWord?.pageIndex ?? pageIndex
    if let session, let current = currentWord {
      pageSuspects = session.suspects(onPageIndex: current.pageIndex)
      host.goToPage(current.pageIndex + 1)
    } else {
      pageSuspects = []
    }
    overlayChanged?()
  }

  private func provenanceText(for word: OCRReviewWord?) -> String {
    guard let word else { return "" }
    var parts: [String] = ["recognized"]
    if word.usedFastFallback { parts.append("fast fallback") }
    if word.provenance == .recognizedUncertain { parts.append("low confidence") }
    parts.append(word.confidenceLabel)
    return parts.joined(separator: " · ")
  }

  private func qualityText(_ quality: String?) -> String {
    switch quality {
    case "fastFallback":
      return "Recognition used Fast fallback; review text before relying on it."
    case "fast":
      return "Recognition quality: Fast."
    case "accurate":
      return "Recognition quality: Accurate."
    default:
      return ""
    }
  }
}
