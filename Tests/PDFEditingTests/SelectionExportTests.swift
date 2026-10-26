import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// EXP-06: selection/range export, reading order/Unicode retention and the
/// explicit appearance-versus-editability choice.
@Suite("Selection and range export")
struct SelectionExportTests {
  private func parsed(_ data: Data) throws -> (PDFGraph, [PDFObjectID]) {
    let result = try PDFParser.parse(data)
    return (result.graph, result.pageIDs)
  }

  private func tableFixture() -> PDFGraph {
    let content = """
      1 w 0 0 0 RG
      55 525 120 45 re S
      175 525 120 45 re S
      55 485 120 45 re S
      175 485 120 45 re S
      55 445 120 45 re S
      175 445 120 45 re S
      BT /F1 12 Tf 72 700 Td (Body text outside the table) Tj ET
      BT /F1 12 Tf 65 555 Td (Name) Tj ET
      BT /F1 12 Tf 65 540 Td (Item) Tj ET
      BT /F1 12 Tf 185 555 Td (Value) Tj ET
      BT /F1 12 Tf 185 540 Td (Amount) Tj ET
      BT /F1 12 Tf 65 515 Td (Revenue) Tj ET
      BT /F1 12 Tf 65 500 Td (Quarter) Tj ET
      BT /F1 12 Tf 185 515 Td (10) Tj ET
      BT /F1 12 Tf 185 500 Td (20) Tj ET
      BT /F1 12 Tf 65 475 Td (Cost) Tj ET
      BT /F1 12 Tf 65 460 Td (Total) Tj ET
      BT /F1 12 Tf 185 475 Td (4) Tj ET
      BT /F1 12 Tf 185 460 Td (8) Tj ET

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

  private func fakeRenderer() -> AppearanceRenderer {
    AppearanceRenderer { request in
      AppearanceImage(
        pngData: Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0, count: 12)),
        pixelWidth: 16, pixelHeight: 16)
    }
  }

  @Test func pageRangeTextExportsOnlyIntendedPages() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.threePages())
    let payload = try SelectionExport.export(
      format: .text, scope: .pageRange(2...2), in: graph, pageIDs: pageIDs)
    #expect(payload.fidelity == .editable)
    let text = String(decoding: payload.data, as: UTF8.self)
    #expect(text.contains("page 2"))
    #expect(!text.contains("page 1"))
    #expect(!text.contains("page 3"))
    #expect(payload.limitations.contains { $0.contains("Plain text") })
  }

  @Test func selectionExportsOnlySelectedClusters() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.threePages())
    let layout = try PageTextLayout.build(pageID: pageIDs[0], in: graph)
    let all = CrossPageSelection(
      anchor: .init(pageIndex: 0, clusterIndex: 0),
      focus: .init(pageIndex: 0, clusterIndex: layout.clusters.count))
    let payload = try SelectionExport.export(
      format: .text, scope: .selection(all), in: graph, pageIDs: pageIDs)
    let text = String(decoding: payload.data, as: UTF8.self)
    #expect(text.contains("page 1"))
    #expect(!text.contains("page 2"))
    #expect(payload.scopeDescription == "current text selection")
    #expect(payload.limitations.contains { $0.contains("Only the text within the current selection") })
  }

  @Test func unicodeSurvivesTextAndRtfEncoding() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.multilingualPages())
    let utf16 = try SelectionExport.export(
      format: .text, scope: .document,
      options: SelectionExportOptions(textEncoding: .utf16),
      in: graph, pageIDs: pageIDs)
    #expect(utf16.data.count >= 2)
    #expect(utf16.data[utf16.data.startIndex] == 0xFF)
    #expect(utf16.data[utf16.data.startIndex + 1] == 0xFE)
    let decoded = String(data: utf16.data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
    #expect(!decoded.isEmpty)

    let rtf = try SelectionExport.export(
      format: .rtf, scope: .document, in: graph, pageIDs: pageIDs)
    let rtfText = String(decoding: rtf.data, as: UTF8.self)
    #expect(rtfText.hasPrefix("{\\rtf1"))
    #expect(rtfText.contains("\\u"))
    #expect(rtf.limitations.contains { $0.contains("Unicode escapes") })
  }

  @Test func htmlEditableEscapesAndCarriesTables() throws {
    let graph = tableFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let html = try SelectionExport.export(
      format: .html, scope: .document, options: SelectionExportOptions(documentTitle: "A & B"),
      in: graph, pageIDs: pageIDs)
    let text = String(decoding: html.data, as: UTF8.self)
    #expect(text.contains("<!DOCTYPE html>"))
    #expect(text.contains("<meta charset=\"utf-8\">"))
    #expect(text.contains("A &amp; B"))
    #expect(text.contains("<table>"))
    #expect(text.contains("Revenue"))
    #expect(text.contains("Body text outside the table"))
    #expect(!text.contains("<script"))
  }

  @Test func csvExportsDetectedTablesOnly() throws {
    let graph = tableFixture()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let payload = try SelectionExport.export(
      format: .tableCSV, scope: .document, in: graph, pageIDs: pageIDs)
    let text = String(decoding: payload.data, as: UTF8.self)
    #expect(text.contains("Name"))
    #expect(text.contains("Revenue"))
    #expect(!text.contains("Body text outside the table"))
    #expect(payload.fileExtension == "csv")
  }

  @Test func editableDocxIsAPackageWithDisclosedLimits() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.threePages())
    let payload = try SelectionExport.export(
      format: .docx, scope: .pageRange(1...2), in: graph, pageIDs: pageIDs)
    #expect(payload.data.count > 100)
    #expect(payload.data.prefix(2) == Data("PK".utf8))
    #expect(payload.limitations.contains { $0.contains("round trip") || $0.contains("DOCX") })
  }

  @Test func appearanceRequiresAcknowledgementRendererAndSupportedFormat() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.threePages())
    #expect(throws: PDFError.self) {
      _ = try SelectionExport.export(
        format: .text, scope: .document, fidelity: .appearance,
        options: SelectionExportOptions(acknowledgeAppearanceIsRendered: true),
        in: graph, pageIDs: pageIDs, appearanceRenderer: fakeRenderer())
    }
    #expect(throws: PDFError.self) {
      _ = try SelectionExport.export(
        format: .html, scope: .document, fidelity: .appearance,
        options: SelectionExportOptions(acknowledgeAppearanceIsRendered: false),
        in: graph, pageIDs: pageIDs, appearanceRenderer: fakeRenderer())
    }
    #expect(throws: PDFError.self) {
      _ = try SelectionExport.export(
        format: .docx, scope: .document, fidelity: .appearance,
        options: SelectionExportOptions(acknowledgeAppearanceIsRendered: true),
        in: graph, pageIDs: pageIDs, appearanceRenderer: nil)
    }
  }

  @Test func appearanceHtmlAndDocxEmbedRenderedPages() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.threePages())
    let options = SelectionExportOptions(acknowledgeAppearanceIsRendered: true)
    let html = try SelectionExport.export(
      format: .html, scope: .pageRange(1...1), fidelity: .appearance, options: options,
      in: graph, pageIDs: pageIDs, appearanceRenderer: fakeRenderer())
    let htmlText = String(decoding: html.data, as: UTF8.self)
    #expect(htmlText.contains("data:image/png;base64,"))
    #expect(html.fidelity == .appearance)
    #expect(html.limitations.contains { $0.contains("rendered PNG images") })

    let docx = try SelectionExport.export(
      format: .docx, scope: .pageRange(1...1), fidelity: .appearance, options: options,
      in: graph, pageIDs: pageIDs, appearanceRenderer: fakeRenderer())
    #expect(docx.data.prefix(2) == Data("PK".utf8))
    #expect(docx.limitations.contains { $0.contains("rendered page images") })
  }

  @Test func emptyOrOutOfRangeScopesAreRefused() throws {
    let (graph, pageIDs) = try parsed(try PDFFixtures.threePages())
    #expect(throws: PDFError.self) {
      _ = try SelectionExport.export(
        format: .text, scope: .pageRange(4...8), in: graph, pageIDs: pageIDs)
    }
    let empty = CrossPageSelection(
      anchor: .init(pageIndex: 0, clusterIndex: 0),
      focus: .init(pageIndex: 0, clusterIndex: 0))
    #expect(throws: PDFError.self) {
      _ = try SelectionExport.export(
        format: .text, scope: .selection(empty), in: graph, pageIDs: pageIDs)
    }
  }
}
