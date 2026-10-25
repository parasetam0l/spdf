import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import PDFKit
import Testing

@Suite("Extended page text formatting")
struct TextFormattingRoundTripTests {
  @Test func underlineStrikeoutRiseWordSpacingRoundTripThroughPageContent() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(
      font: .helvetica, size: 16, wordSpacing: 4.5, rise: 3,
      underline: true, strikeout: true)
    let text = "Styled words"
    let line = PageTextLine(
      text: text, x: 72, baseline: 700,
      segments: [.init(text: text, x: 72, format: format, width: 76)])
    let graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(
        pageID: pageID, lines: [line],
        box: PageTextBox(x: 72, firstBaseline: 700, width: 300, lineSpacing: 22))
    ]), to: parsed.graph)
    let reopened = try PDFParser.parse(PDFWriter.write(graph))
    let reopenedPage = try #require(reopened.pageIDs.first)
    let authored = try AuthoredPageTextBoxes.read(pageID: reopenedPage, in: reopened.graph)
    let box = try #require(authored.first)
    let segment = try #require(box.lines.first?.segments.first)
    #expect(segment.format.underline)
    #expect(segment.format.strikeout)
    #expect(abs(segment.format.rise - 3) < 0.001)
    #expect(abs(segment.format.wordSpacing - 4.5) < 0.001)
    #expect(abs((segment.width ?? 0) - 76) < 0.001)
    let reader = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    #expect(reader.string?.contains(text) == true)
    let content = try PageContent.load(pageID: reopenedPage, in: reopened.graph)
    let bytes = String(decoding: content.bytes, as: UTF8.self)
    #expect(bytes.contains("Tw"))
    #expect(bytes.contains("Ts"))
    #expect(bytes.contains("re f"))
  }
}
