import Foundation
import PDFCore

/// Font dictionaries commonly store metrics and encoding arrays indirectly.
/// Resolve the object before interpreting its type, with a bound for malformed
/// reference chains. Missing objects and cycles are never usable font facts.
enum FontValue {
  static func resolve(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    var value = value
    var visited = Set<PDFObjectID>()
    while case .reference(let id)? = value {
      guard visited.count < 32, visited.insert(id).inserted else { return nil }
      value = graph.objects[id]
    }
    return value
  }
}

/// A subset of the Adobe Glyph List sufficient for the first edit profile:
/// Latin letters, digits, common punctuation, and frequently seen Symbols.
enum GlyphNames {
  static func unicode(for name: String) -> String? {
    if let value = table[name] { return value }
    if name.count == 1, let character = name.first, character.isLetter || character.isNumber {
      return String(character)
    }
    if name.hasPrefix("uni"), name.count == 7,
      let scalar = UInt32(name.dropFirst(3), radix: 16).flatMap(UnicodeScalar.init)
    {
      return String(Character(scalar))
    }
    return nil
  }

  private static let table: [String: String] = [
    "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$",
    "percent": "%", "ampersand": "&", "quotesingle": "'", "quoteright": "\u{2019}",
    "quoteleft": "\u{2018}", "quotedblleft": "\u{201C}", "quotedblright": "\u{201D}",
    "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",",
    "hyphen": "-", "period": ".", "slash": "/", "zero": "0", "one": "1", "two": "2",
    "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
    "nine": "9", "colon": ":", "semicolon": ";", "less": "<", "equal": "=",
    "greater": ">", "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\",
    "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`",
    "braceleft": "{", "bar": "|", "braceright": "}", "asciitilde": "~",
    "endash": "\u{2013}", "emdash": "\u{2014}", "bullet": "\u{2022}", "ellipsis": "\u{2026}",
    "periodcentered": "\u{00B7}", "quotesinglbase": "\u{201A}", "quotedblbase": "\u{201E}",
    "guillemotleft": "\u{00AB}", "guillemotright": "\u{00BB}", "germandbls": "\u{00DF}",
    "ae": "\u{00E6}", "oe": "\u{0153}", "oslash": "\u{00F8}", "ccedilla": "\u{00E7}",
    "degree": "\u{00B0}", "plusminus": "\u{00B1}", "multiply": "\u{00D7}", "divide": "\u{00F7}",
    "euro": "\u{20AC}", "sterling": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}",
    "section": "\u{00A7}", "paragraph": "\u{00B6}", "dagger": "\u{2020}", "daggerdbl": "\u{2021}",
    "copyright": "\u{00A9}", "registered": "\u{00AE}", "trademark": "\u{2122}",
  ]
}

/// P14-001/P14-004: a simple (single-byte) font resolved from a page
/// resource dictionary, with its encoding and optional Differences overrides.
struct SimpleFont: Equatable {
  enum BaseEncoding: Equatable {
    case winAnsi
    case macRoman
    case standardASCII
    case unsupportedName(String)
  }

  let resource: PDFName
  let fontID: PDFObjectID
  let baseFont: String
  let baseEncoding: BaseEncoding
  let differences: [UInt8: String]
  let hasUnknownDifferences: Bool
  let firstChar: Int?
  let widths: [Double]?
  let missingWidth: Double?
  /// P14-023: the font's glyphs are Type 3 content-stream programs
  /// (`/Subtype /Type3` with `/CharProcs`). Reading decodes through the
  /// encoding and ToUnicode normally; writing reuses a code only when its
  /// named glyph program exists in CharProcs (`/CharProcs` names, or nil
  /// when they cannot be read — then writing refuses).
  let isType3: Bool
  /// Raw Differences names per code (glyph names, not Unicode).
  let differenceNames: [UInt8: String]
  /// CharProcs glyph-program names for a Type 3 font; nil otherwise or when
  /// the dictionary cannot be resolved.
  let charProcNames: Set<String>?
  /// P14-024 tail: an explicit ToUnicode CMap takes precedence over the base
  /// encoding and Differences for decoding.
  let toUnicode: ToUnicodeCMap?

  var isSupported: Bool {
    if let toUnicode, !toUnicode.isEmpty { return true }
    switch baseEncoding {
    case .winAnsi, .macRoman, .standardASCII: return !hasUnknownDifferences
    case .unsupportedName: return false
    }
  }

  /// P14-023: this profile can write through the font. Type 3 fonts are
  /// editable only when their glyph programs are readable, so every encoded
  /// code can be verified against `/CharProcs` (see `encode`).
  var isEditable: Bool {
    guard isSupported else { return false }
    if isType3 { return charProcNames != nil }
    return true
  }

  /// P14-012: glyph width in 1000-unit text space, or nil when the font
  /// carries no usable width data. Codes outside the Widths range use the
  /// descriptor's MissingWidth (default 0) when the array exists.
  func width(of code: UInt8) -> Double? {
    let value = Int(code)
    if let firstChar, let widths, value >= firstChar, value < firstChar + widths.count {
      return widths[value - firstChar]
    }
    if let missingWidth { return missingWidth }
    if widths != nil { return 0 }
    return nil
  }

