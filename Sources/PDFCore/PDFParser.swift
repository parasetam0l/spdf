import Foundation

/// Owned-core profile: one PDF 1.x revision with classic cross-reference
/// tables or cross-reference streams, direct or indirect stream lengths,
/// object streams, and FlateDecode for structural streams. Predictors,
/// revision chains, hybrid references, and encryption are rejected
/// explicitly rather than recovered silently.
public enum PDFParser {
  /// The parsed file structure before any object graph is loaded.
  struct Structure {
    let version: String
    let bytes: [UInt8]
    let entries: [Int: XRefEntry]
    let trailer: [PDFName: PDFValue]
    let revisionCount: Int
  }

  /// Header, final cross-reference chain, and trailer. The structures read
  /// here are never encrypted, so this works for encrypted sources too.
  static func structure(
    _ data: Data, limits: PDFLimits, throughRevision: Int? = nil
  ) throws -> Structure {
    guard data.count <= limits.fileBytes else {
      throw PDFError(.limitExceeded, "PDF exceeds the core's configured file limit")
    }
    guard data.count >= 9, data.prefix(5) == Data("%PDF-".utf8) else {
      throw PDFError(.malformed, "Missing PDF header", offset: 0)
    }
    let version = String(decoding: data.dropFirst(5).prefix(3), as: UTF8.self)
    // The structural profile is PDF 1.x; PDF 2.0 headers are accepted for
    // reading because the supported structure is unchanged, with no PDF 2.0
    // feature claims.
    guard (0...7).map({ "1.\($0)" }).contains(version) || version == "2.0" else {
      throw PDFError(.unsupported, "The core currently supports PDF 1.x and 2.0 headers only")
    }
    let bytes = Array(data)
    guard ByteCursor.isWhitespace(bytes[8]) else {
      throw PDFError(.malformed, "Invalid PDF header boundary", offset: 8)
    }
    let searchStart = max(0, data.count - 1_024 * 1_024)
    guard
      let marker = data.range(
        of: Data("startxref".utf8), options: .backwards, in: searchStart..<data.count)
    else { throw PDFError(.malformed, "Missing final cross-reference pointer") }
    var end = try ByteCursor(bytes, offset: marker.upperBound)
    let xrefOffset = try end.integer()
    end.skipWhitespace()
    try end.consume("%%EOF")
    end.skipWhitespace()
    guard end.peek == nil else {
      throw PDFError(.unsupported, "Trailing data after the final EOF is not supported")
    }
    let chain = try PDFCrossReferenceChain.parse(
      in: bytes, startingAt: xrefOffset, limits: limits, throughRevision: throughRevision)
    return Structure(
      version: version, bytes: bytes, entries: chain.entries, trailer: chain.trailer,
      revisionCount: chain.revisionCount)
  }

  /// P28-001: read only the encryption inventory (trailer and /Encrypt), with
  /// no password and no object graph load. Returns nil for unencrypted files.
  /// This lets callers describe the protection before prompting.
  public static func encryptionInventory(
    _ data: Data, limits: PDFLimits = PDFLimits()
  ) throws -> PDFEncryptionInfo? {
    let structure = try structure(data, limits: limits)
    guard structure.trailer[PDFName("Encrypt")] != nil else { return nil }
    var cache: [PDFObjectID: PDFValue] = [:]
    var loader = PDFObjectLoader(
      bytes: structure.bytes, entries: structure.entries, limits: limits)
    return try PDFEncryptionInfo.parse(trailer: structure.trailer) { id in
      if let cached = cache[id] { return cached }
      let loaded = try loader.load(number: id.number)
      cache[loaded.id] = loaded.value
      return loaded.value
    }
  }

  public static func parse(
    _ data: Data, password: String? = nil, limits: PDFLimits = PDFLimits()
  ) throws -> ParsedPDF {
    try parse(data, password: password, decryptionOverride: nil, limits: limits)
  }

