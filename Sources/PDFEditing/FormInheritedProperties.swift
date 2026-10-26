import Foundation
import PDFCore

// FRM-05: inherited AcroForm properties. The field inventory already resolves
// flags, values, /MaxLen, /Opt and /I; appearance generation additionally needs
// the inherited /DA, /DR, /Q and /TU, which may live on any parent field or on
// the AcroForm dictionary. This reader resolves them explicitly so a fill or
// restyle writes an appearance that independent readers show the same way.

/// FRM-05: one field with its inherited appearance properties resolved.
public struct FormEffectiveFieldProperties: Sendable, Equatable {
  public let fieldName: String
  public let fieldID: PDFObjectID?
  public let kind: FormField.Kind
  public let flags: Int64
  public let isReadOnly: Bool
  public let isRequired: Bool
  public let isMultiline: Bool
  public let isComb: Bool
  public let isRichText: Bool
  public let isPassword: Bool
  public let isMultiSelect: Bool
  public let isRadio: Bool
  public let isPushButton: Bool
  /// Effective /DA string from the nearest field ancestor or the AcroForm.
  public let defaultAppearance: String?
  /// Effective /DA font resource name, size and non-stroking color.
  public let defaultAppearanceFontName: PDFName?
  public let defaultAppearanceSize: Double
  public let defaultAppearanceColor: [Double]
  /// Effective /DR Font entries (nearer field ancestors override the AcroForm).
  public let defaultResourceFonts: [PDFName: PDFValue]
  /// Effective /Q alignment (0 left, 1 center, 2 right).
  public let alignment: Int
  public let maxLength: Int?
  public let tooltip: String?
  public let value: PDFValue?
  public let defaultValue: PDFValue?
  public let richValue: PDFValue?
  public let widgetRects: [[Double]]
  public let widgetPageIndexes: [Int]

  public init(
    fieldName: String, fieldID: PDFObjectID?, kind: FormField.Kind, flags: Int64,
    isReadOnly: Bool, isRequired: Bool, isMultiline: Bool, isComb: Bool, isRichText: Bool,
    isPassword: Bool, isMultiSelect: Bool, isRadio: Bool, isPushButton: Bool,
    defaultAppearance: String?, defaultAppearanceFontName: PDFName?,
    defaultAppearanceSize: Double, defaultAppearanceColor: [Double],
    defaultResourceFonts: [PDFName: PDFValue], alignment: Int, maxLength: Int?, tooltip: String?,
    value: PDFValue?, defaultValue: PDFValue?, richValue: PDFValue?, widgetRects: [[Double]],
    widgetPageIndexes: [Int]
  ) {
    self.fieldName = fieldName
    self.fieldID = fieldID
    self.kind = kind
    self.flags = flags
    self.isReadOnly = isReadOnly
    self.isRequired = isRequired
    self.isMultiline = isMultiline
    self.isComb = isComb
    self.isRichText = isRichText
    self.isPassword = isPassword
    self.isMultiSelect = isMultiSelect
    self.isRadio = isRadio
    self.isPushButton = isPushButton
    self.defaultAppearance = defaultAppearance
    self.defaultAppearanceFontName = defaultAppearanceFontName
    self.defaultAppearanceSize = defaultAppearanceSize
    self.defaultAppearanceColor = defaultAppearanceColor
    self.defaultResourceFonts = defaultResourceFonts
    self.alignment = alignment
    self.maxLength = maxLength
    self.tooltip = tooltip
    self.value = value
    self.defaultValue = defaultValue
    self.richValue = richValue
    self.widgetRects = widgetRects
    self.widgetPageIndexes = widgetPageIndexes
  }

  public var displayValue: String? {
    guard case .string(let data)? = value else { return nil }
    return AnnotationText.decode(data)
  }

  public var isCenteredOrRightAligned: Bool { alignment == 1 || alignment == 2 }
}

