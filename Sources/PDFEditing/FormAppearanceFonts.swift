import Foundation
import CoreGraphics
import CoreText
import PDFCore

// FRM-05: appearance fonts for form fields, including embedded TrueType
// programs. Values and appearances must agree in independent readers, so an
// embedded font is written as a Type0 Identity-H font with a ToUnicode map and
// an explicit CIDToGIDMap when CID order differs from glyph order (the same
// profile the page-text writer uses). Imported form fonts are resolved, never
// replaced silently; unsupported programs refuse with an actionable message.

/// FRM-05: a caller-supplied TrueType program for field appearance text.
public struct FormEmbeddedFontSource: Sendable, Equatable {
  public let program: Data
  public let familyName: String
  public let faceName: String
  public let isBold: Bool
  public let isItalic: Bool

  public init(
    program: Data, familyName: String, faceName: String? = nil, isBold: Bool = false,
    isItalic: Bool = false
  ) {
    self.program = program
    self.familyName = familyName
    self.faceName = faceName ?? familyName
    self.isBold = isBold
    self.isItalic = isItalic
  }

  public init(custom: CustomTextFont) {
    self.init(
      program: custom.program, familyName: custom.familyName, faceName: custom.faceName,
      isBold: custom.isBold, isItalic: custom.isItalic)
  }

  /// A safe RTF font-table family name.
  public var sanitizedFamilyName: String {
    let filtered = familyName.map { character -> String in
      if character.isLetter || character.isNumber || character == "-" || character == "." {
        return String(character)
      }
      return "-"
    }.joined()
    return filtered.isEmpty ? "EmbeddedFont" : filtered
  }
}

/// FRM-05: how appearance text is encoded for a field.
public enum FormAppearanceFontChoice: Sendable, Equatable {
  /// One of the Standard 14 faces (no embedding).
  case standard(StandardTextFont)
  /// A licensed TrueType program embedded as a tagged subset.
  case embedded(FormEmbeddedFontSource)

  public var familyLabel: String {
    switch self {
    case .standard(let face): return face.rawValue
    case .embedded(let source): return source.faceName
    }
  }

  public var isEmbedded: Bool {
    if case .embedded = self { return true }
    return false
  }
}

/// FRM-05: a resolved font the appearance writer can encode and measure with.
public enum FormAppearanceFontHandle: Sendable, Equatable {
  /// A Standard-14 face referenced by its resource name.
  case standard(face: StandardTextFont, resourceName: PDFName)
  /// An embedded composite font, or an imported simple font with a ToUnicode map.
  case embedded(
    resourceName: PDFName, codes: [Int: [UInt8]], widths: [Int: Double], byteLength: Int,
    baseName: String)

  public var resourceName: PDFName {
    switch self {
    case .standard(_, let name): return name
    case .embedded(let name, _, _, _, _): return name
    }
  }

  public var isComposite: Bool {
    if case .embedded(_, _, _, let byteLength, _) = self { return byteLength == 2 }
    return false
  }

  public var baseName: String {
    switch self {
    case .standard(let face, _): return face.rawValue
    case .embedded(_, _, _, _, let baseName): return baseName
    }
  }

  /// Encoded code bytes for the text, or nil when a character is not covered.
  /// Never substitutes a different glyph.
  public func encode(_ text: String) -> [UInt8]? {
    switch self {
    case .standard:
      var bytes: [UInt8] = []
      for scalar in text.unicodeScalars {
        guard let data = String(scalar).data(using: .windowsCP1252), data.count == 1 else {
          return nil
        }
        bytes.append(data[0])
      }
      return bytes
    case .embedded(_, let codes, _, _, _):
      var bytes: [UInt8] = []
      for scalar in text.unicodeScalars {
        guard let code = codes[Int(scalar.value)] else { return nil }
        bytes.append(contentsOf: code)
      }
      return bytes
    }
  }

  public func canEncode(_ text: String) -> Bool { encode(text) != nil }

