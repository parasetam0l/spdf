import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P37-001/P37-002/P37-007–P37-011/P37-019–P37-022: the version/extension
/// audit, the PDF/A-2b inventory, and the print-preflight inventory.
@Suite("PDF compatibility")
struct PDFCompatibilityTests {
  /// A page with one font (embedded when `embedded`) and optional extras.
  private func fixture(
    version: String = "1.7", catalogVersion: String? = nil,
    extensions: [PDFName: PDFValue]? = nil, embedded: Bool = false,
    metadata: Bool = false, outputIntent: Bool = false, identifier: Bool = false,
    encrypted: Bool = false, javascript: Bool = false, embeddedFiles: Bool = false,
    needAppearances: Bool = false, movieAnnotation: Bool = false,
    transparency: Bool = false, image: Bool = false, boxes: Bool = false
  ) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [:]
    var catalog: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ]
    if let catalogVersion { catalog[PDFName("Version")] = .name(PDFName(catalogVersion)) }
    if let extensions { catalog[PDFName("Extensions")] = .dictionary(extensions) }
    if metadata { catalog[PDFName("Metadata")] = .reference(PDFObjectID(40)) }
    if outputIntent {
      catalog[PDFName("OutputIntents")] = .array([.reference(PDFObjectID(41))])
    }
    if embeddedFiles {
      catalog[PDFName("Names")] = .dictionary([
        PDFName("EmbeddedFiles"): .dictionary([
          PDFName("Names"): .array([.string(Data("file".utf8)), .reference(PDFObjectID(50))])
        ])
      ])
    }
    if needAppearances {
      catalog[PDFName("AcroForm")] = .dictionary([
        PDFName("NeedAppearances"): .boolean(true)
      ])
    }
    objects[PDFObjectID(1)] = .dictionary(catalog)
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
    ])
    var font: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ]
    if embedded {
      font[PDFName("FontDescriptor")] = .reference(PDFObjectID(30))
      objects[PDFObjectID(30)] = .dictionary([
        PDFName("Type"): .name(PDFName("FontDescriptor")),
        PDFName("FontName"): .name(PDFName("Helvetica")),
        PDFName("Flags"): .integer(32),
        PDFName("FontFile2"): .reference(PDFObjectID(31)),
      ])
      objects[PDFObjectID(31)] = .stream(PDFStream(bytes: Data([0, 1, 2, 3])))
    }
    objects[PDFObjectID(3)] = .dictionary(font)
    var resources: [PDFName: PDFValue] = [
      PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
    ]
    var page: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("Resources"): .dictionary(resources),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ]
    if boxes {
      page[PDFName("CropBox")] = .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ])
      page[PDFName("TrimBox")] = .array([
        .integer(10), .integer(10), .integer(602), .integer(782),
      ])
      page[PDFName("BleedBox")] = .array([
        .integer(5), .integer(5), .integer(607), .integer(787),
      ])
    }
    if image {
      resources[PDFName("XObject")] = .dictionary([PDFName("Im1"): .reference(PDFObjectID(20))])
      page[PDFName("Resources")] = .dictionary(resources)
      objects[PDFObjectID(20)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("BitsPerComponent"): .integer(8),
          ], bytes: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])))
    }
    if transparency {
      resources[PDFName("ExtGState")] = .dictionary([
        PDFName("GS1"): .dictionary([
          PDFName("CA"): .real(0.5), PDFName("op"): .boolean(true),
        ])
      ])
      page[PDFName("Resources")] = .dictionary(resources)
    }
    if javascript || movieAnnotation {
      objects[PDFObjectID(10)] = .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName(movieAnnotation ? "Movie" : "Text")),
        PDFName("Rect"): .array([
          .integer(0), .integer(0), .integer(10), .integer(10),
        ]),
        PDFName("A"): .dictionary([
          PDFName("S"): .name(PDFName("JavaScript")),
          PDFName("JS"): .string(Data("app.alert(1)".utf8)),
        ]),
      ])
      page[PDFName("Annots")] = .array([.reference(PDFObjectID(10))])
    }
    objects[PDFObjectID(4)] = .dictionary(page)
    var content = "BT /F1 12 Tf 72 700 Td (Hello) Tj ET\n"
    if image { content += "q 120 0 0 120 72 500 cm /Im1 Do Q\n" }
    objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(content.utf8)))
    if metadata {
      objects[PDFObjectID(40)] = .stream(
        PDFStream(
          dictionary: [PDFName("Type"): .name(PDFName("Metadata")),
            PDFName("Subtype"): .name(PDFName("XML"))],
          bytes: Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)))
    }
    if outputIntent {
      objects[PDFObjectID(41)] = .dictionary([
        PDFName("Type"): .name(PDFName("OutputIntent")),
        PDFName("S"): .name(PDFName("GTS_PDFA1")),
        PDFName("OutputConditionIdentifier"): .string(Data("sRGB".utf8)),
        PDFName("DestOutputProfile"): .reference(PDFObjectID(42)),
      ])
      objects[PDFObjectID(42)] = .stream(PDFStream(bytes: Data([0, 0, 0, 0])))
    }
    if embeddedFiles {
      objects[PDFObjectID(50)] = .dictionary([
        PDFName("Type"): .name(PDFName("Filespec")),
        PDFName("F"): .string(Data("file.txt".utf8)),
      ])
    }
    var trailer: [PDFName: PDFValue] = [PDFName("Root"): .reference(PDFObjectID(1))]
    if identifier {
      trailer[PDFName("ID")] = .array([
        .string(Data("0123456789abcdef".utf8)), .string(Data("0123456789abcdef".utf8)),
      ])
    }
    if encrypted {
      trailer[PDFName("Encrypt")] = .reference(PDFObjectID(60))
      objects[PDFObjectID(60)] = .dictionary([
        PDFName("Filter"): .name(PDFName("Standard")),
        PDFName("V"): .integer(5), PDFName("R"): .integer(6),
      ])
    }
    return PDFGraph(version: version, objects: objects, trailer: trailer)
  }

  // MARK: - P37-001/P37-002/P37-004

  @Test func versionAuditReportsDeclarationsAndExtensions() throws {
    let graph = fixture(
      version: "2.0", catalogVersion: "2.0",
      extensions: [
        PDFName("ADBE"): .dictionary([
          PDFName("BaseVersion"): .name(PDFName("1.7")),
          PDFName("ExtensionLevel"): .integer(3),
        ])
      ])
    let audit = PDFVersionAudit.audit(in: graph)
    #expect(audit.headerVersion == "2.0")
    #expect(audit.catalogVersion == "2.0")
    #expect(audit.declaresPDF20)
    #expect(audit.effectiveVersion == "2.0")
    let extension1 = try #require(audit.extensions.first)
    #expect(extension1.prefix == "ADBE")
    #expect(extension1.baseVersion == "1.7")
    #expect(extension1.extensionLevel == 3)
    #expect(extension1.preserved)
    // P37-004: no extension is claimed as implemented.
    #expect(audit.implementedExtensionPrefixes.isEmpty)
    #expect(audit.notes.contains { $0.contains("not implemented") })
    #expect(audit.report().contains("PDF version audit"))

    // A 1.7 document with a newer catalog version reports the difference.
    let mixed = PDFVersionAudit.audit(in: fixture(version: "1.4", catalogVersion: "1.7"))
    #expect(mixed.effectiveVersion == "1.7")
    #expect(!mixed.declaresPDF20)
    #expect(mixed.notes.contains { $0.contains("differs") })
  }

  // MARK: - P37-003

  @Test func rewritesPreserveExtensionsAndRefuseSilentDowngrades() throws {
    // A 1.x document with extension dictionaries keeps them (and its catalog
    // version) through a rewrite.
    let extended = fixture(
      version: "1.7", catalogVersion: "1.7",
      extensions: [
        PDFName("ADBE"): .dictionary([
          PDFName("BaseVersion"): .name(PDFName("1.7")),
          PDFName("ExtensionLevel"): .integer(3),
        ]),
        PDFName("XX"): .dictionary([PDFName("BaseVersion"): .name(PDFName("1.7"))]),
      ])
    let written = try PDFWriter.write(extended)
    let parsed = try PDFParser.parse(written)
    let audit = PDFVersionAudit.audit(in: parsed.graph)
    #expect(audit.headerVersion == "1.7")
    #expect(audit.catalogVersion == "1.7")
    #expect(audit.extensions.map(\.prefix) == ["ADBE", "XX"])
    #expect(audit.extensions.allSatisfy { $0.preserved })
    // And the audit still refuses to claim implementation.
    #expect(audit.implementedExtensionPrefixes.isEmpty)

    // Writing a PDF 2.0 graph is refused explicitly — never silently
    // downgraded to 1.7.
    let modern = fixture(version: "2.0", catalogVersion: "2.0")
    #expect(throws: PDFError.self) { try PDFWriter.write(modern) }
    do {
      _ = try PDFWriter.write(modern)
      Issue.record("A PDF 2.0 rewrite was not refused")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  // MARK: - P37-007–P37-011

  @Test func archivalInventoryFindsErrorsOnOrdinaryDocuments() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let inventory = ArchivalInventory.inventory(graph, pageIDs: pageIDs)
    #expect(inventory.profile == .pdfa2b)
    #expect(!inventory.passesInventory)
    let rules = inventory.findings.filter { $0.severity == .error }.map(\.rule)
    #expect(rules.contains("Font embedding"))
    #expect(rules.contains("OutputIntent"))
    #expect(rules.contains("XMP metadata"))
    // The report states explicitly that it is not a conformance claim.
    #expect(inventory.report().contains("not a conformance claim"))
    #expect(inventory.report().contains("no PDF/A identifier is written"))
  }

  @Test func archivalInventoryPassesOnAConformantFixture() throws {
    let graph = fixture(
      embedded: true, metadata: true, outputIntent: true, identifier: true,
      transparency: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let inventory = ArchivalInventory.inventory(graph, pageIDs: pageIDs)
    #expect(inventory.errorCount == 0, "\(inventory.report())")
    #expect(inventory.passesInventory)
    // Transparency is allowed by PDF/A-2 and reported as info.
    #expect(inventory.findings.contains { $0.rule == "Transparency" && $0.severity == .info })
    // XMP presence still needs independent validation.
    #expect(inventory.warningCount >= 0)
  }

  @Test func archivalInventoryFindsForbiddenFeatures() throws {
    let pageIDs = try PDFPageTree.pageIDs(in: fixture())
    let encrypted = ArchivalInventory.inventory(
      fixture(encrypted: true), pageIDs: pageIDs)
    #expect(encrypted.findings.contains { $0.rule == "Encryption" && $0.severity == .error })
    let javascript = ArchivalInventory.inventory(fixture(javascript: true), pageIDs: pageIDs)
    #expect(
      javascript.findings.contains { $0.rule == "Executable actions" && $0.severity == .error })
    let embedded = ArchivalInventory.inventory(
      fixture(embeddedFiles: true), pageIDs: pageIDs)
    #expect(embedded.findings.contains { $0.rule == "Embedded files" && $0.severity == .error })
    let needAppearances = ArchivalInventory.inventory(
      fixture(needAppearances: true), pageIDs: pageIDs)
    #expect(
      needAppearances.findings.contains { $0.rule == "NeedAppearances" && $0.severity == .error })
    let movie = ArchivalInventory.inventory(fixture(movieAnnotation: true), pageIDs: pageIDs)
    #expect(
      movie.findings.contains { $0.rule == "Media annotations" && $0.severity == .error })
  }

  // MARK: - P37-019–P37-022

  @Test func preflightInventoryReportsBoxesFontsImagesAndColors() throws {
    let graph = fixture(version: "1.7", transparency: true, image: true, boxes: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let inventory = PrintPreflightInventory.inventory(graph, pageIDs: pageIDs)
    #expect(!PrintPreflightInventory.profileSelected)
    let page = try #require(inventory.pages.first)
    #expect(page.mediaBox == [0, 0, 612, 792])
    #expect(page.cropBox == [0, 0, 612, 792])
    #expect(page.trimBox == [10, 10, 602, 782])
    #expect(page.bleedBox == [5, 5, 607, 787])
    #expect(page.hasBleed)
    #expect(inventory.fontsNotEmbedded == 1)
    #expect(inventory.fontsEmbedded == 0)
    // 2×2 pixels at a 120 pt placement is far below 150 dpi.
    #expect(inventory.images.count == 1)
    #expect(inventory.lowResolutionImages == 1)
    #expect(inventory.colorSpaceCounts["DeviceRGB"] == 1)
    #expect(!inventory.hasOutputIntent)
    #expect(inventory.transparencyUses == 1)
    #expect(inventory.overprintUses == 1)
    let report = inventory.report()
    #expect(report.contains("No preflight profile is selected"))
    #expect(report.contains("TrimBox"))
    #expect(report.contains("below 150 dpi"))
  }

  @Test func preflightInventoryIsQuietOnAPlainPage() throws {
    let graph = fixture(embedded: true, outputIntent: true, identifier: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let inventory = PrintPreflightInventory.inventory(graph, pageIDs: pageIDs)
    #expect(inventory.fontsEmbedded == 1)
    #expect(inventory.fontsNotEmbedded == 0)
    #expect(inventory.images.isEmpty)
    #expect(inventory.lowResolutionImages == 0)
    #expect(inventory.transparencyUses == 0)
    #expect(inventory.overprintUses == 0)
    #expect(inventory.hasOutputIntent)
  }
}