/// FRM-05: parse the /DA string for its font resource, size and color.
public enum FormDefaultAppearance {
  public struct Parsed: Sendable, Equatable {
    public let fontName: PDFName?
    public let size: Double
    public let color: [Double]
    public init(fontName: PDFName?, size: Double, color: [Double]) {
      self.fontName = fontName
      self.size = size
      self.color = color
    }
  }

  public static func parse(_ value: PDFValue?) -> Parsed {
    guard case .string(let data)? = value else {
      return Parsed(fontName: nil, size: 12, color: [0, 0, 0])
    }
    let text = String(decoding: data, as: UTF8.self)
    let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var fontName: PDFName?
    var size = 12.0
    var color: [Double] = [0, 0, 0]
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      if token == "Tf", index >= 2 {
        for candidate in stride(from: index - 2, through: index - 1, by: 1) {
          let name = tokens[candidate]
          if name.hasPrefix("/"), name.count > 1 {
            fontName = PDFName(String(name.dropFirst()))
          }
        }
        if let parsed = Double(tokens[index - 1]), parsed.isFinite { size = parsed }
      }
      if token == "g", index >= 1, let parsed = Double(tokens[index - 1]), parsed.isFinite {
        color = [parsed, parsed, parsed]
      }
      if token == "rg", index >= 3 {
        let values = tokens[(index - 3)..<index].compactMap(Double.init)
        if values.count == 3, values.allSatisfy(\.isFinite) { color = values }
      }
      index += 1
    }
    return Parsed(
      fontName: fontName, size: max(4, min(size.isFinite ? size : 12, 96)), color: color)
  }
}

/// FRM-05: inherited-property resolution over the field parent chain.
public enum FormEffectivePropertiesReader {
  public static func properties(forFieldNamed name: String, in graph: PDFGraph) throws
    -> FormEffectiveFieldProperties
  {
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    guard let field = fields.first(where: { $0.name == name }) else {
      throw PDFError(.malformed, "Form field " + name + " is missing")
    }
    return try properties(for: field, in: graph, pageIDs: pageIDs)
  }