  /// P06-019: parse the document as of an older revision (1-based from the
  /// oldest), for signature and redaction inspection across updates. The
  /// returned graph, page list, and revision count describe that prefix of
  /// the revision chain; newer updates are invisible to the view.
  public static func parse(
    _ data: Data, throughRevision revision: Int, password: String? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> ParsedPDF {
    try parse(
      data, password: password, decryptionOverride: nil, limits: limits,
      throughRevision: revision)
  }

  /// Internal variant for callers that already hold an authenticated context
  /// (session re-saves verify their protected output without the password).
  static func parse(
    _ data: Data, decryptionContext: PDFDecryptionContext, limits: PDFLimits = PDFLimits()
  ) throws -> ParsedPDF {
    try parse(
      data, password: nil, decryptionOverride: decryptionContext, limits: limits)
  }

  /// P28-020/P28-023: authenticate and return the parsed graph together with
  /// the encryption state needed to save edits back with the same protection.
  /// The password itself is not retained anywhere.
  public static func unlock(
    _ data: Data, password: String, limits: PDFLimits = PDFLimits()
  ) throws -> PDFUnlockedDocument {
    let parsed = try parse(data, password: password, limits: limits)
    guard let info = parsed.encryption, let context = parsed.decryptionContext,
      let isOwner = parsed.encryptionIsOwner
    else {
      throw PDFError(.unsupported, "This document is not encrypted")
    }
    let encryptObjectID: PDFObjectID?
    if case .reference(let id)? = parsed.graph.trailer[PDFName("Encrypt")] {
      encryptObjectID = id
    } else {
      encryptObjectID = nil
    }
    return PDFUnlockedDocument(
      parsed: parsed,
      encryption: PDFEncryptionState(
        info: info, isOwner: isOwner, encryptObjectID: encryptObjectID, context: context))
  }

  private static func parse(
    _ data: Data, password: String?, decryptionOverride: PDFDecryptionContext?,
    limits: PDFLimits, throughRevision: Int? = nil
  ) throws -> ParsedPDF {
    try Task.checkCancellation()
    let structure = try structure(data, limits: limits, throughRevision: throughRevision)
    let bytes = structure.bytes
    let entries = structure.entries
    let trailer = structure.trailer

    // P28-005/P28-015: encrypted documents require an explicit password. The
    // encryption dictionary itself is never encrypted, so the inventory is
    // read first; unsupported profiles and public-key handlers refuse before
    // any password is tested.
    var decryptor = decryptionOverride
    var skipDecryption: Set<PDFObjectID> = []
    var encryptionInfo: PDFEncryptionInfo?
    var encryptionIsOwner: Bool?
    if trailer[PDFName("Encrypt")] != nil {
      if let override = decryptionOverride {
        encryptionInfo = override.info
        encryptionIsOwner = override.isOwner
      } else {
        guard let password else {
          throw PDFError(
            .passwordRequired, "This document is encrypted; a password is required")
        }
        var infoCache: [PDFObjectID: PDFValue] = [:]
        var infoLoader = PDFObjectLoader(bytes: bytes, entries: entries, limits: limits)
        let info = try PDFEncryptionInfo.parse(trailer: trailer) { id in
          if let cached = infoCache[id] { return cached }
          let loaded = try infoLoader.load(number: id.number)
          infoCache[loaded.id] = loaded.value
          return loaded.value
        }
        let security = PDFStandardSecurity(info: info)
        guard let authenticated = try security.authenticate(password: password) else {
          throw PDFError(.incorrectPassword, "The password is incorrect")
        }
        decryptor = PDFDecryptionContext(
          info: info, fileKey: authenticated.key, isOwner: authenticated.isOwner)
        encryptionInfo = info
        encryptionIsOwner = authenticated.isOwner
      }
      if case .reference(let encryptID)? = trailer[PDFName("Encrypt")] {
        skipDecryption.insert(encryptID)
      }
    } else if decryptionOverride != nil {
      throw PDFError(.unsupported, "The document is not encrypted")
    }
    guard case .integer(let size) = trailer[PDFName("Size")], size > 0,
      size <= Int64(limits.objects) + 1,
      Int64(entries.keys.max() ?? 0) < size,
      let freeZero = entries[0], case .free = freeZero
    else { throw PDFError(.malformed, "Invalid cross-reference size or free object zero") }

    var loader = PDFObjectLoader(
      bytes: bytes, entries: entries, limits: limits, decryptor: decryptor,
      skipDecryption: skipDecryption)
    var objects: [PDFObjectID: PDFValue] = [:]
    for number in entries.keys.sorted() {
      try Task.checkCancellation()
      guard number > 0 else { continue }
      if case .free = entries[number]! { continue }
      let (id, value) = try loader.load(number: number)
      objects[id] = value
    }
    let graph = PDFGraph(version: structure.version, objects: objects, trailer: trailer)
    try PDFGraphValidation.validateReferences(in: graph, limits: limits)
    let pages = try PDFGraphValidation.pages(in: graph, limits: limits)
    // P04-017: recoverable compatibility notes. Corruption throws above;
    // these describe accepted-but-noteworthy input without duplicating errors.
    var diagnostics: [PDFDiagnostic] = []
    if structure.version == "2.0" {
      diagnostics.append(
        PDFDiagnostic(
          severity: .info, operation: "parse",
          message: "PDF 2.0 header accepted for reading; no PDF 2.0 features are claimed."))
    }
    // Linearization hints are positional metadata; their presence is noted
    // and they are otherwise ignored (P06-020 stance). Only the first
    // objects are scanned: the hints conventionally open the file.
    for number in 1...16 {
      guard case .dictionary(let dictionary)? = objects[PDFObjectID(number)] else { continue }
      if dictionary[PDFName("Linearized")] != nil,
        let span = loader.spans[PDFObjectID(number)]
      {
        diagnostics.append(
          PDFDiagnostic(
            severity: .info, operation: "parse", object: PDFObjectID(number),
            span: span,
            message: "Linearization hints are present and ignored; the revision chain is authoritative."))
        break
      }
    }
    return ParsedPDF(
      source: data, graph: graph, pageIDs: pages, encryption: encryptionInfo,
      encryptionIsOwner: encryptionIsOwner, decryptionContext: decryptor,
      revisionCount: structure.revisionCount, diagnostics: diagnostics,
      spans: loader.spans)
  }

  /// Dispatch on the startxref target: a classic table or a cross-reference
  /// stream object.
  static func crossReference(
    in bytes: [UInt8], at offset: Int, limits: PDFLimits
  ) throws -> ([Int: XRefEntry], [PDFName: PDFValue]) {
    guard offset >= 0, offset < bytes.count else {
      throw PDFError(.malformed, "Cross-reference pointer is outside the file", offset: offset)
    }
    var cursor = try ByteCursor(bytes, offset: offset)
    if cursor.matches("xref") {
      try cursor.keyword("xref")
      var entries: [Int: XRefEntry] = [:]
      while true {
        try Task.checkCancellation()
        cursor.skipTrivia()
        if cursor.matches("trailer") { break }
        let first = try cursor.integer()
        let count = try cursor.integer()
        let (upper, overflow) = first.addingReportingOverflow(count)
        guard !overflow, count <= limits.objects - entries.count,
          upper <= limits.objects + 1
        else {
          throw PDFError(.limitExceeded, "Cross-reference range exceeds the configured limit")
        }
        for number in first..<upper {
          try Task.checkCancellation()
          let entryOffset = try cursor.integer()
          let generation = try cursor.integer()
          let flag = try cursor.word(maximum: 1)
          guard generation <= 65_535, flag == [110] || flag == [102],
            entries[number] == nil
          else {
            throw PDFError(
              .malformed, "Invalid or duplicate cross-reference entry", offset: cursor.offset)
          }
          entries[number] =
            flag == [110] ? .ordinary(offset: entryOffset, generation: generation) : .free
        }
      }
      try cursor.keyword("trailer")
      var trailerParser = PDFSyntaxParser(cursor: cursor, limits: limits)
      guard case .dictionary(let trailer) = try trailerParser.value() else {
        throw PDFError(.malformed, "Trailer is not a dictionary")
      }
      return (entries, trailer)
    }
    return try PDFXRefStream.parse(bytes: bytes, at: offset, limits: limits)
  }
}

/// Walks the revision chain reachable from the final startxref pointer.
/// Newest revisions take precedence: a replaced or deleted object in a newer
/// revision shadows every older definition, so free entries cannot
/// resurrect. Hybrid-reference tables merge their companion XRefStm stream
/// with documented precedence (XRefStm entries supplement free/absent table
/// entries; in-use entries must agree) and explicit conflict detection.
/// Chains are bounded by a revision count and cycle-checked offsets.
struct PDFCrossReferenceChain {
  static let maximumRevisions = 64

