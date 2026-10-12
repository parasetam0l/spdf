import Foundation

/// P36-012: an explicit locale policy for optional number and date typing.
/// Nothing is typed implicitly: the displayed text is always preserved
/// (P36-013) and a value that does not match the policy stays text.
public struct TableValuePolicy: Sendable, Equatable {
  public enum Locale: String, Sendable, Equatable {
    /// Decimal point, comma grouping, `MM/dd/yyyy` dates.
    case posix
    /// Decimal comma, dot grouping, `dd.MM.yyyy` dates.
    case german
    /// Decimal comma, space grouping, `dd/MM/yyyy` dates.
    case french
  }

  public var locale: Locale
  /// Parse plain numbers (including grouping and a leading sign).
  public var parseNumbers: Bool
  /// Parse dates in the locale's formats plus ISO `yyyy-MM-dd`.
  public var parseDates: Bool
  /// Keep values with leading zeros as text (default; P36-011).
  public var treatLeadingZerosAsText: Bool

  public init(
    locale: Locale = .posix, parseNumbers: Bool = true, parseDates: Bool = true,
    treatLeadingZerosAsText: Bool = true
  ) {
    self.locale = locale
    self.parseNumbers = parseNumbers
    self.parseDates = parseDates
    self.treatLeadingZerosAsText = treatLeadingZerosAsText
  }

  var decimalSeparator: String {
    switch locale {
    case .posix: return "."
    case .german, .french: return ","
    }
  }

  var groupingSeparator: String? {
    switch locale {
    case .posix: return ","
    case .german: return "."
    case .french: return " "
    }
  }

  var dateFormats: [String] {
    switch locale {
    case .posix: return ["yyyy-MM-dd", "MM/dd/yyyy"]
    case .german: return ["yyyy-MM-dd", "dd.MM.yyyy"]
    case .french: return ["yyyy-MM-dd", "dd/MM/yyyy"]
    }
  }
}

/// P36-013: the displayed text stays the source of truth; a typed value is a
/// separate, optional inference.
public struct TableTypedValue: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case text
    case number(Double)
    /// Canonical ISO `yyyy-MM-dd`.
    case date(String)
  }

  /// The cell's displayed text, unchanged.
  public let displayText: String
  public let kind: Kind

  public var isText: Bool { kind == .text }

  public init(displayText: String, kind: Kind) {
    self.displayText = displayText
    self.kind = kind
  }
}

public enum TableValueParser {
  /// Bound: values longer than this are never typed.
  public static let maxCharacters = 64

  /// P36-012/P36-013: infer a typed value without changing the display text.
  public static func typedValue(
    for text: String, policy: TableValuePolicy = .init()
  ) -> TableTypedValue {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maxCharacters else {
      return TableTypedValue(displayText: text, kind: .text)
    }
    if policy.parseDates, let date = dateValue(trimmed, policy: policy) {
      return TableTypedValue(displayText: text, kind: .date(date))
    }
    if policy.parseNumbers, let number = numberValue(trimmed, policy: policy) {
      return TableTypedValue(displayText: text, kind: .number(number))
    }
    return TableTypedValue(displayText: text, kind: .text)
  }

  static func numberValue(_ text: String, policy: TableValuePolicy) -> Double? {
    var value = text
    var negative = false
    if value.hasPrefix("-") {
      negative = true
      value.removeFirst()
    } else if value.hasPrefix("+") {
      value.removeFirst()
    }
    // Digits, the locale's separators, and at most one decimal separator.
    if policy.treatLeadingZerosAsText {
      let digits = value.filter(\.isNumber)
      if digits.count > 1, digits.first == "0", !value.contains(policy.decimalSeparator) {
        return nil  // "007" stays text
      }
    }
    if let grouping = policy.groupingSeparator, !grouping.isEmpty,
      grouping != policy.decimalSeparator
    {
      let parts = value.components(separatedBy: policy.decimalSeparator)
      let integerPart = parts.first ?? ""
      if integerPart.contains(grouping) {
        // Grouping must be well-formed (1–3 digits, then groups of exactly 3).
        let groups = integerPart.components(separatedBy: grouping)
        guard groups.count >= 2, (1...3).contains(groups[0].count),
          groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
          groups.dropFirst().allSatisfy({ $0.count == 3 })
        else { return nil }
      }
      value = value.replacingOccurrences(of: grouping, with: "")
    }
    let pieces = value.components(separatedBy: policy.decimalSeparator)
    guard pieces.count <= 2, pieces.allSatisfy({ $0.allSatisfy(\.isNumber) }), !value.isEmpty,
      pieces.contains(where: { !$0.isEmpty })
    else { return nil }
    let normalized = pieces.joined(separator: ".")
    guard let number = Double(normalized) else { return nil }
    return negative ? -number : number
  }

  static func dateValue(_ text: String, policy: TableValuePolicy) -> String? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.isLenient = false
    for format in policy.dateFormats {
      formatter.dateFormat = format
      guard let date = formatter.date(from: text) else { continue }
      // Require a full-string match (DateFormatter would accept a prefix).
      formatter.dateFormat = format
      guard formatter.string(from: date) == text else { continue }
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.string(from: date)
    }
    return nil
  }
}
