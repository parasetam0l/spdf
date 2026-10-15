import Foundation
import PDFCore

/// P10-009/P10-010/P10-026: write verified output through a temporary file on
/// the destination filesystem, reparse and compare it against the edited
/// graph, and only then atomically replace the destination. A failed
/// verification or write never touches the existing document.
public enum VerifiedFileWriter {
  public static func write(
    _ bytes: Data, to destination: URL, expectedGraph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws {
    try write(bytes, to: destination) { data in
      let reparsed = try PDFParser.parse(data, limits: limits)
      // The writer derives /Size from the output cross-reference table. New
      // content can allocate objects without changing this cached trailer value;
      // incremental output may also retain freed object numbers. Match the
      // session's save verification while comparing every object and other key.
      var expected = expectedGraph
      expected.trailer[PDFName("Size")] = reparsed.graph.trailer[PDFName("Size")]
      guard reparsed.graph == expected else {
        throw PDFError(
          .malformed, "Temporary output failed verification against the edited graph")
      }
    }
  }

  /// Verification variant for output that cannot be reparsed without
  /// credentials (encrypted exports): the caller supplies the check.
  public static func write(
    _ bytes: Data, to destination: URL, verify: (Data) throws -> Void
  ) throws {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(destination.lastPathComponent).spdf-\(UUID().uuidString).tmp")
    do {
      try bytes.write(to: temporary, options: .atomic)
      try verify(try Data(contentsOf: temporary))
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

/// P10-012: a lightweight fingerprint of the source file, recorded at load
/// time so external modifications can be detected before overwriting.
public struct SourceFingerprint: Sendable, Equatable {
  public let size: Int64
  public let modified: Date

  public init(size: Int64, modified: Date) {
    self.size = size
    self.modified = modified
  }

  public static func capture(of url: URL) -> SourceFingerprint? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return SourceFingerprint(size: size.int64Value, modified: modified)
  }

  /// True when the file still matches this fingerprint; false when it was
  /// removed or changed externally.
  public func matches(_ url: URL) -> Bool {
    guard let current = SourceFingerprint.capture(of: url) else { return false }
    return current == self
  }
}