  let entries: [Int: XRefEntry]
  let trailer: [PDFName: PDFValue]
  let revisionCount: Int

  /// - Parameter throughRevision: when set, the view covers the oldest
  ///   `throughRevision` revisions (1-based from the oldest) instead of the
  ///   whole file. Revision 1 of an incremental file is the base document;
  ///   larger values add updates. Out-of-range values are refused.
  static func parse(
    in bytes: [UInt8], startingAt offset: Int, limits: PDFLimits,
    throughRevision: Int? = nil
  ) throws -> PDFCrossReferenceChain {
    // Newest-first sections; merged after the walk so a prefix view can be
    // built oldest-first with the same newest-wins precedence.
    var sections: [([Int: XRefEntry], [PDFName: PDFValue])] = []
    var visited: Set<Int> = []
    var next = offset
    var revisions = 0
    while true {
      try Task.checkCancellation()
      guard revisions < maximumRevisions else {
        throw PDFError(
          .limitExceeded, "Cross-reference revision chain exceeds the configured limit")
      }
      guard visited.insert(next).inserted else {
        throw PDFError(.malformed, "Cross-reference revision chain contains a cycle", offset: next)
      }
      var (sectionEntries, sectionTrailer) = try PDFParser.crossReference(
        in: bytes, at: next, limits: limits)
      // Hybrid-reference table: merge the companion cross-reference stream.
      if let xrefStmValue = sectionTrailer[PDFName("XRefStm")] {
        guard case .integer(let rawOffset) = xrefStmValue,
          let streamOffset = Int(exactly: rawOffset),
          streamOffset > 0, streamOffset < bytes.count
        else {
          throw PDFError(.malformed, "XRefStm pointer is invalid", offset: next)
        }
        guard visited.insert(streamOffset).inserted else {
          throw PDFError(
            .malformed, "Cross-reference revision chain contains a cycle", offset: streamOffset)
        }
        let (streamEntries, _) = try PDFXRefStream.parse(
          bytes: bytes, at: streamOffset, limits: limits)
        for (number, streamEntry) in streamEntries {
          if let tableEntry = sectionEntries[number], tableEntry != .free {
            guard tableEntry == streamEntry else {
              throw PDFError(
                .malformed, "Hybrid cross-reference entries conflict", offset: streamOffset)
            }
          } else {
            sectionEntries[number] = streamEntry
          }
        }
      }
      sections.append((sectionEntries, sectionTrailer))
      guard let prevValue = sectionTrailer[PDFName("Prev")] else { break }
      guard case .integer(let rawPrev) = prevValue, let prev = Int(exactly: rawPrev),
        prev > 0, prev < bytes.count
      else {
        throw PDFError(.malformed, "Previous cross-reference pointer is invalid", offset: next)
      }
      next = prev
      revisions += 1
    }
    let total = revisions + 1
    let depth = throughRevision ?? total
    guard depth >= 1, depth <= total else {
      throw PDFError(
        .malformed, "Revision \(throughRevision ?? 0) is beyond the \(total) revisions present")
    }
    // Oldest-first prefix; newest entries win, exactly as before.
    var merged: [Int: XRefEntry] = [:]
    for (sectionEntries, _) in sections.suffix(depth).reversed() {
      for (number, entry) in sectionEntries {
        merged[number] = entry
      }
    }
    var trailer = sections[sections.count - depth].1
    trailer.removeValue(forKey: PDFName("Prev"))
    trailer.removeValue(forKey: PDFName("XRefStm"))
    return PDFCrossReferenceChain(
      entries: merged, trailer: trailer, revisionCount: depth)
  }
}

/// A resolved cross-reference entry. Compressed entries have no generation;
/// PDF object streams only contain generation-zero objects.
enum XRefEntry: Equatable, Sendable {
  case free
  case ordinary(offset: Int, generation: Int)
  case compressed(stream: Int, index: Int)
}

/// Parsed object stream: the decoded bytes plus the object-number to
/// relative-offset table from its header. Values are parsed on demand.
struct PDFObjectStream {
  let decoded: [UInt8]
  let first: Int
  let order: [Int]
  let offsets: [Int: Int]

