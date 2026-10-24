import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-013/P22-016/P22-017 evidence: annotation metadata, the comment list
/// with page/type/status filtering, and comment ordering.
@Suite("Comment list")
struct CommentListTests {
  @Test func commentsListInPageOrderAndSkipInteractiveControls() throws {
    let (graph, pageIDs) = try annotatedDocument()
    let comments = CommentList.comments(in: graph, pageIDs: pageIDs)
    #expect(comments.count == 4)  // the /Link annotation is not a comment
    #expect(comments.map(\.pageIndex) == [0, 0, 1, 1])
    #expect(
      comments.map(\.subtype) == [
        PDFName("Highlight"), PDFName("Text"), PDFName("Square"), PDFName("Underline"),
      ])
    #expect(comments[0].contents == "first")
    #expect(comments[0].reviewState == PDFName("Accepted"))
    #expect(comments[1].reviewState == PDFName("None"))
    #expect(comments[3].bounds == [10, 10, 60, 34])
  }

  @Test func commentFiltersMatchPageTypeAndStatus() throws {
    let (graph, pageIDs) = try annotatedDocument()
    let comments = CommentList.comments(in: graph, pageIDs: pageIDs)
    #expect(
      CommentList.filter(comments, by: CommentFilter(pageIndex: 1)).map(\.subtype)
        == [PDFName("Square"), PDFName("Underline")])
    #expect(CommentList.filter(comments, by: CommentFilter(subtype: PDFName("Text"))).count == 1)
    #expect(CommentList.filter(comments, by: CommentFilter(state: PDFName("Accepted"))).count == 1)
    #expect(CommentList.filter(comments, by: CommentFilter(state: PDFName("None"))).count == 3)
    #expect(
      CommentList.filter(
        comments,
        by: CommentFilter(
          pageIndex: 0, subtype: PDFName("Highlight"), state: PDFName("Accepted"))
      ).count == 1)
    // Filtering during enumeration produces the same result.
    #expect(
      CommentList.comments(in: graph, pageIDs: pageIDs, filter: CommentFilter(pageIndex: 0)).count
        == 2)
  }

  @Test func commentFiltersMatchTextAndAuthor() throws {
    let (graph, pageIDs) = try annotatedDocument()
    let comments = CommentList.comments(in: graph, pageIDs: pageIDs)
    #expect(CommentList.filter(comments, by: CommentFilter(text: "NOTE")).count == 1)
    #expect(CommentList.filter(comments, by: CommentFilter(text: " reviewed ")).isEmpty)
    #expect(CommentList.filter(comments, by: CommentFilter(author: "ada")).count == 2)
    #expect(
      CommentList.filter(
        comments, by: CommentFilter(pageIndex: 1, text: "ada")
      ).count == 1)
    #expect(
      CommentList.filter(
        comments, by: CommentFilter(text: "note", author: "Grace")
      ).count == 1)
    #expect(
      CommentList.filter(
        comments, by: CommentFilter(text: "note", author: "Ada")
      ).isEmpty)
    #expect(
      CommentList.comments(
        in: graph, pageIDs: pageIDs, filter: CommentFilter(text: "first", author: "Ada")
      ).count == 1)
  }

  @Test func subjectAuthorTimestampAndPrivacyDefaults() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let quads: [Double] = [42, 730, 62, 730, 42, 710, 62, 710]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: quads, contents: "review", author: "Ada",
          modified: "D:20261010120000Z", subject: "Chapter 1")
      ]), to: parsed.graph)
    let annotation = try #require(
      try AnnotationInventory.annotations(in: graph, pageID: pageID).first)
    #expect(annotation.author == "Ada")
    #expect(annotation.subject == "Chapter 1")
    #expect(annotation.modified == "D:20261010120000Z")
    #expect(annotation.state == nil)

    // Defaults never collect identity data.
    let bare = try PDFEditingEngine.commit(
      PDFTransaction([AddHighlightCommand(pageID: pageID, quads: quads)]), to: parsed.graph)
    let bareAnnotation = try #require(
      try AnnotationInventory.annotations(in: bare, pageID: pageID).first)
    #expect(bareAnnotation.author == nil)
    #expect(bareAnnotation.subject == nil)
    #expect(bareAnnotation.modified == nil)
    #expect(bareAnnotation.dictionary[PDFName("T")] == nil)
    #expect(bareAnnotation.dictionary[PDFName("Subj")] == nil)
    #expect(bareAnnotation.dictionary[PDFName("M")] == nil)
  }

  @Test func reviewSummaryFormatsLocalComments() throws {
    let annotation = Annotation(
      pageID: PDFObjectID(3), objectID: nil, index: 0,
      dictionary: [
        PDFName("Subtype"): .name(PDFName("Highlight")),
        PDFName("Contents"): .string(Data("line one\nline two".utf8)),
        PDFName("T"): .string(Data("Ada".utf8)),
        PDFName("M"): .string(Data("D:20261010120000Z".utf8)),
        PDFName("State"): .name(PDFName("Accepted")),
      ])
    let comment = Comment(pageID: PDFObjectID(3), pageIndex: 1, annotation: annotation)
    let summary = CommentSummary.text(comments: [comment])
    #expect(summary.contains("Comments: 1"))
    #expect(summary.contains("Page 2 · Highlight · Accepted · Ada · D:20261010120000Z"))
    #expect(summary.contains("line one line two"))

    let bare = Annotation(
      pageID: PDFObjectID(3), objectID: nil, index: 1,
      dictionary: [PDFName("Subtype"): .name(PDFName("Square"))])
    let bareSummary = CommentSummary.text(
      comments: [Comment(pageID: PDFObjectID(3), pageIndex: 0, annotation: bare)])
    #expect(bareSummary.contains("Page 1 · Square · None"))
    #expect(bareSummary.contains("(no text)"))
    #expect(CommentSummary.text(comments: []).contains("Comments: 0"))
  }

  /// Two pages: highlight (/State /Accepted) plus note and link on page 1;
  /// square and underline on page 2.
  private func annotatedDocument() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    let pageIDs = Array(parsed.pageIDs.prefix(2))
    let quadPoints: [PDFValue] = [
      .integer(10), .integer(34), .integer(60), .integer(34), .integer(10), .integer(10),
      .integer(60), .integer(10),
    ]
    graph.objects[PDFObjectID(200)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Highlight")),
      PDFName("Rect"): .array([.integer(10), .integer(10), .integer(60), .integer(34)]),
      PDFName("QuadPoints"): .array(quadPoints),
      PDFName("Contents"): .string(Data("first".utf8)),
      PDFName("T"): .string(Data("Ada".utf8)),
      PDFName("State"): .name(PDFName("Accepted")),
      PDFName("StateModel"): .name(PDFName("Marked")),
    ])
    graph.objects[PDFObjectID(201)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Text")),
      PDFName("Rect"): .array([.integer(70), .integer(10), .integer(90), .integer(30)]),
      PDFName("Contents"): .string(Data("note".utf8)),
      PDFName("T"): .string(Data("Grace".utf8)),
    ])
    graph.objects[PDFObjectID(202)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Link")),
      PDFName("Rect"): .array([.integer(0), .integer(0), .integer(20), .integer(20)]),
    ])
    graph.objects[PDFObjectID(203)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Square")),
      PDFName("Rect"): .array([.integer(5), .integer(5), .integer(25), .integer(25)]),
      PDFName("T"): .string(Data("Ada".utf8)),
    ])
    graph.objects[PDFObjectID(204)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Underline")),
      PDFName("Rect"): .array([.integer(10), .integer(10), .integer(60), .integer(34)]),
      PDFName("QuadPoints"): .array(quadPoints),
    ])
    func attach(_ annotations: [PDFValue], to pageID: PDFObjectID) throws {
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "Fixture page is missing")
      }
      page[PDFName("Annots")] = .array(annotations)
      graph.objects[pageID] = .dictionary(page)
    }
    try attach(
      [
        .reference(PDFObjectID(200)), .reference(PDFObjectID(201)), .reference(PDFObjectID(202)),
      ], to: pageIDs[0])
    try attach(
      [.reference(PDFObjectID(203)), .reference(PDFObjectID(204))], to: pageIDs[1])
    return (graph, pageIDs)
  }
}
