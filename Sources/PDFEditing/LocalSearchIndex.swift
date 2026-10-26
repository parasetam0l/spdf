import CryptoKit
import Foundation
import PDFCore

// MARK: - Locations

/// AUT-02: one explicit, user-chosen indexing location. Paths are absolute and
/// standardized; the system locations, the home directory itself and the file
/// system root are refused so indexing never silently covers a whole disk.
public struct SearchIndexLocation: Sendable, Equatable, Codable {
  public let path: String
  public let includeSubfolders: Bool

  public init(path: String, includeSubfolders: Bool = true) {
    self.path = path
    self.includeSubfolders = includeSubfolders
  }

  public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

  /// Validate one location before it is added. Throws a clear reason instead of
  /// indexing an unintended tree.
  public static func validated(
    _ rawPath: String, includeSubfolders: Bool
  ) throws -> SearchIndexLocation {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == rawPath, !rawPath.isEmpty else {
      throw PDFError(.malformed, "An indexing location must be a non-empty trimmed path")
    }
    guard rawPath.hasPrefix("/") else {
      throw PDFError(.malformed, "An indexing location must be an absolute path")
    }
    let standardized = URL(fileURLWithPath: rawPath)
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard standardized != "/" else {
      throw PDFError(.malformed, "The file system root cannot be an indexing location")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard standardized != home else {
      throw PDFError(
        .unsupported,
        "The home directory itself is too broad; choose the specific folder to index")
    }
    let refusedPrefixes = [
      "/System", "/Library", "/Applications", "/usr", "/private/etc",
      "/private/var/db", "/private/var/root",
    ]
    for prefix in refusedPrefixes
    where standardized == prefix || standardized.hasPrefix(prefix + "/") {
      throw PDFError(.unsupported, "System location \(prefix) cannot be indexed")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw PDFError(.malformed, "The indexing location is not an existing folder") }
    return SearchIndexLocation(path: standardized, includeSubfolders: includeSubfolders)
  }

  func contains(_ candidatePath: String) -> Bool {
    candidatePath == path || candidatePath.hasPrefix(path + "/")
  }
}

/// AUT-02: what the index stores (privacy-relevant) and its bounds.
public struct SearchIndexOptions: Sendable, Equatable, Codable {
  public var includeRecognizedOCRText: Bool
  public var includeComments: Bool
  public var includeFormValues: Bool
  public var includeBookmarks: Bool
  public var includeMetadata: Bool
  public var maximumLocations: Int
  public var maximumFilesPerLocation: Int
  public var maximumIndexedDocuments: Int

  public init(
    includeRecognizedOCRText: Bool = true,
    includeComments: Bool = true,
    includeFormValues: Bool = true,
    includeBookmarks: Bool = true,
    includeMetadata: Bool = true,
    maximumLocations: Int = 16,
    maximumFilesPerLocation: Int = 5_000,
    maximumIndexedDocuments: Int = 20_000
  ) {
    self.includeRecognizedOCRText = includeRecognizedOCRText
    self.includeComments = includeComments
    self.includeFormValues = includeFormValues
    self.includeBookmarks = includeBookmarks
    self.includeMetadata = includeMetadata
    self.maximumLocations = maximumLocations
    self.maximumFilesPerLocation = maximumFilesPerLocation
    self.maximumIndexedDocuments = maximumIndexedDocuments
  }

  public func validate() throws {
    guard (1...64).contains(maximumLocations) else {
      throw PDFError(.malformed, "The indexing location limit must be 1...64")
    }
    guard (1...100_000).contains(maximumFilesPerLocation) else {
      throw PDFError(.malformed, "The per-location file limit must be 1...100000")
    }
    guard (1...200_000).contains(maximumIndexedDocuments) else {
      throw PDFError(.malformed, "The indexed-document limit must be 1...200000")
    }
  }
}

/// AUT-02: per-file index state. Only an indexed file contributes text; every
/// other state is explicit so a protected or unreadable file is never treated
/// as a no-match.
public enum SearchIndexFileStatus: String, Sendable, Codable, Equatable {
  case indexed
  /// Encrypted/protected (or a public-key handler): no text is stored.
  case protectedExcluded
  /// Readable, but no selected source produced searchable content.
  case noSearchableContent
  /// The indexed path no longer exists. Stored text is cleared.
  case missing
  case unsupported
  case readFailed