  /// A PDF string operand for a Tj/TJ show operator.
  public func operand(_ text: String) -> String? {
    guard let bytes = encode(text) else { return nil }
    if isComposite {
      return "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }
    return Self.literal(bytes)
  }

  /// Measured advance for the text at the given size, in points.
  public func measuredWidth(_ text: String, size: Double) -> Double? {
    guard let bytes = encode(text) else { return nil }
    switch self {
    case .standard(let face, _):
      return FormAppearanceFonts.standardWidth(text, face: face, size: size)
    case .embedded(_, _, let widths, let byteLength, _):
      var total = 0.0
      if byteLength == 2 {
        var index = 0
        while index + 1 < bytes.count {
          let cid = Int(bytes[index]) << 8 | Int(bytes[index + 1])
          total += (widths[cid] ?? 1000) / 1000 * size
          index += 2
        }
      } else {
        for byte in bytes {
          total += (widths[Int(byte)] ?? 1000) / 1000 * size
        }
      }
      return total
    }
  }

  /// A conservative width when a font cannot measure a character: the callers
  /// that matter refuse unencodable text before measuring.
  public func fallbackWidth(_ text: String, size: Double) -> Double {
    measuredWidth(text, size: size) ?? Double(text.count) * size * 0.5
  }

  static func literal(_ bytes: [UInt8]) -> String {
    var result = "("
    for byte in bytes {
      switch byte {
      case 0x28: result += "\\("
      case 0x29: result += "\\)"
      case 0x5C: result += "\\\\"
      default:
        if byte >= 32 && byte < 127 {
          result.append(Character(UnicodeScalar(byte)))
        } else {
          result += String(format: "\\%03o", Int(byte))
        }
      }
    }
    result += ")"
    return result
  }
}

/// FRM-05: register embedded programs in a field's /DR and resolve fonts already
/// present in the document's inherited resources.
public enum FormAppearanceFonts {
  // MARK: Standard faces

  public static func standardSource(for choice: FormAppearanceFontChoice) -> StandardTextFont? {
    if case .standard(let face) = choice { return face }
    return nil
  }

  /// CoreText measurement for a Standard-14 face; nil when the face cannot
  /// represent a scalar.
  public static func standardWidth(_ text: String, face: StandardTextFont, size: Double) -> Double? {
    guard size.isFinite, size > 0, StandardTextFont.canEncode(text) else { return nil }
    let characters = Array(text.utf16)
    guard !characters.isEmpty else { return 0 }
    let font = CTFontCreateWithName(face.rawValue as CFString, 1_000, nil)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, glyphs.count),
      glyphs.allSatisfy({ $0 != 0 })
    else { return nil }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    guard advances.allSatisfy({ $0.width.isFinite && $0.width >= 0 }) else { return nil }
    let total = advances.reduce(0.0) { $0 + Double($1.width) }
    return total * size / 1_000
  }

  /// The declared DA font name for a standard face.
  public static func standardFace(named name: String) -> StandardTextFont? {
    if let face = StandardTextFont(rawValue: name) { return face }
    switch name {
    case "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique":
      return StandardTextFont(rawValue: name)
    default:
      return nil
    }
  }

  // MARK: Embedded program registration

