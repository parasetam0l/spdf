import CoreText
import Foundation
import Testing

@testable import PDFEditing

/// FNT-05: explicit logical and visual ordering, caret conversion, mirrored
/// punctuation and refusal of unsupported explicit controls.
@Suite("Bidirectional text")
struct BidiTextTests {
  @Test func emptyParagraphAndLatinOrdering() throws {
    let empty = try BidiText.resolve("")
    #expect(empty.runs.isEmpty)
    #expect(empty.baseLevel == 0)

    let latin = try BidiText.resolve("hello")
    #expect(latin.baseLevel == 0)
    #expect(latin.runs.count == 1)
    #expect(latin.visualString == "hello")
    #expect(latin.coversEveryUnitOnce)
    #expect(!latin.hasRightToLeftContent)
  }

  @Test func hebrewParagraphReversesInVisualOrder() throws {
    let paragraph = try BidiText.resolve("שלום")
    #expect(paragraph.baseLevel == 1)
    #expect(paragraph.hasRightToLeftContent)
    #expect(paragraph.coversEveryUnitOnce)
    #expect(paragraph.runs.count == 1)
    #expect(paragraph.runs[0].text == "שלום")
    #expect(paragraph.visualString == "םולש")
    // Logical caret 0 sits at the visual right edge; the end at the left.
    #expect(paragraph.visualOffset(forLogical: 0) == 4)
    #expect(paragraph.visualOffset(forLogical: 4) == 0)
  }

  @Test func latinParagraphWithArabicAndNumbers() throws {
    // Expected visual order (LTR paragraph): ABC 123 followed by the
    // reversed Arabic run, exactly as Unicode L2 reordering defines.
    let paragraph = try BidiText.resolve("ABC مرحبا 123", baseDirection: .leftToRight)
    #expect(paragraph.baseLevel == 0)
    #expect(paragraph.coversEveryUnitOnce)
    #expect(paragraph.runs.map(\.direction) == [.leftToRight, .leftToRight, .rightToLeft])
    #expect(paragraph.visualString == "ABC 123 ابحرم")
    let levels = paragraph.runs.map(\.level)
    #expect(levels == [0, 2, 1])
  }

  @Test func rightToLeftParagraphWithNumbers() throws {
    let paragraph = try BidiText.resolve("مرحبا 123")
    #expect(paragraph.baseLevel == 1)
    #expect(paragraph.hasRightToLeftContent)
    #expect(paragraph.coversEveryUnitOnce)
    #expect(paragraph.visualString == "123 ابحرم")
    // Arabic first in logical order is rightmost in a RTL paragraph.
    #expect(paragraph.runs.last?.direction == .rightToLeft)
  }

  @Test func mixedParagraphCaretBoundaries() throws {
    let paragraph = try BidiText.resolve("ABC مرحبا 123", baseDirection: .leftToRight)
    #expect(paragraph.visualOffset(forLogical: 0) == 0)
    #expect(paragraph.visualOffset(forLogical: 4) == 13)
    #expect(paragraph.visualOffset(forLogical: 10) == 4)
    #expect(paragraph.visualOffset(forLogical: 13) == 13)
    // Interior boundaries round-trip; paragraph edges are Home/End affinities
    // and intentionally share a visual position with a neighbouring boundary.
    for logical in 1..<13 {
      let visual = paragraph.visualOffset(forLogical: logical)
      let restored = paragraph.logicalOffset(forVisual: visual)
      #expect(abs(restored - logical) <= 1, "logical \(logical) -> \(visual) -> \(restored)")
    }
  }

  @Test func punctuationMirrorsOnlyInRightToLeftContext() {
    #expect(BidiText.mirrored("(a)") == ")a(")
    #expect(BidiText.mirrored("a(b)c") == "a)b(c")
    #expect(BidiText.mirrored("abc") == "abc")
    let mixed = try? BidiText.resolve("abc (שלום) def", baseDirection: .leftToRight)
    #expect(mixed?.coversEveryUnitOnce == true)
    #expect(mixed?.hasRightToLeftContent == true)
    #expect(mixed?.visualString.contains("שלום") == false)
  }

  @Test func trailingWhitespaceTakesParagraphLevel() throws {
    let paragraph = try BidiText.resolve("abc שלום ", baseDirection: .leftToRight)
    let count = paragraph.levels.count
    #expect(count == 9)
    #expect(paragraph.levels[count - 1] == 0)
    // The trailing space joins no right-to-left run after L1.
    #expect(paragraph.runs.last?.logicalRange.upperBound == 9)
  }

