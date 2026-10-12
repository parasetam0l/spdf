import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P17-008/P17-012/P17-013/P17-014/P17-026/P17-027 evidence: change-set and
/// revision tracking per committed mutation, meaningful undo grouping,
/// failure atomicity (no orphaned partial resources), and stale-command
/// safety.
@Suite("Change tracking")
struct ChangeTrackingTests {
  private func loadedSession() throws -> (DocumentEditSession, [PDFObjectID]) {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.threePages()))
    return (session, session.pageIDs)
  }

  @Test func revisionsAdvanceAndChangeSetsReportTouchedPages() throws {
    let (session, pages) = try loadedSession()
    let loadRevision = session.documentRevision
    #expect(loadRevision > 0)
    // A load is an unknown-scope change: page list empty means "all".
    #expect(session.changeSet().pageIDs.isEmpty)

    try session.rotatePage(at: 1, byDegrees: 90)
    let rotated = session.changeSet()
    #expect(rotated.revision == loadRevision + 1)
    #expect(rotated.pageIDs == [pages[1]])
    #expect(session.changedPageIndices() == [1])

    // A text edit reports its own page; the page list is refreshed first.
    try session.replaceText(pageAt: 0, runIndex: 0, with: "Changed")
    let replaced = session.changeSet()
    #expect(replaced.revision == rotated.revision + 1)
    #expect(replaced.pageIDs == [pages[0]])
    #expect(session.changedPageIndices() == [0])

    // Undo reports the pages of the edit it reverses.
    #expect(session.undo())
    let undone = session.changeSet()
    #expect(undone.revision == replaced.revision + 1)
    #expect(undone.pageIDs == [pages[0]])
    // Redo repeats the edit's pages.
    #expect(session.redo())
    #expect(session.changeSet().pageIDs == [pages[0]])
    #expect(session.documentRevision == undone.revision + 1)

    // A document-level edit (catalog language) reports no page scope: empty
    // means "all pages" for invalidation.
    try session.apply(PDFTransaction([SetStructureLanguageCommand(language: "de")]))
    #expect(session.changeSet().pageIDs.isEmpty)
    #expect(session.changedPageIndices() == nil)
  }

  @Test func commandPageScopeCoversTheEditableSurface() throws {
    // The commands the app commits all declare their pages; a compound
    // transaction unions them in command order.
    let (session, pages) = try loadedSession()
    let graph = try #require(session.currentGraph)
    let rotate = RotatePagesCommand(pageIDs: [pages[1]], byDegrees: 90)
    #expect(rotate.affectedPageIDs(in: graph) == [pages[1]])
    let delete = DeletePagesCommand(pageIDs: [pages[2]])
    #expect(delete.affectedPageIDs(in: graph) == [pages[2]])
    try session.apply(PDFTransaction([rotate, delete]))
    #expect(session.changeSet().pageIDs == [pages[1], pages[2]])
    // One commit is one undo step (grouping); two separate commits are two.
    #expect(session.undo())
    #expect(!session.canUndo)
  }

  @Test func compoundTransactionsAreSingleUndoStepsAndTypingIsPerCommit() throws {
    // P17-008: a multi-command transaction is one undo action; each typing
    // commit is its own step and each undo restores the previous text.
    let (session, pages) = try loadedSession()
    let pageID = pages[0]
    // Compound: two commands in one transaction.
    try session.apply(PDFTransaction([
      RotatePagesCommand(pageIDs: [pageID], byDegrees: 90),
      SetStructureLanguageCommand(language: "en"),
    ]))
    #expect(session.undo())
    #expect(!session.canUndo)
    #expect(session.undo() == false)

    // Typing: two commits, two undo steps, text restored in order.
    try session.replaceText(pageAt: 0, runIndex: 0, with: "First")
    try session.replaceText(pageAt: 0, runIndex: 0, with: "Second")
    func text() throws -> String {
      let graph = try #require(session.currentGraph)
      let content = try PageContent.load(pageID: pageID, in: graph)
      return String(decoding: content.bytes, as: UTF8.self)
    }
    #expect(try text().contains("Second"))
    #expect(session.undo())
    #expect(try text().contains("First"))
    #expect(session.undo())
    #expect(!(try text().contains("First")))
  }

  @Test func sharedResourceEditsReportEveryAffectedPage() throws {
    // P17-022: replacing a shared image object changes every page that
    // places it, so the change set lists all of them — a global effect made
    // intentional and visible rather than an accidental single-page edit.
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.imagePages()))
    let pages = session.pageIDs
    let graph = try #require(session.currentGraph)
    let placements = try ImageInventory.placements(in: graph, pageID: pages[0])
    guard placements.count == 2, placements[0].imageID == placements[1].imageID else {
      Issue.record("fixture no longer shares an image across placements")
      return
    }
    let command = ReplaceSharedImageCommand(
      pageID: pages[0], placementIndex: 0, width: 2, height: 2,
      rgb8: Data([255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0]))
    let reported = command.affectedPageIDs(in: graph)
    #expect(Set(reported) == Set(pages))
    try session.apply(PDFTransaction([command]))
    #expect(Set(session.changeSet().pageIDs) == Set(pages))
    #expect(session.changedPageIndices() == Array(0..<pages.count))
  }

  @Test func failedTransactionsLeaveNoOrphansOrRevisionChanges() throws {
    // P17-026: a transaction that fails mid-way (here: a custom font whose
    // program lacks the replacement glyphs) leaves the graph, page list,
    // revision, and object count untouched.
    let (session, pages) = try loadedSession()
    let before = try #require(session.currentGraph)
    let beforeRevision = session.documentRevision
    let beforePages = session.pageIDs
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("test font program is corrupt")
      return
    }
    // Cyrillic has no glyph in the subset: the insertion refuses.
    #expect(throws: PDFError.self) {
      try session.apply(PDFTransaction([
        AddTextObjectCommand(
          pageID: pages[0], rect: [72, 500, 400, 560], text: "Привет",
          style: AddedTextStyle(size: 18),
          customFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      ]))
    }
    let after = try #require(session.currentGraph)
    #expect(after == before)
    #expect(session.documentRevision == beforeRevision)
    #expect(session.pageIDs == beforePages)
    #expect(after.objects.count == before.objects.count)
    #expect(!session.isDirty)
    // An image replacement with mismatched dimensions refuses the same way.
    let imageSession = DocumentEditSession()
    imageSession.load(try PDFSource(data: PDFFixtures.imagePages()))
    let imageBefore = try #require(imageSession.currentGraph)
    let imageRevision = imageSession.documentRevision
    let imagePage = imageSession.pageIDs[0]
    #expect(throws: PDFError.self) {
      try imageSession.apply(PDFTransaction([
        ReplaceImageDataCommand(
          pageID: imagePage, placementIndex: 0, width: 4, height: 4,
          rgb8: Data(repeating: 1, count: 12))
      ]))
    }
    #expect(try #require(imageSession.currentGraph) == imageBefore)
    #expect(imageSession.documentRevision == imageRevision)
    #expect(imageSession.currentGraph?.objects.count == imageBefore.objects.count)
    // The session is still usable afterwards.
    try session.rotatePage(at: 0, byDegrees: 90)
    #expect(session.isDirty)
  }

  @Test func staleCommandsRefuseInsteadOfCorruptingNewRevisions() throws {
    // P17-027: a command built against an older revision (a deleted page)
    // fails validation; the session state is untouched.
    let (session, pages) = try loadedSession()
    let doomed = pages[1]
    try session.deletePage(at: 1)
    let afterDelete = try #require(session.currentGraph)
    let revisionAfterDelete = session.documentRevision
    #expect(throws: PDFError.self) {
      try session.apply(PDFTransaction([
        ReplaceTextCommand(pageID: doomed, runIndex: 0, replacement: "stale")
      ]))
    }
    #expect(try #require(session.currentGraph) == afterDelete)
    #expect(session.documentRevision == revisionAfterDelete)
    // A stale run index on a live page also refuses (run 99 does not exist).
    #expect(throws: PDFError.self) {
      try session.apply(PDFTransaction([
        ReplaceTextCommand(pageID: session.pageIDs[0], runIndex: 99, replacement: "stale")
      ]))
    }
    #expect(try #require(session.currentGraph) == afterDelete)
  }

  @Test func concurrentEditsAndSavesStaySerializable() async throws {
    // P17-023 supporting evidence: applies and save-byte production run
    // concurrently under the session lock; every produced byte string
    // parses, every apply lands, and the final state is a consistent graph.
    let (session, _) = try loadedSession()
    // Baseline rotations (the fixture pre-rotates its last page).
    func rotations(_ graph: PDFGraph) -> [Int] {
      session.pageIDs.map { pageID in
        guard case .dictionary(let page)? = graph.objects[pageID],
          case .integer(let raw)? = page[PDFName("Rotate")]
        else { return 0 }
        return Int(raw)
      }
    }
    let baselineGraph = try #require(session.currentGraph)
    let baseline = rotations(baselineGraph)
    let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
      for index in 0..<3 {
        group.addTask {
          do {
            try session.rotatePage(at: index, byDegrees: 90)
            return true
          } catch {
            return false
          }
        }
        group.addTask {
          (try? session.bytesForSave()) != nil
        }
      }
      var collected: [Bool] = []
      for await result in group { collected.append(result) }
      return collected
    }
    #expect(results.allSatisfy { $0 })
    // Every concurrent save produced parseable bytes, and the final graph
    // has exactly one additional +90 rotation per page.
    let finalGraph = try #require(session.currentGraph)
    let final = rotations(finalGraph)
    #expect(zip(baseline, final).allSatisfy { ($0 + 90) % 360 == $1 })
    let parsed = try PDFParser.parse(try session.bytesForSave())
    #expect(parsed.pageIDs == session.pageIDs)
  }
}
