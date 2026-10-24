import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// REV-03 acceptance: a reviewer-sized document with 100 comments across 20
/// pages, filtered by text, author, date and status, then bulk-updated and
/// saved/reopened without losing comments or locations.
@Suite("Comment triage acceptance")
struct CommentTriageAcceptanceTests {
  @Test func longDocumentFiltersAndBulkUpdatesSurviveReopen() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    for index in 1..<20 {
      graph = try PDFEditingEngine.commit(
        PDFTransaction([
          InsertBlankPageCommand(atIndex: index, width: 612, height: 792)
        ]), to: graph)
    }
    let pageIDs = try PageTreeView(graph: graph).pages
    #expect(pageIDs.count == 20)

    let authors = ["Ada", "Grace", "Linus", "Margaret"]
    var commands: [any PDFEditCommand] = []
    for index in 0..<100 {
      let page = pageIDs[index % pageIDs.count]
      let x = 24.0 + Double(index % 3) * 90
      let y = 120.0 + Double((index / 3) % 5) * 90
      let day = index % 28 + 1
      commands.append(
        AddHighlightCommand(
          pageID: page,
          quads: [x, y + 18, x + 64, y + 18, x, y, x + 64, y],
          color: [1, 0.84, 0], opacity: 0.5,
          contents: "Review item \(index)",
          author: authors[index % authors.count],
          modified: String(format: "D:202610%02d120000Z", day),
          subject: "Long review"))
    }
    let annotated = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    let comments = CommentList.comments(in: annotated, pageIDs: pageIDs)
    #expect(comments.count == 100)
    #expect(comments.allSatisfy { $0.bounds?.count == 4 })

    // A quarter of the long document is already accepted.
    let acceptedTargets = comments.enumerated().filter { $0.offset % 4 == 0 }
    let accepted = try PDFEditingEngine.commit(
      PDFTransaction(
        acceptedTargets.map {
          SetAnnotationStateCommand(
            pageID: $0.element.pageID, annotationIndex: $0.element.annotation.index,
            state: PDFName("Accepted"))
        }), to: annotated)
    #expect(
      CommentList.filter(
        CommentList.comments(in: accepted, pageIDs: pageIDs),
        by: CommentFilter(state: PDFName("Accepted"))
      ).count == 25)

    let reopened = try PDFParser.parse(try PDFWriter.write(accepted))
    let reopenedComments = CommentList.comments(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(reopenedComments.count == 100)
    #expect(
      CommentList.filter(reopenedComments, by: CommentFilter(author: "Ada")).count == 25)
    #expect(
      CommentList.filter(reopenedComments, by: CommentFilter(text: "Review item 42")).count == 1)
    #expect(
      CommentList.filter(
        reopenedComments, by: CommentFilter(subtype: PDFName("Highlight"))
      ).count == 100)
    let cutoff = try #require(CommentDate.parse("D:20261015120000Z"))
    let recent = CommentList.filter(
      reopenedComments, by: CommentFilter(modifiedOnOrAfter: cutoff))
    #expect(recent.count == 44)
    #expect(
      CommentList.filter(
        reopenedComments,
        by: CommentFilter(author: "Ada", modifiedOnOrAfter: cutoff)
      ).count == 9)

    // Select the recent Grace comments that still need review, update them in
    // one transaction and leave every other comment untouched.
    let allGraceRecent = CommentList.filter(
      reopenedComments,
      by: CommentFilter(author: "Grace", modifiedOnOrAfter: cutoff))
    let targets = CommentList.filter(
      allGraceRecent, by: CommentFilter(state: PDFName("None")))
    #expect(targets.count > 0)
    #expect(targets.count < allGraceRecent.count)
    let alreadyAccepted = allGraceRecent.count - targets.count
    let acceptedBefore = CommentList.filter(
      reopenedComments, by: CommentFilter(state: PDFName("Accepted"))).count
    #expect(acceptedBefore == 25)
    #expect(alreadyAccepted > 0)
    let updated = try PDFEditingEngine.commit(
      PDFTransaction(
        targets.map {
          SetAnnotationStateCommand(
            pageID: $0.pageID, annotationIndex: $0.annotation.index,
            state: PDFName("Completed"))
        }), to: reopened.graph)
    let afterUpdate = CommentList.comments(in: updated, pageIDs: pageIDs)
    #expect(afterUpdate.count == 100)
    #expect(
      CommentList.filter(afterUpdate, by: CommentFilter(state: PDFName("Completed"))).count
        == targets.count)
    #expect(
      CommentList.filter(afterUpdate, by: CommentFilter(state: PDFName("Accepted"))).count
        == acceptedBefore)
    let targetIDs = Set(targets.compactMap { $0.annotation.objectID })
    #expect(
      afterUpdate.filter { targetIDs.contains($0.annotation.objectID ?? PDFObjectID(0)) }
        .allSatisfy { $0.reviewState == PDFName("Completed") })

    // The selection's geometry still points at the same page after reopening.
    let final = try PDFParser.parse(try PDFWriter.write(updated))
    let finalComments = CommentList.comments(in: final.graph, pageIDs: final.pageIDs)
    #expect(finalComments.count == 100)
    let target = try #require(
      finalComments.first {
        targetIDs.contains($0.annotation.objectID ?? PDFObjectID(0))
      })
    #expect(target.pageIndex >= 0 && target.pageIndex < final.pageIDs.count)
    #expect(target.bounds?.count == 4)
    #expect(target.reviewState == PDFName("Completed"))
  }
}
