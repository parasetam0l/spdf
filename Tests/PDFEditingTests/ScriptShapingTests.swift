import CoreText
import Foundation
import Testing

@testable import PDFEditing

/// FNT-04: Core Text shaping with complete grapheme clusters, grapheme-safe
/// caret/deletion/replacement, and the glyph-cluster-to-PDF source map that
/// keeps ligatures and combining sequences atomic. Turkish (İ/ı) and
/// decomposed combining-accent examples are required by the roadmap row.
@Suite("Script shaping")
struct ScriptShapingTests {
  @Test func shapingClustersCoverEveryGraphemeOnce() throws {
    let shaped = ScriptShaping.shape("İstanbul", fontName: "Helvetica", pointSize: 12)
    #expect(shaped.fontName == "Helvetica")
    #expect(shaped.isLogicallyOrdered)
    #expect(shaped.coversAllSourceOffsets)
    #expect(shaped.clusters.count == 8)  // İ s t a n b u l
    #expect(shaped.clusters.map(\.text).joined() == "İstanbul")
    #expect(shaped.clusters.allSatisfy { $0.graphemeCount == 1 })
    #expect(Set(shaped.clusters.map(\.sourceRange.lowerBound)) == Set([0, 1, 2, 3, 4, 5, 6, 7]))
    #expect(shaped.advance > 0)
    #expect(shaped.missingGlyphCount == 0)

    let dotless = ScriptShaping.shape("ıI iİ", fontName: "Helvetica", pointSize: 12)
    #expect(dotless.coversAllSourceOffsets)
    #expect(dotless.clusters.map(\.text).joined() == "ıI iİ")
  }

