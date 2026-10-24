import Foundation
import PDFCore

public enum StandardTextFont: String, CaseIterable, Sendable {
  case helvetica = "Helvetica"
  case helveticaBold = "Helvetica-Bold"
  case helveticaItalic = "Helvetica-Oblique"
  case helveticaBoldItalic = "Helvetica-BoldOblique"
  case times = "Times-Roman"
  case timesBold = "Times-Bold"
  case timesItalic = "Times-Italic"
  case timesBoldItalic = "Times-BoldItalic"
  case courier = "Courier"
  case courierBold = "Courier-Bold"
  case courierItalic = "Courier-Oblique"
  case courierBoldItalic = "Courier-BoldOblique"

  public var family: AddedTextStyle.Family {
    if rawValue.hasPrefix("Times") { return .times }
    if rawValue.hasPrefix("Courier") { return .courier }
    return .helvetica
  }
  public var isBold: Bool { rawValue.contains("Bold") }
  public var isItalic: Bool { rawValue.contains("Italic") || rawValue.contains("Oblique") }
  public static func face(family: AddedTextStyle.Family, bold: Bool, italic: Bool) -> Self {
    Self(rawValue: family.baseFont(bold: bold, italic: italic))!
  }
  public static func canEncode(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { scalar in
      if scalar == "\n" || scalar == "\r" { return true }
      if CharacterSet.controlCharacters.contains(scalar) { return false }
      guard let data = String(scalar).data(using: .windowsCP1252), data.count == 1 else {
        return false
      }
      return String(data: data, encoding: .windowsCP1252) == String(scalar)
    }
  }

  /// A familiar BaseFont name does not prove the source program or glyph
  /// metrics match a standard font. Keep customized fonts on their own path.
  public static func editableRunIndices(pageID: PDFObjectID, in graph: PDFGraph) throws -> [Int] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    guard
      case .dictionary(let fonts)? = (try AddedContent.pageResources(pageID: pageID, in: graph))?[
        PDFName("Font")]
    else { return [] }
    var canonical: [PDFName: Bool] = [:]
    for (resource, value) in fonts {
      let dictionary: [PDFName: PDFValue]?
      switch value {
      case .reference(let id):
        if case .dictionary(let resolved)? = graph.objects[id] {
          dictionary = resolved
        } else {
          dictionary = nil
        }
      case .dictionary(let direct): dictionary = direct
      default: dictionary = nil
      }
      guard let font = dictionary,
        font[PDFName("Subtype")] == .name(PDFName("Type1")),
        case .name(let base)? = font[PDFName("BaseFont")],
        Self(rawValue: String(decoding: base.bytes, as: UTF8.self)) != nil,
        font[PDFName("FontDescriptor")] == nil, font[PDFName("Widths")] == nil,
        font[PDFName("ToUnicode")] == nil
      else { continue }
      switch font[PDFName("Encoding")] {
      case nil: canonical[resource] = true
      case .name(let name)?:
        canonical[resource] = ["WinAnsiEncoding", "MacRomanEncoding", "StandardEncoding"]
          .contains(String(decoding: name.bytes, as: UTF8.self))
      default: break
      }
    }
    return runs.indices.filter {
      canonical[runs[$0].fontResource] == true && canEncode(runs[$0].text)
    }
  }
}

