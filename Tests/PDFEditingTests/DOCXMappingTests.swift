import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P35-015–P35-019: tables, images, hyperlinks/bookmarks, headers/footers with
/// PAGE fields, and documented font substitutions.
@Suite("DOCX content mapping")
struct DOCXMappingTests {
  private func fixture() -> PDFGraph {
    var pageOne = Data()
    pageOne.append(Data("BT /F1 14 Tf 42 740 Td (Quarterly Report) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 24 Tf 42 700 Td (Section One) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 660 Td (Body text with link) Tj ET\n".utf8))
    pageOne.append(Data("BT /F3 12 Tf 42 620 Td (Custom font line) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 14 Tf 42 560 Td (Table of quarterly results) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 520 Td (Name) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 504 Td (Ada) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 220 520 Td (Role) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 220 504 Td (Engineer) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 464 Td (City) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 72 448 Td (London) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 220 464 Td (Team) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 220 448 Td (Platform) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 10 Tf 42 40 Td (Page 1) Tj ET\n".utf8))
    pageOne.append(Data("q 100 0 0 100 300 300 cm /Im1 Do Q\n".utf8))
    var pageTwo = Data()
    pageTwo.append(Data("BT /F1 14 Tf 42 740 Td (Quarterly Report) Tj ET\n".utf8))
    pageTwo.append(Data("BT /F1 12 Tf 42 660 Td (Second page body) Tj ET\n".utf8))
    pageTwo.append(Data("BT /F1 10 Tf 42 40 Td (Page 2) Tj ET\n".utf8))
    let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
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
          PDFName("BaseFont"): .name(PDFName("Custom Sans")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(9): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: green)),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([
              PDFName("F1"): .reference(PDFObjectID(3)),
              PDFName("F3"): .reference(PDFObjectID(8)),
            ]),
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(9))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
          PDFName("Annots"): .array([
            .reference(PDFObjectID(10)), .reference(PDFObjectID(11)),
          ]),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: pageOne)),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(7)),
          PDFName("Annots"): .array([.reference(PDFObjectID(12))]),
        ]),
        PDFObjectID(7): .stream(PDFStream(bytes: pageTwo)),
        PDFObjectID(10): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([
            .integer(42), .integer(655), .integer(200), .integer(675),
          ]),
          PDFName("A"): .dictionary([
            PDFName("S"): .name(PDFName("URI")),
            PDFName("URI"): .string(Data("https://example.invalid/docs".utf8)),
          ]),
        ]),
        PDFObjectID(11): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([
            .integer(42), .integer(615), .integer(200), .integer(635),
          ]),
          PDFName("A"): .dictionary([
            PDFName("S"): .name(PDFName("URI")),
            PDFName("URI"): .string(Data("javascript:alert(1)".utf8)),
          ]),
        ]),
        PDFObjectID(12): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([
            .integer(42), .integer(655), .integer(220), .integer(675),
          ]),
          PDFName("Dest"): .array([.reference(PDFObjectID(4)), .name(PDFName("Fit"))]),
        ]),
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

  private func extractDocumentXML(_ data: Data) throws -> (xml: String, directory: URL) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-mapping-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-mapping-extract-\(UUID().uuidString)")
    _ = try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", directory.path])
    try? FileManager.default.removeItem(at: url)
    let xml = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    return (xml, directory)
  }

  @Test func tablesMapFromDetectedGrids() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let table = try #require(reconstruction.blocks.first { block in
      if case .table = block.kind { return true } else { return false }
    })
    guard case .table(let rows) = table.kind else {
      Issue.record("No table block")
      return
    }
    guard rows.count == 2, rows.allSatisfy({ $0.count == 2 }) else {
      Issue.record("Unexpected table shape")
      return
    }
    // Each grid cell keeps its multi-line text.
    #expect(rows[0][0].map(\.text).joined().contains("Name"))
    #expect(rows[0][0].map(\.text).joined().contains("Ada"))
    #expect(rows[0][1].map(\.text).joined().contains("Engineer"))
    #expect(rows[1][0].map(\.text).joined().contains("London"))
    #expect(rows[1][1].map(\.text).joined().contains("Platform"))
    // Cell text is not duplicated as paragraphs.
    #expect(!reconstruction.blocks.contains { block in
      if case .paragraph = block.kind { return block.text.contains("Engineer") } else { return false }
    })
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let (xml, directory) = try extractDocumentXML(data)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(xml.contains("<w:tbl>"))
    #expect(xml.contains("Engineer"))
    _ = try XMLDocument(data: Data(xml.utf8))
    #expect(reconstruction.limitations.contains { $0.contains("table grids") })

    // Package integrity and independent consumption of the table text.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-mapping-table-\(UUID().uuidString).docx")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let listing = try run("/usr/bin/unzip", ["-t", url.path])
    #expect(listing.status == 0)
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") {
      let converted = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
      #expect(converted.status == 0, "textutil: \(converted.output)")
      #expect(converted.output.contains("Ada"))
      #expect(converted.output.contains("Engineer"))
      #expect(converted.output.contains("Platform"))
    }
  }

  @Test func imagesMapWithRelationshipsAndPlacement() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let imageBlock = try #require(reconstruction.blocks.first { block in
      if case .image = block.kind { return true } else { return false }
    })
    guard case .image(let request) = imageBlock.kind else {
      Issue.record("No image block")
      return
    }
    #expect(request.bounds == [300, 300, 400, 400])

    // Without a resolver the drawing is omitted gracefully.
    let plain = try DOCXExport.package(reconstruction: reconstruction)
    let (plainXML, plainDirectory) = try extractDocumentXML(plain)
    defer { try? FileManager.default.removeItem(at: plainDirectory) }
    #expect(!plainXML.contains("<w:drawing>"))

    // With a resolver the drawing, media file, and relationship appear.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    let data = try DOCXExport.package(
      reconstruction: reconstruction,
      imageResolver: { _ in
        DOCXImageResource(data: png, fileExtension: "png", contentType: "image/png")
      })
    let (xml, directory) = try extractDocumentXML(data)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(xml.contains("<w:drawing>"))
    #expect(xml.contains("r:embed=\"rIdImage1\""))
    // 100 pt = 1,270,000 EMU.
    #expect(xml.contains("cx=\"1270000\""))
    _ = try XMLDocument(data: Data(xml.utf8))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("word/media/image0001.png").path))
    let relationships = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentRelationshipsPart)),
      as: UTF8.self)
    #expect(relationships.contains("media/image0001.png"))
    let contentTypes = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.contentTypesPart)),
      as: UTF8.self)
    #expect(contentTypes.contains("image/png"))
  }

  @Test func hyperlinksMapURIsAndAnchors() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)

    // The safe URI becomes an external hyperlink.
    #expect(xml.contains("<w:hyperlink r:id=\"rIdLink1\">"))
    // The internal destination becomes an anchor and the target page has a
    // bookmark.
    #expect(xml.contains("<w:hyperlink w:anchor=\"page-1\">"))
    #expect(xml.contains("w:name=\"page-1\""))
    #expect(xml.contains("w:name=\"page-2\""))
    // The javascript: URI is dropped (no second external relationship).
    let relationships = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentRelationshipsPart)),
      as: UTF8.self)
    #expect(relationships.contains("https://example.invalid/docs"))
    #expect(!relationships.contains("javascript:"))
    #expect(relationships.contains("TargetMode=\"External\""))
    _ = try XMLDocument(data: Data(xml.utf8))
    _ = try XMLDocument(data: Data(relationships.utf8))
    // Both pages carry bookmarks.
    #expect(reconstruction.blocks.filter { $0.bookmark != nil }.count == 2)
  }

  @Test func headersFootersAndPageNumberFields() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    // The repeated header text is not in the body blocks.
    #expect(!reconstruction.blocks.contains { $0.text.contains("Quarterly Report") })
    let header = try #require(reconstruction.headerFooter.header)
    #expect(header.map(\.text).joined().contains("Quarterly Report"))
    // The repeated page-number footer maps to a PAGE field.
    let footer = try #require(reconstruction.headerFooter.footer)
    #expect(footer.contains { $0.field == "PAGE" })
    #expect(footer.map(\.text).joined().contains("Page "))
    #expect(!reconstruction.blocks.contains { $0.text.contains("Page 1") })
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(DOCXExport.headerPart).path))
    #expect(xml.contains("<w:headerReference"))
    #expect(xml.contains("<w:footerReference"))
    let headerXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.headerPart)),
      as: UTF8.self)
    #expect(headerXML.contains("Quarterly Report"))
    let footerXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.footerPart)),
      as: UTF8.self)
    #expect(footerXML.contains("w:instr=\"PAGE\""))
    _ = try XMLDocument(data: Data(headerXML.utf8))
    _ = try XMLDocument(data: Data(footerXML.utf8))
    _ = try XMLDocument(data: Data(xml.utf8))
  }

  @Test func pageNumberPatternsBecomeFields() {
    // A repeated footer text matching a single-number pattern maps to PAGE.
    let runs = DOCXReconstructionBuilder.pageNumberRuns(
      text: "Page 7", base: DOCXRunInput(text: "Page 7"))
    // Prefix + PAGE field (the empty suffix is omitted).
    #expect(runs.count == 2)
    #expect(runs[0].text == "Page ")
    #expect(runs[1].field == "PAGE")
    #expect(runs[1].text == "7")
    let bracketed = DOCXReconstructionBuilder.pageNumberRuns(
      text: "- 12 -", base: DOCXRunInput(text: "- 12 -"))
    #expect(bracketed.count == 3)
    #expect(bracketed[0].text == "- ")
    #expect(bracketed[1].field == "PAGE")
    #expect(bracketed[2].text == " -")
    let plain = DOCXReconstructionBuilder.pageNumberRuns(
      text: "Confidential", base: DOCXRunInput(text: "Confidential"))
    #expect(plain.count == 1)
    #expect(plain[0].field == nil)
  }

  /// A two-page fixture: page one has two columns, page two a single column,
  /// and the catalog declares a language.
  private func columnFixture() -> PDFGraph {
    var pageOne = Data()
    pageOne.append(Data("BT /F1 12 Tf 42 700 Td (Left column first line) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 680 Td (Left column second line) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 660 Td (Left column third line) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 320 700 Td (Right column first line) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 320 680 Td (Right column second line) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 320 660 Td (Right column third line) Tj ET\n".utf8))
    var pageTwo = Data()
    pageTwo.append(Data("BT /F1 12 Tf 42 660 Td (Single column page text) Tj ET\n".utf8))
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
          PDFName("Lang"): .string(Data("de-DE".utf8)),
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
        PDFObjectID(5): .stream(PDFStream(bytes: pageOne)),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
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

  @Test func multiColumnPagesReadColumnByColumn() throws {
    let graph = columnFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    // Page one is detected as two columns, page two as one: mixed columns map
    // to sections rather than page breaks.
    #expect(reconstruction.blocks.contains { block in
      if case .sectionBreak(let columns) = block.kind { return columns == 2 }
      return false
    })
    #expect(!reconstruction.blocks.contains { $0.kind == .pageBreak })
    #expect(reconstruction.limitations.contains { $0.contains("Column counts differ") })
    #expect(reconstruction.limitations.contains { $0.contains("columns map to Word sections") })

    // Reading order: the left column's lines precede the right column's.
    let texts = reconstruction.blocks.map(\.text)
    let firstLeft = try #require(texts.firstIndex { $0.contains("Left column first") })
    let lastLeft = try #require(texts.firstIndex { $0.contains("Left column third") })
    let firstRight = try #require(texts.firstIndex { $0.contains("Right column first") })
    #expect(lastLeft < firstRight)
    // The column's lines stay one block with its line structure.
    #expect(texts[firstLeft].contains("Left column third line"))

    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    // The section ending page one carries two columns; the final section
    // (page two) stays single-column.
    #expect(xml.contains("<w:sectPr><w:cols w:num=\"2\"/>"))
    let finalSection = try #require(xml.range(of: "<w:sectPr>", options: .backwards))
    #expect(!xml[finalSection.lowerBound...].contains("<w:cols"))
    _ = try XMLDocument(data: Data(xml.utf8))
    #expect(xml.contains("<w:lang w:val=\"de-DE\"/>"))
  }

  @Test func rtlAndLanguageAttributes() throws {
    // Direction and language map with the schema-ordered run properties.
    let runXML = DOCXExport.runXML(
      DOCXRunInput(text: "שלום", rtl: true, language: "he-IL"))
    #expect(runXML.contains("<w:rtl/>"))
    #expect(runXML.contains("<w:lang w:val=\"he-IL\"/>"))
    #expect(runXML.range(of: "<w:rtl/>")!.lowerBound < runXML.range(of: "<w:lang")!.lowerBound)
    let blockXML = DOCXExport.blockXML(
      DOCXBlock(
        kind: .paragraph, runs: [DOCXRunInput(text: "שלום", rtl: true)], rtl: true))
    #expect(blockXML.contains("<w:bidi/>"))
    #expect(blockXML.contains("<w:rtl/>"))

    // Script detection: Hebrew and Arabic are RTL, Latin is not.
    #expect(DOCXReconstructionBuilder.containsRTL("שלום"))
    #expect(DOCXReconstructionBuilder.containsRTL("مرحبا"))
    #expect(!DOCXReconstructionBuilder.containsRTL("hello"))
    #expect(DOCXReconstructionBuilder.isRTLMajority("שלום עולם"))
    #expect(!DOCXReconstructionBuilder.isRTLMajority("hello שלום"))
  }

  @Test func appearanceModeLabelsUncertainRegions() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // Editable mode keeps the low-confidence line as text.
    let editable = try DOCXReconstructionBuilder.reconstruct(pageIDs: pageIDs, in: graph)
    #expect(editable.blocks.contains { $0.text.contains("Body text with link") })
    #expect(!editable.blocks.contains { block in
      if case .image(let request) = block.kind { return request.isAppearance }
      return false
    })

    // Appearance mode replaces it with a rendered region plus a label.
    let appearance = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph, mode: .appearance)
    let region = try #require(appearance.blocks.first { block in
      if case .image(let request) = block.kind { return request.isAppearance }
      return false
    })
    guard case .image(let request) = region.kind else {
      Issue.record("No appearance region")
      return
    }
    #expect(request.name == "appearance")
    #expect(request.bounds == [42, 660, 138, 672])
    #expect(appearance.blocks.contains { $0.text == "Appearance: Body text with link" })
    #expect(appearance.limitations.contains { $0.contains("appearance images") })
    // Confident text is untouched.
    #expect(appearance.blocks.contains { $0.text.contains("Section One") })

    // The packaged document embeds the rendered region.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9])
    let data = try DOCXExport.package(
      reconstruction: appearance,
      imageResolver: { request in
        DOCXImageResource(data: png, fileExtension: "png", contentType: "image/png")
      })
    let (xml, directory) = try extractDocumentXML(data)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(xml.contains("<w:drawing>"))
    #expect(xml.contains("Appearance: Body text with link"))
    _ = try XMLDocument(data: Data(xml.utf8))
  }

  @Test func fontSubstitutionsAreDocumented() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    // The custom font line maps to a substitution; standard fonts do not.
    let custom = try #require(reconstruction.blocks.first { $0.text.contains("Custom font line") })
    #expect(custom.runs.first?.fontFamily == "Helvetica")
    #expect(reconstruction.limitations.contains { $0.contains("substitution") })
    let heading = try #require(reconstruction.blocks.first { $0.text.contains("Section One") })
    #expect(heading.runs.first?.fontFamily == nil)
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(xml.contains("<w:rFonts w:ascii=\"Helvetica\" w:hAnsi=\"Helvetica\"/>"))
  }
}