  /// Register a licensed TrueType program as a Type0 Identity-H font in the
  /// owner field's /DR (or the AcroForm /DR when owner is nil). Returns the
  /// handle the appearance writer encodes with. Reuses a byte-identical
  /// registered font.
  public static func register(
    source: FormEmbeddedFontSource, covering text: String, in graph: inout PDFGraph,
    ownerFieldID: PDFObjectID?
  ) throws -> FormAppearanceFontHandle {
    let inspector = try TrueTypeInspector.inspect(source.program)
    guard !inspector.isCFF else {
      throw PDFError(
        .unsupported,
        "Form appearance font embedding currently supports TrueType outline programs; "
          + "CFF/OpenType programs are refused rather than substituted")
    }
    guard inspector.permitsEditableSubsetEmbedding else {
      throw PDFError(
        .unsupported, "This font's embedding permissions do not allow embedding in a PDF form")
    }
    let written = try CompositeFontWriter.write(
      program: source.program, baseName: source.sanitizedFamilyName, covering: text)
    if let existing = try existingRegisteredFont(matching: written, ownerFieldID: ownerFieldID, in: graph)
    {
      return existing
    }
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    func allocate() -> PDFObjectID {
      let id = PDFObjectID(nextNumber)
      nextNumber += 1
      return id
    }
    let fontID = allocate()
    let descendantID = allocate()
    let descriptorID = allocate()
    let fileID = allocate()
    let cmapID = allocate()
    var cidToGIDMapID: PDFObjectID?
    var encodingCMapID: PDFObjectID?
    if written.cidToGIDMap != nil { cidToGIDMapID = allocate() }
    if written.encodingCMap != nil { encodingCMapID = allocate() }

    guard case .dictionary(var descendant) = written.descendant,
      case .dictionary(var descriptor) = written.descriptor
    else {
      throw PDFError(.malformed, "The embedded font structures are malformed")
    }
    descendant[PDFName("FontDescriptor")] = .reference(descriptorID)
    if let cidToGIDMapID { descendant[PDFName("CIDToGIDMap")] = .reference(cidToGIDMapID) }
    descriptor[PDFName("FontFile2")] = .reference(fileID)
    var fontFile = written.fontFile
    fontFile.dictionary[PDFName("Length")] = .integer(Int64(fontFile.bytes.count))
    var toUnicode = written.toUnicode
    toUnicode.dictionary[PDFName("Length")] = .integer(Int64(toUnicode.bytes.count))
    graph.objects[fontID] = written.type0Dictionary(
      descendant: descendantID, toUnicode: cmapID, baseName: written.baseName,
      encodingCMap: encodingCMapID)
    graph.objects[descendantID] = .dictionary(descendant)
    graph.objects[descriptorID] = .dictionary(descriptor)
    graph.objects[fileID] = .stream(fontFile)
    graph.objects[cmapID] = .stream(toUnicode)
    if let cidToGIDMapID, let stream = written.cidToGIDMap {
      graph.objects[cidToGIDMapID] = .stream(stream)
    }
    if let encodingCMapID, let stream = written.encodingCMap {
      graph.objects[encodingCMapID] = .stream(stream)
    }
    let resourceName = try uniqueFontName(in: &graph, ownerFieldID: ownerFieldID)
    try registerFontResource(
      name: resourceName, fontID: fontID, in: &graph, ownerFieldID: ownerFieldID)
    var codes: [Int: [UInt8]] = [:]
    for (scalar, cid) in written.encoding {
      if written.codeByteLength == 2 {
        codes[scalar] = [UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF)]
      } else {
        guard cid >= 0, cid <= 255 else { continue }
        codes[scalar] = [UInt8(cid)]
      }
    }
    var widths: [Int: Double] = [:]
    for (cid, width) in written.widths { widths[cid] = Double(width) }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return .embedded(
      resourceName: resourceName, codes: codes, widths: widths,
      byteLength: written.codeByteLength, baseName: written.baseName)
  }

  static func existingRegisteredFont(
    matching written: WrittenCompositeFont, ownerFieldID: PDFObjectID?, in graph: PDFGraph
  ) throws -> FormAppearanceFontHandle? {
    let fonts = formResourcesFonts(ownerFieldID: ownerFieldID, in: graph)
    for (name, value) in fonts {
      guard case .reference(let fontID) = value,
        case .dictionary(let font)? = graph.objects[fontID],
        font[PDFName("Subtype")] == .name(PDFName("Type0")),
        case .array(let descendants)? = font[PDFName("DescendantFonts")],
        case .reference(let descendantID)? = descendants.first,
        case .dictionary(let descendant)? = graph.objects[descendantID],
        case .reference(let descriptorID)? = descendant[PDFName("FontDescriptor")],
        case .dictionary(let descriptor)? = graph.objects[descriptorID],
        case .reference(let fileID)? = descriptor[PDFName("FontFile2")],
        case .stream(let file)? = graph.objects[fileID],
        file.bytes == written.fontFile.bytes
      else { continue }
      var codes: [Int: [UInt8]] = [:]
      for (scalar, cid) in written.encoding {
        if written.codeByteLength == 2 {
          codes[scalar] = [UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF)]
        } else {
          guard cid >= 0, cid <= 255 else { continue }
          codes[scalar] = [UInt8(cid)]
        }
      }
      var widths: [Int: Double] = [:]
      for (cid, width) in written.widths { widths[cid] = Double(width) }
      return .embedded(
        resourceName: name, codes: codes, widths: widths, byteLength: written.codeByteLength,
        baseName: written.baseName)
    }
    return nil
  }

  // MARK: Existing document fonts

  /// Resolve the font a /DA string names against the inherited /DR Font
  /// resources. Standard-14 faces and imported simple/composite fonts with a
  /// ToUnicode map are supported; anything else refuses instead of substituting.
  public static func handle(
    forDAFontNamed fontName: PDFName, fonts: [PDFName: PDFValue], in graph: PDFGraph
  ) throws -> FormAppearanceFontHandle {
    guard let value = fonts[fontName] else {
      throw PDFError(
        .unsupported,
        "The field default appearance references the font "
          + String(decoding: fontName.bytes, as: UTF8.self)
          + " which is not present in the inherited /DR resources")
    }
    guard let font = resolvedDictionary(value, in: graph) else {
      throw PDFError(.unsupported, "The field appearance font dictionary is missing")
    }
    if font[PDFName("Subtype")] == .name(PDFName("Type1")),
      let baseName = nameString(font[PDFName("BaseFont")]),
      font[PDFName("Widths")] == nil, font[PDFName("FontDescriptor")] == nil,
      font[PDFName("ToUnicode")] == nil,
      let face = standardFace(named: baseName)
    {
      return .standard(face: face, resourceName: fontName)
    }
    if font[PDFName("Subtype")] == .name(PDFName("Type0")) {
      return try compositeHandle(resourceName: fontName, font: font, in: graph)
    }
    return try simpleHandle(resourceName: fontName, font: font, in: graph)
  }

  static func simpleHandle(
    resourceName: PDFName, font: [PDFName: PDFValue], in graph: PDFGraph
  ) throws -> FormAppearanceFontHandle {
    guard case .reference(let cmapID)? = font[PDFName("ToUnicode")],
      case .stream(let cmapStream)? = graph.objects[cmapID],
      let cmap = ToUnicodeCMap(stream: cmapStream)
    else {
      throw PDFError(
        .unsupported,
        "This imported field font has no readable ToUnicode map, so sPDF cannot write text "
          + "that independent readers are guaranteed to show; the value is refused instead of "
          + "substituting another font")
    }
    var codes: [Int: [UInt8]] = [:]
    for code in UInt8.min...UInt8.max {
      guard let text = cmap.decode(code), text.unicodeScalars.count == 1,
        let scalar = text.unicodeScalars.first
      else { continue }
      if codes[Int(scalar.value)] == nil { codes[Int(scalar.value)] = [code] }
    }
    var widths: [Int: Double] = [:]
    let first = integer(font[PDFName("FirstChar")]) ?? 0
    if case .array(let values)? = font[PDFName("Widths")] {
      for (offset, value) in values.enumerated() {
        if let width = number(value) { widths[first + offset] = width }
      }
    }
    let missing = descriptorWidth(font: font, key: "MissingWidth", in: graph) ?? 0
    for code in 0...255 where widths[code] == nil { widths[code] = missing }
    let baseName = nameString(font[PDFName("BaseFont")]) ?? "Embedded"
    return .embedded(
      resourceName: resourceName, codes: codes, widths: widths, byteLength: 1, baseName: baseName)
  }

  static func compositeHandle(
    resourceName: PDFName, font: [PDFName: PDFValue], in graph: PDFGraph
  ) throws -> FormAppearanceFontHandle {
    guard case .reference(let cmapID)? = font[PDFName("ToUnicode")],
      case .stream(let cmapStream)? = graph.objects[cmapID],
      let decoded = try? PDFFilters.decoded(cmapStream),
      let inverted = TwoByteToUnicode.parse(decoded)
    else {
      throw PDFError(
        .unsupported,
        "This imported composite field font has no readable ToUnicode map; text is refused "
          + "instead of substituting another font")
    }
    guard case .array(let descendants)? = font[PDFName("DescendantFonts")],
      case .reference(let descendantID)? = descendants.first,
      case .dictionary(let descendant)? = graph.objects[descendantID]
    else {
      throw PDFError(.unsupported, "The composite field font has no descendant font")
    }
    let defaultWidth = number(descendant[PDFName("DW")]) ?? 1000
    var widths: [Int: Double] = [:]
    if case .array(let entries)? = descendant[PDFName("W")] {
      var index = 0
      while index + 1 < entries.count {
        guard let start = integer(entries[index]) else { break }
        switch entries[index + 1] {
        case .array(let list):
          for (offset, value) in list.enumerated() {
            if let width = number(value) { widths[start + offset] = width }
          }
          index += 2
        case .integer(let end) where index + 2 < entries.count:
          let last = Int(end)
          let width = number(entries[index + 2]) ?? defaultWidth
          if start <= last, last - start <= 65_535 {
            for cid in start...last { widths[cid] = width }
          }
          index += 3
        default:
          index += 2
        }
      }
    }
    let baseName = nameString(font[PDFName("BaseFont")]) ?? "Embedded"
    var codes: [Int: [UInt8]] = [:]
    for (code, scalar) in inverted {
      let bytes = [UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
      if codes[scalar] == nil { codes[scalar] = bytes }
      if widths[code] == nil { widths[code] = defaultWidth }
    }
    return .embedded(
      resourceName: resourceName, codes: codes, widths: widths, byteLength: 2, baseName: baseName)
  }

  // MARK: Resource bookkeeping

  public static func formResourcesFonts(
    ownerFieldID: PDFObjectID?, in graph: PDFGraph
  ) -> [PDFName: PDFValue] {
    guard let ownerFieldID, case .dictionary(let field)? = graph.objects[ownerFieldID],
      case .dictionary(let resources)? = field[PDFName("DR")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else {
      return FormInventory.acroFormDictionary(in: graph).flatMap { acroForm -> [PDFName: PDFValue] in
        guard case .dictionary(let resources)? = acroForm[PDFName("DR")],
          case .dictionary(let fonts)? = resources[PDFName("Font")]
        else { return [:] }
        return fonts
      } ?? [:]
    }
    return fonts
  }

  static func uniqueFontName(in graph: inout PDFGraph, ownerFieldID: PDFObjectID?) throws -> PDFName {
    let existing = Set(
      formResourcesFonts(ownerFieldID: ownerFieldID, in: graph).keys.map {
        String(decoding: $0.bytes, as: UTF8.self)
      })
    var counter = 1
    var name = PDFName("SPDFF1")
    while existing.contains(String(decoding: name.bytes, as: UTF8.self)) {
      counter += 1
      guard counter < 10_000 else {
        throw PDFError(.limitExceeded, "No free form font resource name remains")
      }
      name = PDFName("SPDFF" + String(counter))
    }
    return name
  }

  static func registerFontResource(
    name: PDFName, fontID: PDFObjectID, in graph: inout PDFGraph, ownerFieldID: PDFObjectID?
  ) throws {
    if let ownerFieldID, case .dictionary(var field)? = graph.objects[ownerFieldID] {
      var resources: [PDFName: PDFValue] = [:]
      if case .dictionary(let existing)? = field[PDFName("DR")] { resources = existing }
      var fonts: [PDFName: PDFValue] = [:]
      if case .dictionary(let existing)? = resources[PDFName("Font")] { fonts = existing }
      fonts[name] = .reference(fontID)
      resources[PDFName("Font")] = .dictionary(fonts)
      field[PDFName("DR")] = .dictionary(resources)
      graph.objects[ownerFieldID] = .dictionary(field)
      return
    }
    var pageIDs: [PDFObjectID] = []
    if let pageIDsValue = try? PageTreeView(graph: graph).pages { pageIDs = pageIDsValue }
    _ = pageIDs
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    var acroForm: [PDFName: PDFValue]
    if case .dictionary(let existing)? = catalog[PDFName("AcroForm")] {
      acroForm = existing
    } else {
      acroForm = [:]
    }
    var resources: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = acroForm[PDFName("DR")] { resources = existing }
    var fonts: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = resources[PDFName("Font")] { fonts = existing }
    fonts[name] = .reference(fontID)
    resources[PDFName("Font")] = .dictionary(fonts)
    acroForm[PDFName("DR")] = .dictionary(resources)
    catalog[PDFName("AcroForm")] = .dictionary(acroForm)
    graph.objects[catalogID] = .dictionary(catalog)
  }

  // MARK: Value helpers

  static func resolvedDictionary(_ value: PDFValue, in graph: PDFGraph) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary): return dictionary
    case .reference(let id):
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default: return nil
    }
  }

  static func nameString(_ value: PDFValue?) -> String? {
    guard case .name(let name)? = value else { return nil }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  static func integer(_ value: PDFValue?) -> Int? {
    if case .integer(let raw)? = value { return Int(exactly: raw) }
    return nil
  }

  static func number(_ value: PDFValue?) -> Double? {
    switch value {
    case .integer(let raw)?: return Double(raw)
    case .real(let raw)?: return raw
    default: return nil
    }
  }

  static func descriptorWidth(
    font: [PDFName: PDFValue], key: String, in graph: PDFGraph
  ) -> Double? {
    guard case .reference(let descriptorID)? = font[PDFName("FontDescriptor")],
      case .dictionary(let descriptor)? = graph.objects[descriptorID]
    else { return nil }
    return number(descriptor[PDFName(key)])
  }
}

