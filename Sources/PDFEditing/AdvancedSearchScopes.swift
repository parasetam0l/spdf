import Foundation
import PDFCore

// MARK: - Scope options

/// AUT-01: what a multi-document search may read. Page text is the primary
/// source; comments, form values, bookmarks and metadata are explicit opt-ins
/// so a search cannot accidentally expose data the caller did not ask for.
/// Recognized OCR text is searched as its own provenance when the page has a
/// generated layer.
public struct AdvancedSearchOptions: Sendable, Equatable {
  public var searchDocumentText: Bool
  public var includeRecognizedOCRText: Bool
  public var includeComments: Bool
  public var includeFormValues: Bool
  public var includeBookmarks: Bool
  public var includeMetadata: Bool
  public var textOptions: TextSearchOptions
  /// Context characters kept on each side of a hit (20...200).
  public var contextCharacters: Int
  /// Delivered hits per document; total hits are still counted.
  public var maximumResultsPerDocument: Int
  /// Documents considered by one folder/search request (1...500).
  public var maximumDocuments: Int
  public var includeSubfolders: Bool

  public init(
    searchDocumentText: Bool = true,
    includeRecognizedOCRText: Bool = true,
    includeComments: Bool = true,
    includeFormValues: Bool = true,
    includeBookmarks: Bool = true,
    includeMetadata: Bool = true,
    textOptions: TextSearchOptions = TextSearchOptions(),
    contextCharacters: Int = 60,
    maximumResultsPerDocument: Int = 200,
    maximumDocuments: Int = 200,
    includeSubfolders: Bool = true
  ) {
    self.searchDocumentText = searchDocumentText
    self.includeRecognizedOCRText = includeRecognizedOCRText
    self.includeComments = includeComments
    self.includeFormValues = includeFormValues
    self.includeBookmarks = includeBookmarks
    self.includeMetadata = includeMetadata
    self.textOptions = textOptions
    self.contextCharacters = contextCharacters
    self.maximumResultsPerDocument = maximumResultsPerDocument
    self.maximumDocuments = maximumDocuments
    self.includeSubfolders = includeSubfolders
  }

  public var includesAnyStructuredSource: Bool {
    includeComments || includeFormValues || includeBookmarks || includeMetadata
  }

  public func validate() throws {
    guard (20...200).contains(contextCharacters) else {
      throw PDFError(.malformed, "Search context must be 20...200 characters")
    }
    guard (1...1_000).contains(maximumResultsPerDocument) else {
      throw PDFError(.malformed, "The per-document result limit must be 1...1000")
    }
    guard (1...500).contains(maximumDocuments) else {
      throw PDFError(.malformed, "The document limit must be 1...500")
    }
    guard searchDocumentText || includeRecognizedOCRText || includesAnyStructuredSource
    else {
      throw PDFError(.malformed, "Enable at least one search source")
    }
  }
}

/// AUT-01: the provenance of one hit. documentText is text drawn by the
/// document; recognizedOCRText is a generated OCR layer's own text.
public enum SearchSource: String, Sendable, Codable, CaseIterable, Hashable {
  case documentText
  case recognizedOCRText
  case comment
  case formValue
  case bookmark
  case metadata

  public var title: String {
    switch self {
    case .documentText: return "Document text"
    case .recognizedOCRText: return "Recognized (OCR) text"
    case .comment: return "Comment"
    case .formValue: return "Form value"
    case .bookmark: return "Bookmark"
    case .metadata: return "Metadata"
    }
  }
}

/// AUT-01: why a file did or did not produce hits. A readable file with no
/// extractable content is distinct from a readable file with no matches.
public enum AdvancedSearchDocumentStatus: String, Sendable, Equatable {
  case searched
  /// Readable, but none of the selected sources yielded searchable content
  /// (for example an image-only scan without an OCR layer).
  case noSearchableContent
  /// Encrypted and not authenticated for this search; the file was not read.
  case passwordRequired
  /// A handler/profile this search does not open (for example public-key).
  case unsupported
  /// The bytes could not be read or parsed within the profile limits.
  case unreadable