/// P35-031: merged cells and spans survive into WordprocessingML.
@Suite("DOCX merged cells")
struct DOCXMergedCellTests {
  fileprivate func ruledGraph() -> PDFGraph {
    var content = "1 w 0 0 0 RG\n"
    content += "72 600 100 40 re S\n"
    content += "172 600 100 40 re S\n"
    content += "72 640 200 40 re S\n"
    content += "BT /F1 12 Tf 90 655 Td (Merged header spanning) Tj ET\n"
    content += "BT /F1 12 Tf 90 615 Td (Left) Tj ET\n"
    content += "BT /F1 12 Tf 200 615 Td (Right) Tj ET\n"
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
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func ruledTableMergesThroughTheBuilder() throws {
    // The ruled fixture's merged header reaches the DOCX builder through the
    // extraction layer and lands as a gridSpan cell.
    let graph = Self.ruledFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let tableBlock = try #require(reconstruction.blocks.first { block in
      if case .table = block.kind { return true } else { return false }
    })
    #expect(tableBlock.spans.contains { $0.row == 0 && $0.column == 0 && $0.columnSpan == 2 })
    // The table text is not duplicated as paragraphs.
    #expect(!reconstruction.blocks.contains { $0.text.contains("Merged header spanning") })
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-ruled-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-ruled-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(xml.contains("<w:gridSpan w:val=\"2\"/>"))
    #expect(xml.contains("Merged header spanning"))
    _ = try XMLDocument(data: Data(xml.utf8))
  }

  static func ruledFixture() -> PDFGraph {
    var content = "1 w 0 0 0 RG\n"
    content += "72 600 100 40 re S\n"
    content += "172 600 100 40 re S\n"
    content += "72 640 200 40 re S\n"
    content += "BT /F1 12 Tf 90 655 Td (Merged header spanning) Tj ET\n"
    content += "BT /F1 12 Tf 90 615 Td (Left) Tj ET\n"
    content += "BT /F1 12 Tf 200 615 Td (Right) Tj ET\n"
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
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func mergedCellsEmitGridSpanAndVMerge() throws {
    // The writer and package emit merged cells with `w:gridSpan`/`w:vMerge`
    // when a table block carries spans.
    let block = DOCXBlock(
      kind: .table(rows: [
        [[DOCXRunInput(text: "Merged header")], []],
        [[DOCXRunInput(text: "Left")], [DOCXRunInput(text: "Right")]],
      ]),
      runs: [],
      spans: [DOCXTableSpan(row: 0, column: 0, rowSpan: 1, columnSpan: 2)])
    let reconstruction = DOCXReconstruction(
      blocks: [block], pageWidth: 612, pageHeight: 792, landscape: false, limitations: [])
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-merge-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(xml.contains("<w:gridSpan w:val=\"2\"/>"))
    #expect(xml.contains("Merged header"))
    _ = try XMLDocument(data: Data(xml.utf8))
    // Vertical merges restart and continue.
    let vertical = DOCXExport.tableXML(
      rows: [[[DOCXRunInput(text: "Top")]], [[DOCXRunInput(text: "")]]],
      spans: [DOCXTableSpan(row: 0, column: 0, rowSpan: 2, columnSpan: 1)], hyperlinks: [:])
    #expect(vertical.contains("<w:vMerge w:val=\"restart\"/>"))
    #expect(vertical.contains("<w:vMerge/>"))
  }
}

