import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P34-001/P34-002/P34-025: text export in reading order with explicit
/// encoding, line endings, and page separators, including WinAnsi Unicode.
@Suite("Text export")
struct TextExportTests {
  private func fixture() -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    func winAnsi(_ text: String) -> Data { text.data(using: .windowsCP1252)! }
    var pageOne = Data()
    pageOne.append(winAnsi("BT /F1 18 Tf 42 700 Td ("))
    pageOne.append(winAnsi("Café — naïve"))
    pageOne.append(winAnsi(") Tj ET\n"))
    pageOne.append(winAnsi("BT /F1 12 Tf 42 660 Td (Second line of body text.) Tj ET\n"))
    pageOne.append(winAnsi("BT /F1 12 Tf 42 640 Td (Third line follows here.) Tj ET\n"))
    var pageTwo = Data()
    pageTwo.append(winAnsi("BT /F1 12 Tf 42 660 Td (Page two text.) Tj ET\n"))
    let graph = PDFGraph(
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
        PDFObjectID(5): .stream(PDFStream(bytes: pageOne)),
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
        PDFObjectID(7): .stream(PDFStream(bytes: pageTwo)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return (graph, [PDFObjectID(4), PDFObjectID(6)])
  }

  @Test func plainTextFollowsReadingOrderWithUnicode() throws {
    let (graph, pageIDs) = fixture()
    let data = try PDFTextExport.plainText(pageIDs: pageIDs, in: graph)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("Café — naïve"))
    #expect(text.contains("Second line of body text."))
    #expect(text.contains("Page two text."))
    let pages = text.components(separatedBy: "\u{0C}")
    #expect(pages.count == 2)
    guard let heading = pages[0].range(of: "Café"),
      let body = pages[0].range(of: "Second line")
    else {
      Issue.record("Exported text is missing lines")
      return
    }
    #expect(heading.lowerBound < body.lowerBound)
    #expect(pages[0].range(of: "Second line")!.lowerBound < pages[0].range(of: "Third line")!.lowerBound)
  }

  @Test func selectedTextHonorsEncodingAndLineEndings() throws {
    let (graph, pageIDs) = fixture()
    let layout = try PageTextLayout.build(pageID: pageIDs[0], in: graph)
    let body = layout.clusters.filter { $0.origin[1] < 680 }
    let options = PDFTextExportOptions(lineEnding: .crlf, encoding: .utf16, pageSeparator: .none)
    let data = PDFTextExport.plainText(clusters: body, options: options)
    #expect(data.prefix(2) == Data([0xFF, 0xFE]))
    guard let decoded = String(data: data, encoding: .utf16) else {
      Issue.record("UTF-16 decoding failed")
      return
    }
    #expect(decoded.contains("\r\n"))
    #expect(!decoded.contains("Café"))
    #expect(decoded.contains("Second line of body text.\r\nThird line follows here."))
  }

  @Test func emptyAndSingleLineSelections() throws {
    let (graph, pageIDs) = fixture()
    #expect(PDFTextExport.plainText(clusters: []).isEmpty)
    let layout = try PageTextLayout.build(pageID: pageIDs[1], in: graph)
    let data = PDFTextExport.plainText(clusters: layout.clusters)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text == "Page two text.")
    #expect(!text.hasSuffix("\n"))
  }

  @Test func pageSeparatorChoices() throws {
    let (graph, pageIDs) = fixture()
    let blank = String(
      decoding: try PDFTextExport.plainText(
        pageIDs: pageIDs, in: graph,
        options: PDFTextExportOptions(pageSeparator: .blankLine)), as: UTF8.self)
    #expect(blank.contains("here.\n\nPage two"))
    let none = String(
      decoding: try PDFTextExport.plainText(
        pageIDs: pageIDs, in: graph, options: PDFTextExportOptions(pageSeparator: .none)),
      as: UTF8.self)
    #expect(none.contains("here.\nPage two"))
    #expect(!none.contains("\u{0C}"))
  }
}
