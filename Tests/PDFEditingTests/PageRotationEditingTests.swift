import CoreText
import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import PDFKit
import Testing

/// TXT-09: inline editing keeps working on pages whose /Rotate turns the
/// page-space text on screen. The editor shows a display-only upright copy and
/// the saved page rotation is never changed.
@Suite("Rotated page editing")
struct PageRotationEditingTests {
  private func rotation(of pageID: PDFObjectID, in graph: PDFGraph) -> Int? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    switch page[PDFName("Rotate")] {
    case .integer(let raw)?: return Int(exactly: raw)
    case nil: return 0
    default: return nil
    }
  }

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

  private func authoredTextPage(
    text: String = "Rotated words", baseline: Double = 700
  ) throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 16)
    let line = PageTextLine(
      text: text, x: 72, baseline: baseline,
      segments: [.init(text: text, x: 72, format: format, width: 90)])
    let box = PageTextBox(x: 72, firstBaseline: baseline, width: 300, lineSpacing: 22)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)]),
      to: parsed.graph)
    return (graph, pageID)
  }

  @Test func uprightPreviewOverridesRotationWithoutMutatingTheSource() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]),
      to: parsed.graph)
    #expect(rotation(of: pageID, in: rotated) == 90)
    let upright = try PageRotationPreview.upright(pageID: pageID, in: rotated)
    #expect(rotation(of: pageID, in: rotated) == 90)
    #expect(rotation(of: pageID, in: upright) == 0)
    let savedRotation = try #require(
      PDFDocument(data: try PDFWriter.write(rotated))?.page(at: 0)?.rotation)
    #expect(savedRotation == 90)
    let previewRotation = try #require(
      PDFDocument(data: try PDFWriter.write(upright))?.page(at: 0)?.rotation)
    #expect(previewRotation == 0)
  }

  @Test func uprightPreviewAlsoOverridesInheritedRotation() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    var graph = parsed.graph
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .reference(let parentID)? = page[PDFName("Parent")],
      case .dictionary(var parent)? = graph.objects[parentID]
    else { throw PDFError(.malformed, "Blank page has no page-tree parent") }
    parent[PDFName("Rotate")] = .integer(90)
    graph.objects[parentID] = .dictionary(parent)
    page[PDFName("Rotate")] = nil
    graph.objects[pageID] = .dictionary(page)
    #expect(PDFDocument(data: try PDFWriter.write(graph))?.page(at: 0)?.rotation == 90)
    let upright = try PageRotationPreview.upright(pageID: pageID, in: graph)
    #expect(PDFDocument(data: try PDFWriter.write(upright))?.page(at: 0)?.rotation == 0)
    #expect(rotation(of: pageID, in: upright) == 0)
  }

  @Test func rewritingPageSpaceTextOnARotatedPageKeepsTheRotation() throws {
    let (graph, pageID) = try authoredTextPage()
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]),
      to: graph)
    let authored = try #require(
      try AuthoredPageTextBoxes.read(pageID: pageID, in: rotated).first)
    let line = try #require(authored.lines.first)
    let format = PageTextFormat(font: .helvetica, size: 16)
    let replacement = PageTextLine(
      text: "Rotated edits", x: line.x, baseline: line.baseline,
      segments: [.init(text: "Rotated edits", x: line.x, format: format)])
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: authored.originalText, lines: [replacement],
      fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: standardAdvances(for: authored), box: authored.box)
    let rewritten = try PDFEditingEngine.commit(PDFTransaction([command]), to: rotated)
    #expect(rotation(of: pageID, in: rewritten) == 90)
    let bytes = try PDFWriter.write(rewritten)
    let reopened = try #require(PDFDocument(data: bytes))
    #expect(reopened.page(at: 0)?.rotation == 90)
    #expect(reopened.string?.contains("Rotated edits") == true)
    let parsed = try PDFParser.parse(bytes)
    #expect(rotation(of: try #require(parsed.pageIDs.first), in: parsed.graph) == 90)
  }

  @Test func addingTextToARotatedPageKeepsTheRotation() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 270)]),
      to: parsed.graph)
    let format = PageTextFormat(font: .helvetica, size: 18)
    let line = PageTextLine(
      text: "New rotated page text", x: 72, baseline: 700,
      segments: [.init(text: "New rotated page text", x: 72, format: format, width: 160)])
    let box = PageTextBox(x: 72, firstBaseline: 700, width: 360, lineSpacing: 24)
    let added = try PDFEditingEngine.commit(
      PDFTransaction([AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)]),
      to: rotated)
    #expect(rotation(of: pageID, in: added) == 270)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(added)))
    #expect(reopened.page(at: 0)?.rotation == 270)
    #expect(reopened.string?.contains("New rotated page text") == true)
  }
}
