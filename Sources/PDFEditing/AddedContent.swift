import Foundation
import PDFCore

/// P21: app-created content inserted as real page content (never annotations
/// unless a caller asks for one). Text uses standard-14 fonts with WinAnsi
/// encoding — no embedding and no redistribution question — and everything is
/// appended as balanced content blocks with registered resources.
public struct AddedTextStyle: Sendable, Equatable {
  public enum Family: String, Sendable, Equatable {
    case helvetica
    case times
    case courier

    var baseFont: String {
      switch self {
      case .helvetica: return "Helvetica"
      case .times: return "Times-Roman"
      case .courier: return "Courier"
      }
    }

    func baseFont(bold: Bool, italic: Bool) -> String {
      switch (self, bold, italic) {
      case (.helvetica, true, _): return "Helvetica-Bold"
      case (.helvetica, _, true): return "Helvetica-Oblique"
      case (.times, true, _): return "Times-Bold"
      case (.times, _, true): return "Times-Italic"
      case (.courier, true, _): return "Courier-Bold"
      case (.courier, _, true): return "Courier-Oblique"
      default: return baseFont
      }
    }
  }

  public var family: Family
  public var bold: Bool
  public var italic: Bool
  public var size: Double
  /// RGB 0...1.
  public var color: [Double]
  public var alignment: TextParagraphCandidate.Alignment
  /// Line spacing multiplier applied to the size.
  public var lineSpacing: Double
  /// 0...1; values below 1 register an ExtGState.
  public var opacity: Double

  public init(
    family: Family = .helvetica, bold: Bool = false, italic: Bool = false, size: Double = 12,
    color: [Double] = [0, 0, 0], alignment: TextParagraphCandidate.Alignment = .left,
    lineSpacing: Double = 1.2, opacity: Double = 1
  ) {
    self.family = family
    self.bold = bold
    self.italic = italic
    self.size = size
    self.color = color
    self.alignment = alignment
    self.lineSpacing = lineSpacing
    self.opacity = opacity
  }
}

public struct AddedShapeStyle: Sendable, Equatable {
  /// RGB 0...1; nil draws no stroke.
  public var strokeColor: [Double]?
  /// RGB 0...1; nil fills nothing.
  public var fillColor: [Double]?
  public var lineWidth: Double
  /// Dash pattern in points; empty is solid.
  public var dash: [Double]
  public var opacity: Double

  public init(
    strokeColor: [Double]? = [0, 0, 0], fillColor: [Double]? = nil, lineWidth: Double = 1,
    dash: [Double] = [], opacity: Double = 1
  ) {
    self.strokeColor = strokeColor
    self.fillColor = fillColor
    self.lineWidth = lineWidth
    self.dash = dash
    self.opacity = opacity
  }
}

public enum AddedShape: Sendable, Equatable {
  case rectangle([Double])
  case ellipse([Double])
  case polygon([[Double]])
  case line(from: [Double], to: [Double])
  case path([[Double]], closed: Bool)

  var bounds: [Double] {
    switch self {
    case .rectangle(let rect), .ellipse(let rect):
      return rect
    case .polygon(let points), .path(let points, _):
      guard !points.isEmpty else { return [0, 0, 0, 0] }
      return [
        points.map { $0[0] }.min() ?? 0, points.map { $0[1] }.min() ?? 0,
        points.map { $0[0] }.max() ?? 0, points.map { $0[1] }.max() ?? 0,
      ]
    case .line(let from, let to):
      return [min(from[0], to[0]), min(from[1], to[1]), max(from[0], to[0]), max(from[1], to[1])]
    }
  }
}

/// P21-016–P21-019: repeated page marks (watermark, header, footer, page
/// number, Bates numbering).
public enum RepeatedMark: Sendable, Equatable {
  case watermark(text: String, style: AddedTextStyle, angle: Double)
  case header(text: String, style: AddedTextStyle)
  case footer(text: String, style: AddedTextStyle)
  /// `{page}` and `{pages}` are replaced with physical indices; `offset` is
  /// added to the physical page number.
  case pageNumber(text: String, style: AddedTextStyle, offset: Int)
  case bates(prefix: String, start: Int, digits: Int, style: AddedTextStyle)

  var style: AddedTextStyle {
    switch self {
    case .watermark(_, let style, _), .header(_, let style), .footer(_, let style),
      .pageNumber(_, let style, _), .bates(_, _, _, let style):
      return style
    }
  }

  func text(pageIndex: Int, pageCount: Int) -> String {
    switch self {
    case .watermark(let text, _, _), .header(let text, _), .footer(let text, _):
      return text
    case .pageNumber(let text, _, let offset):
      let number = pageIndex + 1 + offset
      return
        text.replacingOccurrences(of: "{page}", with: String(number))
        .replacingOccurrences(of: "{pages}", with: String(pageCount))
    case .bates(let prefix, let start, let digits, _):
      let number = start + pageIndex
      return prefix + String(format: "%0\(max(1, digits))d", number)
    }
  }
}

