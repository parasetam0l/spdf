import CoreText
import Foundation

public enum ShapedTextError: Error, Equatable, CustomStringConvertible {
  case emptyText
  case bidiRefused(String)
  case missingGlyphs([UInt32])
  case invalidPointSize(Double)
  case fontUnavailable(String)

  public var description: String {
    switch self {
    case .emptyText:
      return "The shaped text is empty"
    case .bidiRefused(let reason):
      return "The bidirectional paragraph was refused: \(reason)"
    case .missingGlyphs(let scalars):
      let list = scalars.prefix(8).map {
        String(format: "U+%04X", $0)
      }.joined(separator: ", ")
      return "The font has no glyph for: \(list)"
    case .invalidPointSize(let size):
      return "The point size is outside the supported profile (\(size))"
    case .fontUnavailable(let name):
      return "The requested font is unavailable: \(name)"
    }
  }
}

/// FNT-05: one shaped glyph in drawing (visual left-to-right) order.
public struct ShapedGlyph: Sendable, Equatable {
  public let glyphID: Int
  public let advance: Double
  /// Logical UTF-16 range in the shaped paragraph that this glyph draws.
  public let sourceRange: Range<Int>

  public init(glyphID: Int, advance: Double, sourceRange: Range<Int>) {
    self.glyphID = glyphID
    self.advance = advance
    self.sourceRange = sourceRange
  }
}

/// FNT-05: one visually ordered run. Glyphs are stored in the order they must
/// be painted to read correctly; the run keeps its logical range for editing,
/// copy and search.
public struct ShapedTextRun: Sendable, Equatable {
  public let direction: BidiDirection
  public let level: Int
  public let logicalRange: Range<Int>
  public let text: String
  public let glyphs: [ShapedGlyph]
  public let advance: Double

  public init(
    direction: BidiDirection, level: Int, logicalRange: Range<Int>, text: String,
    glyphs: [ShapedGlyph], advance: Double
  ) {
    self.direction = direction
    self.level = level
    self.logicalRange = logicalRange
    self.text = text
    self.glyphs = glyphs
    self.advance = advance
  }
}

/// FNT-05: a Core Text shaped bidirectional paragraph with a logical-to-visual
/// caret model. Runs are in visual order and every glyph records the logical
/// UTF-16 range it draws, so editing never invents a second hidden string.
public struct ShapedParagraph: Sendable, Equatable {
  public let text: String
  public let baseLevel: Int
  public let runs: [ShapedTextRun]
  public let missingScalars: [UInt32]
  public let glyphCount: Int
  public let totalAdvance: Double
  public let fontName: String
  public let pointSize: Double

  public var hasMissingGlyphs: Bool { !missingScalars.isEmpty }
  public var hasRightToLeftRuns: Bool {
    runs.contains { $0.direction == .rightToLeft }
  }

  /// X position of a logical caret offset relative to the paragraph origin.
  /// Carets snap to shaped cluster boundaries so a ligature or combining
  /// sequence is never split.
  public func caretX(forLogicalOffset offset: Int) -> Double {
    let length = text.utf16.count
    let clamped = max(0, min(length, offset))
    // Paragraph edges follow the base direction: Home is the visual left edge
    // for a left-to-right paragraph and End the visual right edge.
    if clamped == 0 {
      return baseLevel % 2 == 0 ? 0 : totalAdvance
    }
    if clamped == length {
      return baseLevel % 2 == 0 ? totalAdvance : 0
    }
    // A boundary belongs to the character that follows it, so an offset at a
    // run start takes that run's leading visual edge (the right edge for RTL).
    var runStart = 0.0
    for run in runs {
      if clamped >= run.logicalRange.lowerBound && clamped < run.logicalRange.upperBound {
        return runStart + caretX(in: run, logicalOffset: clamped)
      }
      runStart += run.advance
    }
    return runStart
  }

  /// Closest logical caret offset for a visual X position relative to the
  /// paragraph origin.
  public func logicalOffset(nearestX x: Double) -> Int {
    let length = text.utf16.count
    guard length > 0 else { return 0 }
    var best = 0
    var bestDistance = Double.infinity
    for offset in 0...length {
      let candidate = caretX(forLogicalOffset: offset)
      let distance = abs(candidate - x)
      if distance < bestDistance - 1e-9
        || (abs(distance - bestDistance) <= 1e-9 && offset % 2 == 0)
      {
        bestDistance = distance
        best = offset
      }
    }
    return best
  }

  /// Visual order of the run indices (runs already are visual order).
  public var visualRunOrder: [Int] { Array(runs.indices) }

  /// True when the shaped glyph ranges cover every logical unit at least once.
  public var coversEveryUnit: Bool {
    var seen = [Int](repeating: 0, count: max(1, text.utf16.count))
    for run in runs {
      for glyph in run.glyphs {
        for index in glyph.sourceRange where index < seen.count {
          seen[index] += 1
        }
      }
    }
    return seen.allSatisfy { $0 >= 1 }
  }

  func caretX(in run: ShapedTextRun, logicalOffset: Int) -> Double {
    switch run.direction {
    case .leftToRight:
      var x = 0.0
      for glyph in run.glyphs {
        if glyph.sourceRange.upperBound <= logicalOffset { x += glyph.advance }
      }
      return x
    case .rightToLeft:
      // Logical order runs right-to-left inside the run; x is measured from
      // the run's left edge, so the advance of earlier logical clusters must
      // be subtracted from the full run width.
      var advanceBefore = 0.0
      for glyph in run.glyphs {
        if glyph.sourceRange.upperBound <= logicalOffset { advanceBefore += glyph.advance }
      }
      return max(0, run.advance - advanceBefore)
    }
  }
}

