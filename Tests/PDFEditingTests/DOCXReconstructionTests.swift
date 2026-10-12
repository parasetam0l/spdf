import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P35-008–P35-013/P35-024: PDF→DOCX content mapping (paragraphs, inline
/// runs, headings, lists, geometry, page breaks), XML mapping of alignment and
/// spacing, and source preservation.
@Suite("DOCX reconstruction")
struct DOCXReconstructionTests {
  private func fixture() -> PDFGraph {
    var pageOne = Data()
    pageOne.append(Data("BT /F1 24 Tf 42 710 Td (Quarterly Report) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 670 Td (Plain intro ) Tj /F2 12 Tf 1 0 0 rg (bold part) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 620 Td (Body line one) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 600 Td (Body line two) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 560 Td (- First bullet) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 540 Td (- Second bullet) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 500 Td (1. Alpha) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 480 Td (2. Beta) Tj ET\n".utf8))
    var pageTwo = Data()
    pageTwo.append(Data("BT /F1 12 Tf 42 500 Td (Second page text) Tj ET\n".utf8))
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(8): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica-Bold")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([
              PDFName("F1"): .reference(PDFObjectID(3)),
              PDFName("F2"): .reference(PDFObjectID(8)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: pageOne)),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(792), .integer(612),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: pageTwo)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
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

  @Test func reconstructionMapsStructureRunsAndGeometry() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)

    // Geometry comes from the first page; the different second page is noted.
    #expect(reconstruction.pageWidth == 612)
    #expect(reconstruction.pageHeight == 792)
    #expect(!reconstruction.landscape)
    #expect(reconstruction.limitations.contains { $0.contains("different sizes") })

    // A deliberate page break separates the pages.
    #expect(reconstruction.blocks.filter { $0.kind == .pageBreak }.count == 1)

    // The heading maps with its level (24 pt versus 12 pt body).
    let heading = try #require(reconstruction.blocks.first { block in
      if case .heading = block.kind { return true } else { return false }
    })
    if case .heading(let level) = heading.kind { #expect(level == 1) }
    #expect(heading.text.contains("Quarterly Report"))

    // Inline runs keep bold and color.
    let intro = try #require(reconstruction.blocks.first { $0.text.contains("Plain intro") })
    #expect(intro.runs.count == 2)
    #expect(intro.runs[0].bold == false)
    #expect(intro.runs[1].bold == true)
    #expect(intro.runs[1].colorHex == "FF0000")
    #expect(intro.runs[1].text.contains("bold part"))

    // Bullet and numbered lists map with markers stripped.
    let bullets = reconstruction.blocks.filter { block in
      if case .listItem(_, let ordered) = block.kind { return !ordered } else { return false }
    }
    #expect(bullets.map(\.text) == ["First bullet", "Second bullet"])
    let numbered = reconstruction.blocks.filter { block in
      if case .listItem(_, let ordered) = block.kind { return ordered } else { return false }
    }
    #expect(numbered.map(\.text) == ["Alpha", "Beta"])

    // Page two's paragraph is present after the break.
    #expect(reconstruction.blocks.contains { $0.text.contains("Second page text") })
  }

  @Test func alignmentIndentAndSpacingMapToWordprocessingML() throws {
    let centered = DOCXExport.blockXML(
      DOCXBlock(
        kind: .paragraph, runs: [DOCXRunInput(text: "Centered")], alignment: .center,
        firstLineIndent: 24, lineSpacing: 18))
    #expect(centered.contains("<w:jc w:val=\"center\"/>"))
    #expect(centered.contains("<w:ind w:firstLine=\"480\"/>"))
    #expect(centered.contains("<w:spacing w:line=\"360\" w:lineRule=\"exact\"/>"))
    let right = DOCXExport.blockXML(
      DOCXBlock(kind: .paragraph, runs: [DOCXRunInput(text: "Right")], alignment: .right))
    #expect(right.contains("<w:jc w:val=\"right\"/>"))
    let list = DOCXExport.blockXML(
      DOCXBlock(kind: .listItem(level: 0, ordered: true), runs: [DOCXRunInput(text: "Item")]))
    #expect(list.contains("<w:numPr>"))
    #expect(list.contains("<w:numId w:val=\"2\"/>"))
    let breakXML = DOCXExport.blockXML(DOCXBlock(kind: .pageBreak, runs: []))
    #expect(breakXML.contains("<w:br w:type=\"page\"/>"))
  }

  @Test func mappedDocumentReopensInAnIndependentConsumer() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") else { return }
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-mapped-\(UUID().uuidString).docx")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)

    // Package structure: numbering part plus the standard parts.
    let listing = try run("/usr/bin/unzip", ["-l", url.path])
    #expect(listing.status == 0)
    for part in DOCXExport.emittedParts {
      #expect(listing.output.contains(part), "missing \(part)")
    }
    // Extract and check the document XML.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-mapped-extract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", directory.path])
    let documentXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(documentXML.contains("<w:pStyle w:val=\"Heading1\"/>"))
    #expect(documentXML.contains("<w:b/>"))
    #expect(documentXML.contains("<w:color w:val=\"FF0000\"/>"))
    #expect(documentXML.contains("<w:br w:type=\"page\"/>"))
    #expect(documentXML.contains("<w:numId w:val=\"1\"/>"))
    _ = try XMLDocument(data: Data(documentXML.utf8))
    let numberingXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.numberingPart)),
      as: UTF8.self)
    #expect(numberingXML.contains("bullet"))
    #expect(numberingXML.contains("decimal"))

    // The independent consumer reads the reconstructed text.
    let converted = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
    #expect(converted.status == 0, "textutil: \(converted.output)")
    #expect(converted.output.contains("Quarterly Report"))
    #expect(converted.output.contains("bold part"))
    #expect(converted.output.contains("First bullet"))
    #expect(converted.output.contains("Alpha"))
    #expect(converted.output.contains("Second page text"))
  }

  @Test func reconstructionLeavesTheSourceGraphUntouched() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let before = try PageContent.load(pageID: pageIDs[0], in: graph).segments[0].decoded
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    _ = try DOCXExport.package(reconstruction: reconstruction)
    let after = try PageContent.load(pageID: pageIDs[0], in: graph).segments[0].decoded
    #expect(before == after)
    #expect(!reconstruction.limitations.isEmpty)
    // The limitations mention what the first mapping does not represent.
    #expect(reconstruction.limitations.contains { $0.contains("Bold and italic") })
  }
}