  public var isSearchable: Bool { self == .searched || self == .noSearchableContent }

  public var title: String {
    switch self {
    case .searched: return "Searched"
    case .noSearchableContent: return "No searchable content"
    case .passwordRequired: return "Password required"
    case .unsupported: return "Unsupported security"
    case .unreadable: return "Unreadable"
    }
  }
}

/// AUT-01: one hit with file/page/context provenance. Text is withheld (nil)
/// when the document permissions deny copying and accessibility extraction;
/// the file and page are still identified so a permission-restricted result
/// is never confused with no match.
public struct AdvancedSearchHit: Sendable, Equatable, Identifiable {
  public let id: String
  public let source: SearchSource
  /// Zero-based page index; nil for document-level metadata.
  public let pageIndex: Int?
  public let pageLabel: String?
  public let context: String?
  public let matchedText: String?
  public let bounds: [[Double]]
  public let isPermissionRestricted: Bool

  public init(
    id: String, source: SearchSource, pageIndex: Int?, pageLabel: String?,
    context: String?, matchedText: String?, bounds: [[Double]],
    isPermissionRestricted: Bool
  ) {
    self.id = id
    self.source = source
    self.pageIndex = pageIndex
    self.pageLabel = pageLabel
    self.context = context
    self.matchedText = matchedText
    self.bounds = bounds
    self.isPermissionRestricted = isPermissionRestricted
  }
}

/// AUT-01: per-file outcome. The hits list is bounded; totalHits is the real
/// count.
public struct AdvancedSearchFileResult: Sendable, Equatable, Identifiable {
  public var id: String { url.path }
  public let url: URL
  public let displayName: String
  public let status: AdvancedSearchDocumentStatus
  public let statusDetail: String?
  public let permissionRestricted: Bool
  public let hits: [AdvancedSearchHit]
  public let totalHits: Int
  public let searchedSources: [SearchSource]

  public var hasMatches: Bool { totalHits > 0 }

  public init(
    url: URL, displayName: String, status: AdvancedSearchDocumentStatus,
    statusDetail: String?, permissionRestricted: Bool, hits: [AdvancedSearchHit],
    totalHits: Int, searchedSources: [SearchSource]
  ) {
    self.url = url
    self.displayName = displayName
    self.status = status
    self.statusDetail = statusDetail
    self.permissionRestricted = permissionRestricted
    self.hits = hits
    self.totalHits = totalHits
    self.searchedSources = searchedSources
  }

  public var summary: String {
    if totalHits > 0 {
      return "\(totalHits) \(totalHits == 1 ? "match" : "matches")"
    }
    if status != .searched { return status.title }
    return "No matches"
  }
}

/// AUT-01: the whole multi-document report. The counts keep "searched but no
/// match", "no searchable content", "password required" and "unsupported"
/// separate, which is the scope row acceptance distinction.
public struct AdvancedSearchReport: Sendable, Equatable {
  public let query: String
  public let files: [AdvancedSearchFileResult]
  public let skippedDocuments: Int

  public init(
    query: String, files: [AdvancedSearchFileResult], skippedDocuments: Int
  ) {
    self.query = query
    self.files = files
    self.skippedDocuments = skippedDocuments
  }

  public var totalHits: Int { files.reduce(0) { $0 + $1.totalHits } }
  public var filesWithHits: Int { files.filter(\.hasMatches).count }
  public var filesWithoutMatches: Int {
    files.filter { $0.status == .searched && !$0.hasMatches }.count
  }
  public var unsearchableFiles: Int {
    files.filter {
      $0.status == .passwordRequired || $0.status == .unsupported || $0.status == .unreadable
    }.count
  }
  public var noContentFiles: Int { files.filter { $0.status == .noSearchableContent }.count }
  public var permissionRestrictedFiles: Int { files.filter(\.permissionRestricted).count }