public struct PageTextFormat: Sendable, Equatable {
  public var font: StandardTextFont
  public var sourceFont: PageTextSourceFont?
  /// Horizontal PDF text-space shear used by synthetic italic source runs.
  /// Glyph x coordinates are shifted by this factor times their y coordinate.
  public var obliqueness: Double
  /// A user-provisioned, explicitly licensed font program for inline writing.
  /// Existing PDF fonts remain represented by `sourceFont` and are reused.
  public var customFont: CustomTextFont?
  public var characterSpacing: Double
  public var fontName: String { customFont?.faceName ?? sourceFont?.name ?? font.rawValue }
  /// A custom regular face has no weight axis in the PDF subset writer. Use a
  /// small text stroke to preserve a bold source face without changing its
  /// glyph advances.
  public var syntheticBoldStrokeWidth: Double {
    guard let customFont, font.isBold, !customFont.isBold, size.isFinite, size > 0 else { return 0 }
    return size * 0.04
  }
  public var size: Double
  public var color: [Double]
  public var opacity: Double
  public init(font: StandardTextFont = .helvetica, size: Double = 12, color: [Double] = [0, 0, 0],
    sourceFont: PageTextSourceFont? = nil, customFont: CustomTextFont? = nil,
    characterSpacing: Double = 0, opacity: Double = 1, obliqueness: Double = 0) {
    self.font = font
    self.sourceFont = sourceFont
    self.obliqueness = obliqueness
    self.customFont = customFont
    self.characterSpacing = characterSpacing
    self.size = size
    self.color = color
    self.opacity = opacity
  }
  public var isValid: Bool {
    size.isFinite && (2...144).contains(size) && characterSpacing.isFinite
      && abs(characterSpacing) <= 144 && color.count == 3
      && color.allSatisfy { $0.isFinite && (0...1).contains($0) }
      && obliqueness.isFinite && abs(obliqueness) <= 0.35
      && opacity.isFinite && (0...1).contains(opacity)
  }
}

public struct PageTextFragment: Sendable, Equatable {
  public let text: String
  public let format: PageTextFormat
  public init(text: String, format: PageTextFormat) {
    self.text = text
    self.format = format
  }
}

public struct PageTextSegment: Sendable, Equatable {
  public let text: String
  public let x: Double
  public let format: PageTextFormat
  public init(text: String, x: Double, format: PageTextFormat) {
    self.text = text
    self.x = x
    self.format = format
  }
}

public struct PageTextBox: Sendable, Equatable {
  public let x: Double
  public let firstBaseline: Double
  public let width: Double
  public let lineSpacing: Double
  public let wraps: Bool
  public init(
    x: Double, firstBaseline: Double, width: Double, lineSpacing: Double, wraps: Bool = true
  ) {
    self.x = x
    self.firstBaseline = firstBaseline
    self.width = width
    self.lineSpacing = lineSpacing
    self.wraps = wraps
  }
  var isValid: Bool {
    [x, firstBaseline, width, lineSpacing].allSatisfy(\.isFinite)
      && abs(x) <= 1_000_000 && abs(firstBaseline) <= 1_000_000
      && (24...2_000).contains(width) && lineSpacing > 0 && lineSpacing <= 1_000
  }
}

/// Authoring metadata retains geometry, paragraph breaks and their nonpainting
/// style. Painted text and styles come from actual PDF painting instructions.
public struct AuthoredPageTextBox: Sendable {
  public let box: PageTextBox
  public let lines: [PageTextLine]
  public let originalText: [Int: String]
  public var fragments: [PageTextFragment] {
    var result: [PageTextFragment] = []
    let fallback = lines.lazy.flatMap(\.segments).first?.format
    for (index, line) in lines.enumerated() {
      result += line.segments.map { PageTextFragment(text: $0.text, format: $0.format) }
      if line.endsParagraph,
        let format = line.breakFormat ?? line.segments.last?.format ?? fallback
      {
        result.append(.init(text: "\n", format: format))
      } else if box.wraps, index + 1 < lines.count, !line.text.hasSuffix("-"),
        line.text.last?.isWhitespace != true,
        let format = line.segments.last?.format ?? fallback
      {
        // A soft line break is a layout boundary, not a paragraph boundary.
        // Keep its separator in the editable string even though the PDF line
        // itself must not end in serialized whitespace.
        result.append(.init(text: " ", format: format))
      }
    }
    return result
  }
}

