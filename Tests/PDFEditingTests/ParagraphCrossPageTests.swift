import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P19-018: cross-page reflow for explicitly declared regions.
@Suite("Cross-page reflow")
struct ParagraphCrossPageTests {
  private func fixture() -> PDFGraph {
    func pageContent(_ heading: String, _ first: String, _ second: String) -> Data {
      var content = Data()
      content.append(Data("BT /F1 14 Tf 42 720 Td (\(heading)) Tj ET\n".utf8))
      content.append(Data("BT /F1 12 Tf 42 660 Td (\(first)) Tj ET\n".utf8))
      content.append(Data("BT /F1 12 Tf 42 640 Td (\(second)) Tj ET\n".utf8))
      return content
    }
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
        PDFObjectID(5): .stream(
          PDFStream(bytes: pageContent("Page one heading", "Alpha original one", "Alpha original two"))),
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
        PDFObjectID(7): .stream(
          PDFStream(bytes: pageContent("Page two heading", "Beta original one", "Beta original two"))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func region(_ graph: PDFGraph) throws -> [ParagraphRegionPage] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    var pages: [ParagraphRegionPage] = []
    for pageID in pageIDs {
      let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
      guard let paragraph = candidates.first(where: { $0.kind == .flowing }) else { continue }
      pages.append(ParagraphRegionPage(pageID: pageID, candidate: paragraph))
    }
    return pages
  }

  private func pageText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    try PageTextLayout.build(pageID: pageID, in: graph).clusters.map(\.text).joined()
  }

  @Test func crossPageReflowDistributesAndRefusesWhenTooSmall() throws {
    let graph = fixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let region = try region(graph)
    #expect(region.count == 2)
    let replacement = (1...24).map { String(format: "w%02d", $0) }.joined(separator: " ")

    // Without overflow the region reports what does not fit.
    let clipped = try CrossPageReflow.plan(
      region: region, replacement: replacement, in: graph,
      options: ParagraphReflowOptions(overflow: .clip))
    #expect(!clipped.remainingText.isEmpty)
    #expect(clipped.pages.count == 2)
    #expect(clipped.pages.allSatisfy { !$0.text.isEmpty })
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          CrossPageReflowCommand(
            region: region, replacement: replacement,
            options: ParagraphReflowOptions(overflow: .clip))
        ]), to: graph)
    }

    // With overflow the remainder extends the last page.
    let plan = try CrossPageReflow.plan(
      region: region, replacement: replacement, in: graph,
      options: ParagraphReflowOptions(overflow: .allow))
    #expect(plan.remainingText.isEmpty)
    #expect(plan.pages[1].overflowed)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        CrossPageReflowCommand(
          region: region, replacement: replacement,
          options: ParagraphReflowOptions(overflow: .allow))
      ]), to: graph)
    let firstText = try pageText(edited, pageIDs[0])
    let secondText = try pageText(edited, pageIDs[1])
    // The first words stay on page one; the last words land on page two.
    #expect(firstText.contains("w01"))
    #expect(!firstText.contains("w24"))
    #expect(secondText.contains("w24"))
    // Unrelated headings are untouched on both pages.
    #expect(firstText.contains("Page one heading"))
    #expect(secondText.contains("Page two heading"))
    // The original paragraph text is gone.
    #expect(!firstText.contains("Alpha original"))
    #expect(!secondText.contains("Beta original"))
  }
}
