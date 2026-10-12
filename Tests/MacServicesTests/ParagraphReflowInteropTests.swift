import Foundation
import PDFCore
import PDFEditing
import PDFKit
import Testing
@testable import MacServices

/// P19-007: a reflowed paragraph reopens in an independent reader with the
/// replacement text present and unrelated content intact.
@Suite("Paragraph reflow interop")
struct ParagraphReflowInteropTests {
  private func fixture() -> PDFGraph {
    let lines: [(String, Double, Double, Double)] = [
      ("Quarterly Report", 42, 700, 24),
      ("First body line of the report.", 42, 660, 12),
      ("Second body line follows here.", 42, 640, 12),
      ("Third body line ends the block.", 42, 620, 12),
      ("Page 1", 500, 60, 12),
    ]
    var content = Data()
    for line in lines {
      content.append(
        Data("BT /F1 \(line.3) Tf \(line.1) \(line.2) Td (\(line.0)) Tj ET\n".utf8))
    }
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func reflowedParagraphReopensInPDFKit() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidate = try #require(
      try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
        .first { $0.kind == .flowing })
    let replacement =
      "Reflowed paragraph text that wraps across several lines and reopens correctly in "
      + "an independent reader without disturbing the heading or the footer."
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(pageID: pageID, candidate: candidate, replacement: replacement)
      ]), to: graph)
    let data = try PDFWriter.write(edited)
    guard let document = PDFDocument(data: data), let string = document.string else {
      Issue.record("PDFKit could not open the reflowed document")
      return
    }
    #expect(string.contains("Reflowed paragraph text"))
    #expect(string.contains("independent reader"))
    #expect(string.contains("Quarterly Report"))
    #expect(string.contains("Page 1"))
    #expect(!string.contains("Second body line"))

    guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/qpdf") else { return }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-reflow-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qpdf")
    process.arguments = ["--check", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "qpdf: \(output)")
  }
}
