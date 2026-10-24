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

  @Test func freeTextAndStampRoundTripWithAppearances() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddFreeTextCommand(
          pageID: parsed.pageIDs[0], rect: [30, 60, 240, 110], text: "Boxed text",
          fontSize: 14, textColor: [0.2, 0.1, 0.6], modified: "D:20261012120000Z"),
        AddStampCommand(
          pageID: parsed.pageIDs[1], rect: [40, 50, 200, 110], stampName: .draft,
          contents: "Review stamp", modified: "D:20261012120500Z"),
      ]), to: parsed.graph)
    let comments = CommentList.comments(in: graph, pageIDs: parsed.pageIDs)
    #expect(comments.count == 2)
    let exported = try CommentExchange.export(comments: comments)
    let portable = try CommentExchange.parse(exported.data)
    #expect(portable.entries.count == 2)
    let freeText = try #require(
      portable.entries.first { $0.subtype == PDFName("FreeText") })
    #expect(freeText.contents == "Boxed text")
    #expect(freeText.defaultAppearance?.contains("Tf") == true)
    let stamp = try #require(portable.entries.first { $0.subtype == PDFName("Stamp") })
    #expect(stamp.iconName == PDFName("Draft"))
    #expect(stamp.contents == "Review stamp")

    let fresh = try PDFParser.parse(PDFFixtures.threePages())
    let plan = try CommentExchange.plan(
      entries: portable.entries, issues: portable.issues, into: fresh.graph,
      pageIDs: fresh.pageIDs)
    #expect(plan.added == 2)
    #expect(plan.skipped.isEmpty)
    let imported = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: fresh.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(imported))
    let importedComments = CommentList.comments(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(importedComments.count == 2)
    let importedFreeText = try #require(
      importedComments.first { $0.subtype == PDFName("FreeText") })
    #expect(importedFreeText.contents == "Boxed text")
    #expect(
      importedFreeText.annotation.dictionary[PDFName("DA")] != nil)
    #expect(importedFreeText.annotation.dictionary[PDFName("AP")] != nil)
    let importedStamp = try #require(
      importedComments.first { $0.subtype == PDFName("Stamp") })
    #expect(importedStamp.annotation.iconName == PDFName("Draft"))
    #expect(importedStamp.annotation.dictionary[PDFName("AP")] != nil)

    let repeatPlan = try CommentExchange.plan(
      entries: portable.entries, issues: portable.issues, into: imported,
      pageIDs: fresh.pageIDs)
    #expect(repeatPlan.added == 0)
    #expect(repeatPlan.unchanged == 2)
    #expect(repeatPlan.commands.isEmpty)

    let revised = portable.entries.map { entry -> CommentExchangeEntry in
      guard entry.subtype == PDFName("FreeText") else { return entry }
      return CommentExchangeEntry(
        identity: entry.identity, pageIndex: entry.pageIndex, subtype: entry.subtype,
        rect: entry.rect, quadPoints: entry.quadPoints, contents: "Revised box",
        author: entry.author, modified: entry.modified, creationDate: entry.creationDate,
        subject: entry.subject, state: entry.state, stateModel: entry.stateModel,
        color: entry.color, opacity: entry.opacity, flags: entry.flags,
        iconName: entry.iconName, inReplyTo: entry.inReplyTo,
        borderWidth: entry.borderWidth, inkStrokes: entry.inkStrokes,
        defaultAppearance: entry.defaultAppearance)
    }
    let updatePlan = try CommentExchange.plan(
      entries: revised, into: imported, pageIDs: fresh.pageIDs)
    #expect(updatePlan.updated == 1)
    #expect(updatePlan.unchanged == 1)
    let updated = try PDFEditingEngine.commit(
      PDFTransaction(updatePlan.commands), to: imported)
    let revisedFreeText = try #require(
      CommentList.comments(in: updated, pageIDs: fresh.pageIDs).first {
        $0.subtype == PDFName("FreeText")
      })
    #expect(revisedFreeText.contents == "Revised box")
    guard case .dictionary(let ap)? = revisedFreeText.annotation.dictionary[PDFName("AP")],
      case .reference(let apID)? = ap[PDFName("N")],
      case .stream(let stream)? = updated.objects[apID]
    else {
      Issue.record("Free-text appearance was not regenerated")
      return
    }
    #expect(String(decoding: stream.bytes, as: UTF8.self).contains("Revised box"))
  }

  @Test func lineAnnotationRoundTripsEndpointsAndArrow() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLineCommand(
          pageID: parsed.pageIDs[0], from: [20, 20], to: [120, 90],
          startEnding: .none, endEnding: .closedArrow, color: [0, 0, 0.8],
          borderWidth: 2, contents: "Review line",
          modified: "D:20261012121000Z")
      ]), to: parsed.graph)
    let comments = CommentList.comments(in: graph, pageIDs: parsed.pageIDs)
    let exported = try CommentExchange.export(comments: comments)
    let portable = try CommentExchange.parse(exported.data)
    let line = try #require(portable.entries.first)
    #expect(line.subtype == PDFName("Line"))
    #expect(line.lineStart == [20, 20])
    #expect(line.lineEnd == [120, 90])
    #expect(line.startEnding == PDFName("None"))
    #expect(line.endEnding == PDFName("ClosedArrow"))

    let fresh = try PDFParser.parse(PDFFixtures.threePages())
    let plan = try CommentExchange.plan(
      entries: portable.entries, issues: portable.issues, into: fresh.graph,
      pageIDs: fresh.pageIDs)
    #expect(plan.added == 1)
    #expect(plan.skipped.isEmpty)
    let imported = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: fresh.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(imported))
    let importedComments = CommentList.comments(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    let importedLine = try #require(importedComments.first)
    #expect(importedLine.subtype == PDFName("Line"))
    #expect(importedLine.contents == "Review line")
    #expect(importedLine.annotation.dictionary[PDFName("L")] != nil)
    #expect(importedLine.annotation.dictionary[PDFName("AP")] != nil)
    let repeatPlan = try CommentExchange.plan(
      entries: portable.entries, into: imported, pageIDs: fresh.pageIDs)
    #expect(repeatPlan.added == 0)
    #expect(repeatPlan.unchanged == 1)
  }

  @Test func importingAnExistingCommentOnAnotherPageMovesIt() throws {
    let (graph, pageIDs) = try reviewedDocument()
    let exported = try CommentExchange.export(
      comments: CommentList.comments(in: graph, pageIDs: pageIDs))
    let parsed = try CommentExchange.parse(exported.data)
    let root = try #require(
      parsed.entries.first { $0.contents == "Smoke review" && $0.inReplyTo == nil })
    let moved = CommentExchangeEntry(
      identity: root.identity, pageIndex: 2, subtype: PDFName("Highlight"),
      rect: [100, 200, 180, 230],
      quadPoints: [100, 230, 180, 230, 100, 200, 180, 200],
      contents: "Moved review", author: root.author, modified: root.modified,
      subject: root.subject, state: PDFName("Accepted"), stateModel: root.stateModel,
      color: [0, 0, 1], opacity: 0.4, flags: 4)
    let plan = try CommentExchange.plan(
      entries: [moved], into: graph, pageIDs: pageIDs)
    #expect(plan.moved == 1)
    #expect(plan.added == 0)
    #expect(plan.updated == 0)
    #expect(plan.skipped.isEmpty)
    #expect(plan.commands.count == 2)

    let updated = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: graph)
    let comments = CommentList.comments(in: updated, pageIDs: pageIDs)
    #expect(comments.count == 3)
    let movedRoot = try #require(
      comments.first { $0.contents == "Moved review" })
    #expect(movedRoot.pageIndex == 2)
    #expect(movedRoot.annotation.rect == [100, 200, 180, 230])
    #expect(movedRoot.annotation.color == [0, 0, 1])
    #expect(movedRoot.reviewState == PDFName("Accepted"))
    let threads = CommentList.threads(comments, by: CommentFilter())
    #expect(
      threads.contains {
        $0.root.contents == "Moved review" && $0.replies.map(\.contents) == ["Smoke reply"]
      })
    guard case .dictionary(let ap)? = movedRoot.annotation.dictionary[PDFName("AP")],
      case .reference(let apID)? = ap[PDFName("N")],
      case .stream(let stream)? = updated.objects[apID]
    else {
      Issue.record("Moved comment appearance is missing")
      return
    }
    #expect(String(decoding: stream.bytes, as: UTF8.self).contains("0 0 1 rg"))

    let reopened = try PDFParser.parse(try PDFWriter.write(updated))
    let reopenedComments = CommentList.comments(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(reopenedComments.first { $0.contents == "Moved review" }?.pageIndex == 2)
    let repeatPlan = try CommentExchange.plan(
      entries: [moved], into: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(repeatPlan.moved == 0)
    #expect(repeatPlan.added == 0)
    #expect(repeatPlan.unchanged == 1)
  }

  @Test func polygonAndPolyLineRoundTripVertices() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let entries = [
      CommentExchangeEntry(
        identity: "polygon-1", pageIndex: 0, subtype: PDFName("Polygon"),
        rect: [20, 20, 120, 120], contents: "Polygon", author: "Ada",
        modified: "D:20261013120000Z", color: [0.2, 0.5, 0.9], opacity: 0.4,
        flags: 4, borderWidth: 2, vertices: [30, 30, 110, 40, 90, 110, 30, 80]),
      CommentExchangeEntry(
        identity: "polyline-1", pageIndex: 0, subtype: PDFName("PolyLine"),
        rect: [140, 20, 240, 120], contents: "Polyline", author: "Ada",
        modified: "D:20261013120500Z", color: [0.9, 0.2, 0.1], opacity: 1,
        flags: 4, borderWidth: 2, vertices: [150, 30, 190, 110, 230, 40]),
    ]
    let imported = try PDFEditingEngine.commit(
      PDFTransaction([
        ImportCommentsCommand(entries: entries, pageIDs: parsed.pageIDs)
      ]), to: parsed.graph)
    let comments = CommentList.comments(in: imported, pageIDs: parsed.pageIDs)
    #expect(comments.map { $0.subtype } == [PDFName("Polygon"), PDFName("PolyLine")])
    #expect(comments.allSatisfy { $0.annotation.dictionary[PDFName("AP")] != nil })
    #expect(comments.allSatisfy { $0.annotation.dictionary[PDFName("Vertices")] != nil })

    let exported = try CommentExchange.export(comments: comments)
    let portable = try CommentExchange.parse(exported.data)
    #expect(portable.entries.count == 2)
    let polygon = try #require(
      portable.entries.first { $0.subtype == PDFName("Polygon") })
    #expect(polygon.vertices?.count == 8)
    #expect(polygon.contents == "Polygon")
    #expect(polygon.color != nil)
    let polyline = try #require(
      portable.entries.first { $0.subtype == PDFName("PolyLine") })
    #expect(polyline.vertices == [150, 30, 190, 110, 230, 40])

    let fresh = try PDFParser.parse(PDFFixtures.onePage())
    let plan = try CommentExchange.plan(
      entries: portable.entries, issues: portable.issues, into: fresh.graph,
      pageIDs: fresh.pageIDs)
    #expect(plan.added == 2)
    #expect(plan.skipped.isEmpty)
    let merged = try PDFEditingEngine.commit(
      PDFTransaction(plan.commands), to: fresh.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(merged))
    #expect(
      CommentList.comments(in: reopened.graph, pageIDs: reopened.pageIDs).count == 2)
    let repeatPlan = try CommentExchange.plan(
      entries: portable.entries, into: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(repeatPlan.added == 0)
    #expect(repeatPlan.unchanged == 2)
  }

  @Test func unsupportedAndMalformedCommentsAreReported() throws {
    let entry = CommentExchangeEntry(
      identity: "attachment-1", pageIndex: 0, subtype: PDFName("FileAttachment"),
      rect: [0, 0, 20, 20], contents: "Attachment")
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