  @Test func combiningMarksStayAttachedToTheirBase() throws {
    let text = "e\u{0301}x I\u{0307}stanbul"
    let shaped = ScriptShaping.shape(text, fontName: "Helvetica", pointSize: 12)
    #expect(shaped.coversAllSourceOffsets)
    #expect(shaped.clusters.map(\.text).joined() == text)
    // Base + combining acute is one cluster, not two.
    let accented = try #require(shaped.clusters.first)
    #expect(accented.text == "e\u{0301}")
    #expect(accented.sourceRange == 0..<2)
    #expect(accented.graphemeCount == 1)
    // Decomposed dotted capital İ (I + U+0307) is also one cluster.
    let decomposedCapital = try #require(shaped.clusters.first { $0.text == "I\u{0307}" })
    #expect(decomposedCapital.sourceRange == 4..<6)

    #expect(ScriptGraphemes.boundaries(in: text).contains(2))
    #expect(!ScriptGraphemes.isBoundary(1, in: text))
    #expect(ScriptGraphemes.cluster(containing: 1, in: text) == 0..<2)
    #expect(ScriptGraphemes.snap(1..<2, in: text) == 0..<2)
    // Deleting backwards from after the accent removes the whole grapheme.
    #expect(ScriptGraphemes.deleteBackward(at: 2, in: text) == 0..<2)
    #expect(ScriptGraphemes.deleteForward(at: 0, in: text) == 0..<2)
    #expect(ScriptGraphemes.caretOffset(2, movingForward: false, in: text) == 0)
    #expect(ScriptGraphemes.caretOffset(1, movingForward: false, in: text) == 0)
    #expect(ScriptGraphemes.caretOffset(0, movingForward: true, in: text) == 2)
    #expect(
      ScriptGraphemes.replacing(1..<2, in: text, with: "X")
        == "Xx I\u{0307}stanbul")
  }

  @Test func ligatureClustersCarrySeveralGraphemesAndOneGlyph() throws {
    let shaped = ScriptShaping.shape("office", fontName: "Helvetica", pointSize: 12)
    #expect(shaped.coversAllSourceOffsets)
    #expect(shaped.clusters.map(\.text).joined() == "office")
    let ligature = try #require(shaped.clusters.first { $0.text == "fi" })
    #expect(ligature.graphemeCount == 2)
    #expect(ligature.glyphRange.count == 1)
    #expect(ligature.sourceRange == 2..<4)
    // Unicode grapheme snapping alone cannot see a shaping ligature; the
    // source map below is what keeps the stored ligature code atomic.
    #expect(ScriptGraphemes.snap(2..<3, in: "office") == 2..<3)
    #expect(ScriptGraphemes.replacing(2..<3, in: "office", with: "X") == "ofXice")
  }

  @Test func glyphClusterSourceMapKeepsLigatureAtomic() throws {
    // Stored PDF: "office" with the fi pair as one stored code (glyph text
    // "fi"), exactly as a subset font with a ligature code stores it.
    let glyphs = [
      PDFSourceGlyph(text: "o", codes: [0x10]),
      PDFSourceGlyph(text: "f", codes: [0x11]),
      PDFSourceGlyph(text: "fi", codes: [0x12]),
      PDFSourceGlyph(text: "c", codes: [0x13]),
      PDFSourceGlyph(text: "e", codes: [0x14]),
    ]
    let shaped = ScriptShaping.shape("office", fontName: "Helvetica", pointSize: 12)
    let map = try GlyphClusterSourceMap(text: "office", glyphs: glyphs, shaped: shaped)
    #expect(map.codes == [0x10, 0x11, 0x12, 0x13, 0x14])
    let ligature = try #require(map.clusters.first { $0.text == "fi" })
    #expect(ligature.pdfGlyphRange == 2..<3)
    #expect(ligature.codeRange == 2..<3)
    // Editing one half of the stored ligature expands to the whole cluster.
    #expect(try map.codeRange(for: 2..<3) == 2..<3)
    #expect(try map.codeRange(for: 2..<4) == 2..<3)
    #expect(map.sourceRange(forCodeRange: 2..<3) == 2..<4)
    let deletion = try map.applying(replacing: 2..<3, with: "", encoded: [])
    #expect(deletion.replacedRange == 2..<4)
    #expect(deletion.text == "ofce")
    #expect(deletion.codes == [0x10, 0x11, 0x13, 0x14])
    let replacement = try map.applying(replacing: 3..<4, with: "X", encoded: [0x22])
    #expect(replacement.text == "ofXce")
    #expect(replacement.codes == [0x10, 0x11, 0x22, 0x13, 0x14])
    // A caret inside the ligature's source range inserts before the single
    // stored ligature code rather than splitting it.
    let insertion = try map.inserting(encoded: [0x33], text: "Y", at: 3)
    #expect(insertion.text == "ofYfice")
    #expect(insertion.codes == [0x10, 0x11, 0x33, 0x12, 0x13, 0x14])
  }

  @Test func glyphClusterSourceMapKeepsCombiningClusterAtomic() throws {
    let text = "e\u{0301}x"
    let glyphs = [
      PDFSourceGlyph(text: "e", codes: [0x20]),
      PDFSourceGlyph(text: "\u{0301}", codes: [0x01]),
      PDFSourceGlyph(text: "x", codes: [0x21]),
    ]
    let shaped = ScriptShaping.shape(text, fontName: "Helvetica", pointSize: 12)
    let map = try GlyphClusterSourceMap(text: text, glyphs: glyphs, shaped: shaped)
    #expect(map.codes == [0x20, 0x01, 0x21])
    let accented = try #require(map.clusters.first)
    #expect(accented.sourceRange == 0..<2)
    #expect(accented.pdfGlyphRange == 0..<2)
    #expect(accented.codeRange == 0..<2)
    // Removing the accent alone snaps to base + mark.
    let removal = try map.applying(replacing: 1..<2, with: "", encoded: [])
    #expect(removal.replacedRange == 0..<2)
    #expect(removal.text == "x")
    #expect(removal.codes == [0x21])
    // Replacing the base alone also snaps to the complete grapheme.
    let replaced = try map.applying(replacing: 0..<1, with: "a", encoded: [0x22])
    #expect(replaced.text == "ax")
    #expect(replaced.codes == [0x22, 0x21])
  }

  @Test func glyphClusterSourceMapRefusesToSplitStoredCodes() throws {
    // A stored code whose glyph text spans two graphemes cannot be edited
    // from a shaped form that separates them: the map must refuse.
    let glyphs = [
      PDFSourceGlyph(text: "fi", codes: [0x12]),
      PDFSourceGlyph(text: "x", codes: [0x13]),
    ]
    var shaped = ScriptShaping.ShapedText(
      text: "fix", fontName: "Test", pointSize: 12, language: nil, glyphs: [
        ScriptShaping.Glyph(glyphID: 1, advance: 5, sourceRange: 0..<1, isFallback: false),
        ScriptShaping.Glyph(glyphID: 2, advance: 5, sourceRange: 1..<2, isFallback: false),
        ScriptShaping.Glyph(glyphID: 3, advance: 5, sourceRange: 2..<3, isFallback: false),
      ],
      clusters: [
        ScriptShaping.Cluster(
          text: "f", sourceRange: 0..<1, glyphRange: 0..<1, advance: 5, isFallback: false),
        ScriptShaping.Cluster(
          text: "i", sourceRange: 1..<2, glyphRange: 1..<2, advance: 5, isFallback: false),
        ScriptShaping.Cluster(
          text: "x", sourceRange: 2..<3, glyphRange: 2..<3, advance: 5, isFallback: false),
      ], missingGlyphCount: 0, isLogicallyOrdered: true)
    #expect(throws: GlyphClusterSourceMap.MappingError.self) {
      _ = try GlyphClusterSourceMap(text: "fix", glyphs: glyphs, shaped: shaped)
    }
    // A decoded-text mismatch refuses as well.
    shaped = ScriptShaping.ShapedText(
      text: "fix", fontName: shaped.fontName, pointSize: shaped.pointSize,
      language: nil, glyphs: shaped.glyphs, clusters: shaped.clusters,
      missingGlyphCount: 0, isLogicallyOrdered: true)
    #expect(throws: GlyphClusterSourceMap.MappingError.textMismatch) {
      _ = try GlyphClusterSourceMap(text: "fiy", glyphs: [
        PDFSourceGlyph(text: "f", codes: [0x01]),
        PDFSourceGlyph(text: "ix", codes: [0x02]),
      ], shaped: shaped)
    }
  }

  @Test func graphemeSafeSegmentsNeverSplitACombiningPair() throws {
    let formatA = PageTextFormat(font: .helvetica, size: 12)
    let formatB = PageTextFormat(font: .helvetica, size: 16)
    let text = "e\u{0301}x"
    let segments = [
      PageTextSegment(text: "e", x: 42, format: formatA, width: 6),
      PageTextSegment(text: "\u{0301}", x: 48, format: formatB, width: 0),
      PageTextSegment(text: "x", x: 48, format: formatA, width: 6),
    ]
    let result = GraphemeSafeTextSegments.normalize(segments: segments, text: text)
    #expect(result.issue == nil)
    #expect(result.segments.map(\.text).joined() == text)
    #expect(result.segments.count == 2)
    #expect(result.segments[0].text == "e\u{0301}")
    #expect(result.segments[0].x == 42)
    #expect(result.segments[0].format.size == 12)  // base formatting wins
    #expect(result.segments[0].width == 6)
    #expect(result.segments[1].text == "x")

    // The ordinary case (boundaries already aligned) is unchanged.
    let plain = [
      PageTextSegment(text: "abc", x: 42, format: formatA, width: 18),
      PageTextSegment(text: "def", x: 60, format: formatB, width: 18),
    ]
    let unchanged = GraphemeSafeTextSegments.normalize(segments: plain, text: "abcdef")
    #expect(unchanged.segments == plain)
    let line = PageTextLine(
      text: text, x: 42, baseline: 700, segments: segments, endsParagraph: false)
    let normalized = GraphemeSafeTextSegments.normalize(line)
    #expect(normalized.issue == nil)
    #expect(normalized.line.segments.map(\.text).joined() == text)
    #expect(normalized.line.segments.count == 2)
  }

  @Test func turkishCaseAndUnicodeFormsArePreserved() throws {
    #expect(ScriptGraphemes.uppercased("istanbul", localeIdentifier: "tr") == "İSTANBUL")
    #expect(ScriptGraphemes.lowercased("I", localeIdentifier: "tr") == "ı")
    #expect(ScriptGraphemes.lowercased("İ", localeIdentifier: "tr") == "i")
    // The input forms are preserved by grapheme-safe replacement: precomposed
    // U+0130 stays one cluster, decomposed I + U+0307 stays one cluster.
    #expect(ScriptGraphemes.boundaries(in: "İ").count == 2)
    #expect(ScriptGraphemes.boundaries(in: "I\u{0307}").count == 2)
    #expect(ScriptGraphemes.replacing(0..<1, in: "İstanbul", with: "I") == "Istanbul")
    #expect(
      ScriptGraphemes.replacing(0..<2, in: "I\u{0307}stanbul", with: "İ") == "İstanbul")
  }
}
