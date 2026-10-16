import Foundation
import PDFCore

/// P14-006–P14-010/P14-017: a codespace-aware ToUnicode CMap for composite
/// fonts. Codes are 1–4 bytes; destinations may be multi-character strings
/// (ligatures).
struct MultiByteToUnicodeCMap {
  struct Codespace {
    let low: Int
    let high: Int
    let byteLength: Int
  }

  private var codespaces: [Codespace] = []
  private var map: [Int: String] = [:]

  var isEmpty: Bool { map.isEmpty && codespaces.isEmpty }

  init?(stream: PDFStream, limits: PDFLimits = PDFLimits()) {
    guard let decoded = try? PDFFilters.decoded(stream, limits: limits) else { return nil }
    self.init(bytes: [UInt8](decoded), limits: limits)
  }

  init?(bytes: [UInt8], limits: PDFLimits = PDFLimits()) {
    let text = String(decoding: bytes, as: UTF8.self)
    // CMaps commonly omit whitespace between hex strings and array brackets.
    let clean = text.replacingOccurrences(of: "%[^\\r\\n]*", with: "", options: .regularExpression)
    let expression = try? NSRegularExpression(pattern: "<[0-9A-Fa-f\\s]*>|\\[|\\]|[^\\s<>\\[\\]]+")
    let tokens: [Substring] = expression?.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
      .compactMap { Range($0.range, in: clean).map { clean[$0] } } ?? []
    var index = 0
    var entries = 0
    while index < tokens.count, entries < 65_536 {
      switch tokens[index] {
      case "begincodespacerange":
        index += 1
        while index + 1 < tokens.count, tokens[index] != "endcodespacerange" {
          guard let low = Self.hexValue(tokens[index]),
            let high = Self.hexValue(tokens[index + 1])
          else { break }
          codespaces.append(
            Codespace(low: low.value, high: high.value, byteLength: low.byteLength))
          index += 2
        }
      case "beginbfchar":
        index += 1
        while index + 1 < tokens.count, tokens[index] != "endbfchar" {
          guard let code = Self.hexValue(tokens[index]),
            let destination = Self.hexString(tokens[index + 1])
          else { break }
          map[code.value] = destination
          entries += 1
          index += 2
        }
      case "beginbfrange":
        index += 1
        while index + 2 < tokens.count, tokens[index] != "endbfrange" {
          guard let low = Self.hexValue(tokens[index]),
            let high = Self.hexValue(tokens[index + 1])
          else { break }
          guard high.value >= low.value, high.value - low.value < 65_536 - entries else { return nil }
          if tokens[index + 2] == "[" {
            index += 3
            for code in low.value...high.value {
              guard index < tokens.count, let destination = Self.hexString(tokens[index]) else { return nil }
              map[code] = destination; entries += 1; index += 1
            }
            guard index < tokens.count, tokens[index] == "]" else { return nil }
            index += 1
          } else if case .some(let token) = tokens[safe: index + 2], token.hasPrefix("<") {
            guard let startScalar = Self.firstScalar(token) else { break }
            for (offset, value) in (low.value...max(low.value, high.value)).enumerated() {
              if let scalar = UnicodeScalar(startScalar + UInt32(offset)) {
                map[value] = String(Character(scalar))
              }
              entries += 1
            }
            index += 3
          } else if let start = Int(tokens[safe: index + 2] ?? "") {
            for (offset, value) in (low.value...max(low.value, high.value)).enumerated() {
              map[value] = String(UnicodeScalar(UInt8(min(255, start + offset))))
              entries += 1
            }
            index += 3
          } else {
            break
          }
        }
      default:
        index += 1
      }
    }
  }

  /// The byte length of the code starting at `bytes[offset]`, from the
  /// declared codespaces (defaulting to 2 for identity CMaps).
  func codeLength(in bytes: [UInt8], offset: Int) -> Int {
    for codespace in codespaces where codespace.byteLength >= 1 {
      var value = 0
      guard offset + codespace.byteLength <= bytes.count else { continue }
      for index in 0..<codespace.byteLength { value = (value << 8) | Int(bytes[offset + index]) }
      if value >= codespace.low, value <= codespace.high { return codespace.byteLength }
    }
    return codespaces.isEmpty ? 2 : 1
  }

  func unicode(for code: Int) -> String? { map[code] }

  var identityMappings: [Int: String]? {
    guard codespaces.allSatisfy({ $0.byteLength == 2 }) else { return nil }
    return map.filter { (0...65_535).contains($0.key) }
  }

