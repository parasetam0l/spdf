import Foundation
import CoreGraphics
import CoreText
import PDFCore

// FRM-05: complex text-field content. Selection-level rich runs are modelled
// explicitly, mirrored into /RV as RTF, and painted into widget appearances with
// per-run fonts, sizes and colors. Text is never silently substituted: a face or
// embedded program that cannot encode the text refuses before mutation.

/// FRM-05: the text style of one selection-level run. A nil font means "inherit
/// the field's effective default appearance font".
public struct FormRichTextStyle: Sendable, Equatable {
  public var bold: Bool
  public var italic: Bool
  public var fontSize: Double
  public var color: [Double]
  public var font: FormAppearanceFontChoice?

  public init(
    bold: Bool = false, italic: Bool = false, fontSize: Double = 12,
    color: [Double] = [0, 0, 0], font: FormAppearanceFontChoice? = nil
  ) {
    self.bold = bold
    self.italic = italic
    self.fontSize = fontSize
    self.color = color
    self.font = font
  }

  public var standardFace: StandardTextFont {
    if case .standard(let face) = font { return face }
    if bold && italic { return .helveticaBoldItalic }
    if bold { return .helveticaBold }
    if italic { return .helveticaItalic }
    return .helvetica
  }

  public var resolvedFace: StandardTextFont { standardFace }

  public var familyLabel: String {
    if let font { return font.familyLabel }
    return "FieldDefault"
  }
}

/// FRM-05: one style run over the field's plain text (UTF-16 offsets).
public struct FormRichTextRun: Sendable, Equatable {
  public var location: Int
  public var length: Int
  public var style: FormRichTextStyle

  public init(location: Int, length: Int, style: FormRichTextStyle) {
    self.location = location
    self.length = length
    self.style = style
  }

  public var range: NSRange { NSRange(location: location, length: length) }
}

/// FRM-05: a text field value with a base style and selection-level runs.
public struct FormRichTextValue: Sendable, Equatable {
  public var plainText: String
  public var baseStyle: FormRichTextStyle
  /// Sorted, non-overlapping runs for text that differs from the base style.
  public var runs: [FormRichTextRun]

  public init(
    plainText: String, baseStyle: FormRichTextStyle = FormRichTextStyle(),
    runs: [FormRichTextRun] = []
  ) {
    self.plainText = plainText
    self.baseStyle = baseStyle
    self.runs = runs
  }

  public static func plain(
    _ text: String, style: FormRichTextStyle = FormRichTextStyle()
  ) -> Self {
    Self(plainText: text, baseStyle: style)
  }

  public var utf16Length: Int { (plainText as NSString).length }
  public var hasRuns: Bool { !runs.isEmpty }

  /// Clamp runs to composed-character boundaries, sort them and reject overlaps.
  public func validatedRuns() throws -> [FormRichTextRun] {
    let length = utf16Length
    let string = plainText as NSString
    var cleaned: [FormRichTextRun] = []
    for run in runs {
      guard run.location >= 0, run.length > 0 else {
        throw PDFError(.malformed, "A rich-text run has an empty range")
      }
      guard run.location + run.length <= length else {
        throw PDFError(.malformed, "A rich-text run extends past the field text")
      }
      let raw = NSRange(location: run.location, length: run.length)
      let aligned = string.rangeOfComposedCharacterSequences(for: raw)
      guard aligned.length > 0 else {
        throw PDFError(.malformed, "A rich-text run does not cover a complete character")
      }
      cleaned.append(
        FormRichTextRun(location: aligned.location, length: aligned.length, style: run.style))
    }
    cleaned.sort { $0.location < $1.location }
    var previousEnd = 0
    for run in cleaned {
      guard run.location >= previousEnd else {
        throw PDFError(.malformed, "Rich-text runs overlap")
      }
      previousEnd = run.location + run.length
    }
    return cleaned
  }

  /// Full coverage segments: the base style fills every gap between runs.
  public func segments() throws -> [(range: NSRange, style: FormRichTextStyle)] {
    let length = utf16Length
    let sorted = try validatedRuns()
    var segments: [(NSRange, FormRichTextStyle)] = []
    var cursor = 0
    for run in sorted {
      if run.location > cursor {
        segments.append((NSRange(location: cursor, length: run.location - cursor), baseStyle))
      }
      segments.append((NSRange(location: run.location, length: run.length), run.style))
      cursor = max(cursor, run.location + run.length)
    }
    if cursor < length {
      segments.append((NSRange(location: cursor, length: length - cursor), baseStyle))
    }
    return segments
  }

