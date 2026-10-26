import CoreText
import Foundation
import PDFCore

/// FNT-05/FNT-06: one TrueType program used for shaped writing. The font name
/// is resolved through Core Text for shaping and glyph selection; the program
/// bytes are what gets embedded, so shaping and the PDF program cannot drift
/// apart silently.
public struct ShapedFontSource: Sendable, Equatable {
  public let program: Data
  public let fontName: String
  public let baseName: String

  public init(program: Data, fontName: String, baseName: String) {
    self.program = program
    self.fontName = fontName
    self.baseName = baseName
  }
}

/// FNT-05/FNT-06: a shaped composite font ready to be referenced from a page.
/// CIDs are the program's glyph ids (CIDFontType2 Identity), so contextual
/// forms selected by shaping are preserved without inventing cmap entries.
public struct WrittenShapedFont: Sendable, Equatable {
  public let baseName: String
  public let widths: [Int: Int]
  public let descendant: PDFValue
  public let descriptor: PDFValue
  public let fontFile: PDFStream
  public let toUnicode: PDFStream
  public let writingMode: CompositeFontWritingMode
  public let glyphIDs: [Int]

  public func type0Dictionary(
    descendantID: PDFObjectID, toUnicodeID: PDFObjectID
  ) -> PDFValue {
    let encoding = writingMode == .vertical ? "Identity-V" : "Identity-H"
    return .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type0")),
      PDFName("BaseFont"): .name(PDFName(baseName)),
      PDFName("Encoding"): .name(PDFName(encoding)),
      PDFName("DescendantFonts"): .array([.reference(descendantID)]),
      PDFName("ToUnicode"): .reference(toUnicodeID),
    ])
  }

  /// Two-byte Identity codes for the given glyph ids (the CID is the glyph id).
  public func encode(_ glyphs: [Int]) -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(glyphs.count * 2)
    for glyph in glyphs {
      guard widths[glyph] != nil, glyph >= 0, glyph <= 0xFFFF else { return nil }
      bytes.append(UInt8((glyph >> 8) & 0xFF))
      bytes.append(UInt8(glyph & 0xFF))
    }
    return bytes
  }
}

