import Foundation
import CoreGraphics
import CoreText
import PDFCore

// FRM-05: appearance layout and the rich-text fill command. Layout is pure so
// validation and tests use exactly the geometry the writer emits; the command
// resolves inherited /DA, /DR and /Q, registers appearance fonts (including an
// embedded TrueType subset), writes /V + coherent /RV and regenerates every
// widget appearance in one undoable step.

/// FRM-05: the layout consequence of a rich value in one widget rectangle.
public struct FormRichTextLayout: Sendable, Equatable {
  public let lineCount: Int
  public let effectiveScale: Double
  public let overflowed: Bool
  public let originY: Double
  public init(lineCount: Int, effectiveScale: Double, overflowed: Bool, originY: Double) {
    self.lineCount = lineCount
    self.effectiveScale = effectiveScale
    self.overflowed = overflowed
    self.originY = originY
  }
}

/// FRM-05: paint a rich value into a widget appearance stream. Pure: the caller
/// supplies resolved font handles and appearance font resources.
public enum FormRichTextAppearance {
  public static let minimumFontSize = 4.0

  struct Segment {
    var text: String
    var handle: FormAppearanceFontHandle
    var style: FormRichTextStyle
    var width: Double
  }

  // MARK: Layout

  public static func layout(
    value: FormRichTextValue, rect: [Double], multiline: Bool, comb: Bool, maxLength: Int?,
    baseFont: FormAppearanceFontHandle, runFonts: [StandardTextFont: FormAppearanceFontHandle]
  ) -> FormRichTextLayout {
    let width = max(1, rect[2] - rect[0])
    let height = max(1, rect[3] - rect[1])
    if comb {
      let cells = max(1, maxLength ?? max(value.utf16Length, 1))
      let cellWidth = width / Double(cells)
      var scale = 1.0
      var overflow = value.utf16Length > cells
      var offset = 0
      for character in value.plainText {
        let style = value.style(atUTF16Offset: offset)
        offset += String(character).utf16.count
        let handle = handle(for: style, base: baseFont, runFonts: runFonts)
        let measured = handle.fallbackWidth(String(character), size: style.fontSize)
        guard measured > 0 else { continue }
        let fit = (cellWidth - 2) / measured
        if fit < scale { scale = fit }
        if fit * style.fontSize < minimumFontSize { overflow = true }
      }
      return FormRichTextLayout(
        lineCount: 1, effectiveScale: max(min(scale, 1), 0.05), overflowed: overflow,
        originY: (height - value.baseStyle.fontSize * max(min(scale, 1), 0.05)) / 2)
    }
    if multiline {
      let lines = wrap(value: value, available: width - 4, base: baseFont, runFonts: runFonts)
      var largestSize = max(1, value.baseStyle.fontSize)
      for line in lines { for segment in line { largestSize = max(largestSize, segment.style.fontSize) } }
      let lineHeight = largestSize * 1.2
      let totalHeight = lineHeight * Double(max(lines.count, 1))
      let scale = totalHeight > height ? height / totalHeight : 1
      let overflow = scale < minimumFontSize / largestSize
      return FormRichTextLayout(
        lineCount: lines.count, effectiveScale: max(min(scale, 1), 0.05), overflowed: overflow,
        originY: height - largestSize * min(scale, 1) * 0.9)
    }
    let segments = measure(value: value, base: baseFont, runFonts: runFonts)
    let total = segments.reduce(0.0) { $0 + $1.width }
    let scale = total > width - 4 ? (width - 4) / max(total, 0.001) : 1
    let overflow = scale < minimumFontSize / max(1, value.baseStyle.fontSize)
    return FormRichTextLayout(
      lineCount: 1, effectiveScale: max(min(scale, 1), 0.05), overflowed: overflow,
      originY: (height - value.baseStyle.fontSize * max(min(scale, 1), 0.05)) / 2)
  }

  // MARK: Stream builder

