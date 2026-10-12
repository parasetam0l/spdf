import Foundation
import PDFCore

/// AppKit may read NSDocuments concurrently; only this immutable-source store crosses threads.
public final class SourceStore: @unchecked Sendable {
  private let lock = NSLock()
  private var source: PDFSource?

  public init() {}

  public func load(_ data: Data) throws {
    let source = try PDFSource(data: data)
    lock.withLock { self.source = source }
  }

  public func snapshot() -> PDFSource? { lock.withLock { source } }

  public func originalBytes() throws -> Data {
    guard let source = snapshot() else {
      throw PDFError(.malformed, "No PDF source is loaded")
    }
    return PDFWriter.originalBytes(of: source)
  }
}

/// Serializes the initial inspection parser away from UI state.
public actor PDFInspector {
  public init() {}

  public func inspect(_ source: PDFSource) throws -> CoreInspection {
    let parsed = try PDFParser.parse(source.data)
    return CoreInspection(
      version: parsed.graph.version, objects: parsed.graph.objects.count, pages: parsed.pageCount)
  }
}

public struct CoreInspection: Equatable, Sendable {
  public let version: String
  public let objects: Int
  public let pages: Int
}