/// P21-020: a preview of a repeated-mark operation before it is committed.
public struct RepeatedMarkPlan: Sendable, Equatable {
  public struct PagePreview: Sendable, Equatable {
    public let pageIndex: Int
    public let text: String
    public let bounds: [Double]
    public let content: String
  }

  public let mark: RepeatedMark
  public let pages: [PagePreview]

  public var summary: String {
    "\(markName) on \(pages.count) page\(pages.count == 1 ? "" : "s")"
  }

  var markName: String {
    switch mark {
    case .watermark: return "watermark"
    case .header: return "header"
    case .footer: return "footer"
    case .pageNumber: return "page number"
    case .bates: return "Bates numbering"
    }
  }
}

public enum AddedContent {
  /// P21-013: snap a point to nearby guides within a tolerance.
  public static func snap(
    _ point: [Double], toGuides guides: [[Double]], tolerance: Double = 6
  ) -> [Double] {
    var result = point
    for guide in guides {
      guard guide.count == 2 else { continue }
      if abs(guide[0] - result[0]) <= tolerance { result[0] = guide[0] }
      if abs(guide[1] - result[1]) <= tolerance { result[1] = guide[1] }
    }
    return result
  }

  /// P21-012: align a set of rectangles. `mode` is left/center/right or
  /// top/middle/bottom.
  public static func align(
    _ rects: [[Double]], mode: TextParagraphCandidate.Alignment
  ) -> [[Double]] {
    guard !rects.isEmpty else { return [] }
    switch mode {
    case .left:
      let target = rects.map { $0[0] }.min() ?? 0
      return rects.map { [$0[0] + (target - $0[0]), $0[1], $0[2] + (target - $0[0]), $0[3]] }
    case .center:
      let target = rects.map { ($0[0] + $0[2]) / 2 }.reduce(0, +) / Double(rects.count)
      return rects.map {
        let shift = target - ($0[0] + $0[2]) / 2
        return [$0[0] + shift, $0[1], $0[2] + shift, $0[3]]
      }
    case .right:
      let target = rects.map { $0[2] }.max() ?? 0
      return rects.map { [$0[0] + (target - $0[2]), $0[1], $0[2] + (target - $0[2]), $0[3]] }
    case .justified:
      return rects
    }
  }

  /// P21-021: a font resource name that does not collide with existing names.
  /// P18-017: `resourceOwner` selects the dictionary that owns /Resources
  /// (a page by default, or a form XObject for form-local writing).
  static func registerStandardFont(
    family: AddedTextStyle.Family, bold: Bool, italic: Bool, pageID: PDFObjectID,
    in graph: inout PDFGraph, resourceOwner: PDFObjectID? = nil
  ) throws -> PDFName {
    let owner = resourceOwner ?? pageID
    let base = family.baseFont(bold: bold, italic: italic)
    var existing: Set<String> = []
    if let resources = try pageResources(pageID: owner, in: graph),
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    {
      existing = Set(fonts.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
    }
    // Reuse an identical standard font when one is already registered.
    if case .dictionary(let fonts)? = (try pageResources(pageID: owner, in: graph))?[
      PDFName("Font")],
      !fonts.isEmpty
    {
      for (name, value) in fonts {
        guard case .reference(let id) = value,
          case .dictionary(let dictionary)? = graph.objects[id],
          case .name(let baseFont)? = dictionary[PDFName("BaseFont")],
          String(decoding: baseFont.bytes, as: UTF8.self) == base,
          // Only reuse a font with the WinAnsi encoding this writer needs;
          // an existing StandardEncoding resource cannot carry accents.
          dictionary[PDFName("Encoding")] == .name(PDFName("WinAnsiEncoding"))
        else { continue }
        return name
      }
    }
    let name = try uniqueFontName(
      prefix: "SPDFF", pageID: pageID, in: graph, resourceOwner: resourceOwner)
    let fontID = nextObjectID(in: graph)
    graph.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName(base)),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    try addResources(
      [name: .reference(fontID)], kind: "Font", pageID: pageID, in: &graph,
      resourceOwner: resourceOwner)
    return name
  }