  public var title: String {
    switch self {
    case .indexed: return "Indexed"
    case .protectedExcluded: return "Protected (excluded)"
    case .noSearchableContent: return "No searchable content"
    case .missing: return "Missing"
    case .unsupported: return "Unsupported"
    case .readFailed: return "Read failed"
    }
  }
}

/// AUT-02: page-scoped searchable text. Comments, form values and bookmarks are
/// stored with their page so results keep file/page/context provenance.
public struct SearchIndexPage: Sendable, Equatable, Codable {
  public let pageIndex: Int
  public let documentText: String
  public let recognizedText: String?
  public let comments: [String]
  public let formValues: [String]
  public let bookmarks: [String]

  public init(
    pageIndex: Int, documentText: String, recognizedText: String?,
    comments: [String], formValues: [String], bookmarks: [String]
  ) {
    self.pageIndex = pageIndex
    self.documentText = documentText
    self.recognizedText = recognizedText
    self.comments = comments
    self.formValues = formValues
    self.bookmarks = bookmarks
  }
}

/// AUT-02: one indexed file. The content hash and modification time make the
/// incremental refresh exact; the path is the identity used for results.
public struct SearchIndexEntry: Sendable, Equatable, Codable, Identifiable {
  public let path: String
  public let fileSize: Int64
  public let modificationTime: TimeInterval
  public let contentHash: String
  public let status: SearchIndexFileStatus
  public let pageCount: Int
  public let pages: [SearchIndexPage]
  public let metadataValues: [String]
  public let detail: String?

  public var id: String { path }
  public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
  public var isSearchable: Bool { status == .indexed }

  public init(
    path: String, fileSize: Int64, modificationTime: TimeInterval, contentHash: String,
    status: SearchIndexFileStatus, pageCount: Int, pages: [SearchIndexPage],
    metadataValues: [String], detail: String?
  ) {
    self.path = path
    self.fileSize = fileSize
    self.modificationTime = modificationTime
    self.contentHash = contentHash
    self.status = status
    self.pageCount = pageCount
    self.pages = pages
    self.metadataValues = metadataValues
    self.detail = detail
  }
}

/// AUT-02: one refresh report. Added/updated/moved/removed/unchanged and the
/// excluded states stay separate so an incremental run is auditable.
public struct SearchIndexRefreshReport: Sendable, Equatable {
  public let scannedFiles: Int
  public let unchangedFiles: Int
  public let addedFiles: Int
  public let updatedFiles: Int
  public let movedFiles: Int
  public let removedFiles: Int
  public let protectedFiles: Int
  public let unsearchableFiles: Int
  public let failedFiles: Int
  public let skippedFiles: Int

  public var indexedFiles: Int { addedFiles + updatedFiles + movedFiles + unchangedFiles }

  public init(
    scannedFiles: Int, unchangedFiles: Int, addedFiles: Int, updatedFiles: Int,
    movedFiles: Int, removedFiles: Int, protectedFiles: Int, unsearchableFiles: Int,
    failedFiles: Int, skippedFiles: Int
  ) {
    self.scannedFiles = scannedFiles
    self.unchangedFiles = unchangedFiles
    self.addedFiles = addedFiles
    self.updatedFiles = updatedFiles
    self.movedFiles = movedFiles
    self.removedFiles = removedFiles
    self.protectedFiles = protectedFiles
    self.unsearchableFiles = unsearchableFiles
    self.failedFiles = failedFiles
    self.skippedFiles = skippedFiles
  }

