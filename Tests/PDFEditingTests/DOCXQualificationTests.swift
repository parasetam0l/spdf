import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// EXP-01: DOCX reconstruction qualification scored per document class with
/// four separate dimensions and attached limitations.
@Suite("DOCX qualification")
struct DOCXQualificationTests {
  // MARK: - Fixtures

  /// Two pages with headings, prose, lists, a ruled table, a text box, a
  /// footnote line and repeated header/footer bands.
  private func richLayoutFixture() -> PDFGraph {
    var pageOne = ""
    pageOne += "1 w 0 0 0 RG\n"
    pageOne += "55 525 120 45 re S\n175 525 120 45 re S\n"
    pageOne += "55 485 120 45 re S\n175 485 120 45 re S\n"
    pageOne += "55 445 120 45 re S\n175 445 120 45 re S\n"
    pageOne += "380 280 160 60 re S\n"
    pageOne += "BT /F1 20 Tf 72 740 Td (Quarterly Report) Tj ET\n"
    pageOne += "BT /F1 12 Tf 72 700 Td (Plain intro line for prose scoring with a wide width) Tj ET\n"
    pageOne += "BT /F1 12 Tf 72 660 Td (- First bullet) Tj ET\n"
    pageOne += "BT /F1 12 Tf 72 640 Td (- Second bullet) Tj ET\n"
    pageOne += "BT /F1 12 Tf 72 620 Td (1. Alpha) Tj ET\n"
    pageOne += "BT /F1 12 Tf 72 600 Td (2. Beta) Tj ET\n"
    pageOne += "BT /F1 12 Tf 65 555 Td (Name) Tj ET\n"
    pageOne += "BT /F1 12 Tf 65 540 Td (Item) Tj ET\n"
    pageOne += "BT /F1 12 Tf 185 555 Td (Value) Tj ET\n"
    pageOne += "BT /F1 12 Tf 185 540 Td (Amount) Tj ET\n"
    pageOne += "BT /F1 12 Tf 65 515 Td (Revenue) Tj ET\n"
    pageOne += "BT /F1 12 Tf 65 500 Td (Quarter) Tj ET\n"
    pageOne += "BT /F1 12 Tf 185 515 Td (10) Tj ET\n"
    pageOne += "BT /F1 12 Tf 185 500 Td (20) Tj ET\n"
    pageOne += "BT /F1 12 Tf 65 475 Td (Cost) Tj ET\n"
    pageOne += "BT /F1 12 Tf 65 460 Td (Total) Tj ET\n"
    pageOne += "BT /F1 12 Tf 185 475 Td (4) Tj ET\n"
    pageOne += "BT /F1 12 Tf 185 460 Td (8) Tj ET\n"
    pageOne += "BT /F1 12 Tf 400 300 Td (Boxed callout text) Tj ET\n"
    pageOne += "BT /F1 9 Tf 72 60 Td (1 A footnote definition) Tj ET\n"
    pageOne += "BT /F1 9 Tf 72 760 Td (REPORT HEADER) Tj ET\n"
    pageOne += "BT /F1 9 Tf 72 30 Td (CONFIDENTIAL FOOTER) Tj ET\n"
    var pageTwo = ""
    pageTwo += "BT /F1 9 Tf 72 760 Td (REPORT HEADER) Tj ET\n"
    pageTwo += "BT /F1 12 Tf 72 700 Td (Second page text) Tj ET\n"
    pageTwo += "BT /F1 9 Tf 72 30 Td (CONFIDENTIAL FOOTER) Tj ET\n"
    return fixtureGraph([pageOne, pageTwo])
  }