enum PageTextLineWriter {
  static func indexedPageFonts(
    page: [PDFName: PDFValue], in graph: PDFGraph
  ) -> [PDFName: IndexedTextFont] {
    guard case .dictionary(let resources)? = FontValue.resolve(
      page[PDFName("Resources")], in: graph),
      case .dictionary(let fontResources)? = FontValue.resolve(
        resources[PDFName("Font")], in: graph)
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: fontResources.keys.sorted().compactMap { resource in
      IndexedTextFont.resolve(resource: resource, page: page, in: graph)
        .map { (resource, $0) }
    })
  }

  static func validateFonts(_ lines: [PageTextLine], pageID: PDFObjectID, in graph: PDFGraph,
    fallbackWitnessText: String? = nil) throws {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Missing text page")
    }
    var pageFonts: [PDFName: IndexedTextFont] = [:]
    if fallbackWitnessText != nil {
      pageFonts = indexedPageFonts(page: page, in: graph)
    }
    for line in lines {
      for segment in line.segments {
        guard !(segment.format.sourceFont != nil && segment.format.customFont != nil) else {
          throw PDFError(.malformed, "A text run cannot select two font sources")
        }
        if let source = segment.format.sourceFont {
          guard let font = IndexedTextFont.resolve(resource: source.resource, page: page, in: graph),
            font.isInlineEditable, PageTextSourceFont.canWriteInline(segment.text) else {
            throw PDFError(.unsupported, "The embedded font does not contain these characters. Choose another font for them.")
          }
          let directlyEncoded: Bool = {
            guard let encoded = font.encode(segment.text), let glyphs = font.glyphs(encoded),
              glyphs.map(\.text).joined() == segment.text,
              let profile = font.profile else { return false }
            return glyphs.allSatisfy({ profile.glyphs[$0.text]?.codes == $0.codes })
          }()
          if !directlyEncoded {
            guard let fallbackWitnessText else {
              throw PDFError(.unsupported, "The embedded font does not contain these characters. Choose another font for them.")
            }
            for scalar in segment.text.unicodeScalars {
              guard Self.inlineGlyph(String(scalar), preferredResource: source.resource,
                preferredFont: font, sourceText: fallbackWitnessText,
                availableFonts: pageFonts) != nil else {
                throw PDFError(.unsupported, "The embedded font does not contain these characters. Choose another font for them.")
              }
            }
          }
        } else if let custom = segment.format.customFont {
          let inspector = try TrueTypeInspector.inspect(custom.program)
          guard !inspector.isCFF, inspector.permitsEditableSubsetEmbedding else {
            throw PDFError(.unsupported,
              "This font's embedding settings do not allow inline PDF writing")
          }
          let needed = Set(segment.text.unicodeScalars.map { Int($0.value) })
          let availability = try TrueTypeSubsetter.availability(
            program: custom.program, unicodes: needed)
          guard availability.missing.isEmpty,
            PageTextSourceFont.canWriteInline(segment.text) else {
            throw PDFError(.unsupported,
              "This licensed font does not contain every supported character in the selection.")
          }
        }
      }
    }
  }

  /// Resolve one printable scalar in the requested subset first, then reuse a
  /// same-face subset already referenced on the page only when shared source
  /// glyph widths provide evidence that it is metrically compatible.
  static func inlineGlyph(
    _ text: String, preferredResource: PDFName, preferredFont: IndexedTextFont,
    sourceText: String, availableFonts: [PDFName: IndexedTextFont]
  ) -> (resource: PDFName, glyph: IndexedTextFont.Glyph)? {
    func encodedGlyph(_ font: IndexedTextFont) -> IndexedTextFont.Glyph? {
      guard let codes = font.encode(text), let glyphs = font.glyphs(codes),
        glyphs.count == 1, glyphs[0].text == text
      else { return nil }
      if let profile = font.profile {
        guard font.sourceGlyphsMatchProfile(glyphs, profile: profile) else { return nil }
      } else if font.hasEmbeddedProgram {
        return nil
      }
      return glyphs[0]
    }

    if let glyph = encodedGlyph(preferredFont) {
      return (preferredResource, glyph)
    }
    for resource in availableFonts.keys.sorted() where resource != preferredResource {
      guard let candidate = availableFonts[resource], candidate.isInlineEditable,
        normalizedEmbeddedFace(candidate.baseFont)
          == normalizedEmbeddedFace(preferredFont.baseFont),
        hasMatchingSharedGlyphMetrics(
          source: preferredFont, candidate: candidate, sourceText: sourceText),
        let glyph = encodedGlyph(candidate),
        let width = glyph.width, width.isFinite, width >= 0
      else { continue }
      return (resource, glyph)
    }
    return nil
  }

  static func normalizedEmbeddedFace(_ baseFont: String) -> String {
    PageTextFontCapability.normalizedEmbeddedFace(baseFont)
  }

  static func hasMatchingSharedGlyphMetrics(
    source: IndexedTextFont, candidate: IndexedTextFont, sourceText: String
  ) -> Bool {
    let sourceProfile = source.profile
    let candidateProfile = candidate.profile
    guard (!source.hasEmbeddedProgram || sourceProfile != nil),
      (!candidate.hasEmbeddedProgram || candidateProfile != nil)
    else { return false }
    guard let sourceProfile, let candidateProfile else { return false }
    return PageTextFontCapability.canUseSubset(
      source: sourceProfile, candidate: candidateProfile, witnessText: sourceText)
  }
  static func originalContent(pageID: PDFObjectID, in graph: PDFGraph) throws -> PageContent {
    let content = try PageContent.load(pageID: pageID, in: graph)
    guard content.segments.allSatisfy(\.isEditable),
      Set(content.segments.map(\.objectID)).count == content.segments.count
    else {
      throw PDFError(.unsupported, "This page repeats streams or uses unsupported content filters")
    }
    var depth = 0
    var inText = false
    for instruction in content.instructions {
      switch instruction.operatorName {
      case "q": depth += 1
      case "Q":
        depth -= 1
        guard depth >= 0 else { throw PDFError(.unsupported, "Unbalanced page graphics state") }
      case "BT":
        guard !inText else { throw PDFError(.unsupported, "Nested page text objects") }
        inText = true
      case "ET":
        guard inText else { throw PDFError(.unsupported, "Unbalanced page text objects") }
        inText = false
      default: break
      }
    }
    guard depth == 0, !inText else {
      throw PDFError(.unsupported, "Unbalanced page content cannot receive inline text")
    }
    return content
  }

  static func validate(_ lines: [PageTextLine], box: PageTextBox?) throws {
    guard lines.count <= 4_000,
      lines.reduce(0, { $0 + max(1, $1.segments.count) }) <= 500,
      box == nil || box!.isValid
    else {
      throw PDFError(.malformed, "Invalid text box geometry")
    }
    for line in lines {
      guard line.breakFormat == nil || (line.endsParagraph && line.breakFormat!.isValid) else {
        throw PDFError(.malformed, "Invalid paragraph break style")
      }
      guard line.breakFormat.map({ !($0.sourceFont != nil && $0.customFont != nil) }) ?? true else {
        throw PDFError(.malformed, "A paragraph break cannot select two font sources")
      }
      guard line.x.isFinite, line.baseline.isFinite,
        abs(line.x) <= 1_000_000, abs(line.baseline) <= 1_000_000
      else {
        throw PDFError(.malformed, "Invalid text line position")
      }
      if let box {
        guard abs(line.x - box.x) < 0.005 else {
          throw PDFError(.malformed, "Text line does not match its box")
        }
      }
      if !line.segments.isEmpty {
        guard line.segments.map(\.text).joined() == line.text,
          line.segments.allSatisfy({
            $0.x.isFinite && abs($0.x) <= 1_000_000 && $0.format.isValid
              && !$0.text.contains("\n") && !$0.text.contains("\r")
              && !($0.format.sourceFont != nil && $0.format.customFont != nil)
              && ($0.format.sourceFont != nil || $0.format.customFont != nil
                || StandardTextFont.canEncode($0.text))
          })
        else {
          throw PDFError(.unsupported, "The selected PDF font cannot encode these characters")
        }
      }
    }
    if let box, let first = lines.first {
      guard abs(first.baseline - box.firstBaseline) < 0.005 else {
        throw PDFError(.malformed, "Text baseline does not match its box")
      }
    }
  }

  static func append(
    _ lines: [PageTextLine], box: PageTextBox?, pageID: PDFObjectID,
    defaultFont: IndexedTextFont?, defaultSize: Double, defaultColor: [Double],
    defaultOpacity: Double = 1, clippingRect: [Double]? = nil, in graph: inout PDFGraph
  ) throws {
    try validate(lines, box: box)
    let fallbackWitnessText = lines.map(\.text).joined()
    try validateFonts(lines, pageID: pageID, in: graph,
      fallbackWitnessText: fallbackWitnessText)
    guard defaultOpacity.isFinite, (0...1).contains(defaultOpacity) else {
      throw PDFError(.malformed, "Invalid paragraph opacity")
    }
    // q/Q does not save the current path. Discard any unpainted source
    // path before constructing our own clip, or it could enlarge that clip.
    var bytes = Array("q\nn\n".utf8)
    var opacityNames: [Double: PDFName] = [:]
    func registerOpacity(_ opacity: Double) throws -> PDFName? {
      guard opacity < 0.999 else { return nil }
      guard opacity.isFinite, (0...1).contains(opacity) else {
        throw PDFError(.malformed, "Invalid paragraph opacity")
      }
      if let existing = opacityNames[opacity] { return existing }
      guard let name = try AddedContent.registerOpacity(
        opacity, pageID: pageID, in: &graph) else { return nil }
      opacityNames[opacity] = name
      return name
    }
    if let rect = clippingRect {
      guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > rect[0], rect[3] > rect[1] else {
        throw PDFError(.malformed, "Invalid paragraph clipping region")
      }
      bytes += Array(([rect[0], rect[1], rect[2] - rect[0], rect[3] - rect[1]]
        .map(AnnotationSupport.number).joined(separator: " ") + " re W n\n").utf8)
    }
    bytes += Array("BT\n0 Tc 0 Tw 100 Tz 0 Ts 0 Tr\n".utf8)
    var lineRecords: [PDFValue] = []
    var customFontResources: [String: PDFName] = [:]
    for line in lines {
      var count = 0
      if line.segments.isEmpty, !line.text.isEmpty, let font = defaultFont,
        let codes = font.encode(line.text)
      {
        try emit(
          codes, x: line.x, baseline: line.baseline, resource: font.resource,
          size: defaultSize, color: defaultColor,
          opacityName: try registerOpacity(defaultOpacity), to: &bytes)
        count = 1
      } else {
        for segment in line.segments where !segment.text.isEmpty {
          let face = segment.format.font
          if let source = segment.format.sourceFont {
            guard case .dictionary(let page)? = graph.objects[pageID],
              let preferredFont = IndexedTextFont.resolve(
                resource: source.resource, page: page, in: graph),
              preferredFont.isInlineEditable
            else {
              throw PDFError(.unsupported,
                "The embedded font does not contain these characters. Choose another font for them.")
            }
            let opacityName = try registerOpacity(segment.format.opacity)
            if let codes = preferredFont.encode(segment.text),
              let glyphs = preferredFont.glyphs(codes),
              glyphs.map(\.text).joined() == segment.text,
              let profile = preferredFont.profile,
              preferredFont.sourceGlyphsMatchProfile(glyphs, profile: profile)
            {
              try emit(
                codes, x: segment.x, baseline: line.baseline, resource: source.resource,
                size: segment.format.size, color: segment.format.color,
                spacing: segment.format.characterSpacing, opacityName: opacityName,
                obliqueness: segment.format.obliqueness,
                syntheticBoldStrokeWidth: segment.format.syntheticBoldStrokeWidth, to: &bytes)
              count += 1
            } else {
              let availableFonts = indexedPageFonts(page: page, in: graph)
              var groupResource: PDFName?
              var groupCodes: [UInt8] = []
              var groupX = segment.x
              var pagePen = segment.x
              func emitGroup() throws {
                guard let resource = groupResource, !groupCodes.isEmpty else { return }
                try emit(
                  groupCodes, x: groupX, baseline: line.baseline, resource: resource,
                  size: segment.format.size, color: segment.format.color,
                  spacing: segment.format.characterSpacing, opacityName: opacityName,
                  obliqueness: segment.format.obliqueness,
                  syntheticBoldStrokeWidth: segment.format.syntheticBoldStrokeWidth,
                  to: &bytes)
                count += 1
                groupCodes.removeAll(keepingCapacity: true)
              }
              for scalar in segment.text.unicodeScalars {
                let text = String(scalar)
                guard let resolved = inlineGlyph(text, preferredResource: source.resource,
                  preferredFont: preferredFont, sourceText: fallbackWitnessText,
                  availableFonts: availableFonts),
                  let width = resolved.glyph.width, width.isFinite, width >= 0
                else {
                  throw PDFError(.unsupported,
                    "The embedded font does not contain these characters. Choose another font for them.")
                }
                if groupResource != resolved.resource {
                  try emitGroup()
                  groupResource = resolved.resource
                  groupX = pagePen
                }
                groupCodes += resolved.glyph.codes
                pagePen += width * segment.format.size / 1_000
                  + segment.format.characterSpacing
                guard pagePen.isFinite else {
                  throw PDFError(.unsupported, "The paragraph glyph advances are invalid")
                }
              }
              try emitGroup()
            }
          } else {
            let resource: PDFName
            if let custom = segment.format.customFont {
              resource = try AddedContent.selectFont(
                style: AddedTextStyle(family: face.family, bold: face.isBold,
                  italic: face.isItalic, size: segment.format.size),
                custom: custom, covering: segment.text, pageID: pageID, in: &graph).resourceName
              customFontResources[custom.identifier] = resource
            } else {
              resource = try AddedContent.registerStandardFont(
                family: face.family, bold: face.isBold, italic: face.isItalic, pageID: pageID,
                in: &graph)
            }
            guard case .dictionary(let page)? = graph.objects[pageID],
              let font = IndexedTextFont.resolve(resource: resource, page: page, in: graph),
              font.isInlineEditable,
              let codes = font.encode(segment.text)
            else { throw PDFError(.unsupported, "The selected font cannot encode these characters") }
            try emit(
              codes, x: segment.x, baseline: line.baseline, resource: resource,
              size: segment.format.size, color: segment.format.color,
              spacing: segment.format.characterSpacing,
              opacityName: try registerOpacity(segment.format.opacity),
              obliqueness: segment.format.obliqueness,
              syntheticBoldStrokeWidth: segment.format.syntheticBoldStrokeWidth, to: &bytes)
            count += 1
          }
        }
      }
      let breakStyle: PDFValue
      if let format = line.breakFormat {
        var resource = format.sourceFont?.resource
        if resource == nil, let custom = format.customFont {
          resource = customFontResources[custom.identifier]
        }
        if format.customFont != nil && resource == nil {
          breakStyle = .null
        } else {
          breakStyle = .array([
            .name(PDFName(format.font.rawValue)), .real(format.size),
            .array(format.color.map { .real($0) }), resource.map { .name($0) } ?? .null,
            .real(format.characterSpacing),
          ])
        }
      } else {
        breakStyle = .null
      }
      lineRecords.append(
        .array([
          .integer(Int64(count)), .boolean(line.endsParagraph),
          .real(line.x), .real(line.baseline), breakStyle,
        ]))
    }
    bytes += Array("ET\nQ\n".utf8)
    try AddedContent.append(
      String(decoding: bytes, as: UTF8.self), pageID: pageID, toFront: true, in: &graph)
    let streamID: PDFObjectID? = {
      guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
      switch page[PDFName("Contents")] {
      case .reference(let id)?: return id
      case .array(let values)?:
        if case .reference(let id)? = values.last { return id }
        return nil
      default: return nil
      }
    }()
    if let box, let id = streamID,
      case .stream(let stream)? = graph.objects[id]
    {
      var dictionary = stream.dictionary
      dictionary[PDFName("SPDFTextVersion")] = .integer(1)
      dictionary[PDFName("SPDFTextBox")] = .array([
        .real(box.x), .real(box.firstBaseline), .real(box.width), .real(box.lineSpacing),
        .boolean(box.wraps),
      ])
      dictionary[PDFName("SPDFTextLines")] = .array(lineRecords)
      graph.objects[id] = .stream(PDFStream(dictionary: dictionary, bytes: stream.bytes))
    }
  }

  private static func emit(
    _ codes: [UInt8], x: Double, baseline: Double, resource: PDFName,
    size: Double, color: [Double], spacing: Double = 0, opacityName: PDFName? = nil,
    obliqueness: Double = 0,
    syntheticBoldStrokeWidth: Double = 0,
    to bytes: inout [UInt8]
  ) throws {
    if let opacityName {
      bytes += Array("/\(String(decoding: opacityName.bytes, as: UTF8.self)) gs\n".utf8)
    }
    bytes += Array("\(AnnotationSupport.number(spacing)) Tc\n".utf8)
    bytes += Array(try PDFWriter.serializedValue(.name(resource)))
    bytes += Array(" \(AnnotationSupport.number(size)) Tf\n".utf8)
    let colorOperands = color.map(AnnotationSupport.number).joined(separator: " ")
    bytes += Array((colorOperands + " rg\n").utf8)
    if syntheticBoldStrokeWidth > 0 {
      bytes += Array((colorOperands + " RG\n1 j\n"
        + AnnotationSupport.number(syntheticBoldStrokeWidth) + " w\n2 Tr\n").utf8)
    }
    bytes += Array(
      "1 0 \(AnnotationSupport.number(obliqueness)) 1 \(AnnotationSupport.number(x)) \(AnnotationSupport.number(baseline)) Tm\n".utf8)
    bytes += ReplaceTextCommand.literalStringBytes(codes)
    bytes += Array(" Tj\n".utf8)
    if syntheticBoldStrokeWidth > 0 { bytes += Array("0 Tr\n".utf8) }
  }
}