  /// P15-021: a font resource name with the given prefix that does not
  /// collide with existing names on the page (or the owning form when
  /// `resourceOwner` is set; see registerStandardFont).
  static func uniqueFontName(
    prefix: String, pageID: PDFObjectID, in graph: PDFGraph,
    resourceOwner: PDFObjectID? = nil
  ) throws -> PDFName {
    let owner = resourceOwner ?? pageID
    var existing: Set<String> = []
    if let resources = try pageResources(pageID: owner, in: graph),
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    {
      existing = Set(fonts.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
    }
    var counter = 1
    var name = PDFName("\(prefix)\(counter)")
    while existing.contains(String(decoding: name.bytes, as: UTF8.self)) {
      counter += 1
      guard counter < 10_000 else {
        throw PDFError(.limitExceeded, "No free font resource name remains")
      }
      name = PDFName("\(prefix)\(counter)")
    }
    return name
  }

  /// P15-007/P15-022: reuse an embedded subset whose file bytes are
  /// identical and whose ToUnicode map already covers every needed scalar.
  /// Byte identity (not the subset tag) decides: the subsetter is
  /// deterministic, so equal coverage means equal bytes. Returns nil when
  /// no registered font qualifies (a subset is embedded).
  static func reuseEmbeddedFont(
    subset: Data, covering needed: Set<Int>, pageID: PDFObjectID, in graph: PDFGraph,
    resourceOwner: PDFObjectID? = nil
  ) throws -> WritableTextFont? {
    let owner = resourceOwner ?? pageID
    guard case .dictionary(let fonts)? = (try pageResources(pageID: owner, in: graph))?[
      PDFName("Font")]
    else { return nil }
    for (name, value) in fonts {
      guard case .reference(let id) = value,
        case .dictionary(let font)? = graph.objects[id],
        font[PDFName("Subtype")] == .name(PDFName("TrueType")),
        case .reference(let descriptorID)? = font[PDFName("FontDescriptor")],
        case .dictionary(let descriptor)? = graph.objects[descriptorID],
        case .reference(let fileID)? = descriptor[PDFName("FontFile2")],
        case .stream(let file)? = graph.objects[fileID],
        file.bytes == subset,
        case .reference(let cmapID)? = font[PDFName("ToUnicode")],
        case .stream(let cmap)? = graph.objects[cmapID],
        let toUnicode = ToUnicodeCMap(stream: cmap)
      else { continue }
      var covered: Set<Int> = []
      for code in UInt8.min...UInt8.max {
        if let text = toUnicode.decode(code), text.unicodeScalars.count == 1 {
          covered.insert(Int(text.unicodeScalars.first!.value))
        }
      }
      if needed.isSubset(of: covered) {
        // Rebuild the writer view from the registered objects.
        guard case .array(let widths)? = font[PDFName("Widths")],
          case .integer(let first)? = font[PDFName("FirstChar")]
        else { continue }
        var encoding: [UInt8: Int] = [:]
        for code in UInt8.min...UInt8.max {
          if let text = toUnicode.decode(code), text.unicodeScalars.count == 1 {
            encoding[code] = Int(text.unicodeScalars.first!.value)
          }
        }
        var widthMap: [UInt8: Int] = [:]
        for (offset, value) in widths.enumerated() {
          guard case .integer(let width) = value else { continue }
          widthMap[UInt8(offset + Int(first))] = Int(width)
        }
        return .embedded(
          written: WrittenFont(
            encoding: encoding, widths: widthMap, fontDictionary: .dictionary(font),
            descriptor: .dictionary(descriptor), fontFile: file, toUnicode: cmap),
          resourceName: name)
      }
    }
    return nil
  }

  /// Deterministic subset tag from coverage (six uppercase letters).
  static func subsetTag(covering needed: Set<Int>) -> String {
    var hash: UInt32 = 2166136261
    for scalar in needed.sorted() {
      var value = UInt32(bitPattern: Int32(scalar))
      for _ in 0..<4 {
        hash ^= value & 0xFF
        hash = hash &* 16777619
        value >>= 8
      }
    }
    return String(
      (0..<6).map { position in
        Character(UnicodeScalar(65 + Int((hash >> (position * 5)) & 31) % 26)!)
      })
  }

  /// P15-007/P15-021/P15-022: select the font for writing — the standard
  /// profile by default, or a caller-supplied program embedded as a tagged
  /// subset with reuse, unique names, and no silent substitution.
  static func selectFont(
    style: AddedTextStyle, custom: CustomTextFont?, covering text: String,
    pageID: PDFObjectID, in graph: inout PDFGraph, resourceOwner: PDFObjectID? = nil
  ) throws -> WritableTextFont {
    let owner = resourceOwner ?? pageID
    guard let custom else {
      let fontName = try registerStandardFont(
        family: style.family, bold: style.bold, italic: style.italic, pageID: pageID,
        in: &graph, resourceOwner: resourceOwner)
      guard case .dictionary(let ownerDict)? = graph.objects[owner],
        let font = SimpleFont.resolve(resource: fontName, page: ownerDict, in: graph)
      else {
        throw PDFError(.malformed, "The standard font could not be resolved")
      }
      return .graph(font: font, resourceName: fontName)
    }
    // Family names become PDF name bytes; sanitize delimiters away.
    let family = custom.familyName.map { character -> String in
      if character.isLetter || character.isNumber || character == "-" || character == "." {
        return String(character)
      }
      return "-"
    }.joined()
    let needed = Set(text.unicodeScalars.map { Int($0.value) })
    let subset = try TrueTypeSubsetter.subset(program: custom.program, unicodes: needed)
    if let reused = try reuseEmbeddedFont(
      subset: subset, covering: needed, pageID: pageID, in: graph,
      resourceOwner: resourceOwner)
    {
      return reused
    }
    let tag = subsetTag(covering: needed)
    let baseName = family.isEmpty ? "\(tag)+Subset" : "\(tag)+\(family)"
    let covered = String(text.unicodeScalars.filter { needed.contains(Int($0.value)) }.map { Character($0) })
    let written = try FontWriter.writeTrueType(program: subset, baseName: baseName, covering: covered)
    let name = try uniqueFontName(
      prefix: "SPDFF", pageID: pageID, in: graph, resourceOwner: resourceOwner)
    // nextObjectID does not reserve: derive all four IDs from one base.
    let base = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let fontID = PDFObjectID(base)
    let descriptorID = PDFObjectID(base + 1)
    let fileID = PDFObjectID(base + 2)
    let cmapID = PDFObjectID(base + 3)
    guard case .dictionary(var fontDictionary) = written.fontDictionary,
      case .dictionary(var descriptor) = written.descriptor
    else {
      throw PDFError(.malformed, "The embedded font structures are malformed")
    }
    fontDictionary[PDFName("FontDescriptor")] = PDFValue.reference(descriptorID)
    fontDictionary[PDFName("ToUnicode")] = PDFValue.reference(cmapID)
    descriptor[PDFName("FontFile2")] = PDFValue.reference(fileID)
    graph.objects[fontID] = .dictionary(fontDictionary)
    graph.objects[descriptorID] = .dictionary(descriptor)
    graph.objects[fileID] = .stream(written.fontFile)
    graph.objects[cmapID] = .stream(written.toUnicode)
    try addResources(
      [name: .reference(fontID)], kind: "Font", pageID: pageID, in: &graph,
      resourceOwner: resourceOwner)
    return .embedded(written: written, resourceName: name)
  }

  /// P21-008: register an ExtGState for a constant alpha (and overprint-free
  /// defaults); returns nil for fully opaque content.
  static func registerOpacity(
    _ opacity: Double, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws -> PDFName? {
    guard opacity < 0.999 else { return nil }
    let clamped = max(0.01, min(opacity, 1))
    var existing: Set<String> = []
    if case .dictionary(let states)? = (try pageResources(pageID: pageID, in: graph))?[
      PDFName("ExtGState")]
    {
      existing = Set(states.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
    }
    var counter = 1
    var name = PDFName("SPDFGS\(counter)")
    while existing.contains(String(decoding: name.bytes, as: UTF8.self)) {
      counter += 1
      name = PDFName("SPDFGS\(counter)")
    }
    let stateID = nextObjectID(in: graph)
    graph.objects[stateID] = .dictionary([
      PDFName("Type"): .name(PDFName("ExtGState")),
      PDFName("ca"): .real(clamped),
      PDFName("CA"): .real(clamped),
    ])
    try addResources(
      [name: .reference(stateID)], kind: "ExtGState", pageID: pageID, in: &graph)
    return name
  }

  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }

  static func pageResources(
    pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> [PDFName: PDFValue]? {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Resources")] {
    case .dictionary(let resources)?:
      return resources
    case .reference(let id)?:
      if case .dictionary(let resources)? = graph.objects[id] { return resources }
      return nil
    default:
      return nil
    }
  }

  static func addResources(
    _ entries: [PDFName: PDFValue], kind: String, pageID: PDFObjectID, in graph: inout PDFGraph,
    resourceOwner: PDFObjectID? = nil
  ) throws {
    let owner = resourceOwner ?? pageID
    func merged(_ resources: [PDFName: PDFValue]) -> [PDFName: PDFValue] {
      var resources = resources
      var existing: [PDFName: PDFValue] = [:]
      if case .dictionary(let dictionary)? = resources[PDFName(kind)] { existing = dictionary }
      for (name, value) in entries { existing[name] = value }
      resources[PDFName(kind)] = .dictionary(existing)
      return resources
    }
    guard case .dictionary(var ownerDict)? = graph.objects[owner] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch ownerDict[PDFName("Resources")] {
    case .dictionary(let resources)?:
      ownerDict[PDFName("Resources")] = .dictionary(merged(resources))
    case .reference(let id)?:
      guard case .dictionary(let resources)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      graph.objects[id] = .dictionary(merged(resources))
    case nil, .null?:
      ownerDict[PDFName("Resources")] = .dictionary([
        PDFName(kind): .dictionary(entries)
      ])
    default:
      throw PDFError(.malformed, "Page resources are malformed")
    }
    graph.objects[owner] = .dictionary(ownerDict)
  }

  /// Appends a content block (or inserts it at the back).
  static func append(
    _ content: String, pageID: PDFObjectID, toFront: Bool, in graph: inout PDFGraph
  ) throws {
    let bytes = Data(content.utf8)
    let streamID = nextObjectID(in: graph)
    graph.objects[streamID] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      page[PDFName("Contents")] =
        toFront ? .array([.reference(id), .reference(streamID)]) : .array([.reference(streamID), .reference(id)])
    case .array(var items)?:
      if toFront { items.append(.reference(streamID)) } else { items.insert(.reference(streamID), at: 0) }
      page[PDFName("Contents")] = .array(items)
    case nil, .null?:
      page[PDFName("Contents")] = .reference(streamID)
    default:
      throw PDFError(.malformed, "Page content is malformed")
    }
    graph.objects[pageID] = .dictionary(page)
  }

  /// Greedy wrapping with the font's own advances.
  static func wrap(
    _ text: String, font: WritableTextFont, size: Double, width: Double
  ) -> [String] {
    let paragraphs = text.components(separatedBy: "\n")
    var lines: [String] = []
    for paragraph in paragraphs {
      var current = ""
      for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
        let candidate = current.isEmpty ? String(word) : current + " " + word
        let measured = font.advance(of: Array(candidate.utf8), fontSize: size)
          ?? Double(candidate.count) * size * 0.5
        if measured > width, !current.isEmpty {
          lines.append(current)
          current = String(word)
        } else {
          current = candidate
        }
      }
      lines.append(current)
    }
    return lines
  }