  public static func build(
    value: FormRichTextValue, rect: [Double], multiline: Bool, comb: Bool, maxLength: Int?,
    alignment: Int, baseFont: FormAppearanceFontHandle,
    runFonts: [StandardTextFont: FormAppearanceFontHandle],
    fontResources: [PDFName: PDFValue]
  ) -> (stream: PDFStream, layout: FormRichTextLayout) {
    let width = max(1, rect[2] - rect[0])
    let height = max(1, rect[3] - rect[1])
    let bounds = layout(
      value: value, rect: rect, multiline: multiline, comb: comb, maxLength: maxLength,
      baseFont: baseFont, runFonts: runFonts)
    var content = "q\n"
    if comb {
      let cells = max(1, maxLength ?? max(value.utf16Length, 1))
      let cellWidth = width / Double(cells)
      var offset = 0
      var cellIndex = 0
      for character in value.plainText where cellIndex < cells {
        let style = value.style(atUTF16Offset: offset)
        offset += String(character).utf16.count
        let handle = handle(for: style, base: baseFont, runFonts: runFonts)
        let text = String(character)
        let measured = handle.fallbackWidth(text, size: style.fontSize)
        let fit = max(0.1, min(1, (cellWidth - 2) / max(measured, 0.001)))
        let size = style.fontSize * fit
        if size >= minimumFontSize - 0.001, let operand = handle.operand(text) {
          let x = Double(cellIndex) * cellWidth + max(0, (cellWidth - measured * fit) / 2)
          let y = (height - size) / 2 + size * 0.2
          content += textShow(
            fontName: handle.resourceName, size: size, color: style.color, x: x, y: y,
            operand: operand)
        }
        cellIndex += 1
      }
    } else if multiline {
      let lines = wrap(value: value, available: width - 4, base: baseFont, runFonts: runFonts)
      var largestSize = max(1, value.baseStyle.fontSize)
      for line in lines { for segment in line { largestSize = max(largestSize, segment.style.fontSize) } }
      let scale = bounds.effectiveScale
      let lineHeight = largestSize * 1.2 * scale
      var y = bounds.originY
      for line in lines {
        let lineWidth = line.reduce(0.0) { $0 + $1.width } * scale
        var x = 2.0
        switch alignment {
        case 1: x = 2 + max(0, (width - 4 - lineWidth) / 2)
        case 2: x = 2 + max(0, width - 4 - lineWidth)
        default: break
        }
        for segment in line {
          guard let operand = segment.handle.operand(segment.text) else { continue }
          content += textShow(
            fontName: segment.handle.resourceName, size: segment.style.fontSize * scale,
            color: segment.style.color, x: x, y: y, operand: operand)
          x += segment.width * scale
        }
        y -= lineHeight
      }
    } else {
      let segments = measure(value: value, base: baseFont, runFonts: runFonts)
      let scale = bounds.effectiveScale
      let total = segments.reduce(0.0) { $0 + $1.width } * scale
      var x = 2.0
      switch alignment {
      case 1: x = 2 + max(0, (width - 4 - total) / 2)
      case 2: x = 2 + max(0, width - 4 - total)
      default: break
      }
      let baseSize = value.baseStyle.fontSize * scale
      let y = (height - baseSize) / 2 + baseSize * 0.2
      for segment in segments {
        guard let operand = segment.handle.operand(segment.text) else { continue }
        content += textShow(
          fontName: segment.handle.resourceName, size: segment.style.fontSize * scale,
          color: segment.style.color, x: x, y: y, operand: operand)
        x += segment.width * scale
      }
    }
    content += "Q\n"
    var resources: [PDFName: PDFValue] = [:]
    if !fontResources.isEmpty { resources[PDFName("Font")] = .dictionary(fontResources) }
    return (
      AnnotationSupport.formAppearance(
        rect: [0, 0, width, height], content: content, resources: resources), bounds
    )
  }

  static func textShow(
    fontName: PDFName, size: Double, color: [Double], x: Double, y: Double, operand: String
  ) -> String {
    let components = color.count == 3 ? color : [0, 0, 0]
    let colorOperator: String
    if components[0] == components[1], components[1] == components[2] {
      colorOperator = AnnotationSupport.number(components[0]) + " g"
    } else {
      colorOperator =
        components.map { AnnotationSupport.number($0) }.joined(separator: " ") + " rg"
    }
    return "BT /" + String(decoding: fontName.bytes, as: UTF8.self) + " "
      + AnnotationSupport.number(size) + " Tf " + colorOperator + " "
      + "1 0 0 1 " + AnnotationSupport.number(x) + " " + AnnotationSupport.number(y) + " Tm "
      + operand + " Tj ET\n"
  }

