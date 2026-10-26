import AppKit
import CoreText
import Foundation
import PDFCore
import PDFFixtures
import PDFKit
import Testing

@testable import PDFEditing

/// FNT-05/FNT-06: bidirectional writing with /ActualText, horizontal CJK
/// kinsoku writing, and vertical Identity-V CJK writing, plus the pure line
/// breaking and vertical layout profiles.
@Suite("CJK and shaped writing")
struct FNTShapedTextTests {
  static let arialUnicodePath = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
  static let arialUnicodeName = "ArialUnicodeMS"

  static func arialUnicodeProgram() -> Data? {
    guard FileManager.default.fileExists(atPath: arialUnicodePath) else { return nil }
    return try? Data(contentsOf: URL(fileURLWithPath: arialUnicodePath))
  }

  static func arialUnicodeFont(_ size: CGFloat = 20) -> CTFont? {
    guard FileManager.default.fileExists(atPath: arialUnicodePath) else { return nil }
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
      URL(fileURLWithPath: arialUnicodePath) as CFURL) as? [CTFontDescriptor]
    guard let descriptor = descriptors?.first else { return nil }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
  }

  static let sfArabicPath = "/System/Library/Fonts/SFArabic.ttf"
  static let sfHebrewPath = "/System/Library/Fonts/SFHebrew.ttf"

  func fontSource() -> ShapedFontSource? {
    guard let program = Self.arialUnicodeProgram() else { return nil }
    return ShapedFontSource(
      program: program, fontName: Self.arialUnicodeName, baseName: "ArialUnicodeMS")
  }

  func programSource(path: String, fontName: String, baseName: String) -> ShapedFontSource? {
    guard FileManager.default.fileExists(atPath: path),
      let program = try? Data(contentsOf: URL(fileURLWithPath: path))
    else { return nil }
    return ShapedFontSource(program: program, fontName: fontName, baseName: baseName)
  }

  func arabicSource() -> ShapedFontSource? {
    if let small = programSource(
      path: Self.sfArabicPath, fontName: ".SF Arabic", baseName: "SFArabic")
    {
      return small
    }
    return fontSource()
  }

  func hebrewSource() -> ShapedFontSource? {
    if let small = programSource(
      path: Self.sfHebrewPath, fontName: ".SF Hebrew", baseName: "SFHebrew")
    {
      return small
    }
    return fontSource()
  }

  func pageID(_ graph: PDFGraph) throws -> PDFObjectID {
    try #require(try PDFPageTree.pageIDs(in: graph).first)
  }

  func savedReopened(_ graph: PDFGraph) throws -> PDFGraph {
    try PDFParser.parse(try PDFWriter.write(graph)).graph
  }

  func pageText(_ graph: PDFGraph, pageIndex: Int = 0) throws -> String {
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data), let page = document.page(at: pageIndex)
    else { return "" }
    return page.string ?? ""
  }

  /// PDFKit search honours /ActualText even though page.string returns the
  /// painted order; external poppler extraction is used for copy evidence when
  /// it is installed (CI may not ship it).
  func findsText(_ needle: String, in graph: PDFGraph) throws -> Bool {
    let data = try PDFWriter.write(graph)
    guard let document = PDFDocument(data: data) else { return false }
    return document.findString(needle, withOptions: []) != nil
  }

  /// Independent logical extraction: mutool honours /ActualText and emits the
  /// logical order; poppler emits visual order with standard bidi controls, so
  /// its output is reordered back before comparison. Returns nil when neither
  /// tool is installed (CI runners may lack both); PDFKit search still runs.
  func externalLogicalText(_ graph: PDFGraph) throws -> String? {
    let data = try PDFWriter.write(graph)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-shaped-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("shaped.pdf")
    try data.write(to: url)
    func run(_ tool: String, _ arguments: [String]) throws -> String? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      let output = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = output
      process.standardError = errorPipe
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    // poppler's bidi control characters make its visual-order output
    // reversible to logical text; mutool writes plain visual order for RTL
    // text, so it is not used for the logical-copy claim.
    let popplerPaths = ["/opt/homebrew/bin/pdftotext", "/usr/local/bin/pdftotext"]
    if let tool = popplerPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
      let text = try? run(tool, [url.path, "-"])
    {
      return logicalFromPoppler(text)
    }
    return nil
  }

  /// poppler's text output is visual order wrapped in RLE/PDF controls; the
  /// enclosed characters are reversed relative to logical order.
  func logicalFromPoppler(_ text: String) -> String {
    var scalars = Array(text.unicodeScalars)
    var output = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
      if scalars[index].value == 0x202B {
        var end = index + 1
        var depth = 1
        while end < scalars.count {
          if scalars[end].value == 0x202B { depth += 1 }
          if scalars[end].value == 0x202C {
            depth -= 1
            if depth == 0 { break }
          }
          end += 1
        }
        if end < scalars.count {
          let inner = Array(scalars[(index + 1)..<end])
          output.append(contentsOf: inner.reversed())
          index = end + 1
          continue
        }
      }
      if [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        .contains(scalars[index].value)
      {
        index += 1
        continue
      }
      output.append(scalars[index])
      index += 1
    }
    return String(output)
  }

  /// poppler wraps /ActualText right-to-left spans in the standard bidi
  /// controls; they are extraction structure, not document text.
  func normalizedBidi(_ text: String) -> String {
    let stripped = String(text.unicodeScalars.filter { scalar in
      switch scalar.value {
      case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x200B, 0x200C,
        0x200D, 0xFEFF:
        return false
      default:
        return true
      }
    })
    // poppler may split a logical line at its own line-break heuristics;
    // collapse whitespace for logical-substring comparison.
    let replaced = stripped
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
    var collapsed = ""
    var pendingSpace = false
    for character in replaced {
      if character == " " {
        pendingSpace = true
        continue
      }
      if pendingSpace, !collapsed.isEmpty { collapsed.append(" ") }
      pendingSpace = false
      collapsed.append(character)
    }
    return collapsed
  }

  func normalized(_ text: String) -> String {
    normalizedBidi(text)
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\t", with: "")
  }

  func compositeFonts(in graph: PDFGraph, pageID: PDFObjectID) throws -> [CompositeFont] {
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph),
      case .dictionary(let fonts)? = FontValue.resolve(resources[PDFName("Font")], in: graph)
    else { return [] }
    var result: [CompositeFont] = []
    for (_, value) in fonts {
      guard case .reference(let id) = value,
        case .dictionary(let dictionary)? = graph.objects[id],
        let font = CompositeFont.parse(dictionary, in: graph, objectID: id)
      else { continue }
      result.append(font)
    }
    return result
  }

  // MARK: - Line breaking profile

  @Test func kinsokuLineBreakingKeepsPunctuationWithText() {
    let text = "日本語、テスト。あ（いう）え"
    let lines = CJKLineBreaker.breakLines(text, maxWidth: 4) { Double($0.count) }
    #expect(!lines.isEmpty)
    #expect(lines.joined() == text)
    for line in lines where line.count > 1 {
      let first = line.first!
      #expect(!CJKProfile.prohibitedLineStart.contains(first), "line starts with \(first)")
      let last = line.last!
      #expect(!CJKProfile.prohibitedLineEnd.contains(last), "line ends with \(last)")
    }
    // The opening bracket must not end a line when avoidable.
    let bracketText = "あ（いう）え"
    let bracketLines = CJKLineBreaker.breakLines(bracketText, maxWidth: 3) { Double($0.count) }
    #expect(bracketLines.joined() == bracketText)
    for line in bracketLines {
      #expect(!CJKProfile.prohibitedLineEnd.contains(line.last ?? " "))
    }
  }

  @Test func latinWordsAreNotSplitAtCharacterBoundaries() {
    let text = "ABC日本語DEF"
    let lines = CJKLineBreaker.breakLines(text, maxWidth: 5) { Double($0.count) }
    #expect(lines.joined() == text)
    // "ABC" stays in one line and is never broken between A and B.
    #expect(lines.contains { $0.contains("ABC") })
    for line in lines where line.count >= 2 && line.hasPrefix("A") {
      #expect(line.hasPrefix("ABC"))
    }
  }

  @Test func verticalLayoutIsTopToBottomAndRightToLeft() throws {
    guard let font = Self.arialUnicodeFont(20) else { return }
    let text = "日本語、テスト。"
    let columns = try VerticalTextLayout.columns(
      text, font: font, fontName: Self.arialUnicodeName, pointSize: 20,
      columnHeight: 80, originX: 500, originY: 700)
    #expect(columns.count >= 2)
    #expect(columns.map(\.text).joined() == text)
    for column in columns {
      #expect(!column.cells.isEmpty)
      var previousY = Double.infinity
      for cell in column.cells {
        #expect(cell.y < previousY + 0.01)
        previousY = cell.y
        #expect(cell.glyphID > 0)
      }
    }
    // Columns advance right-to-left.
    for index in 1..<columns.count {
      #expect(columns[index].x < columns[index - 1].x)
    }
    let rotated = columns.flatMap(\.cells).filter(\.isRotated)
    #expect(!rotated.isEmpty)
    #expect(rotated.allSatisfy { cell in
      CJKProfile.rotatedInVertical.contains(Character(cell.character))
    })
    #expect(rotated.contains { $0.character == "、" })
  }

  @Test func verticalProfileRefusesLatinCharacters() throws {
    guard let font = Self.arialUnicodeFont(20) else { return }
    do {
      _ = try VerticalTextLayout.columns(
        "abc", font: font, fontName: Self.arialUnicodeName, pointSize: 20,
        columnHeight: 200, originX: 500, originY: 700)
      Issue.record("expected a vertical profile refusal")
    } catch let error as CJKLayoutError {
      #expect(error.description.contains("does not support"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  // MARK: - Bidirectional writing

  @Test func arabicParagraphExtractsInLogicalOrderAfterReopen() throws {
    guard let source = fontSource() else { return }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let text = "مرحبا بالعالم"
    let command = InsertBidirectionalTextCommand(
      pageID: pageID, origin: [72, 600], pointSize: 20, font: source, text: text,
      language: "ar")
    let written = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try savedReopened(written)
    #expect(try findsText(text, in: reopened))
    if let external = try externalLogicalText(reopened) {
      #expect(normalizedBidi(external).contains(text), "extracted: \(external)")
    }
    let fonts = try compositeFonts(in: reopened, pageID: pageID)
    let shapedFont = try #require(fonts.first)
    #expect(shapedFont.encodingKind == .identityHorizontal)
    #expect(shapedFont.program == .trueType)
    #expect(shapedFont.hasUnicodeCMap)
    #expect(!shapedFont.hasCIDToGIDMap)
    #expect(shapedFont.codeToUnicode.values.allSatisfy { !$0.isEmpty })
  }

  @Test func mixedDirectionParagraphKeepsLogicalCopy() throws {
    guard let source = fontSource() else { return }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let text = "ABC مرحبا 123"
    let command = InsertBidirectionalTextCommand(
      pageID: pageID, origin: [72, 620], pointSize: 18, font: source, text: text)
    let written = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try savedReopened(written)
    #expect(try findsText(text, in: reopened))
    if let external = try externalLogicalText(reopened) {
      let logical = normalizedBidi(external)
      let scalarList = logical.unicodeScalars
        .map { String(format: "%04X", $0.value) }.joined(separator: " ")
      #expect(logical.contains(text), "scalars: \(scalarList)")
      #expect(!logical.contains("ابحرم"), "scalars: \(scalarList)")
    }
  }

  @Test func hebrewParagraphExtractsInLogicalOrder() throws {
    guard let source = fontSource() else { return }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let text = "שלום עולם"
    let command = InsertBidirectionalTextCommand(
      pageID: pageID, origin: [72, 640], pointSize: 18, font: source, text: text,
      language: "he")
    let written = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try savedReopened(written)
    #expect(try findsText(text, in: reopened))
    if let external = try externalLogicalText(reopened) {
      let logical = normalizedBidi(external)
      #expect(logical.contains(text), "extracted: \(external)")
      #expect(!logical.contains(String(text.reversed())))
    }
  }

  @Test func missingGlyphWritingRefusesBeforeMutation() throws {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let source = ShapedFontSource(
      program: Data([0x00, 0x01, 0x00, 0x00]), fontName: "Helvetica",
      baseName: "Helvetica")
    let command = InsertBidirectionalTextCommand(
      pageID: pageID, origin: [72, 600], pointSize: 16, font: source, text: "مرحبا")
    do {
      try command.validate(in: graph)
      Issue.record("expected a missing-glyph refusal")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("U+06") || error.message.contains("glyph"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  // MARK: - CJK writing

  @Test func horizontalCJKWritingWrapsWithKinsokuAndReopens() throws {
    guard let source = fontSource() else { return }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let text = "日本語のテスト。あいうえお"
    let command = InsertHorizontalCJKTextCommand(
      pageID: pageID, origin: [72, 700], maxWidth: 60, pointSize: 18, font: source,
      text: text)
    let written = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try savedReopened(written)
    #expect(try findsText("日本語", in: reopened))
    if let external = try externalLogicalText(reopened) {
      let logical = normalized(external)
      let font = try #require(Self.arialUnicodeFont(18))
      let expectedLines = try CJKLineBreaker.breakLines(
        text, maxWidth: 60, font: font, pointSize: 18)
      for line in expectedLines {
        #expect(logical.contains(line), "line \(line) missing in \(external)")
      }
      let sourceCounts = Dictionary(
        text.map { ($0, 1) }, uniquingKeysWith: +)
      let extractedCounts = Dictionary(
        logical.map { ($0, 1) }, uniquingKeysWith: +)
      for (character, count) in sourceCounts {
        #expect((extractedCounts[character] ?? 0) >= count)
      }
    }
    let fonts = try compositeFonts(in: reopened, pageID: pageID)
    let shapedFont = try #require(fonts.first)
    #expect(shapedFont.encodingKind == .identityHorizontal)
    #expect(!shapedFont.hasVerticalMetrics)
  }

  @Test func verticalCJKWritingUsesIdentityVAndReopens() throws {
    guard let source = fontSource() else { return }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let text = "日本語、テスト。"
    let command = InsertVerticalCJKTextCommand(
      pageID: pageID, origin: [500, 720], columnHeight: 70, pointSize: 18,
      font: source, text: text)
    let written = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try savedReopened(written)
    let fonts = try compositeFonts(in: reopened, pageID: pageID)
    let shapedFont = try #require(fonts.first)
    #expect(shapedFont.encodingKind == .identityVertical)
    #expect(shapedFont.writingMode == .vertical)
    #expect(shapedFont.hasVerticalMetrics)
    #expect(shapedFont.verticalWidths.count >= 1)
    #expect(try findsText("日本語", in: reopened))
    if let external = try externalLogicalText(reopened) {
      let logical = normalized(external)
      let font = try #require(Self.arialUnicodeFont(18))
      let columns = try VerticalTextLayout.columns(
        text, font: font, fontName: Self.arialUnicodeName, pointSize: 18,
        columnHeight: 70, originX: 500, originY: 720)
      for column in columns {
        #expect(
          logical.contains(normalized(column.text)),
          "column \(column.text) missing in \(external)")
      }
      let sourceCounts = Dictionary(
        text.map { ($0, 1) }, uniquingKeysWith: +)
      let extractedCounts = Dictionary(
        logical.map { ($0, 1) }, uniquingKeysWith: +)
      for (character, count) in sourceCounts {
        #expect((extractedCounts[character] ?? 0) >= count)
      }
    }
    // Rotated punctuation is painted with a 90 degree matrix.
    let data = try PDFWriter.write(reopened)
    let textBytes = String(decoding: data, as: UTF8.self)
    #expect(textBytes.contains("0 -1 1 0"))
  }

  @Test func verticalWritingRefusesLatinText() throws {
    guard let source = fontSource() else { return }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let pageID = try pageID(graph)
    let command = InsertVerticalCJKTextCommand(
      pageID: pageID, origin: [500, 700], columnHeight: 200, pointSize: 18,
      font: source, text: "abc")
    do {
      try command.validate(in: graph)
      Issue.record("expected a vertical profile refusal")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("does not support"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }
}