  static func textBlock(
    lines: [String], origin: [Double], width: Double, fontName: PDFName,
    font: WritableTextFont, style: AddedTextStyle, opacityName: PDFName?
  ) -> String {
    var block = "q\n"
    if let opacityName {
      block += "/\(String(decoding: opacityName.bytes, as: UTF8.self)) gs\n"
    }
    block += "\(number(style.color[0])) \(number(style.color[1])) \(number(style.color[2])) rg\n"
    block += "BT\n/\(String(decoding: fontName.bytes, as: UTF8.self)) \(number(style.size)) Tf\n"
    let leading = style.size * max(style.lineSpacing, 0.8)
    for (index, line) in lines.enumerated() {
      guard let codes = font.encode(line) else { continue }
      let measured = font.advance(of: codes, fontSize: style.size)
        ?? Double(line.count) * style.size * 0.5
      let x: Double
      switch style.alignment {
      case .center: x = origin[0] + (width - measured) / 2
      case .right: x = origin[0] + width - measured
      case .left, .justified: x = origin[0]
      }
      let y = origin[1] - Double(index) * leading
      block += "1 0 0 1 \(number(x)) \(number(y)) Tm\n"
      block += "(\(escaped(codes))) Tj\n"
    }
    block += "ET\nQ\n"
    return block
  }