  public var summary: String {
    var parts = [
      "\(scannedFiles) scanned",
      "\(addedFiles) added",
      "\(updatedFiles) updated",
      "\(movedFiles) moved",
      "\(removedFiles) missing",
      "\(unchangedFiles) unchanged",
    ]
    if protectedFiles > 0 { parts.append("\(protectedFiles) protected (not indexed)") }
    if unsearchableFiles > 0 { parts.append("\(unsearchableFiles) without content") }
    if failedFiles > 0 { parts.append("\(failedFiles) failed") }
    if skippedFiles > 0 { parts.append("\(skippedFiles) skipped") }
    return parts.joined(separator: ", ") + "."
  }
}

/// AUT-02: index search options. The context and result limits keep a query
/// bounded; sources mirror AUT-01 provenance.
public struct SearchIndexSearchOptions: Sendable, Equatable {
  public var textOptions: TextSearchOptions
  public var contextCharacters: Int
  public var maximumResults: Int

  public init(
    textOptions: TextSearchOptions = TextSearchOptions(),
    contextCharacters: Int = 60,
    maximumResults: Int = 500
  ) {
    self.textOptions = textOptions
    self.contextCharacters = contextCharacters
    self.maximumResults = maximumResults
  }

  public func validate() throws {
    guard (20...200).contains(contextCharacters) else {
      throw PDFError(.malformed, "Index search context must be 20...200 characters")
    }
    guard (1...5_000).contains(maximumResults) else {
      throw PDFError(.malformed, "The index result limit must be 1...5000")
    }
  }
}

/// AUT-02: one index hit with file/page/source/context provenance.
public struct SearchIndexHit: Sendable, Equatable, Identifiable {
  public let id: String
  public let path: String
  public let fileName: String
  public let pageIndex: Int?
  public let pageLabel: String?
  public let source: SearchSource
  public let context: String
  public let matchedText: String

  public init(
    id: String, path: String, fileName: String, pageIndex: Int?, pageLabel: String?,
    source: SearchSource, context: String, matchedText: String
  ) {
    self.id = id
    self.path = path
    self.fileName = fileName
    self.pageIndex = pageIndex
    self.pageLabel = pageLabel
    self.source = source
    self.context = context
    self.matchedText = matchedText
  }
}

/// AUT-02: the index search report. Excluded protected/missing files are
/// counted so a zero-hit result is distinguishable from an unindexed one.
public struct SearchIndexSearchReport: Sendable, Equatable {
  public let query: String
  public let hits: [SearchIndexHit]
  public let totalHits: Int
  public let indexedDocuments: Int
  public let protectedDocuments: Int
  public let missingDocuments: Int
  public let noContentDocuments: Int
  public let failedDocuments: Int

  public init(
    query: String, hits: [SearchIndexHit], totalHits: Int, indexedDocuments: Int,
    protectedDocuments: Int, missingDocuments: Int, noContentDocuments: Int,
    failedDocuments: Int
  ) {
    self.query = query
    self.hits = hits
    self.totalHits = totalHits
    self.indexedDocuments = indexedDocuments
    self.protectedDocuments = protectedDocuments
    self.missingDocuments = missingDocuments
    self.noContentDocuments = noContentDocuments
    self.failedDocuments = failedDocuments
  }

