import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// OCR-03: word-level review metadata, correction storage and layer rewriting.
/// Corrected text, Unicode and bounds survive save/reopen and search/copy; the
/// page image and original content streams are untouched.
@Suite("OCR review corrections")
struct OCRReviewTests {
  private let pageLines: [SearchableTextLine] = [
    SearchableTextLine(
      text: "reciept total 42", rect: [100, 600, 400, 620], confidence: 0.42),
    SearchableTextLine(
      text: "Grüße aus İstanbul", rect: [100, 560, 400, 580], confidence: 0.9),
  ]

  private func layeredGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let record = OCRReviewPageRecord.build(
      lines: pageLines, threshold: 0.6, quality: "accurate")
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(pageID: pageID, lines: pageLines),
        RecordOCRReviewCommand(pageID: pageID, record: record),
      ]), to: parsed.graph)
    return (graph, pageID)
  }

  private func lines(in graph: PDFGraph, pageID: PDFObjectID) throws -> [OCRLayerTextLine] {
    try #require(OCRLayerTextReader.lines(pageID: pageID, in: graph))
  }

  @Test func reviewRecordRoundTripsWithWordProvenance() throws {
    let (graph, pageID) = try layeredGraph()
    let record = try #require(OCRReviewStore.read(pageID: pageID, in: graph))
    #expect(record.threshold == 0.6)
    #expect(record.quality == "accurate")
    #expect(record.lines.count == 2)
    #expect(record.lines[0].rect == [100, 600, 400, 620])
    // Only the low-confidence line contributes suspects; all three words.
    #expect(record.suspectWords.map(\.text) == ["reciept", "total", "42"])
    #expect(record.suspectWords.map(\.lineIndex) == [0, 0, 0])
    #expect(record.suspectWords.map(\.wordIndex) == [0, 1, 2])
    #expect(record.suspectWords.allSatisfy { $0.confidence == 0.42 })
    // Word boxes are inside the line box, ordered left to right.
    for word in record.suspectWords {
      #expect(word.rect[0] >= 100 && word.rect[2] <= 400)
      #expect(word.rect[1] == 600 && word.rect[3] == 620)
    }
    #expect(record.suspectWords[0].rect[0] < record.suspectWords[1].rect[0])
    // The metadata stream is private, bounded and survives a round trip.
    let bytes = try PDFWriter.write(graph)
    let reopened = try PDFParser.parse(bytes)
    #expect(try PDFParser.parse(try PDFWriter.write(reopened.graph)).graph == reopened.graph)
    let reopenedRecord = try #require(
      OCRReviewStore.read(pageID: pageID, in: reopened.graph))
    #expect(reopenedRecord == record)
    #expect(OCRLayer.hasGeneratedLayer(in: reopened.graph, pageID: pageID))
  }

  @Test func wordCorrectionsRewriteLayerTextUnicodeAndBounds() throws {
    let (graph, pageID) = try layeredGraph()
    let record = try #require(OCRReviewStore.read(pageID: pageID, in: graph))
    let remaining = record.suspectWords.filter {
      !($0.lineIndex == 0 && $0.wordIndex == 0)
    }
    let corrections = [
      OCRWordCorrection(
        lineIndex: 0, wordIndex: 0, originalWord: "reciept", replacement: "receipt"),
      OCRWordCorrection(
        lineIndex: 1, wordIndex: 2, originalWord: "İstanbul",
        replacement: "İstanbul’da"),
    ]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ApplyOCRCorrectionsCommand(
          pageID: pageID, corrections: corrections,
          record: record.replacingSuspects(remaining))
      ]), to: graph)

    // The generated layer text is rewritten and extraction sees the corrected
    // Unicode through the layer's ToUnicode map.
    let rewritten = try lines(in: edited, pageID: pageID)
    #expect(rewritten.map(\.text) == ["receipt total 42", "Grüße aus İstanbul’da"])
    #expect(
      TextProvenance.recognizedLayerText(pageID: pageID, in: edited)
        == "receipt total 42\nGrüße aus İstanbul’da")
    // Bounds and text size are unchanged.
    #expect(rewritten[0].x == 100 && rewritten[0].y == 600)
    #expect(rewritten[0].fontSize == 20)
    #expect(rewritten[1].y == 560 && rewritten[1].fontSize == 20)
    // The persisted review record keeps the history and the remaining suspects.
    let updated = try #require(OCRReviewStore.read(pageID: pageID, in: edited))
    #expect(updated.corrections == corrections)
    #expect(updated.suspectWords.map(\.text) == ["total", "42"])
    #expect(updated.lines.map(\.rect) == record.lines.map(\.rect))
    // The new Unicode scalar is in the layer font's ToUnicode map.
    let cmap = try toUnicodeText(in: edited, pageID: pageID)
    #expect(cmap.contains("<2019>"))
    // The page image and original content streams are byte-identical.
    let original = try PDFParser.parse(PDFFixtures.imagePages())
    for id in [PDFObjectID(5), PDFObjectID(6), PDFObjectID(7)] {
      guard case .stream(let before)? = original.graph.objects[id],
        case .stream(let after)? = edited.objects[id]
      else {
        Issue.record("Original page object \(id.number) is missing")
        return
      }
      #expect(before.bytes == after.bytes)
    }
    // Save/reopen keeps corrected text, Unicode, bounds and the queue state.
    let reopened = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(
      TextProvenance.recognizedLayerText(pageID: pageID, in: reopened.graph)
        == "receipt total 42\nGrüße aus İstanbul’da")
    let reopenedRecord = try #require(
      OCRReviewStore.read(pageID: pageID, in: reopened.graph))
    #expect(reopenedRecord.corrections.count == 2)
    #expect(reopenedRecord.suspectWords.map(\.text) == ["total", "42"])
    #expect(try lines(in: reopened.graph, pageID: pageID).map(\.y) == [600, 560])
  }

  @Test func multipleCorrectionsInOneLineApplyTogether() throws {
    let (graph, pageID) = try layeredGraph()
    let record = try #require(OCRReviewStore.read(pageID: pageID, in: graph))
    let corrections = [
      OCRWordCorrection(
        lineIndex: 0, wordIndex: 0, originalWord: "reciept", replacement: "receipt"),
      OCRWordCorrection(
        lineIndex: 0, wordIndex: 2, originalWord: "42", replacement: "43"),
    ]
    let remaining = record.suspectWords.filter {
      !($0.lineIndex == 0 && ($0.wordIndex == 0 || $0.wordIndex == 2))
    }
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ApplyOCRCorrectionsCommand(
          pageID: pageID, corrections: corrections,
          record: record.replacingSuspects(remaining))
      ]), to: graph)
    #expect(try lines(in: edited, pageID: pageID)[0].text == "receipt total 43")

    // The same word cannot be corrected twice in one command.
    #expect(throws: PDFError.self) {
      _ = try ApplyOCRCorrectionsCommand(
        pageID: pageID,
        corrections: [
          OCRWordCorrection(
            lineIndex: 0, wordIndex: 0, originalWord: "reciept", replacement: "receipt"),
          OCRWordCorrection(
            lineIndex: 0, wordIndex: 0, originalWord: "reciept", replacement: "receipt2"),
        ], record: record.replacingSuspects(remaining)
      ).validate(in: graph)
    }
    // A correction whose original word no longer matches the layer refuses.
    #expect(throws: PDFError.self) {
      _ = try ApplyOCRCorrectionsCommand(
        pageID: pageID,
        corrections: [
          OCRWordCorrection(
            lineIndex: 0, wordIndex: 0, originalWord: "stale", replacement: "x")
        ], record: record.replacingSuspects(remaining)
      ).validate(in: edited)
    }
  }

  @Test func invalidCorrectionsRefuseBeforeMutation() throws {
    let (graph, pageID) = try layeredGraph()
    let record = try #require(OCRReviewStore.read(pageID: pageID, in: graph))
    func command(
      _ correction: OCRWordCorrection, record: OCRReviewPageRecord = record
    ) -> ApplyOCRCorrectionsCommand {
      ApplyOCRCorrectionsCommand(
        pageID: pageID, corrections: [correction],
        record: record.replacingSuspects([]))
    }
    // Empty or whitespace replacements and beyond-BMP text refuse.
    for replacement in ["", "   ", "two words", "🙂"] {
      #expect(throws: PDFError.self) {
        _ = try command(
          OCRWordCorrection(
            lineIndex: 0, wordIndex: 0, originalWord: "reciept",
            replacement: replacement)
        ).validate(in: graph)
      }
    }
    // Out-of-range lines and words refuse.
    #expect(throws: PDFError.self) {
      _ = try command(
        OCRWordCorrection(
          lineIndex: 9, wordIndex: 0, originalWord: "x", replacement: "y")
      ).validate(in: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try command(
        OCRWordCorrection(
          lineIndex: 0, wordIndex: 9, originalWord: "x", replacement: "y")
      ).validate(in: graph)
    }
    // A page without a generated layer refuses.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    #expect(throws: PDFError.self) {
      _ = try ApplyOCRCorrectionsCommand(
        pageID: parsed.pageIDs[0],
        corrections: [
          OCRWordCorrection(
            lineIndex: 0, wordIndex: 0, originalWord: "a", replacement: "b")
        ], record: record
      ).validate(in: parsed.graph)
    }
    // A record whose line count no longer matches the layer refuses.
    let shorter = OCRReviewPageRecord(
      threshold: 0.6, quality: "accurate", lines: [record.lines[0]],
      suspectWords: [])
    #expect(throws: PDFError.self) {
      _ = try ApplyOCRCorrectionsCommand(
        pageID: pageID,
        corrections: [
          OCRWordCorrection(
            lineIndex: 0, wordIndex: 0, originalWord: "reciept", replacement: "receipt")
        ], record: shorter
      ).validate(in: graph)
    }
    // Nothing mutated by any refusal.
    #expect(try lines(in: graph, pageID: pageID).map(\.text) == pageLines.map(\.text))
  }

  @Test func reviewRecordLimitsAreExplicit() throws {
    #expect(throws: PDFError.self) {
      _ = try OCRReviewPageRecord(
        threshold: 2, quality: "accurate",
        lines: [.init(rect: [0, 0, 10, 10], confidence: 0.5)], suspectWords: []
      ).validated()
    }
    #expect(throws: PDFError.self) {
      _ = try OCRReviewPageRecord(
        threshold: 0.6, quality: "converted",
        lines: [.init(rect: [0, 0, 10, 10], confidence: 0.5)], suspectWords: []
      ).validated()
    }
    // Duplicate suspect words are refused.
    let duplicateWord = OCRReviewWordRecord(
      lineIndex: 0, wordIndex: 0, text: "a", rect: [0, 0, 1, 1], confidence: 0.2)
    #expect(throws: PDFError.self) {
      _ = try OCRReviewPageRecord(
        threshold: 0.6, quality: "accurate",
        lines: [.init(rect: [0, 0, 10, 10], confidence: 0.5)],
        suspectWords: [duplicateWord, duplicateWord]
      ).validated()
    }
    // An oversized record is refused at the stored-size bound.
    let maxWord = OCRReviewWordRecord(
      lineIndex: 0, wordIndex: 0, text: "needs a correction", rect: [0, 0, 120, 20],
      confidence: 0.2)
    let suspects = (0..<OCRReviewPageRecord.maxSuspectWords).map { index in
      OCRReviewWordRecord(
        lineIndex: 0, wordIndex: index, text: maxWord.text, rect: maxWord.rect,
        confidence: maxWord.confidence)
    }
    #expect(throws: PDFError.self) {
      _ = try OCRReviewPageRecord(
        threshold: 0.6, quality: "accurate",
        lines: [.init(rect: [0, 0, 400, 20], confidence: 0.5)],
        suspectWords: suspects
      ).validated()
    }
  }

  @Test func tokenizerPreservesSeparatorsAndEstimatesBoxes() throws {
    #expect(OCRReviewTokenizer.words(" a  b\tc ") == ["a", "b", "c"])
    let rebuilt = try OCRReviewTokenizer.replacingWords(
      in: " a  b\tc ", replacements: [1: "B"])
    #expect(rebuilt == " a  B\tc ")
    let rects = OCRReviewTokenizer.proportionalWordRects(
      lineText: "ab cd", rect: [10, 100, 70, 120])
    #expect(rects.count == 2)
    #expect(rects[0][0] == 10 && rects[1][0] > rects[0][0])
    #expect(rects[1][2] == 70)
    #expect(rects.allSatisfy { $0[1] == 100 && $0[3] == 120 })
    #expect(throws: PDFError.self) {
      try OCRReviewTokenizer.validateCorrection(
        .init(lineIndex: 0, wordIndex: 0, originalWord: "a", replacement: "b c"))
    }
    #expect(throws: PDFError.self) {
      try OCRReviewTokenizer.validateCorrection(
        .init(lineIndex: 0, wordIndex: 0, originalWord: "a b", replacement: "c"))
    }
  }

  private func toUnicodeText(
    in graph: PDFGraph, pageID: PDFObjectID
  ) throws -> String {
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else { throw PDFError(.malformed, "Missing page fonts") }
    for value in fonts.values {
      guard case .reference(let id) = value,
        case .dictionary(let font)? = graph.objects[id],
        case .reference(let cmapID)? = font[PDFName("ToUnicode")],
        case .stream(let stream)? = graph.objects[cmapID]
      else { continue }
      return String(decoding: stream.bytes, as: UTF8.self)
    }
    throw PDFError(.malformed, "Missing OCR ToUnicode map")
  }
}
