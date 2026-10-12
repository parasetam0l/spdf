import PDFCore
import Foundation

/// P30-006: bounded first-party DER reading for CMS structures. Only the
/// shapes the signature profile needs; depth, length, and counts are bounded
/// by the caller's limits, and indefinite (BER) lengths are refused.
struct DERReader {
  let bytes: [UInt8]
  var offset: Int
  let end: Int

  init(bytes: [UInt8], offset: Int = 0, end: Int? = nil) {
    self.bytes = bytes
    self.offset = offset
    self.end = end ?? bytes.count
  }

  var isAtEnd: Bool { offset >= end }

  struct Element {
    let tag: UInt8
    let content: ArraySlice<UInt8>
    /// Offset of the element's first tag byte in the reader's bytes.
    let start: Int
  }

  mutating func readElement(limits: PDFLimits) throws -> Element {
    guard offset < end else {
      throw PDFError(.malformed, "Signature structure ended unexpectedly")
    }
    let start = offset
    let tag = bytes[offset]
    offset += 1
    guard offset < end else {
      throw PDFError(.malformed, "Signature length is missing")
    }
    let first = bytes[offset]
    offset += 1
    var length: Int
    if first & 0x80 == 0 {
      length = Int(first)
    } else {
      let count = Int(first & 0x7F)
      guard count >= 1, count <= 4, offset + count <= end else {
        throw PDFError(.malformed, "Unsupported signature length encoding")
      }
      var value = 0
      for _ in 0..<count {
        value = (value << 8) | Int(bytes[offset])
        offset += 1
      }
      length = value
    }
    guard length >= 0, length <= end - offset, length <= limits.tokenBytes else {
      throw PDFError(.malformed, "Signature element exceeds its bounds")
    }
    let content = bytes[offset..<(offset + length)]
    offset += length
    return Element(tag: tag, content: content, start: start)
  }

  static func expect(_ element: Element, tag: UInt8, _ message: String) throws {
    guard element.tag == tag else {
      throw PDFError(.malformed, message)
    }
  }

  /// Decodes an OBJECT IDENTIFIER value into dotted notation.
  static func oid(_ content: ArraySlice<UInt8>) -> String {
    var parts: [Int] = []
    var value = 0
    var started = false
    for byte in content {
      value = (value << 7) | Int(byte & 0x7F)
      started = true
      if byte & 0x80 == 0 {
        parts.append(value)
        value = 0
        started = false
      }
    }
    if started { parts.append(value) }
    guard let first = parts.first else { return "" }
    var result = [first / 40, first % 40]
    result.append(contentsOf: parts.dropFirst())
    return result.map(String.init).joined(separator: ".")
  }

  static func integer(_ content: ArraySlice<UInt8>) -> Int? {
    guard !content.isEmpty, content.count <= 8 else { return nil }
    var value = 0
    for byte in content { value = (value << 8) | Int(byte) }
    return value
  }

  /// DER UTCTime or GeneralizedTime in the common forms.
  static func time(_ tag: UInt8, _ content: ArraySlice<UInt8>) -> Date? {
    let text = String(decoding: content, as: UTF8.self)
    var format = "yyMMddHHmmssZ"
    if tag == 0x18 { format = "yyyyMMddHHmmssZ" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    if let date = formatter.date(from: text) { return date }
    format = tag == 0x18 ? "yyyyMMddHHmmss" : "yyMMddHHmmss"
    formatter.dateFormat = format
    return formatter.date(from: text)
  }
}
