import Foundation

/// P30-019: minimal DER encoding for CMS signature generation. Only the
/// structures the supported profile emits; every length is canonical.
enum DER {
  static func length(_ count: Int) -> Data {
    if count < 0x80 {
      return Data([UInt8(count)])
    }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
      bytes.insert(UInt8(value & 0xFF), at: 0)
      value >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }

  static func element(tag: UInt8, _ content: Data) -> Data {
    var data = Data([tag])
    data.append(length(content.count))
    data.append(content)
    return data
  }

  static func sequence(_ parts: [Data]) -> Data {
    element(tag: 0x30, concatenated(parts))
  }

  /// SET OF: DER requires the elements sorted by their encodings.
  static func set(_ parts: [Data]) -> Data {
    element(tag: 0x31, concatenated(parts.sorted { $0.lexicographicallyPrecedes($1) }))
  }

  static func integer(_ value: Int) -> Data {
    var bytes: [UInt8] = []
    var remaining = value
    repeat {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    } while remaining > 0
    if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
    return element(tag: 0x02, Data(bytes))
  }

  static func oid(_ dotted: String) -> Data {
    var parts: [Int] = dotted.split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2 else { return element(tag: 0x06, Data()) }
    let first = parts[0] * 40 + parts[1]
    parts.removeFirst(2)
    var bytes: [UInt8] = [UInt8(first)]
    for part in parts {
      var value = part
      var group: [UInt8] = [UInt8(value & 0x7F)]
      value >>= 7
      while value > 0 {
        group.insert(UInt8(value & 0x7F) | 0x80, at: 0)
        value >>= 7
      }
      bytes.append(contentsOf: group)
    }
    return element(tag: 0x06, Data(bytes))
  }

  static func octetString(_ data: Data) -> Data {
    element(tag: 0x04, data)
  }

  static func boolean(_ value: Bool) -> Data {
    element(tag: 0x01, Data([value ? 0xFF : 0x00]))
  }

  /// UTCTime in the DER form (Zulu seconds precision).
  static func utcTime(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    return element(tag: 0x17, Data(formatter.string(from: date).utf8))
  }

  /// Context-specific wrapper; `implicit` keeps the tag without the inner
  /// tag/length (used for [0] IMPLICIT SET in CMS).
  static func context(_ tag: UInt8, _ content: Data, implicit: Bool = false) -> Data {
    element(tag: 0xA0 | tag, content)
  }

  static func concatenated(_ parts: [Data]) -> Data {
    var data = Data()
    for part in parts { data.append(part) }
    return data
  }
}
