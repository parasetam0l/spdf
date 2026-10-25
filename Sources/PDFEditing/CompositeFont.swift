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
    // CMaps commonly omit whitespace between hex strings and array brackets;
    // the shared lexer drops comments and returns bounded tokens.
    let tokens: [String] = CMapLexing.tokens(in: bytes)
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

  /// FNT-03: every code-to-Unicode entry, for callers (such as the inline
  /// editor's font index) that need the reverse text-to-code direction and
  /// compute each code's byte length from the font's encoding.
  var allMappings: [Int: String] { map }

  var identityMappings: [Int: String]? {
    guard codespaces.allSatisfy({ $0.byteLength == 2 }) else { return nil }
    return map.filter { (0...65_535).contains($0.key) }
  }

  static func hexValue(_ token: String) -> (value: Int, byteLength: Int)? {
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
  static func firstScalar(_ token: String) -> UInt32? {
    guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
    let hex = token.dropFirst().dropLast()
    guard hex.count >= 4 else { return nil }
    let end = hex.index(hex.startIndex, offsetBy: 4)
    return UInt32(hex[hex.startIndex..<end], radix: 16)
  }

  static func hexString(_ token: String) -> String? {
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


/// FNT-03: how a composite font maps byte codes to CIDs.
public enum CompositeFontEncodingKind: Sendable, Equatable {
  /// Horizontal Identity-H: the code is the CID (2-byte codes).
  case identityHorizontal
  /// Vertical Identity-V: the code is the CID with vertical metrics (2-byte).
  case identityVertical
  /// An embedded /Encoding CMap stream; its own codespaces and cid
  /// ranges/char entries map codes to CIDs.
  case embeddedCMap(name: String?)
  /// A named non-Identity CMap this profile only records (no reading claim).
  case unsupported

  public var isIdentity: Bool {
    switch self {
    case .identityHorizontal, .identityVertical: return true
    default: return false
    }
  }

  public var isVertical: Bool {
    if case .identityVertical = self { return true }
    return false
  }

  public var displayName: String {
    switch self {
    case .identityHorizontal: return "Identity-H"
    case .identityVertical: return "Identity-V"
    case .embeddedCMap(let name): return name ?? "Embedded CMap"
    case .unsupported: return "Unsupported CMap"
    }
  }
}

/// FNT-03: the writing mode a composite font declares.
public enum CompositeFontWritingMode: String, Sendable, Equatable {
  case horizontal
  case vertical
}

/// FNT-03: the embedded font program form behind a composite font.
/// A CIDFontType2 descendant carries TrueType outlines; a CIDFontType0
/// descendant carries CFF outlines as an OpenType (OTTO) wrapper, a bare
/// Type1C program, or a CID-keyed CIDFontType0C program.
public enum CompositeFontProgram: String, Sendable, Equatable {
  case trueType = "TrueType"
  case openTypeCFF = "OpenType CFF"
  case type1C = "Type1C"
  case cidFontType0C = "CIDFontType0C"
  case unknown = "unknown"

  public var hasCFFOutlines: Bool {
    switch self {
    case .openTypeCFF, .type1C, .cidFontType0C: return true
    default: return false
    }
  }

  public var isCIDKeyedCFF: Bool { self == .cidFontType0C }
}

/// FNT-03: one CID's vertical metrics from /W2 triplets or the /DW2 default:
/// the vertical advance plus the position vector used by vertical writing.
public struct CompositeFontVerticalAdvance: Sendable, Equatable {
  public let advance: Double
  public let positionX: Double
  public let positionY: Double

  public init(advance: Double = 880, positionX: Double = 0, positionY: Double = -1000) {
    self.advance = advance
    self.positionX = positionX
    self.positionY = positionY
  }

  /// The PDF default DW2 vector.
  public static let standard = CompositeFontVerticalAdvance()

  /// Horizontal fonts report no vertical advance rather than an invented one.
  public static let zero = CompositeFontVerticalAdvance(advance: 0, positionX: 0, positionY: 0)
}

/// P14-002–P14-019 + FNT-03: composite (Type0) font facts: the descendant CID
/// font kind, the encoding (named Identity-H/V or an embedded CMap stream with
/// its own codespace and CID mapping), CID-to-GID mapping for CIDFontType2,
/// horizontal /W and vertical /W2 widths, embedding form (TrueType,
/// OpenType-CFF, Type1C, CIDFontType0C), subset prefixes, and a
/// codespace-aware ToUnicode decoder with an explicit missing-mapping policy
/// (never a silent wrong character).
public struct CompositeFont: Sendable {
  var identityMappings: [Int: String]? {
    guard encodingKind == .identityHorizontal, !hasVerticalMetrics else { return nil }
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
    /// Vertical advance when the font is vertical (zero otherwise).
    public let verticalAdvance: CompositeFontVerticalAdvance

    public init(
      code: Int, byteLength: Int, cid: Int?, unicode: String?, width: Double?,
      verticalAdvance: CompositeFontVerticalAdvance = .zero
    ) {
      self.code = code
      self.byteLength = byteLength
      self.cid = cid
      self.unicode = unicode
      self.width = width
      self.verticalAdvance = verticalAdvance
    }
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
  /// The /Encoding name as written, or "Embedded CMap" for a stream.
  public let encodingName: String
  /// FNT-03: the parsed encoding form.
  public let encodingKind: CompositeFontEncodingKind
  public let writingMode: CompositeFontWritingMode
  public let cidToGIDMapIdentity: Bool
  public let hasCIDToGIDMap: Bool
  public let defaultWidth: Double
  public let hasVerticalMetrics: Bool
  public let isEmbedded: Bool
  public let hasUnicodeCMap: Bool
  public let fontObjectID: PDFObjectID?
  /// FNT-03: /Subtype of the descendant font ("CIDFontType2"/"CIDFontType0").
  public let descendantSubtype: String
  /// FNT-03: the embedded program form classified from the descriptor.
  public let program: CompositeFontProgram
  /// FNT-03: the FontFile3 stream's declared /Subtype, when present.
  public let fontFile3Subtype: String?
  /// FNT-03: /W widths keyed by CID; CIDs without an entry use defaultWidth.
  public let widths: [Int: Double]
  /// FNT-03: /W2 vertical advances keyed by CID.
  public let verticalWidths: [Int: CompositeFontVerticalAdvance]
  public let defaultVerticalAdvance: CompositeFontVerticalAdvance
  /// FNT-03: /CMapName of an embedded encoding CMap, when present.
  public let cmapName: String?
  let cmap: MultiByteToUnicodeCMap?
  let embeddedCMap: EmbeddedCIDCMap?
  let cidToGIDTable: CIDToGIDTable?

  /// Parse a Type0 font dictionary. Returns nil for non-composite fonts.
  public static func parse(
    _ dictionary: [PDFName: PDFValue], in graph: PDFGraph, objectID: PDFObjectID? = nil
  ) -> CompositeFont? {
    guard dictionary[PDFName("Subtype")] == .name(PDFName("Type0")) else { return nil }
    var baseFont = ""
    if case .name(let name)? = dictionary[PDFName("BaseFont")] {
      baseFont = String(decoding: name.bytes, as: UTF8.self)
    }
    // FNT-03: named encodings versus an embedded CMap stream.
    var encodingName = "Unknown"
    var encodingKind = CompositeFontEncodingKind.unsupported
    var encodingStream: PDFStream?
    switch dictionary[PDFName("Encoding")] {
    case .name(let name)?:
      let value = String(decoding: name.bytes, as: UTF8.self)
      encodingName = value
      if value == "Identity-H" {
        encodingKind = .identityHorizontal
      } else if value == "Identity-V" {
        encodingKind = .identityVertical
      }
    case .reference(let id)?:
      encodingName = "Embedded CMap"
      if case .stream(let stream)? = graph.objects[id] { encodingStream = stream }
    case .stream(let stream)?:
      encodingName = "Embedded CMap"
      encodingStream = stream
    default:
      break
    }
    var embeddedCMap: EmbeddedCIDCMap?
    if let encodingStream, let parsed = EmbeddedCIDCMap(stream: encodingStream) {
      embeddedCMap = parsed
      encodingKind = .embeddedCMap(name: parsed.name)
    }
    let writingMode: CompositeFontWritingMode =
      encodingKind.isVertical || embeddedCMap?.writingMode == 1 ? .vertical : .horizontal
    var descendant: [PDFName: PDFValue] = [:]
    if case .array(let fonts)? = FontValue.resolve(dictionary[PDFName("DescendantFonts")], in: graph),
      let first = fonts.first,
      case .dictionary(let parsed)? = FontValue.resolve(first, in: graph) { descendant = parsed }
    let descendantSubtype = nameValue(descendant[PDFName("Subtype")]) ?? ""
    var cidToGIDTable: CIDToGIDTable?
    var cidToGIDIdentity = false
    var hasCIDToGID = false
    if case .name(let map)? = descendant[PDFName("CIDToGIDMap")] {
      hasCIDToGID = true
      cidToGIDIdentity = String(decoding: map.bytes, as: UTF8.self) == "Identity"
    } else if descendant[PDFName("CIDToGIDMap")] != nil {
      hasCIDToGID = true
      if case .reference(let id)? = FontValue.resolve(
        descendant[PDFName("CIDToGIDMap")], in: graph),
        case .stream(let stream)? = graph.objects[id]
      {
        cidToGIDTable = CIDToGIDTable(stream: stream)
      } else if case .stream(let stream)? = FontValue.resolve(
        descendant[PDFName("CIDToGIDMap")], in: graph)
      {
        cidToGIDTable = CIDToGIDTable(stream: stream)
      }
      // A present but unreadable map keeps hasCIDToGID true and makes
      // glyphID(forCID:) refuse rather than assume identity.
    }
    let defaultWidth = numberValue(descendant[PDFName("DW")]) ?? 1_000
    let hasVertical = descendant[PDFName("W2")] != nil || descendant[PDFName("DW2")] != nil
    var defaultVertical = CompositeFontVerticalAdvance.standard
    if case .array(let values)? = FontValue.resolve(descendant[PDFName("DW2")], in: graph) {
      let parsed = values.map { numberValue(FontValue.resolve($0, in: graph)) }
      if let advance = parsed.first ?? nil, advance.isFinite {
        defaultVertical = CompositeFontVerticalAdvance(
          advance: advance,
          positionX: parsed.count > 1 ? (parsed[1] ?? 0) : 0,
          positionY: parsed.count > 2 ? (parsed[2] ?? -1_000) : -1_000)
      }
    }
    var descriptor: [PDFName: PDFValue] = [:]
    if case .reference(let descriptorID)? = descendant[PDFName("FontDescriptor")],
      case .dictionary(let parsed)? = graph.objects[descriptorID]
    {
      descriptor = parsed
    }
    let isEmbedded = descriptor[PDFName("FontFile")] != nil
      || descriptor[PDFName("FontFile2")] != nil
      || descriptor[PDFName("FontFile3")] != nil
    let classified = classifyProgram(descriptor: descriptor, in: graph)
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
      encodingKind: encodingKind, writingMode: writingMode,
      cidToGIDMapIdentity: cidToGIDIdentity, hasCIDToGIDMap: hasCIDToGID,
      defaultWidth: defaultWidth, hasVerticalMetrics: hasVertical, isEmbedded: isEmbedded,
      hasUnicodeCMap: cmap?.isEmpty == false, fontObjectID: objectID,
      descendantSubtype: descendantSubtype, program: classified.kind,
      fontFile3Subtype: classified.subtype, widths: parseWidths(descendant[PDFName("W")], in: graph),
      verticalWidths: parseVerticalWidths(descendant[PDFName("W2")], in: graph),
      defaultVerticalAdvance: defaultVertical, cmapName: embeddedCMap?.name, cmap: cmap,
      embeddedCMap: embeddedCMap, cidToGIDTable: cidToGIDTable)
  }

  /// P14-020: a subset prefix is an identity hint, never the original name.
  static func isSubsetName(_ name: String) -> Bool {
    let parts = name.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 6 else { return false }
    return parts[0].allSatisfy { $0.isUppercase }
  }

  /// FNT-03: the byte length of the code at a given offset, using the
  /// encoding CMap's own codespace first and the ToUnicode codespace second.
  public func codeLength(in bytes: [UInt8], offset: Int) -> Int {
    if let embeddedCMap {
      return embeddedCMap.codeLength(in: bytes, offset: offset)
    }
    return cmap?.codeLength(in: bytes, offset: offset) ?? 2
  }

  /// FNT-03: true when this profile can resolve every code to a CID through a
  /// supported encoding (named Identity-H/V or an embedded CMap stream). An
  /// unrecognised named CMap keeps decoding through ToUnicode but stays
  /// non-editable: writing a code without its CID would be a guess.
  public var hasResolvedEncoding: Bool {
    switch encodingKind {
    case .identityHorizontal, .identityVertical, .embeddedCMap: return true
    case .unsupported: return false
    }
  }

  /// FNT-03: the encoded byte length for a code value (the inverse direction
  /// of codeLength, used when writing edited text back).
  public func codeByteLength(forCode code: Int) -> Int {
    if let embeddedCMap { return embeddedCMap.byteLength(forCode: code) }
    return 2
  }

  /// FNT-03: every code-to-Unicode entry the ToUnicode map carries. The
  /// encoding's codespace decides the byte length of each code.
  public var codeToUnicode: [Int: String] { cmap?.allMappings ?? [:] }

  /// FNT-03: the code value for a decoded byte sequence at an offset.
  public func code(in bytes: [UInt8], offset: Int = 0) -> (value: Int, length: Int)? {
    let length = codeLength(in: bytes, offset: offset)
    guard length >= 1, offset >= 0, offset + length <= bytes.count else { return nil }
    var value = 0
    for index in 0..<length { value = (value << 8) | Int(bytes[offset + index]) }
    return (value, length)
  }

  /// FNT-03: the CID a code selects. nil when this profile cannot resolve the
  /// encoding (for example an unimplemented named CMap).
  public func cid(forCode code: Int) -> Int? {
    switch encodingKind {
    case .identityHorizontal, .identityVertical: return code
    case .embeddedCMap: return embeddedCMap?.cid(for: code)
    case .unsupported: return nil
    }
  }

  /// FNT-03: the glyph ID a CID selects. An absent /CIDToGIDMap on a
  /// CIDFontType2 descendant means Identity (PDF Table 118); a CIDFontType0
  /// descendant selects glyphs through the CFF charset and has no map.
  public func glyphID(forCID cid: Int) -> Int? {
    if let cidToGIDTable { return cidToGIDTable.glyphID(forCID: cid) }
    if cidToGIDMapIdentity { return cid }
    if descendantSubtype == "CIDFontType2" { return cid }
    return nil
  }

  /// FNT-03: a CID's horizontal advance width (/W, falling back to /DW).
  public func width(forCID cid: Int) -> Double { widths[cid] ?? defaultWidth }

  /// FNT-03: a CID's vertical advance (/W2, falling back to /DW2).
  public func verticalAdvance(forCID cid: Int) -> CompositeFontVerticalAdvance {
    guard writingMode == .vertical else { return .zero }
    return verticalWidths[cid] ?? defaultVerticalAdvance
  }

  /// Decode a string of codes into glyphs (P14-008/P14-010/P14-019/P14-028,
  /// extended by FNT-03 with embedded-CMap code lengths, CIDs, parsed /W
  /// widths and vertical advances).
  public func decode(
    _ bytes: [UInt8], policy: MissingMappingPolicy = .fail,
    widths: [Int: Double]? = nil
  ) throws -> DecodeResult {
    var glyphs: [Glyph] = []
    var unmapped = 0
    var text = ""
    var offset = 0
    while offset < bytes.count {
      let length = codeLength(in: bytes, offset: offset)
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
      let cid = cid(forCode: code)
      let width: Double
      if let override = widths?[code] {
        width = override
      } else if let cid, let parsed = self.widths[cid] {
        width = parsed
      } else {
        width = defaultWidth
      }
      glyphs.append(
        Glyph(
          code: code, byteLength: length, cid: cid, unicode: resolved, width: width,
          verticalAdvance: cid.map { verticalAdvance(forCID: $0) } ?? .zero))
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
      + (program == .unknown ? "" : " · \(program.rawValue)")
      + (writingMode == .vertical ? " · vertical" : "")
  }

  // MARK: - Parsing helpers

  static func nameValue(_ value: PDFValue?) -> String? {
    guard case .name(let name)? = value else { return nil }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  static func numberValue(_ value: PDFValue?) -> Double? {
    switch value {
    case .integer(let value): return Double(value)
    case .real(let value): return value
    default: return nil
    }
  }

  static func resolveArray(_ value: PDFValue?, in graph: PDFGraph, limit: Int = 65_536)
    -> [PDFValue]?
  {
    guard case .array(let entries)? = FontValue.resolve(value, in: graph),
      entries.count <= limit
    else { return nil }
    return entries
  }

  /// FNT-03: parse a /W array (CID ranges and per-CID width lists).
  static func parseWidths(_ value: PDFValue?, in graph: PDFGraph) -> [Int: Double] {
    guard let entries = resolveArray(value, in: graph), !entries.isEmpty else { return [:] }
    var result: [Int: Double] = [:]
    var cursor = 0
    while cursor < entries.count {
      guard case .integer(let firstRaw)? = FontValue.resolve(entries[cursor], in: graph),
        (0...65_535).contains(Int(firstRaw))
      else { break }
      let first = Int(firstRaw)
      cursor += 1
      guard cursor < entries.count else { break }
      let second = FontValue.resolve(entries[cursor], in: graph)
      if case .array(let values)? = second {
        guard values.count <= 65_536, first + values.count <= 65_536 else { return result }
        for (offset, entry) in values.enumerated() {
          if let width = numberValue(FontValue.resolve(entry, in: graph)),
            width.isFinite, width >= 0
          { result[first + offset] = width }
        }
        cursor += 1
      } else if case .integer(let lastRaw)? = second, Int(lastRaw) >= first,
        Int(lastRaw) <= 65_535, cursor + 1 < entries.count,
        let width = numberValue(FontValue.resolve(entries[cursor + 1], in: graph)),
        width.isFinite, width >= 0
      {
        for cid in first...Int(lastRaw) { result[cid] = width }
        cursor += 2
      } else {
        break
      }
    }
    return result
  }

  /// FNT-03: parse a /W2 array (CID ranges with [w1y vx vy] triplets).
  static func parseVerticalWidths(_ value: PDFValue?, in graph: PDFGraph)
    -> [Int: CompositeFontVerticalAdvance]
  {
    guard let entries = resolveArray(value, in: graph), !entries.isEmpty else { return [:] }
    var result: [Int: CompositeFontVerticalAdvance] = [:]
    var cursor = 0
    func triple(_ values: [PDFValue]) -> [CompositeFontVerticalAdvance] {
      var parsed: [CompositeFontVerticalAdvance] = []
      var index = 0
      while index + 2 < values.count + 1, index + 3 <= values.count {
        guard let advance = numberValue(FontValue.resolve(values[index], in: graph)),
          let positionX = numberValue(FontValue.resolve(values[index + 1], in: graph)),
          let positionY = numberValue(FontValue.resolve(values[index + 2], in: graph)),
          advance.isFinite, positionX.isFinite, positionY.isFinite
        else { break }
        parsed.append(
          CompositeFontVerticalAdvance(
            advance: advance, positionX: positionX, positionY: positionY))
        index += 3
      }
      return parsed
    }
    while cursor < entries.count {
      guard case .integer(let firstRaw)? = FontValue.resolve(entries[cursor], in: graph),
        (0...65_535).contains(Int(firstRaw))
      else { break }
      let first = Int(firstRaw)
      cursor += 1
      guard cursor < entries.count else { break }
      let second = FontValue.resolve(entries[cursor], in: graph)
      if case .array(let values)? = second {
        let parsed = triple(values)
        for (offset, metrics) in parsed.enumerated() where first + offset <= 65_535 {
          result[first + offset] = metrics
        }
        cursor += 1
      } else if case .integer(let lastRaw)? = second, Int(lastRaw) >= first,
        Int(lastRaw) <= 65_535, cursor + 3 < entries.count,
        let advance = numberValue(FontValue.resolve(entries[cursor + 1], in: graph)),
        let positionX = numberValue(FontValue.resolve(entries[cursor + 2], in: graph)),
        let positionY = numberValue(FontValue.resolve(entries[cursor + 3], in: graph))
      {
        for cid in first...Int(lastRaw) {
          result[cid] = CompositeFontVerticalAdvance(
            advance: advance, positionX: positionX, positionY: positionY)
        }
        cursor += 4
      } else {
        break
      }
    }
    return result
  }

  /// FNT-03: classify the embedded program form and record the FontFile3
  /// stream subtype. Bytes decide the outline type; the declared subtype is
  /// only a fallback, and a bare CFF header is parsed far enough to tell a
  /// name-keyed Type1C program from a CID-keyed CIDFontType0C program.
  static func classifyProgram(
    descriptor: [PDFName: PDFValue], in graph: PDFGraph
  ) -> (kind: CompositeFontProgram, subtype: String?) {
    func resolvedStream(_ key: PDFName) -> PDFStream? {
      switch FontValue.resolve(descriptor[key], in: graph) {
      case .stream(let stream)?: return stream
      case .reference(let id)?:
        if case .stream(let stream)? = graph.objects[id] { return stream }
        return nil
      default: return nil
      }
    }
    func bytes(_ stream: PDFStream) -> [UInt8] {
      guard let decoded = try? PDFFilters.decoded(stream) else { return [] }
      return [UInt8](decoded.prefix(4_096))
    }
    var declaredSubtype: String?
    if let file3 = resolvedStream(PDFName("FontFile3")) {
      declaredSubtype = nameValue(file3.dictionary[PDFName("Subtype")])
    }
    if let file2 = resolvedStream(PDFName("FontFile2")) {
      let head = bytes(file2)
      if head.count >= 4, head[0] == 0x4F, head[1] == 0x54, head[2] == 0x54, head[3] == 0x4F {
        return (.openTypeCFF, declaredSubtype)
      }
      return (.trueType, declaredSubtype)
    }
    if let file3 = resolvedStream(PDFName("FontFile3")) {
      let head = bytes(file3)
      if head.count >= 4, head[0] == 0x4F, head[1] == 0x54, head[2] == 0x54, head[3] == 0x4F {
        return (.openTypeCFF, declaredSubtype)
      }
      if head.count >= 4, head[0] == 0, head[1] == 1, head[2] == 0, head[3] == 0 {
        return (.trueType, declaredSubtype)
      }
      // A bare CFF program starts with major 1, minor 0, header size 4.
      if head.count >= 4, head[0] == 1, head[1] == 0 {
        if let facts = CFFProgramFacts.parse(head) {
          return (facts.isCIDKeyed ? .cidFontType0C : .type1C, declaredSubtype)
        }
        let declared: CompositeFontProgram
        switch declaredSubtype {
        case "CIDFontType0C": declared = .cidFontType0C
        case "Type1C": declared = .type1C
        default: declared = .unknown
        }
        return (declared, declaredSubtype)
      }
      switch declaredSubtype {
      case "OpenType": return (.openTypeCFF, declaredSubtype)
      case "CIDFontType0C": return (.cidFontType0C, declaredSubtype)
      case "Type1C": return (.type1C, declaredSubtype)
      default: return (.unknown, declaredSubtype)
      }
    }
    return (.unknown, declaredSubtype)
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


// MARK: - FNT-03 CFF/CID/CMap parsing primitives

/// FNT-03: a bounded lexer for CMap and CFF-adjacent syntax. CMaps commonly
/// omit whitespace between hex strings and array brackets and use percent
/// comments; this lexer drops comments and returns hex strings, brackets and
/// whitespace-delimited names/operators. Every token is produced once and the
/// parser bounds the token count, so malformed streams cannot run away.
enum CMapLexing {
  static let maximumTokens = 1_000_000

  static func text(from bytes: [UInt8]) -> String {
    let raw = String(decoding: bytes, as: UTF8.self)
    var output = ""
    output.reserveCapacity(raw.count)
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      if let comment = line.firstIndex(of: "%") {
        output += line[line.startIndex..<comment]
      } else {
        output += line
      }
      output += "\n"
    }
    return output
  }

  static func tokens(in bytes: [UInt8]) -> [String] {
    tokens(inText: text(from: bytes))
  }

  static func tokens(inText text: String) -> [String] {
    var result: [String] = []
    result.reserveCapacity(min(text.count, 65_536))
    var current = ""
    var index = text.startIndex
    func flush() {
      if !current.isEmpty {
        if result.count < maximumTokens { result.append(current) }
        current.removeAll(keepingCapacity: true)
      }
    }
    while index < text.endIndex {
      let character = text[index]
      if character == "<" {
        flush()
        var token = "<"
        var cursor = text.index(after: index)
        while cursor < text.endIndex {
          let next = text[cursor]
          token.append(next)
          cursor = text.index(after: cursor)
          if next == ">" { break }
        }
        if result.count < maximumTokens { result.append(token) }
        index = cursor
        continue
      }
      if character == "[" || character == "]" {
        flush()
        if result.count < maximumTokens { result.append(String(character)) }
        index = text.index(after: index)
        continue
      }
      if character.isWhitespace {
        flush()
        index = text.index(after: index)
        continue
      }
      current.append(character)
      index = text.index(after: index)
    }
    flush()
    return result
  }
}

/// FNT-03: a parsed embedded /Encoding CMap for a composite font. Supports the
/// codespace ranges, cidchar/cidrange entries, usecmap identity inheritance,
/// /CMapName and /WMode that corpus PDFs use beyond horizontal Identity-H.
/// Unsupported constructs are simply ignored; the parser never invents a CID.
struct EmbeddedCIDCMap: Sendable, Equatable {
  struct Codespace: Sendable, Equatable {
    let low: Int
    let high: Int
    let byteLength: Int
  }

  let name: String?
  let writingMode: Int
  let codespaces: [Codespace]
  let codeToCID: [Int: Int]
  let inheritsIdentity: Bool

  init?(stream: PDFStream, limits: PDFLimits = PDFLimits()) {
    guard let decoded = try? PDFFilters.decoded(stream, limits: limits) else { return nil }
    self.init(bytes: [UInt8](decoded))
  }

  init?(bytes: [UInt8]) {
    let tokens = CMapLexing.tokens(in: bytes)
    var codespaces: [Codespace] = []
    var mapping: [Int: Int] = [:]
    var name: String?
    var writingMode = 0
    var inheritsIdentity = false
    var index = 0
    while index < tokens.count {
      switch tokens[index] {
      case "begincodespacerange":
        index += 1
        while index + 1 < tokens.count, tokens[index] != "endcodespacerange" {
          guard let low = MultiByteToUnicodeCMap.hexValue(tokens[index]),
            let high = MultiByteToUnicodeCMap.hexValue(tokens[index + 1]),
            high.value >= low.value
          else { break }
          codespaces.append(
            Codespace(low: low.value, high: high.value, byteLength: low.byteLength))
          index += 2
        }
      case "begincidchar":
        index += 1
        while index + 1 < tokens.count, tokens[index] != "endcidchar" {
          guard let code = MultiByteToUnicodeCMap.hexValue(tokens[index]),
            let cid = Int(tokens[index + 1]), (0...65_535).contains(cid),
            mapping.count < 65_536
          else { break }
          mapping[code.value] = cid
          index += 2
        }
      case "begincidrange":
        index += 1
        while index + 2 < tokens.count, tokens[index] != "endcidrange" {
          guard let low = MultiByteToUnicodeCMap.hexValue(tokens[index]),
            let high = MultiByteToUnicodeCMap.hexValue(tokens[index + 1]),
            let cid = Int(tokens[index + 2]),
            high.value >= low.value, cid >= 0,
            high.value - low.value < 65_536 - mapping.count
          else { break }
          for offset in 0...max(0, high.value - low.value) {
            mapping[low.value + offset] = cid + offset
          }
          index += 3
        }
      case "usecmap":
        if index > 0 {
          let previous = tokens[index - 1]
          if previous.hasPrefix("/") {
            let inherited = String(previous.dropFirst())
            if inherited == "Identity-H" || inherited == "Identity-V" {
              inheritsIdentity = true
              if inherited == "Identity-V" { writingMode = 1 }
            }
          }
        }
        index += 1
      case "/CMapName":
        if index + 1 < tokens.count, tokens[index + 1].hasPrefix("/") {
          name = String(tokens[index + 1].dropFirst())
        }
        index += 2
      case "/WMode":
        if index + 1 < tokens.count, let mode = Int(tokens[index + 1]) { writingMode = mode }
        index += 2
      default:
        index += 1
      }
    }
    guard name != nil || !mapping.isEmpty || !codespaces.isEmpty || inheritsIdentity else {
      return nil
    }
    self.name = name
    self.writingMode = writingMode
    self.codespaces = codespaces
    self.codeToCID = mapping
    self.inheritsIdentity = inheritsIdentity
  }

  /// The byte length of the code starting at bytes[offset], from the declared
  /// codespaces. Falls back to 2 bytes (the identity/2-byte corpus case).
  func codeLength(in bytes: [UInt8], offset: Int) -> Int {
    for codespace in codespaces where codespace.byteLength >= 1
      && codespace.byteLength <= 4
    {
      var value = 0
      guard offset + codespace.byteLength <= bytes.count else { continue }
      for index in 0..<codespace.byteLength { value = (value << 8) | Int(bytes[offset + index]) }
      if value >= codespace.low, value <= codespace.high { return codespace.byteLength }
    }
    return codespaces.isEmpty ? 2 : 1
  }

  /// The CID a code selects. Identity inheritance covers the whole code space;
  /// explicit cidchar/cidrange entries win for the codes they name.
  func cid(for code: Int) -> Int? {
    if let cid = codeToCID[code] { return cid }
    return inheritsIdentity ? code : nil
  }

  /// FNT-03: the encoded byte length for a code value, from the declared
  /// codespaces (used when writing codes back for an edit).
  func byteLength(forCode code: Int) -> Int {
    for codespace in codespaces where codespace.byteLength >= 1 {
      if code >= codespace.low, code <= codespace.high { return codespace.byteLength }
    }
    return codespaces.isEmpty ? 2 : 1
  }
}

/// FNT-03: a parsed /CIDToGIDMap stream (2-byte glyph ids indexed by CID).
/// Bounded to 65,536 CIDs and validated as an even-length byte string; a
/// present but malformed map makes glyph lookup refuse rather than guess.
struct CIDToGIDTable: Sendable, Equatable {
  private let glyphIDs: [UInt16]

  init?(stream: PDFStream) {
    guard let decoded = try? PDFFilters.decoded(stream) else { return nil }
    self.init(bytes: [UInt8](decoded))
  }

  init?(bytes: [UInt8]) {
    guard bytes.count.isMultiple(of: 2), bytes.count <= 131_072 else { return nil }
    var glyphs: [UInt16] = []
    glyphs.reserveCapacity(bytes.count / 2)
    var index = 0
    while index < bytes.count {
      glyphs.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
      index += 2
    }
    self.glyphIDs = glyphs
  }

  func glyphID(forCID cid: Int) -> Int? {
    guard cid >= 0, cid < glyphIDs.count else { return nil }
    return Int(glyphIDs[cid])
  }
}

/// FNT-03: the small part of a bare CFF program needed to tell a name-keyed
/// Type1C program from a CID-keyed CIDFontType0C program. Parses the header,
/// Name INDEX and Top DICT INDEX, then looks for ROS (a CID-keyed program),
/// CharStrings and the charset. Malformed programs return nil; callers fall
/// back to the declared FontFile3 subtype rather than assuming either form.
struct CFFProgramFacts: Sendable, Equatable {
  let isCIDKeyed: Bool
  let glyphCount: Int
  let fontName: String?

  static func parse(_ bytes: [UInt8]) -> CFFProgramFacts? {
    guard bytes.count >= 4, bytes[0] == 1, bytes[1] == 0 else { return nil }
    let headerSize = Int(bytes[2])
    var offset = headerSize
    guard let nameIndex = parseIndex(bytes, at: offset) else { return nil }
    offset = nameIndex.next
    guard let top = parseIndex(bytes, at: offset), let topBytes = top.items.first else { return nil }
    var isCIDKeyed = false
    var charStringsOffset: Int?
    var charsetOffset: Int?
    var fontName: String?
    if let firstName = nameIndex.items.first {
      fontName = String(decoding: firstName, as: UTF8.self)
    }
    var index = 0
    var operands: [Int] = []
    while index < topBytes.count {
      let byte = Int(topBytes[index])
      if byte == 12 {
        guard index + 1 < topBytes.count else { return nil }
        let operatorCode = Int(topBytes[index + 1])
        if operatorCode == 30 { isCIDKeyed = true }
        operands.removeAll(keepingCapacity: true)
        index += 2
        continue
      }
      if byte <= 21 {
        if byte == 15, let charset = operands.last { charsetOffset = charset }
        if byte == 17, let charStrings = operands.last { charStringsOffset = charStrings }
        operands.removeAll(keepingCapacity: true)
        index += 1
        continue
      }
      if byte == 28 {
        guard index + 2 < topBytes.count else { return nil }
        let value = Int(Int16(bitPattern: UInt16(topBytes[index + 1]) << 8 | UInt16(topBytes[index + 2])))
        operands.append(value)
        index += 3
        continue
      }
      if byte == 29 || byte == 30 {
        if byte == 29 {
          guard index + 4 < topBytes.count else { return nil }
          var value = 0
          for slot in 1...4 { value = (value << 8) | Int(topBytes[index + slot]) }
          operands.append(value)
          index += 5
        } else {
          index += 1
          while index < topBytes.count {
            let next = Int(topBytes[index])
            index += 1
            if next == 0x0C {
              index += 1
            } else if next == 0x0D {
              break
            }
          }
        }
        continue
      }
      if (32...246).contains(byte) {
        operands.append(byte - 139)
      } else if (247...250).contains(byte) {
        guard index + 1 < topBytes.count else { return nil }
        operands.append((byte - 247) * 256 + Int(topBytes[index + 1]) + 108)
        index += 1
      } else if (251...254).contains(byte) {
        guard index + 1 < topBytes.count else { return nil }
        operands.append(-(byte - 251) * 256 - Int(topBytes[index + 1]) - 108)
        index += 1
      }
      index += 1
    }
    let glyphCount: Int
    if let charStringsOffset, charStringsOffset > 0, charStringsOffset < bytes.count,
      let charStrings = parseIndex(bytes, at: charStringsOffset)
    {
      glyphCount = charStrings.items.count
    } else if let charsetOffset, charsetOffset == 0 {
      // Predefined ISOAdobe charset names 229 glyphs, but a program this
      // small cannot be trusted; refuse the count rather than reporting it.
      glyphCount = 0
    } else {
      glyphCount = 0
    }
    return CFFProgramFacts(isCIDKeyed: isCIDKeyed, glyphCount: glyphCount, fontName: fontName)
  }

  private static func parseIndex(_ bytes: [UInt8], at offset: Int)
    -> (items: [[UInt8]], next: Int)?
  {
    guard offset >= 0, offset + 2 <= bytes.count else { return nil }
    let count = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    if count == 0 { return ([], offset + 2) }
    guard count <= 65_535, offset + 3 <= bytes.count else { return nil }
    let offSize = Int(bytes[offset + 2])
    guard offSize >= 1, offSize <= 4 else { return nil }
    let offsetArrayStart = offset + 3
    let dataStart = offsetArrayStart + (count + 1) * offSize
    guard dataStart <= bytes.count else { return nil }
    var offsets: [Int] = []
    offsets.reserveCapacity(count + 1)
    for index in 0...count {
      let at = offsetArrayStart + index * offSize
      var value = 0
      for slot in 0..<offSize { value = (value << 8) | Int(bytes[at + slot]) }
      guard value >= 1 else { return nil }
      offsets.append(value)
    }
    guard let first = offsets.first else { return nil }
    var items: [[UInt8]] = []
    items.reserveCapacity(count)
    for index in 0..<count {
      let start = dataStart + offsets[index] - first
      let end = dataStart + offsets[index + 1] - first
      guard start >= dataStart, end >= start, end <= bytes.count else { return nil }
      items.append(Array(bytes[start..<end]))
    }
    return (items, dataStart + offsets[count] - first)
  }
}

