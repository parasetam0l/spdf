import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// TXT-01: the private-corpus transformed-size paragraph. This test skips in
/// CI when the owner corpus is absent and never prints document content.
@Suite("TXT-01 transformed paragraph")
struct TXT01CorpusTests {
  private static var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func snapshots(
    _ layout: PageTextLayout, excluding bounds: [Double]? = nil
  ) -> [String] {
    layout.clusters.compactMap { cluster in
      if let bounds {
        let b = cluster.bounds
        let overlaps =
          b[0] < bounds[2] && b[2] > bounds[0]
          && b[1] < bounds[3] && b[3] > bounds[1]
        if overlaps { return nil }
      }
      return [
        cluster.text,
        String(format: "%.6f", cluster.bounds[0]),
        String(format: "%.6f", cluster.bounds[1]),
        String(format: "%.6f", cluster.bounds[2]),
        String(format: "%.6f", cluster.bounds[3]),
        String(format: "%.6f", cluster.origin[0]),
        String(format: "%.6f", cluster.origin[1]),
      ].joined(separator: "|")
    }
  }

  @Test func transformedMixedFontParagraphReflowsAndPreservesNeighbors() throws {
    let corpus = Self.repositoryRoot
      .appendingPathComponent("Work/Corpus/downloads/doc-16.pdf")
    guard FileManager.default.fileExists(atPath: corpus.path) else { return }
    let source = try Data(contentsOf: corpus, options: .alwaysMapped)
    let parsed = try PDFParser.parse(source)
    let pageID = parsed.pageIDs[0]
    let candidates = try ParagraphReconstruction.candidatesForEditing(
      pageID: pageID, in: parsed.graph)
    guard
      let candidate = candidates.first(where: {
        $0.text.hasPrefix("Birleştirilmiş sınıflar öğretimi")
      })
    else {
      Issue.record("TXT-01 corpus paragraph was not reconstructed")
      return
    }
    #expect(candidate.fontSize == 10.02)
    #expect(candidate.lineIndices.count == 5)
    let beforeLayout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let beforePageText = Self.normalized(beforeLayout.clusters.map(\.text).joined())
    let targetText = Self.normalized(candidate.text)
    #expect(beforePageText.contains(targetText))
    let beforeOutside = Self.snapshots(
      beforeLayout,
      excluding: [
        candidate.bounds[0] - 2, candidate.bounds[1] - 2,
        candidate.bounds[2] + 4, candidate.bounds[3] + 2,
      ])
    let beforeOtherPages = try parsed.pageIDs.dropFirst().map { id in
      Self.snapshots(try PageTextLayout.build(pageID: id, in: parsed.graph))
    }

    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: candidate.text,
      in: parsed.graph).plan
    #expect(plan.lines.count == candidate.lineIndices.count)
    #expect(plan.fontSize == candidate.fontSize)
    let resources = Set(
      plan.lines.flatMap(\.segments).map { plan.styles[$0.styleIndex].fontResource })
    #expect(resources.count > 1)
    #expect(!plan.overflowed)

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: candidate.text)
      ]), to: parsed.graph)
    let saved1 = try PDFWriter.write(edited, droppingLinearization: true)
    let reopened1 = try PDFParser.parse(saved1)
    let saved2 = try PDFWriter.write(reopened1.graph, droppingLinearization: true)
    let reopened2 = try PDFParser.parse(saved2)

    for reopened in [reopened1, reopened2] {
      #expect(reopened.pageIDs.count == parsed.pageIDs.count)
      let layout = try PageTextLayout.build(
        pageID: reopened.pageIDs[0], in: reopened.graph)
      let pageText = Self.normalized(layout.clusters.map(\.text).joined())
      #expect(pageText.contains(targetText))
      #expect(
        Self.snapshots(
          layout,
          excluding: [
            candidate.bounds[0] - 2, candidate.bounds[1] - 2,
            candidate.bounds[2] + 4, candidate.bounds[3] + 2,
          ]) == beforeOutside,
        "Neighboring page-one clusters changed")
      let otherPages = try reopened.pageIDs.dropFirst().map { id in
        Self.snapshots(try PageTextLayout.build(pageID: id, in: reopened.graph))
      }
      #expect(otherPages == beforeOtherPages)
    }
    #expect(try Data(contentsOf: corpus) == source)
  }
}