  public func style(atUTF16Offset offset: Int) -> FormRichTextStyle {
    let length = utf16Length
    guard offset >= 0, offset < length else { return baseStyle }
    for run in runs where offset >= run.location && offset < run.location + run.length {
      return run.style
    }
    return baseStyle
  }

  /// Apply a style to a UTF-16 range and rebuild minimal runs.
  public func applying(style: FormRichTextStyle, to range: NSRange) throws -> Self {
    let length = utf16Length
    guard range.location >= 0, range.length > 0, range.location + range.length <= length else {
      throw PDFError(.malformed, "The styled range is outside the field text")
    }
    let string = plainText as NSString
    let aligned = string.rangeOfComposedCharacterSequences(for: range)
    guard aligned.length > 0 else {
      throw PDFError(.malformed, "The styled range does not cover a complete character")
    }
    var styles = [FormRichTextStyle](repeating: baseStyle, count: length)
    for segment in try segments() {
      let end = min(segment.range.location + segment.range.length, length)
      for offset in segment.range.location..<end { styles[offset] = segment.style }
    }
    let end = min(aligned.location + aligned.length, length)
    for offset in aligned.location..<end { styles[offset] = style }
    return Self(
      plainText: plainText, baseStyle: baseStyle, runs: Self.compress(styles, base: baseStyle))
  }

  public func removingAllRuns() -> Self {
    Self(plainText: plainText, baseStyle: baseStyle, runs: [])
  }

  static func compress(_ styles: [FormRichTextStyle], base: FormRichTextStyle)
    -> [FormRichTextRun]
  {
    var runs: [FormRichTextRun] = []
    var index = 0
    while index < styles.count {
      let style = styles[index]
      var end = index + 1
      while end < styles.count, styles[end] == style { end += 1 }
      if style != base {
        runs.append(FormRichTextRun(location: index, length: end - index, style: style))
      }
      index = end
    }
    return runs
  }
}

// MARK: - RTF mirror (/RV)

/// FRM-05: encode and decode the /RV rich text value. The encoding is a small,
/// bounded RTF subset: font/color tables, bold, italic, size, color, escaped
/// Unicode and explicit groups. No font embedding program, file reference,
/// image or script content is written, and decoding never executes anything.
public enum FormRichTextRTF {
  public static let maximumRTFBytes = 200_000
  public static let maximumTextLength = 100_000

  // MARK: Encoding

  public static func encode(_ value: FormRichTextValue) -> String {
    let segments = (try? value.segments()) ?? [
      (NSRange(location: 0, length: value.utf16Length), value.baseStyle)
    ]
    var fontFamilies: [String] = [value.baseStyle.familyLabel]
    func family(for style: FormRichTextStyle) -> String {
      if style.font == nil { return value.baseStyle.familyLabel }
      return style.familyLabel
    }
    for segment in segments {
      let name = family(for: segment.style)
      if !fontFamilies.contains(name) { fontFamilies.append(name) }
    }
    var colorTable: [[Double]] = [value.baseStyle.color]
    for segment in segments where !colorTable.contains(segment.style.color) {
      colorTable.append(segment.style.color)
    }
    var fontTable = "{\\fonttbl"
    for (index, name) in fontFamilies.enumerated() {
      fontTable += "{\\f" + String(index) + " " + escapeFontName(name) + ";}"
    }
    fontTable += "}"
    var colors = "{\\colortbl;"
    for color in colorTable {
      let rgb = colorComponents(color)
      colors += "\\red" + String(rgb[0]) + "\\green" + String(rgb[1])
        + "\\blue" + String(rgb[2]) + ";"
    }
    colors += "}"
    var body = ""
    let string = value.plainText as NSString
    for segment in segments {
      guard segment.range.location >= 0, segment.range.length > 0,
        segment.range.location + segment.range.length <= string.length
      else { continue }
      let style = segment.style
      let fontIndex = fontFamilies.firstIndex(of: family(for: style)) ?? 0
      let colorIndex = colorTable.firstIndex(of: style.color).map { $0 + 1 } ?? 1
      var group = "{\\f" + String(fontIndex) + "\\fs" + String(halfPoints(style.fontSize))
      group += "\\cf" + String(colorIndex)
      if style.bold { group += "\\b" }
      if style.italic { group += "\\i" }
      if case .embedded(let source) = style.font {
        group += "{\\*\\spdfembeddedfont " + escapeFontName(source.sanitizedFamilyName) + ";}"
      }
      group += " " + escapeText(string.substring(with: segment.range)) + "}"
      body += group
    }
    return "{\\rtf1\\ansi\\deff0" + fontTable + colors + "\\f0\\fs"
      + String(halfPoints(value.baseStyle.fontSize)) + "\\cf1 " + body + "}"
  }

