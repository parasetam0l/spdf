import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// Independent-implementation verification with qpdf, mupdf, and poppler
/// (development tools, never linked into the app): our encrypted output must
/// decrypt in another engine, our optimized/compressed output must pass their
/// checks, and their text extraction must match our fixtures. Tests skip
/// quietly when a tool is not installed.
@Suite("Independent tool verification")
struct IndependentToolTests {
  private static func locate(_ names: [String]) -> String? {
    for name in names {
      for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let path = "\(directory)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
      }
    }
    return nil
  }

  private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, output)
  }

  private func temporaryFile(_ name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
  }

  @Test func qpdfDecryptsOurEncryptedExport() throws {
    guard let qpdf = Self.locate(["qpdf"]), let pdftotext = Self.locate(["pdftotext"]) else {
      return
    }
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let data = try PDFWriter.write(
      graph, encryption: PDFEncryptionOptions(userPassword: "tool", ownerPassword: "owner"))
    let encryptedURL = temporaryFile("encrypted.pdf")
    let decryptedURL = temporaryFile("decrypted.pdf")
    defer {
      try? FileManager.default.removeItem(at: encryptedURL.deletingLastPathComponent())
    }
    try data.write(to: encryptedURL)

    let decrypt = try run(
      qpdf, ["--password=tool", "--decrypt", encryptedURL.path, decryptedURL.path])
    #expect(decrypt.status == 0, "qpdf: \(decrypt.output)")
    let check = try run(qpdf, ["--check", decryptedURL.path])
    #expect(check.status == 0 || check.status == 3, "qpdf --check: \(check.output)")
    let text = try run(pdftotext, [decryptedURL.path, "-"])
    #expect(text.status == 0)
    #expect(text.output.contains("sPDF Editor fixture - page 1"))
  }

  @Test func qpdfAndMutoolAcceptOurOptimizedOutput() throws {
    guard let qpdf = Self.locate(["qpdf"]), let mutool = Self.locate(["mutool"]) else { return }
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let (_, data, report) = try PDFOptimizer.lossless(parsed.graph)
    let url = temporaryFile("optimized.pdf")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try data.write(to: url)

    let check = try run(qpdf, ["--check", url.path])
    #expect(check.status == 0 || check.status == 3, "qpdf --check: \(check.output)")
    let info = try run(mutool, ["info", url.path])
    #expect(info.status == 0, "mutool info: \(info.output)")
    if report.usedCompressedOutput {
      // The compressed-object framing is exercised here as well.
      #expect(data.range(of: Data("/ObjStm".utf8)) != nil)
    }
  }

  @Test func popplerExtractsOurTextAndMutoolInspectsSignedOutput() throws {
    guard let pdftotext = Self.locate(["pdftotext"]), let mutool = Self.locate(["mutool"])
    else { return }
    let fixtureURL = temporaryFile("three-pages.pdf")
    defer { try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent()) }
    try PDFFixtures.threePages().write(to: fixtureURL)
    let text = try run(pdftotext, [fixtureURL.path, "-"])
    #expect(text.status == 0)
    #expect(text.output.contains("sPDF Editor fixture - page 2"))
    #expect(text.output.contains("Original Swift-generated content"))

    let signedURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Signed/signed-one-page.pdf")
    let info = try run(mutool, ["info", signedURL.path])
    #expect(info.status == 0, "mutool info: \(info.output)")
  }
}

extension IndependentToolTests {
  /// P09-028: independent readers accept stream output as well as classic
  /// output (classic acceptance is proven across the suite).
  @Test func independentReadersAcceptCompressedObjectOutput() throws {
    guard let qpdf = Self.locate(["qpdf"]) else { return }
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let compressed = try PDFWriter.writeCompressed(parsed.graph)
    let url = temporaryFile("compressed.pdf")
    defer {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    try compressed.write(to: url)
    let check = try run(qpdf, ["--check", url.path])
    #expect(check.status == 0 || check.status == 3, "qpdf --check: \(check.output)")
    #expect(
      check.output.contains("No syntax or stream encoding errors found"),
      "qpdf --check: \(check.output)")
  }
}
