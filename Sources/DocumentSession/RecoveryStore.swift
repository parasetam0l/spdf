import Foundation
import PDFCore

/// P10-016: bounded autosave and local recovery policy.
public struct RecoveryPolicy: Sendable, Equatable {
  public var directory: URL
  public var maximumRecords: Int
  public var maximumBytes: Int
  public var autosaveInterval: TimeInterval

  public init(
    directory: URL, maximumRecords: Int = 8, maximumBytes: Int = 128 * 1_024 * 1_024,
    autosaveInterval: TimeInterval = 30
  ) {
    self.directory = directory
    self.maximumRecords = max(1, maximumRecords)
    self.maximumBytes = max(1_024, maximumBytes)
    self.autosaveInterval = max(5, autosaveInterval)
  }
}

/// Metadata stored beside a recovery snapshot. The index never contains
/// document content (P10-018).
public struct RecoveryRecord: Sendable, Equatable {
  public let key: String
  public let version: Int
  public let savedAt: Date
  public let originalURLPath: String?
  public let byteCount: Int
}

/// P10-016–P10-022: a versioned, bounded, owner-only local recovery store.
/// Snapshots are written atomically; only metadata goes into the index; the
/// bytes file contains the document itself and is never logged.
public struct RecoveryStore: Sendable {
  public let policy: RecoveryPolicy

  public init(policy: RecoveryPolicy) {
    self.policy = policy
  }

  /// P10-022: a key that survives moves and renames on the same volume by
  /// using the file's inode, falling back to the normalized path.
  public static func documentKey(for url: URL?) -> String {
    guard let url else { return "untitled" }
    let path = url.standardizedFileURL.path
    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let inode = attributes[.systemFileNumber] as? NSNumber
    {
      return "inode-\(inode.uint64Value)"
    }
    return "path-\(stableHash(path))"
  }

  static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  /// P10-016/P10-017/P10-019/P10-020: snapshot a dirty, editable session.
  /// Non-editable (for example protected) documents never produce recovery
  /// state, and a clean session has nothing to recover.
  @discardableResult
  public func snapshot(
    session: DocumentEditSession, key: String, originalURL: URL?, now: Date = Date()
  ) throws -> RecoveryRecord? {
    guard session.canEdit, session.isDirty else { return nil }
    // P28-024: protected documents never write recovery snapshots. A snapshot
    // would place decrypted content on disk outside the document's
    // protection; records are purged on save and lock instead.
    guard !session.isProtected else { return nil }
    let bytes = try session.bytesForSave()
    guard bytes.count <= policy.maximumBytes else {
      throw PDFError(.limitExceeded, "The document is too large for recovery snapshots")
    }
    let keyDirectory = directory(for: key)
    try createOwnerOnlyDirectory(keyDirectory)
    let version = (try latest(for: key)?.version ?? 0) + 1
    let bytesURL = keyDirectory.appendingPathComponent("\(version).pdf")
    let temporaryURL = keyDirectory.appendingPathComponent(".\(version).pdf.tmp")
    try bytes.write(to: temporaryURL, options: .atomic)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    if FileManager.default.fileExists(atPath: bytesURL.path) {
      try FileManager.default.removeItem(at: bytesURL)
    }
    try FileManager.default.moveItem(at: temporaryURL, to: bytesURL)
    let record = RecoveryRecord(
      key: key, version: version, savedAt: now, originalURLPath: originalURL?.path,
      byteCount: bytes.count)
    try writeIndex(record, keyDirectory: keyDirectory)
    try prune(key: key)
    return record
  }

  /// P10-020: the newest snapshot bytes for a key, if any.
  public func latest(for key: String) throws -> RecoveryRecord? {
    try records(for: key).max { $0.version < $1.version }
  }

  public func latestBytes(for key: String) throws -> Data? {
    guard let record = try latest(for: key) else { return nil }
    return try Data(contentsOf: bytesURL(key: key, version: record.version))
  }

  /// P10-021: drop every recovery record for a key after a verified save.
  public func discard(for key: String) throws {
    let keyDirectory = directory(for: key)
    if FileManager.default.fileExists(atPath: keyDirectory.path) {
      try FileManager.default.removeItem(at: keyDirectory)
    }
  }

  public func records(for key: String) throws -> [RecoveryRecord] {
    let indexURL = directory(for: key).appendingPathComponent("index.json")
    guard let data = try? Data(contentsOf: indexURL),
      let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return entries.compactMap { entry in
      guard let version = entry["version"] as? Int, let savedAt = entry["savedAt"] as? Double
      else { return nil }
      return RecoveryRecord(
        key: key, version: version, savedAt: Date(timeIntervalSince1970: savedAt),
        originalURLPath: entry["originalPath"] as? String,
        byteCount: entry["byteCount"] as? Int ?? 0)
    }
  }

  /// P10-016: all keys that currently have recovery state.
  public func pendingKeys() -> [String] {
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: policy.directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else { return [] }
    return contents.filter { url in
      url.lastPathComponent.hasPrefix("recovery-")
        && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }.map { String($0.lastPathComponent.dropFirst("recovery-".count)) }.sorted()
  }

  // MARK: - Private

  func directory(for key: String) -> URL {
    policy.directory.appendingPathComponent("recovery-\(key)", isDirectory: true)
  }

  func bytesURL(key: String, version: Int) -> URL {
    directory(for: key).appendingPathComponent("\(version).pdf")
  }

  func createOwnerOnlyDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      if !isDirectory.boolValue {
        throw PDFError(.malformed, "Recovery path is not a directory")
      }
      return
    }
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  func writeIndex(_ record: RecoveryRecord, keyDirectory: URL) throws {
    var entries = try records(for: record.key)
    entries.removeAll { $0.version == record.version }
    entries.append(record)
    try writeIndex(entries, keyDirectory: keyDirectory)
  }

  func writeIndex(_ entries: [RecoveryRecord], keyDirectory: URL) throws {
    let sorted = entries.sorted { $0.version < $1.version }
    let payload: [[String: Any]] = sorted.map { entry in
      var dictionary: [String: Any] = [
        "version": entry.version,
        "savedAt": entry.savedAt.timeIntervalSince1970,
        "byteCount": entry.byteCount,
      ]
      if let path = entry.originalURLPath { dictionary["originalPath"] = path }
      return dictionary
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let indexURL = keyDirectory.appendingPathComponent("index.json")
    try data.write(to: indexURL, options: .atomic)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
  }

  /// P10-016: keep only the newest `maximumRecords` snapshots and keep the
  /// index consistent with the retained files.
  func prune(key: String) throws {
    let keyDirectory = directory(for: key)
    let contents = try FileManager.default.contentsOfDirectory(
      at: keyDirectory, includingPropertiesForKeys: nil, options: [])
    let versions = contents.compactMap { url -> Int? in
      let name = url.deletingPathExtension().lastPathComponent
      guard !name.hasPrefix("."), name != "index" else { return nil }
      return Int(name)
    }.sorted()
    guard versions.count > policy.maximumRecords else { return }
    let removed = Set(versions.prefix(versions.count - policy.maximumRecords))
    for version in removed {
      try? FileManager.default.removeItem(at: keyDirectory.appendingPathComponent("\(version).pdf"))
    }
    let remaining = try records(for: key).filter { !removed.contains($0.version) }
    try writeIndex(remaining, keyDirectory: keyDirectory)
  }
}