  // MARK: Decoding

  public static func decode(_ rtf: String) -> FormRichTextValue? {
    guard rtf.utf8.count <= maximumRTFBytes else { return nil }
    guard var value = decodeInternal(rtf) else { return nil }
    value.runs = (try? value.validatedRuns()) ?? []
    return value
  }

  static func decodeInternal(_ rtf: String) -> FormRichTextValue? {
    let characters = Array(rtf)
    guard !characters.isEmpty else { return nil }
    let tables = scanTables(characters)
    let root = scanRootState(characters, tables: tables)
    var text = ""
    var styles: [FormRichTextStyle] = []
    var index = 0
    var stack: [FormRichTextStyle] = []
    var state = root
    var skippingUntilDepth = -1
    var unicodeSkip = 0
    var pendingHighSurrogate: UInt16?
    func currentStyle() -> FormRichTextStyle {
      var style = state
      style.bold = state.bold
      style.italic = state.italic
      style.fontSize = state.fontSize
      style.color = state.color
      style.font = state.font
      return style
    }
    func append(_ string: String) {
      guard text.utf16.count + string.utf16.count <= maximumTextLength else { return }
      text += string
      for _ in 0..<string.utf16.count { styles.append(currentStyle()) }
    }
    while index < characters.count {
      let character = characters[index]
      if character == "{" {
        guard stack.count < 64 else { return nil }
        stack.append(state)
        index += 1
        continue
      }
      if character == "}" {
        state = stack.popLast() ?? root
        if skippingUntilDepth >= 0, stack.count <= skippingUntilDepth {
          skippingUntilDepth = -1
        }
        index += 1
        continue
      }
      if skippingUntilDepth >= 0 {
        index += 1
        continue
      }
      if unicodeSkip > 0 {
        unicodeSkip -= 1
        index += 1
        continue
      }
      if character == "\\" {
        index += 1
        guard index < characters.count else { break }
        let next = characters[index]
        if next == "\\" || next == "{" || next == "}" {
          append(String(next))
          index += 1
          continue
        }
        if next == "*" {
          skippingUntilDepth = max(0, stack.count - 1)
          index += 1
          continue
        }
        if next == "'" {
          if index + 2 < characters.count,
            let byte = UInt8(String(characters[(index + 1)...(index + 2)]), radix: 16),
            let decoded = String(bytes: [byte], encoding: .windowsCP1252)
          {
            append(decoded)
            index += 3
          } else {
            index += 1
          }
          continue
        }
        var word = ""
        while index < characters.count, characters[index].isLetter {
          word.append(characters[index])
          index += 1
        }
        var negative = false
        if index < characters.count, characters[index] == "-" {
          negative = true
          index += 1
        }
        var digits = ""
        while index < characters.count, characters[index].isLetter == false,
          characters[index].isNumber
        {
          digits.append(characters[index])
          index += 1
        }
        if index < characters.count, characters[index] == " " { index += 1 }
        let parameter = Int(digits).map { negative ? -$0 : $0 }
        switch word {
        case "fonttbl", "colortbl":
          skippingUntilDepth = max(0, stack.count - 1)
        case "b": state.bold = (parameter ?? 1) != 0
        case "i": state.italic = (parameter ?? 1) != 0
        case "fs": state.fontSize = Double(parameter ?? 24) / 2
        case "cf": state.color = tables.color(index: parameter ?? 1)
        case "f":
          let fontIndex = parameter ?? 0
          state.font = fontIndex == tables.baseFontIndex
            ? tables.baseFont : tables.fontChoice(index: fontIndex)
        case "u":
          guard let raw = parameter else { continue }
          let scalarValue = raw < 0 ? raw + 65_536 : raw
          let unit = UInt16(clamping: max(0, min(scalarValue, 65_535)))
          if (0xD800...0xDBFF).contains(unit) {
            pendingHighSurrogate = unit
          } else if (0xDC00...0xDFFF).contains(unit), let high = pendingHighSurrogate {
            let code = 0x1_0000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
            guard let scalar = UnicodeScalar(code) else { return nil }
            append(String(Character(scalar)))
            pendingHighSurrogate = nil
          } else {
            pendingHighSurrogate = nil
            guard let scalar = UnicodeScalar(UInt32(unit)) else { return nil }
            append(String(Character(scalar)))
          }
          unicodeSkip = 1
        case "line", "par":
          append("\n")
        case "tab":
          append("\t")
        default:
          break
        }
        continue
      }
      append(String(character))
      index += 1
    }
    guard text.utf16.count <= maximumTextLength else { return nil }
    return FormRichTextValue(
      plainText: text, baseStyle: root, runs: FormRichTextValue.compress(styles, base: root))
  }