  static func hexValue(_ token: Substring) -> (value: Int, byteLength: Int)? {
    guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
    let hex = token.dropFirst().dropLast()
    guard !hex.isEmpty, hex.count <= 8 else { return nil }
    var value = 0
    for character in hex {
      guard let digit = character.hexDigitValue else { return nil }
      value = (value << 4) | digit
    }
    return (value, hex.count / 2)
  }

  /// The first Unicode scalar of a `<...>` destination (for range increment).
  static func firstScalar(_ token: Substring) -> UInt32? {
    guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
    let hex = token.dropFirst().dropLast()
    guard hex.count >= 4 else { return nil }
    let end = hex.index(hex.startIndex, offsetBy: 4)
    return UInt32(hex[hex.startIndex..<end], radix: 16)
  }

  static func hexString(_ token: Substring) -> String? {
    guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
    let hex = token.dropFirst().dropLast()
    guard hex.count % 4 == 0 else { return nil }
    var result = ""
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 4)
      guard let value = UInt32(hex[index..<next], radix: 16) else { return nil }
      result.unicodeScalars.append(UnicodeScalar(value) ?? "\u{FFFD}")
      index = next
    }
    return result
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// P14-002–P14-019: composite (Type0) font facts: descendant CID font,
/// encoding CMap, CIDToGIDMap, CID widths, vertical metrics, embedding, subset
/// prefixes, and a codespace-aware ToUnicode decoder with an explicit
/// missing-mapping policy (never a silent wrong character).
public struct CompositeFont: Sendable {
  var identityMappings: [Int: String]? {
    guard encodingName == "Identity-H", !hasVerticalMetrics else { return nil }
    return cmap?.identityMappings
  }
  public enum MissingMappingPolicy: String, Sendable, Equatable {
    /// Decoding fails for unmapped codes (default).
    case fail
    /// Substitute U+FFFD, flagged in the result.
    case replacementCharacter
  }

  public struct Glyph: Sendable, Equatable {
    public let code: Int
    public let byteLength: Int
    public let cid: Int?
    /// nil when the code has no Unicode mapping.
    public let unicode: String?
    public let width: Double?
  }

  public struct DecodeResult: Sendable, Equatable {
    public let glyphs: [Glyph]
    public let unmappedCount: Int
    public let text: String

    public var hasUnmappedCodes: Bool { unmappedCount > 0 }
  }

  public enum DecodeError: Error, Equatable {
    case missingUnicodeMapping(code: Int)
    case malformedCodes
  }

  public let baseFont: String
  public let isSubset: Bool
  public let encodingName: String
  public let cidToGIDMapIdentity: Bool
  public let hasCIDToGIDMap: Bool
  public let defaultWidth: Double
  public let hasVerticalMetrics: Bool
  public let isEmbedded: Bool
  public let hasUnicodeCMap: Bool
  public let fontObjectID: PDFObjectID?
  let cmap: MultiByteToUnicodeCMap?

  /// Parse a Type0 font dictionary. Returns nil for non-composite fonts.
  public static func parse(
    _ dictionary: [PDFName: PDFValue], in graph: PDFGraph, objectID: PDFObjectID? = nil
  ) -> CompositeFont? {
    guard dictionary[PDFName("Subtype")] == .name(PDFName("Type0")) else { return nil }
    var baseFont = ""
    if case .name(let name)? = dictionary[PDFName("BaseFont")] {
      baseFont = String(decoding: name.bytes, as: UTF8.self)
    }
    var encodingName = "Unknown"
    switch dictionary[PDFName("Encoding")] {
    case .name(let name)?:
      encodingName = String(decoding: name.bytes, as: UTF8.self)
    case .reference?, .stream?:
      encodingName = "Embedded CMap"
    default:
      break
    }
    var descendant: [PDFName: PDFValue] = [:]
    if case .array(let fonts)? = FontValue.resolve(dictionary[PDFName("DescendantFonts")], in: graph),
      let first = fonts.first,
      case .dictionary(let parsed)? = FontValue.resolve(first, in: graph) { descendant = parsed }
    var cidToGIDIdentity = false
    var hasCIDToGID = false
    if case .name(let map)? = descendant[PDFName("CIDToGIDMap")] {
      hasCIDToGID = true
      cidToGIDIdentity = String(decoding: map.bytes, as: UTF8.self) == "Identity"
    } else if descendant[PDFName("CIDToGIDMap")] != nil {
      hasCIDToGID = true
    }
    let defaultWidth: Double
    if case .integer(let width)? = FontValue.resolve(descendant[PDFName("DW")], in: graph) {
      defaultWidth = Double(width)
    } else if case .real(let width)? = FontValue.resolve(descendant[PDFName("DW")], in: graph) {
      defaultWidth = width
    } else {
      defaultWidth = 1_000
    }
    let hasVertical = descendant[PDFName("W2")] != nil || descendant[PDFName("DW2")] != nil
    var isEmbedded = false
    if case .reference(let descriptorID)? = descendant[PDFName("FontDescriptor")],
      case .dictionary(let descriptor)? = graph.objects[descriptorID]
    {
      isEmbedded =
        descriptor[PDFName("FontFile")] != nil || descriptor[PDFName("FontFile2")] != nil
        || descriptor[PDFName("FontFile3")] != nil
    }
    let cmap: MultiByteToUnicodeCMap?
    if case .reference(let id)? = dictionary[PDFName("ToUnicode")],
      case .stream(let stream)? = graph.objects[id]
    {
      cmap = MultiByteToUnicodeCMap(stream: stream)
    } else {
      cmap = nil
    }
    return CompositeFont(
      baseFont: baseFont, isSubset: isSubsetName(baseFont), encodingName: encodingName,
      cidToGIDMapIdentity: cidToGIDIdentity, hasCIDToGIDMap: hasCIDToGID,
      defaultWidth: defaultWidth, hasVerticalMetrics: hasVertical, isEmbedded: isEmbedded,
      hasUnicodeCMap: cmap?.isEmpty == false, fontObjectID: objectID, cmap: cmap)
  }

