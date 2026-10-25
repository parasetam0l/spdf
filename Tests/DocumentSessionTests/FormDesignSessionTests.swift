import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-01/FRM-02 session evidence: one committed gesture is one undo step, and
/// accepted detected proposals are created as one undoable transaction.
@Suite("Form design sessions")
struct FormDesignSessionTests {
  @Test func multiWidgetMoveIsOneUndoStep() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    let pageID = try #require(session.pageIDs.first)
    try session.apply(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 600, 272, 624], name: "First"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 500, 272, 524], name: "Second"),
      ]))
    let baseline = try session.bytesForSave()
    let widgets = try FormDesignInventory.widgets(
      in: try #require(session.currentGraph), pageIDs: session.pageIDs)
    var selection = FormWidgetSelection()
    for widget in widgets { selection.select(widget) }
    try session.apply(PDFTransaction(selection.moveCommands(by: [12, -8])))
    let movedGraph = try #require(session.currentGraph)
    let movedRect = try #require(
      try FormDesignInventory.widgets(in: movedGraph, pageIDs: session.pageIDs).first?.rect)
    #expect(movedRect == [84, 592, 284, 616])
    #expect(session.undo())
    let restoredGraph = try #require(session.currentGraph)
    let restored = try FormDesignInventory.widgets(in: restoredGraph, pageIDs: session.pageIDs)
    #expect(restored.map(\.rect) == [[72, 600, 272, 624], [72, 500, 272, 524]])
    #expect(try session.bytesForSave() == baseline)
    #expect(session.redo())
    let redoneGraph = try #require(session.currentGraph)
    let redone = try FormDesignInventory.widgets(in: redoneGraph, pageIDs: session.pageIDs)
    #expect(redone.map(\.rect) == [[84, 592, 284, 616], [84, 492, 284, 516]])
  }

  @Test func acceptedDetectedFieldsCommitAsOneUndoStep() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    let pageID = try #require(session.pageIDs.first)
    let graph = try #require(session.currentGraph)
    let lines = [
      FormDetectionTextLine(text: "First:", rect: [72, 700, 120, 712], source: .documentText),
      FormDetectionTextLine(text: "Second:", rect: [72, 650, 130, 662], source: .documentText),
    ]
    let outcome = FormFieldDetection.pureDetection(
      pageIndex: 0, pageID: pageID, pageBounds: [0, 0, 612, 792], textLines: lines, shapes: [],
      existingFields: [])
    var review = FormFieldDetectionReview(report: FormDetectionReport(
      pages: [outcome.report], candidates: outcome.candidates))
    review.acceptAllEligible()
    let plan = try review.makePlan(in: graph)
    #expect(plan.transaction.commands.count == 2)
    try session.apply(plan.transaction)
    #expect(try FormInventory.fields(in: try #require(session.currentGraph), pageIDs: [pageID]).count == 2)
    #expect(session.undo())
    #expect(try FormInventory.fields(in: try #require(session.currentGraph), pageIDs: [pageID]).isEmpty)
    #expect(session.redo())
    #expect(try FormInventory.fields(in: try #require(session.currentGraph), pageIDs: [pageID]).count == 2)
  }

  @Test func tabOrderChangeIsOneUndoStep() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    let pageID = try #require(session.pageIDs.first)
    try session.apply(
      PDFTransaction([
        AddTextFieldCommand(pageID: pageID, rect: [72, 500, 272, 524], name: "Low"),
        AddTextFieldCommand(pageID: pageID, rect: [72, 700, 272, 724], name: "High"),
      ]))
    let graph = try #require(session.currentGraph)
    let fields = try FormInventory.fields(in: graph, pageIDs: [pageID])
    var review = FormTabOrder.transaction(order: ["High", "Low"], fields: fields)
    #expect(review != nil)
    try session.apply(try #require(review))
    let reordered = try FormInventory.fields(
      in: try #require(session.currentGraph), pageIDs: [pageID])
    #expect(reordered.map(\.name) == ["High", "Low"])
    #expect(session.undo())
    let restored = try FormInventory.fields(
      in: try #require(session.currentGraph), pageIDs: [pageID])
    #expect(restored.map(\.name) == ["Low", "High"])
    _ = review
  }
}
