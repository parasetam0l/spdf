import Darwin
import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P35-025–P35-029: independent package validation, an independent DOCX
/// consumer, expected-reconstruction checks, the no-round-trip disclosure, and
/// the speed/size/memory measurement.
@Suite("DOCX verification")
struct DOCXVerificationTests {
  // MARK: - Fixture

  /// Two pages: repeated header/footer, heading, linked paragraph, a 2×2
  /// table, an image, and second-page text.
  private func fixture() -> PDFGraph {
    var pageOne = Data()
    pageOne.append(Data("BT /F1 14 Tf 42 740 Td (Quarterly Report) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 24 Tf 42 700 Td (Section One) Tj ET\n".utf8))
    pageOne.append(Data("BT /F1 12 Tf 42 660 Td (Body text with link) Tj ET\n".utf8))
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
          PDFName("Lang"): .string(Data("en-US".utf8)),
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
        PDFObjectID(8): .stream(
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
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(8))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
          PDFName("Annots"): .array([.reference(PDFObjectID(9))]),
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
        PDFObjectID(9): .dictionary([
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

  private func package(_ reconstruction: DOCXReconstruction) throws -> (data: Data, url: URL) {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 7, 7, 7])
    let data = try DOCXExport.package(
      reconstruction: reconstruction,
      imageResolver: { _ in
        DOCXImageResource(data: png, fileExtension: "png", contentType: "image/png")
      })
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-verify-\(UUID().uuidString).docx")
    try data.write(to: url)
    return (data, url)
  }

  // MARK: - P35-025

  /// Every XML part parses, relationship ids are unique, non-external targets
  /// exist, content types cover every part, and the document's relationship
  /// references resolve.
  @Test func packageRelationshipsAndXMLValidateIndependently() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let (_, url) = try package(reconstruction)
    defer { try? FileManager.default.removeItem(at: url) }

    // Independent ZIP integrity.
    let listing = try run("/usr/bin/unzip", ["-t", url.path])
    #expect(listing.status == 0, "unzip -t: \(listing.output)")

    // Extract and parse every XML part with the platform parser.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-verify-extract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", directory.path])
    var files: [String] = []
    let resolvedRoot = directory.resolvingSymlinksInPath().path + "/"
    if let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    {
      for case let fileURL as URL in enumerator {
        guard
          (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { continue }
        let relative = fileURL.resolvingSymlinksInPath().path.replacingOccurrences(
          of: resolvedRoot, with: "")
        files.append(relative)
        if relative.hasSuffix(".xml") || relative.hasSuffix(".rels") {
          _ = try XMLDocument(data: try Data(contentsOf: fileURL))
        }
      }
    }
    #expect(files.contains(DOCXExport.documentPart))
    #expect(files.contains(DOCXExport.documentRelationshipsPart))

    // Relationship ids unique; targets exist unless external.
    var idsByPart: [String: [String]] = [:]
    var allIds: Set<String> = []
    for file in files where file.hasSuffix(".rels") {
      let xml = try XMLDocument(data: try Data(contentsOf: directory.appendingPathComponent(file)))
      let relationships = try xml.nodes(forXPath: "//*[local-name()='Relationship']")
      let ownerDirectory = (file as NSString).deletingLastPathComponent
      let baseDirectory =
        ownerDirectory == "_rels"
        ? "" : (ownerDirectory as NSString).deletingLastPathComponent
      var ids: [String] = []
      for node in relationships {
        guard let element = node as? XMLElement else { continue }
        let id = element.attribute(forName: "Id")?.stringValue ?? ""
        let target = element.attribute(forName: "Target")?.stringValue ?? ""
        let mode = element.attribute(forName: "TargetMode")?.stringValue
        ids.append(id)
        allIds.insert(id)
        #expect(!id.isEmpty)
        if mode == "External" {
          #expect(target.hasPrefix("http") || target.hasPrefix("mailto"))
        } else {
          let resolved =
            baseDirectory.isEmpty ? target : baseDirectory + "/" + target
          #expect(files.contains(resolved), "missing relationship target \(resolved)")
        }
      }
      idsByPart[file] = ids
      #expect(Set(ids).count == ids.count, "duplicate relationship id in \(file)")
    }
    #expect(idsByPart[DOCXExport.packageRelationshipsPart]?.count == 1)
    #expect(!allIds.isEmpty)

    // Content types cover every part.
    let contentTypesXML = try XMLDocument(
      data: try Data(
        contentsOf: directory.appendingPathComponent(DOCXExport.contentTypesPart)))
    let defaults = try contentTypesXML.nodes(forXPath: "//*[local-name()='Default']")
    let overrides = try contentTypesXML.nodes(forXPath: "//*[local-name()='Override']")
    var extensions: Set<String> = []
    for node in defaults {
      if let element = node as? XMLElement,
        let value = element.attribute(forName: "Extension")?.stringValue
      {
        extensions.insert(value.lowercased())
      }
    }
    var partNames: Set<String> = []
    for node in overrides {
      if let element = node as? XMLElement,
        let value = element.attribute(forName: "PartName")?.stringValue
      {
        partNames.insert(value)
      }
    }
    for file in files where file != DOCXExport.contentTypesPart {
      // OPC defines a part's extension as the substring after the final dot
      // (so `_rels/.rels` has the extension `rels`).
      let basename = (file as NSString).lastPathComponent
      let extensionName =
        basename.contains(".")
        ? String(basename.split(separator: ".").last ?? "").lowercased() : ""
      let covered = extensions.contains(extensionName) || partNames.contains("/" + file)
      #expect(covered, "no content type for \(file)")
    }

    // The document's r:id/r:embed references resolve in its relationship part.
    let documentXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    let referencePattern = try NSRegularExpression(pattern: "r:(?:id|embed)=\"([^\"]+)\"")
    let matches = referencePattern.matches(
      in: documentXML, range: NSRange(documentXML.startIndex..., in: documentXML))
    let documentIds = Set(idsByPart[DOCXExport.documentRelationshipsPart] ?? [])
    for match in matches {
      if let range = Range(match.range(at: 1), in: documentXML) {
        let reference = String(documentXML[range])
        #expect(documentIds.contains(reference), "unresolved r:id \(reference)")
      }
    }
    #expect(matches.count >= 3)  // styles, settings, numbering at least
  }

  // MARK: - P35-026

  @Test func representativePackageConvertsInIndependentConsumer() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") else { return }
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let (_, url) = try package(reconstruction)
    defer { try? FileManager.default.removeItem(at: url) }

    // Plain text: the table cells, headings, and both pages read back.
    let text = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
    #expect(text.status == 0, "textutil txt: \(text.output)")
    // Header/footer content lives in its own part; the body text conversion
    // carries the document content.
    for expected in [
      "Section One", "Body text with link", "Ada", "Engineer", "London",
      "Platform", "Second page body",
    ] {
      #expect(text.output.contains(expected), "missing \(expected)")
    }

    // Rich Text and HTML conversions also succeed and keep the table text.
    let rtf = try run("/usr/bin/textutil", ["-convert", "rtf", "-stdout", url.path])
    #expect(rtf.status == 0, "textutil rtf: \(rtf.output)")
    #expect(rtf.output.contains("Engineer"))
    let html = try run("/usr/bin/textutil", ["-convert", "html", "-stdout", url.path])
    #expect(html.status == 0, "textutil html: \(html.output)")
    #expect(html.output.contains("Engineer"))
    #expect(html.output.contains("Section One"))
  }