  private func fixtureGraph(_ contents: [String]) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(contents.count)),
        PDFName("Kids"): .array([]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ]),
    ]
    var kids: [PDFValue] = []
    for (index, content) in contents.enumerated() {
      let pageID = PDFObjectID(10 + index * 2)
      let contentID = PDFObjectID(11 + index * 2)
      kids.append(.reference(pageID))
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
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
    }
    if case .dictionary(var pages)? = objects[PDFObjectID(2)] {
      pages[PDFName("Kids")] = .array(kids)
      objects[PDFObjectID(2)] = .dictionary(pages)
    }
    return PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func parsedGraph(_ data: Data) throws -> (PDFGraph, [PDFObjectID]) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, parsed.pageIDs)
  }

  // MARK: - Dimension separation

  @Test func fourDimensionsAreScoredSeparatelyAndOfficesStayAttached() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let bytesBefore = try PDFWriter.write(graph)
    let expectation = DOCXQualificationExpectation.default(
      for: .baselineProse,
      requiredTextFragments: ["Quarterly Report", "Plain intro line"])
    let result = try DOCXQualification.qualify(
      documentClass: .baselineProse, expectation: expectation,
      in: graph, pageIDs: pageIDs)

    #expect(result.dimensionScores.count == 4)
    #expect(Set(result.dimensionScores.map(\.dimension)) == Set(DOCXQualificationDimension.allCases))
    #expect(result.dimensionScores.allSatisfy { $0.score != nil })
    #expect(result.dimension(.textCompleteness)?.status == .measured)
    #expect(result.dimension(.editability)?.status == .measured)
    #expect(result.dimension(.structure)?.status == .measured)
    #expect(result.dimension(.renderedLayout)?.status == .measuredProxy)
    #expect(result.officeApplicationStatus == .measuredProxy)
    #expect(result.attachedLimitations.contains(DOCXQualification.officeApplicationLimitation))
    #expect(result.attachedLimitations.contains(DOCXQualification.reconstructionOnlyLimitation))
    #expect(result.attachedLimitations.contains { $0.contains("intended Office applications") })
    // Repeated header/footer bands are deduplicated and list markers become
    // list semantics, so the honest body/dimension score is below 1.0.
    #expect((result.dimension(.textCompleteness)?.score ?? 0) > 0.8)
    // Qualification is read-only.
    let bytesAfter = try PDFWriter.write(graph)
    #expect(bytesAfter == bytesBefore)
  }

  @Test func listsAndHeadingsAreScoredByStructureChecks() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let expectation = DOCXQualificationExpectation.default(
      for: .lists, requiredTextFragments: ["First bullet", "Second bullet"])
    let result = try DOCXQualification.qualify(
      documentClass: .lists, expectation: expectation, in: graph, pageIDs: pageIDs)
    #expect(result.listItemCount >= 2)
    #expect(result.headingCount >= 1)
    #expect(result.dimension(.structure)?.score == 1.0)
  }

  @Test func complexTablesAreScoredWithRowsAndColumns() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let expectation = DOCXQualificationExpectation.default(
      for: .complexTables, requiredTextFragments: ["Revenue", "Name"])
    let result = try DOCXQualification.qualify(
      documentClass: .complexTables, expectation: expectation, in: graph, pageIDs: pageIDs)
    #expect(result.tableCount >= 1)
    #expect(result.dimension(.structure)?.score == 1.0)
    #expect(result.findings.contains { $0.contains("largest reconstructed table") })
  }

  @Test func headerFooterBandsAreScored() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let expectation = DOCXQualificationExpectation.default(for: .headersFooters)
    let result = try DOCXQualification.qualify(
      documentClass: .headersFooters, expectation: expectation, in: graph, pageIDs: pageIDs)
    #expect(result.dimension(.structure)?.score == 1.0)
    #expect(result.findings.allSatisfy { !$0.contains("header band") && !$0.contains("footer band") })
  }

  @Test func textBoxesAndFootnotesStayEditableText() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let boxes = try DOCXQualification.qualify(
      documentClass: .textBoxes,
      expectation: DOCXQualificationExpectation.default(
        for: .textBoxes, requiredTextFragments: ["Boxed callout text"]),
      in: graph, pageIDs: pageIDs)
    #expect(boxes.dimension(.structure)?.score == 1.0)
    #expect(boxes.appearanceImageCount == 0)
    #expect(boxes.attachedLimitations.contains { $0.contains("ordinary editable paragraphs") })

    let footnotes = try DOCXQualification.qualify(
      documentClass: .footnotes,
      expectation: DOCXQualificationExpectation.default(
        for: .footnotes, requiredTextFragments: ["A footnote definition"]),
      in: graph, pageIDs: pageIDs)
    #expect(footnotes.dimension(.structure)?.score == 1.0)
    #expect(footnotes.attachedLimitations.contains { $0.contains("ordinary paragraphs") })
  }

  @Test func columnsFixtureIsScoredByTheColumnClass() throws {
    let (graph, pageIDs) = try parsedGraph(PDFFixtures.twoColumnPages())
    let expectation = DOCXQualificationExpectation.default(
      for: .columns, requiredTextFragments: ["Left one", "Right one"])
    let result = try DOCXQualification.qualify(
      documentClass: .columns, expectation: expectation, in: graph, pageIDs: pageIDs)
    #expect(result.dimension(.textCompleteness)?.score != nil)
    // The reconstruction either detects two columns or records the limitation;
    // per-class structure score is always measured (never asserted blindly).
    let structure = try #require(result.dimension(.structure))
    #expect(structure.status == .measured)
    #expect(!structure.findings.contains { $0.contains("Readable block output") })
    #expect(result.attachedLimitations.contains { $0.contains("columns") })
  }

  @Test func imageClassCountsEditableImageBlocks() throws {
    let (graph, pageIDs) = try parsedGraph(PDFFixtures.imagePages())
    let expectation = DOCXQualificationExpectation.default(for: .images)
    let result = try DOCXQualification.qualify(
      documentClass: .images, expectation: expectation, in: graph, pageIDs: pageIDs)
    #expect(result.imageBlockCount >= 1)
    #expect(result.dimension(.structure)?.score == 1.0)
    #expect(result.dimension(.editability) != nil)
  }

  @Test func markdownAndJSONReportsCarryScoresAndLimitations() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let result = try DOCXQualification.qualify(
      documentClass: .baselineProse,
      expectation: DOCXQualificationExpectation.default(
        for: .baselineProse, requiredTextFragments: ["Quarterly Report"]),
      in: graph, pageIDs: pageIDs)
    let markdown = DOCXQualification.markdownReport([result])
    #expect(markdown.contains("# DOCX reconstruction qualification (EXP-01)"))
    #expect(markdown.contains("| Text completeness |"))
    #expect(markdown.contains("| Rendered layout |"))
    #expect(markdown.contains("Limitations attached to this output:"))
    #expect(markdown.contains("intended Office applications"))

    let data = try #require(result.json().data(using: .utf8))
    let object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["documentClass"] as? String == "baselineProse")
    #expect(object["officeApplicationStatus"] as? String == "measuredProxy")
    let dimensions = try #require(object["dimensions"] as? [[String: Any]])
    #expect(dimensions.count == 4)
    #expect(dimensions.map { $0["dimension"] as? String }.compactMap { $0 }.sorted()
      == DOCXQualificationDimension.allCases.map(\.rawValue).sorted())
    #expect((object["attachedLimitations"] as? [String] ?? []).contains { $0.contains("Office") })
  }

  @Test func reportNeverPresentsOfficesAsExecuted() throws {
    let graph = richLayoutFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let result = try DOCXQualification.qualify(
      documentClass: .textBoxes, expectation: nil, in: graph, pageIDs: pageIDs)
    let markdown = DOCXQualification.markdownReport([result])
    // The scorecard states the local-proxy status instead of claiming Word.
    #expect(markdown.contains("measured (local proxy)"))
    #expect(!markdown.contains("Office verified"))
    #expect(result.reconstructionLimitations.count >= 0)
  }
}
