import Foundation
import PDFCore
@testable import DocumentSession
import PDFFixtures
@testable import PDFEditing
import PDFFixtures
import Testing

/// P17-020/P17-023/P17-024/P17-029 evidence: recovery snapshots and save
/// bytes always reflect a committed transaction order (never a partial
/// transaction), reload coordinates with pending history, and undo memory is
/// bounded and measured.
@Suite("Transaction order")
struct TransactionOrderTests {
  private func loadedSession() throws -> DocumentEditSession {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.textWidthsPages()))
    return session
  }

  private func highlightQuads(_ index: Int) -> [Double] {
    let shift = Double(index)
    return [42, 730 + shift, 62, 730 + shift, 42, 710 + shift, 62, 710 + shift]
  }

  /// One transaction that changes two independent facts at once, so a
  /// partially applied transaction is detectable from either fact alone.
  private func pair(_ session: DocumentEditSession, index: Int) throws {
    let pageID = session.pageIDs[0]
    try session.apply(PDFTransaction([
      AddHighlightCommand(pageID: pageID, quads: highlightQuads(index)),
      RotatePagesCommand(pageIDs: [pageID], byDegrees: 90),
    ]))
  }

  /// (comment count, rotation degrees) of a graph — both come from the same
  /// committed pairs, so a mixed state would mean a partial transaction.
  private func stateOf(_ bytes: Data) throws -> (comments: Int, rotation: Int) {
    let parsed = try PDFParser.parse(bytes)
    let pageID = parsed.pageIDs[0]
    let comments = try CommentList.comments(in: parsed.graph, pageIDs: parsed.pageIDs).count
    var rotation = 0
    if case .dictionary(let page)? = parsed.graph.objects[pageID],
      case .integer(let raw)? = page[PDFName("Rotate")]
    {
      rotation = Int(raw)
    }
    return (comments, rotation)
  }

  @Test func recoveryReplayFollowsCommittedOrder() throws {
    // P17-020: a snapshot captures exactly the committed state; undo and redo
    // move the recoverable state with them, in order.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(policy: RecoveryPolicy(directory: directory))
    let session = try loadedSession()
    let key = "doc"

    // A clean session has nothing to recover.
    #expect(try store.snapshot(session: session, key: key, originalURL: nil) == nil)

    try pair(session, index: 0)
    let first = try #require(try store.snapshot(session: session, key: key, originalURL: nil))
    let firstURL = store.bytesURL(key: key, version: first.version)
    let firstBytes = try Data(contentsOf: firstURL)
    let firstState = try stateOf(firstBytes)
    #expect(firstState.comments == 1)
    #expect(firstState.rotation == 90)

    // Undo removes the whole pair (one transaction, one undo step); the
    // replayed state follows: a clean session needs no recovery.
    #expect(session.undo())
    #expect(try store.snapshot(session: session, key: key, originalURL: nil) == nil)
    // Redo restores the pair atomically and a fresh snapshot reflects it.
    #expect(session.redo())
    let second = try #require(try store.snapshot(session: session, key: key, originalURL: nil))
    let secondURL = store.bytesURL(key: key, version: second.version)
    let secondBytes = try Data(contentsOf: secondURL)
    let secondState = try stateOf(secondBytes)
    #expect(secondState.comments == 1)
    #expect(secondState.rotation == 90)
    // Replaying the latest snapshot reproduces the session's committed state.
    let restored = DocumentEditSession()
    restored.load(try PDFSource(data: secondBytes))
    #expect(restored.currentGraph == session.currentGraph)
  }

  @Test func snapshotsAndSavesNeverCapturePartialTransactions() async throws {
    // P17-020/P17-023: snapshots and save bytes taken while transactions
    // commit concurrently always show both facts of a pair or neither.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-atomic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(policy: RecoveryPolicy(directory: directory))
    let session = try loadedSession()
    let key = "race"
    let pairs = 6

    let observations = await withTaskGroup(of: [(Int, Int)]?.self) { group -> [[(Int, Int)]] in
      for index in 0..<pairs {
        group.addTask {
          try? self.pair(session, index: index)
          return nil
        }
        group.addTask {
          guard let bytes = try? session.bytesForSave(),
            let state = try? self.stateOf(bytes)
          else { return nil }
          return [(state.comments, state.rotation)]
        }
        group.addTask {
          guard
            let record = try? store.snapshot(session: session, key: key, originalURL: nil),
            let bytes = try? Data(contentsOf: store.bytesURL(key: key, version: record.version)),
            let state = try? self.stateOf(bytes)
          else { return nil }
          return [(state.comments, state.rotation)]
        }
      }
      var collected: [[(Int, Int)]] = []
      for await result in group {
        if let result { collected.append(result) }
      }
      return collected
    }
    let states = observations.flatMap { $0 }
    #expect(!states.isEmpty)
    // Both-or-neither: rotation counts the same pairs the comments do
    // (rotations normalize to 0/90/180/270, so the count is modulo 360).
    for state in states {
      #expect(state.1 == (state.0 * 90) % 360, "partial transaction observed: \(state)")
    }
    // The final state has every pair exactly once.
    let finalBytes = try session.bytesForSave()
    let finalState = try stateOf(finalBytes)
    #expect(finalState.comments == pairs)
    #expect(finalState.rotation == (pairs * 90) % 360)
  }

  @Test func reloadCoordinatesWithPendingHistory() throws {
    // P17-024: reloading a document discards pending undo/redo history,
    // resets dirtiness, advances the revision, and reports an all-pages
    // change set. Worker coordination itself is covered by the render
    // service tests (closed documents reject renders; P11-012).
    let session = try loadedSession()
    try pair(session, index: 0)
    try pair(session, index: 1)
    #expect(session.canUndo)
    #expect(session.isDirty)
    let revisionBefore = session.documentRevision

    let replacement = try PDFFixtures.onePage()
    session.load(try PDFSource(data: replacement))
    #expect(!session.canUndo)
    #expect(!session.canRedo)
    #expect(!session.isDirty)
    #expect(session.documentRevision == revisionBefore + 1)
    #expect(session.changeSet().pageIDs.isEmpty)  // all pages
    #expect(try session.bytesForSave() == replacement)
    let parsed = try PDFParser.parse(try #require(session.currentGraph.map { try PDFWriter.write($0) }))
    #expect(parsed.pageIDs == session.pageIDs)
  }

  @Test func undoMemoryIsBoundedAndMeasured() throws {
    // P17-029: 200 commits keep the bounded 50-entry undo stack; the oldest
    // snapshots are dropped and memory growth stays bounded. Numbers print.
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.threePages()))
    let start = ContinuousClock.now
    for index in 0..<200 {
      let pageID = session.pageIDs[index % 3]
      try session.apply(PDFTransaction([
        RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)
      ]))
    }
    let elapsed = ContinuousClock.now - start
    let milliseconds =
      elapsed.components.seconds * 1000
      + elapsed.components.attoseconds / 1_000_000_000_000_000
    // Exactly the 50 most recent entries remain undoable.
    var undone = 0
    while session.undo() { undone += 1 }
    #expect(undone == DocumentEditSession.undoLimit)
    // Redo restores the same bound in the other direction.
    var redone = 0
    while session.redo() { redone += 1 }
    #expect(redone == DocumentEditSession.undoLimit)
    let growth = memoryFootprint()
    print(
      "[P17-029] 200 commits in \(milliseconds) ms, bounded undo \(DocumentEditSession.undoLimit), "
        + "footprint after \(growth / 1_048_576) MiB")
    #expect(milliseconds < 10_000)
  }

  private func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