  struct Tables {
    var fonts: [Int: String] = [:]
    var colors: [[Double]] = []
    var baseFontIndex = 0
    var baseFont: FormAppearanceFontChoice? = nil

    func fontChoice(index: Int) -> FormAppearanceFontChoice? {
      guard let name = fonts[index] else { return nil }
      guard let face = StandardTextFont(rawValue: name) else { return nil }
      return .standard(face)
    }

    func color(index: Int) -> [Double] {
      guard index >= 1, index <= colors.count else { return [0, 0, 0] }
      return colors[index - 1]
    }
  }

  static func scanTables(_ characters: [Character]) -> Tables {
    var tables = Tables()
    // Font table: scan groups of the form {\fN name;}
    if let start = findSequence("{\\fonttbl", in: characters) {
      var index = start + 10
      var depth = 1
      var currentFont: Int?
      var name = ""
      while index < characters.count, depth > 0, tables.fonts.count < 512 {
        let character = characters[index]
        if character == "{" {
          depth += 1
          currentFont = nil
          name = ""
          index += 1
          continue
        }
        if character == "}" {
          if let font = currentFont {
            tables.fonts[font] = sanitizeFontName(name)
          }
          depth -= 1
          currentFont = nil
          name = ""
          index += 1
          continue
        }
        if character == "\\", index + 1 < characters.count, characters[index + 1] == "f" {
          var cursor = index + 2
          var digits = ""
          while cursor < characters.count, characters[cursor].isNumber {
            digits.append(characters[cursor])
            cursor += 1
          }
          if let font = Int(digits) {
            currentFont = font
            name = ""
            index = cursor
            if index < characters.count, characters[index] == " " { index += 1 }
            continue
          }
        }
        if currentFont != nil, character != ";" { name.append(character) }
        index += 1
      }
    }
    // Color table: entries separated by ';', components as \redN\greenN\blueN.
    if let start = findSequence("{\\colortbl", in: characters) {
      var index = start + 10
      var depth = 1
      var current = [0, 0, 0]
      var entries = 0
      var isFirstSeparator = true
      while index < characters.count, depth > 0, entries < 512 {
        let character = characters[index]
        if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
        } else if character == ";" {
          if isFirstSeparator {
            // RTF requires a separator after \colortbl before the first color;
            // it is not an entry of its own.
            isFirstSeparator = false
          } else {
            tables.colors.append([
              Double(current[0]) / 255, Double(current[1]) / 255, Double(current[2]) / 255,
            ])
            entries += 1
          }
          current = [0, 0, 0]
        } else if character == "\\" {
          var cursor = index + 1
          var word = ""
          while cursor < characters.count, characters[cursor].isLetter {
            word.append(characters[cursor])
            cursor += 1
          }
          var digits = ""
          while cursor < characters.count, characters[cursor].isNumber {
            digits.append(characters[cursor])
            cursor += 1
          }
          let value = Int(digits) ?? 0
          if word == "red" { current[0] = min(max(value, 0), 255) }
          if word == "green" { current[1] = min(max(value, 0), 255) }
          if word == "blue" { current[2] = min(max(value, 0), 255) }
          index = cursor
          continue
        }
        index += 1
      }
    }
    tables.baseFont = tables.fontChoice(index: 0)
    return tables
  }

  static func scanRootState(_ characters: [Character], tables: Tables) -> FormRichTextStyle {
    var state = FormRichTextStyle()
    state.font = tables.baseFont
    if tables.fonts[0] == nil { state.font = nil }
    var index = 0
    var depth = 0
    var seenText = false
    while index < characters.count, !seenText {
      let character = characters[index]
      if character == "{" {
        let groupStart = index
        // Skip font/color table groups entirely.
        if sequenceAt(characters, index: groupStart, equals: "{\\fonttbl")
          || sequenceAt(characters, index: groupStart, equals: "{\\colortbl")
        {
          var scan = index
          var groupDepth = 1
          while scan + 1 < characters.count, groupDepth > 0 {
            scan += 1
            if characters[scan] == "{" { groupDepth += 1 }
            if characters[scan] == "}" { groupDepth -= 1 }
          }
          index = scan + 1
          continue
        }
        depth += 1
        index += 1
        continue
      }
      if character == "}" {
        depth = max(0, depth - 1)
        index += 1
        continue
      }
      if character == "\\", depth <= 1 {
        var cursor = index + 1
        var word = ""
        while cursor < characters.count, characters[cursor].isLetter {
          word.append(characters[cursor])
          cursor += 1
        }
        var negative = false
        if cursor < characters.count, characters[cursor] == "-" {
          negative = true
          cursor += 1
        }
        var digits = ""
        while cursor < characters.count, characters[cursor].isNumber {
          digits.append(characters[cursor])
          cursor += 1
        }
        let parameter = Int(digits).map { negative ? -$0 : $0 }
        switch word {
        case "f":
          let fontIndex = parameter ?? 0
          state.font = fontIndex == 0 ? tables.baseFont : tables.fontChoice(index: fontIndex)
        case "fs":
          if let half = parameter { state.fontSize = Double(half) / 2 }
        case "cf":
          state.color = tables.color(index: parameter ?? 1)
        case "b":
          state.bold = (parameter ?? 1) != 0
        case "i":
          state.italic = (parameter ?? 1) != 0
        default:
          break
        }
        index = cursor
        continue
      }
      if depth == 0, character != " " || seenText { seenText = true }
      index += 1
    }
    if state.font == nil, let name = tables.fonts[0], let face = StandardTextFont(rawValue: name) {
      state.font = .standard(face)
    }
    if state.fontSize < 4 || state.fontSize > 96 { state.fontSize = 12 }
    if state.color.count != 3 { state.color = [0, 0, 0] }
    return state
  }

  // MARK: Encoding helpers

  static func findSequence(_ sequence: String, in characters: [Character]) -> Int? {
    let pattern = Array(sequence)
    guard !pattern.isEmpty, characters.count >= pattern.count else { return nil }
    for start in 0...(characters.count - pattern.count) {
      var matches = true
      for offset in 0..<pattern.count where characters[start + offset] != pattern[offset] {
        matches = false
        break
      }
      if matches { return start }
    }
    return nil
  }

  static func sequenceAt(_ characters: [Character], index: Int, equals sequence: String) -> Bool {
    let pattern = Array(sequence)
    guard index + pattern.count <= characters.count else { return false }
    for offset in 0..<pattern.count where characters[index + offset] != pattern[offset] {
      return false
    }
    return true
  }

  static func sanitizeFontName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ";", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func halfPoints(_ size: Double) -> Int {
    let bounded = size.isFinite ? min(max(size, 4), 96) : 12
    return min(max(Int((bounded * 2).rounded()), 8), 192)
  }

  static func colorComponents(_ color: [Double]) -> [Int] {
    let components: [Double]
    if color.count == 1 {
      components = [color[0], color[0], color[0]]
    } else if color.count == 3 {
      components = color
    } else {
      components = [0, 0, 0]
    }
    return components.map { Int((min(max($0.isFinite ? $0 : 0, 0), 1) * 255).rounded()) }
  }

  static func escapeFontName(_ name: String) -> String {
    var sanitized = name.map { character -> String in
      if character == ";" || character == "{" || character == "}" || character == "\\" {
        return ""
      }
      if character.isLetter || character.isNumber || character == "-" || character == "."
        || character == " "
      {
        return String(character)
      }
      return "-"
    }.joined()
    if sanitized.isEmpty { sanitized = "Font" }
    return sanitized
  }

  static func escapeText(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\": result += "\\\\"
      case "{": result += "\\{"
      case "}": result += "\\}"
      case "\n": result += "\\line "
      case "\r": result += "\\line "
      case "\t": result += "\\tab "
      default:
        if scalar.value >= 32 && scalar.value <= 126 {
          result.append(Character(scalar))
        } else if scalar.value <= 0xFFFF {
          result += "\\u" + String(Int(Int16(bitPattern: UInt16(scalar.value)))) + "?"
        } else {
          let value = scalar.value - 0x1_0000
          let high = UInt16(0xD800 + (value >> 10))
          let low = UInt16(0xDC00 + (value & 0x3FF))
          result += "\\u" + String(Int(Int16(bitPattern: high))) + "?"
          result += "\\u" + String(Int(Int16(bitPattern: low))) + "?"
        }
      }
    }
    return result
  }
}