  public var summary: String {
    var parts = [
      "\(totalHits) \(totalHits == 1 ? "match" : "matches") in \(indexedDocuments) "
        + "indexed \(indexedDocuments == 1 ? "document" : "documents")",
    ]
    if protectedDocuments > 0 {
      parts.append("\(protectedDocuments) protected (not indexed)")
    }
    if missingDocuments > 0 { parts.append("\(missingDocuments) missing") }
    if noContentDocuments > 0 { parts.append("\(noContentDocuments) without content") }
    if failedDocuments > 0 { parts.append("\(failedDocuments) failed") }
    return parts.joined(separator: "; ") + "."
  }
}

// MARK: - The index

/// AUT-02: the local full-text index. It is explicit, versioned and
/// deterministic; locations are user-chosen folders and only unprotected,
/// readable documents contribute text. Encrypted/protected documents are
/// recorded by identity/status and their plaintext is never written.
///
/// Privacy disclosure (shown by the App panel): the index file is unencrypted
/// JSON and contains page text from unprotected documents. Protected documents
/// are excluded, but the chosen index location must still be protected like
/// the documents it describes.
public struct LocalSearchIndex: Sendable, Equatable, Codable {
  public static let currentVersion = 1
  public static let fileName = "FullTextIndex.json"
  public static let disclosure =
    "The local full-text index is an unencrypted JSON file. It stores page text "
    + "only for unprotected, readable documents; encrypted or protected documents "
    + "are recorded by path, size, hash and status and their plaintext is never "
    + "written. Keep the index in a location you control."

  public private(set) var version: Int
  public private(set) var options: SearchIndexOptions
  public private(set) var locations: [SearchIndexLocation]
  public private(set) var entries: [SearchIndexEntry]

  public init(options: SearchIndexOptions = SearchIndexOptions()) {
    self.version = Self.currentVersion
    self.options = options
    self.locations = []
    self.entries = []
  }

  public init(data: Data) throws {
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(LocalSearchIndex.self, from: data)
    self = decoded
    try validate()
  }

  /// Deterministic JSON: sorted keys, stable entry order.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public var indexedDocuments: Int { entries.filter(\.isSearchable).count }
  public var protectedDocuments: Int {
    entries.filter { $0.status == .protectedExcluded }.count
  }
  public var missingDocuments: Int { entries.filter { $0.status == .missing }.count }

  public func entry(for path: String) -> SearchIndexEntry? {
    entries.first { $0.path == path }
  }

  public mutating func addLocation(
    path: String, includeSubfolders: Bool = true
  ) throws {
    try options.validate()
    guard locations.count < options.maximumLocations else {
      throw PDFError(
        .limitExceeded,
        "At most \(options.maximumLocations) indexing locations are supported")
    }
    let location = try SearchIndexLocation.validated(
      path, includeSubfolders: includeSubfolders)
    guard !locations.contains(where: { $0.path == location.path }) else {
      throw PDFError(.malformed, "That folder is already an indexing location")
    }
    locations.append(location)
    locations.sort { $0.path < $1.path }
  }

  /// Removing a location also removes the entries under it, so a future
  /// refresh cannot keep returning files from a folder the user removed.
  @discardableResult
  public mutating func removeLocation(path: String) throws -> Int {
    let standardized = URL(fileURLWithPath: path)
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard let index = locations.firstIndex(where: { $0.path == standardized }) else {
      throw PDFError(.malformed, "That folder is not an indexing location")
    }
    let location = locations[index]
    locations.remove(at: index)
    let before = entries.count
    entries.removeAll { location.contains($0.path) }
    return before - entries.count
  }

  // MARK: Refresh

