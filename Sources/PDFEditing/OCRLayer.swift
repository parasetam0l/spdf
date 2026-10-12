import Foundation
import PDFCore

/// P26-010: one line of searchable text with its page-space box and the
/// recognition confidence that produced it (provenance).
public struct SearchableTextLine: Sendable, Equatable {
  public let text: String
  /// Page-space rectangle `[x0, y0, x1, y1]` in unrotated page coordinates.
  public let rect: [Double]
  public let confidence: Double?

  public init(text: String, rect: [Double], confidence: Double? = nil) {
    self.text = text
    self.rect = rect
    self.confidence = confidence
  }
}

/// P26-010/P26-011/P26-013/P26-014: the generated searchable text layer.
/// Layers are Type0 Identity-H fonts with a ToUnicode CMap drawing invisible
/// (`3 Tr`) text, marked with private keys so they can be detected and
/// replaced without touching original content.
public enum OCRLayer {
  static let marker = PDFName("SPDFOCR")

  public static func hasGeneratedLayer(in graph: PDFGraph, pageID: PDFObjectID) -> Bool {
    !layerStreamIDs(in: graph, pageID: pageID).isEmpty
      || !layerFontNames(in: graph, pageID: pageID).isEmpty
  }

  /// Whether the page shows text operators at all, including text our
  /// simple-font profile cannot decode yet (P26-013).
  public static func pageShowsText(_ pageID: PDFObjectID, in graph: PDFGraph) -> Bool {
    guard let content = try? PageContent.load(pageID: pageID, in: graph) else { return false }
    return content.instructions.contains { instruction in
      ["Tj", "TJ", "'", "\""].contains(instruction.operatorName)
    }
  }

  static func layerStreamIDs(in graph: PDFGraph, pageID: PDFObjectID) -> [PDFObjectID] {
    var ids: [PDFObjectID] = []
    for value in pageContentValues(in: graph, pageID: pageID) {
      guard case .reference(let id) = value,
        case .stream(let stream)? = graph.objects[id],
        stream.dictionary[marker] == .boolean(true)
      else { continue }
      ids.append(id)
    }
    return ids
  }

  static func layerFontNames(in graph: PDFGraph, pageID: PDFObjectID) -> [PDFName] {
    guard let resources = pageResources(in: graph, pageID: pageID),
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else { return [] }
    return fonts.keys.sorted().filter { name in
      guard case .reference(let id)? = fonts[name],
        case .dictionary(let font)? = graph.objects[id],
        font[marker] == .boolean(true)
      else { return false }
      return true
    }
  }

