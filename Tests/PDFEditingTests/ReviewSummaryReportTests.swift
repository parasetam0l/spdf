import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// REV-04 evidence: a printable review summary with page context images,
/// numbered comment anchors, reply threads, filters, stable identities and a
/// deterministic PDF structure.
@Suite("Review summary report (REV-04)")
struct ReviewSummaryReportTests {
  // MARK: Fixtures

  private struct Fixture {
    let graph: PDFGraph
    let pageIDs: [PDFObjectID]
  }

  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private func makeFixture() throws -> Fixture {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    var graph = parsed.graph
    graph = try commit(
      [
        AddHighlightCommand(
          pageID: pageIDs[0],
          quads: [40, 730, 120, 730, 40, 710, 120, 710],
          contents: "Fix the intro", author: "Alice",
          modified: "D:20260101120000Z", subject: "Edit request")
      ], to: graph)
    graph = try commit(
      [
        AddReplyCommand(
          pageID: pageIDs[0], annotationIndex: 0, text: "Agreed, will fix",
          author: "Bob", modified: "D:20260102120000Z")
      ], to: graph)
    graph = try commit(
      [
        AddHighlightCommand(
          pageID: pageIDs[2],
          quads: [300, 730, 400, 730, 300, 710, 400, 710],
          contents: "Remove stale chart", author: "Bob",
          modified: "D:20260201120000Z")
      ], to: graph)
    graph = try commit(
      [
        SetAnnotationStateCommand(
          pageID: pageIDs[0], annotationIndex: 0, state: PDFName("Accepted"))
      ], to: graph)
    try setIdentity("REV-100", pageID: pageIDs[0], annotationIndex: 0, in: &graph)
    return Fixture(graph: graph, pageIDs: pageIDs)
  }

  private func setIdentity(
    _ identity: String, pageID: PDFObjectID, annotationIndex: Int, in graph: inout PDFGraph
  ) throws {
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    guard annotations.indices.contains(annotationIndex),
      let objectID = annotations[annotationIndex].objectID,
      case .dictionary(var dictionary)? = graph.objects[objectID]
    else {
      Issue.record("Fixture annotation is missing")
      return
    }
    dictionary[PDFName("NM")] = .string(Data(identity.utf8))
    graph.objects[objectID] = .dictionary(dictionary)
  }

  private func raster(_ color: UInt8 = 180) -> ReportRasterImage {
    ReportRasterImage(
      width: 4, height: 4, rgb8: Data(repeating: color, count: 4 * 4 * 3))
  }

  private func reportText(_ data: Data) throws -> String {
    let parsed = try PDFParser.parse(data)
    var lines: [String] = []
    for pageID in parsed.pageIDs {
      let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
      lines.append(layout.lines.map { layout.text(in: $0) }.joined(separator: "\n"))
    }
    return lines.joined(separator: "\n")
  }

  // MARK: Tests

