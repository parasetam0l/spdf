import Foundation
import PDFCore
@testable import DocumentSession
import PDFFixtures
import Testing

/// P10-009/P10-010/P10-012/P10-026 evidence: verified temporary writes that
/// never touch the destination on failure, and external-modification
/// detection through source fingerprints.
@Suite("Verified saves")
struct VerifiedFileWriterTests {
  @Test func verifiedWriteReplacesAtomicallyAndCleansUp() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("document.pdf")
    try PDFFixtures.onePage().write(to: destination)
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    try VerifiedFileWriter.write(
      PDFFixtures.threePages(), to: destination, expectedGraph: parsed.graph)
    let reread = try PDFParser.parse(try Data(contentsOf: destination))
    #expect(reread.pageCount == 3)
    // No temporary files remain.
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents == ["document.pdf"])
  }

  @Test func failedVerificationLeavesTheOriginalUntouched() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("document.pdf")
    let original = try PDFFixtures.onePage()
    try original.write(to: destination)
    let other = try PDFParser.parse(PDFFixtures.threePages())
    // The bytes do not match the expected graph: the write must refuse and
    // leave the original file byte-identical (P10-026).
    #expect(throws: PDFError.self) {
      try VerifiedFileWriter.write(original, to: destination, expectedGraph: other.graph)
    }
    #expect(try Data(contentsOf: destination) == original)
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(contents == ["document.pdf"])
  }

  @Test func missingDestinationDirectoryFailsWithoutSideEffects() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("missing/document.pdf")
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    #expect(throws: (any Error).self) {
      try VerifiedFileWriter.write(
        PDFFixtures.onePage(), to: destination, expectedGraph: parsed.graph)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func fingerprintDetectsExternalChanges() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("source.pdf")
    try PDFFixtures.onePage().write(to: url)
    let fingerprint = try #require(SourceFingerprint.capture(of: url))
    #expect(fingerprint.matches(url))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    #expect(!fingerprint.matches(url))
    try FileManager.default.removeItem(at: url)
    #expect(!fingerprint.matches(url))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "spdf-verified-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
