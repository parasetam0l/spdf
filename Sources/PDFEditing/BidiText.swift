import Foundation

/// FNT-05: resolved Unicode bidirectional character classes for the
/// representative scripts in the declared profile (Latin, Hebrew, Arabic and
/// Devanagari letters, European/Arabic-Indic digits, neutrals, combining
/// marks). Explicit embedding/override controls are refused rather than
/// guessed.
public enum BidiCharacterClass: String, Sendable, Equatable {
  case leftToRightLetter = "L"
  case rightToLeftLetter = "R"
  case arabicLetter = "AL"
  case europeanNumber = "EN"
  case arabicNumber = "AN"
  case europeanSeparator = "ES"
  case europeanTerminator = "ET"
  case commonSeparator = "CS"
  case nonSpacingMark = "NSM"
  case boundaryNeutral = "BN"
  case paragraphSeparator = "B"
  case segmentSeparator = "S"
  case whiteSpace = "WS"
  case otherNeutral = "ON"
}

public enum BidiDirection: Sendable, Equatable, Hashable {
  case leftToRight
  case rightToLeft
}

public enum BidiBaseDirection: Sendable, Equatable, Hashable {
  case leftToRight
  case rightToLeft
  case automatic
}

public enum BidiTextError: Error, Equatable, CustomStringConvertible {
  case explicitControlsUnsupported(String)
  case paragraphTooLong(Int)
  case byteOrderMarkUnsupported

  public var description: String {
    switch self {
    case .explicitControlsUnsupported(let detail):
      return "Explicit bidi embedding/override controls are outside this profile (\(detail))"
    case .paragraphTooLong(let count):
      return "The bidi paragraph is too long (\(count) UTF-16 units)"
    case .byteOrderMarkUnsupported:
      return "Byte order marks are not part of an edited paragraph; use the paragraph direction"
    }
  }
}

/// FNT-05: one resolved run in visual order. visualText is the string that
/// should be drawn (with mirrored punctuation for RTL), while text is the
/// logical substring and logicalRange addresses the source paragraph.
public struct BidiRun: Sendable, Equatable {
  public let text: String
  public let visualText: String
  public let logicalRange: Range<Int>
  public let level: Int

  public var direction: BidiDirection {
    level % 2 == 0 ? .leftToRight : .rightToLeft
  }

  public init(
    text: String, visualText: String, logicalRange: Range<Int>, level: Int
  ) {
    self.text = text
    self.visualText = visualText
    self.logicalRange = logicalRange
    self.level = level
  }
}

/// FNT-05: a resolved bidirectional paragraph with explicit logical and
/// visual ordering, caret conversion and mirrored punctuation.
public struct BidiParagraph: Sendable, Equatable {
  public let text: String
  public let baseLevel: Int
  /// Resolved embedding level for every UTF-16 unit.
  public let levels: [Int]
  /// Runs in visual left-to-right order.
  public let runs: [BidiRun]
  /// Maps every logical UTF-16 boundary (0...n) to a visual boundary.
  public let logicalToVisualBoundary: [Int]
  public let hasRightToLeftContent: Bool

  public var baseDirection: BidiDirection {
    baseLevel % 2 == 0 ? .leftToRight : .rightToLeft
  }

  /// The visual string built from the visual runs (mirrored punctuation).
  public var visualString: String {
    runs.map(\.visualText).joined()
  }

  /// Convert a logical caret offset to its visual caret offset.
  public func visualOffset(forLogical offset: Int) -> Int {
    let clamped = max(0, min(logicalToVisualBoundary.count - 1, offset))
    return logicalToVisualBoundary[clamped]
  }

  /// Convert a visual caret offset back to a logical caret offset.
  public func logicalOffset(forVisual offset: Int) -> Int {
    let clamped = max(0, offset)
    var best = 0
    var bestDistance = Int.max
    for (logical, visual) in logicalToVisualBoundary.enumerated() {
      let distance = abs(visual - clamped)
      if distance < bestDistance
        || (distance == bestDistance && logical % 2 == 0)
      {
        bestDistance = distance
        best = logical
      }
    }
    return best
  }

  /// True when every logical unit is covered exactly once by the visual runs.
  public var coversEveryUnitOnce: Bool {
    var seen = [Int](repeating: 0, count: max(1, text.utf16.count))
    for run in runs {
      for index in run.logicalRange where index < seen.count {
        seen[index] += 1
      }
    }
    return seen.allSatisfy { $0 == 1 }
  }
}