  /// P14-015: advance of a code sequence in unscaled text-space units,
  /// including character/word spacing and horizontal scaling.
  func advance(
    of codes: [UInt8], fontSize: Double, charSpacing: Double, wordSpacing: Double,
    horizontalScale: Double
  ) -> Double? {
    var total = 0.0
    for code in codes {
      guard let width = width(of: code) else { return nil }
      total += width / 1000 * fontSize
      total += charSpacing
      if code == 32 { total += wordSpacing }
    }
    return total * horizontalScale / 100
  }

  /// Decode one string's bytes to text using this font's encoding (ToUnicode
  /// first when present, then Differences, then the base encoding).
  func decode(_ codes: [UInt8]) -> String {
    var result = ""
    for code in codes {
      if let toUnicode, let mapped = toUnicode.decode(code) {
        result += mapped
        continue
      }
      if let mapped = differences[code] {
        result += mapped
        continue
      }
      // An unknown Differences name replaces the base glyph too. Never
      // silently read (or later write) the base character at that code.
      if differenceNames[code] != nil {
        result += "\u{FFFD}"
        continue
      }
      switch baseEncoding {
      case .winAnsi:
        if let text = String(bytes: [code], encoding: .windowsCP1252) {
          result += text
        } else {
          result += "\u{FFFD}"
        }
      case .macRoman:
        result += PDFMacRoman.characters[code].map(String.init) ?? "\u{FFFD}"
      case .standardASCII:
        switch code {
        case 0x20...0x7E:
          // StandardEncoding differs from ASCII only at the quotes.
          if code == 0x27 { result += "\u{2019}" } else if code == 0x60 { result += "\u{2018}" }
          else { result += String(UnicodeScalar(code)) }
        default:
          result += "\u{FFFD}"
        }
      case .unsupportedName:
        result += "\u{FFFD}"
      }
    }
    return result
  }

  /// Encode replacement text with existing glyphs, or nil when any character
  /// has no available code (P18-006: never substitute silently). For a
  /// Type 3 font (P14-023) a code is accepted only when its Differences name
  /// names a glyph program that exists in `/CharProcs`.
  func encode(_ text: String) -> [UInt8]? {
    var reverse: [Character: [UInt8]] = [:]
    for (code, mapped) in differences.sorted(by: { $0.key < $1.key }) {
      if let character = mapped.first, mapped.count == 1 {
        reverse[character, default: []].append(code)
      }
    }
    if case .macRoman = baseEncoding {
      for (character, codes) in PDFMacRoman.codes {
        reverse[character, default: []] += codes
      }
    }
    if case .standardASCII = baseEncoding {
      for code in 0x20...0x7E {
        let byte = UInt8(code)
        let character: Character
        if byte == 0x27 {
          character = "\u{2019}"
        } else if byte == 0x60 {
          character = "\u{2018}"
        } else {
          character = Character(UnicodeScalar(byte))
        }
        reverse[character, default: []].append(byte)
      }
    }
    func verified(_ code: UInt8, for character: Character) -> UInt8? {
      guard decode([code]) == String(character) else { return nil }
      guard isType3 else { return code }
      guard let name = differenceNames[code], let charProcNames,
        charProcNames.contains(name)
      else {
        return nil
      }
      return code
    }
    var codes: [UInt8] = []
    for character in text {
      // P19-007: an explicit ToUnicode CMap is the reverse map of choice.
      if let toUnicode, let code = toUnicode.code(for: String(character)),
        let code = verified(code, for: character)
      {
        codes.append(code)
        continue
      }
      if let code = reverse[character]?.lazy.compactMap({ verified($0, for: character) }).first {
        codes.append(code)
        continue
      }
      switch baseEncoding {
      case .winAnsi:
        guard let data = String(character).data(using: .windowsCP1252), data.count == 1,
          let code = verified(data[0], for: character)
        else {
          return nil
        }
        codes.append(code)
      case .macRoman, .standardASCII:
        return nil  // character has no verified code in the supported base encoding
      case .unsupportedName:
        return nil
      }
    }
    return codes
  }