  init(decoded: [UInt8], dictionary: [PDFName: PDFValue], limits: PDFLimits) throws {
    guard case .integer(let rawCount)? = dictionary[PDFName("N")], rawCount >= 0,
      rawCount <= Int64(limits.objects),
      case .integer(let rawFirst)? = dictionary[PDFName("First")], rawFirst >= 0,
      rawFirst <= Int64(decoded.count)
    else {
      throw PDFError(.malformed, "Object stream header is invalid")
    }
    let count = Int(rawCount)
    let first = Int(rawFirst)
    var parser = PDFSyntaxParser(cursor: try ByteCursor(decoded), limits: limits)
    var order: [Int] = []
    var offsets: [Int: Int] = [:]
    for _ in 0..<count {
      try Task.checkCancellation()
      let number = try parser.cursor.integer()
      let relative = try parser.cursor.integer()
      guard number > 0, relative >= 0 else {
        throw PDFError(.malformed, "Object stream header pair is invalid")
      }
      let (absolute, overflow) = first.addingReportingOverflow(relative)
      guard !overflow, absolute <= decoded.count else {
        throw PDFError(.malformed, "Object stream entry is outside the decoded data")
      }
      guard offsets[number] == nil else {
        throw PDFError(.malformed, "Duplicate object inside an object stream")
      }
      order.append(number)
      offsets[number] = relative
    }
    guard parser.cursor.offset <= first else {
      throw PDFError(.malformed, "Object stream header overlaps its objects")
    }
    self.decoded = decoded
    self.first = first
    self.order = order
    self.offsets = offsets
  }

  func loadObject(number: Int, index: Int, limits: PDFLimits) throws
    -> (id: PDFObjectID, value: PDFValue)
  {
    guard index >= 0, index < order.count, order[index] == number else {
      throw PDFError(.malformed, "Object stream index does not match the compressed object")
    }
    guard let relative = offsets[number] else {
      throw PDFError(.malformed, "Compressed object is missing from its object stream")
    }
    let (absolute, overflow) = first.addingReportingOverflow(relative)
    guard !overflow, absolute <= decoded.count else {
      throw PDFError(.malformed, "Compressed object is outside its object stream")
    }
    var parser = PDFSyntaxParser(cursor: try ByteCursor(decoded, offset: absolute), limits: limits)
    let value = try parser.value()
    return (PDFObjectID(number, generation: 0), value)
  }
}

/// P04-013: bounded LRU object cache with explicit memory accounting.
/// Eviction only drops already-parsed values; the loader re-parses evicted
/// objects from source bytes on next access, so cached state never affects
/// resolution results. Sizes are estimates for budgeting, not exact
/// allocations: each value carries a 16-byte entry overhead plus its payload.
struct PDFObjectCache {
  /// Default budgets follow the parse limits, so in-limit documents keep the
  /// previous keep-everything behavior while pathological inputs stay bounded.
  let maxEntries: Int
  let maxBytes: Int
  private var entries: [Int: (id: PDFObjectID, value: PDFValue)] = [:]
  /// Access order, least-recently-used first.
  private var order: [Int] = []
  private(set) var bytes = 0
  private(set) var hits = 0
  private(set) var misses = 0
  private(set) var evictions = 0

  init(maxEntries: Int, maxBytes: Int) {
    self.maxEntries = max(1, maxEntries)
    self.maxBytes = max(0, maxBytes)
  }

  static func estimatedSize(of value: PDFValue) -> Int {
    estimatedSize(of: value, depth: 0)
  }

  private static func estimatedSize(of value: PDFValue, depth: Int) -> Int {
    guard depth <= 32 else { return 8 }
    switch value {
    case .null:
      return 16
    case .boolean:
      return 17
    case .integer, .real, .reference:
      return 24
    case .name(let name):
      return 16 + name.bytes.count
    case .string(let data):
      return 16 + data.count
    case .array(let items):
      return 16 + items.reduce(0) { $0 + estimatedSize(of: $1, depth: depth + 1) }
    case .dictionary(let dictionary):
      return 16
        + dictionary.reduce(0) {
          $0 + 16 + $1.key.bytes.count + estimatedSize(of: $1.value, depth: depth + 1)
        }
    case .stream(let stream):
      return 16 + stream.bytes.count
        + stream.dictionary.reduce(0) {
          $0 + 16 + $1.key.bytes.count + estimatedSize(of: $1.value, depth: depth + 1)
        }
    }
  }

  mutating func get(_ number: Int) -> (id: PDFObjectID, value: PDFValue)? {
    guard let entry = entries[number] else {
      misses += 1
      return nil
    }
    hits += 1
    if let index = order.firstIndex(of: number) {
      order.remove(at: index)
      order.append(number)
    }
    return entry
  }

  mutating func set(_ number: Int, entry: (id: PDFObjectID, value: PDFValue)) {
    if let old = entries[number] {
      bytes -= PDFObjectCache.estimatedSize(of: old.value)
      entries[number] = entry
      bytes += PDFObjectCache.estimatedSize(of: entry.value)
      if let index = order.firstIndex(of: number) {
        order.remove(at: index)
      }
      order.append(number)
    } else {
      entries[number] = entry
      bytes += PDFObjectCache.estimatedSize(of: entry.value)
      order.append(number)
    }
    evictIfNeeded()
  }

  private mutating func evictIfNeeded() {
    // The most recently stored entry is always retained, even when a single
    // entry alone exceeds the byte budget; the next insert evicts it first.
    while (entries.count > maxEntries || bytes > maxBytes), order.count > 1,
      let oldest = order.first
    {
      order.removeFirst()
      if let removed = entries.removeValue(forKey: oldest) {
        bytes = max(0, bytes - PDFObjectCache.estimatedSize(of: removed.value))
        evictions += 1
      }
    }
  }

  var count: Int { entries.count }
}

/// Loads objects by cross-reference entry, caching parsed values and
/// decoded object streams so one stream is decoded at most once per parse.
struct PDFObjectLoader {
  let bytes: [UInt8]
  let entries: [Int: XRefEntry]
  let limits: PDFLimits
  let decryptor: PDFDecryptionContext?
  let skipDecryption: Set<PDFObjectID>
  /// P04-013: bounded LRU cache with explicit accounting (see PDFObjectCache).
  private var cache: PDFObjectCache
  /// P04-011: source spans for successfully loaded objects.
  private(set) var spans: [PDFObjectID: PDFSourceSpan] = [:]
  private var objectStreams: [Int: PDFObjectStream] = [:]
  private var resolvingLengths: Set<Int> = []
  private(set) var objectStreamDecodeCount = 0