/// FNT-05: a bounded UAX #9 implementation for the declared profile. Levels,
/// weak/neutral resolution, implicit levels, L1 resets and L2 reordering are
/// implemented; explicit embedding controls and isolates are refused so the
/// result never silently disagrees with the UI.
public enum BidiText {
  public static let maximumUnits = 16_384

  public static func resolve(
    _ text: String, baseDirection: BidiBaseDirection = .automatic
  ) throws -> BidiParagraph {
    let units = Array(text.utf16)
    guard units.count <= maximumUnits else {
      throw BidiTextError.paragraphTooLong(units.count)
    }
    guard !units.isEmpty else {
      return BidiParagraph(
        text: text, baseLevel: 0, levels: [], runs: [],
        logicalToVisualBoundary: [0], hasRightToLeftContent: false)
    }
    try rejectUnsupportedControls(units)
    var classes = units.map { characterClass(for: $0) }
    let baseLevel: Int
    switch baseDirection {
    case .leftToRight:
      baseLevel = 0
    case .rightToLeft:
      baseLevel = 1
    case .automatic:
      baseLevel = firstStrongLevel(in: classes) ?? 0
    }

    // W1: a non-spacing mark takes the class of the preceding character.
    for index in 1..<classes.count where classes[index] == .nonSpacingMark {
      classes[index] = classes[index - 1] == .boundaryNeutral
        || classes[index - 1] == .nonSpacingMark
        ? classes[index] : classes[index - 1]
    }
    // W2/W3: European numbers after an Arabic letter become Arabic numbers;
    // Arabic letters resolve to right-to-left.
    var lastStrong: BidiCharacterClass = baseLevel == 0 ? .leftToRightLetter : .rightToLeftLetter
    for index in classes.indices {
      switch classes[index] {
      case .arabicLetter:
        lastStrong = .rightToLeftLetter
        classes[index] = .rightToLeftLetter
      case .leftToRightLetter, .rightToLeftLetter:
        lastStrong = classes[index]
      case .europeanNumber:
        if lastStrong == .arabicLetter || lastStrong == .rightToLeftLetter {
          classes[index] = .arabicNumber
        }
      default:
        break
      }
    }
    // W4: separators between numbers become numbers.
    if classes.count >= 3 {
    for index in 1..<(classes.count - 1) {
      let previous = classes[index - 1]
      let next = classes[index + 1]
      if classes[index] == .europeanSeparator
        && previous == .europeanNumber && next == .europeanNumber
      {
        classes[index] = .europeanNumber
      } else if classes[index] == .commonSeparator,
        (previous == .europeanNumber && next == .europeanNumber)
          || (previous == .arabicNumber && next == .arabicNumber)
      {
        classes[index] = previous
      }
    }
    }
    // W5: a terminator next to a European number becomes a number.
    for index in classes.indices {
      guard classes[index] == .europeanTerminator else { continue }
      var left = index
      while left > 0, classes[left - 1] == .europeanTerminator { left -= 1 }
      if left > 0, classes[left - 1] == .europeanNumber {
        for terminator in left...index { classes[terminator] = .europeanNumber }
        continue
      }
      var right = index
      while right + 1 < classes.count, classes[right + 1] == .europeanTerminator {
        right += 1
      }
      if right + 1 < classes.count, classes[right + 1] == .europeanNumber {
        for terminator in index...right { classes[terminator] = .europeanNumber }
      }
    }
    // W6: remaining separators/terminators are neutrals.
    for index in classes.indices
    where classes[index] == .europeanSeparator
      || classes[index] == .europeanTerminator
      || classes[index] == .commonSeparator
    {
      classes[index] = .otherNeutral
    }
    // W7: a European number after a left-to-right letter becomes a letter.
    lastStrong = baseLevel == 0 ? .leftToRightLetter : .rightToLeftLetter
    for index in classes.indices {
      switch classes[index] {
      case .leftToRightLetter, .rightToLeftLetter:
        lastStrong = classes[index]
      case .europeanNumber:
        if lastStrong == .leftToRightLetter { classes[index] = .leftToRightLetter }
      default:
        break
      }
    }

    // N rules: neutrals take the direction of surrounding strong text.
    var types = classes
    var index = 0
    while index < types.count {
      if !isNeutral(types[index]) {
        index += 1
        continue
      }
      var start = index
      while start > 0, isNeutral(types[start - 1]) { start -= 1 }
      var end = index
      while end + 1 < types.count, isNeutral(types[end + 1]) { end += 1 }
      let before: BidiDirection? = start > 0 ? direction(of: types[start - 1]) : nil
      let after: BidiDirection? = end + 1 < types.count ? direction(of: types[end + 1]) : nil
      let resolved: BidiCharacterClass
      if before == after, let before {
        resolved = before == .leftToRight ? .leftToRightLetter : .rightToLeftLetter
      } else {
        resolved = baseLevel == 0 ? .leftToRightLetter : .rightToLeftLetter
      }
      for neutral in start...end { types[neutral] = resolved }
      index = end + 1
    }

    // I1/I2 implicit levels.
    var levels = [Int](repeating: baseLevel, count: units.count)
    for index in types.indices {
      switch types[index] {
      case .leftToRightLetter:
        levels[index] = baseLevel + (baseLevel % 2)
      case .rightToLeftLetter:
        levels[index] = baseLevel + (baseLevel % 2 == 0 ? 1 : 0)
      case .europeanNumber, .arabicNumber:
        levels[index] = baseLevel + (baseLevel % 2 == 0 ? 2 : 1)
      default:
        levels[index] = baseLevel
      }
    }
    // L1: separators and trailing whitespace reset to the paragraph level.
    for index in levels.indices where classes[index] == .paragraphSeparator
      || classes[index] == .segmentSeparator
    {
      levels[index] = baseLevel
    }
    var trailing = levels.count - 1
    while trailing >= 0,
      classes[trailing] == .whiteSpace || classes[trailing] == .boundaryNeutral
    {
      levels[trailing] = baseLevel
      trailing -= 1
    }

    // L2 reordering on code units.
    var order = Array(levels.indices)
    if let highest = levels.max(), highest > 0 {
      var lowestOdd = highest
      for level in levels where level % 2 == 1 { lowestOdd = min(lowestOdd, level) }
      if lowestOdd <= highest {
        for level in stride(from: highest, through: lowestOdd, by: -1) {
          var cursor = 0
          while cursor < order.count {
            guard levels[order[cursor]] >= level else {
              cursor += 1
              continue
            }
            var end = cursor
            while end + 1 < order.count, levels[order[end + 1]] >= level { end += 1 }
            order[cursor...end].reverse()
            cursor = end + 1
          }
        }
      }
    }

    // Build visual runs from contiguous equal levels in the visual order.
    var runs: [BidiRun] = []
    var visualCursor = 0
    while visualCursor < order.count {
      let level = levels[order[visualCursor]]
      var end = visualCursor
      while end + 1 < order.count, levels[order[end + 1]] == level { end += 1 }
      let logicalUnits = order[visualCursor...end].sorted()
      let logicalRange = logicalUnits.first!..<(logicalUnits.last! + 1)
      let logicalText = String(decoding: units[logicalRange], as: UTF16.self)
      let visualText = String(decoding: order[visualCursor...end].map { units[$0] }, as: UTF16.self)
      runs.append(
        BidiRun(
          text: logicalText,
          visualText: level % 2 == 0 ? visualText : mirrored(visualText),
          logicalRange: logicalRange, level: level))
      visualCursor = end + 1
    }

    // Boundary mapping from logical offsets to visual offsets. A boundary in
    // the middle of the paragraph uses the leading visual edge of the logical
    // character that follows it (right edge inside a right-to-left run). The
    // paragraph edges follow the base direction: Home is the visual left edge
    // and End the visual right edge of a left-to-right paragraph, and the
    // mirrored visual edges for a right-to-left paragraph.
    var boundary = [Int](repeating: 0, count: units.count + 1)
    var visualStart = 0
    for run in runs {
      for logical in run.logicalRange {
        if run.level % 2 == 0 {
          boundary[logical] = visualStart + (logical - run.logicalRange.lowerBound)
        } else {
          boundary[logical] = visualStart + (run.logicalRange.upperBound - logical)
        }
      }
      visualStart += run.logicalRange.count
    }
    boundary[0] = baseLevel % 2 == 0 ? 0 : units.count
    boundary[units.count] = baseLevel % 2 == 0 ? units.count : 0

    return BidiParagraph(
      text: text, baseLevel: baseLevel, levels: levels, runs: runs,
      logicalToVisualBoundary: boundary,
      hasRightToLeftContent: levels.contains { $0 % 2 == 1 })
  }

