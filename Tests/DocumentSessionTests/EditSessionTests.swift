import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P10-005/P17-006/P17-015/P17-018/P17-019/P17-025/P17-028 evidence: dirty
/// state, snapshot undo/redo, bounded history, and verified save bytes.
@Suite("Edit sessions")
struct EditSessionTests {
  @Test func repeatedSaveConsumersNeverReuseAnEarlierDocumentState() throws {
    let session = DocumentEditSession()
    let original = try PDFFixtures.threePages()
    session.load(try PDFSource(data: original))
    try session.rotatePage(at: 0, byDegrees: 90)
    let first = try session.bytesForSave()
    // The viewer, recovery and Save may each request the same revision.
    #expect(try session.bytesForSave() == first)
    #expect(try session.bytesForSave() == first)
    session.noteSaved()
    try session.rotatePage(at: 1, byDegrees: 180)
    let second = try session.bytesForSave()
    #expect(second != first)
    #expect(second.starts(with: first))
    #expect(try session.bytesForSave() == second)
    #expect(session.undo())
    #expect(try session.bytesForSave() == first)
    #expect(session.redo())
    #expect(try session.bytesForSave() == second)
    // Loading another source invalidates every previous consumer's result.
    let replacement = try PDFFixtures.onePage()
    session.load(try PDFSource(data: replacement))
    #expect(try session.bytesForSave() == replacement)
    #expect(session.pageIDs.count == 1)
  }