  static func escaped(_ bytes: [UInt8]) -> String {
    var result = ""
    for byte in bytes {
      switch byte {
      case 0x28: result += "\\("
      case 0x29: result += "\\)"
      case 0x5C: result += "\\\\"
      case 0x0A: result += "\\n"
      case 0x0D: result += "\\r"
      case 0x09: result += "\\t"
      case 0x20...0x7E: result.append(Character(UnicodeScalar(byte)))
      default: result += String(format: "\\%03o", byte)
      }
    }
    return result
  }

  static func number(_ value: Double) -> String {
    let rounded = (value * 1_000).rounded() / 1_000
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    return String(rounded)
  }
}

// MARK: - Commands

/// P21-001/P21-002/P21-003/P21-011/P21-014: insert a new text object into the
/// page content with wrapping, alignment, and optional clipping.
public struct AddTextObjectCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let text: String
  public let style: AddedTextStyle
  /// Append on top (front) or insert behind existing content (back).
  public let toFront: Bool
  /// Clip the text to its rectangle.
  public let clips: Bool
  /// P15-007: an optional caller-supplied font program, embedded as a
  /// tagged subset (nil keeps the standard-14 profile).
  public let customFont: CustomTextFont?

  public init(
    pageID: PDFObjectID, rect: [Double], text: String, style: AddedTextStyle = AddedTextStyle(),
    toFront: Bool = true, clips: Bool = false, customFont: CustomTextFont? = nil
  ) {
    self.pageID = pageID
    self.rect = rect
    self.text = text
    self.style = style
    self.toFront = toFront
    self.clips = clips
    self.customFont = customFont
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Text" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The text box is empty")
    }
    guard !text.isEmpty, text.utf8.count <= 100_000 else {
      throw PDFError(.limitExceeded, "The text is empty or exceeds the size limit")
    }
    guard style.size >= 2, style.size <= 400 else {
      throw PDFError(.malformed, "The font size is outside the supported range")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let font = try AddedContent.selectFont(
      style: style, custom: customFont, covering: text, pageID: pageID, in: &graph)
    let fontName = font.resourceName
    let opacityName = try AddedContent.registerOpacity(
      style.opacity, pageID: pageID, in: &graph)
    let lines = AddedContent.wrap(
      text, font: font, size: style.size, width: rect[2] - rect[0])
    guard lines.allSatisfy({ font.encode($0) != nil }) else {
      throw PDFError(
        .unsupported,
        "The text contains characters the standard-14 WinAnsi profile cannot encode; no partial text is written")
    }
    // The first baseline sits one ascent below the top edge.
    let ascent = style.size * 0.8
    var block = ""
    if clips {
      block += "q\n\(AddedContent.number(rect[0])) \(AddedContent.number(rect[1])) "
        + "\(AddedContent.number(rect[2] - rect[0])) \(AddedContent.number(rect[3] - rect[1])) re W n\n"
    }
    block += AddedContent.textBlock(
      lines: lines, origin: [rect[0], rect[3] - ascent], width: rect[2] - rect[0],
      fontName: fontName, font: font, style: style, opacityName: opacityName)
    if clips { block += "Q\n" }
    try AddedContent.append(block, pageID: pageID, toFront: toFront, in: &graph)
    return graph
  }
}