  /// AUT-02: incremental refresh. Files whose size and modification time are
  /// unchanged are reused without reading; changed files are re-extracted;
  /// files no longer present are marked missing with their text cleared; a
  /// file whose content moved to another indexed path is relinked by hash
  /// instead of being re-extracted.
  public mutating func refresh(
    limits: PDFLimits = PDFLimits()
  ) throws -> SearchIndexRefreshReport {
    try validate()
    guard !locations.isEmpty else {
      throw PDFError(.malformed, "Add an indexing location before refreshing")
    }
    let manager = FileManager.default
    var candidates: [URL] = []
    var skippedFiles = 0
    for location in locations {
      let urls = try Self.enumeratePDFs(
        in: location, maximum: options.maximumFilesPerLocation, manager: manager)
      if urls.count >= options.maximumFilesPerLocation { skippedFiles += 1 }
      candidates.append(contentsOf: urls)
    }
    var unique: [String: URL] = [:]
    for url in candidates {
      unique[url.standardizedFileURL.resolvingSymlinksInPath().path] = url
    }
    var ordered = unique.keys.sorted()
    if ordered.count > options.maximumIndexedDocuments {
      skippedFiles += ordered.count - options.maximumIndexedDocuments
      ordered = Array(ordered.prefix(options.maximumIndexedDocuments))
    }

    var existing = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    var missingExisting = existing.filter { !manager.fileExists(atPath: $0.key) }
    var newEntries: [SearchIndexEntry] = []
    var unchangedFiles = 0
    var addedFiles = 0
    var updatedFiles = 0
    var movedFiles = 0
    var protectedFiles = 0
    var unsearchableFiles = 0
    var failedFiles = 0

    for path in ordered {
      guard let url = unique[path] else { continue }
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      let fileSize = Int64(values?.fileSize ?? 0)
      let modificationTime = (values?.contentModificationDate ?? Date(timeIntervalSince1970: 0))
        .timeIntervalSince1970
      if let previous = existing[path], previous.fileSize == fileSize,
        abs(previous.modificationTime - modificationTime) < 0.001,
        previous.status != .missing
      {
        newEntries.append(previous)
        existing.removeValue(forKey: path)
        unchangedFiles += 1
        continue
      }
      let data: Data
      do {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
      } catch {
        newEntries.append(
          Self.failureEntry(
            path: path, fileSize: fileSize, modificationTime: modificationTime,
            hash: "", status: .readFailed,
            detail: "The file could not be read: \(error.localizedDescription)"))
        existing.removeValue(forKey: path)
        failedFiles += 1
        continue
      }
      let hash = Self.contentHash(data)
      // Moved-file handling: a new path whose bytes equal a missing entry is
      // the same document; relink it and keep its extracted text.
      if existing[path] == nil,
        let moved = missingExisting.first(where: { $0.value.contentHash == hash })
      {
        let previous = moved.value
        let entry = SearchIndexEntry(
          path: path, fileSize: fileSize, modificationTime: modificationTime,
          contentHash: hash, status: previous.status, pageCount: previous.pageCount,
          pages: previous.pages, metadataValues: previous.metadataValues,
          detail: previous.detail)
        newEntries.append(entry)
        existing.removeValue(forKey: path)
        existing.removeValue(forKey: moved.key)
        missingExisting.removeValue(forKey: moved.key)
        movedFiles += 1
        continue
      }
      let entry = Self.makeEntry(
        path: path, fileSize: fileSize, modificationTime: modificationTime,
        hash: hash, data: data, options: options, limits: limits)
      switch entry.status {
      case .protectedExcluded: protectedFiles += 1
      case .noSearchableContent: unsearchableFiles += 1
      case .readFailed, .unsupported: failedFiles += 1
      default: break
      }
      if existing.removeValue(forKey: path) == nil {
        addedFiles += 1
      } else {
        updatedFiles += 1
      }
      newEntries.append(entry)
    }

    // Entries not seen during this scan are either missing on disk or were
    // skipped because a limit was reached; missing files lose their text.
    var removedFiles = 0
    for (path, entry) in existing {
      if !manager.fileExists(atPath: path) {
        if entry.status == .missing {
          newEntries.append(entry)
        } else {
          newEntries.append(
            Self.failureEntry(
              path: path, fileSize: entry.fileSize,
              modificationTime: entry.modificationTime, hash: entry.contentHash,
              status: .missing,
              detail: "The indexed file no longer exists at this path."))
          removedFiles += 1
        }
      } else {
        newEntries.append(entry)
      }
    }
    entries = newEntries.sorted { $0.path < $1.path }
    return SearchIndexRefreshReport(
      scannedFiles: ordered.count, unchangedFiles: unchangedFiles,
      addedFiles: addedFiles, updatedFiles: updatedFiles, movedFiles: movedFiles,
      removedFiles: removedFiles, protectedFiles: protectedFiles,
      unsearchableFiles: unsearchableFiles, failedFiles: failedFiles,
      skippedFiles: skippedFiles)
  }