/// P35-034: hyperlink run bounds prefer exact cluster geometry and fall back
/// to per-line proportional bounds for fonts without metrics.
@Suite("DOCX link bounds")
struct DOCXLinkBoundTests {
  @Test func linkBoundsPreferClusterGeometryThenPerLine() throws {
    // A metrics-bearing fixture: the link covers the first word only, so the
    // linked run's bounds must not swallow the rest of the line.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    // A link rectangle over the first text run only.
    let linkID = PDFObjectID(900)
    graph.objects[linkID] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Link")),
      PDFName("Rect"): .array([
        .integer(40), .integer(705), .integer(70), .integer(735),
      ]),
      PDFName("A"): .dictionary([
        PDFName("S"): .name(PDFName("URI")),
        PDFName("URI"): .string(Data("https://example.invalid/ab".utf8)),
      ]),
    ])
    if case .dictionary(var page)? = graph.objects[pageID] {
      page[PDFName("Annots")] = .array([.reference(linkID)])
      graph.objects[pageID] = .dictionary(page)
    }
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: [pageID], in: graph)
    let linkedRuns = reconstruction.blocks.flatMap(\.runs).filter { $0.hyperlinkURI != nil }
    #expect(!linkedRuns.isEmpty)
    // Only the covered text carries the link (not the whole line).
    #expect(linkedRuns.map(\.text).joined().count < 10)
  }
}