  static func pageContentValues(in graph: PDFGraph, pageID: PDFObjectID) -> [PDFValue] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    switch page[PDFName("Contents")] {
    case .array(let array)?:
      return array
    case .reference(let id)?:
      return [.reference(id)]
    default:
      return []
    }
  }

  static func pageResources(in graph: PDFGraph, pageID: PDFObjectID) -> [PDFName: PDFValue]? {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
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

  /// P26-014/P26-023: remove a previously generated layer and its font
  /// objects, leaving original content untouched.
  public static func removeLayer(pageID: PDFObjectID, in graph: inout PDFGraph) throws {
    let streamIDs = layerStreamIDs(in: graph, pageID: pageID)
    let fontNames = layerFontNames(in: graph, pageID: pageID)
    guard !streamIDs.isEmpty || !fontNames.isEmpty else { return }

    // Remove the marked content streams from /Contents.
    if !streamIDs.isEmpty {
      let removed = Set(streamIDs)
      let remaining = pageContentValues(in: graph, pageID: pageID).filter { value in
        if case .reference(let id) = value { return !removed.contains(id) }
        return true
      }
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "Page is missing")
      }
      switch page[PDFName("Contents")] {
      case .reference(let id)? where removed.contains(id):
        page[PDFName("Contents")] = remaining.isEmpty ? nil : (remaining.count == 1 ? remaining[0] : .array(remaining))
      case .array:
        page[PDFName("Contents")] = remaining.isEmpty ? nil : (remaining.count == 1 ? remaining[0] : .array(remaining))
      default:
        break
      }
      graph.objects[pageID] = .dictionary(page)
    }

    // Remove the marked font resources and the objects they own.
    var owned: [PDFObjectID] = []
    if !fontNames.isEmpty, let resources = pageResources(in: graph, pageID: pageID) {
      var fonts: [PDFName: PDFValue] = [:]
      if case .dictionary(let existing)? = resources[PDFName("Font")] { fonts = existing }
      for name in fontNames {
        if case .reference(let id)? = fonts[name] {
          owned.append(id)
          if case .dictionary(let font)? = graph.objects[id] {
            if case .array(let descendants)? = font[PDFName("DescendantFonts")] {
              for descendant in descendants {
                if case .reference(let descendantID) = descendant {
                  owned.append(descendantID)
                  if case .dictionary(let dictionary)? = graph.objects[descendantID],
                    case .reference(let descriptorID)? = dictionary[PDFName("FontDescriptor")]
                  {
                    owned.append(descriptorID)
                  }
                }
              }
            }
            if case .reference(let cmapID)? = font[PDFName("ToUnicode")] {
              owned.append(cmapID)
            }
          }
        }
        fonts.removeValue(forKey: name)
      }
      var updated = resources
      updated[PDFName("Font")] = fonts.isEmpty ? nil : .dictionary(fonts)
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "Page is missing")
      }
      page[PDFName("Resources")] = .dictionary(updated)
      graph.objects[pageID] = .dictionary(page)
    }

    for id in ([streamIDs] + [owned]).flatMap({ $0 }) {
      if case .stream(let stream)? = graph.objects[id] {
        // Only delete marked objects or streams owned by the layer.
        if stream.dictionary[marker] == .boolean(true) || owned.contains(id) {
          graph.objects[id] = nil
        }
      } else if owned.contains(id), !AnnotationSupport.isReferenced(id, in: graph) {
        graph.objects[id] = nil
      }
    }
    let highest = graph.objects.keys.map(\.number).max() ?? 0
    AnnotationSupport.finish(&graph, highest: highest)
  }

  static func toUnicodeCMap(codes: [UInt16]) -> PDFStream {
    var content = """
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
      /CMapName /Adobe-Identity-UCS def
      /CMapType 2 def
      1 begincodespacerange
      <0000> <FFFF>
      endcodespacerange

      """
    var remaining = codes
    while !remaining.isEmpty {
      let chunk = Array(remaining.prefix(100))
      remaining.removeFirst(chunk.count)
      content += "\(chunk.count) beginbfchar\n"
      for code in chunk {
        content += String(format: "<%04X> <%04X>\n", Int(code), Int(code))
      }
      content += "endbfchar\n"
    }
    content += """
      endcmap
      CMapName currentdict /CMap defineresource pop
      end
      end

      """
    let bytes = Data(content.utf8)
    return PDFStream(
      dictionary: [
        PDFName("Length"): .integer(Int64(bytes.count)),
        marker: .boolean(true),
      ], bytes: bytes)
  }

  /// A unique `/Focr`-style resource name on the page.
  static func uniqueFontName(in graph: PDFGraph, pageID: PDFObjectID) -> PDFName {
    var existing: Set<PDFName> = []
    if let resources = pageResources(in: graph, pageID: pageID),
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    {
      existing = Set(fonts.keys)
    }
    var name = PDFName("Focr")
    var counter = 1
    while existing.contains(name) {
      name = PDFName("Focr\(counter)")
      counter += 1
    }
    return name
  }

  /// Add or replace a `/Font` entry on the page's resources.
  static func addFontResource(
    name: PDFName, fontID: PDFObjectID, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var resources: [PDFName: PDFValue]
    switch page[PDFName("Resources")] {
    case .dictionary(let existing)?:
      resources = existing
    case .reference(let id)?:
      guard case .dictionary(let existing)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page resources are missing")
      }
      resources = existing
    default:
      resources = [:]
    }
    var fonts: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = resources[PDFName("Font")] { fonts = existing }
    fonts[name] = .reference(fontID)
    resources[PDFName("Font")] = .dictionary(fonts)
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
  }
}

