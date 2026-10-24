import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-09: document information editing.
@Suite("Document metadata")
struct DocumentMetadataCommandTests {
  @Test func metadataRoundTripsThroughSaveAndReopen() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        SetDocumentMetadataCommand(
          metadata: DocumentMetadata(
            title: "Yıllık Rapor", author: "Ayşe İzci", subject: "Summary",
            keywords: "report, annual", creator: "sPDF", producer: "sPDF"))
      ]), to: parsed.graph)
    let reopened = try PDFParser.parse(try PDFWriter.write(edited))
    let facts = PDFDocumentInventory.documentFacts(
      in: reopened.graph, pageCount: reopened.pageCount)
    #expect(facts.metadata.title == "Yıllık Rapor")
    #expect(facts.metadata.author == "Ayşe İzci")
    #expect(facts.metadata.subject == "Summary")
    #expect(facts.metadata.keywords == "report, annual")
  }

  @Test func clearingAllFieldsRemovesTheInfoDictionary() throws {
    var parsed = try PDFParser.parse(PDFFixtures.onePage())
    parsed = try PDFParser.parse(PDFWriter.write(try PDFEditingEngine.commit(
      PDFTransaction([
        SetDocumentMetadataCommand(metadata: DocumentMetadata(title: "Temporary"))
      ]), to: parsed.graph)))
    let cleared = try PDFEditingEngine.commit(
      PDFTransaction([SetDocumentMetadataCommand(metadata: DocumentMetadata())]),
      to: parsed.graph)
    #expect(cleared.trailer[PDFName("Info")] == nil)
  }
}
