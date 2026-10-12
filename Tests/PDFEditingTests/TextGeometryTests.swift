import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P16-001/003/004/009/010/013/015/016/017 evidence: glyph geometry, lines,
/// words, hit testing, selection text, and normalized search.
@Suite("Text geometry")
struct TextGeometryTests {
  private func layout(of data: Data, pageIndex: Int = 0) throws -> PageTextLayout {
    let parsed = try PDFParser.parse(data)
    let content = try PageContent.load(pageID: parsed.pageIDs[pageIndex], in: parsed.graph)
    return try PageTextLayout.build(in: content, graph: parsed.graph)
  }

  @Test func glyphLinesAndWordsFromWidths() throws {
    let layout = try layout(of: PDFFixtures.textWidthsPages())
    #expect(layout.clusters.count == 4)
    #expect(layout.clusters.map(\.text) == ["A", "B", "C", "D"])
    #expect(layout.lines.count == 1)
    #expect(layout.words == [0..<2, 2..<4])
    #expect(layout.clusters[0].bounds == [42, 710, 52, 730])
    #expect(layout.clusters[2].bounds == [72, 710, 82, 730])
    #expect(layout.text(in: 0..<4) == "ABCD")
    #expect(layout.text(in: 0..<2) == "AB")
    #expect(layout.clusters.map(\.runIndex) == [0, 0, 1, 1])
  }

  @Test func linesAndWordsAcrossMultipleLines() throws {
    let layout = try layout(of: PDFFixtures.textEditPages())
    #expect(layout.lines.count == 3)
    #expect(layout.text(in: layout.lines[0]).contains("Replace this text"))
    #expect(layout.text(in: layout.lines[1]).contains("Kern"))
    #expect(layout.text(in: layout.lines[2]).contains("Quotes (kept)"))
    let quotesLine = layout.lines[2]
    let words = layout.words.filter { quotesLine.contains($0.lowerBound) }
    #expect(words.count == 2)
    #expect(layout.text(in: words[0]) == "Quotes")
    #expect(layout.text(in: words[1]) == "(kept)")
  }

  @Test func embeddedProgramBoundsExtendHitBoxesConservatively() throws {
    // P14-016: with an embedded program, cluster boxes are the union of the
    // conservative size estimate and the glyph's real ink box. C descends
    // (yMin -29 of 2048 units) below the baseline; A does not (yMin 0), so
    // its box stays the estimate. The union never shrinks the estimate.
    let layout = try layout(of: PDFFixtures.fontEmbeddedPages())
    #expect(layout.lines.count == 2)
    let line = layout.lines[0]
    #expect(line.count == 3)
    let a = layout.clusters[line.lowerBound]
    let c = layout.clusters[line.lowerBound + 2]
    #expect(a.text == "A" && c.text == "C")
    // A: ink inside the estimate on every side.
    #expect(a.bounds == [42, 700, 58.416, 724])
    // C: the descender pulls the bottom edge below the baseline to
    // 700 - 29 * 24 / 2048 = 699.66015625.
    #expect(c.bounds[3] == 724)
    let expectedBottom = 700 - 29.0 * 24 / 2048
    #expect(abs(c.bounds[1] - expectedBottom) < 1e-9)
    // Hit testing now reaches the descender ink that the size estimate
    // missed: a probe at y 699.8 inside C's ink lands on C.
    #expect(layout.clusterIndex(at: [c.bounds[0] + 2, 699.8]) == line.lowerBound + 2)
    // The fi ligature sits on line 2 with a zero-width estimate (code 1 is
    // outside the Widths range); its ink box supplies the real right edge
    // (xMax 1098 of 2048 units) while the height stays the estimate top.
    let ligature = layout.clusters[layout.lines[1].lowerBound]
    #expect(ligature.text == "ﬁ")
    #expect(ligature.bounds[0] == 42)
    #expect(ligature.bounds[1] == 660)
    #expect(abs(ligature.bounds[2] - (42 + 1098.0 * 24 / 2048)) < 1e-9)
    #expect(ligature.bounds[3] == 684)
  }

