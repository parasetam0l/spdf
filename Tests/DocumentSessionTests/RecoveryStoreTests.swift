import Foundation
import PDFCore
@testable import DocumentSession
import PDFFixtures
@testable import PDFEditing
import Testing

/// P10-016–P10-023/P10-029 evidence: bounded versioned recovery, restore
/// after simulated termination, discard after verified saves, owner-only
/// access, move-safe keys, and view state kept separate from edits.
@Suite("Recovery")
struct RecoveryStoreTests {
  @Test func snapshotsAreVersionedBoundedAndRestorable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(policy: RecoveryPolicy(directory: directory, maximumRecords: 3))
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.textWidthsPages()))
    let pageID = session.pageIDs[0]

    // A clean session has nothing to recover.
    #expect(try store.snapshot(session: session, key: "doc", originalURL: nil) == nil)

    try session.rotatePage(at: 0, byDegrees: 90)
    let first = try #require(try store.snapshot(session: session, key: "doc", originalURL: nil))
    #expect(first.version == 1)
    try session.apply(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: [42, 730, 62, 730, 42, 710, 62, 710])
      ]))
    let second = try #require(try store.snapshot(session: session, key: "doc", originalURL: nil))
    #expect(second.version == 2)
    #expect(second.byteCount > 0)

    // P10-020: restore after simulated termination.
    let recoveredBytes = try #require(try store.latestBytes(for: "doc"))
    let restored = DocumentEditSession()
    restored.load(try PDFSource(data: recoveredBytes))
    #expect(restored.currentGraph == session.currentGraph)
    #expect(
      try CommentList.comments(in: restored.currentGraph!, pageIDs: restored.pageIDs).count == 1)

    // P10-016: the record bound prunes the oldest snapshots.
    for _ in 0..<4 {
      try session.rotatePage(at: 0, byDegrees: 90)
      _ = try store.snapshot(session: session, key: "doc", originalURL: nil)
    }
    let records = try store.records(for: "doc")
    #expect(records.count == 3)
    #expect(records.map(\.version) == [4, 5, 6])

    // P10-018: the index carries no document content and files are owner-only.
    let indexURL = store.directory(for: "doc").appendingPathComponent("index.json")
    let indexText = String(decoding: try Data(contentsOf: indexURL), as: UTF8.self)
    #expect(!indexText.contains("Original"))
    let indexPermissions =
      try FileManager.default.attributesOfItem(atPath: indexURL.path)[.posixPermissions]
      as? NSNumber
    #expect(indexPermissions?.intValue == 0o600)
    let bytesURL = store.bytesURL(key: "doc", version: 6)
    let bytesPermissions =
      try FileManager.default.attributesOfItem(atPath: bytesURL.path)[.posixPermissions]
      as? NSNumber
    #expect(bytesPermissions?.intValue == 0o600)
    let directoryPermissions =
      try FileManager.default.attributesOfItem(atPath: store.directory(for: "doc").path)[
        .posixPermissions
      ] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)

    // P10-021/P10-029: a verified save discards stale records, and a clean
    // session never re-applies saved transactions.
    session.noteSaved()
    try store.discard(for: "doc")
    #expect(try store.latest(for: "doc") == nil)
    #expect(try store.snapshot(session: session, key: "doc", originalURL: nil) == nil)
    #expect(store.pendingKeys().isEmpty)
  }

  @Test func protectedAndEmptySessionsNeverSnapshot() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(policy: RecoveryPolicy(directory: directory))
    let session = DocumentEditSession()
    #expect(!session.canEdit)
    #expect(try store.snapshot(session: session, key: "empty", originalURL: nil) == nil)
    #expect(try store.latest(for: "empty") == nil)
  }

  @Test func pendingKeysResolveStoredSnapshots() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoveryStore(policy: RecoveryPolicy(directory: directory))
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFFixtures.onePage()))
    try session.rotatePage(at: 0, byDegrees: 90)
    let expected = try session.bytesForSave()
    _ = try store.snapshot(session: session, key: "inode-123", originalURL: nil)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("unrelated"), withIntermediateDirectories: true)
    #expect(store.pendingKeys() == ["inode-123"])
    let key = try #require(store.pendingKeys().first)
    #expect(try store.latestBytes(for: key) == expected)
  }

  @Test func documentKeySurvivesMovesAndRenames() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("document.pdf")
    try PDFFixtures.onePage().write(to: original)
    let key = RecoveryStore.documentKey(for: original)
    let renamed = directory.appendingPathComponent("renamed.pdf")
    try FileManager.default.moveItem(at: original, to: renamed)
    #expect(RecoveryStore.documentKey(for: renamed) == key)
  }

  @Test func viewStateRoundTripsSeparatelyFromEdits() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ViewStateStore(directory: directory)
    let state = ViewState(
      windowFrame: [10, 20, 800, 600], pageNumber: 3, scale: 1.25, sidebarVisible: false,
      sidebarMode: "comments")
    try store.save(state, for: "doc")
    #expect(store.load(for: "doc") == state)
    try store.discard(for: "doc")
    #expect(store.load(for: "doc") == nil)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spdf-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

extension RecoveryStoreTests {
  /// P12-019: sidebar width and layout mode round-trip; files written before
  /// the fields existed load with automatic width and continuous layout.
  @Test func viewStateCarriesSidebarWidthAndLayoutMode() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ViewStateStore(directory: directory)
    let state = ViewState(
      windowFrame: [10, 20, 800, 600], pageNumber: 2, scale: 1.5,
      sidebarVisible: true, sidebarMode: "pages", sidebarWidth: 210,
      continuous: false)
    try store.save(state, for: "doc")
    #expect(store.load(for: "doc") == state)
    let legacy: [String: Any] = [
      "windowFrame": [Double](), "pageNumber": 1, "scale": 0.0,
      "sidebarVisible": true, "sidebarMode": "pages",
    ]
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    let legacyURL = directory.appendingPathComponent("view-legacy.json")
    try legacyData.write(to: legacyURL)
    #expect(store.load(for: "legacy") == ViewState())
  }
}
