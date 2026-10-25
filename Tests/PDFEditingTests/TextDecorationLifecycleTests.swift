import CoreText
import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import PDFKit
import Testing

/// TXT-08 regression: underline/strikeout paint must follow the authored box
/// through a second commit. The writer appends decorations as a marked block;
/// a rewrite retires the previous block before appending the replacement.
@Suite("Text decoration lifecycle")
struct TextDecorationLifecycleTests {
  private func decoratedPage(
    text: String = "Styled words", baseline: Double = 700
  ) throws -> (graph: PDFGraph, pageID: PDFObjectID, authored: AuthoredPageTextBox) {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(
      font: .helvetica, size: 16, wordSpacing: 2, rise: 3, underline: true, strikeout: true)
    let line = PageTextLine(
      text: text, x: 72, baseline: baseline,
      segments: [.init(text: text, x: 72, format: format, width: 76)])
    let box = PageTextBox(x: 72, firstBaseline: baseline, width: 300, lineSpacing: 22)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)
      ]), to: parsed.graph)
    let saved = try PDFParser.parse(PDFWriter.write(graph))
    let savedPage = try #require(saved.pageIDs.first)
    let authored = try #require(
      try AuthoredPageTextBoxes.read(pageID: savedPage, in: saved.graph).first)
    return (saved.graph, savedPage, authored)
  }

  private func plainLine(_ authoredLine: PageTextLine, baseline: Double? = nil) -> PageTextLine {
    let format = PageTextFormat(font: .helvetica, size: 16)
    return PageTextLine(
      text: authoredLine.text, x: authoredLine.x,
      baseline: baseline ?? authoredLine.baseline,
      segments: [.init(text: authoredLine.text, x: authoredLine.x, format: format)])
  }

  /// Standard-14 runs can omit /Widths, so the rewrite command needs the
  /// platform advances for the source text, exactly as the native editor
  /// supplies them.
  private func standardAdvances(
    for authored: AuthoredPageTextBox, size: Double = 16
  ) -> [Int: Double] {
    let coreFont = CTFontCreateWithName("Helvetica" as CFString, 1_000, nil)
    var result: [Int: Double] = [:]
    for (index, text) in authored.originalText {
      let characters = Array(text.utf16)
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      guard CTFontGetGlyphsForCharacters(coreFont, characters, &glyphs, glyphs.count) else {
        continue
      }
      var advances = [CGSize](repeating: .zero, count: glyphs.count)
      _ = CTFontGetAdvancesForGlyphs(coreFont, .horizontal, glyphs, &advances, glyphs.count)
      result[index] = advances.reduce(0.0) { $0 + $1.width.rounded() * size / 1_000 }
    }
    return result
  }

  private func rewrite(
    _ authored: AuthoredPageTextBox, lines: [PageTextLine], box: PageTextBox,
    pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> PDFGraph {
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: authored.originalText, lines: lines,
      fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: standardAdvances(for: authored), box: box)
    return try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
  }

  private func pageString(_ graph: PDFGraph, pageID: PDFObjectID) throws -> String {
    let content = try PageContent.load(pageID: pageID, in: graph)
    return String(decoding: content.bytes, as: UTF8.self)
  }

  private func decorationRects(in bytes: String) -> [(x: Double, y: Double, w: Double, h: Double)] {
    let pattern = #"([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) re f"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(location: 0, length: (bytes as NSString).length)
    return expression.matches(in: bytes, range: range).compactMap { match in
      func value(_ index: Int) -> Double? {
        guard let range = Range(match.range(at: index), in: bytes) else { return nil }
        return Double(bytes[range])
      }
      guard let x = value(1), let y = value(2), let w = value(3), let h = value(4) else {
        return nil
      }
      return (x, y, w, h)
    }
  }

  @Test func removingDecorationsOnRewriteRetiresPreviousPainting() throws {
    let (graph, pageID, authored) = try decoratedPage()
    let line = try #require(authored.lines.first)
    let rewritten = try rewrite(
      authored, lines: [plainLine(line)], box: authored.box, pageID: pageID, in: graph)
    let bytes = try pageString(rewritten, pageID: pageID)
    #expect(!bytes.contains(PageTextLineWriter.decorationBeginMarker))
    #expect(decorationRects(in: bytes).isEmpty)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(rewritten)))
    #expect(reopened.string?.contains("Styled words") == true)
    let boxes = try AuthoredPageTextBoxes.read(pageID: pageID, in: rewritten)
    #expect(
      boxes.allSatisfy { box in
        box.lines.flatMap(\.segments).allSatisfy { !$0.format.underline && !$0.format.strikeout }
      })
  }

  @Test func movingDecoratedBoxLeavesExactlyOneDecorationAtTheNewPosition() throws {
    let (graph, pageID, authored) = try decoratedPage()
    let line = try #require(authored.lines.first)
    let movedBaseline = line.baseline - 40
    let format = PageTextFormat(font: .helvetica, size: 16, underline: true)
    let moved = PageTextLine(
      text: line.text, x: line.x, baseline: movedBaseline,
      segments: [.init(text: line.text, x: line.x, format: format, width: 76)])
    let box = PageTextBox(
      x: line.x, firstBaseline: movedBaseline, width: 300, lineSpacing: 22)
    let rewritten = try rewrite(
      authored, lines: [moved], box: box, pageID: pageID, in: graph)
    let bytes = try pageString(rewritten, pageID: pageID)
    #expect(bytes.components(separatedBy: PageTextLineWriter.decorationBeginMarker).count == 2)
    let rects = decorationRects(in: bytes)
    #expect(rects.count == 1)
    let expectedY = movedBaseline - 0.10 * 16
    #expect(abs((rects.first?.y ?? .nan) - expectedY) < 0.01)
    #expect(abs((rects.first?.w ?? .nan) - 76) < 0.01)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(rewritten)))
    #expect(reopened.string?.contains("Styled words") == true)
  }

  @Test func rewritingOneBoxKeepsAnotherBoxesDecorations() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 16, underline: true)
    func line(_ text: String, baseline: Double) -> PageTextLine {
      PageTextLine(
        text: text, x: 72, baseline: baseline,
        segments: [.init(text: text, x: 72, format: format, width: 60)])
    }
    let firstBox = PageTextBox(x: 72, firstBaseline: 700, width: 300, lineSpacing: 22)
    let secondBox = PageTextBox(x: 72, firstBaseline: 640, width: 300, lineSpacing: 22)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(
          pageID: pageID, lines: [line("First box", baseline: 700)], box: firstBox),
        AddPageTextLinesCommand(
          pageID: pageID, lines: [line("Second box", baseline: 640)], box: secondBox),
      ]), to: parsed.graph)
    let saved = try PDFParser.parse(PDFWriter.write(graph))
    let savedPage = try #require(saved.pageIDs.first)
    let boxes = try AuthoredPageTextBoxes.read(pageID: savedPage, in: saved.graph)
    let first = try #require(boxes.first { $0.lines.first?.text == "First box" })
    let firstLine = try #require(first.lines.first)
    let plain = PageTextFormat(font: .helvetica, size: 16)
    let replacement = PageTextLine(
      text: firstLine.text, x: firstLine.x, baseline: firstLine.baseline,
      segments: [.init(text: firstLine.text, x: firstLine.x, format: plain)])
    let rewritten = try rewrite(
      first, lines: [replacement], box: first.box, pageID: savedPage, in: saved.graph)
    let bytes = try pageString(rewritten, pageID: savedPage)
    #expect(bytes.components(separatedBy: PageTextLineWriter.decorationBeginMarker).count == 2)
    let rects = decorationRects(in: bytes)
    #expect(rects.count == 1)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(rewritten)))
    #expect(reopened.string?.contains("First box") == true)
    #expect(reopened.string?.contains("Second box") == true)
  }

  @Test func editingPreviewHidesPreviouslyPaintedDecorations() throws {
    let (graph, pageID, authored) = try decoratedPage()
    let hidden = try PageTextEditing.hidingParagraph(
      pageID: pageID, originalText: authored.originalText,
      standardFontAdvances: standardAdvances(for: authored), in: graph)
    let hiddenBytes = try pageString(hidden, pageID: pageID)
    #expect(!hiddenBytes.contains(PageTextLineWriter.decorationBeginMarker))
    #expect(decorationRects(in: hiddenBytes).isEmpty)
    let sourceBytes = try pageString(graph, pageID: pageID)
    #expect(sourceBytes.contains(PageTextLineWriter.decorationBeginMarker))
    #expect(decorationRects(in: sourceBytes).count == 2)
  }

  @Test func subscriptRoundTripsAsNegativeRise() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 16, rise: -3.2)
    let text = "H2O"
    let line = PageTextLine(
      text: text, x: 72, baseline: 700,
      segments: [.init(text: text, x: 72, format: format, width: 40)])
    let box = PageTextBox(x: 72, firstBaseline: 700, width: 300, lineSpacing: 22)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)]),
      to: parsed.graph)
    let saved = try PDFParser.parse(PDFWriter.write(graph))
    let savedPage = try #require(saved.pageIDs.first)
    let content = try PageContent.load(pageID: savedPage, in: saved.graph)
    let bytes = String(decoding: content.bytes, as: UTF8.self)
    #expect(bytes.contains(" Ts"))
    #expect(bytes.contains("-3.2"))
    let boxes = try AuthoredPageTextBoxes.read(pageID: savedPage, in: saved.graph)
    let segment = try #require(boxes.first?.lines.first?.segments.first)
    #expect(abs(segment.format.rise + 3.2) < 0.001)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    #expect(reopened.string?.contains(text) == true)
  }

  @Test func characterSpacingRoundTripsThroughPageContent() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 16, characterSpacing: 0.5)
    let text = "Tracked"
    let line = PageTextLine(
      text: text, x: 72, baseline: 700,
      segments: [.init(text: text, x: 72, format: format, width: 70)])
    let box = PageTextBox(x: 72, firstBaseline: 700, width: 300, lineSpacing: 22)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)]),
      to: parsed.graph)
    let saved = try PDFParser.parse(PDFWriter.write(graph))
    let savedPage = try #require(saved.pageIDs.first)
    let content = try PageContent.load(pageID: savedPage, in: saved.graph)
    let bytes = String(decoding: content.bytes, as: UTF8.self)
    #expect(bytes.contains("0.5 Tc"))
    let boxes = try AuthoredPageTextBoxes.read(pageID: savedPage, in: saved.graph)
    let segment = try #require(boxes.first?.lines.first?.segments.first)
    #expect(abs(segment.format.characterSpacing - 0.5) < 0.001)
  }
}