/// P26-010/P26-011/P26-012: add an invisible Unicode text layer to a scanned
/// page. Original content and rasters are untouched; only a marked content
/// stream and font objects are appended.
public struct AddSearchableTextLayerCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let lines: [SearchableTextLine]
  /// P26-014: replace an existing generated layer instead of refusing.
  public let replacingExistingLayer: Bool

  public init(
    pageID: PDFObjectID, lines: [SearchableTextLine], replacingExistingLayer: Bool = false
  ) {
    self.pageID = pageID
    self.lines = lines
    self.replacingExistingLayer = replacingExistingLayer
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Searchable Text" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !lines.isEmpty else {
      throw PDFError(.malformed, "A searchable text layer needs at least one line")
    }
    let hasLayer = OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID)
    if hasLayer {
      guard replacingExistingLayer else {
        throw PDFError(.unsupported, "This page already has a generated searchable text layer")
      }
    } else {
      // P26-013: never add a duplicate layer to a page that already shows
      // text, including text our simple-font profile cannot decode yet.
      guard !OCRLayer.pageShowsText(pageID, in: graph) else {
        throw PDFError(
          .unsupported, "This page already contains text; no OCR layer is needed")
      }
    }
    for line in lines {
      guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        line.rect.count == 4, line.rect.allSatisfy(\.isFinite),
        line.rect[2] > line.rect[0], line.rect[3] > line.rect[1]
      else {
        throw PDFError(.malformed, "Searchable text line geometry or text is invalid")
      }
      guard line.text.unicodeScalars.allSatisfy({ $0.value < 0x10000 }) else {
        throw PDFError(.unsupported, "Searchable text beyond the BMP is not supported yet")
      }
    }
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 6
    guard next <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for the searchable text layer")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    if replacingExistingLayer {
      try OCRLayer.removeLayer(pageID: pageID, in: &graph)
    }
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    var codes: [UInt16] = []
    var hexLines: [String] = []
    for line in lines {
      var hex = ""
      for unit in line.text.utf16 {
        hex += String(format: "%04X", Int(unit))
        if !codes.contains(unit) { codes.append(unit) }
      }
      hexLines.append(hex)
    }

    let cmapID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[cmapID] = .stream(OCRLayer.toUnicodeCMap(codes: codes))
    let descriptorID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[descriptorID] = .dictionary([
      PDFName("Type"): .name(PDFName("FontDescriptor")),
      PDFName("FontName"): .name(PDFName("SPDFOCR")),
      PDFName("Flags"): .integer(4),
      PDFName("FontBBox"): .array([
        .integer(0), .integer(-200), .integer(1000), .integer(900),
      ]),
      PDFName("ItalicAngle"): .integer(0),
      PDFName("Ascent"): .integer(900),
      PDFName("Descent"): .integer(-200),
      PDFName("CapHeight"): .integer(700),
      PDFName("StemV"): .integer(80),
      OCRLayer.marker: .boolean(true),
    ])
    let cidFontID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[cidFontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("CIDFontType2")),
      PDFName("BaseFont"): .name(PDFName("SPDFOCR")),
      PDFName("CIDSystemInfo"): .dictionary([
        PDFName("Registry"): .string(Data("Adobe".utf8)),
        PDFName("Ordering"): .string(Data("Identity".utf8)),
        PDFName("Supplement"): .integer(0),
      ]),
      PDFName("FontDescriptor"): .reference(descriptorID),
      PDFName("DW"): .integer(1000),
      OCRLayer.marker: .boolean(true),
    ])
    let type0ID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[type0ID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type0")),
      PDFName("BaseFont"): .name(PDFName("SPDFOCR")),
      PDFName("Encoding"): .name(PDFName("Identity-H")),
      PDFName("DescendantFonts"): .array([.reference(cidFontID)]),
      PDFName("ToUnicode"): .reference(cmapID),
      OCRLayer.marker: .boolean(true),
    ])

    let fontName = OCRLayer.uniqueFontName(in: graph, pageID: pageID)
    var content = "q\nBT\n3 Tr\n"
    for (index, line) in lines.enumerated() {
      let size = max(1, line.rect[3] - line.rect[1])
      content += "/\(String(decoding: fontName.bytes, as: UTF8.self)) "
      content += "\(AnnotationSupport.number(size)) Tf\n"
      content += "1 0 0 1 \(AnnotationSupport.number(line.rect[0])) "
      content += "\(AnnotationSupport.number(line.rect[1])) Tm\n"
      content += "<\(hexLines[index])> Tj\n"
    }
    content += "ET\nQ\n"
    let bytes = Data(content.utf8)
    let streamID = PDFObjectID(nextNumber)
    nextNumber += 1
    graph.objects[streamID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Length"): .integer(Int64(bytes.count)),
          OCRLayer.marker: .boolean(true),
        ], bytes: bytes))

    try FlattenAnnotationsCommand.appendContents(
      [.reference(streamID)], pageID: pageID, in: &graph)
    try OCRLayer.addFontResource(
      name: fontName, fontID: type0ID, pageID: pageID, in: &graph)
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return graph
  }
}

