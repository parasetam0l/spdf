import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P19-020/P19-021/P19-022: list reconstruction with editable numbering,
/// table-cell grids edited independently, and manual grouping/splitting.
@Suite("Paragraph helpers")
struct ParagraphHelperTests {
  private func fixture(lines: [(String, Double, Double, Double)]) -> PDFGraph {
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

  private func pageText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    try PageTextLayout.build(pageID: pageID, in: graph).clusters.map(\.text).joined()
  }

  @Test func listDetectionAndRenumbering() throws {
    let graph = fixture(lines: [
      ("- First item", 72, 660, 12),
      ("- Second item", 72, 640, 12),
      ("- Third item", 72, 620, 12),
      ("1. Alpha", 72, 560, 12),
      ("2. Beta", 72, 540, 12),
      ("3. Gamma", 72, 520, 12),
    ])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let lists = ParagraphListReconstruction.lists(from: candidates)
    #expect(lists.count == 2)
    let bullets = try #require(lists.first { $0.style.kind == .bullet })
    #expect(bullets.items.count == 3)
    #expect(bullets.items.map(\.text) == ["First item", "Second item", "Third item"])
    #expect(bullets.items.map(\.marker) == ["-", "-", "-"])
    let ordered = try #require(lists.first { $0.style.kind == .ordered })
    #expect(ordered.items.count == 3)
    #expect(ordered.style.format == .arabic)
    #expect(ordered.style.start == 1)

    // Editable numbering: roman with a custom start and separator.
    let roman = ordered.renumbered(
      ParagraphListStyle(kind: .ordered, format: .upperRoman, separator: ")", start: 4))
    #expect(roman == ["IV) Alpha", "V) Beta", "VI) Gamma"])
    let letters = ordered.renumbered(
      ParagraphListStyle(kind: .ordered, format: .lowerAlpha, separator: ".", start: 27))
    #expect(letters == ["aa. Alpha", "ab. Beta", "ac. Gamma"])

    // Marker parsing covers the supported styles.
    #expect(ParagraphListReconstruction.marker(in: "- dash item")?.style.kind == .bullet)
    #expect(ParagraphListReconstruction.marker(in: "iv. roman")?.style.format == .lowerRoman)
    #expect(ParagraphListReconstruction.marker(in: "B) letter")?.style.format == .upperAlpha)
    #expect(ParagraphListReconstruction.marker(in: "plain text") == nil)

    // A renumbered item reflows through the normal command.
    let firstItem = try #require(ordered.items.first?.candidate)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: firstItem, replacement: roman[0],
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: graph)
    // The item's narrow box may wrap the marker from its text.
    let itemText = try pageText(edited, pageID)
    #expect(itemText.contains("IV)"))
    #expect(itemText.contains("Alpha"))
    #expect(itemText.contains("2. Beta"))

  }

  @Test func tableCellsFormAGridAndEditIndependently() throws {
    let graph = fixture(lines: [
      ("Table of quarterly results", 72, 720, 14),
      ("Name", 72, 660, 12),
      ("Ada", 72, 644, 12),
      ("Role", 220, 660, 12),
      ("Engineer", 220, 644, 12),
      ("City", 72, 600, 12),
      ("London", 72, 584, 12),
      ("Team", 220, 600, 12),
      ("Platform", 220, 584, 12),
    ])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let grid = TableCellReconstruction.grid(from: candidates)
    #expect(grid.cells.count == 4)
    #expect(grid.rowCount == 2)
    #expect(grid.columnCount == 2)
    let name = try #require(grid.cell(row: 0, column: 0))
    #expect(name.text == "Name\nAda")
    let team = try #require(grid.cell(row: 1, column: 1))
    #expect(team.text == "Team\nPlatform")
    // The cells are separate candidates, not one paragraph.
    #expect(Set(grid.cells.map(\.runIndices)).count == 4)

    // Editing one cell leaves the other three cells untouched.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: name,
          replacement: "Full name Ada Lovelace",
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: graph)
    let text = try pageText(edited, pageID)
    // The narrow cell wraps the replacement; the words are present.
    #expect(text.contains("Full"))
    #expect(text.contains("Lovelace"))
    #expect(text.contains("Engineer"))
    #expect(text.contains("London"))
    #expect(text.contains("Platform"))
  }

  @Test func manualGroupingAndSplitting() throws {
    // Two well-separated lines: two candidates by default.
    let graph = fixture(lines: [
      ("Separate first part", 42, 660, 12),
      ("Separate second part", 42, 600, 12),
    ])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let separate = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    #expect(separate.count == 2)
    let runIndices = separate.flatMap(\.runIndices)
    let merged = try ParagraphReconstruction.candidates(
      pageID: pageID, in: graph,
      grouping: ParagraphGrouping(merges: [Set(runIndices)]))
    #expect(merged.count == 1)
    let mergedCandidate = try #require(merged.first)
    #expect(mergedCandidate.lineIndices.count == 2)
    #expect(mergedCandidate.text.contains("Separate first part"))
    #expect(mergedCandidate.text.contains("Separate second part"))
    // The merged candidate reflows across both original lines.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: mergedCandidate,
          replacement: "Merged replacement text for the manual group.",
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: graph)
    let text = try pageText(edited, pageID)
    #expect(text.contains("Merged"))
    #expect(!text.contains("Separate first part"))

    // A three-line paragraph splits at a chosen line.
    let splitGraph = fixture(lines: [
      ("Line one of the block", 42, 660, 12),
      ("Line two of the block", 42, 640, 12),
      ("Line three of the block", 42, 620, 12),
    ])
    let splitPage = try PDFPageTree.pageIDs(in: splitGraph)[0]
    let whole = try ParagraphReconstruction.candidates(pageID: splitPage, in: splitGraph)
    #expect(whole.count == 1)
    let firstRun = try #require(whole.first?.runIndices.first)
    let split = try ParagraphReconstruction.candidates(
      pageID: splitPage, in: splitGraph,
      grouping: ParagraphGrouping(splits: [firstRun: 1]))
    #expect(split.count == 2)
    let head = try #require(split.first { $0.text.contains("Line one") })
    #expect(head.lineIndices.count == 1)
    let tail = try #require(split.first { $0.text.contains("Line two") })
    #expect(tail.lineIndices.count == 2)
    #expect(tail.text.contains("Line three"))
    // The split tail reflows on its own.
    let splitEdited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: splitPage, candidate: tail,
          replacement: "Split tail replacement text.",
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: splitGraph)
    let splitText = try pageText(splitEdited, splitPage)
    #expect(splitText.contains("Line one of the block"))
    #expect(splitText.contains("Split tail"))
  }
}
