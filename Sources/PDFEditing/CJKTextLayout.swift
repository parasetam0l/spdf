import CoreText
import Foundation

/// FNT-06: the declared CJK profiles. Horizontal CJK is ordinary left-to-right
/// writing with kinsoku line breaking; vertical CJK is a separate writing mode
/// with Identity-V metrics, top-to-bottom columns ordered right-to-left and
/// explicitly rotated punctuation. The two profiles never share fabricated
/// mappings.
public enum CJKProfile {
  public enum Script: String, Sendable, Equatable {
    case han
    case hiragana
    case katakana
    case hangul
    case fullWidthForm
    case cjkPunctuation
    case space
    case other
  }

  public static func script(of character: Character) -> Script {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1
    else { return .other }
    switch scalar.value {
    case 0x3000:
      return .space
    case 0x3001...0x303F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40,
      0xFF5B...0xFF65, 0xFE10...0xFE19, 0xFE30...0xFE4F:
      return .cjkPunctuation
    case 0x3040...0x309F:
      return .hiragana
    case 0x30A0...0x30FF, 0x31F0...0x31FF:
      return .katakana
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
      0x20000...0x2FA1F:
      return .han
    case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
      return .hangul
    case 0xFF00...0xFFEF:
      return .fullWidthForm
    default:
      return .other
    }
  }

  public static func isCJK(_ character: Character) -> Bool {
    switch script(of: character) {
    case .han, .hiragana, .katakana, .hangul, .fullWidthForm, .cjkPunctuation,
      .space:
      return true
    case .other:
      return false
    }
  }

  /// Characters that Japanese line breaking forbids at the start of a line.
  public static let prohibitedLineStart: Set<Character> = [
    "、", "。", "，", "．", "：", "；", "！", "？", "）", "〕", "〉", "》", "」",
    "』", "】", "｝", "］", "・", "ー", "〜", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ",
    "っ", "ゃ", "ゅ", "ょ", "ゎ", "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ",
    "ュ", "ョ", "ヮ", "々", "〻", "%", "‰",
  ]

  /// Characters that Japanese line breaking forbids at the end of a line.
  public static let prohibitedLineEnd: Set<Character> = [
    "（", "〔", "〈", "《", "「", "『", "【", "｛", "［", "“", "‘",
  ]

  /// Punctuation that is rotated (90 degrees clockwise) in vertical writing by
  /// this profile. The glyph itself is not substituted with a fabricated code;
  /// the rotation is declared as part of the vertical profile.
  public static let rotatedInVertical: Set<Character> = [
    "、", "。", "，", "．", "：", "；", "・", "〜", "（", "）", "「", "」",
    "『", "』", "【", "】", "〈", "〉", "《", "》", "〔", "〕",
  ]
}

public enum CJKLayoutError: Error, Equatable, CustomStringConvertible {
  case emptyText
  case unsupportedVerticalCharacter(String)
  case missingGlyph(String)
  case invalidPointSize(Double)
  case invalidColumnHeight(Double)

  public var description: String {
    switch self {
    case .emptyText:
      return "The CJK text is empty"
    case .unsupportedVerticalCharacter(let character):
      return "Vertical CJK writing does not support the character \(character) in this profile"
    case .missingGlyph(let character):
      return "The font has no glyph for the CJK character \(character)"
    case .invalidPointSize(let size):
      return "The point size is outside the supported profile (\(size))"
    case .invalidColumnHeight(let height):
      return "The vertical column height is not usable (\(height))"
    }
  }
}

/// FNT-06: kinship-aware line breaking shared by horizontal CJK lines and
/// vertical columns. Tokens are single CJK characters (breakable everywhere),
/// whole Latin/digit runs (break only at spaces) and spaces.
public enum CJKLineBreaker {
  public enum Token: Sendable, Equatable {
    case character(String)
    case word(String)
    case space(String)
  }

