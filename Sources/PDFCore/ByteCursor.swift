import Foundation

struct ByteCursor {
  let bytes: [UInt8]
  var offset: Int

  init(_ bytes: [UInt8], offset: Int = 0) throws {
    guard (0...bytes.count).contains(offset) else {
      throw PDFError(.malformed, "Offset is outside the file", offset: offset)
    }
    self.bytes = bytes
    self.offset = offset
  }

  var peek: UInt8? { offset < bytes.count ? bytes[offset] : nil }

  static func isWhitespace(_ byte: UInt8) -> Bool {
    [0, 9, 10, 12, 13, 32].contains(byte)
  }

  static func isDelimiter(_ byte: UInt8) -> Bool {
    [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte)
  }

  mutating func skipWhitespace() {
    while let byte = peek, Self.isWhitespace(byte) { offset += 1 }
  }

  mutating func skipTrivia() {
    while true {
      skipWhitespace()
      guard peek == 37 else { return }
      while let byte = peek, byte != 10, byte != 13 { offset += 1 }
    }
  }

  mutating func read() throws -> UInt8 {
    guard let byte = peek else {
      throw PDFError(.malformed, "Unexpected end of file", offset: offset)
    }
    offset += 1
    return byte
  }

  func matches(_ ascii: String) -> Bool {
    let token = Array(ascii.utf8)
    guard token.count <= bytes.count - offset else { return false }
    return bytes[offset..<(offset + token.count)].elementsEqual(token)
  }

  mutating func consume(_ ascii: String) throws {
    guard matches(ascii) else {
      throw PDFError(.malformed, "Expected a structural PDF token", offset: offset)
    }
    offset += ascii.utf8.count
  }

  mutating func keyword(_ ascii: String) throws {
    try consume(ascii)
    guard peek == nil || Self.isWhitespace(peek!) || Self.isDelimiter(peek!) else {
      throw PDFError(.malformed, "Invalid structural token boundary", offset: offset)
    }
  }

  mutating func word(maximum: Int) throws -> [UInt8] {
    skipTrivia()
    let start = offset
    while let byte = peek, !Self.isWhitespace(byte), !Self.isDelimiter(byte) {
      guard offset - start < maximum else {
        throw PDFError(.limitExceeded, "Token exceeds the configured limit", offset: start)
      }
      offset += 1
    }
    guard offset > start else {
      throw PDFError(.malformed, "Expected a PDF token", offset: offset)
    }
    return Array(bytes[start..<offset])
  }

  mutating func integer(maximum: Int = 32) throws -> Int {
    let token = try word(maximum: maximum)
    guard token.allSatisfy({ (48...57).contains($0) }),
      let value = Int(String(decoding: token, as: UTF8.self))
    else {
      throw PDFError(.malformed, "Invalid unsigned integer", offset: offset - token.count)
    }
    return value
  }

  mutating func take(_ count: Int) throws -> Data {
    guard count >= 0, count <= bytes.count - offset else {
      throw PDFError(.malformed, "Byte range exceeds the file", offset: offset)
    }
    let result = Data(bytes[offset..<(offset + count)])
    offset += count
    return result
  }
}

/// Public byte classification for layers that tokenize PDF byte streams
/// (content streams in PDFEditing) without exposing the cursor itself.
public enum PDFByteClassification {
  public static func isWhitespace(_ byte: UInt8) -> Bool { ByteCursor.isWhitespace(byte) }
  public static func isDelimiter(_ byte: UInt8) -> Bool { ByteCursor.isDelimiter(byte) }
}