  static func isNeutral(_ value: BidiCharacterClass) -> Bool {
    switch value {
    case .otherNeutral, .whiteSpace, .boundaryNeutral, .segmentSeparator,
      .paragraphSeparator:
      return true
    default:
      return false
    }
  }

  static func direction(of value: BidiCharacterClass) -> BidiDirection? {
    switch value {
    case .leftToRightLetter, .europeanNumber: return .leftToRight
    case .rightToLeftLetter, .arabicNumber: return .rightToLeft
    default: return nil
    }
  }

  static func firstStrongLevel(in classes: [BidiCharacterClass]) -> Int? {
    for value in classes {
      if value == .leftToRightLetter { return 0 }
      if value == .rightToLeftLetter || value == .arabicLetter { return 1 }
    }
    return nil
  }

  /// Explicit embedding and override controls change the meaning of the text
  /// in ways an edited paragraph should not carry; isolate controls have the
  /// same problem. Refusing them is the declared profile.
  static func rejectUnsupportedControls(_ units: [UInt16]) throws {
    for unit in units {
      switch unit {
      case 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069:
        throw BidiTextError.explicitControlsUnsupported(
          String(format: "U+%04X", unit))
      case 0xFEFF:
        throw BidiTextError.byteOrderMarkUnsupported
      default:
        break
      }
    }
  }