  // MARK: - P35-027

  @Test func expectedReconstructionMatchesTheFixture() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)

    // Geometry from the first page (612×792 pt → 12240×15840 twips).
    #expect(reconstruction.pageWidth == 612)
    #expect(reconstruction.pageHeight == 792)
    #expect(!reconstruction.landscape)

    // Text: heading level from the size ratio, linked paragraph, second page.
    let heading = try #require(reconstruction.blocks.first { $0.text == "Section One" })
    if case .heading(let level) = heading.kind {
      #expect(level == 1)
    } else {
      Issue.record("Section One is not a heading")
    }
    let linked = try #require(reconstruction.blocks.first { $0.text == "Body text with link" })
    #expect(linked.runs.first?.hyperlinkURI == "https://example.invalid/docs")

    // Table: two rows by two columns with the cell texts.
    let table = try #require(reconstruction.blocks.first { block in
      if case .table = block.kind { return true } else { return false }
    })
    guard case .table(let rows) = table.kind else {
      Issue.record("No table block")
      return
    }
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.count == 2 })
    #expect(rows[0][0].map(\.text).joined().contains("Name"))
    #expect(rows[1][1].map(\.text).joined().contains("Platform"))

    // Image: exact placement bounds and a drawing at 100 pt (1,270,000 EMU).
    let imageBlock = try #require(reconstruction.blocks.first { block in
      if case .image = block.kind { return true } else { return false }
    })
    guard case .image(let request) = imageBlock.kind else {
      Issue.record("No image block")
      return
    }
    #expect(request.bounds == [300, 300, 400, 400])

    // Header/footer from the repeated bands with a PAGE field.
    #expect(reconstruction.headerFooter.header?.map(\.text).joined() == "Quarterly Report")
    #expect(reconstruction.headerFooter.footer?.contains { $0.field == "PAGE" } == true)

    // One deliberate page break and both page bookmarks.
    #expect(reconstruction.blocks.filter { $0.kind == .pageBreak }.count == 1)
    #expect(reconstruction.blocks.filter { $0.bookmark != nil }.count == 2)

    // The packaged document carries the geometry, drawing, and hyperlink.
    let (data, url) = try package(reconstruction)
    defer { try? FileManager.default.removeItem(at: url) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-verify-expected-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", directory.path])
    let documentXML = String(
      decoding: try Data(contentsOf: directory.appendingPathComponent(DOCXExport.documentPart)),
      as: UTF8.self)
    #expect(documentXML.contains("<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"))
    #expect(documentXML.contains("r:embed=\"rIdImage1\""))
    #expect(documentXML.contains("<w:hyperlink r:id=\"rIdLink1\">"))
    #expect(documentXML.contains("<w:br w:type=\"page\"/>"))
    #expect(data.count > 0)
  }

  // MARK: - P35-028

  @Test func noRoundTripClaimIsMade() throws {
    // The canonical disclosure denies a perfect round trip and states the
    // source is untouched.
    let disclosure = DOCXExport.fidelityDisclosure
    #expect(disclosure.contains("not a perfect round trip"))
    #expect(disclosure.contains("cannot reproduce"))
    #expect(disclosure.contains("PDF is not modified"))

    // Every reconstruction of real content records limitations.
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    #expect(!reconstruction.limitations.isEmpty)
    #expect(reconstruction.limitations.contains { $0.contains("not reconstructed") })

    // The documentation carries the same statement.
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    for relative in ["Docs/Exports.md", "README.md"] {
      let contents = try String(
        contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
      #expect(
        contents.contains("never a perfect round trip")
          || contents.contains("not a perfect round trip")
          || contents.contains("cannot reproduce"),
        "\(relative) lacks the fidelity statement")
    }
  }

  // MARK: - P35-029

  @Test func exportSpeedSizeAndMemoryAreBounded() throws {
    // A realistic synthetic document: 60 pages with a heading and 40 lines.
    var objects: [PDFObjectID: PDFValue] = [:]
    var kids: [PDFValue] = []
    var nextID = 100
    for page in 1...60 {
      var content = Data()
      content.append(Data("BT /F1 24 Tf 42 740 Td (Chapter \(page)) Tj ET\n".utf8))
      for line in 0..<40 {
        content.append(
          Data(
            "BT /F1 12 Tf 42 \(700 - line * 16) Td (Page \(page) line \(line) with some words) Tj ET\n"
              .utf8))
      }
      let contentID = PDFObjectID(nextID)
      let pageID = PDFObjectID(nextID + 1)
      nextID += 2
      objects[contentID] = .stream(PDFStream(bytes: content))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(60),
      PDFName("Kids"): .array(kids),
    ])
    objects[PDFObjectID(3)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    #expect(pageIDs.count == 60)

    let before = memoryFootprint()
    let start = ContinuousClock.now
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let elapsed = ContinuousClock.now - start
    let after = memoryFootprint()
    let milliseconds =
      elapsed.components.seconds * 1000
      + elapsed.components.attoseconds / 1_000_000_000_000_000
    let growth = after > before ? after - before : 0
    print(
      "[P35-029] \(reconstruction.blocks.count) blocks, \(milliseconds) ms, "
        + "\(data.count / 1024) KiB, footprint growth \(growth / 1_048_576) MiB")
    #expect(reconstruction.blocks.count > 100)
    // ~1.8 s measured for 60 pages / 2,460 lines after computing the structure
    // roles once per document (the per-page inspection was quadratic); the
    // bound keeps headroom for slower CI machines.
    #expect(milliseconds < 15_000)
    #expect(data.count < 8 * 1_048_576)
    #expect(growth < 512 * 1_048_576)
  }

  private func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
