import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P19-001–P19-006/P19-029: paragraph candidates from source-linked runs,
/// structure-guided boundaries, style-compatible grouping, alignment/indent/
/// spacing inference, flow versus label/cell classification, and the analysis
/// measurement.
@Suite("Paragraph reconstruction")
struct ParagraphReconstructionTests {
  private func fixture(lines: [(text: String, x: Double, y: Double, size: Double)]) -> PDFGraph {
    var content = Data()
    for line in lines {
      let escaped = line.text.replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)")
      content.append(
        Data(
          "BT /F1 \(line.size) Tf \(line.x) \(line.y) Td (\(escaped)) Tj ET\n".utf8))
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

  @Test func analysisFindsHeadingFlowingAndLabelParagraphs() throws {
    let graph = fixture(lines: [
      ("Quarterly Report", 42, 700, 24),
      ("First body line of the report.", 42, 660, 12),
      ("Second body line follows here.", 42, 640, 12),
      ("Third body line ends the block.", 42, 620, 12),
      ("Page 1", 500, 60, 12),
    ])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    for candidate in candidates {
      print("[debug] kind:", candidate.kind, "lines:", candidate.lineIndices.count, "text:", candidate.text.replacingOccurrences(of: "\n", with: " | "))
    }
    #expect(candidates.count == 3)
    let heading = try #require(candidates.first { $0.kind == .heading })
    #expect(heading.fontSize == 24)
    #expect(heading.text == "Quarterly Report")
    #expect(heading.structureRole == nil)
    let flowing = try #require(candidates.first { $0.kind == .flowing })
    #expect(flowing.lineIndices.count == 3)
    #expect(flowing.text.contains("Second body line"))
    #expect(abs(flowing.lineSpacing - 20) < 1.5)
    #expect(flowing.confidence >= 0.75)
    let label = try #require(candidates.first { $0.kind == .label })
    #expect(label.text == "Page 1")
    #expect(label.confidence < flowing.confidence)
    // Source links: every candidate maps to runs and clusters.
    #expect(!flowing.runIndices.isEmpty)
    #expect(flowing.clusterRange.count > 0)
  }

  @Test func structureRolesGuideParagraphBoundaries() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let candidates = try ParagraphReconstruction.candidates(
      pageID: parsed.pageIDs[0], in: parsed.graph)
    let heading = try #require(candidates.first { $0.structureRole == "H1" })
    #expect(heading.kind == .heading)
    #expect(heading.text == "Tagged heading")
    #expect(heading.confidence >= 0.9)
    let paragraph = try #require(candidates.first { $0.structureRole == "P" })
    #expect(paragraph.text == "Tagged paragraph text")
    // Tagged roles confirm boundaries even for single lines.
    #expect(candidates.contains { $0.structureRole == "P" })
  }

  @Test func narrowColumnsAreClassifiedAsTableCells() throws {
    let graph = fixture(lines: [
      ("Wide first line spanning most of the page width here.", 42, 700, 12),
      ("Wide second line also spanning most of the width.", 42, 680, 12),
      ("Cell", 60, 500, 12),
      ("Data", 60, 484, 12),
      ("Rows", 60, 468, 12),
    ])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let cell = try #require(candidates.first { $0.kind == .tableCell })
    #expect(cell.lineIndices.count == 3)
    #expect(cell.confidence < 0.6)
    #expect(candidates.contains { $0.kind == .flowing })
  }

  /// Two-pass fixture: measure each line's width with the same estimator the
  /// analysis uses, then position lines for exact alignment.
  private func alignedFixture(
    _ texts: [String], alignment: TextParagraphCandidate.Alignment
  ) throws -> PDFGraph {
    let probe = fixture(
      lines: texts.enumerated().map { ($0.element, 42.0, 700.0 - Double($0.offset) * 20, 12.0) })
    let probePage = try PDFPageTree.pageIDs(in: probe)[0]
    let layout = try PageTextLayout.build(pageID: probePage, in: probe)
    var widths: [Double] = []
    for range in layout.lines {
      let clusters = range.map { layout.clusters[$0] }.filter { !$0.isWhitespace }
      var width = 0.0
      for cluster in clusters {
        let estimated = cluster.advance
          ?? (0.5 * cluster.fontSize * Double(max(cluster.text.count, 1)))
        width += max(cluster.bounds[2] - cluster.bounds[0], estimated)
      }
      widths.append(width)
    }
    let positions: [Double]
    switch alignment {
    case .center:
      positions = widths.map { 300 - $0 / 2 }
    case .right:
      positions = widths.map { 560 - $0 }
    default:
      positions = widths.map { _ in 42 }
    }
    return fixture(
      lines: texts.enumerated().map {
        ($0.element, positions[$0.offset], 700.0 - Double($0.offset) * 20, 12.0)
      })
  }

  @Test func alignmentAndIndentInference() throws {
    let centered = try alignedFixture(
      ["Centered heading line", "A longer centered line here", "Short"], alignment: .center)
    let centeredPage = try PDFPageTree.pageIDs(in: centered)[0]
    let centeredBlock = try #require(
      try ParagraphReconstruction.candidates(pageID: centeredPage, in: centered)
        .first { $0.lineIndices.count == 3 })
    #expect(centeredBlock.alignment == .center)

    let right = try alignedFixture(
      ["Right aligned one", "Right aligned longer", "Rights"], alignment: .right)
    let rightPage = try PDFPageTree.pageIDs(in: right)[0]
    let rightBlock = try #require(
      try ParagraphReconstruction.candidates(pageID: rightPage, in: right)
        .first { $0.lineIndices.count == 3 })
    #expect(rightBlock.alignment == .right)

    // First-line indentation: the first line starts further right.
    let indented = fixture(lines: [
      ("Indented first line", 72, 700, 12),
      ("Continuation line at the margin", 42, 680, 12),
      ("Another continuation line here", 42, 660, 12),
    ])
    let indentedPage = try PDFPageTree.pageIDs(in: indented)[0]
    let indentedBlock = try #require(
      try ParagraphReconstruction.candidates(pageID: indentedPage, in: indented)
        .first { $0.lineIndices.count == 3 })
    #expect(indentedBlock.firstLineIndent > 20)
    #expect(indentedBlock.alignment == .left)
  }

  @Test func analysisStaysBoundedOnManyLines() throws {
    var lines: [(text: String, x: Double, y: Double, size: Double)] = []
    for index in 0..<200 {
      let y = 780.0 - Double(index) * 3.6
      lines.append(("Line \(index) of the measurement page.", 42, y, 6))
    }
    let graph = fixture(lines: lines)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let start = ContinuousClock.now
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let duration = ContinuousClock.now - start
    let milliseconds = duration.components.seconds * 1000
      + duration.components.attoseconds / 1_000_000_000_000_000
    print("[P19-029] analyzed \(candidates.count) candidates in \(milliseconds) ms")
    #expect(!candidates.isEmpty)
    #expect(duration < .seconds(2))
  }
}
