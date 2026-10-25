import AppKit
import Foundation
@testable import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// TXT-04: authored paragraph identity must survive deliberately wide leading.
/// The 1.8× vertical-gap heuristic is a fallback for source-only layouts; it
/// must not split or merge reopened authored boxes.
@Suite("Authored paragraph spacing")
struct AuthoredParagraphSpacingTests {
  private func line(_ text: String, x: Double, baseline: Double,
    format: PageTextFormat) -> PageTextLine {
    PageTextLine(text: text, x: x, baseline: baseline,
      segments: [PageTextSegment(text: text, x: x, format: format)])
  }

  @MainActor private func targets(_ graph: PDFGraph, pageID: PDFObjectID,
    document: PDFDocument) throws -> [PageTextTarget] {
    let page = try #require(document.page(at: 0))
    let blocks = try PageTextEditing.blocks(pageID: pageID, in: graph)
    return NativeParagraphEditing.targets(
      from: blocks, pageID: pageID, graph: graph, page: page, pageIndex: 0)
  }

  @Test @MainActor func widelySpacedAuthoredParagraphStaysSelectableAndEditableAfterReopen() throws {
    let parsed = try PDFParser.parse(BlankPDF.data(format: .letter))
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 12)
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(
        pageID: pageID,
        lines: [
          line("First line of a deliberately wide paragraph.", x: 72, baseline: 700,
            format: format),
          line("Second line stays in the same paragraph.", x: 72, baseline: 650,
            format: format),
          line("Third line stays in the same paragraph.", x: 72, baseline: 600,
            format: format),
        ],
        box: PageTextBox(x: 72, firstBaseline: 700, width: 340,
          lineSpacing: 50, wraps: true))
    ]), to: graph)
    // This neighbor is close enough for the fallback 1.8× gap rule to merge.
    graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(
        pageID: pageID,
        lines: [line("Neighbor paragraph stays separate.", x: 72, baseline: 580,
          format: format)],
        box: PageTextBox(x: 72, firstBaseline: 580, width: 220,
          lineSpacing: 14, wraps: true))
    ]), to: graph)

    let saved = try PDFWriter.write(graph)
    let reopened = try PDFParser.parse(saved)
    let reopenedPageID = try #require(reopened.pageIDs.first)
    let document = try #require(PDFDocument(data: saved))
    let authored = try AuthoredPageTextBoxes.read(pageID: reopenedPageID, in: reopened.graph)
    #expect(authored.count == 2)
    let discovered = try targets(reopened.graph, pageID: reopenedPageID, document: document)
    let wide = try #require(discovered.first { $0.text.contains("First line") })
    let paragraph = try #require(wide.paragraph)
    #expect(paragraph.originalText.count == 3)
    #expect(abs(paragraph.lineSpacing - 50) < 0.01)
    #expect(wide.text.contains("Third line"))
    #expect(!wide.text.contains("Neighbor"))
    let neighbor = try #require(discovered.first { $0.text.contains("Neighbor paragraph") })
    #expect(neighbor.text == "Neighbor paragraph stays separate.")
    #expect(neighbor.paragraph?.originalText.count == 1)
    #expect(abs((neighbor.paragraph?.lineSpacing ?? 0) - 14) < 0.01)
    let neighborRect = neighbor.rect

    let authoredBox = try #require(authored.first { box in
      box.originalText.keys.contains(wide.runIndex)
    })
    var updated = authoredBox.lines
    let first = try #require(updated.first)
    let editedText = first.text + " Edited."
    let firstFormat = try #require(first.segments.first?.format)
    updated[0] = line(editedText, x: first.x, baseline: first.baseline, format: firstFormat)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(
        pageID: reopenedPageID, originalText: paragraph.originalText, lines: updated,
        fontSize: firstFormat.size, color: firstFormat.color,
        standardFontAdvances: paragraph.standardFontAdvances,
        sourceRunOutputCounts: paragraph.sourceRunOutputCounts, box: authoredBox.box)
    ]), to: reopened.graph)

    let editedBytes = try PDFWriter.write(edited)
    let editedReopen = try PDFParser.parse(editedBytes)
    let editedPageID = try #require(editedReopen.pageIDs.first)
    let editedDocument = try #require(PDFDocument(data: editedBytes))
    let after = try targets(editedReopen.graph, pageID: editedPageID, document: editedDocument)
    let editedWide = try #require(after.first { $0.text.contains("First line") })
    #expect(editedWide.text.contains("Edited."))
    #expect(editedWide.text.contains("Third line"))
    #expect(!editedWide.text.contains("Neighbor"))
    #expect(editedWide.paragraph?.originalText.count == 3)
    let editedNeighbor = try #require(after.first { $0.text.contains("Neighbor paragraph") })
    #expect(editedNeighbor.text == "Neighbor paragraph stays separate.")
    #expect(editedNeighbor.paragraph?.originalText.count == 1)
    #expect(editedNeighbor.rect == neighborRect)
    #expect(try AuthoredPageTextBoxes.read(pageID: editedPageID, in: editedReopen.graph).count == 2)
  }
}