  static func handle(
    for style: FormRichTextStyle, base: FormAppearanceFontHandle,
    runFonts: [StandardTextFont: FormAppearanceFontHandle]
  ) -> FormAppearanceFontHandle {
    guard let font = style.font else { return base }
    if case .standard(let face) = font { return runFonts[face] ?? base }
    return base
  }

  static func measure(
    value: FormRichTextValue, base: FormAppearanceFontHandle,
    runFonts: [StandardTextFont: FormAppearanceFontHandle]
  ) -> [Segment] {
    let segments = (try? value.segments()) ?? []
    let string = value.plainText as NSString
    var result: [Segment] = []
    for segment in segments {
      guard segment.range.length > 0,
        segment.range.location + segment.range.length <= string.length
      else { continue }
      let text = string.substring(with: segment.range)
      let handle = handle(for: segment.style, base: base, runFonts: runFonts)
      let width = handle.fallbackWidth(text, size: segment.style.fontSize)
      if let last = result.last, last.handle == handle, last.style == segment.style {
        result[result.count - 1].text += text
        result[result.count - 1].width += width
      } else {
        result.append(Segment(text: text, handle: handle, style: segment.style, width: width))
      }
    }
    return result
  }

  /// Character-level wrapping; explicit newlines force a break.
  static func wrap(
    value: FormRichTextValue, available: Double, base: FormAppearanceFontHandle,
    runFonts: [StandardTextFont: FormAppearanceFontHandle]
  ) -> [[Segment]] {
    var lines: [[Segment]] = []
    var current: [Segment] = []
    var currentWidth = 0.0
    func flush() {
      lines.append(current)
      current = []
      currentWidth = 0
    }
    let segments = measure(value: value, base: base, runFonts: runFonts)
    for segment in segments {
      for character in segment.text {
        if character == "\n" {
          flush()
          continue
        }
        let text = String(character)
        let width = segment.handle.fallbackWidth(text, size: segment.style.fontSize)
        if currentWidth + width > available, currentWidth > 0 { flush() }
        if let last = current.last, last.handle == segment.handle, last.style == segment.style {
          current[current.count - 1].text += text
          current[current.count - 1].width += width
        } else {
          current.append(
            Segment(text: text, handle: segment.handle, style: segment.style, width: width))
        }
        currentWidth += width
      }
    }
    if !current.isEmpty || lines.isEmpty { lines.append(current) }
    return lines
  }
}

// MARK: - Fill / restyle command

/// FRM-05: write a rich text value with inherited appearance properties and an
/// embedded-font-capable appearance. One undoable command; no script involved.
public struct SetFormRichTextCommand: PDFEditCommand, Equatable, Sendable {
  public let fieldName: String
  public let value: FormRichTextValue

  public init(fieldName: String, value: FormRichTextValue) {
    self.fieldName = fieldName
    self.value = value
  }

  public var name: String { "Set Rich Form Text" }

  public func validate(in graph: PDFGraph) throws {
    let properties = try FormEffectivePropertiesReader.properties(
      forFieldNamed: fieldName, in: graph)
    try validate(properties: properties, in: graph)
  }

