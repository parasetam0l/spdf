import Foundation

public struct PDFSyntaxParser {
  var cursor: ByteCursor
  let limits: PDFLimits

  /// Public facade used by content-stream parsing in higher layers.
  public init(bytes: [UInt8], offset: Int = 0, limits: PDFLimits = PDFLimits()) throws {
    self.cursor = try ByteCursor(bytes, offset: offset)
    self.limits = limits
  }

  init(cursor: ByteCursor, limits: PDFLimits) {
    self.cursor = cursor
    self.limits = limits
  }

  /// Current byte offset of the underlying cursor.
  public var offset: Int { cursor.offset }

  /// Byte at the cursor without consuming it.
  public var peekByte: UInt8? { cursor.peek }

  public mutating func skipTrivia() { cursor.skipTrivia() }

  public mutating func word(maximum: Int) throws -> [UInt8] {
    try cursor.word(maximum: maximum)
  }

  public mutating func setOffset(_ offset: Int) throws {
    guard (0...cursor.bytes.count).contains(offset) else {
      throw PDFError(.malformed, "Offset is outside the data", offset: offset)
    }
    cursor.offset = offset
  }

  public mutating func value(depth: Int = 0) throws -> PDFValue {
    try Task.checkCancellation()
    guard depth <= limits.nesting else {
      throw error(.limitExceeded, "Object nesting exceeds the configured limit")
    }
    cursor.skipTrivia()
    switch cursor.peek {
    case 47: return .name(try name())
    case 40: return .string(try literalString())
    case 60:
      if cursor.matches("<<") { return .dictionary(try dictionary(depth: depth)) }
      return .string(try hexadecimalString())
    case 91:
      cursor.offset += 1
      var values: [PDFValue] = []
      while true {
        cursor.skipTrivia()
        if cursor.peek == 93 {
          cursor.offset += 1
          return .array(values)
        }
        guard values.count < limits.objects else {
          throw error(.limitExceeded, "Array exceeds the configured item limit")
        }
        values.append(try value(depth: depth + 1))
      }
    default:
      let start = cursor.offset
      let token = try cursor.word(maximum: limits.tokenBytes)
      switch token {
      case Array("null".utf8): return .null
      case Array("true".utf8): return .boolean(true)
      case Array("false".utf8): return .boolean(false)
      default: break
      }
      let number = try parseNumber(token, at: start)
      if case .integer(let integer) = number, integer >= 0,
        let numberID = Int(exactly: integer)
      {
        let checkpoint = cursor.offset
        // A failed lookahead must not swallow malformed following values.
        if let generation = try? cursor.integer(), (0...65_535).contains(generation) {
          cursor.skipTrivia()
          if cursor.matches("R") {
            cursor.offset += 1
            if cursor.peek == nil || ByteCursor.isWhitespace(cursor.peek!)
              || ByteCursor.isDelimiter(cursor.peek!)
            {
              return .reference(PDFObjectID(numberID, generation: generation))
            }
          }
        }
        cursor.offset = checkpoint
      }
      return number
    }
  }

  mutating func dictionary(depth: Int) throws -> [PDFName: PDFValue] {
    try cursor.consume("<<")
    var result: [PDFName: PDFValue] = [:]
    while true {
      cursor.skipTrivia()
      if cursor.matches(">>") {
        cursor.offset += 2
        return result
      }
      guard result.count < limits.objects else {
        throw error(.limitExceeded, "Dictionary exceeds the configured entry limit")
      }
      guard cursor.peek == 47 else {
        throw error(.malformed, "Dictionary key is not a name")
      }
      let key = try name()
      guard result[key] == nil else {
        throw error(.malformed, "Duplicate dictionary keys are not supported")
      }
      result[key] = try value(depth: depth + 1)
    }
  }

