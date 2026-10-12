import Foundation

/// PDF names and strings are byte sequences, not Swift Unicode strings.
public struct PDFName: Hashable, Sendable, Comparable {
  public let bytes: [UInt8]

  public init(bytes: [UInt8]) { self.bytes = bytes }
  public init(_ ascii: String) { bytes = Array(ascii.utf8) }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
  }
}

public struct PDFObjectID: Hashable, Sendable, Comparable {
  public let number: Int
  public let generation: Int

  public init(_ number: Int, generation: Int = 0) {
    self.number = number
    self.generation = generation
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.number, lhs.generation) < (rhs.number, rhs.generation)
  }
}

public struct PDFStream: Equatable, Sendable {
  public var dictionary: [PDFName: PDFValue]
  public var bytes: Data

  public init(dictionary: [PDFName: PDFValue] = [:], bytes: Data) {
    self.dictionary = dictionary
    self.bytes = bytes
  }
}

public indirect enum PDFValue: Equatable, Sendable {
  case null
  case boolean(Bool)
  case integer(Int64)
  case real(Double)
  case name(PDFName)
  case string(Data)
  case array([PDFValue])
  case dictionary([PDFName: PDFValue])
  case reference(PDFObjectID)
  case stream(PDFStream)
}

public struct PDFGraph: Equatable, Sendable {
  public var version: String
  public var objects: [PDFObjectID: PDFValue]
  public var trailer: [PDFName: PDFValue]

  public init(
    version: String = "1.7", objects: [PDFObjectID: PDFValue],
    trailer: [PDFName: PDFValue]
  ) {
    self.version = version
    self.objects = objects
    self.trailer = trailer
  }
}

extension PDFGraph {
  /// Validate references and the page tree without producing output. Editing
  /// layers call this on a staged graph before it may replace canonical state.
  public func validate(limits: PDFLimits = PDFLimits()) throws {
    try PDFGraphValidation.validateReferences(in: self, limits: limits)
    _ = try PDFGraphValidation.pages(in: self, limits: limits)
  }
}

/// P09-018: named save modes decided before any output bytes are produced.
public enum PDFSaveMode: String, Equatable, Sendable {
  /// Return the exact original source bytes for a truly unchanged document.
  case originalBytes
  /// Append a new revision to the saved file, retaining prior bytes.
  case incrementalUpdate
  /// Serialize a validated full rewrite of the current graph.
  case fullRewrite
}

public struct PDFSavePlan: Equatable, Sendable {
  public let mode: PDFSaveMode

  public init(mode: PDFSaveMode) {
    self.mode = mode
  }
}

public struct ParsedPDF: Sendable {
  public let source: Data
  public let graph: PDFGraph
  public let pageIDs: [PDFObjectID]
  /// P28-001: the standard security handler inventory when the source was
  /// encrypted (nil for unencrypted documents).
  public let encryption: PDFEncryptionInfo?
  /// Whether the supplied password authenticated as the owner password.
  public let encryptionIsOwner: Bool?
  /// P06-018/P06-019: how many revisions the parsed view covers (1 for a
  /// file without updates; fewer than the file's total for a prefix view).
  public let revisionCount: Int
  /// P04-017: recoverable compatibility notes collected while parsing.
  /// Corruption still throws; these never duplicate a thrown error.
  public let diagnostics: [PDFDiagnostic]
  /// P04-011: source spans for loaded objects, keyed by identity.
  public let spans: [PDFObjectID: PDFSourceSpan]
  /// P28-020: the authenticated decryption context, used to re-encrypt edits
  /// with the same protection without retaining the password.
  let decryptionContext: PDFDecryptionContext?

  public init(
    source: Data, graph: PDFGraph, pageIDs: [PDFObjectID],
    encryption: PDFEncryptionInfo? = nil, encryptionIsOwner: Bool? = nil,
    revisionCount: Int = 1, diagnostics: [PDFDiagnostic] = [],
    spans: [PDFObjectID: PDFSourceSpan] = [:]
  ) {
    self.init(
      source: source, graph: graph, pageIDs: pageIDs, encryption: encryption,
      encryptionIsOwner: encryptionIsOwner, decryptionContext: nil,
      revisionCount: revisionCount, diagnostics: diagnostics, spans: spans)
  }