  func validate(properties: FormEffectiveFieldProperties, in graph: PDFGraph) throws {
    guard properties.kind == .text else {
      throw PDFError(.unsupported, "Rich text applies to text fields")
    }
    guard !properties.isReadOnly else {
      throw PDFError(.unsupported, "This form field is read-only")
    }
    guard !properties.widgetRects.isEmpty else {
      throw PDFError(.unsupported, "This text field has no widget to paint an appearance on")
    }
    _ = try value.validatedRuns()
    try validateStyles()
    if let maxLength = properties.maxLength, value.utf16Length > maxLength {
      throw PDFError(
        .malformed,
        "The text is longer than the field's maximum length of " + String(maxLength))
    }
    if properties.isComb, properties.maxLength == nil {
      throw PDFError(.unsupported, "Comb fields need /MaxLen before styled text can be written")
    }
    if properties.isComb, value.plainText.contains("\n") || value.plainText.contains("\r") {
      throw PDFError(.unsupported, "Comb field values cannot contain line breaks")
    }
    if !properties.isMultiline, value.plainText.contains("\n") || value.plainText.contains("\r") {
      throw PDFError(
        .unsupported, "The field is not multiline; remove line breaks or enable multiline")
    }
    let base = try validationBaseHandle(properties: properties, in: graph)
    let runFonts = try validationRunHandles()
    try validateEncodable(base: base, runFonts: runFonts)
    for rect in properties.widgetRects {
      let built = FormRichTextAppearance.build(
        value: value, rect: rect, multiline: properties.isMultiline, comb: properties.isComb,
        maxLength: properties.maxLength, alignment: properties.alignment, baseFont: base,
        runFonts: runFonts, fontResources: [:])
      if built.layout.overflowed {
        throw PDFError(
          .unsupported,
          "The styled text does not fit the field at the minimum appearance size; shorten the "
            + "value, enable multiline or enlarge the field")
      }
    }
  }

  func validateStyles() throws {
    for style in [value.baseStyle] + value.runs.map(\.style) {
      guard style.fontSize.isFinite, style.fontSize >= 4, style.fontSize <= 96 else {
        throw PDFError(.malformed, "Rich-text size must be within 4...96 points")
      }
      guard style.color.count == 3,
        style.color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
      else {
        throw PDFError(.malformed, "Rich-text color must be three components within 0...1")
      }
    }
    for run in value.runs {
      if case .embedded = run.style.font {
        throw PDFError(
          .unsupported,
          "Run-level embedded fonts are outside the declared profile; set the embedded font as "
            + "the field font and use bold/italic/size/color on selections")
      }
    }
  }

  func validationBaseHandle(
    properties: FormEffectiveFieldProperties, in graph: PDFGraph
  ) throws -> FormAppearanceFontHandle {
    switch value.baseStyle.font {
    case .standard(let face):
      return .standard(face: face, resourceName: PDFName(face.rawValue))
    case .embedded(let source):
      guard !value.plainText.isEmpty else {
        return .standard(face: .helvetica, resourceName: PDFName("Helvetica"))
      }
      return try FormRichTextFontSupport.previewHandle(source: source, covering: value.plainText)
    case nil:
      return try FormEffectivePropertiesReader.appearanceFont(for: properties, in: graph)
    }
  }

  /// Every segment must be encodable by the face that paints it; otherwise the
  /// writer would silently drop characters from the appearance.
  func validateEncodable(
    base: FormAppearanceFontHandle, runFonts: [StandardTextFont: FormAppearanceFontHandle]
  ) throws {
    let string = value.plainText as NSString
    for segment in try value.segments() {
      guard segment.range.length > 0,
        segment.range.location + segment.range.length <= string.length
      else { continue }
      let text = string.substring(with: segment.range)
      let handle: FormAppearanceFontHandle
      if let font = segment.style.font {
        switch font {
        case .standard(let face):
          handle = runFonts[face] ?? base
        case .embedded:
          handle = base
        }
      } else {
        handle = base
      }
      // Line separators are painted by the layout, not encoded as glyphs.
      for line in text.components(separatedBy: CharacterSet.newlines) where !line.isEmpty {
        guard handle.canEncode(line) else {
          throw PDFError(
            .unsupported,
            "The face " + handle.baseName + " cannot encode part of the field text; sPDF "
              + "refuses to substitute characters. Choose a font that covers the text.")
        }
      }
    }
  }