  public var summary: String {
    var parts = [
      "\(totalHits) \(totalHits == 1 ? "match" : "matches") in \(filesWithHits) of "
        + "\(files.count) \(files.count == 1 ? "document" : "documents")",
    ]
    if filesWithoutMatches > 0 {
      parts.append("\(filesWithoutMatches) searched with no match")
    }
    if noContentFiles > 0 { parts.append("\(noContentFiles) without searchable content") }
    if unsearchableFiles > 0 { parts.append("\(unsearchableFiles) unsearchable") }
    if permissionRestrictedFiles > 0 {
      parts.append("\(permissionRestrictedFiles) permission-restricted")
    }
    if skippedDocuments > 0 { parts.append("\(skippedDocuments) skipped") }
    return parts.joined(separator: "; ") + "."
  }

  public func results(for source: SearchSource) -> [AdvancedSearchFileResult] {
    files.filter { $0.searchedSources.contains(source) }
  }
}

/// AUT-01: an in-memory or on-disk document to search. The optional password
/// is used only to authenticate this call and is never retained in results.
public struct AdvancedSearchDocument: Sendable, Equatable {
  public let displayName: String
  public let url: URL
  public let data: Data
  public let password: String?

  public init(displayName: String, url: URL, data: Data, password: String? = nil) {
    self.displayName = displayName
    self.url = url
    self.data = data
    self.password = password
  }

  public static func file(_ url: URL, password: String? = nil) throws -> Self {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return Self(
      displayName: url.lastPathComponent, url: url, data: data, password: password)
  }
}

// MARK: - Search engine

/// AUT-01: multi-document/folder search. Per-file failures are reported in the
/// result list instead of aborting the whole scan; only invalid requests throw.
public enum AdvancedSearch {
  public static func search(
    query: String, documents: [AdvancedSearchDocument],
    options: AdvancedSearchOptions = AdvancedSearchOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> AdvancedSearchReport {
    try validate(query: query, options: options)
    var files: [AdvancedSearchFileResult] = []
    var skipped = 0
    for document in documents {
      if files.count >= options.maximumDocuments {
        skipped = documents.count - files.count
        break
      }
      files.append(evaluate(document: document, query: query, options: options, limits: limits))
    }
    return AdvancedSearchReport(query: query, files: files, skippedDocuments: skipped)
  }

  /// Search already-enumerated file URLs, reading each within the profile.
  public static func search(
    query: String, files: [URL],
    options: AdvancedSearchOptions = AdvancedSearchOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> AdvancedSearchReport {
    try validate(query: query, options: options)
    var results: [AdvancedSearchFileResult] = []
    var skipped = 0
    for url in files {
      if results.count >= options.maximumDocuments {
        skipped = files.count - results.count
        break
      }
      let document: AdvancedSearchDocument
      do {
        document = try AdvancedSearchDocument.file(url)
      } catch {
        results.append(
          AdvancedSearchFileResult(
            url: url, displayName: url.lastPathComponent, status: .unreadable,
            statusDetail: "The file could not be read: \(error.localizedDescription)",
            permissionRestricted: false, hits: [], totalHits: 0, searchedSources: []))
        continue
      }
      results.append(
        evaluate(document: document, query: query, options: options, limits: limits))
    }
    return AdvancedSearchReport(query: query, files: results, skippedDocuments: skipped)
  }

  /// Search a folder of PDFs (explicitly selected by the caller).
  public static func search(
    query: String, folder: URL,
    options: AdvancedSearchOptions = AdvancedSearchOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> AdvancedSearchReport {
    try validate(query: query, options: options)
    let files = try pdfFiles(
      in: folder, recursive: options.includeSubfolders,
      maximum: options.maximumDocuments + 1)
    return try search(query: query, files: files, options: options, limits: limits)
  }

  /// AUT-01: enumerate PDFs in an explicitly chosen folder. Hidden entries and
  /// package descendants are skipped; symbolic links are not followed.
  public static func pdfFiles(
    in folder: URL, recursive: Bool, maximum: Int
  ) throws -> [URL] {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw PDFError(.malformed, "The search folder does not exist") }
    var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
    if !recursive { options.insert(.skipsSubdirectoryDescendants) }
    guard let enumerator = manager.enumerator(
      at: folder, includingPropertiesForKeys: [.isRegularFileKey],
      options: options,
      errorHandler: { _, _ in true })
    else { throw PDFError(.malformed, "The search folder could not be enumerated") }
    var files: [URL] = []
    for case let url as URL in enumerator {
      guard url.pathExtension.lowercased() == "pdf" else { continue }
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      files.append(url)
      if files.count >= maximum { break }
    }
    return files.sorted { $0.path < $1.path }
  }

  public static func validate(query: String, options: AdvancedSearchOptions) throws {
    try options.validate()
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "Enter search text")
    }
  }