  @Test func combiningMarksPreserveMappingsInBothOrders() throws {
    // P14-018: extraction, word grouping, selection, and search keep the
    // combining mark with its base in both stream orders, and each cluster
    // keeps its own source code for reverse mapping.
    let layout = try layout(of: PDFFixtures.combiningMarkPages())
    #expect(layout.lines.count == 2)
    let first = layout.lines[0]
    let second = layout.lines[1]
    // Both lines extract as e + U+0301 (decomposed) in logical order,
    // including the reordered line that draws the mark first.
    #expect(layout.text(in: first) == "e\u{0301}")
    #expect(layout.text(in: second) == "e\u{0301}")
    // Source codes survive in the logical order: base is 'e' (101), mark is
    // code 1 with text U+0301.
    #expect(layout.clusters[first.lowerBound].code == 101)
    #expect(layout.clusters[first.lowerBound + 1].code == 1)
    #expect(layout.clusters[first.lowerBound + 1].text == "\u{0301}")
    #expect(layout.clusters[second.lowerBound].code == 101)
    #expect(layout.clusters[second.lowerBound + 1].code == 1)
    // The mark never starts a word.
    #expect(layout.words == [first, second])
    // Selection at the base covers both clusters as one word.
    let probe = [
      layout.clusters[first.lowerBound].bounds[0] + 1,
      (layout.clusters[first.lowerBound].bounds[1] + layout.clusters[first.lowerBound].bounds[3])
        / 2,
    ]
    #expect(layout.wordSelection(at: probe) == first)
    // Search: a precomposed query matches the decomposed document (canonical
    // equivalence) and highlights both clusters of each pair.
    let canonical = TextSearch.search(query: "\u{00E9}", in: layout)
    #expect(canonical.count == 2)
    #expect(canonical[0].clusterRange == first)
    #expect(canonical[1].clusterRange == second)
    #expect(canonical[0].bounds.count == 2)
    #expect(TextSearch.search(query: "\u{00E9}", in: layout, options: TextSearchOptions(wholeWord: true)).count == 2)
    // The decomposed query matches too.
    #expect(TextSearch.search(query: "e\u{0301}", in: layout).count == 2)
  }

