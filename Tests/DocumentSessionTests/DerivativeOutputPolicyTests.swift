import DocumentSession
import Foundation
import PDFCore
import Testing

/// SAF-03 evidence: every derivative writer rejects the open source as its
/// destination, including equivalent paths, symbolic links, and hard links.
@Suite("Derivative output policy")
struct DerivativeOutputPolicyTests {
  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-derivative-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func rejectsTheOpenSourceInEveryPathForm() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try Data("%PDF-1.7\n".utf8).write(to: source)

    #expect(throws: PDFError.self) {
      try DerivativeOutputPolicy.validateDestination(source, source: source)
    }
    #expect(throws: PDFError.self) {
      try DerivativeOutputPolicy.validateDestination(
        directory.appendingPathComponent("sub/../source.pdf"), source: source)
    }

    let symbolic = directory.appendingPathComponent("symbolic.pdf")
    try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
    #expect(throws: PDFError.self) {
      try DerivativeOutputPolicy.validateDestination(symbolic, source: source)
    }

    let hardLink = directory.appendingPathComponent("hard-link.pdf")
    try FileManager.default.linkItem(at: source, to: hardLink)
    #expect(throws: PDFError.self) {
      try DerivativeOutputPolicy.validateDestination(hardLink, source: source)
    }
  }

  @Test func acceptsADistinctPath() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try Data("%PDF-1.7\n".utf8).write(to: source)
    try DerivativeOutputPolicy.validateDestination(
      directory.appendingPathComponent("sanitized.pdf"), source: source)
  }

  @Test func unsignedSourceAllowsAnyDestination() throws {
    try DerivativeOutputPolicy.validateDestination(
      URL(fileURLWithPath: "/tmp/untitled.pdf"), source: nil)
  }
}
