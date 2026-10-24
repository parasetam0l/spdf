import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// TXT-02: edited mixed-font paragraph reflow on the private corpus. The test
/// skips when the owner document is absent and never prints document content.
@Suite("TXT-02 edited mixed-font paragraph")
struct TXT02CorpusTests {
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
        if b[0] < bounds[2] && b[2] > bounds[0]
          && b[1] < bounds[3] && b[3] > bounds[1]
        {
          return nil
        }
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

  private static func excludedBounds(_ candidate: TextParagraphCandidate) -> [Double] {
    [
      candidate.bounds[0] - 2, candidate.bounds[1] - 2,
      candidate.bounds[2] + 4, candidate.bounds[3] + 2,
    ]
  }

  private static func load() throws -> (
    source: Data, parsed: ParsedPDF, candidate: TextParagraphCandidate,
    pageID: PDFObjectID
  )? {
    let url = repositoryRoot.appendingPathComponent("Work/Corpus/downloads/doc-16.pdf")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let source = try Data(contentsOf: url, options: .alwaysMapped)
    let parsed = try PDFParser.parse(source)
    let pageID = parsed.pageIDs[0]
    let candidates = try ParagraphReconstruction.candidatesForEditing(
      pageID: pageID, in: parsed.graph)
    guard
      let candidate = candidates.first(where: {
        $0.text.hasPrefix("Birleştirilmiş sınıflar öğretimi")
      })
    else { return nil }
    return (source, parsed, candidate, pageID)
  }

  @Test func editedMixedFontParagraphUsesSourceSubsetsAndPreservesNeighbors() throws {
    guard let (source, parsed, candidate, pageID) = try Self.load() else { return }
    let oldWord = "programında"
    let newWord = "proğramında"
    #expect(candidate.text.components(separatedBy: oldWord).count == 2)
    let replacement = candidate.text.replacingOccurrences(of: oldWord, with: newWord)
    let beforeLayout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let beforeOutside = Self.snapshots(
      beforeLayout, excluding: Self.excludedBounds(candidate))
    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement,
      in: parsed.graph).plan
    #expect(plan.fontSize == candidate.fontSize)
    #expect(plan.lines.count == candidate.lineIndices.count)
    let styles = Set(
      plan.lines.flatMap(\.segments).map { plan.styles[$0.styleIndex].fontResource })
    #expect(styles.count > 1)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate, replacement: replacement)
      ]), to: parsed.graph)
    let reopened1 = try PDFParser.parse(
      try PDFWriter.write(edited, droppingLinearization: true))
    let reopened2 = try PDFParser.parse(
      try PDFWriter.write(reopened1.graph, droppingLinearization: true))
    for reopened in [reopened1, reopened2] {
      let layout = try PageTextLayout.build(
        pageID: reopened.pageIDs[0], in: reopened.graph)
      let text = Self.normalized(layout.clusters.map(\.text).joined())
      #expect(text.contains(Self.normalized(replacement)))
      #expect(
        Self.snapshots(layout, excluding: Self.excludedBounds(candidate)) == beforeOutside)
    }
    #expect(try Data(contentsOf: Self.repositoryRoot.appendingPathComponent(
      "Work/Corpus/downloads/doc-16.pdf")) == source)
  }

  @Test func uncoveredEditedCharacterRefusesBeforeMutation() throws {
    guard let (_, parsed, candidate, pageID) = try Self.load() else { return }
    let before = try PDFWriter.write(parsed.graph, droppingLinearization: true)
    do {
      _ = try ParagraphReflow.plan(
        pageID: pageID, candidate: candidate,
        replacement: candidate.text.replacingOccurrences(of: "sınıf", with: "漢"),
        in: parsed.graph)
      Issue.record("Mixed-font reflow accepted a character no source font covers")
    } catch let error as PDFError {
      #expect(error.message == PageTextFontCapability.uncoveredCharacterMessage("漢"))
    }
    #expect(try PDFWriter.write(parsed.graph, droppingLinearization: true) == before)
  }
}
