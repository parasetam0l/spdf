import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P35-001–P35-007/P35-023: ZIP packaging with system DEFLATE, deterministic
/// parts, XML escaping, the DOCX package structure, and the no-macros policy.
@Suite("DOCX packaging")
struct DOCXPackageTests {
  private func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-docx-\(UUID().uuidString)-\(name)")
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  /// Extract an archive with the system unzip into a fresh directory and read
  /// entries as bytes (pipes corrupt binary data through text decoding).
  private func extract(_ archive: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-docx-extract-\(UUID().uuidString)")
    let result = try run("/usr/bin/unzip", ["-q", "-o", archive.path, "-d", directory.path])
    #expect(result.status == 0, "unzip: \(result.output)")
    return directory
  }

  @Test func zipWriterRoundTripsThroughIndependentUnzip() throws {
    let text = Data(String(repeating: "compressible text line\n", count: 200).utf8)
    let binary = Data((0..<512).map { UInt8(($0 &* 31) & 0xFF) })
    var zip = ZIPArchiveWriter()
    try zip.add(name: "hello.txt", data: text)
    try zip.add(name: "data/binary.bin", data: binary)
    try zip.add(name: "empty.txt", data: Data())
    let archive = try zip.archive()
    let url = tempFile("roundtrip.zip")
    defer { try? FileManager.default.removeItem(at: url) }
    try archive.write(to: url)

    let test = try run("/usr/bin/unzip", ["-t", url.path])
    #expect(test.status == 0, "unzip -t: \(test.output)")
    let directory = try extract(url)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try Data(contentsOf: directory.appendingPathComponent("hello.txt")) == text)
    #expect(
      try Data(contentsOf: directory.appendingPathComponent("data/binary.bin")) == binary)
    // The compressible entry is deflated (smaller than the input).
    #expect(archive.count < text.count)
  }

  @Test func zipLimitsAreEnforced() throws {
    var small = ZIPArchiveWriter(
      limits: ZIPArchiveWriter.Limits(maxEntries: 2, maxEntryBytes: 8, maxTotalBytes: 12))
    try small.add(name: "a", data: Data([1, 2, 3]))
    try small.add(name: "b", data: Data([4, 5]))
    #expect(throws: PDFError.self) { try small.add(name: "c", data: Data([6])) }
    var bytes = ZIPArchiveWriter(
      limits: ZIPArchiveWriter.Limits(maxEntries: 4, maxEntryBytes: 8, maxTotalBytes: 64))
    #expect(throws: PDFError.self) {
      try bytes.add(name: "big", data: Data(repeating: 0, count: 9))
    }
    #expect(throws: PDFError.self) { try bytes.add(name: "../evil", data: Data([1])) }
    #expect(throws: PDFError.self) { try bytes.add(name: "/absolute", data: Data([1])) }
  }

  @Test func archiveBytesAreDeterministic() throws {
    func archive() throws -> Data {
      var zip = ZIPArchiveWriter()
      try zip.add(name: "a.xml", data: Data("<a>1</a>".utf8))
      try zip.add(name: "b.txt", data: Data("text".utf8))
      return try zip.archive()
    }
    #expect(try archive() == (try archive()))
  }

  @Test func xmlEscapingStripsInvalidCharacters() {
    #expect(DOCXXML.escape("<script>alert(1)</script> & \"quoted\" 'single'")
      == "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quoted&quot; &#39;single&#39;")
    #expect(DOCXXML.escape("line\u{0007}break\nkept") == "linebreak\nkept")
    #expect(DOCXXML.escape("tab\there") == "tab\there")
  }

  @Test func docxPackageContainsRequiredPartsAndNoMacros() throws {
    let paragraphs = [
      DOCXParagraphInput(text: "Quarterly Report", style: .heading(level: 1)),
      DOCXParagraphInput(text: "First body line."),
      DOCXParagraphInput(text: "Second line with <markup> & quotes \"x\"."),
    ]
    let data = try DOCXExport.package(
      paragraphs: paragraphs, options: DOCXExportOptions(title: "Report"))
    let url = tempFile("package.docx")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)

    let listing = try run("/usr/bin/unzip", ["-l", url.path])
    #expect(listing.status == 0)
    for part in DOCXExport.emittedParts {
      #expect(listing.output.contains(part), "missing \(part)")
    }
    let directory = try extract(url)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lowered = listing.output.lowercased()
    #expect(!lowered.contains("vba"))
    #expect(!lowered.contains("macro"))
    #expect(!lowered.contains(".bin"))

    // XML parts parse and the document maps headings and escaped text.
    let contentTypes = try Data(
      contentsOf: directory.appendingPathComponent(DOCXExport.contentTypesPart))
    #expect(try XMLDocument(data: contentTypes) != nil)
    let documentXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(documentXML.contains("<w:pStyle w:val=\"Heading1\"/>"))
    #expect(documentXML.contains("Quarterly Report"))
    #expect(documentXML.contains("&lt;markup&gt; &amp; quotes &quot;x&quot;"))
    #expect(!documentXML.contains("<markup>"))
    _ = try XMLDocument(data: Data(documentXML.utf8))
    let stylesXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.stylesPart)),
      as: UTF8.self)
    #expect(stylesXML.contains("Heading1"))
    let relationships = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.packageRelationshipsPart)),
      as: UTF8.self)
    #expect(relationships.contains("word/document.xml"))
    // Deterministic package bytes.
    #expect(try DOCXExport.package(paragraphs: paragraphs, options: DOCXExportOptions(title: "Report")) == data)
  }

  @Test func independentConsumerReadsTheDocument() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") else { return }
    let paragraphs = [
      DOCXParagraphInput(text: "Quarterly Report", style: .heading(level: 1)),
      DOCXParagraphInput(text: "First body line of the report."),
      DOCXParagraphInput(text: "Second line ends the block."),
    ]
    let data = try DOCXExport.package(paragraphs: paragraphs)
    let url = tempFile("consumer.docx")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let converted = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
    #expect(converted.status == 0, "textutil: \(converted.output)")
    #expect(converted.output.contains("Quarterly Report"))
    #expect(converted.output.contains("First body line of the report."))
    #expect(converted.output.contains("Second line ends the block."))
  }

  @Test func exportModesAreExplicit() {
    #expect(DOCXExportMode.editable.rawValue == "editable")
    #expect(DOCXExportMode.appearance.rawValue == "appearance")
    #expect(DOCXExportOptions().mode == .editable)
  }
}
