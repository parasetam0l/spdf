import Foundation
import PDFCore

/// FRM-03: portable form-value exchange in FDF and XFDF. Both formats carry
/// field names and values; the document's own field inventory decides whether
/// a value is text, a choice export value, or a button state.
public enum FormDataExchange {
  public enum Format: String, Sendable, CaseIterable {
    case fdf
    case xfdf

    public var title: String { self == .fdf ? "FDF" : "XFDF" }
  }

  public static func export(_ values: [FormFieldValue], format: Format) -> Data {
    switch format {
    case .xfdf:
      return Data(exportXFDF(values).utf8)
    case .fdf:
      return Data(exportFDF(values).utf8)
    }
  }

  /// Parsed (name, value) pairs. A nil value means the field is off/empty.
  public static func parse(_ data: Data, format: Format) throws -> [(name: String, value: String?)] {
    switch format {
    case .xfdf:
      return try parseXFDF(data)
    case .fdf:
      return try parseFDF(data)
    }
  }

  /// Map raw name/value pairs onto the document's fields, then reuse the
  /// existing fill-command policy. Returns skipped names for missing or
  /// read-only fields.
  public static func commands(
    forRawValues values: [(name: String, value: String?)],
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> (commands: [any PDFEditCommand], skipped: [String], ambiguous: [String]) {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    var mapped: [FormFieldValue] = []
    var missing: [String] = []
    for pair in values {
      guard let field = fields.first(where: { $0.name == pair.name }) else {
        missing.append(pair.name)
        continue
      }
      switch field.kind {
      case .text:
        mapped.append(
          FormFieldValue(name: pair.name, kind: "text", value: pair.value ?? ""))
      case .choice:
        mapped.append(
          FormFieldValue(name: pair.name, kind: "choice", value: pair.value ?? ""))
      case .button:
        mapped.append(
          FormFieldValue(
            name: pair.name, kind: "button",
            buttonState: (pair.value?.isEmpty ?? true) ? "Off" : pair.value))
      default:
        continue
      }
    }
    let result = try FormValues.commands(for: mapped, in: graph, pageIDs: pageIDs)
    return (result.commands, missing + result.skipped, result.ambiguous)
  }

  // MARK: - XFDF

  private static func exportXFDF(_ values: [FormFieldValue]) -> String {
    var xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <xfdf xmlns="http://ns.adobe.com/xfdf/">
      <fields>

      """
    for value in values {
      let raw: String
      switch value.kind {
      case "button": raw = value.buttonState ?? "Off"
      default: raw = value.value ?? ""
      }
      xml += "<field name=\"\(escapeXML(value.name))\"><value>\(escapeXML(raw))</value></field>\n"
    }
    xml += "</fields>\n</xfdf>\n"
    return xml
  }

  private static func parseXFDF(_ data: Data) throws -> [(name: String, value: String?)] {
    final class Delegate: NSObject, XMLParserDelegate {
      var fields: [(String, String?)] = []
      var currentName: String?
      var value = ""
      var insideValue = false
      var sawRoot = false
      var failure: String?

      func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
      ) {
        if elementName == "xfdf" { sawRoot = true }
        if elementName == "field" {
          currentName = attributes["name"]
          value = ""
        }
        if elementName == "value" {
          insideValue = true
          value = ""
        }
      }

      func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideValue { value += string }
      }

      func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
      ) {
        if elementName == "value" {
          if let name = currentName { fields.append((name, value)) }
          insideValue = false
        }
        if elementName == "field" { currentName = nil }
      }

      func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        failure = error.localizedDescription
      }
    }
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.failure == nil, delegate.sawRoot else {
      throw PDFError(
        .malformed,
        "The XFDF file could not be read: \(delegate.failure ?? "missing xfdf root")")
    }
    guard !delegate.fields.isEmpty else {
      throw PDFError(.malformed, "The XFDF file contains no field values")
    }
    return delegate.fields
  }

  private static func escapeXML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  // MARK: - FDF

  private static func exportFDF(_ values: [FormFieldValue]) -> String {
    var body = ""
    for value in values {
      let name = pdfTextString(value.name)
      switch value.kind {
      case "button":
        let state = value.buttonState ?? "Off"
        let token = state == "Off" ? "/Off" : "/\(escapeName(state))"
        body += "<< /T \(name) /V \(token) >>\n"
      default:
        body += "<< /T \(name) /V \(pdfTextString(value.value ?? "")) >>\n"
      }
    }
    return """
      %FDF-1.2
      1 0 obj
      << /FDF << /Fields [
      \(body)] >> >>
      endobj
      trailer
      << /Root 1 0 R >>
      %%EOF

      """
  }

  private static func pdfTextString(_ text: String) -> String {
    if text.unicodeScalars.allSatisfy({ $0.value < 128 }) {
      let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)")
      return "(\(escaped))"
    }
    var hex = "FEFF"
    for unit in text.utf16 {
      hex += String(format: "%04X", unit)
    }
    return "<\(hex)>"
  }

  private static func escapeName(_ name: String) -> String {
    var result = ""
    for byte in name.utf8 {
      if (33...126).contains(byte), byte != 35, byte != 40, byte != 41, byte != 47, byte != 60,
        byte != 62, byte != 91, byte != 93, byte != 123, byte != 125, byte != 37
      {
        result.append(Character(UnicodeScalar(byte)))
      } else {
        result += String(format: "#%02X", byte)
      }
    }
    return result
  }

  private enum FDFValue {
    case name(String)
    case string(String)
    case array([FDFValue])
    case dictionary([String: FDFValue])
    case other
  }

  private struct FDFScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func skipTrivia() {
      while index < bytes.count {
        let byte = bytes[index]
        if byte == 0x25 {  // %
          while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
            index += 1
          }
          continue
        }
        if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
          || byte == 0x00
        {
          index += 1
          continue
        }
        break
      }
    }

    mutating func value() throws -> FDFValue {
      skipTrivia()
      guard index < bytes.count else { throw PDFError(.malformed, "Unexpected end of FDF") }
      switch bytes[index] {
      case 0x2F:  // /
        index += 1
        var name: [UInt8] = []
        while index < bytes.count, !isDelimiter(bytes[index]) {
          if bytes[index] == 0x23, index + 2 < bytes.count,
            let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2])
          {
            name.append(high << 4 | low)
            index += 3
          } else {
            name.append(bytes[index])
            index += 1
          }
        }
        return .name(String(decoding: name, as: UTF8.self))
      case 0x28:  // (
        return .string(try literalString())
      case 0x3C:  // <
        if index + 1 < bytes.count, bytes[index + 1] == 0x3C {
          return .dictionary(try dictionary())
        }
        return .string(try hexString())
      case 0x5B:  // [
        return .array(try array())
      default:
        while index < bytes.count, !isDelimiter(bytes[index]) { index += 1 }
        return .other
      }
    }

    private mutating func dictionary() throws -> [String: FDFValue] {
      index += 2
      var result: [String: FDFValue] = [:]
      while true {
        skipTrivia()
        guard index < bytes.count else { throw PDFError(.malformed, "Unterminated FDF dictionary") }
        if bytes[index] == 0x3E, index + 1 < bytes.count, bytes[index + 1] == 0x3E {
          index += 2
          return result
        }
        guard bytes[index] == 0x2F else {
          _ = try value()
          continue
        }
        guard case .name(let key) = try value() else { continue }
        result[key] = try value()
      }
    }

    private mutating func array() throws -> [FDFValue] {
      index += 1
      var result: [FDFValue] = []
      while true {
        skipTrivia()
        guard index < bytes.count else { throw PDFError(.malformed, "Unterminated FDF array") }
        if bytes[index] == 0x5D {
          index += 1
          return result
        }
        result.append(try value())
      }
    }

    private mutating func literalString() throws -> String {
      index += 1
      var depth = 1
      var result: [UInt8] = []
      while index < bytes.count, depth > 0 {
        let byte = bytes[index]
        index += 1
        if byte == 0x5C {  // backslash
          guard index < bytes.count else { break }
          let next = bytes[index]
          index += 1
          switch next {
          case 0x6E: result.append(0x0A)
          case 0x72: result.append(0x0D)
          case 0x74: result.append(0x09)
          case 0x62: result.append(0x08)
          case 0x66: result.append(0x0C)
          case 0x28, 0x29, 0x5C: result.append(next)
          case 0x30...0x37:
            var value = Int(next - 0x30)
            for _ in 0..<2 {
              guard index < bytes.count, (0x30...0x37).contains(bytes[index]) else { break }
              value = value * 8 + Int(bytes[index] - 0x30)
              index += 1
            }
            result.append(UInt8(value & 0xFF))
          default:
            result.append(next)
          }
          continue
        }
        if byte == 0x28 {
          depth += 1
          result.append(byte)
          continue
        }
        if byte == 0x29 {
          depth -= 1
          if depth == 0 { break }
          result.append(byte)
          continue
        }
        result.append(byte)
      }
      return decodePDFString(result)
    }

    private mutating func hexString() throws -> String {
      index += 1
      var digits: [UInt8] = []
      while index < bytes.count, bytes[index] != 0x3E {
        if !isWhitespace(bytes[index]) { digits.append(bytes[index]) }
        index += 1
      }
      guard index < bytes.count else { throw PDFError(.malformed, "Unterminated FDF hex string") }
      index += 1
      if digits.count % 2 == 1 { digits.append(0x30) }
      var bytes: [UInt8] = []
      var cursor = 0
      while cursor + 1 < digits.count {
        guard let high = hex(digits[cursor]), let low = hex(digits[cursor + 1]) else {
          throw PDFError(.malformed, "Invalid FDF hex string")
        }
        bytes.append(high << 4 | low)
        cursor += 2
      }
      return decodePDFString(bytes)
    }

    private func isDelimiter(_ byte: UInt8) -> Bool {
      isWhitespace(byte) || [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25]
        .contains(byte)
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C || byte == 0
    }

    private func hex(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 0x30...0x39: return byte - 0x30
      case 0x41...0x46: return byte - 0x41 + 10
      case 0x61...0x66: return byte - 0x61 + 10
      default: return nil
      }
    }

    private func decodePDFString(_ bytes: [UInt8]) -> String {
      if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
        var units: [UInt16] = []
        var cursor = 2
        while cursor + 1 < bytes.count {
          units.append(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
          cursor += 2
        }
        return String(decoding: units, as: UTF16.self)
      }
      return String(decoding: bytes, as: UTF8.self)
    }
  }

  private static func parseFDF(_ data: Data) throws -> [(name: String, value: String?)] {
    var scanner = FDFScanner(bytes: Array(data))
    // Find the first dictionary after the %FDF header.
    while scanner.index < scanner.bytes.count {
      scanner.skipTrivia()
      if scanner.index + 1 < scanner.bytes.count,
        scanner.bytes[scanner.index] == 0x3C, scanner.bytes[scanner.index + 1] == 0x3C
      {
        break
      }
      scanner.index += 1
    }
    guard let root = try? scanner.value(), case .dictionary(let rootDictionary) = root,
      case .dictionary(let fdf)? = rootDictionary["FDF"],
      case .array(let fields)? = fdf["Fields"]
    else {
      throw PDFError(.malformed, "The FDF file has no /Fields array")
    }
    var values: [(String, String?)] = []
    for field in fields {
      guard case .dictionary(let dictionary) = field else { continue }
      guard case .string(let name)? = dictionary["T"] else { continue }
      switch dictionary["V"] {
      case .string(let value)?:
        values.append((name, value))
      case .name(let value)?:
        values.append((name, value == "Off" ? nil : value))
      case nil:
        values.append((name, nil))
      default:
        continue
      }
    }
    guard !values.isEmpty else {
      throw PDFError(.malformed, "The FDF file contains no field values")
    }
    return values
  }
}