/// Shared fixture builder for the wrap tests (mirrors the mapping fixture).
enum PDFFixtureBuilders {
  static func mappingFixture() -> PDFGraph {
    var pageOne = Data()
    pageOne.append(Data("BT /F1 12 Tf 42 660 Td (Body text with link) Tj ET\n".utf8))
    pageOne.append(Data("q 100 0 0 100 300 300 cm /Im1 Do Q\n".utf8))
    let green = Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])
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
        PDFObjectID(9): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: green)),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))]),
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(9))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: pageOne)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }
}

/// P35-032: images overlapping text become anchored drawings with wrap;
/// images that do not overlap stay inline.
@Suite("DOCX image wrap")
struct DOCXImageWrapTests {
  @Test func overlappingImagesAnchorWithDrawOrder() throws {
    // The mapping fixture draws the image after the text, so it sits in front.
    let graph = PDFFixtureBuilders.mappingFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let imageBlock = try #require(reconstruction.blocks.first { block in
      if case .image = block.kind { return true } else { return false }
    })
    guard case .image(let request) = imageBlock.kind else {
      Issue.record("no image block")
      return
    }
    // The image does not overlap text in this fixture: inline.
    #expect(request.wrap == .inline)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 3])
    let data = try DOCXExport.package(
      reconstruction: reconstruction,
      imageResolver: { _ in
        DOCXImageResource(data: png, fileExtension: "png", contentType: "image/png")
      })
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-wrap-\\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-wrap-extract-\\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(xml.contains("<wp:inline"))
    #expect(!xml.contains("<wp:anchor"))

    // An anchored request emits an anchor with wrap and the behind flag.
    let anchored = DOCXExport.imageXML(
      request: DOCXImageRequest(
        pageIndex: 0, name: "Im1", bounds: [100, 400, 200, 500], wrap: .squareBehind),
      relationshipID: "rIdImage1", pictureIndex: 1)
    #expect(anchored.contains("<wp:anchor"))
    #expect(anchored.contains("behindDoc=\"1\""))
    #expect(anchored.contains("<wp:wrapSquare wrapText=\"bothSides\"/>"))
    #expect(anchored.contains("r:embed=\"rIdImage1\""))
    let front = DOCXExport.imageXML(
      request: DOCXImageRequest(
        pageIndex: 0, name: "Im1", bounds: [100, 400, 200, 500], wrap: .squareInFront),
      relationshipID: "rIdImage1", pictureIndex: 2)
    #expect(front.contains("behindDoc=\"0\""))
  }
}