/// P21-004–P21-008/P21-011/P21-014: insert a vector shape with stroke, fill,
/// dash, and constant opacity.
public struct AddVectorShapeCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let shape: AddedShape
  public let style: AddedShapeStyle
  public let toFront: Bool
  public let clips: Bool

  public init(
    pageID: PDFObjectID, shape: AddedShape, style: AddedShapeStyle = AddedShapeStyle(),
    toFront: Bool = true, clips: Bool = false
  ) {
    self.pageID = pageID
    self.shape = shape
    self.style = style
    self.toFront = toFront
    self.clips = clips
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Vector Shape" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard style.strokeColor != nil || style.fillColor != nil else {
      throw PDFError(.malformed, "The shape has neither stroke nor fill")
    }
    guard style.lineWidth >= 0, style.lineWidth <= 200 else {
      throw PDFError(.malformed, "The line width is outside the supported range")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let opacityName = try AddedContent.registerOpacity(
      style.opacity, pageID: pageID, in: &graph)
    var block = "q\n"
    if let opacityName {
      block += "/\(String(decoding: opacityName.bytes, as: UTF8.self)) gs\n"
    }
    let bounds = shape.bounds
    if clips {
      block += "\(AddedContent.number(bounds[0])) \(AddedContent.number(bounds[1])) "
        + "\(AddedContent.number(max(bounds[2] - bounds[0], 1))) "
        + "\(AddedContent.number(max(bounds[3] - bounds[1], 1))) re W n\n"
    }
    if let stroke = style.strokeColor {
      block += "\(AddedContent.number(stroke[0])) \(AddedContent.number(stroke[1])) "
        + "\(AddedContent.number(stroke[2])) RG\n"
      block += "\(AddedContent.number(max(style.lineWidth, 0.1))) w\n"
      if !style.dash.isEmpty {
        block += "[" + style.dash.map(AddedContent.number).joined(separator: " ") + "] 0 d\n"
      }
    }
    if let fill = style.fillColor {
      block += "\(AddedContent.number(fill[0])) \(AddedContent.number(fill[1])) "
        + "\(AddedContent.number(fill[2])) rg\n"
    }
    block += pathOperators(for: shape)
    let paint: String
    switch (style.fillColor != nil, style.strokeColor != nil) {
    case (true, true): paint = "B\n"
    case (true, false): paint = "f\n"
    default: paint = "S\n"
    }
    block += paint + "Q\n"
    try AddedContent.append(block, pageID: pageID, toFront: toFront, in: &graph)
    return graph
  }

  func pathOperators(for shape: AddedShape) -> String {
    switch shape {
    case .rectangle(let rect):
      return
        "\(AddedContent.number(rect[0])) \(AddedContent.number(rect[1])) "
        + "\(AddedContent.number(rect[2] - rect[0])) \(AddedContent.number(rect[3] - rect[1])) re\n"
    case .ellipse(let rect):
      let k = 0.5523
      let cx = (rect[0] + rect[2]) / 2
      let cy = (rect[1] + rect[3]) / 2
      let rx = (rect[2] - rect[0]) / 2
      let ry = (rect[3] - rect[1]) / 2
      return
        "\(AddedContent.number(cx + rx)) \(AddedContent.number(cy)) m\n"
        + "\(AddedContent.number(cx + rx)) \(AddedContent.number(cy + k * ry)) "
        + "\(AddedContent.number(cx + k * rx)) \(AddedContent.number(cy + ry)) "
        + "\(AddedContent.number(cx)) \(AddedContent.number(cy + ry)) c\n"
        + "\(AddedContent.number(cx - k * rx)) \(AddedContent.number(cy + ry)) "
        + "\(AddedContent.number(cx - rx)) \(AddedContent.number(cy + k * ry)) "
        + "\(AddedContent.number(cx - rx)) \(AddedContent.number(cy)) c\n"
        + "\(AddedContent.number(cx - rx)) \(AddedContent.number(cy - k * ry)) "
        + "\(AddedContent.number(cx - k * rx)) \(AddedContent.number(cy - ry)) "
        + "\(AddedContent.number(cx)) \(AddedContent.number(cy - ry)) c\n"
        + "\(AddedContent.number(cx + k * rx)) \(AddedContent.number(cy - ry)) "
        + "\(AddedContent.number(cx + rx)) \(AddedContent.number(cy - k * ry)) "
        + "\(AddedContent.number(cx + rx)) \(AddedContent.number(cy)) c\n"
    case .polygon(let points), .path(let points, _):
      guard let first = points.first else { return "" }
      var operators =
        "\(AddedContent.number(first[0])) \(AddedContent.number(first[1])) m\n"
      for point in points.dropFirst() {
        operators += "\(AddedContent.number(point[0])) \(AddedContent.number(point[1])) l\n"
      }
      let closed: Bool
      if case .polygon = shape { closed = true } else if case .path(_, let isClosed) = shape {
        closed = isClosed
      } else {
        closed = false
      }
      if closed { operators += "h\n" }
      return operators
    case .line(let from, let to):
      return
        "\(AddedContent.number(from[0])) \(AddedContent.number(from[1])) m\n"
        + "\(AddedContent.number(to[0])) \(AddedContent.number(to[1])) l\n"
    }
  }
}