  /// Mirror the opening/closing punctuation used by representative
  /// bidirectional text. Characters without a mirror keep their identity.
  public static func mirrored(_ text: String) -> String {
    String(text.map { character in mirrorMap[character] ?? character })
  }

  static let mirrorMap: [Character: Character] = [
    "(": ")", ")": "(", "[": "]", "]": "[", "{": "}", "}": "{",
    "«": "»", "»": "«", "‹": "›", "›": "‹", "<": ">", ">": "<",
  ]

  // MARK: - Classification

  static func characterClass(for unit: UInt16) -> BidiCharacterClass {
    guard let scalarValue = UnicodeScalar(unit).map({ Int($0.value) }) else {
      return .otherNeutral
    }
    let scalar = scalarValue
    if isNonSpacingMark(scalar) { return .nonSpacingMark }
    if scalar == 0 { return .boundaryNeutral }
    if scalar == 0x0A { return .paragraphSeparator }
    if scalar == 0x0D || scalar == 0x09 || scalar == 0x0B || scalar == 0x1C
      || scalar == 0x1D || scalar == 0x1E || scalar == 0x1F
    {
      return .segmentSeparator
    }
    switch scalar {
    case 0x20, 0x0C, 0x85, 0x2028, 0x2029:
      return .whiteSpace
    case 0x2B, 0x2D:
      return .europeanSeparator
    case 0x2C, 0x2E:
      return .commonSeparator
    case 0x23, 0x24, 0x25, 0x40, 0xB0, 0xA2, 0xA3, 0xA4, 0xA5, 0xB1,
      0x2018, 0x2019, 0x201C, 0x201D, 0x2013, 0x2014, 0x2026:
      return .otherNeutral
    case 0x30...0x39, 0x06F0...0x06F9, 0xFF10...0xFF19, 0x0966...0x096F:
      return .europeanNumber
    case 0x0660...0x0669:
      return .arabicNumber
    case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF,
      0xFE70...0xFEFF:
      return .arabicLetter
    case 0x0590...0x05FF:
      if isHebrewPunctuation(scalar) { return .otherNeutral }
      return .rightToLeftLetter
    case 0x0900...0x097F:
      return .leftToRightLetter
    case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x02AF, 0x0370...0x058F,
      0x0900...0x0FFF, 0x1E00...0x1FFF, 0x2C00...0x2C7F, 0xA720...0xA7FF:
      return .leftToRightLetter
    case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
      0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFF0F, 0xFF1A...0xFF20,
      0xFF3B...0xFF40, 0xFF5B...0xFF65, 0x20000...0x2FA1F:
      return .leftToRightLetter
    case 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x061C, 0x2060:
      return .boundaryNeutral
    default:
      return .otherNeutral
    }
  }

  static func isNonSpacingMark(_ scalar: Int) -> Bool {
    switch scalar {
    case 0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x05BF,
      0x05C1...0x05C2, 0x05C4...0x05C5, 0x05C7, 0x0610...0x061A,
      0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4,
      0x06E7...0x06E8, 0x06EA...0x06ED, 0x0711, 0x0730...0x074A,
      0x07A6...0x07B0, 0x0816...0x082D, 0x0859...0x085B, 0x08D3...0x08E1,
      0x08E3...0x0903, 0x093A...0x094F, 0x0951...0x0957, 0x0962, 0x0963,
      0x0E31, 0x0E34...0x0E3A, 0x0E47...0x0E4E, 0xFE00...0xFE0F,
      0xFE20...0xFE2F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF:
      return true
    default:
      return false
    }
  }

  static func isHebrewPunctuation(_ scalar: Int) -> Bool {
    switch scalar {
    case 0x05BE, 0x05C0, 0x05C3, 0x05C6, 0x05F3, 0x05F4:
      return true
    default:
      return false
    }
  }
}
