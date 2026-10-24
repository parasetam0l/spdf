import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// REV-01: XFDF comment exchange and idempotent merge.
@Suite("Comment exchange")
struct CommentExchangeTests {
  private func reviewedDocument() throws -> (PDFGraph, [PDFObjectID]) {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    let highlight = AddHighlightCommand(
      pageID: parsed.pageIDs[0],
      quads: [10, 100, 60, 100, 10, 80, 60, 80],
      color: [1, 1, 0], opacity: 0.5, contents: "Smoke review", author: "Reviewer",
      modified: "D:20261010120000Z", subject: "Review")
    let note = AddNoteCommand(
      pageID: parsed.pageIDs[1], at: [20, 20], contents: "Standalone note",
      author: "Reviewer", modified: "D:20261010120500Z")
    graph = try PDFEditingEngine.commit(
      PDFTransaction([highlight, note]), to: graph)
    let reply = AddReplyCommand(
      pageID: parsed.pageIDs[0], annotationIndex: 0, text: "Smoke reply",
      author: "Reviewer", modified: "D:20261010121000Z")
    graph = try PDFEditingEngine.commit(PDFTransaction([reply]), to: graph)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStateCommand(
          pageID: parsed.pageIDs[0], annotationIndex: 0, state: PDFName("Accepted"))
      ]), to: graph)
    return (graph, parsed.pageIDs)
  }

  @Test func exportAndImportPreserveThreadsStateAndGeometry() throws {
    let (graph, pageIDs) = try reviewedDocument()
    let comments = CommentList.comments(in: graph, pageIDs: pageIDs)
    #expect(comments.count == 3)
    let exported = try CommentExchange.export(comments: comments)
    #expect(exported.exported == 3)
    #expect(exported.skipped.isEmpty)

    let parsed = try CommentExchange.parse(exported.data)
    #expect(parsed.issues.isEmpty)
    #expect(parsed.entries.count == 3)
    let highlight = try #require(
      parsed.entries.first { $0.contents == "Smoke review" })
    #expect(highlight.pageIndex == 0)
    #expect(highlight.state == PDFName("Accepted"))
    #expect(highlight.author == "Reviewer")
    #expect(highlight.quadPoints?.count == 8)
    #expect(!highlight.identity.isEmpty)
    let reply = try #require(parsed.entries.first { $0.contents == "Smoke reply" })
    #expect(reply.inReplyTo == highlight.identity)

    let fresh = try PDFParser.parse(PDFFixtures.threePages())
    let plan = try CommentExchange.plan(
      entries: parsed.entries, issues: parsed.issues, into: fresh.graph,
      pageIDs: fresh.pageIDs)
    #expect(plan.added == 3)
    #expect(plan.updated == 0)
    #expect(plan.unchanged == 0)
    #expect(plan.skipped.isEmpty)
    let imported = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: fresh.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(imported))
    let importedComments = CommentList.comments(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(importedComments.count == 3)
    let threads = CommentList.threads(importedComments, by: CommentFilter())
    #expect(threads.count == 2)
    #expect(
      threads.contains {
        $0.root.contents == "Smoke review" && $0.replies.count == 1
          && $0.replies[0].contents == "Smoke reply"
      })
    #expect(
      importedComments.first { $0.contents == "Smoke review" }?.reviewState
        == PDFName("Accepted"))
  }

  @Test func importingTheSameFileTwiceDoesNotDuplicateComments() throws {
    let (graph, pageIDs) = try reviewedDocument()
    let exported = try CommentExchange.export(
      comments: CommentList.comments(in: graph, pageIDs: pageIDs))
    let parsed = try CommentExchange.parse(exported.data)
    let fresh = try PDFParser.parse(PDFFixtures.threePages())
    let firstPlan = try CommentExchange.plan(
      entries: parsed.entries, issues: parsed.issues, into: fresh.graph,
      pageIDs: fresh.pageIDs)
    let imported = try PDFEditingEngine.commit(
      PDFTransaction(firstPlan.commands), to: fresh.graph)

    let secondPlan = try CommentExchange.plan(
      entries: parsed.entries, issues: [], into: imported, pageIDs: fresh.pageIDs)
    #expect(secondPlan.added == 0)
    #expect(secondPlan.updated == 0)
    #expect(secondPlan.unchanged == 3)
    #expect(secondPlan.commands.isEmpty)
    #expect(secondPlan.skipped.isEmpty)
  }

  @Test func reimportedStateAndTextUpdateTheExistingThread() throws {
    let (graph, pageIDs) = try reviewedDocument()
    let exported = try CommentExchange.export(
      comments: CommentList.comments(in: graph, pageIDs: pageIDs))
    let parsed = try CommentExchange.parse(exported.data)
    let fresh = try PDFParser.parse(PDFFixtures.threePages())
    let firstPlan = try CommentExchange.plan(
      entries: parsed.entries, issues: [], into: fresh.graph, pageIDs: fresh.pageIDs)
    let imported = try PDFEditingEngine.commit(
      PDFTransaction(firstPlan.commands), to: fresh.graph)
    let changed = parsed.entries.map { entry -> CommentExchangeEntry in
      guard entry.contents == "Smoke review" else { return entry }
      return CommentExchangeEntry(
        identity: entry.identity, pageIndex: entry.pageIndex, subtype: entry.subtype,
        rect: entry.rect, quadPoints: entry.quadPoints, contents: "Updated review",
        author: entry.author, modified: "D:20261011120000Z", creationDate: entry.creationDate,
        subject: entry.subject, state: PDFName("Rejected"), stateModel: entry.stateModel,
        color: entry.color, opacity: entry.opacity, flags: entry.flags,
        iconName: entry.iconName, inReplyTo: entry.inReplyTo,
        borderWidth: entry.borderWidth, inkStrokes: entry.inkStrokes)
    }
    let updatePlan = try CommentExchange.plan(
      entries: changed, issues: [], into: imported, pageIDs: fresh.pageIDs)
    #expect(updatePlan.added == 0)
    #expect(updatePlan.updated == 1)
    #expect(updatePlan.unchanged == 2)
    #expect(updatePlan.commands.count == 1)
    let updated = try PDFEditingEngine.commit(
      PDFTransaction(updatePlan.commands), to: imported)
    #expect(
      CommentList.comments(in: updated, pageIDs: fresh.pageIDs).first {
        $0.contents == "Updated review"
      }?.reviewState == PDFName("Rejected"))
  }

  @Test func missingContentsDoNotLeakIntoTheNextComment() throws {
    let data = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots>
      <text page="0" rect="10,10,30,30" name="first"><contents>First</contents></text>
      <text page="0" rect="40,40,60,60" name="second"/>
      </annots></xfdf>
      """.utf8)
    let result = try CommentExchange.parse(data)
    #expect(result.entries.count == 2)
    #expect(result.entries[0].contents == "First")
    #expect(result.entries[1].contents == nil)
  }

  @Test func legacyCommentWithoutNMUsesAStableFallbackIdentity() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddNoteCommand(pageID: parsed.pageIDs[0], at: [10, 10], contents: "Legacy")
      ]), to: parsed.graph)
    let comment = try #require(
      CommentList.comments(in: graph, pageIDs: parsed.pageIDs).first)
    let objectID = try #require(comment.annotation.objectID)
    guard case .dictionary(var dictionary)? = graph.objects[objectID] else {
      Issue.record("Missing note dictionary")
      return
    }
    dictionary[PDFName("NM")] = nil
    graph.objects[objectID] = .dictionary(dictionary)
    let legacy = try #require(CommentList.comments(in: graph, pageIDs: parsed.pageIDs).first)
    let exported = try CommentExchange.export(comments: [legacy])
    let portable = try CommentExchange.parse(exported.data)
    #expect(portable.entries.first?.identity == "spdf-\(objectID.number)")
    let plan = try CommentExchange.plan(
      entries: portable.entries, into: graph, pageIDs: parsed.pageIDs)
    #expect(plan.added == 0)
    #expect(plan.updated == 1)
    #expect(plan.commands.count == 1)
  }

  @Test func unsupportedAndMalformedCommentsAreReported() throws {
    let entry = CommentExchangeEntry(
      identity: "stamp-1", pageIndex: 0, subtype: PDFName("Stamp"),
      rect: [0, 0, 20, 20], contents: "Stamped")
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let plan = try CommentExchange.plan(
      entries: [entry], into: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(plan.added == 0)
    #expect(plan.commands.isEmpty)
    #expect(plan.skipped.count == 1)

    let malformedMarkup = CommentExchangeEntry(
      identity: "bad-markup", pageIndex: 0, subtype: PDFName("Highlight"),
      rect: [0, 0, 20, 20], quadPoints: [1, 2, 3], contents: "Bad")
    let markupPlan = try CommentExchange.plan(
      entries: [malformedMarkup], into: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(markupPlan.added == 0)
    #expect(markupPlan.commands.isEmpty)
    #expect(markupPlan.skipped.count == 1)

    let data = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots>
      <highlight page="0" rect="bad" name="broken"><contents>Broken</contents></highlight>
      </annots></xfdf>
      """.utf8)
    let result = try CommentExchange.parse(data)
    #expect(result.entries.isEmpty)
    #expect(result.issues.count == 1)
  }
}