  @Test func explicitControlsAndBOMRefused() {
    do {
      _ = try BidiText.resolve("a\u{202B}b")
      Issue.record("expected an explicit-control refusal")
    } catch let error as BidiTextError {
      #expect(error.description.contains("202B"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
    do {
      _ = try BidiText.resolve("\u{FEFF}abc")
      Issue.record("expected a BOM refusal")
    } catch let error as BidiTextError {
      #expect(error.description.contains("Byte order mark"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func oversizedParagraphRefused() {
    let text = String(repeating: "a", count: BidiText.maximumUnits + 1)
    do {
      _ = try BidiText.resolve(text)
      Issue.record("expected a length refusal")
    } catch let error as BidiTextError {
      #expect(error.description.contains("too long"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  // MARK: - Contextual shaping

  static let arialUnicodePath = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"

  static func arialUnicode(_ size: CGFloat = 20) -> CTFont? {
    guard FileManager.default.fileExists(atPath: arialUnicodePath) else { return nil }
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
      URL(fileURLWithPath: arialUnicodePath) as CFURL) as? [CTFontDescriptor]
    guard let descriptor = descriptors?.first else { return nil }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
  }

  @Test func arabicContextualShapingUsesJoinedForms() throws {
    guard let font = Self.arialUnicode() else { return }
    let shaped = try BidiShaping.shape(
      "مرحبا", font: font, fontName: "ArialUnicodeMS", language: "ar")
    #expect(!shaped.hasMissingGlyphs)
    #expect(shaped.hasRightToLeftRuns)
    #expect(shaped.coversEveryUnit)
    #expect(shaped.glyphCount <= 5)
    // The shaped forms must not all be the isolated cmap glyphs.
    var isolated: Set<Int> = []
    for scalar in "مرحبا".unicodeScalars {
      var character = Array(String(scalar).utf16)
      var glyph: CGGlyph = 0
      if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) {
        isolated.insert(Int(glyph))
      }
    }
    let shapedGlyphs = Set(shaped.runs.flatMap { $0.glyphs.map(\.glyphID) })
    #expect(!isolated.isEmpty)
    #expect(!shapedGlyphs.subtracting(isolated).isEmpty)
  }

  @Test func hebrewAndIndicShapingCoverEveryUnit() throws {
    guard let font = Self.arialUnicode() else { return }
    let hebrew = try BidiShaping.shape(
      "שלום עולם", font: font, fontName: "ArialUnicodeMS", language: "he")
    #expect(!hebrew.hasMissingGlyphs)
    #expect(hebrew.hasRightToLeftRuns)
    #expect(hebrew.coversEveryUnit)
    #expect(hebrew.glyphCount == 9)

    let indic = try BidiShaping.shape(
      "नमस्ते", font: font, fontName: "ArialUnicodeMS", language: "hi")
    #expect(!indic.hasMissingGlyphs)
    #expect(indic.coversEveryUnit)
    #expect(indic.glyphCount <= 6)
    #expect(indic.runs.allSatisfy { $0.direction == .leftToRight })
  }

  @Test func mixedDirectionShapingMatchesCoreTextRunOrder() throws {
    guard let font = Self.arialUnicode() else { return }
    let text = "ABC مرحبا 123"
    let shaped = try BidiShaping.shape(
      text, font: font, fontName: "ArialUnicodeMS")
    #expect(shaped.coversEveryUnit)
    #expect(!shaped.hasMissingGlyphs)
    // Cross-check the declared visual run order against Core Text's own
    // bidirectional run order for the same attributed text.
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    var coreTextRanges: [Range<Int>] = []
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let range = CTRunGetStringRange(run)
      if range.length > 0 {
        coreTextRanges.append(Int(range.location)..<(Int(range.location) + Int(range.length)))
      }
    }
    #expect(shaped.runs.map(\.logicalRange) == coreTextRanges)
  }

  @Test func shapedCaretModelIsReversible() throws {
    guard let font = Self.arialUnicode() else { return }
    let shaped = try BidiShaping.shape(
      "ABC אבג DEF", font: font, fontName: "ArialUnicodeMS")
    #expect(shaped.coversEveryUnit)
    #expect(abs(shaped.caretX(forLogicalOffset: 0)) < 0.01)
    #expect(
      abs(shaped.caretX(forLogicalOffset: shaped.text.utf16.count) - shaped.totalAdvance)
        < 0.01)
    let positions = (0...shaped.text.utf16.count).map {
      shaped.caretX(forLogicalOffset: $0)
    }
    for boundary in 1..<shaped.text.utf16.count {
      let x = positions[boundary]
      // Boundaries on either side of a right-to-left run share one visual
      // caret position (affinity); only unique visual positions round-trip.
      let shared = positions.enumerated().contains {
        $0.offset != boundary && abs($0.element - x) < 0.5
      }
      if shared { continue }
      let restored = shaped.logicalOffset(nearestX: x)
      #expect(
        abs(restored - boundary) <= 1,
        "boundary \(boundary) -> \(restored) runs \(shaped.runs.map { $0.logicalRange })")
    }
  }

  @Test func missingGlyphsAreReportedNotFabricated() throws {
    let shaped = try BidiShaping.shape(
      "مرحبا", fontName: "Helvetica", pointSize: 14)
    #expect(shaped.hasMissingGlyphs)
    #expect(!shaped.missingScalars.isEmpty)
  }
}
