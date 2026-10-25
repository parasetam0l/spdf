import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// OCR-03: suspect-word confidence/provenance, the keyboard review queue, and
/// correction staging/commit/reload. The session never mutates the document
/// until its commands are committed.
@Suite("OCR review session")
struct OCRReviewSessionTests {
  private func results() -> [OCRPageResult] {
    [
      OCRPageResult(
        pageIndex: 0,
        lines: [
          OCRTextLine(
            text: "reciept total", rect: [100, 600, 400, 620], confidence: 0.35,
            words: [
              OCRTextWord(text: "reciept", rect: [100, 600, 180, 620], confidence: 0.35),
              OCRTextWord(text: "total", rect: [190, 600, 250, 620], confidence: 0.35),
            ]),
          OCRTextLine(
            text: "Safe line", rect: [100, 560, 400, 580], confidence: 0.95),
        ],
        usedFastFallback: true),
      OCRPageResult(
        pageIndex: 1,
        lines: [
          OCRTextLine(
            text: "İstanbul", rect: [80, 500, 300, 520], confidence: 0.4,
            words: [
              OCRTextWord(text: "İstanbul", rect: [80, 500, 220, 520], confidence: 0.4)
            ])
        ],
        usedFastFallback: true),
    ]
  }

  private func layeredGraph(
    results: [OCRPageResult]
  ) throws -> (graph: PDFGraph, pageIDs: [PDFObjectID], session: OCRReviewSession) {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    let seeds = OCRReviewBuilder.seeds(from: results, pageIDs: pageIDs)
    let quality = OCRReviewBuilder.quality(level: .accurate, results: results)
    var commands: [any PDFEditCommand] = []
    for seed in seeds {
      let lines = seed.lines
      commands.append(AddSearchableTextLayerCommand(pageID: seed.pageID, lines: lines))
      commands.append(
        RecordOCRReviewCommand(
          pageID: seed.pageID,
          record: OCRReviewBuilder.record(for: seed, threshold: 0.6, quality: quality)))
    }
    let graph = try PDFEditingEngine.commit(PDFTransaction(commands), to: parsed.graph)
    let session = try OCRReviewSession.build(
      seeds: seeds, threshold: 0.6, quality: quality)
    return (graph, pageIDs, session)
  }

  @Test func buildsSuspectQueueWithConfidenceProvenanceAndWordBoxes() throws {
    let layered = try layeredGraph(results: results())
    let graph = layered.graph
    let pageIDs = layered.pageIDs
    var session = layered.session
    #expect(session.quality == "fastFallback")
    #expect(session.threshold == 0.6)
    #expect(session.remainingSuspectCount == 3)
    #expect(session.pages.count == 2)
    #expect(session.pages[0].suspectCount == 2)
    #expect(session.pages[1].suspectCount == 1)
    let words = session.suspects(onPageIndex: 0)
    #expect(words.map(\.text) == ["reciept", "total"])
    #expect(words.allSatisfy { $0.provenance == .recognizedUncertain })
    #expect(words.allSatisfy { $0.usedFastFallback })
    #expect(words.allSatisfy { $0.confidenceLabel == "35%" })
    // Explicit word boxes from the recognizer are used, not estimates.
    #expect(words[0].rect == [100, 600, 180, 620])
    #expect(words[1].rect == [190, 600, 250, 620])
    #expect(session.selectFirst()?.text == "reciept")
    // The page records are persisted and match the review queue.
    for pageID in pageIDs {
      #expect(OCRReviewStore.read(pageID: pageID, in: graph) != nil)
    }
  }

  @Test func keyboardQueueNavigationAndSkip() throws {
    let (_, _, template) = try layeredGraph(results: results())
    var session = template
    #expect(session.selectFirst()?.text == "reciept")
    #expect(session.selectNext()?.text == "total")
    #expect(session.selectNext()?.text == "İstanbul")
    #expect(session.selectNext()?.text == "İstanbul")  // no wrap
    #expect(session.selectPrevious()?.text == "total")
    #expect(session.selectFirst()?.text == "reciept")
    let total = try #require(session.suspects(onPageIndex: 0).last)
    #expect(session.select(id: total.id)?.text == "total")
    #expect(session.jumpToPage(1)?.text == "İstanbul")
    #expect(session.jumpToPage(9) == nil)
    #expect(session.currentPositionLabel == "3 of 3")
    #expect(session.skipCurrent()?.text == "İstanbul")
    #expect(session.remainingSuspectCount == 2)
    #expect(session.skippedCount == 1)
    #expect(session.current?.text == "total")
  }

  @Test func stagedCorrectionsCommitTextUnicodeBoundsAndReload() throws {
    let results = results()
    var (graph, pageIDs, session) = try layeredGraph(results: results)
    // Correct the first word, then the two remaining suspects on page 0.
    #expect(session.selectFirst()?.text == "reciept")
    try session.stageCorrection("receipt")
    #expect(session.current?.text == "total")
    try session.stageCorrection("totals")
    #expect(session.current?.text == "İstanbul")
    try session.stageCorrection("İstanbul’da")
    #expect(session.remainingSuspectCount == 0)
    #expect(session.stagedCorrectionCount == 3)
    #expect(session.hasStagedCorrections)
    let commands = try session.commands()
    #expect(commands.count == 2)
    graph = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)

