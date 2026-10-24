import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-014/P22-015 evidence: threaded replies with /IRT relationships and
/// review-status writing with filtering.
@Suite("Replies and review status")
struct ReplyAndStatusTests {
  @Test func replyCreatesThreadedNoteAtParentCorner() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let quads: [Double] = [42, 770, 102, 770, 42, 710, 102, 710]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(pageID: pageID, quads: quads, contents: "original")
      ]), to: parsed.graph)
    let replied = try PDFEditingEngine.commit(
      PDFTransaction([
        AddReplyCommand(
          pageID: pageID, annotationIndex: 0, text: "Agreed", author: "Ada",
          modified: "D:20261011120000Z")
      ]), to: marked)
    let comments = try CommentList.comments(in: replied, pageIDs: [pageID])
    #expect(comments.count == 2)
    let parent = comments[0]
    let reply = comments[1]
    #expect(reply.subtype == PDFName("Text"))
    #expect(reply.contents == "Agreed")
    #expect(reply.author == "Ada")
    #expect(reply.annotation.iconName == PDFName("Comment"))
    #expect(reply.replyTo == parent.annotation.objectID)
    #expect(reply.annotation.rect == [82, 750, 102, 770])

    let threads = CommentList.threads(in: replied, pageIDs: [pageID])
    #expect(threads.count == 1)
    #expect(threads[0].root.annotation.objectID == parent.annotation.objectID)
    #expect(threads[0].replies.map(\.contents) == ["Agreed"])

    // Filtering out the parent promotes the reply so it stays visible.
    let textOnly = CommentList.threads(
      in: replied, pageIDs: [pageID], filter: CommentFilter(subtype: PDFName("Text")))
    #expect(textOnly.count == 1)
    #expect(textOnly[0].root.contents == "Agreed")
    #expect(textOnly[0].replies.isEmpty)

    // Deleting the parent is refused while a reply references it.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]), to: replied)
    }
    // Deleting the reply itself is allowed and leaves the root alone.
    let replyDeleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 1)]), to: replied)
    let remaining = CommentList.threads(in: replyDeleted, pageIDs: [pageID])
    #expect(remaining.count == 1)
    #expect(remaining[0].replies.isEmpty)
    #expect(try PDFParser.parse(PDFWriter.write(replyDeleted)).graph == replyDeleted)
  }

  @Test func replyRefusesInvalidInput() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: [42, 770, 102, 770, 42, 710, 102, 710])
      ]), to: parsed.graph)
    func refuse(_ command: any PDFEditCommand, in graph: PDFGraph) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    refuse(AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "   "), in: marked)
    refuse(
      AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "x", size: 200), in: marked)
    refuse(
      AddReplyCommand(pageID: pageID, annotationIndex: 99, text: "x"), in: marked)

    // Direct dictionary parents cannot carry /IRT relationships.
    var direct = parsed.graph
    guard case .dictionary(var page)? = direct.objects[pageID] else {
      Issue.record("Fixture page is missing")
      return
    }
    page[PDFName("Annots")] = .array([
      .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Highlight")),
        PDFName("Rect"): .array([.integer(10), .integer(10), .integer(60), .integer(60)]),
      ])
    ])
    direct.objects[pageID] = .dictionary(page)
    refuse(AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "x"), in: direct)
  }

  @Test func bulkStatusUpdatesAreAtomic() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: [42, 770, 102, 770, 42, 710, 102, 710], contents: "one"),
        AddNoteCommand(pageID: pageID, at: [20, 20], contents: "two"),
      ]), to: parsed.graph)
    let comments = CommentList.comments(in: marked, pageIDs: [pageID])
    #expect(comments.count == 2)
    let updated = try PDFEditingEngine.commit(
      PDFTransaction(
        comments.map {
          SetAnnotationStateCommand(
            pageID: $0.pageID, annotationIndex: $0.annotation.index, state: PDFName("Accepted"))
        }), to: marked)
    #expect(
      CommentList.comments(in: updated, pageIDs: [pageID]).map(\.reviewState)
        == [PDFName("Accepted"), PDFName("Accepted")])
    let reopened = try PDFParser.parse(PDFWriter.write(updated))
    #expect(
      CommentList.comments(in: reopened.graph, pageIDs: [pageID]).allSatisfy {
        $0.reviewState == PDFName("Accepted")
      })
    let cleared = try PDFEditingEngine.commit(
      PDFTransaction(
        comments.map {
          SetAnnotationStateCommand(
            pageID: $0.pageID, annotationIndex: $0.annotation.index, state: nil)
        }), to: updated)
    #expect(
      CommentList.comments(in: cleared, pageIDs: [pageID]).allSatisfy {
        $0.reviewState == PDFName("None")
      })
  }

  @Test func statusRoundTripAndFiltering() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let quads: [Double] = [42, 770, 102, 770, 42, 710, 102, 710]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([AddHighlightCommand(pageID: pageID, quads: quads)]), to: parsed.graph)

    let accepted = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStateCommand(pageID: pageID, annotationIndex: 0, state: PDFName("Accepted"))
      ]), to: marked)
    var comment = try #require(
      try CommentList.comments(in: accepted, pageIDs: [pageID]).first)
    #expect(comment.reviewState == PDFName("Accepted"))
    #expect(
      comment.annotation.dictionary[PDFName("StateModel")] == .name(PDFName("Marked")))
    #expect(
      CommentList.filter([comment], by: CommentFilter(state: PDFName("Accepted"))).count == 1)
    #expect(CommentList.filter([comment], by: CommentFilter(state: PDFName("None"))).isEmpty)

    // Changing and clearing the status keeps the model consistent.
    let rejected = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStateCommand(pageID: pageID, annotationIndex: 0, state: PDFName("Rejected"))
      ]), to: accepted)
    comment = try #require(try CommentList.comments(in: rejected, pageIDs: [pageID]).first)
    #expect(comment.reviewState == PDFName("Rejected"))
    let cleared = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStateCommand(pageID: pageID, annotationIndex: 0, state: nil)
      ]), to: rejected)
    comment = try #require(try CommentList.comments(in: cleared, pageIDs: [pageID]).first)
    #expect(comment.reviewState == PDFName("None"))
    #expect(comment.annotation.dictionary[PDFName("State")] == nil)
    #expect(comment.annotation.dictionary[PDFName("StateModel")] == nil)
    let clearedExplicitly = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStateCommand(
          pageID: pageID, annotationIndex: 0, state: PDFName("None"))
      ]), to: accepted)
    comment = try #require(try CommentList.comments(in: clearedExplicitly, pageIDs: [pageID]).first)
    #expect(comment.reviewState == PDFName("None"))

    // Links have no review status, and unknown statuses are refused.
    let linked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLinkCommand(
          pageID: pageID, rect: [10, 10, 60, 30], target: .uri("https://example.com"))
      ]), to: marked)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetAnnotationStateCommand(pageID: pageID, annotationIndex: 1, state: PDFName("Accepted"))
        ]), to: linked)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetAnnotationStateCommand(pageID: pageID, annotationIndex: 0, state: PDFName("Bogus"))
        ]), to: marked)
    }
    #expect(try PDFParser.parse(PDFWriter.write(cleared)).graph == cleared)
  }

  @Test func threadsGroupMultipleRepliesInOrder() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let quads: [Double] = [42, 770, 102, 770, 42, 710, 102, 710]
    var graph = try PDFEditingEngine.commit(
      PDFTransaction([AddHighlightCommand(pageID: pageID, quads: quads)]), to: parsed.graph)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([AddNoteCommand(pageID: pageID, at: [200, 200], contents: "standalone")]),
      to: graph)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "first")]),
      to: graph)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "second")]),
      to: graph)
    let threads = CommentList.threads(in: graph, pageIDs: [pageID])
    #expect(threads.count == 2)
    #expect(threads[0].root.subtype == PDFName("Highlight"))
    #expect(threads[0].replies.map(\.contents) == ["first", "second"])
    #expect(threads[1].root.contents == "standalone")
    #expect(threads[1].replies.isEmpty)
  }
}