  @Test func editedSessionRoundTripUndoRedoAndExactOriginalBytes() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    #expect(session.canEdit)
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == original)

    try session.rotatePage(at: 0, byDegrees: 90)
    #expect(session.isDirty)
    #expect(session.canUndo)
    #expect(!session.canRedo)
    let edited = try session.bytesForSave()
    #expect(edited != original)
    let editedParsed = try PDFParser.parse(edited)
    #expect(editedParsed.pageIDs == session.pageIDs)
    guard case .dictionary(let page)? = editedParsed.graph.objects[editedParsed.pageIDs[0]],
      case .integer(let raw)? = page[PDFName("Rotate")]
    else {
      Issue.record("Edited page has no rotation")
      return
    }
    #expect(Int(raw) == 90)

    // Undo returns to the saved revision and restores exact original bytes.
    #expect(session.undo())
    #expect(!session.isDirty)
    #expect(session.canRedo)
    #expect(try session.bytesForSave() == original)

    // Redo reproduces the same edited bytes deterministically.
    #expect(session.redo())
    #expect(session.isDirty)
    #expect(try session.bytesForSave() == edited)
    #expect(!session.canRedo)
  }

  @Test func redactionAndSanitizeUndoRestoresOriginalBytes() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let pageID = session.pageIDs[0]
    try session.apply(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[40, 700, 570, 745]])
      ]))
    try session.apply(PDFTransaction([SanitizeDocumentCommand()]))
    #expect(session.isDirty)
    // Sanitizing a fully reachable graph is a no-op and must not fabricate
    // an undo step, so one undo returns to the original bytes.
    #expect(session.undo())
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == original)
  }

  @Test func failedCommandsLeaveTheSessionUntouched() throws {
    let original = try PDFFixtures.onePage()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    #expect(throws: PDFError.self) { try session.rotatePage(at: 99, byDegrees: 90) }
    #expect(!session.isDirty)
    #expect(!session.canUndo)
    #expect(try session.bytesForSave() == original)

    let badTransaction = PDFTransaction([
      RotatePagesCommand(pageIDs: [session.pageIDs[0]], byDegrees: 45)
    ])
    #expect(throws: PDFError.self) { try session.apply(badTransaction) }
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == original)
  }

  @Test func saveLifecycleTrackingAcrossSaveAndSaveAs() throws {
    let original = try PDFFixtures.onePage()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.rotatePage(at: 0, byDegrees: 180)
    let edited = try session.bytesForSave()
    session.noteSaved()  // Save and Save As both mark the current revision saved
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == edited)

    #expect(session.undo())
    #expect(session.isDirty)
    #expect(try session.bytesForSave() == original)
    #expect(session.redo())
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == edited)
  }

  @Test func undoHistoryIsBounded() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    for index in 0..<60 {
      try session.rotatePage(at: 0, byDegrees: index % 2 == 0 ? 90 : -90)
    }
    var undone = 0
    while session.undo() { undone += 1 }
    #expect(undone == DocumentEditSession.undoLimit)
  }

  @Test func savePlanSelectsOriginalBytesOrIncrementalBase() throws {
    let original = try PDFFixtures.onePage()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    #expect(session.savePlan.mode == .originalBytes)
    try session.rotatePage(at: 0, byDegrees: 90)
    #expect(session.savePlan.mode == .incrementalUpdate)
    // Saving does not move the plan back to original bytes: the saved
    // revision still differs from the source file.
    session.noteSaved()
    #expect(!session.isDirty)
    #expect(session.savePlan.mode == .incrementalUpdate)
    #expect(session.undo())
    #expect(session.savePlan.mode == .originalBytes)
  }

  @Test func incrementalSavesChainAcrossMultipleEdits() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))

    try session.rotatePage(at: 0, byDegrees: 90)
    let firstSave = try session.bytesForSave()
    session.noteSaved()
    // Base bytes are retained exactly (P09-020 for the eligible mode).
    #expect(firstSave.prefix(original.count) == original)

    let order = session.pageIDs
    try session.movePage(at: 2, to: 0)
    let secondSave = try session.bytesForSave()
    session.noteSaved()
    #expect(secondSave.prefix(firstSave.count) == firstSave)

    let parsed = try PDFParser.parse(secondSave)
    #expect(parsed.pageIDs == [order[2], order[0], order[1]])
    guard case .dictionary(let page)? = parsed.graph.objects[order[0]],
      case .integer(let rotation)? = page[PDFName("Rotate")]
    else {
      Issue.record("Rotated page lost across incremental saves")
      return
    }
    #expect(rotation == 90)
    #expect(!session.isDirty)

    // Undoing both edits returns the exact original bytes.
    #expect(session.undo())
    #expect(session.undo())
    #expect(try session.bytesForSave() == original)
  }

  @Test func annotationEditsSaveIncrementallyAndUndoCleanly() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let parsed = try PDFParser.parse(original)
    let pageID = session.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let word = try #require(layout.words.first)
    let quads = AddHighlightCommand.quads(
      forClusterBounds: layout.clusters[word].map(\.bounds))

    try session.apply(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: quads, contents: "First",
          modified: "D:20261010120000Z")
      ]))
    let first = try session.bytesForSave()
    let firstParsed = try PDFParser.parse(first)
    #expect(try AnnotationInventory.annotations(in: firstParsed.graph, pageID: pageID).count == 1)
    #expect(session.comments().count == 1)
    session.noteSaved()

    try session.apply(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: quads, contents: "Second",
          modified: "D:20261010120100Z")
      ]))
    let second = try session.bytesForSave()
    #expect(second.prefix(first.count) == first)
    let secondParsed = try PDFParser.parse(second)
    #expect(try AnnotationInventory.annotations(in: secondParsed.graph, pageID: pageID).count == 2)
    #expect(session.comments().count == 2)

    #expect(session.undo())
    let undone = try PDFParser.parse(try session.bytesForSave())
    #expect(try AnnotationInventory.annotations(in: undone.graph, pageID: pageID).count == 1)
    #expect(session.comments().count == 1)
    #expect(session.undo())
    #expect(try session.bytesForSave() == original)
    #expect(session.comments().isEmpty)
  }

  @Test func deletingTheNewestAnnotationSavesCleanly() throws {
    let original = try PDFFixtures.textWidthsPages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let pageID = session.pageIDs[0]
    try session.apply(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: [42, 730, 62, 730, 42, 710, 62, 710])
      ]))
    #expect(try session.bytesForSave() != original)
    // Removing the newest objects must shrink the declared /Size, or the
    // save verification would reject the produced bytes.
    try session.apply(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]))
    #expect(try session.bytesForSave() == original)
    #expect(session.comments().isEmpty)
  }

  @Test func threadsSurviveSaveReopenDeleteUndo() throws {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.textWidthsPages()))
    let pageID = session.pageIDs[0]
    let quads: [Double] = [42, 730, 62, 730, 42, 710, 62, 710]
    try session.apply(
      PDFTransaction([AddHighlightCommand(pageID: pageID, quads: quads, contents: "root")]))
    try session.apply(
      PDFTransaction([
        AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "reply one", author: "Ada")
      ]))
    try session.apply(
      PDFTransaction([
        SetAnnotationStateCommand(pageID: pageID, annotationIndex: 0, state: PDFName("Accepted"))
      ]))
    let first = try session.bytesForSave()
    session.noteSaved()
    let reopened = try PDFParser.parse(first)
    let threads = CommentList.threads(in: reopened.graph, pageIDs: reopened.pageIDs)
    #expect(threads.count == 1)
    #expect(threads[0].root.reviewState == PDFName("Accepted"))
    #expect(threads[0].replies.map(\.contents) == ["reply one"])
    #expect(threads[0].replies[0].author == "Ada")

    // Deleting the reply and saving removes it from the reopened thread.
    try session.apply(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 1)]))
    let second: Data
    do {
      second = try session.bytesForSave()
    } catch {
      Issue.record("DEBUG second save failed: \(error)")
      return
    }
    session.noteSaved()
    #expect(second.prefix(first.count) == first)
    let reopenedSecond = try PDFParser.parse(second)
    let secondThreads = CommentList.threads(
      in: reopenedSecond.graph, pageIDs: reopenedSecond.pageIDs)
    #expect(secondThreads.count == 1)
    #expect(secondThreads[0].replies.isEmpty)

    // Undo restores the thread in the saved revision; redo removes it again.
    #expect(session.undo())
    let third = try PDFParser.parse(try session.bytesForSave())
    #expect(
      CommentList.threads(in: third.graph, pageIDs: third.pageIDs)[0].replies.count == 1)
    #expect(session.redo())
    let fourth = try PDFParser.parse(try session.bytesForSave())
    #expect(
      CommentList.threads(in: fourth.graph, pageIDs: fourth.pageIDs)[0].replies.isEmpty)
  }

  @Test func formFillsUseTheInteractiveSaveWorkflow() throws {
    let original = try PDFFixtures.formPages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    #expect(!session.isDirty)
    // Filling is a live edit: no separate "apply form" step exists.
    try session.fillFormText(fieldName: "name", text: "Ada")
    #expect(session.isDirty)
    let saved = try session.bytesForSave()
    #expect(saved != original)
    session.noteSaved()
    #expect(!session.isDirty)
    let reopened = try PDFParser.parse(saved)
    #expect(
      try FormInventory.fields(in: reopened.graph, pageIDs: reopened.pageIDs)
        .first { $0.name == "name" }?.stringValue == "Ada")
    #expect(session.undo())
    #expect(session.isDirty)
    #expect(try session.bytesForSave() == original)
  }

  @Test func textReplacementUndoRedoAndSaveChain() throws {
    let original = try PDFFixtures.textEditPages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    try session.replaceText(pageAt: 0, runIndex: 0, with: "Edited by session")
    #expect(session.isDirty)
    let edited = try session.bytesForSave()
    #expect(edited.prefix(original.count) == original)

    let parsed = try PDFParser.parse(edited)
    let pageID = parsed.pageIDs[0]
    let content = try PageContent.load(pageID: pageID, in: parsed.graph)
    let runs = try TextRunIndexer.runs(in: content, graph: parsed.graph)
    #expect(runs.first?.text == "Edited by session")
    #expect(!String(decoding: content.bytes, as: UTF8.self).contains("Replace this text"))

    session.noteSaved()
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == edited)
    #expect(session.undo())
    #expect(try session.bytesForSave() == original)
    #expect(session.redo())
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == edited)
  }

  @Test func structuralEditsRefreshPageListAndUndoExactly() throws {
    let original = try PDFFixtures.threePages()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let order = session.pageIDs

    try session.movePage(at: 2, to: 0)
    #expect(session.pageIDs == [order[2], order[0], order[1]])
    try session.insertBlankPage(at: 1, width: 200, height: 300)
    #expect(session.pageIDs.count == 4)
    #expect(session.pageMediaBox(at: 1) == [0, 0, 200, 300])
    try session.deletePage(at: 0)
    #expect(session.pageIDs.count == 3)
    #expect(session.isDirty)

    #expect(session.undo())
    #expect(session.pageIDs.count == 4)
    #expect(session.undo())
    #expect(session.pageIDs == [order[2], order[0], order[1]])
    #expect(session.undo())
    #expect(!session.isDirty)
    #expect(session.pageIDs == order)
    #expect(try session.bytesForSave() == original)
  }

  @Test func unsupportedDocumentsStayReadOnlyAndCopyable() throws {
    let data = Data("%PDF-2.0\nunknown bytes".utf8)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: data))
    #expect(!session.canEdit)
    #expect(!session.isDirty)
    #expect(try session.bytesForSave() == data)
    #expect(throws: PDFError.self) { try session.rotatePage(at: 0, byDegrees: 90) }
  }
}