/// FRM-05: a bounded two-byte ToUnicode reader used to invert imported
/// composite form fonts. Only code-to-Unicode entries are read; no text is
/// executed or rendered here.
enum TwoByteToUnicode {
  static func parse(_ bytes: Data) -> [Int: Int]? {
    let text = String(decoding: bytes, as: UTF8.self)
    let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var map: [Int: Int] = [:]
    func hexValue(_ token: String) -> Int? {
      let trimmed = token.hasPrefix("<") && token.hasSuffix(">")
        ? String(token.dropFirst().dropLast()) : token
      guard !trimmed.isEmpty, trimmed.count <= 4 else { return nil }
      return Int(trimmed, radix: 16)
    }
    func unicodeValue(_ token: String) -> Int? {
      let trimmed = token.hasPrefix("<") && token.hasSuffix(">")
        ? String(token.dropFirst().dropLast()) : token
      guard trimmed.count == 4 else { return nil }
      return Int(trimmed, radix: 16)
    }
    var index = 0
    var entries = 0
    while index < tokens.count {
      if tokens[index] == "beginbfchar" {
        index += 1
        while index + 1 < tokens.count, tokens[index] != "endbfchar" {
          guard let code = hexValue(tokens[index]), let scalar = unicodeValue(tokens[index + 1])
          else { break }
          map[code] = scalar
          entries += 1
          index += 2
          if entries > 65_535 { return map }
        }
        continue
      }
      if tokens[index] == "beginbfrange" {
        index += 1
        while index + 2 < tokens.count, tokens[index] != "endbfrange" {
          guard let low = hexValue(tokens[index]), let high = hexValue(tokens[index + 1])
          else { break }
          let destination = tokens[index + 2]
          if destination.hasPrefix("[") {
            var cursor = index + 2
            var code = low
            while cursor < tokens.count, tokens[cursor] != "]" {
              let token = tokens[cursor]
              if token.hasPrefix("<"), let scalar = unicodeValue(token), code <= high {
                map[code] = scalar
                code += 1
              }
              cursor += 1
            }
            index = cursor + 1
          } else if let start = unicodeValue(destination) {
            if low <= high, high - low <= 65_535 {
              for offset in 0...(high - low) { map[low + offset] = start + offset }
            }
            index += 3
          } else {
            index += 1
          }
          entries = map.count
          if entries > 65_535 { return map }
        }
        continue
      }
      index += 1
    }
    return map.isEmpty ? nil : map
  }
}
