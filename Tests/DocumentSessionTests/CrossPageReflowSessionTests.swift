import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// P19-028: cross-page supported reflow through undo, save, and reopen.
@Suite("Cross-page session")
struct CrossPageReflowSessionTests {
  private func fixtureBytes() throws -> Data {
    func pageContent(_ heading: String, _ first: String, _ second: String) -> Data {
      var content = Data()
      content.append(Data("BT /F1 14 Tf 42 720 Td (\(heading)) Tj ET\n".utf8))
      content.append(Data("BT /F1 12 Tf 42 660 Td (\(first)) Tj ET\n".utf8))
      content.append(Data("BT /F1 12 Tf 42 640 Td (\(second)) Tj ET\n".utf8))
      return content
    }
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
        PDFObjectID(5): .stream(
          PDFStream(
            bytes: pageContent("Page one heading", "Alpha original one", "Alpha original two"))),
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
          PDFStream(
            bytes: pageContent("Page two heading", "Beta original one", "Beta original two"))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFWriter.write(graph)
  }

  private func pageText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    try PageTextLayout.build(pageID: pageID, in: graph).clusters.map(\.text).joined()
  }

  @Test func crossPageReflowUndoRedoAndReopen() throws {
    let original = try fixtureBytes()
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    #expect(session.canEdit)

    guard let graph = session.currentGraph else {
      Issue.record("Session graph missing")
      return
    }
    let pageIDs = session.pageIDs
    var region: [ParagraphRegionPage] = []
    for pageID in pageIDs {
      let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
      guard let paragraph = candidates.first(where: { $0.kind == .flowing }) else { continue }
      region.append(ParagraphRegionPage(pageID: pageID, candidate: paragraph))
    }
    #expect(region.count == 2)
    let replacement = (1...24).map { String(format: "w%02d", $0) }.joined(separator: " ")

    try session.apply(
      PDFTransaction([
        CrossPageReflowCommand(
          region: region, replacement: replacement,
          options: ParagraphReflowOptions(overflow: .allow))
      ]))
    #expect(session.isDirty)
    let edited = try session.bytesForSave()
    #expect(edited != original)
    let editedParsed = try PDFParser.parse(edited)
    let firstText = try pageText(editedParsed.graph, editedParsed.pageIDs[0])
    let secondText = try pageText(editedParsed.graph, editedParsed.pageIDs[1])
    #expect(firstText.contains("w01"))
    #expect(secondText.contains("w24"))
    #expect(firstText.contains("Page one heading"))
    #expect(secondText.contains("Page two heading"))

    // Reopen: a fresh session from the saved bytes keeps the distribution.
    let reopened = DocumentEditSession()
    reopened.load(try PDFSource(data: edited))
    guard let reopenedGraph = reopened.currentGraph else {
      Issue.record("Reopened graph missing")
      return
    }
    #expect(
      try pageText(reopenedGraph, reopened.pageIDs[0]).contains("w01"))
    #expect(
      try pageText(reopenedGraph, reopened.pageIDs[1]).contains("w24"))

    // Undo restores the exact original bytes; redo reproduces the edit.
    #expect(session.undo())
    #expect(try session.bytesForSave() == original)
    let undoneParsed = try PDFParser.parse(try session.bytesForSave())
    #expect(
      try pageText(undoneParsed.graph, undoneParsed.pageIDs[0]).contains("Alpha original one"))
    #expect(
      try pageText(undoneParsed.graph, undoneParsed.pageIDs[1]).contains("Beta original one"))
    #expect(session.redo())
    #expect(try session.bytesForSave() == edited)
  }
}
