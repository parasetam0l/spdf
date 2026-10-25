import DocumentSession
import Foundation
import PDFCore
import PDFKit
@testable import PDFEditing
import PDFFixtures
import Testing

/// OCR-03: corrected OCR text is what search and copy see, before and after
/// save/reopen, and the review record stays associated with the corrected
/// layer. The scanned page image is not part of this rewrite.
@Suite("OCR review search and copy")
struct OCRReviewSearchTests {
  @Test func correctedOCRTextIsSearchableAndCopiedAfterReopen() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let lines = [
      SearchableTextLine(
        text: "reciept total 42", rect: [100, 600, 400, 620], confidence: 0.35),
      SearchableTextLine(
        text: "İstanbul", rect: [100, 560, 300, 580], confidence: 0.4),
    ]
    let record = OCRReviewPageRecord.build(
      lines: lines, threshold: 0.6, quality: "accurate")
    let session = DocumentEditSession()
    session.load(try PDFSource(data: try PDFWriter.write(parsed.graph)))
    try session.apply(
      PDFTransaction([
        AddSearchableTextLayerCommand(pageID: pageID, lines: lines),
        RecordOCRReviewCommand(pageID: pageID, record: record),
      ]))

    // The unrecognized spelling is searchable as recognized text before review.
    let index = TextSearchIndex(session: session)
    let before = try index.search("reciept")
    #expect(before.count == 1)
    #expect(before.first?.provenance == .recognizedText)

    let remaining = record.suspectWords.filter {
      !($0.lineIndex == 0 && $0.wordIndex == 0) && !($0.lineIndex == 1 && $0.wordIndex == 0)
    }
    try session.apply(
      PDFTransaction([
        ApplyOCRCorrectionsCommand(
          pageID: pageID,
          corrections: [
            OCRWordCorrection(
              lineIndex: 0, wordIndex: 0, originalWord: "reciept",
              replacement: "receipt"),
            OCRWordCorrection(
              lineIndex: 1, wordIndex: 0, originalWord: "İstanbul",
              replacement: "İstanbul’da"),
          ],
          record: record.replacingSuspects(remaining))
      ]))

    // The revision-aware index follows the committed correction.
    #expect(before.count == 1)
    #expect(try index.search("receipt").count == 1)
    #expect(try index.search("reciept").isEmpty)
    let unicode = try index.search("İstanbul’da")
    #expect(unicode.count == 1)
    #expect(unicode.first?.provenance == .recognizedText)

    // Copy through PDFKit sees the corrected Unicode and no old spelling.
    let saved = try session.bytesForSave()
    let document = try #require(PDFDocument(data: saved))
    let copied = document.string ?? ""
    #expect(copied.contains("receipt total 42"))
    #expect(copied.contains("İstanbul’da"))
    #expect(!copied.contains("reciept"))

    // Reopening keeps corrected text, Unicode, search and the review record;
    // the image page content stream was untouched by the correction.
    let reopened = DocumentEditSession()
    reopened.load(try PDFSource(data: saved))
    let graph = try #require(reopened.currentGraph)
    let reopenedIndex = TextSearchIndex(session: reopened)
    #expect(try reopenedIndex.search("receipt").count == 1)
    #expect(try reopenedIndex.search("İstanbul’da").count == 1)
    let reopenedRecord = try #require(OCRReviewStore.read(pageID: pageID, in: graph))
    #expect(reopenedRecord.corrections.count == 2)
    #expect(reopenedRecord.suspectWords.count == 2)
    guard case .stream(let originalContent)? = parsed.graph.objects[PDFObjectID(5)],
      case .stream(let reopenedContent)? = graph.objects[PDFObjectID(5)]
    else {
      Issue.record("Original page content stream is missing")
      return
    }
    #expect(originalContent.bytes == reopenedContent.bytes)
  }
}
