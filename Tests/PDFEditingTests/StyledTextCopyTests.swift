import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P16-014: formatting-preserving copy — the rich-text form carries the
/// run's family, size, and color and nothing the profile does not model.
@Suite("Styled copy")
struct StyledTextCopyTests {
  private func twoStyleGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let content = """
      BT /F1 12 Tf 1 0 0 rg 42 700 Td (Red run) Tj ET
      BT /F2 18 Tf 0 0 1 rg 42 660 Td (Blue {run}) Tj ET

      """
    let graph = PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([
              PDFName("F1"): .reference(PDFObjectID(4)),
              PDFName("F2"): .reference(PDFObjectID(5)),
            ])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(6)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("ABCDEF+Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(5): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Times-Bold")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(6): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return (graph, PDFObjectID(3))
  }

  @Test func styledRunsCaptureFamilySizeAndColor() throws {
    let (graph, pageID) = try twoStyleGraph()
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    let range = 0..<layout.clusters.count
    let runs = try #require(
      try StyledTextCopy.styledRuns(pageID: pageID, range: range, in: graph))
    #expect(runs.count == 2)
    // Subset prefixes are stripped from the family.
    #expect(runs[0].fontFamily == "Helvetica")
    #expect(abs(runs[0].fontSize - 12) < 0.001)
    #expect(runs[0].color == [1, 0, 0])
    #expect(runs[0].text == "Red run")
    #expect(runs[1].fontFamily == "Times-Bold")
    #expect(abs(runs[1].fontSize - 18) < 0.001)
    #expect(runs[1].color == [0, 0, 1])
    #expect(runs[1].text == "Blue {run}")
  }

  @Test func richTextCarriesTablesAndEscapes() throws {
    let (graph, pageID) = try twoStyleGraph()
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    let rtf = try #require(
      try StyledTextCopy.richText(pageID: pageID, range: 0..<layout.clusters.count, in: graph))
    #expect(rtf.hasPrefix("{\\rtf1"))
    #expect(rtf.contains("{\\fonttbl"))
    #expect(rtf.hasPrefix("{\\rtf1"))
    #expect(rtf.contains("Helvetica;"))
    #expect(rtf.contains("Times-Bold;"))
    #expect(rtf.contains("\\red255\\green0\\blue0;"))
    #expect(rtf.contains("\\red0\\green0\\blue255;"))
    #expect(rtf.contains("\\fs24"))  // 12 pt
    #expect(rtf.contains("\\fs36"))  // 18 pt
    // Braces are escaped so the RTF stays well-formed.
    #expect(rtf.contains("Blue \\{run\\}"))
    #expect(!rtf.contains("Blue {run}"))
    // A partial range keeps only its runs.
    guard let firstRunEnd = layout.clusters.firstIndex(where: { $0.text == "B" }) else {
      Issue.record("no second-run cluster")
      return
    }
    let firstOnly = try #require(
      try StyledTextCopy.richText(pageID: pageID, range: 0..<firstRunEnd, in: graph))
    #expect(firstOnly.contains("Red run"))
    #expect(!firstOnly.contains("Blue"))
    // Empty and out-of-bounds ranges yield nil so callers fall back.
    #expect(try StyledTextCopy.richText(pageID: pageID, range: 0..<0, in: graph) == nil)
    #expect(
      try StyledTextCopy.richText(
        pageID: pageID, range: 0..<(layout.clusters.count + 2), in: graph) == nil)
  }

  @Test func nonASCIITextUsesUnicodeEscapes() throws {
    let (graph, pageID) = try twoStyleGraph()
    var mutated = graph
    // Replace the page content with an accented word so the escape path runs.
    mutated.objects[PDFObjectID(6)] = .stream(
      PDFStream(bytes: Data("BT /F1 12 Tf 42 700 Td (Grüße) Tj ET\n".utf8)))
    let layout = try PageTextLayout.build(pageID: pageID, in: mutated)
    let rtf = try #require(
      try StyledTextCopy.richText(
        pageID: pageID, range: 0..<layout.clusters.count, in: mutated))
    #expect(rtf.contains("Gr"))
    // The ü arrives either as a WinAnsi byte decoded to U+00FC (escaped) or
    // as the replacement glyph; in both cases no raw non-ASCII byte is
    // emitted into the RTF body.
    for scalar in rtf.unicodeScalars where scalar.value > 127 {
      Issue.record("raw non-ASCII scalar leaked into RTF: \(scalar)")
      break
    }
    #expect(rtf.contains("\\u") || rtf.contains("\\'"))
  }
}