  func validationRunHandles() throws -> [StandardTextFont: FormAppearanceFontHandle] {
    var handles: [StandardTextFont: FormAppearanceFontHandle] = [:]
    for run in value.runs {
      guard case .standard(let face)? = run.style.font else { continue }
      let runText = (value.plainText as NSString).substring(with: run.range)
      guard StandardTextFont.canEncode(runText) else {
        throw PDFError(
          .unsupported,
          "The face " + face.rawValue + " cannot encode part of the styled text; sPDF refuses "
            + "to substitute characters")
      }
      handles[face] = .standard(face: face, resourceName: PDFName(face.rawValue))
    }
    if value.baseStyle.font == nil || !value.baseStyle.font!.isEmbedded {
      // Base text must be encodable by the effective base face.
    }
    return handles
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let properties = try FormEffectivePropertiesReader.properties(
      forFieldNamed: fieldName, in: graph)
    guard let field = try FormInventory.fields(in: graph, pageIDs: pageIDs)
      .first(where: { $0.name == fieldName }),
      let fieldID = field.fieldID,
      case .dictionary(var fieldDictionary)? = graph.objects[fieldID]
    else { throw PDFError(.malformed, "Form field is missing") }
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1

    // Base font: register an explicit embedded program or Standard face, or use
    // the inherited effective /DA font unchanged.
    let base: FormAppearanceFontHandle
    var fonts = properties.defaultResourceFonts
    switch value.baseStyle.font {
    case .standard(let face):
      let registered = try FormRichTextFontSupport.standardFont(
        face: face, fonts: &fonts, in: &graph, nextNumber: &nextNumber)
      base = registered
    case .embedded(let source):
      if value.plainText.isEmpty {
        base = try FormEffectivePropertiesReader.appearanceFont(for: properties, in: graph)
      } else {
        base = try FormAppearanceFonts.register(
          source: source, covering: value.plainText, in: &graph, ownerFieldID: fieldID)
        let registered = FormAppearanceFonts.formResourcesFonts(
          ownerFieldID: fieldID, in: graph)
        for (name, value) in registered { fonts[name] = value }
      }
    case nil:
      base = try FormEffectivePropertiesReader.appearanceFont(for: properties, in: graph)
      if fonts[base.resourceName] == nil {
        if case .standard(let face, let name) = base {
          // The inherited /DA names a Standard-14 face this writer has not
          // registered yet; register it under the same resource name.
          _ = try FormRichTextFontSupport.standardFont(
            face: face, fonts: &fonts, in: &graph, nextNumber: &nextNumber,
            preferredName: name)
        }
      }
    }

    // Run fonts: standard faces only (declared profile).
    var runFonts: [StandardTextFont: FormAppearanceFontHandle] = [:]
    for run in value.runs {
      guard case .standard(let face)? = run.style.font, runFonts[face] == nil else { continue }
      runFonts[face] = try FormRichTextFontSupport.standardFont(
        face: face, fonts: &fonts, in: &graph, nextNumber: &nextNumber)
    }

    // Persist the flattened inherited resources plus the appearance fonts.
    var resources: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = fieldDictionary[PDFName("DR")] { resources = existing }
    resources[PDFName("Font")] = .dictionary(fonts)
    fieldDictionary[PDFName("DR")] = .dictionary(resources)
    let color = value.baseStyle.color.count == 3 ? value.baseStyle.color : [0, 0, 0]
    fieldDictionary[PDFName("DA")] = .string(
      Data(
        ("/" + String(decoding: base.resourceName.bytes, as: UTF8.self) + " "
          + AnnotationSupport.number(value.baseStyle.fontSize) + " Tf "
          + color.map { AnnotationSupport.number($0) }.joined(separator: " ") + " rg").utf8))
    fieldDictionary[PDFName("V")] = .string(AnnotationText.encode(value.plainText))
    fieldDictionary[PDFName("RV")] = .string(Data(FormRichTextRTF.encode(value).utf8))
    fieldDictionary[PDFName("Ff")] = .integer(properties.flags | 33_554_432)
    graph.objects[fieldID] = .dictionary(fieldDictionary)

    var appearanceFonts: [PDFName: PDFValue] = [:]
    appearanceFonts[base.resourceName] = fonts[base.resourceName]
    for (_, handle) in runFonts { appearanceFonts[handle.resourceName] = fonts[handle.resourceName] }
    for widget in field.widgets {
      guard let widgetID = widget.objectID, let rect = widget.rect else { continue }
      let built = FormRichTextAppearance.build(
        value: value, rect: rect, multiline: properties.isMultiline, comb: properties.isComb,
        maxLength: properties.maxLength, alignment: properties.alignment, baseFont: base,
        runFonts: runFonts, fontResources: appearanceFonts)
      nextNumber = try SetFormTextCommand.installAppearance(
        built.stream, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
    }
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      var acroForm: [PDFName: PDFValue] = [:]
      if case .dictionary(let existing)? = catalog[PDFName("AcroForm")] { acroForm = existing }
      acroForm[PDFName("NeedAppearances")] = .boolean(false)
      catalog[PDFName("AcroForm")] = .dictionary(acroForm)
      graph.objects[catalogID] = .dictionary(catalog)
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return graph
  }
}

/// FRM-05: shared registration helpers for the rich text command.
enum FormRichTextFontSupport {
  static func standardFontID(
    face: StandardTextFont, in graph: inout PDFGraph, nextNumber: inout Int
  ) throws -> PDFObjectID {
    SetFormRichTextStyleCommand.standardFontID(
      named: face.rawValue, in: &graph, nextNumber: &nextNumber)
  }