/// FNT-05/FNT-06: glyph-id composite font writing for shaped scripts and
/// vertical CJK. Whole TrueType programs are embedded (glyph-level subsetting
/// is outside this profile), CIDs equal glyph ids, /W carries horizontal
/// advances and /W2/DW2 carry the declared vertical advances.
public enum ShapedFontWriter {
  public static func write(
    program: Data, baseName: String, glyphs: [Int],
    unicodeByGlyph: [Int: String], pointSize: Double,
    writingMode: CompositeFontWritingMode,
    verticalAdvances: [Int: Double]? = nil
  ) throws -> WrittenShapedFont {
    guard !program.isEmpty else {
      throw PDFError(.malformed, "The shaped font program is empty")
    }
    guard pointSize.isFinite, pointSize > 0 else {
      throw PDFError(.malformed, "The shaped font point size is not usable")
    }
    let inspector = try TrueTypeInspector.inspect(program)
    guard !inspector.isCFF else {
      throw PDFError(
        .unsupported,
        "Shaped script embedding supports TrueType outlines; CFF programs are outside this profile")
    }
    let orderedGlyphs = Array(Set(glyphs)).sorted()
    guard !orderedGlyphs.isEmpty else {
      throw PDFError(.malformed, "No shaped glyphs were provided")
    }
    for glyph in orderedGlyphs {
      guard glyph > 0, glyph < inspector.glyphCount else {
        throw PDFError(.malformed, "A shaped glyph id is outside the font program")
      }
    }
    var widths: [Int: Int] = [:]
    for glyph in orderedGlyphs {
      guard let advance = inspector.advances[glyph] else {
        throw PDFError(.malformed, "The font program has no advance for a shaped glyph")
      }
      widths[glyph] = Int(
        (Double(advance) * 1000 / Double(max(1, inspector.unitsPerEm))).rounded())
    }
    let tagged = "\(tag(glyphs: orderedGlyphs))+\(baseName)"
    var wEntries: [PDFValue] = []
    for glyph in orderedGlyphs {
      wEntries.append(.integer(Int64(glyph)))
      wEntries.append(.array([.integer(Int64(widths[glyph] ?? 0))]))
    }
    var descendant: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("CIDFontType2")),
      PDFName("BaseFont"): .name(PDFName(tagged)),
      PDFName("CIDSystemInfo"): .dictionary([
        PDFName("Registry"): .string(Data("Adobe".utf8)),
        PDFName("Ordering"): .string(Data("Identity".utf8)),
        PDFName("Supplement"): .integer(0),
      ]),
      PDFName("DW"): .integer(1000),
      PDFName("W"): .array(wEntries),
    ]
    if writingMode == .vertical {
      let defaultAdvance = verticalAdvanceValue(
        nil, pointSize: pointSize, inspector: inspector, override: verticalAdvances)
      descendant[PDFName("DW2")] = .array([
        .integer(Int64(defaultAdvance)), .integer(-1000),
      ])
      var w2Entries: [PDFValue] = []
      for glyph in orderedGlyphs {
        let advance = verticalAdvanceValue(
          glyph, pointSize: pointSize, inspector: inspector, override: verticalAdvances)
        w2Entries.append(.integer(Int64(glyph)))
        w2Entries.append(
          .array([
            .integer(Int64(advance)), .integer(0), .integer(-1000),
          ]))
      }
      descendant[PDFName("W2")] = .array(w2Entries)
    }
    var descriptor = FontWriter.descriptor(baseName: tagged, inspector: inspector)
    var bfchar: [String] = []
    for glyph in orderedGlyphs {
      // Visible shaped glyphs carry no extractable Unicode of their own: the
      // marked-content /ActualText and the invisible logical text below are
      // the copy/search source. Mapping them to U+200B keeps extractors from
      // emitting a duplicate or visually ordered copy of the paragraph.
      let text = unicodeByGlyph[glyph] ?? "\u{200B}"
      var destination = ""
      for unit in text.utf16 {
        destination += String(format: "%04X", Int(unit))
      }
      if destination.isEmpty { destination = "200B" }
      bfchar.append(String(format: "<%04X> <%@>", glyph, destination))
    }
    let cmapText =
      "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo\n<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n\(bfchar.count) beginbfchar\n\(bfchar.joined(separator: "\n"))\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    descriptor.removeValue(forKey: PDFName("FontFile2"))
    return WrittenShapedFont(
      baseName: tagged, widths: widths, descendant: .dictionary(descendant),
      descriptor: .dictionary(descriptor),
      fontFile: PDFStream(bytes: program),
      toUnicode: PDFStream(bytes: Data(cmapText.utf8)),
      writingMode: writingMode, glyphIDs: orderedGlyphs)
  }

  static func verticalAdvanceValue(
    _ glyph: Int?, pointSize: Double, inspector: TrueTypeInspector,
    override: [Int: Double]?
  ) -> Int {
    if let glyph, let value = override?[glyph], value.isFinite, value > 0,
      pointSize > 0
    {
      return max(1, Int((value / pointSize * 1000).rounded()))
    }
    let ascent = Double(inspector.ascent) * 1000 / Double(max(1, inspector.unitsPerEm))
    return max(1, Int(ascent.rounded()))
  }

  static func tag(glyphs: [Int]) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for glyph in glyphs {
      hash = (hash ^ UInt64(bitPattern: Int64(glyph))) &* 0x0000_0100_0000_01B3
    }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    var result = ""
    for index in 0..<6 {
      result.append(alphabet[Int((hash >> UInt64(index * 5)) & 0x1F) % alphabet.count])
    }
    return result
  }
}