  @Test func multiColumnPagesReadColumnByColumn() throws {
    // P16-007: baseline-grouped lines would interleave the columns; the
    // gutter splits each baseline and orders the page column-major.
    let layout = try layout(of: PDFFixtures.twoColumnPages())
    #expect(layout.lines.count == 6)
    let texts = layout.lines.map { layout.text(in: $0) }
    #expect(
      texts == ["Left one", "Left two", "Left three", "Right one", "Right two", "Right three"])
    // Selection and words stay inside their column segment. This fixture's
    // standard-14 font has no /Widths, so cluster boxes are zero-width
    // markers at the glyph origin (the conservative profile).
    let probe = [320.0, 686.0]
    let word = try #require(layout.wordSelection(at: probe))
    #expect(layout.text(in: word) == "Right")
    let line = try #require(layout.lineIndex(containing: word.lowerBound))
    #expect(layout.text(in: layout.lines[line]) == "Right two")
    // Search is line-bounded per column segment: a query spanning the
    // visual baseline ("one Right") never matches.
    #expect(TextSearch.search(query: "one Right", in: layout).isEmpty)
    #expect(TextSearch.search(query: "Right two", in: layout).count == 1)
    // Whole-page text in reading order is column-major.
    #expect(layout.text(in: 0..<layout.clusters.count).contains("Left threeRight one"))
    // A single-column page keeps one segment per baseline (no regression).
    let single = try self.layout(of: PDFFixtures.textEditPages())
    #expect(single.lines.count == 3)
  }

  @Test func rotatedRunsGetComposedBounds() throws {
    // P16-008: a 90-degree run's bounds follow its real orientation (the
    // fixture draws "Rotated line" with `0 1 -1 0 200 200 Tm`), and a scaled
    // run's bounds scale with its matrix. The identity matrix reproduces the
    // historical axis-aligned estimate exactly.
    let layout = try layout(of: PDFFixtures.transformedTextPages())
    let rotatedLine = try #require(layout.lines.first { line in
      layout.text(in: line).contains("Rotated")
    })
    let cluster = layout.clusters[rotatedLine.lowerBound]
    #expect(cluster.text == "R")
    // The 12 pt em runs along -x from the baseline (matrix 0 1 -1 0), so the
    // glyph box spans x 188..200 at baseline y 200.
    #expect(cluster.origin == [200, 200])
    let bounds = cluster.bounds
    #expect(bounds[0] <= 188.001)
    #expect(bounds[2] == 200)
    #expect(bounds[1] == 200)
    #expect(bounds[3] == 200)
    // Hit testing reaches the rotated glyph column.
    #expect(layout.clusterIndex(at: [194, 200]) != nil)

    let scaledLine = try #require(layout.lines.first { line in
      layout.text(in: line).contains("Scaled")
    })
    let scaled = layout.clusters[scaledLine.lowerBound]
    // The 2x matrix doubles the em: the box is 24 pt tall on the baseline.
    #expect(scaled.bounds[3] - scaled.bounds[1] >= 24 - 0.001)
    #expect(scaled.origin == [42, 500])
  }

  @Test func ligatureAndCombiningSelectionBoundaries() throws {
    // P16-025: a ligature cluster selects as one unit carrying its
    // multi-character Unicode, and a combining sequence selects with its
    // base without ever splitting them.
    let embedded = try layout(of: PDFFixtures.fontEmbeddedPages())
    let ligatureLine = embedded.lines[1]
    let ligature = embedded.clusters[ligatureLine.lowerBound]
    #expect(ligature.text == "ﬁ")
    #expect(ligatureLine.count == 1)
    // Character/word/line selection all resolve to the single cluster.
    let ligatureProbe = [42.0, 666.0]
    #expect(embedded.characterSelection(at: ligatureProbe) == ligatureLine)
    #expect(embedded.wordSelection(at: ligatureProbe) == ligatureLine)
    #expect(embedded.lineSelection(at: ligatureProbe) == ligatureLine)
    // The ligature's own form matches, and the decomposed "fi" matches too:
    // the search folding applies the system's compatibility mapping, so
    // typing "fi" finds the ligature while the extracted/copied text stays
    // the exact U+FB01 form.
    #expect(TextSearch.search(query: "ﬁ", in: embedded).count == 1)
    #expect(TextSearch.search(query: "fi", in: embedded).count == 1)
    #expect(embedded.text(in: ligatureLine) == "ﬁ")

    // Combining pair: word selection spans base + mark, and the selection
    // never splits them (the mark is never its own word).
    let combining = try layout(of: PDFFixtures.combiningMarkPages())
    for line in combining.lines {
      let word = try #require(combining.wordSelection(at: {
        let cluster = combining.clusters[line.lowerBound]
        return [cluster.bounds[0], (cluster.bounds[1] + cluster.bounds[3]) / 2]
      }()))
      #expect(word == line)
      #expect(combining.text(in: word) == "e\u{0301}")
    }
  }

  @Test func hitTestingAndSelectionHelpers() throws {
    let layout = try layout(of: PDFFixtures.textWidthsPages())
    #expect(layout.clusterIndex(at: [45, 715]) == 0)
    #expect(layout.clusterIndex(at: [75, 715]) == 2)
    #expect(layout.clusterIndex(at: [45, 300]) == nil)
    #expect(layout.characterSelection(at: [45, 715]) == 0..<1)
    #expect(layout.wordSelection(at: [75, 715]) == 2..<4)
    #expect(layout.lineSelection(at: [75, 715]) == 0..<4)
  }

  @Test func searchOptionsAndHighlightBounds() throws {
    let layout = try layout(of: PDFFixtures.textWidthsPages())
    let insensitive = TextSearch.search(query: "cd", in: layout)
    #expect(insensitive.count == 1)
    #expect(insensitive[0].clusterRange == 2..<4)
    #expect(insensitive[0].lineIndex == 0)
    #expect(insensitive[0].bounds == [layout.clusters[2].bounds, layout.clusters[3].bounds])

    let sensitive = TextSearch.search(
      query: "cd", in: layout, options: TextSearchOptions(caseSensitive: true))
    #expect(sensitive.isEmpty)
    #expect(
      TextSearch.search(query: "AB", in: layout, options: TextSearchOptions(wholeWord: true))
        .count == 1)
    #expect(
      TextSearch.search(query: "C", in: layout, options: TextSearchOptions(wholeWord: true))
        .isEmpty)
    #expect(TextSearch.search(query: "C", in: layout).count == 1)
    #expect(TextSearch.search(query: "zz", in: layout).isEmpty)
  }

  @Test func diacriticInsensitiveSearch() throws {
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    var content = Data("BT /F1 20 Tf 42 700 Td (caf".utf8)
    content.append(0xE9)  // WinAnsi é
    content.append(Data(") Tj ET\n".utf8))
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: content))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let layout = try PageTextLayout.build(
      in: PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph), graph: parsed.graph)
    #expect(layout.clusters.map(\.text).joined() == "caf\u{00E9}")
    #expect(TextSearch.search(query: "cafe", in: layout).isEmpty)
    let folded = TextSearch.search(
      query: "cafe", in: layout, options: TextSearchOptions(diacriticInsensitive: true))
    #expect(folded.count == 1)
    #expect(layout.text(in: folded[0].clusterRange) == "caf\u{00E9}")
  }

  @Test func searchDeliversPartialResultsOnRequest() throws {
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("BT /F1 20 Tf 42 700 Td (ABABAB) Tj ET\n".utf8)))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let layout = try PageTextLayout.build(
      in: PageContent.load(pageID: parsed.pageIDs[0], in: parsed.graph), graph: parsed.graph)
    var seen = 0
    let partial = TextSearch.search(query: "AB", in: layout) { _ in
      seen += 1
      return false
    }
    #expect(partial.count == 1 && seen == 1)
    #expect(TextSearch.search(query: "AB", in: layout).count == 3)
  }
}