/// P21-015: place a new image (raw 8-bit RGB) as real page content.
public struct AddImageStampCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let rect: [Double]
  public let width: Int
  public let height: Int
  public let rgb8: Data
  public let opacity: Double
  public let toFront: Bool

  public init(
    pageID: PDFObjectID, rect: [Double], width: Int, height: Int, rgb8: Data,
    opacity: Double = 1, toFront: Bool = true
  ) {
    self.pageID = pageID
    self.rect = rect
    self.width = width
    self.height = height
    self.rgb8 = rgb8
    self.opacity = opacity
    self.toFront = toFront
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Image Stamp" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard width > 0, height > 0, width <= 20_000, height <= 20_000,
      rgb8.count >= width * height * 3
    else {
      throw PDFError(.malformed, "The image data does not match its dimensions")
    }
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
      throw PDFError(.malformed, "The placement rectangle is empty")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let imageID = AddedContent.nextObjectID(in: graph)
    let encoded = try PDFFilters.encodeFlate(Data(rgb8.prefix(width * height * 3)))
    graph.objects[imageID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Image")),
          PDFName("Width"): .integer(Int64(width)),
          PDFName("Height"): .integer(Int64(height)),
          PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
          PDFName("BitsPerComponent"): .integer(8),
          PDFName("Filter"): .name(PDFName("FlateDecode")),
          PDFName("Length"): .integer(Int64(encoded.count)),
        ], bytes: encoded))
    // A unique XObject resource name.
    var existing: Set<String> = []
    if case .dictionary(let objects)? = (try AddedContent.pageResources(pageID: pageID, in: graph))?[
      PDFName("XObject")]
    {
      existing = Set(objects.keys.map { String(decoding: $0.bytes, as: UTF8.self) })
    }
    var counter = 1
    var name = PDFName("SPDFIm\(counter)")
    while existing.contains(String(decoding: name.bytes, as: UTF8.self)) {
      counter += 1
      name = PDFName("SPDFIm\(counter)")
    }
    try AddedContent.addResources(
      [name: .reference(imageID)], kind: "XObject", pageID: pageID, in: &graph)
    let opacityName = try AddedContent.registerOpacity(opacity, pageID: pageID, in: &graph)
    var block = "q\n"
    if let opacityName {
      block += "/\(String(decoding: opacityName.bytes, as: UTF8.self)) gs\n"
    }
    block +=
      "\(AddedContent.number(rect[2] - rect[0])) 0 0 \(AddedContent.number(rect[3] - rect[1])) "
      + "\(AddedContent.number(rect[0])) \(AddedContent.number(rect[1])) cm\n"
    block += "/\(String(decoding: name.bytes, as: UTF8.self)) Do\nQ\n"
    try AddedContent.append(block, pageID: pageID, toFront: toFront, in: &graph)
    return graph
  }
}

/// P21-016–P21-022: repeated page marks across explicit page ranges with a
/// preview, unique resource names, and compound undo (one command covers every
/// page it touches).
public struct AddRepeatedMarkCommand: PDFEditCommand, Equatable, Sendable {
  public let pageIDs: [PDFObjectID]
  public let mark: RepeatedMark
  /// Margins used for header/footer/page-number placement.
  public let margin: Double
  /// P15-007: an optional caller-supplied font program, embedded as a
  /// tagged subset (nil keeps the standard-14 profile).
  public let customFont: CustomTextFont?