/// FNT-05: insert one logically ordered bidirectional paragraph as visually
/// ordered glyph runs. Each line is wrapped in a marked content span carrying
/// the logical text as /ActualText, so copy, search and extraction in an
/// independent reader keep the logical order instead of the painted order.
public struct InsertBidirectionalTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let origin: [Double]
  public let pointSize: Double
  public let color: [Double]
  public let font: ShapedFontSource
  public let text: String
  public let language: String?
  public let baseDirection: BidiBaseDirection

  public init(
    pageID: PDFObjectID, origin: [Double], pointSize: Double = 14,
    color: [Double] = [0, 0, 0], font: ShapedFontSource, text: String,
    language: String? = nil, baseDirection: BidiBaseDirection = .automatic
  ) {
    self.pageID = pageID
    self.origin = origin
    self.pointSize = pointSize
    self.color = color
    self.font = font
    self.text = text
    self.language = language
    self.baseDirection = baseDirection
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Insert Bidirectional Text" }

  public func validate(in graph: PDFGraph) throws {
    try ShapedTextInsertion.validateCommon(
      pageID: pageID, origin: origin, pointSize: pointSize, color: color,
      text: text, graph: graph)
    let CTFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
    let shaped = try BidiShaping.shape(
      text, font: CTFont, fontName: font.fontName, pointSize: pointSize,
      language: language, baseDirection: baseDirection)
    try ShapedTextInsertion.requireCovered(shaped)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    let ctFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
    let shaped = try BidiShaping.shape(
      text, font: ctFont, fontName: font.fontName, pointSize: pointSize,
      language: language, baseDirection: baseDirection)
    return try ShapedTextInsertion.insert(
      pageID: pageID, graph: graph, shapedLines: [shaped], origins: [origin],
      pointSize: pointSize, color: color, font: font,
      writingMode: .horizontal)
  }
}