  // MARK: Per-document evaluation

  static func evaluate(
    document: AdvancedSearchDocument, query: String,
    options: AdvancedSearchOptions, limits: PDFLimits
  ) -> AdvancedSearchFileResult {
    func result(
      _ status: AdvancedSearchDocumentStatus, detail: String? = nil,
      restricted: Bool = false, hits: [AdvancedSearchHit] = [], total: Int = 0,
      sources: [SearchSource] = []
    ) -> AdvancedSearchFileResult {
      AdvancedSearchFileResult(
        url: document.url, displayName: document.displayName, status: status,
        statusDetail: detail, permissionRestricted: restricted, hits: hits,
        totalHits: total, searchedSources: sources)
    }
    guard document.data.count <= limits.fileBytes else {
      return result(.unreadable, detail: "The file exceeds the search size limit")
    }
    let parsed: ParsedPDF
    do {
      parsed = try PDFParser.parse(
        document.data, password: document.password, limits: limits)
    } catch let error as PDFError {
      switch error.kind {
      case .passwordRequired, .incorrectPassword:
        return result(
          .passwordRequired,
          detail: "Open this encrypted document with its password to search it.")
      case .unsupported:
        return result(.unsupported, detail: error.message)
      default:
        return result(.unreadable, detail: error.message)
      }
    } catch {
      return result(.unreadable, detail: error.localizedDescription)
    }
    let policy = PDFDocumentSecurityPolicy(parsed: parsed)
    let restricted = policy.isEncrypted && !policy.isOwner
      && !policy.allows(.copyContent) && !policy.allows(.extractForAccessibility)
    var hits: [AdvancedSearchHit] = []
    var totalHits = 0
    var sources: [SearchSource] = []
    var searchableUnits = 0
    func append(
      source: SearchSource, pageIndex: Int?, context: String?, matchedText: String?,
      bounds: [[Double]] = []
    ) {
      totalHits += 1
      guard hits.count < options.maximumResultsPerDocument else { return }
      let label = pageIndex.map { "Page \($0 + 1)" }
      hits.append(
        AdvancedSearchHit(
          id: "\(document.displayName)#p\(pageIndex.map { String($0) } ?? "doc")#"
            + "\(source.rawValue)#\(totalHits)",
          source: source, pageIndex: pageIndex, pageLabel: label,
          context: restricted ? nil : context,
          matchedText: restricted ? nil : matchedText,
          bounds: bounds, isPermissionRestricted: restricted))
    }
    func markSource(_ source: SearchSource) {
      if !sources.contains(source) { sources.append(source) }
    }

    if options.searchDocumentText {
      var foundDocumentText = false
      for (pageIndex, pageID) in parsed.pageIDs.enumerated() {
        guard let layout = try? PageTextLayout.build(
          pageID: pageID, in: parsed.graph, limits: limits)
        else { continue }
        let pageText = Self.lineTexts(of: layout)
        if pageText.contains(where: { !$0.isEmpty }) {
          searchableUnits += 1
          foundDocumentText = true
        }
        for match in TextSearch.search(query: query, in: layout, options: options.textOptions) {
          let snippet = Self.snippet(
            for: match, in: layout, contextCharacters: options.contextCharacters)
          append(
            source: .documentText, pageIndex: pageIndex,
            context: snippet?.context, matchedText: snippet?.text,
            bounds: match.bounds)
        }
      }
      if foundDocumentText { markSource(.documentText) }
    }

    if options.includeRecognizedOCRText {
      var foundOCR = false
      for (pageIndex, pageID) in parsed.pageIDs.enumerated() {
        guard let layerText = TextProvenance.recognizedLayerText(
          pageID: pageID, in: parsed.graph, limits: limits),
          !layerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { continue }
        searchableUnits += 1
        foundOCR = true
        for line in layerText.split(whereSeparator: \.isNewline) {
          let text = String(line)
          guard let match = Self.firstMatch(query: query, in: text, options: options.textOptions)
          else { continue }
          append(
            source: .recognizedOCRText, pageIndex: pageIndex,
            context: Self.snippet(
              text, match: match, contextCharacters: options.contextCharacters),
            matchedText: match.text)
        }
      }
      if foundOCR { markSource(.recognizedOCRText) }
    }

    if options.includeComments {
      var foundComment = false
      let comments = CommentList.comments(in: parsed.graph, pageIDs: parsed.pageIDs)
      for comment in comments {
        let values = [comment.contents, comment.subject].compactMap { $0 }
        guard !values.isEmpty else { continue }
        searchableUnits += 1
        foundComment = true
        for value in values {
          guard let match = Self.firstMatch(
            query: query, in: value, options: options.textOptions)
          else { continue }
          let author = comment.author.map { " by \($0)" } ?? ""
          append(
            source: .comment, pageIndex: comment.pageIndex,
            context: Self.snippet(
              value, match: match, contextCharacters: options.contextCharacters) + author,
            matchedText: match.text)
        }
      }
      if foundComment { markSource(.comment) }
    }

    if options.includeFormValues {
      let fields = (try? FormInventory.fields(in: parsed.graph, pageIDs: parsed.pageIDs)) ?? []
      var foundFieldValue = false
      for field in fields {
        guard let value = field.stringValue, !value.isEmpty else { continue }
        searchableUnits += 1
        foundFieldValue = true
        guard let match = Self.firstMatch(
          query: query, in: value, options: options.textOptions)
        else { continue }
        append(
          source: .formValue, pageIndex: field.widgets.first?.pageIndex,
          context: "\(field.name): "
            + Self.snippet(
              value, match: match, contextCharacters: options.contextCharacters),
          matchedText: match.text)
      }
      if foundFieldValue { markSource(.formValue) }
    }

    if options.includeBookmarks {
      var foundBookmark = false
      for item in Self.flatten(PDFOutlineInventory.items(
        in: parsed.graph, pageIDs: parsed.pageIDs)) {
        let title = item.title
        guard !title.isEmpty else { continue }
        searchableUnits += 1
        foundBookmark = true
        guard let match = Self.firstMatch(
          query: query, in: title, options: options.textOptions)
        else { continue }
        append(
          source: .bookmark, pageIndex: item.pageIndex,
          context: "Bookmark: "
            + Self.snippet(
              title, match: match, contextCharacters: options.contextCharacters),
          matchedText: match.text)
      }
      if foundBookmark { markSource(.bookmark) }
    }

    if options.includeMetadata {
      let metadata = PDFDocumentInventory.metadata(in: parsed.graph)
      var values: [(String, String)] = []
      func addMetadata(_ label: String, _ value: String?) {
        if let value { values.append((label, value)) }
      }
      addMetadata("Title", metadata.title)
      addMetadata("Author", metadata.author)
      addMetadata("Subject", metadata.subject)
      addMetadata("Keywords", metadata.keywords)
      addMetadata("Creator", metadata.creator)
      addMetadata("Producer", metadata.producer)
      var foundMetadata = false
      for (label, value) in values {
        searchableUnits += 1
        foundMetadata = true
        guard let match = Self.firstMatch(
          query: query, in: value, options: options.textOptions)
        else { continue }
        append(
          source: .metadata, pageIndex: nil,
          context: "\(label): "
            + Self.snippet(
              value, match: match, contextCharacters: options.contextCharacters),
          matchedText: match.text)
      }
      if foundMetadata { markSource(.metadata) }
    }

    if searchableUnits == 0 && totalHits == 0 {
      return result(
        .noSearchableContent,
        detail:
          "The document is readable but none of the selected sources contains "
            + "searchable content. A scanned page without an OCR layer is reported here, "
            + "not as a no-match.",
        restricted: restricted, hits: hits, total: totalHits, sources: sources)
    }
    return result(
      .searched,
      detail: restricted
        ? "Permissions deny copying and accessibility extraction; page and source are "
          + "identified but the matched text is withheld."
        : nil,
      restricted: restricted, hits: hits, total: totalHits, sources: sources)
  }