// MARK: - Protected sessions (P28-020–P28-024)

@Suite("Protected sessions")
struct ProtectedSessionTests {
  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Encrypted/\(name).pdf")
    return try Data(contentsOf: url)
  }

  @Test func protectedSessionEditsAndSavesWithTheSameProtection() throws {
    let source = try PDFSource(data: fixture("aes-256-r6"))
    let session = DocumentEditSession()
    try session.loadProtected(source, password: "abc")
    #expect(session.isProtected)
    #expect(session.canEdit)
    #expect(session.protectionAllowsEditing)
    #expect(session.isOwnerUnlocked == false)
    #expect(session.pageIDs.count == 1)

    try session.rotatePage(id: session.pageIDs[0], byDegrees: 90)
    #expect(session.isDirty)
    let saved = try session.bytesForSave()
    // The output stays protected: no password fails, the password opens it,
    // and the edit survives.
    #expect(throws: PDFError.self) { _ = try PDFParser.parse(saved) }
    let reparsed = try PDFParser.unlock(saved, password: "abc")
    #expect(reparsed.encryption.info.profile == .aes256)
    guard case .dictionary(let page)? = reparsed.parsed.graph.objects[reparsed.parsed.pageIDs[0]],
      case .integer(let rotation)? = page[PDFName("Rotate")]
    else {
      Issue.record("Rotated page missing")
      return
    }
    #expect(rotation == 90)

    // Locking releases the unlocked state and reverts to read-only with the
    // exact encrypted source bytes.
    session.lockSession()
    #expect(!session.isProtected)
    #expect(!session.canEdit)
    #expect(try session.bytesForSave() == source.data)
  }

  @Test func modificationPermissionGatesEditing() throws {
    // A file written with modification disallowed stays read-only for the
    // user password but editable for the owner.
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let data = try PDFWriter.write(
      graph,
      encryption: PDFEncryptionOptions(
        userPassword: "user", ownerPassword: "owner", permissions: 4 | 16))
    let session = DocumentEditSession()
    try session.loadProtected(try PDFSource(data: data), password: "user")
    #expect(session.isProtected)
    #expect(!session.protectionAllowsEditing)
    #expect(!session.canEdit)
    #expect(throws: PDFError.self) {
      try session.rotatePage(id: session.pageIDs[0], byDegrees: 90)
    }

    let ownerSession = DocumentEditSession()
    try ownerSession.loadProtected(try PDFSource(data: data), password: "owner")
    #expect(ownerSession.isOwnerUnlocked)
    #expect(ownerSession.canEdit)
    try ownerSession.rotatePage(id: ownerSession.pageIDs[0], byDegrees: 90)
    let saved = try ownerSession.bytesForSave()
    let reparsed = try PDFParser.unlock(saved, password: "user")
    #expect(reparsed.encryption.info.allowsCopying)
    #expect(!reparsed.encryption.info.allowsModification)
    guard case .dictionary(let page)? = reparsed.parsed.graph.objects[reparsed.parsed.pageIDs[0]],
      case .integer(let rotation)? = page[PDFName("Rotate")]
    else {
      Issue.record("Owner edit missing")
      return
    }
    #expect(rotation == 90)
  }

  @Test func protectedSessionsNeverWriteRecoverySnapshots() throws {
    // P28-024: a snapshot of a protected document would put decrypted content
    // on disk outside its protection, so the store refuses.
    let source = try PDFSource(data: fixture("aes-256-r6"))
    let session = DocumentEditSession()
    try session.loadProtected(source, password: "abc")
    try session.rotatePage(id: session.pageIDs[0], byDegrees: 90)
    #expect(session.isDirty)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(policy: RecoveryPolicy(directory: directory))
    #expect(try store.snapshot(session: session, key: "protected", originalURL: nil) == nil)
    #expect(try store.latest(for: "protected") == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("protected").path))
  }

  @Test func keychainStoreRoundTripsWhenAvailable() throws {
    let url = URL(fileURLWithPath: "/tmp/spdf-keychain-\(UUID().uuidString).pdf")
    guard KeychainCredentialStore.save(password: "s3cret", forDocumentAt: url) else {
      // A headless/unsigned test host may deny keychain access; the app path
      // is exercised through the same store.
      return
    }
    defer { KeychainCredentialStore.remove(forDocumentAt: url) }
    #expect(KeychainCredentialStore.password(forDocumentAt: url) == "s3cret")
    #expect(KeychainCredentialStore.save(password: "newer", forDocumentAt: url))
    #expect(KeychainCredentialStore.password(forDocumentAt: url) == "newer")
    #expect(KeychainCredentialStore.remove(forDocumentAt: url))
    #expect(KeychainCredentialStore.password(forDocumentAt: url) == nil)
  }
}

