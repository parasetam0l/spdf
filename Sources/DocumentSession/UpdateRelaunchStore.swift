import Foundation

/// File identity and view metadata only; document bytes and credentials have
/// no representation in the relaunch format.
public struct RelaunchDocument: Sendable, Equatable, Codable {
  public var bookmark: Data
  public var securityScoped: Bool
  public var view: ViewState
  public var wasKeyWindow: Bool

  public init(url: URL, view: ViewState, wasKeyWindow: Bool = false) throws {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    do {
      bookmark = try url.bookmarkData(options: [.withSecurityScope])
      securityScoped = true
    } catch {
      // The current application is not sandboxed. Some locations only
      // support a regular identity bookmark; normal file permissions apply.
      bookmark = try url.bookmarkData(options: [.minimalBookmark])
      securityScoped = false
    }
    self.view = view
    self.wasKeyWindow = wasKeyWindow
  }

  public mutating func resolve() throws -> URL {
    var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    if securityScoped { options.insert(.withSecurityScope) }
    var stale = false
    let url = try URL(resolvingBookmarkData: bookmark, options: options,
      relativeTo: nil, bookmarkDataIsStale: &stale)
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    if stale {
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      let renewed = try RelaunchDocument(url: url, view: view, wasKeyWindow: wasKeyWindow)
      bookmark = renewed.bookmark
      securityScoped = renewed.securityScoped
    }
    return url
  }
}

public struct UpdateRelaunchState: Sendable, Equatable, Codable {
  public var schemaVersion: Int = 1
  public var id: UUID = UUID()
  public var bundleIdentifier: String
  public var sourceBuild: String
  public var createdAt: Date
  public var documents: [RelaunchDocument]
  public var updateSettingsFrame: [Double]?

  public init(bundleIdentifier: String, sourceBuild: String, documents: [RelaunchDocument],
    updateSettingsFrame: [Double]? = nil, now: Date = Date())
  {
    self.bundleIdentifier = bundleIdentifier
    self.sourceBuild = sourceBuild
    self.documents = documents
    self.updateSettingsFrame = updateSettingsFrame
    createdAt = now
  }
}

/// Pending state is claimed once, with a compatible backup retained for
/// manual rollback. Unknown future schemas remain untouched.
public struct UpdateRelaunchStore: Sendable {
  public let directory: URL
  public var pendingURL: URL { directory.appendingPathComponent("pending.json") }
  public var backupURL: URL { directory.appendingPathComponent("previous.json") }

  public init(directory: URL) { self.directory = directory }

  public func stage(_ state: UpdateRelaunchState) throws {
    guard state.schemaVersion == 1, state.documents.count <= 100 else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    if FileManager.default.fileExists(atPath: pendingURL.path) {
      let existing = try Data(contentsOf: pendingURL, options: .mappedIfSafe)
      guard existing.count <= 4 * 1_024 * 1_024,
        let header = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
        header["schemaVersion"] as? Int == 1
      else { throw CocoaError(.fileReadCorruptFile) }
      try writeData(existing, to: backupURL)
    }
    try write(state, to: pendingURL)
  }

  public func take(bundleIdentifier: String, now: Date = Date()) throws -> UpdateRelaunchState? {
    guard FileManager.default.fileExists(atPath: pendingURL.path) else { return nil }
    let data = try Data(contentsOf: pendingURL, options: .mappedIfSafe)
    guard data.count <= 4 * 1_024 * 1_024,
      let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      header["schemaVersion"] as? Int == 1
    else { throw CocoaError(.fileReadCorruptFile) }
    let state = try JSONDecoder().decode(UpdateRelaunchState.self, from: data)
    guard state.bundleIdentifier == bundleIdentifier, state.documents.count <= 100 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    // Persist the original schema before consuming. A failed backup write
    // never silently discards the pending request.
    try writeData(data, to: backupURL)
    try FileManager.default.removeItem(at: pendingURL)
    guard now.timeIntervalSince(state.createdAt) <= 7 * 24 * 60 * 60,
      state.createdAt.timeIntervalSince(now) <= 5 * 60
    else { return nil }
    return state
  }

  public func saveBackup(_ state: UpdateRelaunchState) throws {
    try write(state, to: backupURL)
  }

  private func write(_ state: UpdateRelaunchState, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
    try writeData(data, to: url)
  }

  private func writeData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
