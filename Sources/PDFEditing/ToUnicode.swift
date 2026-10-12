import Foundation
import PDFCore

/// P14-024/P16 tail: a simple-font ToUnicode CMap. When a font carries one,
/// decoding comes from the CMap (bfchar/bfrange) instead of the base encoding
/// or Differences, which is what many Type 3 and subset fonts rely on.
struct ToUnicodeCMap: Equatable {
  private var map: [UInt8: String] = [:]

  var isEmpty: Bool { map.isEmpty }

  init?(stream: PDFStream, limits: PDFLimits = PDFLimits()) {
    guard let decoded = try? PDFFilters.decoded(stream, limits: limits) else { return nil }
    self.init(bytes: [UInt8](decoded), limits: limits)
  }

  init?(bytes: [UInt8], limits: PDFLimits = PDFLimits()) {
    let text = String(decoding: bytes, as: UTF8.self)
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    var index = 0
    var entries = 0
    while index < tokens.count {
      let token = tokens[index]
      if token == "beginbfchar" {
        index += 1
        while index + 1 < tokens.count, tokens[index] != "endbfchar" {
          guard let code = Self.hexByte(tokens[index]),
            let destination = Self.hexString(tokens[index + 1])
          else { break }
          map[code] = destination
          entries += 1
          index += 2
          if entries >= 65_536 { return }
        }
        continue
      }
      if token == "beginbfrange" {
        index += 1
        while index < tokens.count, tokens[index] != "endbfrange" {
          guard let low = Self.hexByte(tokens[index]), let high = Self.hexByte(tokens[index + 1])
          else { break }
          let destinationToken = tokens[index + 2]
          if destinationToken.hasPrefix("[") {
            // Array form: one destination per code.
            var cursor = index + 2
            var destinationIndex = 0
            var destinations: [String] = []
            while cursor < tokens.count, !tokens[cursor].hasSuffix("]") {
              if let destination = Self.hexString(tokens[cursor]) { destinations.append(destination) }
              cursor += 1
              destinationIndex += 1
            }
            if cursor < tokens.count, let destination = Self.hexString(tokens[cursor]) {
              destinations.append(destination)
            }
            for (offset, destination) in destinations.enumerated() {
              let code = Int(low) + offset
              if code <= Int(high), code <= 255 { map[UInt8(code)] = destination }
            }
            index = cursor + 1
            entries += destinations.count
            continue
          }
          guard let destination = Self.hexString(destinationToken) else { break }
          let base = Array(destination.utf16)
          for code in Int(low)...Int(high) where code <= 255 {
            let offset = code - Int(low)
            var units = base
            if let last = units.last {
              units[units.count - 1] = last &+ UInt16(offset & 0xFF)
            }
            map[UInt8(code)] = String(decoding: units, as: UTF16.self)
          }
          entries += Int(high) - Int(low) + 1
          index += 3
          if entries >= 65_536 { return }
        }
        continue
      }
      index += 1
    }
  }

  /// Single-byte decoding (the simple-font profile).
  func decode(_ code: UInt8) -> String? { map[code] }

  /// Reverse lookup for reflow: the code that decodes to `text`.
  func code(for text: String) -> UInt8? {
    for (code, mapped) in map where mapped == text { return code }
    return nil
  }

  /// `<0041>` -> 0x41; multi-byte sources keep their last byte in this
  /// single-byte profile.
  static func hexByte(_ token: Substring) -> UInt8? {
    guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
    let hex = token.dropFirst().dropLast()
    guard !hex.isEmpty, hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(value)
      index = next
    }
    return bytes.last
  }

  /// `<00410042>` -> UTF-16BE "AB"; odd lengths fall back to Latin-1 bytes.
  static func hexString(_ token: Substring) -> String? {
    guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
    let hex = token.dropFirst().dropLast()
    guard !hex.isEmpty, hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let value = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(value)
      index = next
    }
    if bytes.count % 2 == 0 {
      var units: [UInt16] = []
      var cursor = 0
      while cursor + 1 < bytes.count {
        units.append(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
        cursor += 2
      }
      return String(decoding: units, as: UTF16.self)
    }
    return String(bytes: bytes, encoding: .isoLatin1)
  }
}