  /// Resolve one named font resource from a page's Resources/Font dictionary.
  static func resolve(
    resource: PDFName, page: [PDFName: PDFValue], in graph: PDFGraph
  ) -> SimpleFont? {
    guard case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph),
      case .dictionary(let fonts)? = FontValue.resolve(resources[PDFName("Font")], in: graph),
      let entry = fonts[resource]
    else { return nil }
    let fontID: PDFObjectID
    let font: [PDFName: PDFValue]
    switch entry {
    case .reference(let id):
      guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
      fontID = id
      font = dictionary
    case .dictionary(let dictionary):
      guard case .reference(let id)? = dictionary[PDFName("objid")] else { return nil }
      fontID = id
      font = dictionary
    default:
      return nil
    }
    return make(resource: resource, fontID: fontID, dictionary: font, in: graph)
  }

  private static func make(
    resource: PDFName, fontID: PDFObjectID, dictionary: [PDFName: PDFValue], in graph: PDFGraph
  ) -> SimpleFont? {
    // Composite fonts are out of the first profile.
    if dictionary[PDFName("Subtype")] == .name(PDFName("Type0")) { return nil }
    // P14-023: Type 3 fonts write only through verified glyph programs.
    let isType3 = dictionary[PDFName("Subtype")] == .name(PDFName("Type3"))
    let baseFont: String
    if case .name(let name)? = dictionary[PDFName("BaseFont")] {
      baseFont = String(decoding: name.bytes, as: UTF8.self)
    } else {
      baseFont = ""
    }
    var baseEncoding: BaseEncoding = .standardASCII
    var differences: [UInt8: String] = [:]
    var differenceNames: [UInt8: String] = [:]
    let encoding = FontValue.resolve(dictionary[PDFName("Encoding")], in: graph)
    if dictionary[PDFName("Encoding")] != nil && encoding == nil { return nil }
    switch encoding {
    case nil:
      baseEncoding = .standardASCII
    case .name(let name)?:
      baseEncoding = Self.encoding(named: name)
    case .dictionary(let encoding)?:
      if case .name(let name)? = FontValue.resolve(encoding[PDFName("BaseEncoding")], in: graph) {
        baseEncoding = Self.encoding(named: name)
      }
      if case .array(let values)? = FontValue.resolve(encoding[PDFName("Differences")], in: graph) {
        var current: Int?
        for value in values {
          switch value {
          case .integer(let raw):
            current = Int(raw)
          case .name(let glyph):
            if let code = current, (0...255).contains(code) {
              let name = String(decoding: glyph.bytes, as: UTF8.self)
              differenceNames[UInt8(code)] = name
              if let unicode = GlyphNames.unicode(for: name) {
                differences[UInt8(code)] = unicode
              } else {
                differences.removeValue(forKey: UInt8(code))
              }
              current = code + 1
            }
          default:
            break
          }
        }
      }
    default:
      return nil
    }
    let unknownDifferences = differenceNames.keys.contains { differences[$0] == nil }
    // Widths: FirstChar/Widths pairs, with the descriptor's MissingWidth for
    // codes outside the covered range.
    var firstChar: Int?
    var widths: [Double]?
    if case .integer(let rawFirst)? = FontValue.resolve(dictionary[PDFName("FirstChar")], in: graph),
      let parsedFirst = Int(exactly: rawFirst),
      case .array(let rawWidths)? = FontValue.resolve(dictionary[PDFName("Widths")], in: graph)
    {
      var parsedWidths: [Double] = []
      var invalid = false
      for raw in rawWidths {
        switch FontValue.resolve(raw, in: graph) {
        case .integer(let value)?: parsedWidths.append(Double(value))
        case .real(let value)?: parsedWidths.append(value)
        default: invalid = true
        }
        if invalid { break }
      }
      if !invalid, !parsedWidths.isEmpty {
        firstChar = parsedFirst
        widths = parsedWidths
      }
    }
    var missingWidth: Double?
    if case .dictionary(let descriptor)? = FontValue.resolve(dictionary[PDFName("FontDescriptor")], in: graph) {
      switch FontValue.resolve(descriptor[PDFName("MissingWidth")], in: graph) {
      case .integer(let raw)?: missingWidth = Double(raw)
      case .real(let raw)?: missingWidth = raw
      default: break
      }
    }
    var toUnicode: ToUnicodeCMap?
    switch dictionary[PDFName("ToUnicode")] {
    case .reference(let cmapID)?:
      if case .stream(let stream)? = graph.objects[cmapID] {
        toUnicode = ToUnicodeCMap(stream: stream)
      }
    case .stream(let stream)?:
      toUnicode = ToUnicodeCMap(stream: stream)
    default:
      break
    }
    // P14-023: the glyph-program names a Type 3 font can actually paint.
    var charProcNames: Set<String>?
    if isType3 {
      var charProcs: [PDFName: PDFValue]?
      switch dictionary[PDFName("CharProcs")] {
      case .reference(let procsID)?:
        if case .dictionary(let value)? = graph.objects[procsID] { charProcs = value }
      case .dictionary(let value)?:
        charProcs = value
      default:
        break
      }
      if let charProcs {
        charProcNames = Set(charProcs.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
      }
    }
    return SimpleFont(
      resource: resource, fontID: fontID, baseFont: baseFont, baseEncoding: baseEncoding,
      differences: differences, hasUnknownDifferences: unknownDifferences, firstChar: firstChar,
      widths: widths, missingWidth: missingWidth, isType3: isType3,
      differenceNames: differenceNames, charProcNames: charProcNames, toUnicode: toUnicode)
  }

  private static func encoding(named name: PDFName) -> BaseEncoding {
    switch name {
    case PDFName("WinAnsiEncoding"): return .winAnsi
    case PDFName("MacRomanEncoding"): return .macRoman
    case PDFName("StandardEncoding"): return .standardASCII
    default: return .unsupportedName(String(decoding: name.bytes, as: UTF8.self))
    }
  }
}
