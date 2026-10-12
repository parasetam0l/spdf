import DocumentSession
import Foundation
import PDFCore
import Testing

@Suite("Original-source sessions")
struct SourceStoreTests {
  @Test func unsupportedSourceCanBeCopiedUnchanged() throws {
    let data = Data("%PDF-2.0\nunknown bytes\u{00FF}".utf8)
    let store = SourceStore()
    try store.load(data)
    #expect(try store.originalBytes() == data)
    #expect(throws: PDFError.self) { try PDFParser.parse(data) }
  }

  @Test func failedReloadRetainsPreviousSource() throws {
    let store = SourceStore()
    let original = Data("%PDF-1.7\noriginal".utf8)
    try store.load(original)
    #expect(throws: PDFError.self) { try store.load(Data("not a PDF".utf8)) }
    #expect(try store.originalBytes() == original)
  }

  @Test func documentsHaveIndependentStorage() throws {
    let a = SourceStore()
    let b = SourceStore()
    let first = Data("%PDF-1.7\nfirst".utf8)
    let second = Data("%PDF-1.7\nsecond".utf8)
    try a.load(first)
    try b.load(second)
    #expect(try a.originalBytes() == first)
    #expect(try b.originalBytes() == second)
  }

  @Test func emptyStoreAndOpeningLimitsFail() {
    #expect(throws: PDFError.self) { try SourceStore().originalBytes() }
    #expect(throws: PDFError.self) { try PDFSource(data: Data("%PDF-1.7\n".utf8), maximumBytes: 2) }
  }
}