  init(
    bytes: [UInt8], entries: [Int: XRefEntry], limits: PDFLimits,
    decryptor: PDFDecryptionContext? = nil, skipDecryption: Set<PDFObjectID> = [],
    cacheEntries: Int? = nil, cacheBytes: Int? = nil
  ) {
    self.bytes = bytes
    self.entries = entries
    self.limits = limits
    self.decryptor = decryptor
    self.skipDecryption = skipDecryption
    self.cache = PDFObjectCache(
      maxEntries: cacheEntries ?? limits.objects,
      maxBytes: cacheBytes ?? limits.decodedBytes)
  }

  /// P04-013: current cache accounting for tests and benchmarks.
  var cacheStats: (entries: Int, bytes: Int, hits: Int, misses: Int, evictions: Int) {
    (cache.count, cache.bytes, cache.hits, cache.misses, cache.evictions)
  }

  mutating func load(number: Int) throws -> (id: PDFObjectID, value: PDFValue) {
    switch resolve(number: number) {
    case .resolved:
      // resolve caches every success, so the entry is present unless the
      // budget is smaller than a single entry; that degenerate case is
      // served straight from source without caching.
      if let cached = cache.get(number) { return cached }
      return try loadFresh(number: number)
    case .missing:
      throw PDFError(.malformed, "Object has no cross-reference entry")
    case .free:
      throw PDFError(.malformed, "Reference resolves to a free object")
    case .malformed(let message):
      throw PDFError(.malformed, message)
    case .unsupported(let message):
      throw PDFError(.unsupported, message)
    case .limit(let message):
      throw PDFError(.limitExceeded, message)
    }
  }

  /// P04-012: non-throwing object resolution distinguishing missing, free,
  /// malformed, and unsupported states. Successes share `load`'s cache.
  mutating func resolve(number: Int) -> ObjectResolution {
    if let cached = cache.get(number) { return .resolved(cached.value) }
    guard let entry = entries[number] else { return .missing }
    if case .free = entry { return .free }
    do {
      let loaded = try loadFresh(number: number)
      cache.set(number, entry: loaded)
      return .resolved(loaded.value)
    } catch let error as PDFError {
      switch error.kind {
      case .unsupported:
        return .unsupported(error.message)
      case .limitExceeded:
        return .limit(error.message)
      default:
        return .malformed(error.message)
      }
    } catch {
      return .malformed(String(describing: error))
    }
  }

  /// Parse one object from source bytes without consulting the cache.
  /// Evicted entries reload through this path, so cached state never
  /// affects resolution results.
  private mutating func loadFresh(number: Int) throws -> (id: PDFObjectID, value: PDFValue) {
    guard let entry = entries[number] else {
      throw PDFError(.malformed, "Object has no cross-reference entry")
    }
    switch entry {
    case .free:
      throw PDFError(.malformed, "Reference resolves to a free object")
    case .ordinary(let offset, let generation):
      let ordinary = try loadOrdinary(number: number, offset: offset, generation: generation)
      spans[ordinary.id] = PDFSourceSpan(start: offset, end: ordinary.end)
      return (ordinary.id, ordinary.value)
    case .compressed(let stream, let index):
      let objectStream = try loadObjectStream(number: stream)
      let loaded = try objectStream.loadObject(number: number, index: index, limits: limits)
      // A compressed object lives inside its stream's span when known.
      for (id, span) in spans where id.number == stream {
        spans[loaded.id] = span
        break
      }
      return loaded
    }
  }

  private mutating func loadOrdinary(number: Int, offset: Int, generation: Int) throws
    -> (id: PDFObjectID, value: PDFValue, end: Int)
  {
    guard offset > 0, offset < bytes.count else {
      throw PDFError(.malformed, "Object offset is outside the file", offset: offset)
    }
    var parser = PDFSyntaxParser(cursor: try ByteCursor(bytes, offset: offset), limits: limits)
    guard try parser.cursor.integer() == number,
      try parser.cursor.integer() == generation
    else {
      throw PDFError(
        .malformed, "Cross-reference identity does not match its object", offset: offset)
    }
    parser.cursor.skipTrivia()
    try parser.cursor.keyword("obj")
    var value = try parser.value()
    parser.cursor.skipTrivia()
    if parser.cursor.matches("stream") {
      guard case .dictionary(let dictionary) = value else {
        throw parser.error(.malformed, "Stream has no dictionary")
      }
      try parser.cursor.keyword("stream")
      if parser.cursor.peek == 13 { parser.cursor.offset += 1 }
      guard try parser.cursor.read() == 10 else {
        throw parser.error(.malformed, "Stream must begin with LF or CRLF")
      }
      let (streamDictionary, payload) = try streamPayload(
        dictionary: dictionary, start: parser.cursor.offset, parser: &parser)
      value = .stream(PDFStream(dictionary: streamDictionary, bytes: payload))
    }
    // P28-009/P28-012/P28-013: decrypt the object's strings and stream payload
    // with its own object key. The encryption dictionary is skipped, and
    // structures that are never encrypted (signature contents) are preserved.
    let id = PDFObjectID(number, generation: generation)
    if let decryptor, !skipDecryption.contains(id) {
      value = try decryptor.decryptObject(value, id: id)
    }
    parser.cursor.skipTrivia()
    try parser.cursor.keyword("endobj")
    return (id, value, parser.cursor.offset)
  }