  // MARK: Text helpers

  /// Build per-line strings from a layout, preserving cluster order.
  static func lineTexts(of layout: PageTextLayout) -> [String] {
    layout.lines.map { line in
      line.map { layout.clusters[$0].text }.joined()
    }
  }

  struct MatchLocation {
    let text: String
    let context: String?
  }

  static func snippet(
    for match: TextMatch, in layout: PageTextLayout, contextCharacters: Int
  ) -> MatchLocation? {
    guard layout.lines.indices.contains(match.lineIndex) else { return nil }
    let line = layout.lines[match.lineIndex]
    var text = ""
    var offsets: [Int: Int] = [:]
    var start: Int?
    for clusterIndex in line {
      offsets[clusterIndex] = text.count
      if clusterIndex == match.clusterRange.lowerBound { start = text.count }
      text += layout.clusters[clusterIndex].text
    }
    let last = match.clusterRange.upperBound - 1
    guard let start, let lastOffset = offsets[last] else { return nil }
    let range = start..<(lastOffset + layout.clusters[last].text.count)
    let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
    let upper = text.index(text.startIndex, offsetBy: range.upperBound)
    return MatchLocation(
      text: String(text[lower..<upper]),
      context: contextSnippet(
        text, range: range, contextCharacters: contextCharacters))
  }