/// FNT-06: insert horizontal CJK text with kinsoku line breaking. Each line is
/// a normal Identity-H run from the same shaped font and carries the logical
/// line text as /ActualText.
public struct InsertHorizontalCJKTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let origin: [Double]
  public let maxWidth: Double
  public let lineSpacing: Double
  public let pointSize: Double
  public let color: [Double]
  public let font: ShapedFontSource
  public let text: String

  public init(
    pageID: PDFObjectID, origin: [Double], maxWidth: Double,
    lineSpacing: Double = 0, pointSize: Double = 14,
    color: [Double] = [0, 0, 0], font: ShapedFontSource, text: String
  ) {
    self.pageID = pageID
    self.origin = origin
    self.maxWidth = maxWidth
    self.lineSpacing = lineSpacing
    self.pointSize = pointSize
    self.color = color
    self.font = font
    self.text = text
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Insert Horizontal CJK Text" }

  public func validate(in graph: PDFGraph) throws {
    try ShapedTextInsertion.validateCommon(
      pageID: pageID, origin: origin, pointSize: pointSize, color: color,
      text: text, graph: graph)
    guard maxWidth.isFinite, maxWidth > 0 else {
      throw PDFError(.malformed, "The CJK line width is not usable")
    }
    let ctFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
    let lines = try CJKLineBreaker.breakLines(
      text, maxWidth: maxWidth, font: ctFont, pointSize: pointSize)
    for line in lines {
      let shaped = try BidiShaping.shape(
        line, font: ctFont, fontName: font.fontName, pointSize: pointSize)
      try ShapedTextInsertion.requireCovered(shaped)
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    let ctFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
    let lines = try CJKLineBreaker.breakLines(
      text, maxWidth: maxWidth, font: ctFont, pointSize: pointSize)
    var shapedLines: [ShapedParagraph] = []
    var origins: [[Double]] = []
    let spacing = lineSpacing > 0 ? lineSpacing : pointSize * 1.25
    for (index, line) in lines.enumerated() {
      shapedLines.append(
        try BidiShaping.shape(
          line, font: ctFont, fontName: font.fontName, pointSize: pointSize))
      origins.append([origin[0], origin[1] - Double(index) * spacing])
    }
    return try ShapedTextInsertion.insert(
      pageID: pageID, graph: graph, shapedLines: shapedLines, origins: origins,
      pointSize: pointSize, color: color, font: font, writingMode: .horizontal)
  }
}

/// FNT-06: insert vertical CJK columns. The font is embedded as Identity-V
/// with /W2 and /DW2 vertical advances; columns run top-to-bottom and are
/// placed right-to-left. Punctuation in the declared rotated set is painted
/// rotated by 90 degrees; /ActualText keeps the logical text recoverable.
public struct InsertVerticalCJKTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let origin: [Double]
  public let columnHeight: Double
  public let columnPitch: Double
  public let pointSize: Double
  public let color: [Double]
  public let font: ShapedFontSource
  public let text: String

  public init(
    pageID: PDFObjectID, origin: [Double], columnHeight: Double = 320,
    columnPitch: Double = 0, pointSize: Double = 18,
    color: [Double] = [0, 0, 0], font: ShapedFontSource, text: String
  ) {
    self.pageID = pageID
    self.origin = origin
    self.columnHeight = columnHeight
    self.columnPitch = columnPitch
    self.pointSize = pointSize
    self.color = color
    self.font = font
    self.text = text
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Insert Vertical CJK Text" }

  public func validate(in graph: PDFGraph) throws {
    try ShapedTextInsertion.validateCommon(
      pageID: pageID, origin: origin, pointSize: pointSize, color: color,
      text: text, graph: graph)
    guard columnHeight.isFinite, columnHeight > pointSize else {
      throw PDFError(.malformed, "The vertical column height is not usable")
    }
    let ctFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
    do {
      _ = try VerticalTextLayout.columns(
        text, font: ctFont, fontName: font.fontName, pointSize: pointSize,
        columnHeight: columnHeight, originX: origin[0], originY: origin[1],
        columnPitch: columnPitch > 0 ? columnPitch : nil)
    } catch let error as CJKLayoutError {
      throw PDFError(.unsupported, error.description)
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    let ctFont = CTFontCreateWithName(font.fontName as CFString, pointSize, nil)
    let columns = try VerticalTextLayout.columns(
      text, font: ctFont, fontName: font.fontName, pointSize: pointSize,
      columnHeight: columnHeight, originX: origin[0], originY: origin[1],
      columnPitch: columnPitch > 0 ? columnPitch : nil)
    var glyphs: [Int] = []
    var verticalAdvances: [Int: Double] = [:]
    for column in columns {
      for cell in column.cells {
        if !glyphs.contains(cell.glyphID) { glyphs.append(cell.glyphID) }
        verticalAdvances[cell.glyphID] = cell.advance
      }
    }
    var graph = graph
    let written = try ShapedFontWriter.write(
      program: font.program, baseName: font.baseName, glyphs: glyphs,
      unicodeByGlyph: [:], pointSize: pointSize,
      writingMode: .vertical, verticalAdvances: verticalAdvances)
    let fontName = try ShapedTextInsertion.addFont(
      written: written, pageID: pageID, in: &graph)
    let fontToken = ShapedTextInsertion.fontResourceToken(fontName)
    let invisible = try ShapedTextInsertion.addInvisibleLogicalFont(
      scalars: columns.flatMap { column in
        column.text.unicodeScalars.map(\.value)
      }, pageID: pageID, in: &graph)
    let invisibleToken = ShapedTextInsertion.fontResourceToken(invisible.name)
    var content = "q\n"
    for column in columns {
      content += "BT\n/\(fontToken) \(ShapedTextInsertion.number(pointSize)) Tf\n"
      content += ShapedTextInsertion.colorOperators(color)
      for cell in column.cells {
        guard let code = written.encode([cell.glyphID]) else {
          throw PDFError(.malformed, "A vertical glyph could not be encoded")
        }
        let hex = ShapedTextInsertion.hexCodes(code)
        if cell.isRotated {
          content += "0 -1 1 0 \(ShapedTextInsertion.number(cell.x)) \(ShapedTextInsertion.number(cell.y)) Tm <\(hex)> Tj\n"
        } else {
          content += "1 0 0 1 \(ShapedTextInsertion.number(cell.x)) \(ShapedTextInsertion.number(cell.y)) Tm <\(hex)> Tj\n"
        }
      }
      content += "ET\nEMC\n"
      // Invisible logical column text for copy/search, with /ActualText so
      // simple-font readers keep the logical order.
      let logicalHex = ShapedTextInsertion.hexCodes(
        ShapedTextInsertion.encodeLogical(column.text, font: invisible))
      content += "BT\n/\(invisibleToken) \(ShapedTextInsertion.number(pointSize)) Tf\n3 Tr\n"
      content += "1 0 0 1 \(ShapedTextInsertion.number(column.x)) \(ShapedTextInsertion.number(column.topY)) Tm <\(logicalHex)> Tj\n"
      content += "ET\nEMC\n"
    }
    content += "Q\n"
    try ShapedTextInsertion.append(
      content: content, pageID: pageID, in: &graph)
    return graph
  }
}

/// FNT-05/FNT-06: shared insertion plumbing.
enum ShapedTextInsertion {
  static func validateCommon(
    pageID: PDFObjectID, origin: [Double], pointSize: Double, color: [Double],
    text: String, graph: PDFGraph
  ) throws {
    guard try PDFPageTree.pageIDs(in: graph).contains(pageID) else {
      throw PDFError(.malformed, "The shaped text page is missing")
    }
    guard origin.count == 2, origin.allSatisfy({ $0.isFinite }),
      abs(origin[0]) <= 1_000_000, abs(origin[1]) <= 1_000_000
    else {
      throw PDFError(.malformed, "The shaped text origin is not usable")
    }
    guard pointSize.isFinite, (2...200).contains(pointSize) else {
      throw PDFError(.malformed, "The shaped text point size is outside the profile")
    }
    guard color.count == 3, color.allSatisfy({ $0.isFinite && (0...1).contains($0) })
    else {
      throw PDFError(.malformed, "The shaped text color is not usable")
    }
    guard !text.isEmpty else {
      throw PDFError(.malformed, "The shaped text is empty")
    }
    guard text.utf16.count <= 8_192 else {
      throw PDFError(.limitExceeded, "The shaped text paragraph is too long")
    }
  }

  static func requireCovered(_ shaped: ShapedParagraph) throws {
    guard !shaped.hasMissingGlyphs else {
      throw PDFError(.unsupported, missingGlyphMessage(shaped.missingScalars))
    }
    guard shaped.coversEveryUnit else {
      throw PDFError(.unsupported, "The shaping result does not cover every logical character")
    }
  }

  static func missingGlyphMessage(_ scalars: [UInt32]) -> String {
    let list = scalars.prefix(8).map { String(format: "U+%04X", $0) }.joined(separator: ", ")
    return "The selected font has no glyph for: \(list)"
  }

  static func insert(
    pageID: PDFObjectID, graph: PDFGraph, shapedLines: [ShapedParagraph],
    origins: [[Double]], pointSize: Double, color: [Double],
    font: ShapedFontSource, writingMode: CompositeFontWritingMode
  ) throws -> PDFGraph {
    guard shapedLines.count == origins.count else {
      throw PDFError(.malformed, "Shaped lines and positions do not match")
    }
    var glyphs: [Int] = []
    let units = Array(shapedLines.map { Array($0.text.utf16) })
    for (lineIndex, shaped) in shapedLines.enumerated() {
      for run in shaped.runs {
        for glyph in run.glyphs {
          if !glyphs.contains(glyph.glyphID) { glyphs.append(glyph.glyphID) }
          let localRange = glyph.sourceRange
          guard localRange.lowerBound >= 0,
            localRange.upperBound <= units[lineIndex].count,
            localRange.lowerBound < localRange.upperBound
          else {
            throw PDFError(.malformed, "A shaped glyph lost its logical source range")
          }
        }
      }
    }
    var graph = graph
    let written = try ShapedFontWriter.write(
      program: font.program, baseName: font.baseName, glyphs: glyphs,
      unicodeByGlyph: [:], pointSize: pointSize,
      writingMode: writingMode)
    let fontName = try addFont(written: written, pageID: pageID, in: &graph)
    let fontToken = fontResourceToken(fontName)
    let logicalScalars = shapedLines.flatMap { paragraph in
      paragraph.text.unicodeScalars.map(\.value)
    }
    let invisible = try addInvisibleLogicalFont(
      scalars: logicalScalars, pageID: pageID, in: &graph)
    let invisibleToken = fontResourceToken(invisible.name)
    var content = "q\n"
    for (lineIndex, shaped) in shapedLines.enumerated() {
      let origin = origins[lineIndex]
      content += "BT\n/\(fontToken) \(number(pointSize)) Tf\n"
      content += colorOperators(color)
      var x = origin[0]
      for run in shaped.runs {
        guard let code = written.encode(run.glyphs.map(\.glyphID)) else {
          throw PDFError(.malformed, "A shaped glyph could not be encoded")
        }
        content += "1 0 0 1 \(number(x)) \(number(origin[1])) Tm <\(hexCodes(code))> Tj\n"
        x += run.advance
      }
      content += "ET\nEMC\n"
      // Invisible logical text: the copy/search source for this line. The
      // marked-content /ActualText makes simple-font readers (mutool, poppler)
      // emit the logical order instead of their bidi visual order.
      let logicalHex = hexCodes(
        encodeLogical(shaped.text, font: invisible))
      content += "BT\n/\(invisibleToken) \(number(pointSize)) Tf\n3 Tr\n"
      content += "1 0 0 1 \(number(origin[0])) \(number(origin[1])) Tm <\(logicalHex)> Tj\n"
      content += "ET\nEMC\n"
    }
    content += "Q\n"
    try append(content: content, pageID: pageID, in: &graph)
    return graph
  }

  struct InvisibleLogicalFont {
    let name: PDFName
    let codes: [UInt32: UInt8]
  }

  /// Add a simple Type1 font whose only job is logical extraction: every
  /// distinct scalar gets a one-byte code and a ToUnicode mapping. It is drawn
  /// with text rendering mode 3, so it is invisible but extracted in logical
  /// order by independent readers and search.
  static func addInvisibleLogicalFont(
    scalars: [UInt32], pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws -> InvisibleLogicalFont {
    let unique = Array(Set(scalars)).sorted()
    guard !unique.isEmpty else {
      throw PDFError(.malformed, "The shaped text has no logical characters")
    }
    guard unique.count <= 255 else {
      throw PDFError(.limitExceeded, "A shaped paragraph has too many distinct characters")
    }
    var next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let fontID = PDFObjectID(next); next += 1
    let cmapID = PDFObjectID(next); next += 1
    var codes: [UInt32: UInt8] = [:]
    var differences: [PDFValue] = [.integer(1)]
    var bfchar: [String] = []
    for (index, scalar) in unique.enumerated() {
      let code = UInt8(index + 1)
      codes[scalar] = code
      differences.append(.name(PDFName("g\(index + 1)")))
      let destination = utf16Hex(scalar: scalar)
      bfchar.append(String(format: "<%02X> <%@>", Int(code), destination))
    }
    let cmapText =
      "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo\n<< /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n\(bfchar.count) beginbfchar\n\(bfchar.joined(separator: "\n"))\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    graph.objects[cmapID] = .stream(
      PDFStream(bytes: Data(cmapText.utf8)))
    // Real advances keep extractors from treating the invisible glyphs as one
    // overlapping cluster; the values are arbitrary because the text mode is 3.
    let widthEntries = unique.indices.map { index in
      PDFValue.integer(500)
    }
    graph.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("FirstChar"): .integer(1),
      PDFName("LastChar"): .integer(Int64(unique.count)),
      PDFName("Widths"): .array(widthEntries),
      PDFName("Encoding"): .dictionary([
        PDFName("Type"): .name(PDFName("Encoding")),
        PDFName("Differences"): .array(differences),
      ]),
      PDFName("ToUnicode"): .reference(cmapID),
    ])
    let name = uniqueFontName(pageID: pageID, in: graph)
    try OCRLayer.addFontResource(name: name, fontID: fontID, pageID: pageID, in: &graph)
    graph.trailer[PDFName("Size")] = .integer(Int64(next))
    return InvisibleLogicalFont(name: name, codes: codes)
  }

  static func actualTextSpan(_ logical: String) -> String {
    var hex = "FEFF"
    for unit in logical.utf16 { hex += String(format: "%04X", Int(unit)) }
    return "/Span << /ActualText <\(hex)> >> BDC\n"
  }

  static func utf16Hex(scalar: UInt32) -> String {
    guard let unicode = UnicodeScalar(scalar) else { return "0020" }
    var hex = ""
    for unit in String(Character(unicode)).utf16 {
      hex += String(format: "%04X", Int(unit))
    }
    return hex.isEmpty ? "0020" : hex
  }

  static func encodeLogical(_ text: String, font: InvisibleLogicalFont) -> [UInt8] {
    var bytes: [UInt8] = []
    for scalar in text.unicodeScalars {
      if let code = font.codes[scalar.value] { bytes.append(code) }
    }
    return bytes
  }

  static func hexCodes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", Int($0)) }.joined()
  }

  static func addFont(
    written: WrittenShapedFont, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws -> PDFName {
    var next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    func allocate() -> PDFObjectID {
      defer { next += 1 }
      return PDFObjectID(next)
    }
    let toUnicodeID = allocate()
    let descendantID = allocate()
    let descriptorID = allocate()
    let programID = allocate()
    let fontID = allocate()
    graph.objects[toUnicodeID] = .stream(written.toUnicode)
    graph.objects[programID] = .stream(written.fontFile)
    var descriptor: [PDFName: PDFValue]
    if case .dictionary(let values) = written.descriptor {
      descriptor = values
    } else {
      throw PDFError(.malformed, "The shaped font descriptor is malformed")
    }
    descriptor[PDFName("FontFile2")] = .reference(programID)
    graph.objects[descriptorID] = .dictionary(descriptor)
    var descendant: [PDFName: PDFValue]
    if case .dictionary(let values) = written.descendant {
      descendant = values
    } else {
      throw PDFError(.malformed, "The shaped font descendant is malformed")
    }
    descendant[PDFName("FontDescriptor")] = .reference(descriptorID)
    graph.objects[descendantID] = .dictionary(descendant)
    graph.objects[fontID] = written.type0Dictionary(
      descendantID: descendantID, toUnicodeID: toUnicodeID)
    let fontName = uniqueFontName(pageID: pageID, in: graph)
    try OCRLayer.addFontResource(
      name: fontName, fontID: fontID, pageID: pageID, in: &graph)
    graph.trailer[PDFName("Size")] = .integer(Int64(next))
    return fontName
  }

  static func uniqueFontName(pageID: PDFObjectID, in graph: PDFGraph) -> PDFName {
    var existing: Set<PDFName> = []
    if case .dictionary(let page)? = graph.objects[pageID] {
      var resources: [PDFName: PDFValue]?
      switch page[PDFName("Resources")] {
      case .dictionary(let value)?: resources = value
      case .reference(let id)?:
        if case .dictionary(let value)? = graph.objects[id] { resources = value }
      default: break
      }
      if case .dictionary(let fonts)? = resources?[PDFName("Font")] {
        existing = Set(fonts.keys)
      }
    }
    var counter = 1
    while true {
      let candidate = PDFName("SPDFShaped\(counter)")
      if !existing.contains(candidate) { return candidate }
      counter += 1
    }
  }

  static func fontResourceToken(_ name: PDFName) -> String {
    String(decoding: name.bytes, as: UTF8.self)
  }

  static func colorOperators(_ color: [Double]) -> String {
    "\(number(color[0])) \(number(color[1])) \(number(color[2])) rg\n"
      + "\(number(color[0])) \(number(color[1])) \(number(color[2])) RG\n"
  }

  static func append(content: String, pageID: PDFObjectID, in graph: inout PDFGraph) throws {
    let bytes = Data(content.utf8)
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let streamID = PDFObjectID(next)
    graph.objects[streamID] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(bytes.count))],
        bytes: bytes))
    try FlattenAnnotationsCommand.appendContents(
      [.reference(streamID)], pageID: pageID, in: &graph)
    graph.trailer[PDFName("Size")] = .integer(Int64(next + 1))
  }

  static func number(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(format: "%.4f", value)
  }
}
