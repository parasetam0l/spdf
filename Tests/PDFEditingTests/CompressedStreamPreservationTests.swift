import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P07-013/P07-014/P07-016/P07-028: DCT, JPX, CCITT, and JBIG2 payloads
/// survive edits and full rewrites byte-identically — the core never
/// decodes them, so there is nothing to corrupt.
@Suite("Compressed stream preservation")
struct CompressedStreamPreservationTests {
  private func payloadStream(filter: String, bytes: [UInt8]) -> PDFStream {
    PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName(filter))], bytes: Data(bytes))
  }

  @Test func unsupportedPayloadsSurviveEditsAndRewrites() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let payloads: [(PDFObjectID, PDFStream)] = [
      (PDFObjectID(800), payloadStream(
        filter: "DCTDecode", bytes: [0xFF, 0xD8, 0xFF, 0xD9, 0xAA, 0xBB])),
      (PDFObjectID(801), payloadStream(
        filter: "JPXDecode",
        bytes: [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20])),
      (PDFObjectID(802), payloadStream(filter: "CCITTFaxDecode", bytes: [0x11, 0x22])),
      (PDFObjectID(803), payloadStream(filter: "JBIG2Decode", bytes: [0x33, 0x44])),
    ]
    for (id, stream) in payloads {
      graph.objects[id] = .stream(stream)
    }
    // An unrelated edit plus a full rewrite must not touch one payload byte.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [try PDFPageTree.pageIDs(in: graph)[0]], byDegrees: 90)]),
      to: graph)
    let written = try PDFWriter.write(edited)
    let reparsed = try PDFParser.parse(written)
    for (id, stream) in payloads {
      guard case .stream(let roundTripped)? = reparsed.graph.objects[id] else {
        Issue.record("payload \(id.number) missing after rewrite")
        continue
      }
      #expect(roundTripped.bytes == stream.bytes)
      // The writer records an exact /Length; everything else is verbatim.
      #expect(roundTripped.dictionary[PDFName("Filter")] == stream.dictionary[PDFName("Filter")])
      var expected = stream.dictionary
      expected[PDFName("Length")] = .integer(Int64(stream.bytes.count))
      #expect(roundTripped.dictionary == expected)
    }
  }

  @Test func emptyAndMultiStreamContentArraysBehave() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    // An empty content array parses as no segments.
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      Issue.record("page missing")
      return
    }
    page[PDFName("Contents")] = .array([])
    graph.objects[pageID] = .dictionary(page)
    let empty = try PageContent.load(pageID: pageID, in: graph)
    #expect(empty.segments.isEmpty)
    // A multi-stream array concatenates every member in order.
    guard case .dictionary(let original)? = try PDFParser.parse(PDFFixtures.onePage()).graph
      .objects[pageID],
      case .reference(let firstID)? = original[PDFName("Contents")]
    else {
      Issue.record("fixture page missing its stream")
      return
    }
    let secondID = PDFObjectID(900)
    graph.objects[secondID] = .stream(
      PDFStream(bytes: Data("BT /F1 12 Tf 42 600 Td (Second) Tj ET\n".utf8)))
    page[PDFName("Contents")] = .array([.reference(firstID), .reference(secondID)])
    graph.objects[pageID] = .dictionary(page)
    let multi = try PageContent.load(pageID: pageID, in: graph)
    #expect(multi.segments.count == 2)
    #expect(multi.segments.map(\.objectID) == [firstID, secondID])
  }
}
