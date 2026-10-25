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

  /// A one-page graph whose only text is a single run drawn at `degrees`.
  private func angledPage(degrees: Double) throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = PDFObjectID(3)
    let radians = degrees * .pi / 180
    let cosine = cos(radians), sine = sin(radians)
    let content = String(
      format: "BT /F1 12 Tf %.6f %.6f %.6f %.6f 120 400 Tm (Angled line) Tj ET",
      cosine, sine, -sine, cosine)
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(content.utf8)))
    return (graph, pageID)
  }

  @Test func finderSupportsExplicitArbitraryAngles() throws {
    let (graph, pageID) = try angledPage(degrees: 30)
    let runs = try PageTextEditing.rotatedTextRuns(pageID: pageID, in: graph)
    let run = try #require(runs.first(where: { $0.text.contains("Angled") }))
    #expect(abs(run.rotationDegrees - 30) < 0.01)
    #expect(abs(run.anchor[0] - 120) < 0.01 && abs(run.anchor[1] - 400) < 0.01)
    let radians = 30.0 * .pi / 180
    #expect(abs(run.direction[0] - cos(radians)) < 1e-6)
    #expect(abs(run.direction[1] - sin(radians)) < 1e-6)
    #expect(abs(run.fontSize - 12) < 0.01)
    // The horizontal paragraph profile must not claim the angled run.
    #expect(try PageTextEditing.blocks(pageID: pageID, in: graph).isEmpty)
  }

  @Test func replacingAnAngledRunKeepsItsMatrix() throws {
    let (graph, pageID) = try angledPage(degrees: 30)
    let target = try #require(
      try PageTextEditing.rotatedTextRuns(pageID: pageID, in: graph)
        .first(where: { $0.text.contains("Angled") }))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: pageID, runIndex: target.runIndex, replacement: "Angled edits")
      ]), to: graph)
    let bytes = try PDFWriter.write(edited)
    let reopened = try PDFDocument(data: bytes)
    #expect(reopened?.string?.contains("Angled edits") == true)
    #expect(reopened?.string?.contains("Angled line") == false)
    let radians = 30.0 * .pi / 180
    let cosine = cos(radians), sine = sin(radians)
    let matrix = String(
      format: "%.6f %.6f %.6f %.6f 120 400 Tm", cosine, sine, -sine, cosine)
    let reparsed = try PDFParser.parse(bytes)
    let content = try PageContent.load(pageID: pageID, in: reparsed.graph)
    let stream = String(decoding: content.bytes, as: UTF8.self)
    #expect(stream.contains(matrix))
    let again = try PageTextEditing.rotatedTextRuns(pageID: pageID, in: reparsed.graph)
    let replaced = try #require(again.first(where: { $0.text.contains("Angled edits") }))
    #expect(abs(replaced.rotationDegrees - 30) < 0.01)
  }
}
