import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// A11Y-07: accessible reading/reflow/high-contrast access and verification
/// that tags survive text edits, OCR, page assembly and exports.
@Suite("Accessible reading and tag preservation")
struct AccessibleReadingTests {
  // MARK: - Fixtures

  /// A tagged page with heading, paragraph, list, table and figure structure.
  private func richTaggedFixture() -> PDFGraph {
    let content = """
      /H1 <</MCID 0>> BDC
      BT /F1 20 Tf 42 710 Td (Report heading) Tj ET
      EMC
      /P <</MCID 1>> BDC
      BT /F1 12 Tf 42 660 Td (Intro paragraph) Tj ET
      EMC
      /LI1 <</MCID 2>> BDC
      BT /F1 12 Tf 42 620 Td (- First item) Tj ET
      EMC
      /LI2 <</MCID 3>> BDC
      BT /F1 12 Tf 42 600 Td (- Second item) Tj ET
      EMC
      /TH1 <</MCID 4>> BDC
      BT /F1 12 Tf 60 540 Td (Name) Tj ET
      EMC
      /TH2 <</MCID 5>> BDC
      BT /F1 12 Tf 160 540 Td (Value) Tj ET
      EMC
      /TD1 <</MCID 6>> BDC
      BT /F1 12 Tf 60 520 Td (Revenue) Tj ET
      EMC
      /TD2 <</MCID 7>> BDC
      BT /F1 12 Tf 160 520 Td (10) Tj ET
      EMC
      /Figure <</MCID 8>> BDC
      q 100 0 0 100 380 380 cm /Im1 Do Q
      EMC

      """
    let objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
        PDFName("StructTreeRoot"): .reference(PDFObjectID(3)),
        PDFName("MarkInfo"): .dictionary([PDFName("Marked"): .boolean(true)]),
        PDFName("Lang"): .string(Data("en-US".utf8)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("StructTreeRoot")),
        PDFName("ParentTree"): .reference(PDFObjectID(40)),
        PDFName("ParentTreeNextKey"): .integer(1),
        PDFName("K"): .array([
          .reference(PDFObjectID(20)), .reference(PDFObjectID(21)),
          .reference(PDFObjectID(22)), .reference(PDFObjectID(27)),
        ]),
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
      // Heading 0
      PDFObjectID(20): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("H1")),
        PDFName("P"): .reference(PDFObjectID(3)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(0),
      ]),
      // Paragraph 1
      PDFObjectID(21): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("P")),
        PDFName("P"): .reference(PDFObjectID(3)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(1),
      ]),
      // List 2
      PDFObjectID(22): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("L")),
        PDFName("P"): .reference(PDFObjectID(3)),
        PDFName("K"): .array([.reference(PDFObjectID(23)), .reference(PDFObjectID(24))]),
      ]),
      PDFObjectID(23): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("LI")),
        PDFName("P"): .reference(PDFObjectID(22)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(2),
      ]),
      PDFObjectID(24): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("LI")),
        PDFName("P"): .reference(PDFObjectID(22)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(3),
      ]),
      // Table
      PDFObjectID(27): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("Table")),
        PDFName("P"): .reference(PDFObjectID(3)),
        PDFName("K"): .array([.reference(PDFObjectID(28))]),
      ]),
      PDFObjectID(28): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("TR")),
        PDFName("P"): .reference(PDFObjectID(27)),
        PDFName("K"): .array([
          .reference(PDFObjectID(25)), .reference(PDFObjectID(26)),
        ]),
      ]),
      PDFObjectID(25): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("TH")),
        PDFName("P"): .reference(PDFObjectID(28)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(4),
      ]),
      PDFObjectID(26): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("TD")),
        PDFName("P"): .reference(PDFObjectID(28)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(5),
      ]),
      // Figure 8
      PDFObjectID(29): .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("Figure")),
        PDFName("P"): .reference(PDFObjectID(3)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("Alt"): .string(Data("A green square".utf8)),
        PDFName("K"): .integer(8),
      ]),
      PDFObjectID(40): .dictionary([
        PDFName("Nums"): .array([
          .integer(0), .array([
            .reference(PDFObjectID(20)), .reference(PDFObjectID(21)),
            .reference(PDFObjectID(22)), .reference(PDFObjectID(23)),
            .reference(PDFObjectID(24)), .reference(PDFObjectID(25)),
            .reference(PDFObjectID(26)), .reference(PDFObjectID(27)),
            .reference(PDFObjectID(28)), .reference(PDFObjectID(29)),
          ]),
        ])
      ]),
    ]
    // The table and figure need to be reachable from the root.
    var patched = objects
    if case .dictionary(var root)? = patched[PDFObjectID(3)] {
      root[PDFName("K")] = .array([
        .reference(PDFObjectID(20)), .reference(PDFObjectID(21)),
        .reference(PDFObjectID(22)), .reference(PDFObjectID(27)),
        .reference(PDFObjectID(29)),
      ])
      patched[PDFObjectID(3)] = .dictionary(root)
    }
    return PDFGraph(
      version: "1.7", objects: patched,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  /// A tagged page whose only paint is an image (a scan) with a Figure tag.
  private func taggedScanFixture() -> PDFGraph {
    let content = """
      /Figure <</MCID 0>> BDC
      q 400 0 0 300 72 400 cm /Im1 Do Q
      EMC

      """
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
          PDFName("StructTreeRoot"): .reference(PDFObjectID(3)),
          PDFName("MarkInfo"): .dictionary([PDFName("Marked"): .boolean(true)]),
          PDFName("Lang"): .string(Data("en-US".utf8)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("StructTreeRoot")),
          PDFName("ParentTree"): .reference(PDFObjectID(10)),
          PDFName("ParentTreeNextKey"): .integer(1),
          PDFName("K"): .array([.reference(PDFObjectID(20))]),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(7))]),
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
          PDFName("StructParents"): .integer(0),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(7): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Image")),
              PDFName("Width"): .integer(2), PDFName("Height"): .integer(2),
              PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
              PDFName("BitsPerComponent"): .integer(8),
            ], bytes: Data(repeating: 128, count: 12))),
        PDFObjectID(20): .dictionary([
          PDFName("Type"): .name(PDFName("StructElem")),
          PDFName("S"): .name(PDFName("Figure")),
          PDFName("P"): .reference(PDFObjectID(3)),
          PDFName("Pg"): .reference(PDFObjectID(4)),
          PDFName("Alt"): .string(Data("Scanned document page".utf8)),
          PDFName("K"): .integer(0),
        ]),
        PDFObjectID(10): .dictionary([
          PDFName("Nums"): .array([
            .integer(0), .array([.reference(PDFObjectID(20))]),
          ])
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  /// A single page with black, red, light gray and large gray text.
  private func contrastFixture() -> PDFGraph {
    let content = """
      0 g BT /F1 12 Tf 72 700 Td (Black text) Tj ET
      1 0 0 rg BT /F1 12 Tf 72 680 Td (Red text) Tj ET
      0.9 g BT /F1 12 Tf 72 660 Td (Faint gray text) Tj ET
      0.9 g BT /F1 20 Tf 72 630 Td (Large faint gray) Tj ET

      """
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

  // MARK: - Reading model

  @Test func taggedDocumentYieldsOrderedNavigationModel() throws {
    let graph = richTaggedFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let model = try AccessibleReadingBuilder.build(in: graph, pageIDs: pageIDs)

    #expect(model.isTagged)
    #expect(model.language == "en-US")
    let roles = model.items.map(\.role)
    #expect(roles == [.heading, .paragraph, .listItem, .listItem, .table, .tableCell, .tableCell, .figure])
    #expect(model.headings.first?.text == "Report heading")
    #expect(model.headings.first?.level == 1)
    #expect(model.items.filter { $0.role == .listItem }.map(\.text) == ["- First item", "- Second item"])
    #expect(model.items.filter { $0.role == .tableCell }.map(\.text) == ["Name", "Value"])
    #expect(model.figures.first?.label == "A green square")
    // The synthetic fixture may carry informational structure issues; the
    // reading model must not silently lose resolvable elements.
    #expect(!model.structureIssueDescriptions.contains { $0.hasPrefix("danglingReference") })

    let script = model.voiceOverNavigationScript()
    #expect(script.contains { $0.contains("Rotor > Headings (1)") })
    #expect(script.contains { $0.contains("heading level 1, Report heading") })
    #expect(script.contains { $0.contains("Rotor > Tables (1)") })
    #expect(script.contains { $0.contains("Figures with alternate text (1)") })
    #expect(script.contains { $0.contains("en-US") })

    let reflowed = model.reflowedText(width: 40)
    #expect(reflowed.contains("# Report heading"))
    #expect(reflowed.contains("- First item"))
    #expect(reflowed.split(separator: "\n").allSatisfy { $0.count <= 40 })
  }

  @Test func untaggedDocumentFallsBackToGeometricOrderWithLimitation() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let model = try AccessibleReadingBuilder.build(
      in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(!model.isTagged)
    #expect(!model.items.isEmpty)
    #expect(model.items.allSatisfy { $0.role == .paragraph })
    #expect(model.limitations.contains { $0.contains("not tagged") })
    #expect(model.limitations.contains { $0.contains("Lang") })
    #expect(model.plainText.contains("sPDF Editor fixture"))
  }

  // MARK: - High contrast

  @Test func highContrastReportsFaintTextWithWcagThresholds() throws {
    let graph = contrastFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let report = try HighContrastAccess.audit(in: graph, pageIDs: pageIDs)
    #expect(report.checkedRunCount == 4)
    // Pure red is about 4.0:1 on white (a warning), the two faint grays fail.
    #expect(report.findings.count == 3)
    let faint = report.findings.filter { $0.snippet.contains("gray") }
    #expect(faint.count == 2)
    #expect(faint.allSatisfy { $0.severity == .failure })
    #expect(faint.contains { $0.fontSize == 12 && $0.threshold == 4.5 })
    #expect(faint.contains { $0.fontSize == 20 && $0.threshold == 3.0 })
    #expect(report.findings.contains { $0.snippet.contains("Red") && $0.severity == .warning })
    #expect(!report.passesMachineChecks)

    // Black on white is the maximum WCAG ratio; saturated red is below 4.5:1.
    #expect(abs(HighContrastAccess.contrastRatio(
      foreground: [0, 0, 0], background: [1, 1, 1]) - 21) < 0.01)
    #expect(HighContrastAccess.contrastRatio(
      foreground: [1, 0, 0], background: [1, 1, 1]) < 4.5)
    #expect(HighContrastAccess.suggestedOverride(background: [1, 1, 1]) == [0, 0, 0])
    #expect(report.report().contains("Contrast is computed from owned text-run color state"))
  }

  // MARK: - Tag preservation

  @Test func textEditKeepsEveryElementAndMcidMapping() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageIDs = parsed.pageIDs
    let before = try TagSnapshot.capture(in: parsed.graph, pageIDs: pageIDs)
    let content = try PageContent.load(pageID: pageIDs[0], in: parsed.graph)
    let runs = try TextRunIndexer.runs(in: content, graph: parsed.graph)
    let paragraphIndex = try #require(
      runs.firstIndex { $0.text.contains("Tagged paragraph") })
    let command = ReplaceTextCommand(
      pageID: pageIDs[0], runIndex: paragraphIndex,
      replacement: "Edited paragraph text")
    let edited = try command.apply(to: parsed.graph)
    let after = try TagSnapshot.capture(in: edited, pageIDs: pageIDs)

    #expect(after.contentPieces == before.contentPieces)
    let report = TagPreservationVerifier.verify(
      operation: .textEdit, before: before, after: after)
    #expect(report.status == .preserved)
    #expect(report.isAcceptable)
    #expect(report.findings.contains { $0.contains("MCID mapping is unchanged") })

    let model = try AccessibleReadingBuilder.build(in: edited, pageIDs: pageIDs)
    #expect(model.items.contains { $0.text.contains("Edited paragraph text") })
  }

  @Test func ocrLayerStaysOutsideStructureAndNeedsReview() throws {
    let graph = taggedScanFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let before = try TagSnapshot.capture(in: graph, pageIDs: pageIDs)
    #expect(before.isTagged)
    #expect(before.generatedOCRPages.isEmpty)

    let command = AddSearchableTextLayerCommand(
      pageID: pageIDs[0],
      lines: [SearchableTextLine(text: "Recognized scan text", rect: [90, 500, 340, 520])])
    let withLayer = try command.apply(to: graph)
    let after = try TagSnapshot.capture(in: withLayer, pageIDs: pageIDs)
    #expect(after.generatedOCRPages == [0])

    let report = TagPreservationVerifier.verify(
      operation: .ocr, before: before, after: after)
    #expect(report.status == .needsReview)
    #expect(report.findings.contains { $0.contains("outside the structure tree") })

    let model = try AccessibleReadingBuilder.build(in: withLayer, pageIDs: pageIDs)
    #expect(model.limitations.contains { $0.contains("OCR") && $0.contains("outside the document structure tree") })
    #expect(model.items.contains { $0.isGeneratedOCR && $0.text.contains("Recognized scan text") })
  }

  @Test func pageAssemblyDisclosesNewUntaggedPageCoverage() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let before = try TagSnapshot.capture(in: parsed.graph, pageIDs: parsed.pageIDs)
    let command = DuplicatePagesCommand(pageIDs: parsed.pageIDs)
    let duplicated = try command.apply(to: parsed.graph)
    let pageIDs = try PDFPageTree.pageIDs(in: duplicated)
    #expect(pageIDs.count == 2)
    let after = try TagSnapshot.capture(in: duplicated, pageIDs: pageIDs)
    let report = TagPreservationVerifier.verify(
      operation: .pageAssembly, before: before, after: after)
    #expect(report.status == .needsReview)
    #expect(report.findings.contains { $0.contains("Page count changed") })
    #expect(report.findings.contains { $0.contains("structure coverage") })
  }

  @Test func untaggedSourcesReportNoPreservableSemantics() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let before = try TagSnapshot.capture(in: parsed.graph, pageIDs: parsed.pageIDs)
    let report = TagPreservationVerifier.verify(
      operation: .textEdit, before: before, after: before)
    #expect(report.status == .untagged)
    #expect(report.findings.contains { $0.contains("no usable structure tree") })
    // A report never presents an untagged source as a pass.
    #expect(report.isAcceptable)
  }

  @Test func exportTextOrderIsVerifiedAgainstAccessibleOrder() throws {
    let graph = richTaggedFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let model = try AccessibleReadingBuilder.build(in: graph, pageIDs: pageIDs)
    let ordered = TagPreservationVerifier.verifyExportOrder(
      derivativeText: model.plainText, model: model)
    #expect(ordered.status == .preserved)
    #expect(ordered.findings.contains { $0.contains("accessible reading items appear in derivative order") })

    let shuffled = model.items.reversed().filter { !$0.isEmpty }
      .map(\.text).joined(separator: "\n")
    let reversed = TagPreservationVerifier.verifyExportOrder(
      derivativeText: shuffled, model: model)
    #expect(reversed.status != .preserved)
    #expect(reversed.findings.contains { $0.contains("Missing or out of order") })
    #expect(reversed.limitations.contains { $0.contains("structure") })
  }
}