/// FNT-05: Core Text shaping for the declared bidi/contextual profile. Arabic
/// and Indic contextual forms come from the font's GSUB tables; RTL runs are
/// stored in painting order; every glyph keeps its logical source range.
public enum BidiShaping {
  public static let supportedPointSizes: ClosedRange<Double> = 2...200

  public static func shape(
    _ text: String, fontName: String = "Helvetica", pointSize: Double = 12,
    language: String? = nil, baseDirection: BidiBaseDirection = .automatic
  ) throws -> ShapedParagraph {
    guard !text.isEmpty else { throw ShapedTextError.emptyText }
    guard supportedPointSizes.contains(pointSize), pointSize.isFinite else {
      throw ShapedTextError.invalidPointSize(pointSize)
    }
    let font = CTFontCreateWithName(fontName as CFString, pointSize, nil)
    return try shape(
      text, font: font, fontName: fontName, pointSize: pointSize,
      language: language, baseDirection: baseDirection)
  }

  public static func shape(
    _ text: String, font: CTFont, fontName: String? = nil,
    pointSize: Double? = nil, language: String? = nil,
    baseDirection: BidiBaseDirection = .automatic
  ) throws -> ShapedParagraph {
    guard !text.isEmpty else { throw ShapedTextError.emptyText }
    let size = pointSize ?? Double(CTFontGetSize(font))
    guard supportedPointSizes.contains(size), size.isFinite else {
      throw ShapedTextError.invalidPointSize(size)
    }
    let resolvedName = fontName
      ?? (CTFontCopyPostScriptName(font) as String? ?? "font")
    let paragraph: BidiParagraph
    do {
      paragraph = try BidiText.resolve(text, baseDirection: baseDirection)
    } catch let error as BidiTextError {
      throw ShapedTextError.bidiRefused(error.description)
    }
    guard paragraph.baseLevel == 0 || paragraph.baseLevel == 1 else {
      throw ShapedTextError.bidiRefused("The paragraph level is not 0 or 1")
    }
    let units = Array(text.utf16)
    var missing: [UInt32] = []
    var shapedRuns: [ShapedTextRun] = []
    var totalAdvance = 0.0
    var glyphCount = 0
    for run in paragraph.runs {
      let sliceUnits = Array(units[run.logicalRange])
      let sliceText = String(decoding: sliceUnits, as: UTF16.self)
      var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font
      ]
      if let language, !language.isEmpty {
        attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language
      }
      let attributed = NSAttributedString(string: sliceText, attributes: attributes)
      let line = CTLineCreateWithAttributedString(attributed)
      var glyphs: [ShapedGlyph] = []
      var advance = 0.0
      for ctRun in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(ctRun)
        guard count > 0 else { continue }
        var glyphIDs = [CGGlyph](repeating: 0, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(ctRun, CFRange(location: 0, length: count), &glyphIDs)
        CTRunGetStringIndices(ctRun, CFRange(location: 0, length: count), &indices)
        CTRunGetAdvances(ctRun, CFRange(location: 0, length: count), &advances)
        let sliceLength = sliceUnits.count
        var clusterEnds = [Int](repeating: sliceLength, count: count)
        var sorted = indices.enumerated()
          .map { (index: Int($0.element), glyph: $0.offset) }
          .sorted { $0.index < $1.index }
        for position in sorted.indices {
          let current = sorted[position]
          var nextIndex = sliceLength
          var cursor = position + 1
          while cursor < sorted.count {
            if sorted[cursor].index > current.index {
              nextIndex = sorted[cursor].index
              break
            }
            cursor += 1
          }
          clusterEnds[current.glyph] = max(current.index + 1, nextIndex)
        }
        for glyphIndex in 0..<count {
          let start = max(0, min(sliceLength, Int(indices[glyphIndex])))
          let end = max(start, min(sliceLength, clusterEnds[glyphIndex]))
          let sourceRange = (run.logicalRange.lowerBound + start)..<(run.logicalRange.lowerBound + end)
          glyphs.append(
            ShapedGlyph(
              glyphID: Int(glyphIDs[glyphIndex]),
              advance: Double(advances[glyphIndex].width),
              sourceRange: sourceRange))
          advance += Double(advances[glyphIndex].width)
        }
      }
      // Missing glyph detection: a scalar is covered only when the font maps
      // it to a non-notdef glyph. Contextual forms keep their base coverage.
      var cursor = 0
      for scalar in sliceText.unicodeScalars {
        var glyph: CGGlyph = 0
        var character = Array(String(scalar).utf16)
        let covered = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        let isControl = scalar.value < 0x20 && scalar.value != 0x09
        if !covered || glyph == 0 {
          if !isControl, !missing.contains(scalar.value) { missing.append(scalar.value) }
        }
        cursor += 1
      }
      let shapedRun = ShapedTextRun(
        direction: run.direction, level: run.level, logicalRange: run.logicalRange,
        text: sliceText, glyphs: glyphs, advance: advance)
      shapedRuns.append(shapedRun)
      totalAdvance += advance
      glyphCount += glyphs.count
    }
    return ShapedParagraph(
      text: text, baseLevel: paragraph.baseLevel, runs: shapedRuns,
      missingScalars: missing, glyphCount: glyphCount, totalAdvance: totalAdvance,
      fontName: resolvedName, pointSize: size)
  }

  /// Convenience for tests and callers that need the shaped paragraph's
  /// logical run order (visual order is the default for painting).
  public static func logicalRuns(_ paragraph: ShapedParagraph) -> [ShapedTextRun] {
    paragraph.runs.sorted { $0.logicalRange.lowerBound < $1.logicalRange.lowerBound }
  }
}