  // MARK: Search

  public func search(
    _ query: String, options: SearchIndexSearchOptions = SearchIndexSearchOptions()
  ) throws -> SearchIndexSearchReport {
    try options.validate()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PDFError(.malformed, "Enter search text") }
    var hits: [SearchIndexHit] = []
    var totalHits = 0
    var indexedDocuments = 0
    var protectedDocuments = 0
    var missingDocuments = 0
    var noContentDocuments = 0
    var failedDocuments = 0

    func append(
      entry: SearchIndexEntry, pageIndex: Int?, source: SearchSource, text: String
    ) {
      guard let match = AdvancedSearch.firstMatch(
        query: trimmed, in: text, options: options.textOptions)
      else { return }
      totalHits += 1
      guard hits.count < options.maximumResults else { return }
      let context = AdvancedSearch.contextSnippet(
        text, range: match.range, contextCharacters: options.contextCharacters)
      hits.append(
        SearchIndexHit(
          id: "\(entry.path)#\(pageIndex.map { String($0) } ?? "doc")#"
            + "\(source.rawValue)#\(totalHits)",
          path: entry.path, fileName: entry.fileName, pageIndex: pageIndex,
          pageLabel: pageIndex.map { "Page \($0 + 1)" }, source: source,
          context: context, matchedText: match.text))
    }

    for entry in entries {
      switch entry.status {
      case .indexed: indexedDocuments += 1
      case .protectedExcluded: protectedDocuments += 1
      case .missing: missingDocuments += 1
      case .noSearchableContent: noContentDocuments += 1
      case .unsupported, .readFailed: failedDocuments += 1
      }
      guard entry.status == .indexed else { continue }
      for page in entry.pages {
        if !page.documentText.isEmpty {
          append(
            entry: entry, pageIndex: page.pageIndex, source: .documentText,
            text: page.documentText)
        }
        if let recognized = page.recognizedText, !recognized.isEmpty {
          append(
            entry: entry, pageIndex: page.pageIndex, source: .recognizedOCRText,
            text: recognized)
        }
        for comment in page.comments {
          append(entry: entry, pageIndex: page.pageIndex, source: .comment, text: comment)
        }
        for value in page.formValues {
          append(entry: entry, pageIndex: page.pageIndex, source: .formValue, text: value)
        }
        for bookmark in page.bookmarks {
          append(entry: entry, pageIndex: page.pageIndex, source: .bookmark, text: bookmark)
        }
      }
      for value in entry.metadataValues {
        append(entry: entry, pageIndex: nil, source: .metadata, text: value)
      }
    }
    return SearchIndexSearchReport(
      query: trimmed, hits: hits, totalHits: totalHits,
      indexedDocuments: indexedDocuments, protectedDocuments: protectedDocuments,
      missingDocuments: missingDocuments, noContentDocuments: noContentDocuments,
      failedDocuments: failedDocuments)
  }