/// P35-033: three-column pages map to `w:cols w:num="3"` with column-major
/// reading order.
@Suite("DOCX three columns")
struct DOCXThreeColumnTests {
  @Test func threeColumnsMapToAThreeColumnSection() throws {
    var content = ""
    for (column, x) in [(0, 42.0), (1, 240.0), (2, 438.0)] {
      for line in 0..<3 {
        content += "BT /F1 12 Tf \(Int(x)) \(680 - line * 20) Td (Column \(column) line \(line)) Tj ET\n"
      }
    }
    let graph = PDFGraph(
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
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    #expect(reconstruction.columns == 3)
    #expect(reconstruction.limitations.contains { $0.contains("Column counts differ") } == false)
    // Column-major: all column-0 lines precede column-1 lines, and so on.
    let texts = reconstruction.blocks.map(\.text)
    let firstOf = { (column: Int) in
      texts.firstIndex { $0.contains("Column \(column) line 0") } ?? Int.max
    }
    #expect(firstOf(0) < firstOf(1))
    #expect(firstOf(1) < firstOf(2))
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-3col-\(UUID().uuidString).docx")
    try data.write(to: url)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-3col-extract-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.removeItem(at: directory)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", "-o", url.path, "-d", directory.path]
    try process.run()
    process.waitUntilExit()
    let xml = String(
      decoding: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(xml.contains("<w:cols w:num=\"3\"/>"))
  }
}