  @Test func reportCarriesIdentitiesAnchorsThreadsAndContext() throws {
    let fixture = try makeFixture()
    let image = ReviewSummaryPageImage(pageIndex: 0, image: raster())
    let report = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs, pageImages: [image])
    #expect(report.entries.count == 2)
    #expect(report.totalDocumentComments == 3)
    #expect(report.includedCommentCount == 3)
    #expect(report.includedReplyCount == 1)
    #expect(report.pagesWithComments == [0, 2])
    #expect(report.pagesWithImages == [0])
    #expect(report.entries[0].identity == "REV-100")
    #expect(report.entries[0].anchor == 1)
    #expect(report.entries[0].author == "Alice")
    #expect(report.entries[0].subject == "Edit request")
    #expect(report.entries[0].state == "Accepted")
    #expect(report.entries[0].replies.count == 1)
    #expect(report.entries[0].replies[0].author == "Bob")
    #expect(report.entries[0].replies[0].replyToIdentity == "REV-100")
    #expect(report.entries[1].identity.hasPrefix("spdf-"))
    #expect(report.entries[1].anchor == 2)
    let data = try PDFWriter.write(fixture.graph)
    #expect(try PDFWriter.write(fixture.graph) == data, "Reporting must not mutate the source")
    #expect(try PDFParser.parse(report.data).pageIDs.count == report.pageCount)
    let text = try reportText(report.data)
    #expect(text.contains("Review Summary"))
    #expect(text.contains("REV-100"))
    #expect(text.contains("Fix the intro"))
    #expect(text.contains("Agreed, will fix"))
    #expect(text.contains("Author: Alice"))
    #expect(text.contains("Author: Bob"))
    #expect(text.contains("Accepted"))
    #expect(text.contains("Anchor 1"))
    #expect(text.contains("Anchor 2"))
    #expect(text.contains("Page context"))
    #expect(text.contains("Comment details"))
    #expect(text.contains("Reply |"))
    #expect(text.contains("Page 1"))
    #expect(text.contains("Page 3"))
  }

  @Test func filtersSelectAuthorsTypesStatesTextPagesAndDates() throws {
    let fixture = try makeFixture()
    var aliceFilter = CommentFilter()
    aliceFilter.author = "Alice"
    let byAuthor = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(filter: aliceFilter))
    #expect(byAuthor.entries.count == 1)
    #expect(byAuthor.entries[0].identity == "REV-100")
    // Filters apply to every annotation, including replies: Bob's reply is not
    // part of an Alice-only report.
    #expect(byAuthor.entries[0].replies.isEmpty)
    #expect(byAuthor.includedCommentCount == 1)
    let authorText = try reportText(byAuthor.data)
    #expect(authorText.contains("author \"Alice\""))

    var acceptedFilter = CommentFilter()
    acceptedFilter.state = PDFName("Accepted")
    let byState = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(filter: acceptedFilter))
    #expect(byState.entries.count == 1)
    #expect(byState.entries[0].state == "Accepted")

    var noteFilter = CommentFilter()
    noteFilter.subtype = PDFName("Text")
    let byType = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(filter: noteFilter))
    #expect(byType.entries.count == 1)
    #expect(byType.entries[0].replyToIdentity == "REV-100")
    #expect(byType.entries[0].contents == "Agreed, will fix")

    var chartFilter = CommentFilter()
    chartFilter.text = "stale chart"
    let byText = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(filter: chartFilter))
    #expect(byText.entries.count == 1)
    #expect(byText.entries[0].pageIndex == 2)

    let byPage = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(pageIndices: [2]))
    #expect(byPage.entries.count == 1)
    #expect(byPage.pagesWithComments == [2])

    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    parser.dateFormat = "yyyy-MM-dd"
    let after = try #require(parser.date(from: "2026-01-15"))
    let byDate = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(
        filter: CommentFilter(modifiedOnOrAfter: after)))
    #expect(byDate.entries.count == 1)
    #expect(byDate.entries[0].pageIndex == 2)
  }

  @Test func replyThreadsCanBeDisabledAndOrphanRepliesStayVisible() throws {
    let fixture = try makeFixture()
    let withoutThreads = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(includeReplyThreads: false))
    #expect(withoutThreads.entries.count == 3)
    #expect(withoutThreads.entries.allSatisfy { $0.replies.isEmpty })
    let replyEntry = try #require(withoutThreads.entries.first {
      $0.contents == "Agreed, will fix"
    })
    #expect(replyEntry.replyToIdentity == "REV-100")
    let text = try reportText(withoutThreads.data)
    #expect(text.contains("parent comment is not included"))
  }

  @Test func noMatchesStillProducesARecordableReport() throws {
    let fixture = try makeFixture()
    var filter = CommentFilter()
    filter.author = "Nobody"
    let report = try ReviewSummaryReportBuilder.build(
      graph: fixture.graph, pageIDs: fixture.pageIDs,
      options: ReviewSummaryOptions(filter: filter))
    #expect(report.entries.isEmpty)
    #expect(report.includedCommentCount == 0)
    #expect(report.totalDocumentComments == 3)
    #expect(report.filterDescription.contains("author"))
    let text = try reportText(report.data)
    #expect(text.contains("No review comments match"))
    #expect(text.contains("Nobody"))
  }

  @Test func nonWinAnsiTextIsShownWithExactUTF8Appendix() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    let original = "Gizli Şirket – müşteri"
    let graph = try commit(
      [
        AddHighlightCommand(
          pageID: pageIDs[0], quads: [40, 730, 120, 730, 40, 710, 120, 710],
          contents: original, author: "Ayşe")
      ], to: parsed.graph)
    let report = try ReviewSummaryReportBuilder.build(graph: graph, pageIDs: pageIDs)
    #expect(report.entries.count == 1)
    #expect(report.entries[0].contents == original)
    #expect(report.entries[0].author == "Ayşe")
    let hex = Array(original.utf8).map { String(format: "%02X", $0) }.joined()
    let text = try reportText(report.data)
    #expect(text.contains("Exact UTF-8:"))
    #expect(text.contains(hex))
    #expect(text.contains("?"))
  }

  @Test func rotatedPageContextAndDeterministicBytes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.annotationPages())
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    let options = ReviewSummaryOptions(
      title: "Rotated Review", sourceDescription: "annotation-pages.pdf",
      documentRevision: 7, generatedOn: "2026-10-25 12:00", pageIndices: [1])
    let first = try ReviewSummaryReportBuilder.build(
      graph: parsed.graph, pageIDs: pageIDs,
      pageImages: [ReviewSummaryPageImage(pageIndex: 1, image: raster(90))],
      options: options)
    let second = try ReviewSummaryReportBuilder.build(
      graph: parsed.graph, pageIDs: pageIDs,
      pageImages: [ReviewSummaryPageImage(pageIndex: 1, image: raster(90))],
      options: options)
    #expect(first.entries.count == 1)
    #expect(first.entries[0].pageIndex == 1)
    #expect(first.data == second.data, "Identical inputs must produce identical report bytes")
    #expect(first.pageCount == second.pageCount)
    let text = try reportText(first.data)
    #expect(text.contains("Rotated Review"))
    #expect(text.contains("annotation-pages.pdf"))
    #expect(text.contains("Document revision: 7"))
    #expect(text.contains("Generated: 2026-10-25 12:00"))
    #expect(text.contains("Rotated-page note"))
    #expect(text.contains("Page 2"))
    // Generated-on text is the only provenance; without it the report stays
    // deterministic for the same filters and images.
    let plain = try ReviewSummaryReportBuilder.build(graph: parsed.graph, pageIDs: pageIDs)
    let plainAgain = try ReviewSummaryReportBuilder.build(graph: parsed.graph, pageIDs: pageIDs)
    #expect(plain.data == plainAgain.data)
  }

  @Test func invalidInputsAreRefused() throws {
    let fixture = try makeFixture()
    #expect(throws: PDFError.self) {
      _ = try ReviewSummaryReportBuilder.build(graph: fixture.graph, pageIDs: [])
    }
    let badImage = ReviewSummaryPageImage(
      pageIndex: 0, image: ReportRasterImage(width: 2, height: 2, rgb8: Data([1, 2, 3])))
    #expect(throws: PDFError.self) {
      _ = try ReviewSummaryReportBuilder.build(
        graph: fixture.graph, pageIDs: fixture.pageIDs, pageImages: [badImage])
    }
  }

  @Test func filterDescriptionIsExplicit() {
    var filter = CommentFilter()
    filter.author = "Alice"
    filter.subtype = PDFName("Highlight")
    filter.state = PDFName("Accepted")
    filter.text = "intro"
    let description = ReviewSummaryReportBuilder.describe(
      filter: filter, pageIndices: [0, 2])
    #expect(description.contains("pages 1, 3"))
    #expect(description.contains("Highlight"))
    #expect(description.contains("Accepted"))
    #expect(description.contains("Alice"))
    #expect(description.contains("intro"))
  }
}