  public static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var word = ""
    func flushWord() {
      if !word.isEmpty {
        tokens.append(.word(word))
        word = ""
      }
    }
    for character in text {
      if character.isWhitespace {
        flushWord()
        tokens.append(.space(String(character)))
        continue
      }
      if CJKProfile.isCJK(character) {
        flushWord()
        tokens.append(.character(String(character)))
        continue
      }
      word.append(character)
    }
    flushWord()
    return tokens
  }

  /// Break into lines no wider than maxWidth according to the measure
  /// closure, applying the kinsoku start/end prohibition afterwards. A single
  /// token wider than the limit is placed on its own line (never split).
  public static func breakLines(
    _ text: String, maxWidth: Double, measure: (String) -> Double
  ) -> [String] {
    guard !text.isEmpty, maxWidth.isFinite, maxWidth > 0 else {
      return text.isEmpty ? [] : [text]
    }
    let tokens = tokenize(text)
    guard !tokens.isEmpty else { return [] }
    var lines: [String] = []
    var lineStart = 0
    var index = 0
    var lineWidth = 0.0
    while index < tokens.count {
      let tokenWidth = measure(Self.text(of: tokens[index]))
      if index == lineStart {
        lineWidth = tokenWidth
        index += 1
        continue
      }
      if lineWidth + tokenWidth <= maxWidth + 1e-9 {
        lineWidth += tokenWidth
        index += 1
        continue
      }
      var breakIndex = index
      // Never start a line with prohibited punctuation: give the previous
      // line one more allowed token by moving the break one token left.
      while breakIndex > lineStart + 1,
        let next = firstCharacter(tokens[breakIndex]),
        CJKProfile.prohibitedLineStart.contains(next)
      {
        breakIndex -= 1
      }
      // Never end a line with an opening bracket: include one more token.
      while breakIndex > lineStart,
        let previous = lastCharacter(tokens[breakIndex - 1]),
        CJKProfile.prohibitedLineEnd.contains(previous),
        breakIndex < tokens.count
      {
        breakIndex += 1
      }
      if breakIndex <= lineStart { breakIndex = lineStart + 1 }
      if breakIndex > index { breakIndex = index }
      lines.append(Self.joined(tokens[lineStart..<breakIndex], Self.text(of:)))
      let moved = tokens[breakIndex..<index]
      lineWidth = moved.reduce(0.0) { $0 + measure(Self.text(of: $1)) }
      lineStart = breakIndex
      // Process the overflowing token again for the next line.
    }
    if lineStart < tokens.count {
      lines.append(Self.joined(tokens[lineStart...], Self.text(of:)))
    }
    return lines
  }

  static func joined<T>(_ slice: ArraySlice<T>, _ convert: (T) -> String) -> String {
    slice.map(convert).joined()
  }

  public static func breakLines(
    _ text: String, maxWidth: Double, font: CTFont, pointSize: Double
  ) throws -> [String] {
    guard !text.isEmpty else { throw CJKLayoutError.emptyText }
    guard pointSize.isFinite, (2...200).contains(pointSize) else {
      throw CJKLayoutError.invalidPointSize(pointSize)
    }
    return breakLines(text, maxWidth: maxWidth) { token in
      measure(token, font: font, pointSize: pointSize)
    }
  }

  public static func measure(_ text: String, font: CTFont, pointSize: Double) -> Double {
    var total = 0.0
    for character in text {
      let units = Array(String(character).utf16)
      var glyphs = [CGGlyph](repeating: 0, count: units.count)
      if CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) {
        var advances = [CGSize](repeating: .zero, count: units.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, units.count)
        total += advances.reduce(0) { $0 + $1.width }
      } else {
        total += pointSize
      }
    }
    return total
  }

  public static func text(of token: Token) -> String {
    switch token {
    case .character(let value), .word(let value), .space(let value):
      return value
    }
  }

  static func firstCharacter(_ token: Token) -> Character? {
    text(of: token).first
  }

  static func lastCharacter(_ token: Token) -> Character? {
    text(of: token).last
  }
}