  /// Ensure a Standard-14 face is registered in the field /DR fonts dictionary
  /// and return its handle. Names never collide with a different face.
  static func standardFont(
    face: StandardTextFont, fonts: inout [PDFName: PDFValue], in graph: inout PDFGraph,
    nextNumber: inout Int, preferredName: PDFName? = nil
  ) throws -> FormAppearanceFontHandle {
    let name = preferredName ?? PDFName(face.rawValue)
    if let existing = fonts[name], isSameFace(existing, face: face, in: graph) {
      return .standard(face: face, resourceName: name)
    }
    var chosen = name
    if fonts[chosen] != nil {
      var counter = 2
      while fonts[PDFName(face.rawValue + String(counter))] != nil { counter += 1 }
      chosen = PDFName(face.rawValue + String(counter))
    }
    let fontID = try standardFontID(face: face, in: &graph, nextNumber: &nextNumber)
    fonts[chosen] = .reference(fontID)
    return .standard(face: face, resourceName: chosen)
  }

  static func isSameFace(
    _ value: PDFValue, face: StandardTextFont, in graph: PDFGraph
  ) -> Bool {
    guard case .reference(let id) = value, case .dictionary(let font)? = graph.objects[id],
      font[PDFName("Subtype")] == .name(PDFName("Type1")),
      let baseName = font[PDFName("BaseFont")], case .name(let name) = baseName
    else { return false }
    return String(decoding: name.bytes, as: UTF8.self) == face.rawValue
  }

  /// A measurement-capable handle for an embedded program without mutating the
  /// graph: the writer output supplies the code map and widths.
  static func previewHandle(
    source: FormEmbeddedFontSource, covering text: String
  ) throws -> FormAppearanceFontHandle {
    let inspector = try TrueTypeInspector.inspect(source.program)
    guard !inspector.isCFF else {
      throw PDFError(
        .unsupported,
        "Form appearance font embedding currently supports TrueType outline programs")
    }
    guard inspector.permitsEditableSubsetEmbedding else {
      throw PDFError(
        .unsupported, "This font's embedding permissions do not allow embedding in a PDF form")
    }
    for scalar in Set(text.unicodeScalars.map({ Int($0.value) })) {
      guard inspector.unicodeToGlyph[scalar].map({ $0 > 0 }) == true else {
        throw PDFError(
          .unsupported,
          "The embedded font has no glyph for U+"
            + String(scalar, radix: 16, uppercase: true))
      }
    }
    let written = try CompositeFontWriter.write(
      program: source.program, baseName: source.sanitizedFamilyName, covering: text)
    var codes: [Int: [UInt8]] = [:]
    var widths: [Int: Double] = [:]
    for (scalar, cid) in written.encoding {
      codes[scalar] = written.codeByteLength == 2
        ? [UInt8((cid >> 8) & 0xFF), UInt8(cid & 0xFF)] : [UInt8(max(0, min(cid, 255)))]
      widths[cid] = Double(written.widths[cid] ?? 1000)
    }
    return .embedded(
      resourceName: PDFName("SPDFF1"), codes: codes, widths: widths,
      byteLength: written.codeByteLength, baseName: written.baseName)
  }
}
