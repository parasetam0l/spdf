import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import PDFFixtures
import Testing
@testable import MacServices

/// P34-009–P34-014/P34-027: semantic and appearance HTML export, escaping,
/// script-free output, link and heading preservation, the image policy, and
/// outline export.
@Suite("HTML and outline export")
struct HTMLExportTests {
  private func hostileFixture() -> PDFGraph {
    func winAnsi(_ text: String) -> Data { text.data(using: .windowsCP1252)! }
    var content = Data()
    content.append(winAnsi("BT /F1 12 Tf 42 660 Td ("))
    content.append(winAnsi("<script>alert(1)</script> & \"quoted\""))
    content.append(winAnsi(") Tj ET\n"))
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
          PDFName("Annots"): .array([.reference(PDFObjectID(6)), .reference(PDFObjectID(7))]),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([.integer(42), .integer(600), .integer(200), .integer(620)]),
          PDFName("A"): .dictionary([
            PDFName("S"): .name(PDFName("URI")),
            PDFName("URI"): .string(Data("javascript:alert(2)".utf8)),
          ]),
        ]),
        PDFObjectID(7): .dictionary([
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Link")),
          PDFName("Rect"): .array([.integer(42), .integer(560), .integer(200), .integer(580)]),
          PDFName("A"): .dictionary([
            PDFName("S"): .name(PDFName("URI")),
            PDFName("URI"): .string(Data("https://safe.example/".utf8)),
          ]),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func outlineFixture() -> PDFGraph {
    PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
          PDFName("Outlines"): .reference(PDFObjectID(10)),
          PDFName("Names"): .dictionary([
            PDFName("Dests"): .dictionary([
              PDFName("Names"): .array([
                .string(Data("intro".utf8)),
                .array([.reference(PDFObjectID(4)), .name(PDFName("Fit"))]),
              ])
            ])
          ]),
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
        PDFObjectID(5): .stream(PDFStream(bytes: Data("BT /F1 12 Tf 42 660 Td (One) Tj ET\n".utf8))),
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
        PDFObjectID(7): .stream(PDFStream(bytes: Data("BT /F1 12 Tf 42 660 Td (Two) Tj ET\n".utf8))),
        PDFObjectID(10): .dictionary([
          PDFName("Type"): .name(PDFName("Outlines")),
          PDFName("First"): .reference(PDFObjectID(11)),
          PDFName("Last"): .reference(PDFObjectID(14)),
          PDFName("Count"): .integer(4),
        ]),
        PDFObjectID(11): .dictionary([
          PDFName("Title"): .string(Data("Chapter & One".utf8)),
          PDFName("Parent"): .reference(PDFObjectID(10)),
          PDFName("Dest"): .array([.reference(PDFObjectID(4)), .name(PDFName("Fit"))]),
          PDFName("First"): .reference(PDFObjectID(12)),
          PDFName("Next"): .reference(PDFObjectID(13)),
        ]),
        PDFObjectID(12): .dictionary([
          PDFName("Title"): .string(Data("Section 1.1".utf8)),
          PDFName("Parent"): .reference(PDFObjectID(11)),
          PDFName("Dest"): .array([.reference(PDFObjectID(6)), .name(PDFName("Fit"))]),
        ]),
        PDFObjectID(13): .dictionary([
          PDFName("Title"): .string(Data("Chapter 2".utf8)),
          PDFName("Parent"): .reference(PDFObjectID(10)),
          PDFName("Dest"): .array([.reference(PDFObjectID(6)), .name(PDFName("Fit"))]),
          PDFName("Next"): .reference(PDFObjectID(14)),
        ]),
        PDFObjectID(14): .dictionary([
          PDFName("Title"): .string(Data("Named Intro".utf8)),
          PDFName("Parent"): .reference(PDFObjectID(10)),
          PDFName("Dest"): .string(Data("intro".utf8)),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func png(fromDataURI html: String) -> Data? {
    guard let range = html.range(of: "data:image/png;base64,") else { return nil }
    let rest = html[range.upperBound...]
    let base64 = rest.prefix { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
    return Data(base64Encoded: String(base64))
  }

  @Test func semanticExportPreservesHeadingsLinksAndFigures() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let result = try PDFHTMLExport.export(pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(result.html.contains("<h1>Tagged heading</h1>"))
    #expect(result.html.contains("<p>Tagged paragraph text</p>"))
    #expect(result.html.contains("<a href=\"https://example.invalid/tagged\">"))
    #expect(result.html.contains("alt=\"A green square\""))
    #expect(result.html.contains("data:image/png;base64,"))
    #expect(result.resources.isEmpty)
    #expect(!result.html.contains("<script"))
  }

  @Test func imagePolicyEmbedAndPackage() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let embedded = try PDFHTMLExport.export(
      pageIDs: parsed.pageIDs, in: parsed.graph,
      options: PDFHTMLExportOptions(mode: .semantic, imagePolicy: .embed))
    #expect(embedded.resources.isEmpty)
    let image = try #require(png(fromDataURI: embedded.html))
    #expect(image.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

    let packaged = try PDFHTMLExport.export(
      pageIDs: parsed.pageIDs, in: parsed.graph,
      options: PDFHTMLExportOptions(mode: .semantic, imagePolicy: .package))
    let key = try #require(packaged.resources.keys.first)
    #expect(key == "images/figure-0001.png")
    #expect(packaged.resources[key]?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    #expect(packaged.html.contains("src=\"images/figure-0001.png\""))
    #expect(!packaged.html.contains("data:image/png"))
  }

  @Test func untaggedExportEscapesTextAndDropsUnsafeLinks() throws {
    let graph = hostileFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let result = try PDFHTMLExport.export(pageIDs: pageIDs, in: graph)
    #expect(result.html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(result.html.contains("&amp; &quot;quoted&quot;"))
    #expect(!result.html.contains("<script>"))
    #expect(!result.html.contains("javascript:"))
    #expect(result.html.contains("href=\"https://safe.example/\""))
    #expect(!result.html.contains("onload="))
    #expect(!result.html.contains("onclick="))
    #expect(!result.html.contains("<iframe"))
    #expect(!result.html.contains("<object"))
  }

  @Test func appearanceModeRendersPages() throws {
    let parsed = try PDFParser.parse(PDFWriter.write(PDFFixtures.graph(pages: 2)))
    let result = try PDFHTMLExport.export(
      pageIDs: parsed.pageIDs, in: parsed.graph,
      options: PDFHTMLExportOptions(mode: .appearance, imageDPI: 72))
    #expect(result.html.contains("<section class=\"page\" id=\"page-1\">"))
    #expect(result.html.contains("<section class=\"page\" id=\"page-2\">"))
    let count = result.html.components(separatedBy: "<img class=\"page\"").count - 1
    #expect(count == 2)
    let image = try #require(png(fromDataURI: result.html))
    guard let source = CGImageSourceCreateWithData(image as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      Issue.record("Exported page image did not decode")
      return
    }
    #expect(cgImage.width == 612 && cgImage.height == 792)
    #expect(!result.html.contains("<script"))
  }

  @Test func outlineInventoryAndExport() throws {
    let graph = outlineFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let items = PDFOutlineInventory.items(in: graph, pageIDs: pageIDs)
    #expect(items.count == 3)
    #expect(items[0].title == "Chapter & One")
    #expect(items[0].pageIndex == 0)
    #expect(items[0].children.count == 1)
    #expect(items[0].children[0].title == "Section 1.1")
    #expect(items[0].children[0].pageIndex == 1)
    #expect(items[1].title == "Chapter 2")
    #expect(items[2].title == "Named Intro")
    #expect(items[2].pageIndex == 0)

    let markdown = PDFOutlineExport.text(items: items, format: .markdown, documentTitle: "Book")
    #expect(markdown.contains("# Book"))
    #expect(markdown.contains("- [Chapter & One](#page-1)"))
    #expect(markdown.contains("  - [Section 1.1](#page-2)"))
    #expect(markdown.contains("- [Chapter 2](#page-2)"))

    let html = PDFOutlineExport.text(items: items, format: .html, documentTitle: "Book & More")
    #expect(html.contains("<a href=\"#page-1\">Chapter &amp; One</a>"))
    #expect(html.contains("<ul>"))
    #expect(html.contains("<title>Book &amp; More</title>"))
    #expect(!html.contains("<script"))
  }

  @Test func noActiveContentInAnyMode() throws {
    let parsed = try PDFParser.parse(PDFWriter.write(PDFFixtures.graph(pages: 1)))
    for mode in [PDFHTMLExportOptions.Mode.semantic, .appearance] {
      for policy in [PDFHTMLExportOptions.ImagePolicy.embed, .package] {
        let result = try PDFHTMLExport.export(
          pageIDs: parsed.pageIDs, in: parsed.graph,
          options: PDFHTMLExportOptions(mode: mode, imagePolicy: policy))
        for forbidden in ["<script", "javascript:", "onload=", "onclick=", "<iframe", "<object", "<embed"] {
          #expect(!result.html.lowercased().contains(forbidden))
        }
      }
    }
  }
}
