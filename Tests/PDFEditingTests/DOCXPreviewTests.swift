import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P35-022: the bounded reconstruction preview with ambiguous reading-order
/// flags.
@Suite("DOCX preview")
struct DOCXPreviewTests {
  private func reconstruction() -> DOCXReconstruction {
    DOCXReconstruction(
      blocks: [
        DOCXBlock(
          kind: .heading(level: 1), runs: [DOCXRunInput(text: "Title")], confidence: 0.9),
        DOCXBlock(
          kind: .paragraph, runs: [DOCXRunInput(text: "Confident line")], confidence: 0.8),
        DOCXBlock(
          kind: .paragraph,
          runs: [
            DOCXRunInput(
              text:
                "Uncertain line that is quite long and will be truncated in the preview snippet because it exceeds eighty characters")
          ],
          confidence: 0.5),
        DOCXBlock(kind: .pageBreak, runs: []),
        DOCXBlock(
          kind: .table(rows: [[[DOCXRunInput(text: "A")], [DOCXRunInput(text: "B")]]]),
          runs: []),
        DOCXBlock(
          kind: .image(
            DOCXImageRequest(
              pageIndex: 1, name: "appearance", bounds: [0, 0, 10, 10], isAppearance: true)),
          runs: []),
      ],
      pageWidth: 612, pageHeight: 792, landscape: false,
      limitations: ["Test limitation"])
  }

  @Test func previewGroupsPagesFlagsAmbiguityAndStaysBounded() {
    let preview = DOCXPreview.build(reconstruction: reconstruction())
    #expect(preview.totalCount == 6)
    #expect(preview.entries.count == 5)  // the page break is not an entry
    #expect(preview.ambiguousCount == 1)
    #expect(!preview.truncated)
    #expect(preview.entries[0].pageNumber == 1)
    #expect(preview.entries[0].kind == "heading1")
    #expect(preview.entries[2].ambiguous)
    #expect(!preview.entries[1].ambiguous)
    // Snippets are flattened and bounded to 80 characters.
    #expect(preview.entries[2].text.count == 80)
    #expect(!preview.entries[2].text.contains("\n"))
    // Page grouping follows the deliberate break.
    #expect(preview.entries[3].pageNumber == 2)
    #expect(preview.entries[3].kind == "table 1×2")
    #expect(preview.entries[3].text == "A | B")
    #expect(preview.entries[4].kind == "appearance")
    #expect(preview.entries[4].text == "(image)")

    let text = preview.text()
    #expect(text.contains("DOCX reconstruction preview — 6 blocks, 1 ambiguous"))
    #expect(text.contains("Page 1"))
    #expect(text.contains("Page 2"))
    #expect(text.contains("⚠ ambiguous"))
    #expect(text.contains("Test limitation"))
  }

  @Test func previewIsBoundedOnLargeReconstructions() {
    let blocks = (0..<(DOCXPreview.maxEntries + 50)).map { index in
      DOCXBlock(kind: .paragraph, runs: [DOCXRunInput(text: "Line \(index)")])
    }
    let preview = DOCXPreview.build(
      reconstruction: DOCXReconstruction(
        blocks: blocks, pageWidth: 612, pageHeight: 792, landscape: false, limitations: []))
    #expect(preview.entries.count == DOCXPreview.maxEntries)
    #expect(preview.truncated)
    #expect(preview.text().contains("preview truncated"))
  }

  @Test func previewReflectsBuilderConfidences() throws {
    // A page with a heading and a low-confidence label line.
    var content = Data()
    content.append(Data("BT /F1 24 Tf 42 700 Td (Report Title) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 660 Td (Body line one) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 640 Td (Body line two) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 600 Td (Loose label) Tj ET\n".utf8))
    let graph = PDFGraph(
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
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph)
    let preview = DOCXPreview.build(reconstruction: reconstruction)
    #expect(preview.entries.contains { $0.kind == "heading1" && $0.text == "Report Title" })
    let label = try #require(preview.entries.first { $0.text == "Loose label" })
    #expect(label.ambiguous)
    #expect(preview.ambiguousCount >= 1)
  }
}
