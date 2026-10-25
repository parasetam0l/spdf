import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import PDFKit
import Testing

/// TXT-09: text drawn with a rotated page-space matrix is offered to the
/// single-run in-place editor, which must preserve that matrix.
@Suite("Rotated text runs")
struct RotatedTextRunTests {
  @Test func finderFindsTheNinetyDegreeLineOnly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.transformedTextPages())
    let pageID = try #require(parsed.pageIDs.first)
    let runs = try PageTextEditing.rotatedTextRuns(pageID: pageID, in: parsed.graph)
    let rotated = try #require(runs.first(where: { $0.text.contains("Rotated") }))
    #expect(abs(rotated.rotationDegrees - 90) < 0.01)
    #expect(!rotated.rect[2].isNaN && rotated.rect[2] > rotated.rect[0])
    #expect(!runs.contains { $0.text.contains("Scaled") })
  }

  @Test func replacingARotatedRunKeepsTheTextMatrix() throws {
    let parsed = try PDFParser.parse(PDFFixtures.transformedTextPages())
    let pageID = try #require(parsed.pageIDs.first)
    let target = try #require(
      try PageTextEditing.rotatedTextRuns(pageID: pageID, in: parsed.graph)
        .first(where: { $0.text.contains("Rotated") }))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: target.runIndex, replacement: "Rotated edits")
      ]), to: parsed.graph)
    let bytes = try PDFWriter.write(edited)
    let reopened = try #require(PDFDocument(data: bytes))
    #expect(reopened.string?.contains("Rotated edits") == true)
    #expect(reopened.string?.contains("Rotated line") == false)
    #expect(reopened.string?.contains("Scaled line") == true)
    let reparsed = try PDFParser.parse(bytes)
    let reopenedPage = try #require(reparsed.pageIDs.first)
    let content = try PageContent.load(pageID: reopenedPage, in: reparsed.graph)
    let stream = String(decoding: content.bytes, as: UTF8.self)
    #expect(stream.contains("0 1 -1 0 200 200 Tm"))
  }
}