  public static func allProperties(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> [FormEffectiveFieldProperties]
  {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    return try fields.map { field in
      try properties(for: field, in: graph, pageIDs: pageIDs)
    }
  }

  public static func properties(
    for field: FormField, in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> FormEffectiveFieldProperties {
    let chain = parentChain(fieldID: field.fieldID, in: graph)
    let acroForm = FormInventory.acroFormDictionary(in: graph)
    let daValue: PDFValue? = inheritedValue("DA", chain: chain)
      ?? acroForm?[PDFName("DA")]
    let parsedDA = FormDefaultAppearance.parse(daValue)
    var fonts: [PDFName: PDFValue] = [:]
    if let acroForm, case .dictionary(let resources)? = acroForm[PDFName("DR")],
      case .dictionary(let acroFonts)? = resources[PDFName("Font")]
    {
      fonts = acroFonts
    }
    // Nearer ancestors override the AcroForm resources.
    for dictionary in chain.reversed() {
      guard case .dictionary(let resources)? = dictionary[PDFName("DR")],
        case .dictionary(let localFonts)? = resources[PDFName("Font")]
      else { continue }
      for (key, value) in localFonts { fonts[key] = value }
    }
    let alignment = inheritedInteger("Q", chain: chain)
      ?? acroForm?[PDFName("Q")].flatMap(integer) ?? 0
    let richValue: PDFValue? = inheritedValue("RV", chain: chain)
    var rects: [[Double]] = []
    var pages: [Int] = []
    for widget in field.widgets {
      guard let rect = widget.rect, let pageIndex = widget.pageIndex else { continue }
      rects.append(rect)
      pages.append(pageIndex)
    }
    _ = pageIDs
    return FormEffectiveFieldProperties(
      fieldName: field.name, fieldID: field.fieldID, kind: field.kind, flags: field.flags,
      isReadOnly: field.isReadOnly, isRequired: field.isRequired,
      isMultiline: field.isMultiline, isComb: field.isComb, isRichText: field.isRichText,
      isPassword: field.flags & 8192 != 0, isMultiSelect: field.isMultiSelect,
      isRadio: field.isRadio, isPushButton: field.isPushButton,
      defaultAppearance: daValue.flatMap(daString), defaultAppearanceFontName: parsedDA.fontName,
      defaultAppearanceSize: parsedDA.size, defaultAppearanceColor: parsedDA.color,
      defaultResourceFonts: fonts, alignment: max(0, min(alignment, 2)),
      maxLength: field.maxLength, tooltip: inheritedString("TU", chain: chain),
      value: field.value, defaultValue: field.defaultValue, richValue: richValue,
      widgetRects: rects, widgetPageIndexes: pages)
  }

  /// Resolve the effective appearance font. A missing /DA font falls back to
  /// the declared Standard-14 Helvetica default; an unusable imported font
  /// refuses instead of silently substituting another face.
  public static func appearanceFont(
    for properties: FormEffectiveFieldProperties, in graph: PDFGraph
  ) throws -> FormAppearanceFontHandle {
    guard let fontName = properties.defaultAppearanceFontName else {
      return standardHelvetica(in: graph)
    }
    if let font = properties.defaultResourceFonts[fontName] {
      return try FormAppearanceFonts.handle(forDAFontNamed: fontName, fonts: [fontName: font], in: graph)
    }
    // A /DA may name a font registered in the AcroForm /DR only.
    let acroFonts = FormAppearanceFonts.formResourcesFonts(ownerFieldID: nil, in: graph)
    if let font = acroFonts[fontName] {
      return try FormAppearanceFonts.handle(forDAFontNamed: fontName, fonts: [fontName: font], in: graph)
    }
    if let face = FormAppearanceFonts.standardFace(
      named: String(decoding: fontName.bytes, as: UTF8.self))
    {
      return .standard(face: face, resourceName: fontName)
    }
    throw PDFError(
      .unsupported,
      "The field default appearance names the font "
        + String(decoding: fontName.bytes, as: UTF8.self)
        + " which is missing from the inherited /DR resources; sPDF refuses to substitute a "
        + "different face")
  }

  static func standardHelvetica(in graph: PDFGraph) -> FormAppearanceFontHandle {
    var local = graph
    var nextNumber = (local.objects.keys.map(\.number).max() ?? 0) + 1
    let id = SetFormRichTextStyleCommand.standardFontID(
      named: "Helvetica", in: &local, nextNumber: &nextNumber)
    _ = id
    return .standard(face: .helvetica, resourceName: PDFName("Helv"))
  }

  // MARK: Parent chain helpers

  static func parentChain(fieldID: PDFObjectID?, in graph: PDFGraph) -> [[PDFName: PDFValue]] {
    var chain: [[PDFName: PDFValue]] = []
    var current = fieldID
    var depth = 0
    var visited: Set<PDFObjectID> = []
    while let id = current, depth < 32, visited.insert(id).inserted {
      guard case .dictionary(let dictionary)? = graph.objects[id] else { break }
      chain.append(dictionary)
      if case .reference(let parent)? = dictionary[PDFName("Parent")] {
        current = parent
      } else {
        current = nil
      }
      depth += 1
    }
    return chain
  }

  static func inheritedValue(
    _ key: String, chain: [[PDFName: PDFValue]]
  ) -> PDFValue? {
    for dictionary in chain {
      if let value = dictionary[PDFName(key)] { return value }
    }
    return nil
  }

  static func inheritedString(_ key: String, chain: [[PDFName: PDFValue]]) -> String? {
    guard case .string(let data)? = inheritedValue(key, chain: chain) else { return nil }
    return AnnotationText.decode(data)
  }

  static func inheritedInteger(_ key: String, chain: [[PDFName: PDFValue]]) -> Int? {
    guard let value = inheritedValue(key, chain: chain) else { return nil }
    return integer(value)
  }

  static func integer(_ value: PDFValue) -> Int? {
    if case .integer(let raw) = value { return Int(exactly: raw) }
    return nil
  }

  static func daString(_ value: PDFValue) -> String? {
    guard case .string(let data) = value else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