  // MARK: Persistence

  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded().write(to: url, options: .atomic)
  }

  public static func load(from url: URL) throws -> LocalSearchIndex {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return LocalSearchIndex()
    }
    return try LocalSearchIndex(data: try Data(contentsOf: url))
  }

  // MARK: Validation

  public func validate() throws {
    guard version == Self.currentVersion else {
      throw PDFError(
        .unsupported,
        "The full-text index version \(version) is not supported; rebuild the index")
    }
    try options.validate()
    guard locations.count <= options.maximumLocations else {
      throw PDFError(.limitExceeded, "The index has too many locations")
    }
    guard entries.count <= options.maximumIndexedDocuments else {
      throw PDFError(.limitExceeded, "The index has too many documents")
    }
    var locationPaths: Set<String> = []
    for location in locations {
      guard location.path.hasPrefix("/") else {
        throw PDFError(.malformed, "An index location must be absolute")
      }
      guard locationPaths.insert(location.path).inserted else {
        throw PDFError(.malformed, "Duplicate indexing location")
      }
    }
    var paths: Set<String> = []
    for entry in entries {
      guard entry.path.hasPrefix("/") else {
        throw PDFError(.malformed, "An indexed path must be absolute")
      }
      guard paths.insert(entry.path).inserted else {
        throw PDFError(.malformed, "Duplicate indexed path")
      }
      guard locations.contains(where: { $0.contains(entry.path) }) else {
        throw PDFError(.malformed, "An indexed path is outside the indexing locations")
      }
      guard entry.fileSize >= 0 else {
        throw PDFError(.malformed, "A negative file size is invalid")
      }
      guard entry.contentHash.count == 64 || entry.contentHash.isEmpty else {
        throw PDFError(.malformed, "The content hash is not a SHA-256 digest")
      }
      if entry.status == .protectedExcluded || entry.status == .missing
        || entry.status == .readFailed || entry.status == .unsupported
      {
        guard entry.pages.isEmpty && entry.metadataValues.isEmpty else {
          throw PDFError(
            .malformed,
            "A non-indexed document must not carry stored plaintext")
        }
      }
      if entry.status == .noSearchableContent || entry.status == .indexed {
        var indexes: Set<Int> = []
        for page in entry.pages {
          guard indexes.insert(page.pageIndex).inserted else {
            throw PDFError(.malformed, "Duplicate page index in the index")
          }
        }
      }
      if entry.status == .indexed {
        guard 0...100_000_000 ~= entry.pageCount else {
          throw PDFError(.malformed, "Invalid page count in the index")
        }
      }
    }
  }

  // MARK: Helpers

  static func enumeratePDFs(
    in location: SearchIndexLocation, maximum: Int, manager: FileManager
  ) throws -> [URL] {
    var options: FileManager.DirectoryEnumerationOptions = [
      .skipsHiddenFiles, .skipsPackageDescendants,
    ]
    if !location.includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
    guard let enumerator = manager.enumerator(
      at: location.url, includingPropertiesForKeys: [.isRegularFileKey],
      options: options, errorHandler: { _, _ in true })
    else { throw PDFError(.malformed, "An indexing location could not be enumerated") }
    var result: [URL] = []
    for case let url as URL in enumerator {
      guard url.pathExtension.lowercased() == "pdf" else { continue }
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      result.append(url)
      if result.count >= maximum { break }
    }
    return result
  }

  static func contentHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func failureEntry(
    path: String, fileSize: Int64, modificationTime: TimeInterval, hash: String,
    status: SearchIndexFileStatus, detail: String?
  ) -> SearchIndexEntry {
    SearchIndexEntry(
      path: path, fileSize: fileSize, modificationTime: modificationTime,
      contentHash: hash, status: status, pageCount: 0, pages: [],
      metadataValues: [], detail: detail)
  }

  static func makeEntry(
    path: String, fileSize: Int64, modificationTime: TimeInterval, hash: String,
    data: Data, options: SearchIndexOptions, limits: PDFLimits
  ) -> SearchIndexEntry {
    let parsed: ParsedPDF
    do {
      parsed = try PDFParser.parse(data, limits: limits)
    } catch let error as PDFError {
      switch error.kind {
      case .passwordRequired, .incorrectPassword:
        return failureEntry(
          path: path, fileSize: fileSize, modificationTime: modificationTime,
          hash: hash, status: .protectedExcluded,
          detail:
            "Encrypted or protected document excluded from the plaintext index; open "
            + "it in the app to search it.")
      case .unsupported:
        return failureEntry(
          path: path, fileSize: fileSize, modificationTime: modificationTime,
          hash: hash, status: .unsupported, detail: error.message)
      default:
        return failureEntry(
          path: path, fileSize: fileSize, modificationTime: modificationTime,
          hash: hash, status: .readFailed, detail: error.message)
      }
    } catch {
      return failureEntry(
        path: path, fileSize: fileSize, modificationTime: modificationTime,
        hash: hash, status: .readFailed, detail: error.localizedDescription)
    }

    var commentsByPage: [Int: [String]] = [:]
    if options.includeComments {
      for comment in CommentList.comments(in: parsed.graph, pageIDs: parsed.pageIDs) {
        let values = [comment.contents, comment.subject].compactMap { $0 }
        guard !values.isEmpty else { continue }
        commentsByPage[comment.pageIndex, default: []].append(contentsOf: values)
      }
    }
    var formsByPage: [Int: [String]] = [:]
    if options.includeFormValues {
      let fields = (try? FormInventory.fields(
        in: parsed.graph, pageIDs: parsed.pageIDs)) ?? []
      for field in fields {
        guard let value = field.stringValue, !value.isEmpty,
          let pageIndex = field.widgets.first?.pageIndex
        else { continue }
        formsByPage[pageIndex, default: []].append("\(field.name): \(value)")
      }
    }
    var bookmarksByPage: [Int: [String]] = [:]
    if options.includeBookmarks {
      for item in AdvancedSearch.flatten(PDFOutlineInventory.items(
        in: parsed.graph, pageIDs: parsed.pageIDs)) {
        guard let pageIndex = item.pageIndex, !item.title.isEmpty else { continue }
        bookmarksByPage[pageIndex, default: []].append(item.title)
      }
    }
    var metadataValues: [String] = []
    if options.includeMetadata {
      let metadata = PDFDocumentInventory.metadata(in: parsed.graph)
      metadataValues = [
        metadata.title, metadata.author, metadata.subject, metadata.keywords,
        metadata.creator, metadata.producer,
      ].compactMap { $0 }
    }

    var pages: [SearchIndexPage] = []
    var units = 0
    for (pageIndex, pageID) in parsed.pageIDs.enumerated() {
      var documentText = ""
      if let layout = try? PageTextLayout.build(
        pageID: pageID, in: parsed.graph, limits: limits)
      {
        documentText = AdvancedSearch.lineTexts(of: layout).joined(separator: "\n")
      }
      var recognizedText: String?
      if options.includeRecognizedOCRText {
        recognizedText = TextProvenance.recognizedLayerText(
          pageID: pageID, in: parsed.graph, limits: limits)
      }
      let comments = options.includeComments ? commentsByPage[pageIndex] ?? [] : []
      let formValues = options.includeFormValues ? formsByPage[pageIndex] ?? [] : []
      let bookmarks = options.includeBookmarks ? bookmarksByPage[pageIndex] ?? [] : []
      if !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        units += 1
      }
      if !(recognizedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        units += 1
      }
      units += comments.count + formValues.count + bookmarks.count
      pages.append(
        SearchIndexPage(
          pageIndex: pageIndex, documentText: documentText,
          recognizedText: recognizedText, comments: comments,
          formValues: formValues, bookmarks: bookmarks))
    }
    units += metadataValues.count
    guard units > 0 else {
      return failureEntry(
        path: path, fileSize: fileSize, modificationTime: modificationTime,
        hash: hash, status: .noSearchableContent,
        detail: "The document is readable but has no searchable content.")
    }
    return SearchIndexEntry(
      path: path, fileSize: fileSize, modificationTime: modificationTime,
      contentHash: hash, status: .indexed, pageCount: pages.count, pages: pages,
      metadataValues: metadataValues, detail: nil)
  }
}
