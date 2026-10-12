import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P36-001–P36-008: table detection profiles, geometry and ruled detection,
/// row/column inference, multi-line cells, merged cells, prose distinction,
/// structure tags, and OCR provenance.
@Suite("Table extraction")
struct TableExtractionTests {
  private func baseGraph(pageOne: String, pageTwo: String? = nil) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(pageTwo == nil ? 1 : 2),
        PDFName("Kids"): .array(
          pageTwo == nil
            ? [.reference(PDFObjectID(4))] : [.reference(PDFObjectID(4)), .reference(PDFObjectID(6))]),
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
      PDFObjectID(5): .stream(PDFStream(bytes: Data(pageOne.utf8))),
    ]
    if let pageTwo {
      objects[PDFObjectID(6)] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(7)),
      ])
      objects[PDFObjectID(7)] = .stream(PDFStream(bytes: Data(pageTwo.utf8)))
    }
    return PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  /// A 2×2 grid of multi-line cells under a wide heading (text geometry only).
  private func geometryFixture() -> PDFGraph {
    var content = ""
    content += "BT /F1 14 Tf 72 720 Td (Table of quarterly results) Tj ET\n"
    content += "BT /F1 12 Tf 72 660 Td (Name) Tj ET\n"
    content += "BT /F1 12 Tf 72 644 Td (Ada) Tj ET\n"
    content += "BT /F1 12 Tf 220 660 Td (Role) Tj ET\n"
    content += "BT /F1 12 Tf 220 644 Td (Engineer) Tj ET\n"
    content += "BT /F1 12 Tf 72 600 Td (City) Tj ET\n"
    content += "BT /F1 12 Tf 72 584 Td (London) Tj ET\n"
    content += "BT /F1 12 Tf 220 600 Td (Team) Tj ET\n"
    content += "BT /F1 12 Tf 220 584 Td (Platform) Tj ET\n"
    return baseGraph(pageOne: content)
  }

  /// A ruled 2×2 grid whose top row is merged (no middle vertical rule).
  private func ruledFixture(includeText: Bool = true) -> PDFGraph {
    var content = "1 w 0 0 0 RG\n"
    content += "72 600 100 40 re S\n"
    content += "172 600 100 40 re S\n"
    content += "72 640 200 40 re S\n"
    if includeText {
      content += "BT /F1 12 Tf 90 615 Td (Left) Tj ET\n"
      content += "BT /F1 12 Tf 200 615 Td (Right) Tj ET\n"
      content += "BT /F1 12 Tf 90 655 Td (Merged header spanning) Tj ET\n"
    }
    return baseGraph(pageOne: content)
  }

  // MARK: - P36-001/P36-003/P36-004/P36-005/P36-006

  @Test func geometryDetectionInfersRowsColumnsAndMultiLineCells() throws {
    let graph = geometryFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let tables = try TableExtraction.tables(pageIDs: pageIDs, in: graph)
    #expect(tables.count == 1)
    let table = try #require(tables.first)
    #expect(table.detection == .geometry)
    #expect(table.rowCount == 2)
    #expect(table.columnCount == 2)
    #expect(table.confidence >= 0.6)
    #expect(table.limitations.isEmpty)
    // Multi-line cell text keeps its reading order (P36-004).
    #expect(table.cell(row: 0, column: 0)?.text == "Name\nAda")
    #expect(table.cell(row: 1, column: 1)?.text == "Team\nPlatform")
    #expect(table.cell(row: 0, column: 0)?.provenance == .text)
    // Every cell spans exactly one slot here.
    #expect(table.cells.allSatisfy { $0.rowSpan == 1 && $0.columnSpan == 1 })
    let grid = table.grid()
    #expect(grid[0][0] == "Name\nAda")
    #expect(grid[1][1] == "Team\nPlatform")
  }

  @Test func geometryDetectionRejectsMultiColumnProse() throws {
    // Narrow prose-like blocks that would classify as cells, under a very wide
    // title: two columns of multi-line, wordy blocks (P36-006).
    var content = "BT /F1 24 Tf 30 740 Td (Comprehensive multi-column prose demonstration title) Tj ET\n"
    for (column, x) in [(0, 72.0), (1, 340.0)] {
      _ = column
      content += "BT /F1 12 Tf \(Int(x)) 660 Td (one two three four five six) Tj ET\n"
      content += "BT /F1 12 Tf \(Int(x)) 644 Td (seven eight nine ten eleven) Tj ET\n"
      content += "BT /F1 12 Tf \(Int(x)) 600 Td (alpha beta gamma delta epsilon) Tj ET\n"
      content += "BT /F1 12 Tf \(Int(x)) 584 Td (zeta eta theta iota kappa) Tj ET\n"
    }
    let graph = baseGraph(pageOne: content)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let tables = try TableExtraction.tables(pageIDs: pageIDs, in: graph)
    #expect(tables.isEmpty)
  }

  // MARK: - P36-002/P36-005

  @Test func ruledDetectionBuildsCellsAndInfersMergedSpans() throws {
    let graph = ruledFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let tables = try TableExtraction.tables(
      pageIDs: pageIDs, in: graph, profile: TableDetectionProfile(mode: .ruled))
    #expect(tables.count == 1)
    let table = try #require(tables.first)
    #expect(table.detection == .ruled)
    #expect(table.rowCount == 2)
    #expect(table.columnCount == 2)
    #expect(table.confidence >= 0.6)
    // The header spans both columns because the middle rule is missing.
    let header = try #require(table.cell(row: 0, column: 0))
    #expect(header.columnSpan == 2)
    #expect(header.text == "Merged header spanning")
    #expect(table.cell(row: 0, column: 1) == nil)
    #expect(table.limitations.contains { $0.contains("Merged cells") })
    #expect(table.cell(row: 1, column: 0)?.text == "Left")
    #expect(table.cell(row: 1, column: 1)?.text == "Right")
    // The merged slot is explained by the span, not counted as empty.
    #expect(!table.limitations.contains { $0.contains("empty slot") })
    let grid = table.grid()
    #expect(grid[0][0] == "Merged header spanning")
    #expect(grid[0][1] == nil)
  }

  @Test func ruledDetectionRespectsTheProfileGate() throws {
    let graph = ruledFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // A profile that demands more rows than the grid has returns nothing.
    let strict = TableDetectionProfile(mode: .ruled, minimumRows: 4)
    #expect(try TableExtraction.tables(pageIDs: pageIDs, in: graph, profile: strict).isEmpty)
  }

  // MARK: - P36-007

  @Test func taggedTablesUseStructureRoles() throws {
    // A page with four marked-content cells arranged as a 2×2 tagged table.
    var content = ""
    let positions = [(72, 660), (220, 660), (72, 600), (220, 600)]
    for (mcid, position) in positions.enumerated() {
      content += "/TD <</MCID \(mcid)>> BDC\n"
      content += "BT /F1 12 Tf \(position.0) \(position.1) Td (Tagged \(mcid)) Tj ET\n"
      content += "EMC\n"
    }
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
        PDFName("K"): .array([.reference(PDFObjectID(40))]),
      ]),
      PDFObjectID(4): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))])
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
    ]
    // Cell elements (K = MCID), row elements (K = cells), table (K = rows).
    var tdIDs: [PDFObjectID] = []
    for mcid in 0..<4 {
      let id = PDFObjectID(20 + mcid)
      tdIDs.append(id)
      objects[id] = .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("TD")),
        PDFName("P"): .reference(PDFObjectID(30 + mcid / 2)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .integer(Int64(mcid)),
      ])
    }
    for row in 0..<2 {
      objects[PDFObjectID(30 + row)] = .dictionary([
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("TR")),
        PDFName("P"): .reference(PDFObjectID(40)),
        PDFName("Pg"): .reference(PDFObjectID(4)),
        PDFName("K"): .array([.reference(tdIDs[row * 2]), .reference(tdIDs[row * 2 + 1])]),
      ])
    }
    objects[PDFObjectID(40)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("Table")),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("Pg"): .reference(PDFObjectID(4)),
      PDFName("K"): .array([.reference(PDFObjectID(30)), .reference(PDFObjectID(31))]),
    ])
    objects[PDFObjectID(8)] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0), .array(tdIDs.map { .reference($0) }),
      ])
    ])
    let graph = PDFGraph(
      objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let tables = try TableExtraction.tables(pageIDs: pageIDs, in: graph)
    let tagged = try #require(tables.first { $0.detection == .tagged })
    #expect(tagged.rowCount == 2)
    #expect(tagged.columnCount == 2)
    #expect(tagged.confidence == 0.95)
    #expect(tagged.cell(row: 0, column: 0)?.text == "Tagged 0")
    #expect(tagged.cell(row: 0, column: 1)?.text == "Tagged 1")
    #expect(tagged.cell(row: 1, column: 0)?.text == "Tagged 2")
    #expect(tagged.cell(row: 1, column: 1)?.text == "Tagged 3")
    #expect(tagged.cells.allSatisfy { $0.provenance == .text })
  }

  // MARK: - P36-008

  @Test func ocrDerivedCellsKeepRecognitionProvenance() throws {
    // The page has rules but no text; recognized lines (from the OCR job) are
    // supplied explicitly and keep their provenance and confidence.
    let graph = ruledFixture(includeText: false)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // Without recognized lines there is nothing to extract.
    let plain = try TableExtraction.tables(
      pageIDs: pageIDs, in: graph, profile: TableDetectionProfile(mode: .ruled))
    #expect(plain.isEmpty)

    let tables = try TableExtraction.tables(
      pageIDs: pageIDs, in: graph, profile: TableDetectionProfile(mode: .ruled),
      recognizedLines: [
        0: [
          SearchableTextLine(text: "Left", rect: [90, 610, 140, 630], confidence: 0.9),
          SearchableTextLine(text: "Right", rect: [200, 610, 260, 630], confidence: 0.85),
          SearchableTextLine(
            text: "Merged header spanning", rect: [90, 650, 250, 670], confidence: 0.8),
        ]
      ])
    let table = try #require(tables.first)
    #expect(table.cell(row: 1, column: 0)?.text == "Left")
    #expect(table.cell(row: 0, column: 0)?.text == "Merged header spanning")
    // Every cell's text comes from recognition (P36-008) with its confidence.
    #expect(table.cells.allSatisfy { $0.provenance == .ocr })
    #expect(table.cell(row: 1, column: 0)?.confidence == 0.9)
  }

  @Test func textCellsStayTextWithoutRecognizedLines() throws {
    let graph = ruledFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let tables = try TableExtraction.tables(
      pageIDs: pageIDs, in: graph, profile: TableDetectionProfile(mode: .ruled),
      recognizedLines: [0: [SearchableTextLine(text: "Ignored", rect: [400, 700, 500, 720])]])
    let table = try #require(tables.first)
    // Lines outside the cells change nothing.
    #expect(table.cells.allSatisfy { $0.provenance == .text })
    #expect(table.cell(row: 1, column: 0)?.text == "Left")
  }
}