/// FNT-06: one glyph placed in a vertical column. Rotated punctuation uses the
/// declared vertical profile angle instead of a fabricated vertical code.
public struct VerticalTextCell: Sendable, Equatable {
  public let character: String
  public let glyphID: Int
  public let advance: Double
  public let isRotated: Bool
  public let x: Double
  public let y: Double

  public init(
    character: String, glyphID: Int, advance: Double, isRotated: Bool,
    x: Double, y: Double
  ) {
    self.character = character
    self.glyphID = glyphID
    self.advance = advance
    self.isRotated = isRotated
    self.x = x
    self.y = y
  }
}

public struct VerticalTextColumn: Sendable, Equatable {
  public let text: String
  public let cells: [VerticalTextCell]
  public let x: Double
  public let topY: Double
  public let height: Double
}

/// FNT-06: vertical CJK layout independent of PDF. Columns run top-to-bottom
/// and are ordered right-to-left; punctuation rotates and kinsoku applies.
public enum VerticalTextLayout {
  public static func columns(
    _ text: String, font: CTFont, fontName: String = "font", pointSize: Double,
    columnHeight: Double, originX: Double, originY: Double,
    columnPitch: Double? = nil
  ) throws -> [VerticalTextColumn] {
    guard !text.isEmpty else { throw CJKLayoutError.emptyText }
    guard pointSize.isFinite, (2...200).contains(pointSize) else {
      throw CJKLayoutError.invalidPointSize(pointSize)
    }
    guard columnHeight.isFinite, columnHeight > pointSize else {
      throw CJKLayoutError.invalidColumnHeight(columnHeight)
    }
    for character in text where !CJKProfile.isCJK(character) {
      throw CJKLayoutError.unsupportedVerticalCharacter(String(character))
    }
    let pitch = columnPitch ?? pointSize
    let lines = CJKLineBreaker.breakLines(text, maxWidth: columnHeight) { token in
      verticalMeasure(token, font: font, pointSize: pointSize)
    }
    var columns: [VerticalTextColumn] = []
    for (columnIndex, line) in lines.enumerated() {
      let columnX = originX - Double(columnIndex) * pitch
      var cells: [VerticalTextCell] = []
      var cursorY = originY
      for character in line {
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count),
          let glyph = glyphs.first, glyph != 0
        else {
          throw CJKLayoutError.missingGlyph(String(character))
        }
        let advance = verticalAdvance(glyph: glyph, font: font, pointSize: pointSize)
        cells.append(
          VerticalTextCell(
            character: String(character), glyphID: Int(glyph), advance: advance,
            isRotated: CJKProfile.rotatedInVertical.contains(character),
            x: columnX, y: cursorY))
        cursorY -= advance
      }
      columns.append(
        VerticalTextColumn(
          text: line, cells: cells, x: columnX, topY: originY,
          height: originY - cursorY))
    }
    _ = fontName
    return columns
  }

  public static func verticalMeasure(
    _ text: String, font: CTFont, pointSize: Double
  ) -> Double {
    var total = 0.0
    for character in text {
      let units = Array(String(character).utf16)
      var glyphs = [CGGlyph](repeating: 0, count: units.count)
      if CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count),
        let glyph = glyphs.first
      {
        total += verticalAdvance(glyph: glyph, font: font, pointSize: pointSize)
      } else {
        total += pointSize
      }
    }
    return total
  }

  public static func verticalAdvance(
    glyph: CGGlyph, font: CTFont, pointSize: Double
  ) -> Double {
    var glyphs = [glyph]
    var advances = [CGSize](repeating: .zero, count: 1)
    CTFontGetAdvancesForGlyphs(font, .vertical, &glyphs, &advances, 1)
    let vertical = abs(advances[0].height) > 0 ? abs(advances[0].height) : advances[0].width
    return vertical > 0 ? vertical : pointSize
  }
}