  /// P14-020: a subset prefix is an identity hint, never the original name.
  static func isSubsetName(_ name: String) -> Bool {
    let parts = name.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 6 else { return false }
    return parts[0].allSatisfy { $0.isUppercase }
  }

  /// Decode a string of codes into glyphs (P14-008/P14-010/P14-019/P14-028).
  public func decode(
    _ bytes: [UInt8], policy: MissingMappingPolicy = .fail,
    widths: [Int: Double]? = nil
  ) throws -> DecodeResult {
    var glyphs: [Glyph] = []
    var unmapped = 0
    var text = ""
    var offset = 0
    while offset < bytes.count {
      let length = cmap?.codeLength(in: bytes, offset: offset) ?? 2
      guard length >= 1, offset + length <= bytes.count else {
        throw DecodeError.malformedCodes
      }
      var code = 0
      for index in 0..<length { code = (code << 8) | Int(bytes[offset + index]) }
      let unicode = cmap?.unicode(for: code)
      if unicode == nil { unmapped += 1 }
      if unicode == nil, policy == .fail {
        throw DecodeError.missingUnicodeMapping(code: code)
      }
      let resolved = unicode ?? (policy == .replacementCharacter ? "\u{FFFD}" : nil)
      if let resolved { text += resolved }
      glyphs.append(
        Glyph(
          code: code, byteLength: length, cid: encodingName == "Identity-H" ? code : nil,
          unicode: resolved, width: widths?[code] ?? defaultWidth))
      offset += length
    }
    return DecodeResult(glyphs: glyphs, unmappedCount: unmapped, text: text)
  }

  public func coverage() -> String {
    "\(baseFont)\(isSubset ? " (subset)" : "") · \(encodingName) · "
      + "\(hasUnicodeCMap ? "ToUnicode" : "no ToUnicode") · "
      + "\(isEmbedded ? "embedded" : "not embedded")"
      + (hasVerticalMetrics ? " · vertical metrics" : "")
      + (hasCIDToGIDMap ? " · CIDToGIDMap" : "")
  }
}

/// P14-024/P14-029: a bounded font-mapping cache owned by a document session.
public final class FontMappingCache: @unchecked Sendable {
  public struct Entry: Sendable, Equatable {
    public let fontObjectID: PDFObjectID
    public let text: String
  }

  public let owner: String
  public let capacity: Int
  private var storage: [PDFObjectID: String] = [:]
  private var order: [PDFObjectID] = []
  public private(set) var hits = 0
  public private(set) var misses = 0

  public init(owner: String, capacity: Int = 64) {
    self.owner = owner
    self.capacity = max(1, capacity)
  }

  public var count: Int { storage.count }

  public func text(for fontObjectID: PDFObjectID) -> String? {
    if let text = storage[fontObjectID] {
      hits += 1
      order.removeAll { $0 == fontObjectID }
      order.append(fontObjectID)
      return text
    }
    misses += 1
    return nil
  }

  public func store(_ text: String, for fontObjectID: PDFObjectID) {
    storage[fontObjectID] = text
    order.removeAll { $0 == fontObjectID }
    order.append(fontObjectID)
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      storage[oldest] = nil
    }
  }

  public func clear() {
    storage.removeAll()
    order.removeAll()
  }
}
