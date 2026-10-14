import DocumentSession
import Foundation
import Testing

@Suite("Update relaunch state")
struct UpdateRelaunchStoreTests {
  @Test func claimIsOneUseAndPreservesPrivateCompatibleBackup() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UpdateRelaunchStore(directory: directory)
    let state = UpdateRelaunchState(bundleIdentifier: "test.spdf", sourceBuild: "12", documents: [],
      updateSettingsFrame: [10, 20, 460, 380])
    try store.stage(state)
    #expect(try store.take(bundleIdentifier: "test.spdf") == state)
    #expect(try store.take(bundleIdentifier: "test.spdf") == nil)
    #expect(try JSONDecoder().decode(UpdateRelaunchState.self,
      from: Data(contentsOf: store.backupURL)) == state)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber == NSNumber(value: 0o700))
    #expect(try FileManager.default.attributesOfItem(atPath: store.backupURL.path)[.posixPermissions]
      as? NSNumber == NSNumber(value: 0o600))
  }

  @Test func futureSchemaAndWrongApplicationArePreserved() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UpdateRelaunchStore(directory: directory)
    let state = UpdateRelaunchState(bundleIdentifier: "test.spdf", sourceBuild: "12", documents: [])
    try store.stage(state)
    let original = try Data(contentsOf: store.pendingURL)
    #expect(throws: CocoaError.self) { try store.take(bundleIdentifier: "other.spdf") }
    #expect(try Data(contentsOf: store.pendingURL) == original)
    var future = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    future["schemaVersion"] = 2
    let unknown = try JSONSerialization.data(withJSONObject: future)
    try unknown.write(to: store.pendingURL)
    #expect(throws: CocoaError.self) { try store.take(bundleIdentifier: "test.spdf") }
    #expect(try Data(contentsOf: store.pendingURL) == unknown)
    #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
    #expect(throws: CocoaError.self) { try store.stage(state) }
    #expect(try Data(contentsOf: store.pendingURL) == unknown)
  }

  @Test func failedBackupDoesNotConsumeThePendingRequest() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UpdateRelaunchStore(directory: directory)
    try store.stage(UpdateRelaunchState(bundleIdentifier: "test.spdf", sourceBuild: "12", documents: []))
    let original = try Data(contentsOf: store.pendingURL)
    try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: true)
    #expect(throws: CocoaError.self) { try store.take(bundleIdentifier: "test.spdf") }
    #expect(try Data(contentsOf: store.pendingURL) == original)
  }

  @Test func expiredRecordDoesNotReopenAnOldSession() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UpdateRelaunchStore(directory: directory)
    let now = Date()
    try store.stage(UpdateRelaunchState(bundleIdentifier: "test.spdf", sourceBuild: "12", documents: [],
      now: now.addingTimeInterval(-8 * 24 * 60 * 60)))
    #expect(try store.take(bundleIdentifier: "test.spdf", now: now) == nil)
    #expect(FileManager.default.fileExists(atPath: store.backupURL.path))
    #expect(!FileManager.default.fileExists(atPath: store.pendingURL.path))
  }

  @Test func identityBookmarkFollowsRenameAndCarriesOnlyViewState() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = directory.appendingPathComponent("original.pdf")
    let renamed = directory.appendingPathComponent("renamed.pdf")
    try Data("Private document contents never enter the journal".utf8).write(to: original)
    let view = ViewState(windowFrame: [10, 20, 800, 600], pageNumber: 3, scale: 1.25,
      sidebarMode: "forms", sidebarWidth: 200, continuous: false)
    var entry = try RelaunchDocument(url: original, view: view, wasKeyWindow: true)
    try FileManager.default.moveItem(at: original, to: renamed)
    let resolved = try entry.resolve()
    #expect(resolved.standardizedFileURL.path == renamed.standardizedFileURL.path)
    #expect(entry.view == view && entry.wasKeyWindow)
    let encoded = try JSONEncoder().encode(entry)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("Private document contents"))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spdf-relaunch-\(UUID().uuidString)")
  }
}