public enum AuthoredPageTextBoxes {
  /// Metadata is a hint, never authority to bypass the normal edit checks.
  /// Every current string, style and position is resolved from page content.
  public static func read(pageID: PDFObjectID, in graph: PDFGraph) throws -> [AuthoredPageTextBox] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let allRuns = try TextRunIndexer.runs(in: content, graph: graph)
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: graph)
    let standard = Set(try StandardTextFont.editableRunIndices(pageID: pageID, in: graph)
      .map { allRuns[$0].fontResource })
    func number(_ value: PDFValue) -> Double? {
      switch value {
      case .real(let n): return n
      case .integer(let n): return Double(n)
      default: return nil
      }
    }
    var boxes: [AuthoredPageTextBox] = []
    for (segmentIndex, segment) in content.segments.enumerated() {
      let dictionary = segment.dictionary
      guard dictionary[PDFName("SPDFAdded")] == .boolean(true),
        dictionary[PDFName("SPDFTextVersion")] == .integer(1),
        case .array(let geometry)? = dictionary[PDFName("SPDFTextBox")], geometry.count == 5,
        let x = number(geometry[0]), let baseline = number(geometry[1]),
        let width = number(geometry[2]), let spacing = number(geometry[3]),
        case .boolean(let wraps) = geometry[4],
        case .array(let records)? = dictionary[PDFName("SPDFTextLines")], records.count <= 4_000
      else { continue }
      let box = PageTextBox(
        x: x, firstBaseline: baseline, width: width, lineSpacing: spacing, wraps: wraps)
      guard box.isValid else { continue }
      let indices = allRuns.indices.filter {
        content.segmentIndex(for: allRuns[$0].stringSpan) == segmentIndex
      }
      guard !indices.isEmpty else { continue }
      var cursor = 0
      var lines: [PageTextLine] = []
      var original: [Int: String] = [:]
      var valid = true
      for record in records {
        guard case .array(let fields) = record, (4...5).contains(fields.count),
          case .integer(let count) = fields[0], count >= 0, count <= 4_000,
          case .boolean(let hard) = fields[1], let lineX = number(fields[2]),
          let lineY = number(fields[3]), lineX.isFinite, lineY.isFinite,
          abs(lineX - box.x) < 0.005, abs(lineY) <= 1_000_000,
          cursor + Int(count) <= indices.count
        else {
          valid = false
          break
        }
        var breakFormat: PageTextFormat?
        if fields.count == 5, fields[4] != .null {
          guard hard, case .array(let style) = fields[4], [3, 5].contains(style.count),
            case .name(let name) = style[0],
            let font = StandardTextFont(rawValue: String(decoding: name.bytes, as: UTF8.self)),
            let size = number(style[1]), case .array(let components) = style[2],
            components.count == 3
          else {
            valid = false
            break
          }
          var format = PageTextFormat(font: font, size: size, color: components.compactMap(number))
          if style.count == 5 {
            guard let spacing = number(style[4]) else { valid = false; break }
            format.characterSpacing = spacing
            if case .name(let resource) = style[3],
              case .dictionary(let page)? = graph.objects[pageID],
              let source = IndexedTextFont.resolve(resource: resource, page: page, in: graph)?.profile?.source {
              format.sourceFont = source
            } else if style[3] != .null { valid = false; break }
          }
          guard format.isValid else {
            valid = false
            break
          }
          breakFormat = format
        }
        var segments: [PageTextSegment] = []
        for index in indices[cursor..<(cursor + Int(count))] {
          let run = allRuns[index]
          let style = TextEditTargeting.inputStyle(runIndex: index, runs: allRuns, in: graph)
          guard let family = style.fontFamily,
            let format = PageTextEditing.format(for: run, family: family, pageID: pageID, in: graph,
              standard: standard, profiles: profiles),
            abs(run.baselineY - lineY) < 0.002
          else {
            valid = false
            break
          }
          original[index] = run.text
          segments.append(
            .init(
              text: run.text, x: run.baselineX,
              format: format))
        }
        cursor += Int(count)
        if let first = segments.first, abs(first.x - lineX) >= 0.005 { valid = false }
        lines.append(
          .init(
            text: segments.map(\.text).joined(), x: lineX, baseline: lineY,
            segments: segments, endsParagraph: hard, breakFormat: breakFormat))
      }
      guard valid, cursor == indices.count, let first = lines.first,
        abs(first.baseline - box.firstBaseline) < 0.005
      else { continue }
      // Fonts without /Widths are verified by the platform when editing.
      // Reading metadata still checks instruction/transform identity below.
      guard
        original.keys.allSatisfy({ index in
          let run = allRuns[index]
          return content.instructions[run.instructionIndex].operatorName == "Tj"
            && TextCanvasSupport.inlineObliqueness(
              for: TextCanvasSupport.concatenate(run.ctm, run.matrix)) != nil
        })
      else { continue }
      boxes.append(.init(box: box, lines: lines, originalText: original))
    }
    return boxes
  }
}