  /// P05-019/P05-021: consume a stream payload using the declared /Length
  /// (direct or indirect) when it is valid; otherwise recover the payload
  /// with a bounded search for the first endstream/endobj boundary. The
  /// search window is limited to the configured stream limit plus a small
  /// slack, so malformed input cannot trigger unbounded scanning. A
  /// recovered payload replaces the invalid /Length with its actual size so
  /// the graph stays resolvable.
  private mutating func streamPayload(
    dictionary: [PDFName: PDFValue], start: Int, parser: inout PDFSyntaxParser
  ) throws -> (dictionary: [PDFName: PDFValue], payload: Data) {
    let declared: Int?
    do {
      declared = try streamLength(dictionary[PDFName("Length")], at: start)
    } catch is PDFError {
      declared = nil
    }
    if let declared {
      do {
        return (dictionary, try strictPayload(length: declared, start: start, parser: &parser))
      } catch is PDFError {
      }
    }
    let payload = try recoveredPayload(start: start, parser: &parser)
    var normalized = dictionary
    normalized[PDFName("Length")] = .integer(Int64(payload.count))
    return (normalized, payload)
  }

  private func strictPayload(length: Int, start: Int, parser: inout PDFSyntaxParser) throws -> Data {
    guard start >= 0, length >= 0, start <= bytes.count, length <= bytes.count - start else {
      throw PDFError(.malformed, "Stream length is outside the file", offset: start)
    }
    var probe = parser
    probe.cursor.offset = start + length
    probe.cursor.skipWhitespace()
    try probe.cursor.keyword("endstream")
    parser = probe
    return Data(bytes[start..<(start + length)])
  }

  private func recoveredPayload(start: Int, parser: inout PDFSyntaxParser) throws -> Data {
    let marker = Array("endstream".utf8)
    let window = min(bytes.count, start + limits.streamBytes + 64)
    var search = start
    var attempts = 0
    while search <= window - marker.count, attempts < 64 {
      try Task.checkCancellation()
      guard let found = firstMarker(marker, from: search, to: window) else { break }
      attempts += 1
      var end = found
      if end > start, bytes[end - 1] == 10 { end -= 1 }
      if end > start, bytes[end - 1] == 13 { end -= 1 }
      guard end - start <= limits.streamBytes else {
        throw PDFError(
          .limitExceeded, "Recovered stream exceeds the configured limit", offset: start)
      }
      var probe = parser
      probe.cursor.offset = found
      do {
        try probe.cursor.keyword("endstream")
        let afterMarker = probe.cursor.offset
        probe.cursor.skipTrivia()
        try probe.cursor.keyword("endobj")
        parser.cursor.offset = afterMarker
        return Data(bytes[start..<end])
      } catch is PDFError {
        search = found + marker.count
      }
    }
    throw PDFError(
      .malformed, "Stream length is invalid and no bounded endstream marker was found",
      offset: start)
  }

  private func firstMarker(_ marker: [UInt8], from: Int, to: Int) -> Int? {
    guard to - from >= marker.count else { return nil }
    for position in from...(to - marker.count) {
      if bytes[position] == marker[0],
        bytes[position..<(position + marker.count)].elementsEqual(marker)
      {
        return position
      }
    }
    return nil
  }

  private mutating func streamLength(_ value: PDFValue?, at objectOffset: Int) throws -> Int {
    guard let value else {
      throw PDFError(.malformed, "Stream has no length", offset: objectOffset)
    }
    switch value {
    case .integer(let raw):
      return try checkedLength(raw, at: objectOffset)
    case .reference(let id):
      guard resolvingLengths.insert(id.number).inserted else {
        throw PDFError(.malformed, "Circular stream-length reference")
      }
      defer { resolvingLengths.remove(id.number) }
      let (loadedID, lengthValue) = try load(number: id.number)
      guard loadedID == id else {
        throw PDFError(.malformed, "Stream length reference identity does not match")
      }
      guard case .integer(let raw) = lengthValue else {
        throw PDFError(.malformed, "Indirect stream length is not an integer")
      }
      return try checkedLength(raw, at: objectOffset)
    default:
      throw PDFError(.malformed, "Stream length is not an integer", offset: objectOffset)
    }
  }

  private func checkedLength(_ raw: Int64, at offset: Int) throws -> Int {
    guard raw >= 0, raw <= Int64(limits.streamBytes), let length = Int(exactly: raw) else {
      throw PDFError(.limitExceeded, "Invalid or excessive stream length", offset: offset)
    }
    return length
  }

