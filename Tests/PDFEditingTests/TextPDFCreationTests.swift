import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// PAG-08: plain-text PDF creation with wrapping and pagination.
@Suite("Text PDF creation")
struct TextPDFCreationTests {
  @Test func longTextIsWrappedAndPaginated() throws {
    let text = (1...140).map { "Line \($0) of the created document." }
      .joined(separator: "\n")
    let data = try TextPDFCreation.make(text: text, layout: .letter, fontSize: 12)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageCount > 1)
    let first = try PageTextLayout.build(
      pageID: parsed.pageIDs[0], in: parsed.graph)
    let firstText = first.lines.map { first.text(in: $0) }.joined(separator: "\n")
    #expect(firstText.contains("Line 1"))
    let last = try PageTextLayout.build(
      pageID: parsed.pageIDs[parsed.pageIDs.count - 1], in: parsed.graph)
    let lastText = last.lines.map { last.text(in: $0) }.joined(separator: "\n")
    #expect(!lastText.isEmpty)
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    #expect(attributes.allSatisfy { $0.mediaBox == [0, 0, 612, 792] })
  }

  @Test func emptyTextAndInvalidSizesAreRefused() throws {
    #expect(throws: PDFError.self) {
      _ = try TextPDFCreation.make(text: "   \n")
    }
    #expect(throws: PDFError.self) {
      _ = try TextPDFCreation.make(text: "hello", fontSize: 1)
    }
    #expect(throws: PDFError.self) {
      _ = try TextPDFCreation.make(text: "hello", margins: 400)
    }
  }
}