    let firstPageLines = try #require(
      OCRLayerTextReader.lines(pageID: pageIDs[0], in: graph))
    #expect(firstPageLines.map(\.text) == ["receipt totals", "Safe line"])
    let secondPageLines = try #require(
      OCRLayerTextReader.lines(pageID: pageIDs[1], in: graph))
    #expect(secondPageLines.map(\.text) == ["İstanbul’da"])
    #expect(
      TextProvenance.recognizedLayerText(pageID: pageIDs[0], in: graph)
        == "receipt totals\nSafe line")
    // Line bounds are preserved from the recognition record.
    #expect(firstPageLines[0].x == 100 && firstPageLines[0].y == 600)
    #expect(firstPageLines[0].fontSize == 20)

    // Reload from the persisted metadata: history is kept, queue is empty, and
    // further corrections can still be staged on the same layer.
    var reloaded = try #require(OCRReviewSession.load(pageIDs: pageIDs, in: graph))
    #expect(reloaded.remainingSuspectCount == 0)
    #expect(reloaded.appliedCorrections == 3)
    #expect(reloaded.quality == "fastFallback")
    #expect(reloaded.threshold == 0.6)
    #expect(reloaded.selectFirst() == nil)
    // The corrected layer survives save/reopen with Unicode extraction intact.
    let reopened = try PDFParser.parse(try PDFWriter.write(graph))
    let reopenedSession = try #require(
      OCRReviewSession.load(pageIDs: pageIDs, in: reopened.graph))
    #expect(reopenedSession.appliedCorrections == 3)
    #expect(
      TextProvenance.recognizedLayerText(pageID: pageIDs[1], in: reopened.graph)
        == "İstanbul’da")
    // A reloaded session can stage and commit another correction.
    let fresh = try OCRPDFReviewFixture.addSuspect(
      pageID: pageIDs[0], text: "Extra", in: reopened.graph)
    reloaded = try #require(OCRReviewSession.load(pageIDs: pageIDs, in: fresh))
    #expect(reloaded.remainingSuspectCount == 1)
    #expect(reloaded.selectFirst()?.text == "Extra")
    try reloaded.stageCorrection("Extra!")
    let second = try PDFEditingEngine.commit(
      PDFTransaction(try reloaded.commands()), to: fresh)
    #expect(
      TextProvenance.recognizedLayerText(pageID: pageIDs[0], in: second)?.contains("Extra!")
        == true)
  }

  @Test func undoAndStagingRules() throws {
    let (_, _, template) = try layeredGraph(results: results())
    var session = template
    #expect(try session.commands().isEmpty)
    // The first suspect is selected when the queue is built.
    #expect(session.current?.text == "reciept")
    // A replacement equal to the recognized word does not consume the queue.
    let remaining = session.remainingSuspectCount
    #expect(throws: PDFError.self) { try session.stageCorrection("reciept") }
    #expect(throws: PDFError.self) { try session.stageCorrection("two words") }
    #expect(throws: PDFError.self) { try session.stageCorrection("🙂") }
    #expect(session.remainingSuspectCount == remaining)
    #expect(session.current?.text == "reciept")
    try session.stageCorrection("receipt")
    #expect(session.stagedCorrectionCount == 1)
    #expect(session.remainingSuspectCount == remaining - 1)
    let restoredValue = session.undoLastStagedCorrection()
    let restored = try #require(restoredValue)
    #expect(restored.text == "reciept")
    #expect(session.stagedCorrectionCount == 0)
    #expect(session.remainingSuspectCount == remaining)
    #expect(session.current?.text == "reciept")
    #expect(try session.commands().isEmpty)
    // No metadata means no review session, and empty results refuse.
    let bare = try PDFParser.parse(PDFFixtures.imagePages())
    #expect(OCRReviewSession.load(pageIDs: bare.pageIDs, in: bare.graph) == nil)
    #expect(throws: PDFError.self) {
      _ = try OCRReviewSession.build(seeds: [], threshold: 0.6, quality: "accurate")
    }
  }

  @Test func proportionalFallbackWhenRecognizerHasNoWords() throws {
    let plain = [
      OCRPageResult(
        pageIndex: 0,
        lines: [
          OCRTextLine(text: "alpha beta gamma", rect: [10, 100, 310, 120], confidence: 0.3)
        ],
        usedFastFallback: false)
    ]
    var (graph, pageIDs, session) = try layeredGraph(results: plain)
    #expect(session.remainingSuspectCount == 3)
    let words = session.suspects(onPageIndex: 0)
    #expect(words.map(\.text) == ["alpha", "beta", "gamma"])
    #expect(words[0].rect[0] == 10)
    #expect(words[2].rect[2] == 310)
    #expect(zip(words, words.dropFirst()).allSatisfy { left, right in left.rect[0] < right.rect[0] })
    #expect(session.selectNext()?.text == "beta")
    try session.stageCorrection("BETA")
    graph = try PDFEditingEngine.commit(
      PDFTransaction(try session.commands()), to: graph)
    #expect(
      TextProvenance.recognizedLayerText(pageID: pageIDs[0], in: graph)
        == "alpha BETA gamma")
  }
}

/// Fixture helper shared by the reload assertion: adds one more low-confidence
/// word to a page's generated layer through the review command path.
private enum OCRPDFReviewFixture {
  static func addSuspect(pageID: PDFObjectID, text: String, in graph: PDFGraph) throws
    -> PDFGraph
  {
    let lines = try #require(OCRLayerTextReader.lines(pageID: pageID, in: graph))
    var textLines: [SearchableTextLine] = lines.map {
      SearchableTextLine(
        text: $0.text, rect: [$0.x, $0.y, $0.x + 200, $0.y + $0.fontSize],
        confidence: 0.95)
    }
    textLines.append(
      SearchableTextLine(
        text: text, rect: [100, 400, 300, 420], confidence: 0.3))
    let record = OCRReviewPageRecord.build(
      lines: textLines, threshold: 0.6, quality: "fastFallback")
    return try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID, lines: textLines, replacingExistingLayer: true),
        RecordOCRReviewCommand(pageID: pageID, record: record),
      ]), to: graph)
  }
}