  mutating func name() throws -> PDFName {
    try cursor.consume("/")
    var result: [UInt8] = []
    while let byte = cursor.peek,
      !ByteCursor.isWhitespace(byte), !ByteCursor.isDelimiter(byte)
    {
      try checkTokenLength(result.count, additional: 1)
      cursor.offset += 1
      if byte == 35 {
        guard let first = Self.hex(try cursor.read()),
          let second = Self.hex(try cursor.read())
        else { throw error(.malformed, "Invalid escaped name") }
        result.append(first * 16 + second)
      } else {
        result.append(byte)
      }
    }
    return PDFName(bytes: result)
  }

  mutating func literalString() throws -> Data {
    try cursor.consume("(")
    var result: [UInt8] = []
    var nesting = 1
    while nesting > 0 {
      try checkTokenLength(result.count)
      let byte = try cursor.read()
      switch byte {
      case 40:
        nesting += 1
        guard nesting <= limits.nesting else {
          throw error(.limitExceeded, "String nesting exceeds the configured limit")
        }
        result.append(byte)
      case 41:
        nesting -= 1
        if nesting > 0 { result.append(byte) }
      case 92:
        let escaped = try cursor.read()
        switch escaped {
        case 110: result.append(10)
        case 114: result.append(13)
        case 116: result.append(9)
        case 98: result.append(8)
        case 102: result.append(12)
        case 10: break
        case 13:
          if cursor.peek == 10 { cursor.offset += 1 }
        case 48...55:
          var octal = Int(escaped - 48)
          for _ in 0..<2 {
            guard let next = cursor.peek, (48...55).contains(next) else { break }
            cursor.offset += 1
            octal = octal * 8 + Int(next - 48)
          }
          result.append(UInt8(octal & 255))
        default: result.append(escaped)
        }
      case 13:
        if cursor.peek == 10 { cursor.offset += 1 }
        result.append(10)
      default: result.append(byte)
      }
      try checkTokenLength(result.count)
    }
    return Data(result)
  }

  mutating func hexadecimalString() throws -> Data {
    try cursor.consume("<")
    var result: [UInt8] = []
    var pending: UInt8?
    while true {
      try checkTokenLength(result.count)
      let byte = try cursor.read()
      if byte == 62 {
        if let pending { result.append(pending * 16) }
        try checkTokenLength(result.count)
        return Data(result)
      }
      if ByteCursor.isWhitespace(byte) { continue }
      guard let nibble = Self.hex(byte) else {
        throw error(.malformed, "Invalid hexadecimal string")
      }
      if let first = pending {
        result.append(first * 16 + nibble)
        try checkTokenLength(result.count)
        pending = nil
      } else {
        pending = nibble
      }
    }
  }

  func parseNumber(_ token: [UInt8], at offset: Int) throws -> PDFValue {
    let unsigned = token.first == 43 || token.first == 45 ? Array(token.dropFirst()) : token
    let digits = unsigned.filter { (48...57).contains($0) }.count
    let dots = unsigned.filter { $0 == 46 }.count
    guard digits > 0, dots <= 1, digits + dots == unsigned.count else {
      throw PDFError(.malformed, "Invalid PDF number or unsupported token", offset: offset)
    }
    let text = String(decoding: token, as: UTF8.self)
    if dots == 0 {
      guard let integer = Int64(text) else {
        throw PDFError(.limitExceeded, "Integer exceeds the supported range", offset: offset)
      }
      return .integer(integer)
    }
    guard let real = Double(text), real.isFinite else {
      throw PDFError(.limitExceeded, "Real number exceeds the supported range", offset: offset)
    }
    return .real(real)
  }

  func checkTokenLength(_ count: Int, additional: Int = 0) throws {
    if cursor.offset & 4095 == 0 { try Task.checkCancellation() }
    guard additional <= limits.tokenBytes, count <= limits.tokenBytes - additional else {
      throw error(.limitExceeded, "Token exceeds the configured limit")
    }
  }

  func error(_ kind: PDFError.Kind, _ message: String) -> PDFError {
    PDFError(kind, message, offset: cursor.offset)
  }

  static func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}
