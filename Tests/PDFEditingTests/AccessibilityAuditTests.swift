import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P37-015–P37-018: the PDF/UA-oriented audit separates machine-checkable
/// findings from human review, and independent UA validation runs when a
/// validator is available.
@Suite("Accessibility audit")
struct PDFAccessibilityAuditTests {
  /// A tagged page with one Figure element (optionally with /Alt).
  private func taggedFixture(alt: String?) -> PDFGraph {
    var content = ""
    content += "/Figure <</MCID 0>> BDC\n"
    content += "q 100 0 0 100 72 600 cm /Im1 Do Q\n"
    content += "EMC\n"
    content += "/P <</MCID 1>> BDC\n"
    content += "BT /F1 12 Tf 72 560 Td (A paragraph) Tj ET\n"
    content += "EMC\n"
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("StructTreeRoot"): .reference(PDFObjectID(3)),
        PDFName("MarkInfo"): .dictionary([PDFName("Marked"): .boolean(true)]),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("StructTreeRoot")),
        PDFName("ParentTree"): .reference(PDFObjectID(8)),
        PDFName("ParentTreeNextKey"): .integer(1),
        PDFName("K"): .array([.reference(PDFObjectID(20)), .reference(PDFObjectID(21))]),
      ]),
      PDFObjectID(4): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))]),
          PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(7))]),
        ]),
        PDFName("Contents"): .reference(PDFObjectID(5)),
        PDFName("StructParents"): .integer(0),
      ]),
      PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      PDFObjectID(6): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ]),
      PDFObjectID(7): .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("BitsPerComponent"): .integer(8),
          ], bytes: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]))),
    ]
    var figure: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("Figure")),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("Pg"): .reference(PDFObjectID(4)),
      PDFName("K"): .integer(0),
    ]
    if let alt { figure[PDFName("Alt")] = .string(Data(alt.utf8)) }
    objects[PDFObjectID(20)] = .dictionary(figure)
    objects[PDFObjectID(21)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("P")),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("Pg"): .reference(PDFObjectID(4)),
      PDFName("K"): .integer(1),
    ])
    objects[PDFObjectID(8)] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0), .array([.reference(PDFObjectID(20)), .reference(PDFObjectID(21))]),
      ])
    ])
    return PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  @Test func figuresWithoutAltTextAreErrorsAndAltPresenceIsInfo() throws {
    let without = taggedFixture(alt: nil)
    let pageIDs = try PDFPageTree.pageIDs(in: without)
    let audit = PDFAccessibilityAudit.audit(without, pageIDs: pageIDs)
    #expect(
      audit.findings.contains { $0.rule == "Figure alternate text" && $0.severity == .error })
    #expect(!audit.passesMachineChecks)

    let with = taggedFixture(alt: "A red square")
    let withAudit = PDFAccessibilityAudit.audit(with, pageIDs: pageIDs)
    #expect(
      withAudit.findings.contains { $0.rule == "Figure alternate text" && $0.severity == .info })
    #expect(withAudit.findings.contains { $0.rule == "Structure tree" && $0.severity == .info } == false)
  }

  @Test func untaggedDocumentsFailStructureChecks() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let audit = PDFAccessibilityAudit.audit(parsed.graph, pageIDs: parsed.pageIDs)
    #expect(audit.findings.contains { $0.rule == "Structure tree" && $0.severity == .error })
    #expect(!audit.passesMachineChecks)
    let report = audit.report()
    #expect(report.contains("Automated checks cannot prove accessibility"))
    #expect(report.contains("Human review required"))
    #expect(audit.humanReviewRequirements.count == 7)
    // Rendering is explicitly not evidence.
    #expect(audit.findings.contains { $0.rule == "Rendering" })
  }

  @Test func taggedDocumentsReportLanguageAndStructure() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let audit = PDFAccessibilityAudit.audit(parsed.graph, pageIDs: parsed.pageIDs)
    // The tagged fixture has a structure tree.
    #expect(!audit.findings.contains { $0.rule == "Structure tree" && $0.severity == .error })
    // Language presence is reported either way, never assumed.
    #expect(audit.findings.contains { $0.rule == "Language" })
    #expect(audit.report().contains("PDF/UA-oriented"))
  }

  @Test func independentUAValidationRunsWhenAvailable() throws {
    guard FileManager.default.isExecutableFile(atPath: ArchivalDerivative.defaultValidatorPath)
    else { return }
    let graph = taggedFixture(alt: "A red square")
    let data = try PDFWriter.write(graph)
    let result = try #require(ArchivalDerivative.validateAccessibility(data))
    #expect(result.validator == "veraPDF")
    #expect(result.profileName.contains("UA"))
    let report = result.report()
    #expect(report.contains("veraPDF"))
    #expect(report.contains("No PDF/A identifier is written by this app"))
    // The verdict is recorded as-is; automated validation alone never proves
    // accessibility, which the audit report states separately.
    if !result.isCompliant {
      #expect(result.failedRules > 0)
    }
  }
}