/// P26-023: drop a generated searchable text layer, for example before
/// replacing the scan it was recognized from.
public struct RemoveOCRLayerCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID

  public init(pageID: PDFObjectID) {
    self.pageID = pageID
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Remove Searchable Text" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID) else {
      throw PDFError(.malformed, "This page has no generated searchable text layer")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    try OCRLayer.removeLayer(pageID: pageID, in: &graph)
    return graph
  }
}

/// P16-021: internal provenance for extraction consumers — which text runs
/// on a page were drawn by a generated OCR layer (as opposed to original
/// document text).
public enum TextProvenance {
  /// Run indices whose source stream belongs to a generated OCR layer.
  public static func recognizedRunIndices(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) -> Set<Int> {
    let layerIDs = Set(OCRLayer.layerStreamIDs(in: graph, pageID: pageID))
    guard !layerIDs.isEmpty,
      let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits),
      let runs = try? TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    else { return [] }
    var result: Set<Int> = []
    for (index, run) in runs.enumerated() {
      guard let segment = content.segmentIndex(for: run.stringSpan),
        layerIDs.contains(content.segments[segment].objectID)
      else { continue }
      result.insert(index)
    }
    return result
  }
}

extension TextProvenance {
  /// P16-021: the text a generated OCR layer draws on `pageID`, decoded
  /// through its composite font's ToUnicode map, joined line by line. Nil
  /// when the page has no generated layer or nothing decodes; the owned
  /// layout cannot place this text (composite fonts are out of the layout
  /// profile), so consumers use it for provenance-aware search while the
  /// independent renderer supplies highlights.
  public static func recognizedLayerText(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) -> String? {
    guard OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID),
      let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits)
    else { return nil }
    let layerIDs = Set(OCRLayer.layerStreamIDs(in: graph, pageID: pageID))
    guard !layerIDs.isEmpty else { return nil }
    let fontNames = Set(
      OCRLayer.layerFontNames(in: graph, pageID: pageID).map {
        String(decoding: $0.bytes, as: UTF8.self)
      })
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    var lines: [String] = []
    for segment in content.segments where layerIDs.contains(segment.objectID) {
      guard let parsed = try? ContentParser.instructions(in: segment.decoded, limits: limits)
      else { continue }
      for instruction in parsed {
        guard instruction.operatorName == "Tj" || instruction.operatorName == "TJ"
        else { continue }
        var codes: [UInt8] = []
        collectCodes(instruction.operands.first?.value, into: &codes)
        guard !codes.isEmpty else { continue }
        guard let fontName = segmentFontName(instruction, in: parsed) else { continue }
        guard fontNames.isEmpty || fontNames.contains(String(decoding: fontName.bytes, as: UTF8.self))
        else { continue }
        let font = fontDictionary(named: fontName, page: page, in: graph)
        guard let font, let composite = CompositeFont.parse(font, in: graph) else { continue }
        if let decoded = try? composite.decode(codes, policy: .replacementCharacter) {
          let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty { lines.append(text) }
        }
      }
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }

  /// The last Tf font name seen before a show operator inside one stream.
  private static func segmentFontName(
    _ instruction: ContentInstruction, in parsed: [ContentInstruction]
  ) -> PDFName? {
    for candidate in parsed {
      if candidate.operatorName == "Tf",
        case .name(let name)? = candidate.operands.first?.value
      {
        // Best-effort: the layer writes Tf once at the start of the block.
        return name
      }
    }
    return nil
  }

  private static func collectCodes(_ value: PDFValue?, into codes: inout [UInt8]) {
    switch value {
    case .string(let data)?:
      codes.append(contentsOf: data)
    case .array(let members)?:
      for member in members { collectCodes(member, into: &codes) }
    default:
      break
    }
  }

  private static func fontDictionary(
    named name: PDFName, page: [PDFName: PDFValue], in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    guard case .dictionary(let resources)? = page[PDFName("Resources")] else { return nil }
    guard case .dictionary(let fonts)? = resources[PDFName("Font")] else { return nil }
    guard let entry = fonts[name] else { return nil }
    switch entry {
    case .reference(let id):
      if case .dictionary(let font)? = graph.objects[id] { return font }
    case .dictionary(let font):
      return font
    default:
      break
    }
    return nil
  }
}
