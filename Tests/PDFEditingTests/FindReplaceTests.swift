import Foundation
import PDFCore
import PDFFixtures
import PDFKit
@testable import PDFEditing
import Testing

@Suite("Previewed find and replace")
struct FindReplaceTests {
  private func fixture(pages: Int = 2) throws -> (PDFGraph, [PDFObjectID]) {
    let graph = PDFFixtures.graph(pages: pages)
    return (graph, try PDFPageTree.pageIDs(in: graph))
  }

  private func preview(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], current: Int,
    scope: FindReplaceScope, query: String, replacement: String,
    selection: [[Double]]? = nil
  ) throws -> FindReplacePreview {
    let request = FindReplaceRequest(
      scope: scope, pageIDs: pageIDs, currentPageIndex: current,
      selectionRects: selection, query: query, replacement: replacement)
    return try FindReplace.preview(request, in: graph)
  }

  @Test func documentPreviewAndSingleTransactionApply() throws {
    let (graph, pages) = try fixture()
    let preview = try preview(
      graph, pageIDs: pages, current: 0, scope: .document,
      query: "fixture", replacement: "fix")
    #expect(preview.matches.count == 2)
    #expect(preview.eligibleCount == 2)
    #expect(preview.refusedCount == 0)
    #expect(preview.matches.allSatisfy { $0.text == "fixture" })
    let command = try #require(preview.command)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(edited)))
    #expect(reopened.string?.contains("sPDF Editor fix - page 1") == true)
    #expect(reopened.string?.contains("sPDF Editor fix - page 2") == true)
    #expect(graph.objects.keys.count > 0)
  }

  @Test func pageAndSelectionScopesNarrowResults() throws {
    let (graph, pages) = try fixture()
    let page = try preview(
      graph, pageIDs: pages, current: 0, scope: .page,
      query: "fixture", replacement: "fix")
    #expect(page.eligibleCount == 1)
    #expect(page.matches.first?.pageIndex == 0)

    let selection = try preview(
      graph, pageIDs: pages, current: 0, scope: .selection,
      query: "fixture", replacement: "fix", selection: [[38, 694, 420, 720]])
    #expect(selection.eligibleCount == 1)
    #expect(selection.matches.first?.pageIndex == 0)

    let empty = try preview(
      graph, pageIDs: pages, current: 1, scope: .selection,
      query: "fixture", replacement: "fix", selection: [[38, 694, 60, 720]])
    #expect(empty.matches.isEmpty)
  }

  @Test func repeatedMatchesInOneRunAreOneReplacementEdit() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 12)
    let text = "banana banana"
    var graph = parsed.graph
    graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(
        pageID: pageID,
        lines: [.init(
          text: text, x: 72, baseline: 700,
          segments: [.init(text: text, x: 72, format: format)])],
        box: PageTextBox(x: 72, firstBaseline: 700, width: 260, lineSpacing: 16))
    ]), to: graph)
    let preview = try preview(
      graph, pageIDs: [pageID], current: 0, scope: .page,
      query: "banana", replacement: "apple")
    #expect(preview.matches.count == 2)
    #expect(preview.eligibleCount == 2)
    let command = try #require(preview.command)
    #expect(command.replacements[pageID]?.count == 1)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(edited)))
    #expect(reopened.string?.contains("apple apple") == true)
  }

  @Test func multipleRunsOnOnePageAreReplacedByOneCommand() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let format = PageTextFormat(font: .helvetica, size: 12)
    func line(_ text: String, _ baseline: Double) -> PageTextLine {
      .init(text: text, x: 72, baseline: baseline,
        segments: [.init(text: text, x: 72, format: format)])
    }
    let graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(
        pageID: pageID,
        lines: [line("banana", 700), line("banana", 678)],
        box: PageTextBox(x: 72, firstBaseline: 700, width: 260, lineSpacing: 22))
    ]), to: parsed.graph)
    let preview = try preview(
      graph, pageIDs: [pageID], current: 0, scope: .page,
      query: "banana", replacement: "apple")
    #expect(preview.eligibleCount == 2)
    let command = try #require(preview.command)
    #expect(command.replacements[pageID]?.count == 2)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try #require(PDFDocument(data: try PDFWriter.write(edited)))
    #expect(reopened.string?.components(separatedBy: "apple").count == 3)
  }

  @Test func mixedFontMatchIsIndividuallyRefused() throws {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let pageID = try #require(parsed.pageIDs.first)
    let first = PageTextFormat(font: .helvetica, size: 12)
    let second = PageTextFormat(font: .times, size: 12)
    let line = PageTextLine(
      text: "Hello world", x: 72, baseline: 700,
      segments: [
        .init(text: "Hello ", x: 72, format: first),
        .init(text: "world", x: 110, format: second),
      ])
    let graph = try PDFEditingEngine.commit(PDFTransaction([
      AddPageTextLinesCommand(
        pageID: pageID, lines: [line],
        box: PageTextBox(x: 72, firstBaseline: 700, width: 300, lineSpacing: 16))
    ]), to: parsed.graph)
    let preview = try preview(
      graph, pageIDs: [pageID], current: 0, scope: .page,
      query: "Hello world", replacement: "Hi")
    let match = try #require(preview.matches.first)
    #expect(preview.eligibleCount == 0)
    #expect(match.eligibility.reason?.contains("font or text-run boundary") == true)
    #expect(preview.command == nil)
  }

  @Test func lineBoundaryMatchIsReportedAsRefused() throws {
    let (graph, pages) = try fixture()
    let preview = try preview(
      graph, pageIDs: pages, current: 0, scope: .page,
      query: "fixture - page 1 Original",
      replacement: "fixture - page 1 Changed")
    #expect(preview.eligibleCount == 0)
    #expect(preview.matches.contains { $0.eligibility.reason?.contains("line boundary") == true })
    #expect(preview.command == nil)
  }
}