public struct AddPageTextLinesCommand: PDFEditCommand, Sendable, Equatable {
  public let pageID: PDFObjectID
  public let lines: [PageTextLine]
  public let box: PageTextBox
  public init(pageID: PDFObjectID, lines: [PageTextLine], box: PageTextBox) {
    self.pageID = pageID
    self.lines = lines
    self.box = box
  }
  public var name: String { "Add Text" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public func validate(in graph: PDFGraph) throws {
    guard try PDFPageTree.pageIDs(in: graph).contains(pageID),
      lines.allSatisfy({ $0.text.isEmpty || !$0.segments.isEmpty })
    else { throw PDFError(.malformed, "Missing text page or formatted lines") }
    try PageTextLineWriter.validate(lines, box: box)
    try PageTextLineWriter.validateFonts(lines, pageID: pageID, in: graph)
    _ = try PageTextLineWriter.originalContent(pageID: pageID, in: graph)
  }
  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    var result = try PageContentCopy.makePrivate(pageID: pageID, in: graph)
    let content = try PageTextLineWriter.originalContent(pageID: pageID, in: result)
    // PDF content streams share graphics state. Restore the initial page CTM,
    // clipping and alpha before painting the native editor's page positions.
    if !content.segments.isEmpty {
      let ranges: [(range: Range<Int>, replacement: [UInt8])] = [
        (range: 0..<0, replacement: Array("q\n".utf8)),
        (range: content.bytes.count..<content.bytes.count, replacement: Array("\nQ\n".utf8)),
      ]
      for index in content.segments.indices {
        let local = ranges.filter { content.segmentIndex(for: $0.range) == index }
        result = try content.replacing(ranges: local, in: result)
      }
    }
    try PageTextLineWriter.append(
      lines, box: box, pageID: pageID,
      defaultFont: nil, defaultSize: 12, defaultColor: [0, 0, 0], in: &result)
    return result
  }
}