  struct TextMatchLocation {
    let text: String
    let range: Range<Int>
  }

  /// Find the first option-aware match in a plain string. Whole-word is not
  /// applied here (it needs layout words); the layout path handles it.
  static func firstMatch(
    query: String, in text: String, options: TextSearchOptions
  ) -> TextMatchLocation? {
    var compareOptions: String.CompareOptions = []
    if !options.caseSensitive { compareOptions.insert(.caseInsensitive) }
    if options.diacriticInsensitive { compareOptions.insert(.diacriticInsensitive) }
    guard let range = text.range(of: query, options: compareOptions) else { return nil }
    let lower = text.distance(from: text.startIndex, to: range.lowerBound)
    let upper = text.distance(from: text.startIndex, to: range.upperBound)
    return TextMatchLocation(text: String(text[range]), range: lower..<upper)
  }

  static func snippet(
    _ text: String, match: TextMatchLocation, contextCharacters: Int
  ) -> String {
    contextSnippet(text, range: match.range, contextCharacters: contextCharacters)
  }

  static func contextSnippet(
    _ text: String, range: Range<Int>, contextCharacters: Int
  ) -> String {
    guard !text.isEmpty, range.lowerBound >= 0, range.upperBound <= text.count else {
      return text
    }
    let lower = max(0, range.lowerBound - contextCharacters)
    let upper = min(text.count, range.upperBound + contextCharacters)
    let start = text.index(text.startIndex, offsetBy: lower)
    let end = text.index(text.startIndex, offsetBy: upper)
    var snippet = String(text[start..<end])
    if lower > 0 { snippet = "..." + snippet }
    if upper < text.count { snippet += "..." }
    return snippet
  }

  static func flatten(_ items: [PDFOutlineItem]) -> [PDFOutlineItem] {
    var result: [PDFOutlineItem] = []
    func walk(_ nodes: [PDFOutlineItem], depth: Int) {
      guard depth < 16 else { return }
      for node in nodes {
        result.append(node)
        walk(node.children, depth: depth + 1)
      }
    }
    walk(items, depth: 0)
    return result
  }
}