  init(
    source: Data, graph: PDFGraph, pageIDs: [PDFObjectID],
    encryption: PDFEncryptionInfo?, encryptionIsOwner: Bool?,
    decryptionContext: PDFDecryptionContext?, revisionCount: Int = 1,
    diagnostics: [PDFDiagnostic] = [], spans: [PDFObjectID: PDFSourceSpan] = [:]
  ) {
    self.source = source
    self.graph = graph
    self.pageIDs = pageIDs
    self.encryption = encryption
    self.encryptionIsOwner = encryptionIsOwner
    self.decryptionContext = decryptionContext
    self.revisionCount = revisionCount
    self.diagnostics = diagnostics
    self.spans = spans
  }

  public var pageCount: Int { pageIDs.count }
}

public struct PDFLimits: Sendable {
  public let fileBytes: Int
  public let objects: Int
  public let nesting: Int
  public let tokenBytes: Int
  public let streamBytes: Int
  public let decodedBytes: Int

  public init(
    fileBytes: Int = 64 * 1_024 * 1_024, objects: Int = 100_000,
    nesting: Int = 64, tokenBytes: Int = 1_024 * 1_024,
    streamBytes: Int = 32 * 1_024 * 1_024, decodedBytes: Int = 64 * 1_024 * 1_024
  ) {
    self.fileBytes = max(0, fileBytes)
    self.objects = min(max(0, objects), Int.max - 1)
    self.nesting = min(max(0, nesting), 256)
    self.tokenBytes = max(0, tokenBytes)
    self.streamBytes = max(0, streamBytes)
    self.decodedBytes = max(0, decodedBytes)
  }
}

/// Messages contain structural context only, never document payloads.
/// P04-011: a byte range in the source file (end exclusive). Spans locate
/// objects, streams, and revisions for diagnostics and repair without
/// carrying any content.
public struct PDFSourceSpan: Sendable, Equatable {
  public let start: Int
  public let end: Int

  public init(start: Int, end: Int) {
    self.start = max(0, start)
    self.end = max(self.start, end)
  }

  public var length: Int { end - start }
}

/// P04-017/P04-018: a typed diagnostic. Severity separates fatal corruption
/// (thrown as `PDFError`) from recoverable compatibility notes (collected).
/// Context is identity plus spans only — diagnostics never carry document
/// content (P04-025).
public struct PDFDiagnostic: Sendable, Equatable {
  public enum Severity: String, Sendable, Equatable {
    case info
    case warning
    case error
  }

  public let severity: Severity
  /// The operation that produced this diagnostic ("parse", "repair", ...).
  public let operation: String
  public let object: PDFObjectID?
  public let span: PDFSourceSpan?
  public let message: String

  public init(
    severity: Severity, operation: String, object: PDFObjectID? = nil,
    span: PDFSourceSpan? = nil, message: String
  ) {
    self.severity = severity
    self.operation = operation
    self.object = object
    self.span = span
    self.message = message
  }
}

public struct PDFError: Error, LocalizedError, Equatable, Sendable {
  public enum Kind: String, Sendable {
    case malformed, unsupported, limitExceeded
    /// P28-015: the document is encrypted and no password was supplied.
    case passwordRequired
    /// P28-015: a password was supplied but does not match.
    case incorrectPassword
  }

  public let kind: Kind
  public let offset: Int?
  public let message: String

  public init(_ kind: Kind, _ message: String, offset: Int? = nil) {
    self.kind = kind
    self.offset = offset
    self.message = message
  }

  public var errorDescription: String? {
    if let offset { return "\(message) (byte \(offset))." }
    return "\(message)."
  }
}

/// An immutable original source; even unsupported PDFs can be copied unchanged.
public struct PDFSource: Sendable {
  public let data: Data

  public init(data: Data, maximumBytes: Int = 256 * 1_024 * 1_024) throws {
    guard data.count <= maximumBytes else {
      throw PDFError(.limitExceeded, "This file exceeds the current opening limit")
    }
    guard data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil else {
      throw PDFError(.malformed, "The file does not contain a PDF header")
    }
    self.data = data
  }
}