  public init(
    pageIDs: [PDFObjectID], mark: RepeatedMark, margin: Double = 36,
    customFont: CustomTextFont? = nil
  ) {
    self.pageIDs = pageIDs
    self.mark = mark
    self.margin = margin
    self.customFont = customFont
  }

  /// P17-012: the pages this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Add Page Mark" }

  public func validate(in graph: PDFGraph) throws {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected")
    }
    for pageID in pageIDs {
      try AnnotationSupport.validatePage(pageID, in: graph)
    }
  }

  /// P21-020: the per-page preview (text, bounds, and content block).
  public func plan(in input: PDFGraph) throws -> RepeatedMarkPlan {
    var graph = input
    var previews: [RepeatedMarkPlan.PagePreview] = []
    for (index, pageID) in pageIDs.enumerated() {
      let text = mark.text(pageIndex: index, pageCount: pageIDs.count)
      let box = try pageBox(pageID, in: graph)
      let rect = placementRect(in: box)
      let font = try AddedContent.selectFont(
        style: mark.style, custom: customFont, covering: text, pageID: pageID,
        in: &graph)
      let fontName = font.resourceName
      let lines = AddedContent.wrap(
        text, font: font, size: mark.style.size, width: rect[2] - rect[0])
      var content = ""
      if case .watermark(_, _, let angle) = mark {
        content +=
          "q\n\(AddedContent.number(cos(angle * .pi / 180))) "
          + "\(AddedContent.number(sin(angle * .pi / 180))) "
          + "\(AddedContent.number(-sin(angle * .pi / 180))) "
          + "\(AddedContent.number(cos(angle * .pi / 180))) "
          + "\(AddedContent.number(rect[0])) \(AddedContent.number(rect[1])) cm\n"
      } else {
        content += "q\n"
      }
      content += AddedContent.textBlock(
        lines: lines, origin: [rect[0], rect[3] - mark.style.size * 0.8], width: rect[2] - rect[0],
        fontName: fontName, font: font, style: mark.style, opacityName: nil)
      content += "Q\n"
      previews.append(
        RepeatedMarkPlan.PagePreview(
          pageIndex: index, text: text, bounds: rect, content: content))
    }
    return RepeatedMarkPlan(mark: mark, pages: previews)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let plan = try plan(in: graph)
    for (index, pageID) in pageIDs.enumerated() {
      let text = mark.text(pageIndex: index, pageCount: pageIDs.count)
      let box = try pageBox(pageID, in: graph)
      let rect = placementRect(in: box)
      let font = try AddedContent.selectFont(
        style: mark.style, custom: customFont, covering: text, pageID: pageID,
        in: &graph)
      let fontName = font.resourceName
      let opacityName = try AddedContent.registerOpacity(
        mark.style.opacity, pageID: pageID, in: &graph)
      let lines = AddedContent.wrap(
        text, font: font, size: mark.style.size, width: rect[2] - rect[0])
      guard lines.allSatisfy({ font.encode($0) != nil }) else {
        throw PDFError(
          .unsupported,
          "The mark text contains characters the standard-14 WinAnsi profile cannot encode")
      }
      var content = "q\n"
      if case .watermark(_, _, let angle) = mark, angle != 0 {
        content +=
          "\(AddedContent.number(cos(angle * .pi / 180))) "
          + "\(AddedContent.number(sin(angle * .pi / 180))) "
          + "\(AddedContent.number(-sin(angle * .pi / 180))) "
          + "\(AddedContent.number(cos(angle * .pi / 180))) "
          + "\(AddedContent.number(rect[0])) \(AddedContent.number(rect[1])) cm\n"
      }
      content += AddedContent.textBlock(
        lines: lines, origin: [rect[0], rect[3] - mark.style.size * 0.8], width: rect[2] - rect[0],
        fontName: fontName, font: font, style: mark.style, opacityName: opacityName)
      content += "Q\n"
      try AddedContent.append(content, pageID: pageID, toFront: true, in: &graph)
      _ = plan
    }
    return graph
  }

  func pageBox(_ pageID: PDFObjectID, in graph: PDFGraph) throws -> [Double] {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    for key in ["CropBox", "MediaBox"] {
      if case .array(let values)? = page[PDFName(key)] {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
    }
    return [0, 0, 612, 792]
  }

  func placementRect(in box: [Double]) -> [Double] {
    switch mark {
    case .header:
      return [box[0] + margin, box[3] - margin, box[2] - margin, box[3] - margin + mark.style.size]
    case .footer, .pageNumber, .bates:
      return [box[0] + margin, box[1] + margin - mark.style.size, box[2] - margin, box[1] + margin]
    case .watermark:
      let width = (box[2] - box[0]) * 0.6
      let height = mark.style.size * 1.4
      let x = box[0] + ((box[2] - box[0]) - width) / 2
      let y = box[1] + ((box[3] - box[1]) - height) / 2
      return [x, y, x + width, y + height]
    }
  }
}