  private mutating func loadObjectStream(number: Int) throws -> PDFObjectStream {
    if let cached = objectStreams[number] { return cached }
    guard let entry = entries[number], case .ordinary = entry else {
      throw PDFError(.malformed, "An object stream must be an ordinary indirect object")
    }
    let (_, value) = try load(number: number)
    guard case .stream(let stream) = value,
      stream.dictionary[PDFName("Type")] == .name(PDFName("ObjStm"))
    else {
      throw PDFError(.malformed, "Compressed objects must be stored in an object stream")
    }
    // /Extends describes a semantic collection, not inherited object bytes.
    // The xref entry still selects this stream's own object/index. Validate
    // collection references and cycles after loading the complete graph.
    let decoded = [UInt8](try PDFFilters.decoded(stream, limits: limits))
    let objectStream = try PDFObjectStream(
      decoded: decoded, dictionary: stream.dictionary, limits: limits)
    objectStreamDecodeCount += 1
    objectStreams[number] = objectStream
    return objectStream
  }
}

/// Cross-reference stream parsing: field widths, index ranges, and typed
/// entries per ISO 32000-1 7.5.8.
enum PDFXRefStream {
  static func parse(bytes: [UInt8], at offset: Int, limits: PDFLimits) throws
    -> ([Int: XRefEntry], [PDFName: PDFValue])
  {
    var parser = PDFSyntaxParser(cursor: try ByteCursor(bytes, offset: offset), limits: limits)
    _ = try parser.cursor.integer()
    _ = try parser.cursor.integer()
    parser.cursor.skipTrivia()
    try parser.cursor.keyword("obj")
    let value = try parser.value()
    parser.cursor.skipTrivia()
    guard case .dictionary(let dictionary) = value,
      dictionary[PDFName("Type")] == .name(PDFName("XRef")),
      parser.cursor.matches("stream")
    else {
      throw PDFError(
        .unsupported,
        "The cross-reference pointer does not lead to a classic table or a cross-reference stream",
        offset: offset)
    }
    guard case .integer(let rawLength)? = dictionary[PDFName("Length")] else {
      throw PDFError(
        .unsupported, "An indirect length on the cross-reference stream itself is not supported",
        offset: offset)
    }
    guard rawLength >= 0, rawLength <= Int64(limits.streamBytes),
      let length = Int(exactly: rawLength)
    else {
      throw PDFError(.limitExceeded, "Invalid cross-reference stream length", offset: offset)
    }
    try parser.cursor.keyword("stream")
    if parser.cursor.peek == 13 { parser.cursor.offset += 1 }
    guard try parser.cursor.read() == 10 else {
      throw parser.error(.malformed, "Stream must begin with LF or CRLF")
    }
    let payload = try parser.cursor.take(length)
    parser.cursor.skipWhitespace()
    try parser.cursor.keyword("endstream")
    parser.cursor.skipTrivia()
    try parser.cursor.keyword("endobj")
    let decoded = [UInt8](
      try PDFFilters.decoded(PDFStream(dictionary: dictionary, bytes: payload), limits: limits))

    guard case .integer(let rawSize)? = dictionary[PDFName("Size")], rawSize > 0,
      rawSize <= Int64(limits.objects) + 1
    else {
      throw PDFError(.malformed, "Cross-reference stream has an invalid Size")
    }
    let size = Int(rawSize)
    let widths = try fieldWidths(dictionary)
    let ranges = try indexRanges(dictionary, size: size, limits: limits)
    let entries = try entries(decoded: decoded, ranges: ranges, widths: widths)
    var trailer = dictionary
    for key in ["Type", "W", "Index", "Filter", "DecodeParms", "DP", "Length", "F", "DL"] {
      trailer.removeValue(forKey: PDFName(key))
    }
    return (entries, trailer)
  }

  /// P06-010: W is three field widths, each 0...8 bytes. A missing W
  /// defaults to [1 1 1].
  static func fieldWidths(_ dictionary: [PDFName: PDFValue]) throws -> (w1: Int, w2: Int, w3: Int)
  {
    guard let value = dictionary[PDFName("W")] else { return (1, 1, 1) }
    guard case .array(let fields) = value, fields.count == 3 else {
      throw PDFError(.malformed, "Cross-reference stream field widths must be a three-item array")
    }
    var widths: [Int] = []
    for field in fields {
      guard case .integer(let raw) = field, raw >= 0, raw <= 8 else {
        throw PDFError(.malformed, "Cross-reference stream field width is invalid")
      }
      widths.append(Int(raw))
    }
    let total = widths[0] + widths[1] + widths[2]
    guard total >= 1, total <= 24 else {
      throw PDFError(.malformed, "Cross-reference stream entry width is invalid")
    }
    return (widths[0], widths[1], widths[2])
  }

  /// P06-011: Index ranges default to [0 Size] and must stay within Size.
  static func indexRanges(
    _ dictionary: [PDFName: PDFValue], size: Int, limits: PDFLimits
  ) throws -> [Range<Int>] {
    guard let value = dictionary[PDFName("Index")] else { return [0..<size] }
    guard case .array(let fields) = value, !fields.isEmpty, fields.count % 2 == 0 else {
      throw PDFError(.malformed, "Cross-reference stream Index must be an even-sized array")
    }
    guard fields.count / 2 <= limits.objects else {
      throw PDFError(.limitExceeded, "Cross-reference stream Index exceeds the configured limit")
    }
    var ranges: [Range<Int>] = []
    var total = 0
    for pair in stride(from: 0, to: fields.count, by: 2) {
      guard case .integer(let rawFirst) = fields[pair],
        case .integer(let rawCount) = fields[pair + 1],
        rawFirst >= 0, rawCount >= 0,
        let first = Int(exactly: rawFirst), let count = Int(exactly: rawCount)
      else {
        throw PDFError(.malformed, "Cross-reference stream Index range is invalid")
      }
      let (upper, overflow) = first.addingReportingOverflow(count)
      guard !overflow, upper <= size else {
        throw PDFError(
          .malformed, "Cross-reference stream Index range is outside the declared Size")
      }
      total += count
      guard total <= limits.objects else {
        throw PDFError(.limitExceeded, "Cross-reference stream Index exceeds the configured limit")
      }
      ranges.append(first..<upper)
    }
    return ranges
  }

  /// P06-013: entries are typed 0 (free), 1 (ordinary), 2 (compressed).
  /// Reserved type values degrade to free entries as the specification allows.
  static func entries(decoded: [UInt8], ranges: [Range<Int>], widths: (w1: Int, w2: Int, w3: Int))
    throws -> [Int: XRefEntry]
  {
    let fieldBytes = widths.w1 + widths.w2 + widths.w3
    var entries: [Int: XRefEntry] = [:]
    var position = 0
    for range in ranges {
      for number in range {
        try Task.checkCancellation()
        guard position <= decoded.count, fieldBytes <= decoded.count - position else {
          throw PDFError(.malformed, "Cross-reference stream data is truncated")
        }
        let type = widths.w1 == 0 ? 1 : try read(decoded, position, widths.w1)
        let second = try read(decoded, position + widths.w1, widths.w2)
        let third = try read(decoded, position + widths.w1 + widths.w2, widths.w3)
        position += fieldBytes
        guard entries[number] == nil else {
          throw PDFError(.malformed, "Cross-reference stream contains duplicate entries")
        }
        entries[number] = try entry(type: type, second: second, third: third)
      }
    }
    return entries
  }