/// P38-022: repaired documents whose graph did not fully validate stay
/// read-only until the repair is explicitly accepted.
@Suite("Repair gating")
struct RepairGatingTests {
  @Test func repairedDocumentsStayReadOnlyUntilAccepted() throws {
    let data = try PDFFixtures.onePage()
    let source = try PDFSource(data: data)
    let session = DocumentEditSession()
    session.load(source)
    #expect(session.canEdit)
    #expect(!session.repairedEditGated)

    // A repaired-but-unvalidated document gates edits and keeps the source
    // bytes available for an exact copy.
    session.markRepaired(editSafe: false)
    #expect(!session.canEdit)
    #expect(session.repairedEditGated)
    #expect(throws: PDFError.self) { try session.rotatePage(at: 0, byDegrees: 90) }
    #expect(try session.bytesForSave() == data)
    #expect(!session.isDirty)

    // Reloading clears the gate.
    session.load(source)
    #expect(session.canEdit)
    #expect(!session.repairedEditGated)
  }
}

/// P23-023: the organizer's actions are single transactions, so a multi-page
/// delete or a duplicate is one compound undo step.
@Suite("Page organizer actions")
struct PageOrganizerActionTests {
  @Test func multiPageActionsAreSingleUndoSteps() throws {
    let source = try PDFSource(data: try PDFFixtures.threePages())
    let session = DocumentEditSession()
    session.load(source)
    let originalOrder = session.pageIDs
    #expect(originalOrder.count == 3)

    // Delete two pages in one transaction: one undo restores everything.
    try session.apply(PDFTransaction([DeletePagesCommand(pageIDs: [originalOrder[0], originalOrder[2]])]))
    #expect(session.pageIDs == [originalOrder[1]])
    #expect(session.canUndo)
    session.undo()
    #expect(session.pageIDs == originalOrder)
    #expect(!session.isDirty)

    // Duplicate + reorder as one transaction is also a single undo step.
    try session.apply(
      PDFTransaction([
        DuplicatePageCommand(pageID: originalOrder[0]),
        ReorderPagesCommand(pageID: originalOrder[2], toIndex: 0),
      ]))
    #expect(session.pageIDs.count == 4)
    session.undo()
    #expect(session.pageIDs == originalOrder)
    #expect(try session.bytesForSave() == source.data)
  }
}

extension EditSessionTests {
  /// P04-025: locking releases the file key — the wrong password fails
  /// afterwards and the right one unlocks again from scratch.
  @Test func lockReleasesTheFileKey() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Encrypted/aes-256-r6.pdf")
    let source = try PDFSource(data: Data(contentsOf: url))
    let session = DocumentEditSession()
    try session.loadProtected(source, password: "abc")
    #expect(session.isProtected && session.canEdit)
    session.lockSession()
    #expect(!session.isProtected && !session.canEdit)
    #expect(throws: PDFError.self) {
      try session.loadProtected(source, password: "wrong")
    }
    #expect(!session.isProtected)
    try session.loadProtected(source, password: "abc")
    #expect(session.isProtected && session.canEdit)
  }
}