  static func read(_ bytes: [UInt8], _ start: Int, _ width: Int) throws -> Int {
    guard width >= 0, width <= 8 else {
      throw PDFError(.malformed, "Cross-reference stream field width is invalid")
    }
    var value = 0
    for index in 0..<width {
      value = (value << 8) | Int(bytes[start + index])
    }
    guard value >= 0 else {
      throw PDFError(.malformed, "Cross-reference field exceeds the supported integer range")
    }
    return value
  }

  static func entry(type: Int, second: Int, third: Int) throws -> XRefEntry {
    switch type {
    case 0:
      guard third <= 65_535 else {
        throw PDFError(.malformed, "Free cross-reference entry is invalid")
      }
      return .free
    case 1:
      guard second > 0, third <= 65_535 else {
        throw PDFError(.malformed, "Cross-reference stream entry is invalid")
      }
      return .ordinary(offset: second, generation: third)
    case 2:
      guard second > 0, third >= 0 else {
        throw PDFError(.malformed, "Compressed-object entry is invalid")
      }
      return .compressed(stream: second, index: third)
    default:
      return .free
    }
  }
}

enum PDFGraphValidation {
  static func validateReferences(in graph: PDFGraph, limits: PDFLimits) throws {
    func visit(_ value: PDFValue, depth: Int) throws {
      try Task.checkCancellation()
      guard depth <= limits.nesting else {
        throw PDFError(.limitExceeded, "Object graph exceeds the nesting limit")
      }
      switch value {
      case .reference(let id):
        guard graph.objects[id] != nil else {
          throw PDFError(.malformed, "Object graph contains an unresolved reference")
        }
      case .array(let values):
        for value in values { try visit(value, depth: depth + 1) }
      case .dictionary(let dictionary):
        for value in dictionary.values { try visit(value, depth: depth + 1) }
      case .stream(let stream): try visit(.dictionary(stream.dictionary), depth: depth + 1)
      default: break
      }
    }
    for value in graph.objects.values { try visit(value, depth: 0) }
    try visit(.dictionary(graph.trailer), depth: 0)
    try validateObjectStreamCollections(in: graph, limits: limits)
  }

  private static func validateObjectStreamCollections(in graph: PDFGraph, limits: PDFLimits) throws {
    var parents: [PDFObjectID: PDFObjectID] = [:]
    for (id, value) in graph.objects {
      guard case .stream(let stream) = value,
        stream.dictionary[PDFName("Type")] == .name(PDFName("ObjStm")),
        let extends = stream.dictionary[PDFName("Extends")] else { continue }
      guard case .reference(let parent) = extends,
        case .stream(let base)? = graph.objects[parent],
        base.dictionary[PDFName("Type")] == .name(PDFName("ObjStm")) else {
        throw PDFError(.malformed, "An object stream's Extends must reference another object stream")
      }
      parents[id] = parent
    }
    // Iterative and memoized: even a hostile collection cannot recurse or
    // repeatedly walk the same long suffix. Shared bases are valid.
    var depths: [PDFObjectID: Int] = [:]
    for start in parents.keys.sorted() {
      try Task.checkCancellation()
      var path: [PDFObjectID] = []
      var visited = Set<PDFObjectID>()
      var current = start
      while depths[current] == nil {
        guard visited.insert(current).inserted else {
          throw PDFError(.malformed, "Object stream collection contains a cycle")
        }
        guard path.count <= limits.nesting else {
          throw PDFError(.limitExceeded, "Object stream collection exceeds the nesting limit")
        }
        path.append(current)
        guard let parent = parents[current] else { depths[current] = 0; break }
        current = parent
      }
      var depth = depths[current]!
      for id in path.reversed() where depths[id] == nil {
        depth += 1
        guard depth <= limits.nesting else {
          throw PDFError(.limitExceeded, "Object stream collection exceeds the nesting limit")
        }
        depths[id] = depth
      }
    }
  }

  static func pages(in graph: PDFGraph, limits: PDFLimits) throws -> [PDFObjectID] {
    guard case .reference(let root) = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog) = graph.objects[root],
      catalog[PDFName("Type")] == .name(PDFName("Catalog")),
      case .reference(let pageRoot) = catalog[PDFName("Pages")]
    else { throw PDFError(.malformed, "Missing catalog or page-tree root") }
    var visited: Set<PDFObjectID> = []
    func walk(_ id: PDFObjectID, depth: Int) throws -> [PDFObjectID] {
      try Task.checkCancellation()
      guard depth <= limits.nesting, visited.count < limits.objects else {
        throw PDFError(.limitExceeded, "Page tree exceeds the configured limit")
      }
      guard visited.insert(id).inserted else {
        throw PDFError(.malformed, "Page tree contains a cycle or repeated page")
      }
      guard case .dictionary(let dictionary) = graph.objects[id] else {
        throw PDFError(.malformed, "Page-tree reference is not a dictionary")
      }
      if dictionary[PDFName("Type")] == .name(PDFName("Page")) { return [id] }
      guard dictionary[PDFName("Type")] == .name(PDFName("Pages")),
        case .array(let kids) = dictionary[PDFName("Kids")],
        case .integer(let expected) = dictionary[PDFName("Count")]
      else { throw PDFError(.malformed, "Invalid page-tree node") }
      var pages: [PDFObjectID] = []
      for kid in kids {
        guard case .reference(let child) = kid else {
          throw PDFError(.malformed, "Page-tree child is not an indirect reference")
        }
        pages += try walk(child, depth: depth + 1)
      }
      guard Int64(pages.count) == expected else {
        throw PDFError(.malformed, "Page-tree count does not match its children")
      }
      return pages
    }
    return try walk(pageRoot, depth: 0)
  }
}
