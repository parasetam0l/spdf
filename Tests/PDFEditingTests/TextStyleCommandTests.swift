import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P18-014/015/016/018/019/022/030 evidence: style changes, move/resize,
/// multi-instruction spans, link reporting, marked-content preservation,
/// editability reasons, and the recorded writable profile. P15-027 evidence:
/// fallback-substituted text renders and extracts in independent readers.
@Suite("Text style and span editing")
struct TextStyleCommandTests {
  private func parsed(_ data: Data) throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, parsed.pageIDs[0])
  }

  private func runs(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> [TextRun] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    return try TextRunIndexer.runs(in: content, graph: graph)
  }

  // MARK: - P18-014 style changes

  @Test func changeFontSizeRewritesOnlyTheGoverningSelection() throws {
    let (graph, pageID) = try parsed(PDFFixtures.textEditPages())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ChangeTextStyleCommand(
          pageID: pageID, runIndex: 0, style: TextStyleChange(fontSize: 18))
      ]), to: graph)
    let content = try PageContent.load(pageID: pageID, in: edited)
    let text = String(decoding: content.bytes, as: UTF8.self)
    #expect(text.contains("/F1 18 Tf"))
    // The original selection is retained and restored after this show.
    #expect(text.contains("/F1 24 Tf"))
    #expect(text.contains("(Replace this text)"))
    // Neighboring runs keep their 12 pt selections.
    #expect(text.contains("/F1 12 Tf"))
    let layout = try PageTextLayout.build(pageID: pageID, in: edited)
    #expect(layout.clusters.first { $0.runIndex == 0 }?.fontSize == 18)
    // Reopen: the size survives a full write/parse round trip.
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let relayout = try PageTextLayout.build(pageID: pageID, in: reopened.graph)
    #expect(relayout.clusters.first { $0.runIndex == 0 }?.fontSize == 18)
    #expect(
      try TextRunIndexer.runs(
        in: PageContent.load(pageID: pageID, in: reopened.graph),
        graph: reopened.graph)[0].text == "Replace this text")
  }

  @Test func changeFillColorInsertsPaintWithoutMovingText() throws {
    let (graph, pageID) = try parsed(PDFFixtures.textEditPages())
    let before = try PageTextLayout.build(pageID: pageID, in: graph)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ChangeTextStyleCommand(
          pageID: pageID, runIndex: 0, style: TextStyleChange(fillColor: [1, 0, 0]))
      ]), to: graph)
    let content = try PageContent.load(pageID: pageID, in: edited)
    #expect(String(decoding: content.bytes, as: UTF8.self).contains("1 0 0 rg"))
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    // Geometry is unchanged; only paint changed.
    #expect(after.clusters.map(\.bounds) == before.clusters.map(\.bounds))
    #expect(after.text(in: 0..<after.clusters.count) == before.text(in: 0..<before.clusters.count))
    let target = try TextEditTargeting.runTarget(atPoint: [50, 715], in: edited, pageID: pageID)
    #expect(target?.style.fillColor == [1, 0, 0])
  }

  @Test func changeFontResourceRequiresAnEncodablePageFont() throws {
    var (graph, pageID) = try parsed(PDFFixtures.textWidthsPages())
    // Add a second, otherwise identical page font.
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(var fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(let font)? = graph.objects[fontID]
    else {
      Issue.record("fixture font missing")
      return
    }
    var bold = font
    bold[PDFName("BaseFont")] = .name(PDFName("Helvetica-Bold"))
    graph.objects[PDFObjectID(40)] = .dictionary(bold)
    fonts[PDFName("F2")] = .reference(PDFObjectID(40))
    var updatedResources = resources
    updatedResources[PDFName("Font")] = .dictionary(fonts)
    var updatedPage = page
    updatedPage[PDFName("Resources")] = .dictionary(updatedResources)
    graph.objects[pageID] = .dictionary(updatedPage)

    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ChangeTextStyleCommand(
          pageID: pageID, runIndex: 0, style: TextStyleChange(fontResource: PDFName("F2")))
      ]), to: graph)
    let text = String(
      decoding: (try PageContent.load(pageID: pageID, in: edited)).bytes, as: UTF8.self)
    #expect(text.contains("/F2"))
    #expect(
      try TextRunIndexer.runs(
        in: PageContent.load(pageID: pageID, in: edited), graph: edited)[0].text == "AB")

    // Unknown resources and empty changes refuse.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ChangeTextStyleCommand(
            pageID: pageID, runIndex: 0, style: TextStyleChange(fontResource: PDFName("F9")))
        ]), to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ChangeTextStyleCommand(
            pageID: pageID, runIndex: 0, style: TextStyleChange())
        ]), to: graph)
    }
  }

  // MARK: - P18-015 move and resize

  @Test func moveTextShiftsOnlyTheTargetInstruction() throws {
    let (graph, pageID) = try parsed(PDFFixtures.textEditPages())
    let before = try PageTextLayout.build(pageID: pageID, in: graph)
    let beforeBounds = before.clusters.filter { $0.runIndex == 0 }.map(\.bounds)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([MoveTextCommand(pageID: pageID, runIndex: 0, dx: 10, dy: 5)]),
      to: graph)
    let after = try PageTextLayout.build(pageID: pageID, in: edited)
    // The target moved by exactly the offset (Td translation is exact).
    for (old, new) in zip(
      beforeBounds, after.clusters.filter { $0.runIndex == 0 }.map(\.bounds))
    {
      #expect(abs(new[0] - old[0] - 10) < 1e-9 && abs(new[1] - old[1] - 5) < 1e-9)
      #expect(abs(new[2] - old[2] - 10) < 1e-9 && abs(new[3] - old[3] - 5) < 1e-9)
    }
    // Neighbors hold their positions: the compensating Td restores the pen.
    for run in 1..<4 {
      let old = before.clusters.filter { $0.runIndex == run }.map(\.bounds)
      let new = after.clusters.filter { $0.runIndex == run }.map(\.bounds)
      #expect(old.count == new.count)
      for (left, right) in zip(old, new) {
        #expect(abs(left[0] - right[0]) < 1e-6 && abs(left[1] - right[1]) < 1e-6)
      }
    }
    // Save/reopen keeps the move.
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let relayout = try PageTextLayout.build(pageID: pageID, in: reopened.graph)
    #expect(relayout.text(in: 0..<relayout.clusters.count).contains("Replace this text"))
  }

  @Test func zeroMoveIsANoOpAndResizeSetsTheSize() throws {
    let (graph, pageID) = try parsed(PDFFixtures.textEditPages())
    let untouched = try PDFEditingEngine.commit(
      PDFTransaction([MoveTextCommand(pageID: pageID, runIndex: 0, dx: 0, dy: 0)]),
      to: graph)
    #expect(untouched == graph)
    let resized = try PDFEditingEngine.commit(
      PDFTransaction([ResizeTextCommand(pageID: pageID, runIndex: 0, fontSize: 30)]),
      to: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: resized)
    #expect(layout.clusters.first { $0.runIndex == 0 }?.fontSize == 30)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([ResizeTextCommand(pageID: pageID, runIndex: 0, fontSize: 0)]),
        to: graph)
    }
  }

  // MARK: - P18-016 multi-instruction spans

  @Test func replaceSpanAcrossTJMembersRemovesOriginalCodes() throws {
    let (graph, pageID) = try parsed(PDFFixtures.textWidthsPages())
    // Runs 0 ("AB") and 1 ("CD") are members of one TJ array.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextSpanCommand(pageID: pageID, runRange: 0..<2, replacement: "XY")
      ]), to: graph)
    let content = try PageContent.load(pageID: pageID, in: edited)
    let text = String(decoding: content.bytes, as: UTF8.self)
    // The TJ-array rewrite serializes through the writer, which encodes
    // string bytes as hex: "XY" lands as <5859> (the P18-003 path). The
    // original member codes are gone either way.
    #expect(text.contains("<5859>"))
    #expect(!text.contains("(AB)") && !text.contains("(CD)"))
    #expect(!text.contains("<4142>") && !text.contains("<4344>"))
    let layout = try PageTextLayout.build(pageID: pageID, in: edited)
    #expect(layout.text(in: 0..<layout.clusters.count) == "XY")
    // An unencodable span refuses rather than partially substituting.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextSpanCommand(pageID: pageID, runRange: 0..<2, replacement: "arrow \u{2192}")
        ]), to: graph)
    }
  }

  @Test func replaceSpanAcrossSeparateInstructions() throws {
    let content = """
      BT /F1 12 Tf 42 700 Td (Hel) Tj ET
      BT /F1 12 Tf 90 700 Td (lo) Tj ET
      BT /F1 12 Tf 42 660 Td (After) Tj ET
      """ + "\n"
    var graph = TextPipelineTests.syntheticSinglePage(content: content)
    graph = try PDFParser.parse(PDFWriter.write(graph)).graph
    let pageID = try #require(try PDFPageTree.pageIDs(in: graph).first)
    let before = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(before.map(\.text) == ["Hel", "lo", "After"])
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextSpanCommand(pageID: pageID, runRange: 0..<2, replacement: "Hi")
      ]), to: graph)
    let after = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: edited), graph: edited)
    #expect(after[0].text == "Hi" && after[1].text.isEmpty && after[2].text == "After")
    let bytes = String(
      decoding: (try PageContent.load(pageID: pageID, in: edited)).bytes, as: UTF8.self)
    #expect(!bytes.contains("(Hel)") && !bytes.contains("(lo)"))
    // Undo-equivalence: the bytes verify through a rewrite round trip.
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    #expect(reopened.graph == edited)
  }

  // MARK: - P18-018 link reporting

  @Test func textMoveReportsTouchedLinks() throws {
    let (graph, pageID) = try parsed(PDFFixtures.taggedPages())
    // The fixture's link covers the heading line.
    let overlapping = TextLinkImpact.affectedLinks(
      pageID: pageID, oldBounds: [42, 700, 240, 730], newBounds: [42, 700, 240, 730],
      in: graph)
    #expect(!overlapping.isEmpty)
    #expect(overlapping.affectedRects.allSatisfy { $0.count == 4 })
    let distant = TextLinkImpact.affectedLinks(
      pageID: pageID, oldBounds: [400, 100, 500, 120], newBounds: [410, 100, 510, 120],
      in: graph)
    #expect(distant.isEmpty)
    // Annotations themselves are untouched by the text move.
    let (moved, _) = try parsed(PDFFixtures.taggedPages())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([MoveTextCommand(pageID: pageID, runIndex: 0, dx: 4, dy: 0)]),
      to: moved)
    let beforeLinks = try AnnotationInventory.annotations(in: moved, pageID: pageID)
      .filter { $0.subtype == PDFName("Link") }.map { $0.rect }
    let afterLinks = try AnnotationInventory.annotations(in: edited, pageID: pageID)
      .filter { $0.subtype == PDFName("Link") }.map { $0.rect }
    #expect(beforeLinks == afterLinks)
  }

  // MARK: - P18-019 marked content

  @Test func textEditsPreserveMarkedContentSpans() throws {
    let (graph, pageID) = try parsed(PDFFixtures.taggedPages())
    let before = try MarkedContentPreservation.spans(pageID: pageID, in: graph)
    #expect(before.contains(MarkedContentPreservation.Span(tag: "P", mcid: 1)))
    for command: any PDFEditCommand in [
      ReplaceTextCommand(pageID: pageID, runIndex: 1, replacement: "Tagged paragraph edit"),
      ChangeTextStyleCommand(
        pageID: pageID, runIndex: 1, style: TextStyleChange(fontSize: 14)),
      MoveTextCommand(pageID: pageID, runIndex: 1, dx: 6, dy: 0),
    ] {
      let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      #expect(
        try MarkedContentPreservation.spans(pageID: pageID, in: edited) == before,
        "command \(command.name) must preserve marked-content spans")
      // Structure roles still resolve after the rewrite.
      let roles = ParagraphReconstruction.structureRolesByPage(
        in: edited, pageIDs: [pageID])
      #expect(roles[pageID]?[1] == "P")
    }
  }

  // MARK: - P18-022 editability reasons

  @Test func editabilityNamesUnsupportedFontsAndClipping() throws {
    let (graph, pageID) = try parsed(PDFFixtures.textEditPages())
    let supported = TextEditabilityCheck.assess(pageID: pageID, runIndex: 0, in: graph)
    #expect(supported.isEditable && supported.reasons.isEmpty)

    var macRoman = graph
    guard case .dictionary(let page)? = macRoman.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(var font)? = macRoman.objects[fontID]
    else {
      Issue.record("fixture font missing")
      return
    }
    font[PDFName("Encoding")] = .name(PDFName("MacRomanEncoding"))
    macRoman.objects[fontID] = .dictionary(font)
    let refused = TextEditabilityCheck.assess(pageID: pageID, runIndex: 0, in: macRoman)
    #expect(!refused.isEditable)
    #expect(refused.reasons.joined().contains("MacRoman"))

    var clipped = graph
    guard case .stream(let stream)? = clipped.objects[PDFObjectID(5)] else {
      Issue.record("fixture stream missing")
      return
    }
    var bytes = Data("7 Tr\n".utf8)
    bytes.append(stream.bytes)
    clipped.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: stream.dictionary, bytes: bytes))
    let rewritten = try PDFParser.parse(PDFWriter.write(clipped))
    let clip = TextEditabilityCheck.assess(
      pageID: rewritten.pageIDs[0], runIndex: 0, in: rewritten.graph)
    #expect(!clip.isEditable)
    #expect(clip.reasons.joined().contains("clipping"))

    let missing = TextEditabilityCheck.assess(
      pageID: pageID, runIndex: 99, in: graph)
    #expect(!missing.isEditable)
  }

  // MARK: - P18-030 writable profile fixtures

  @Test func writableProfileFixturesStillExerciseTheProfile() throws {
    #expect(WritableTextProfile.regressionFixtureNames().count == 8)
    #expect(WritableTextProfile.summary.contains("Simple fonts"))
    let builders: [String: () throws -> Data] = [
      "textEditPages": PDFFixtures.textEditPages,
      "textWidthsPages": PDFFixtures.textWidthsPages,
      "fontEmbeddedPages": PDFFixtures.fontEmbeddedPages,
      "combiningMarkPages": PDFFixtures.combiningMarkPages,
      "twoColumnPages": PDFFixtures.twoColumnPages,
      "transformedTextPages": PDFFixtures.transformedTextPages,
      "taggedPages": PDFFixtures.taggedPages,
      "multilingualPages": PDFFixtures.multilingualPages,
    ]
    for name in WritableTextProfile.regressionFixtureNames() {
      let builder = try #require(builders[name], "profile lists an unbuilt fixture \(name)")
      let parsed = try PDFParser.parse(try builder())
      #expect(!parsed.pageIDs.isEmpty, "fixture \(name) must parse")
    }
  }

  // MARK: - P15-027 fallback rendering in independent readers

  @Test func fallbackSubstitutionRendersAndExtractsIndependently() throws {
    guard
      let mutool = Self.locate("mutool"), let pdftotext = Self.locate("pdftotext"),
      let qpdf = Self.locate("qpdf")
    else { return }
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("test font program is corrupt")
      return
    }
    var graph = try PDFParser.parse(PDFFixtures.textWidthsPages()).graph
    let pageID = try #require(try PDFPageTree.pageIDs(in: graph).first)
    // Helvetica has no fi ligature: replace AB with it through the DejaVu
    // fallback (the P18-007 path under test).
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: pageID, runIndex: 0, replacement: "Aﬁ",
          fallbackFont: CustomTextFont(program: program, familyName: "DejaVuSans"))
      ]), to: graph)
    let data = try PDFWriter.write(edited)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-fallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pdfURL = directory.appendingPathComponent("fallback.pdf")
    try data.write(to: pdfURL)

    let check = try Self.run(qpdf, ["--check", pdfURL.path])
    #expect(check.status == 0 || check.status == 3, "qpdf --check: \(check.output)")

    let text = try Self.run(pdftotext, [pdfURL.path, "-"])
    #expect(text.status == 0)
    #expect(text.output.contains("A"), "pdftotext: \(text.output)")
    #expect(
      text.output.contains("fi") || text.output.contains("ﬁ"),
      "pdftotext: \(text.output)")

    // Rendered ink: the fallback glyphs paint dark pixels in mutool's raster.
    let pgmURL = directory.appendingPathComponent("page.pgm")
    let draw = try Self.run(
      mutool, ["draw", "-F", "pgm", "-r", "72", "-o", pgmURL.path, pdfURL.path])
    #expect(draw.status == 0, "mutool draw: \(draw.output)")
    let dark = try Self.darkPixels(inPGM: Data(contentsOf: pgmURL))
    #expect(dark > 20, "fallback text must render ink, got \(dark) dark pixels")
  }

  // MARK: - Tool helpers (development binaries only)

  private static func locate(_ name: String) -> String? {
    for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
      let path = "\(directory)/\(name)"
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
  }

  private static func run(_ executable: String, _ arguments: [String]) throws -> (
    status: Int32, output: String
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
  }

  /// Dark-pixel count of a binary PGM raster.
  private static func darkPixels(inPGM data: Data) throws -> Int {
    var index = data.startIndex
    func readToken() -> String? {
      while index < data.endIndex, data[index] == 0x23 {
        while index < data.endIndex, data[index] != 0x0A { index += 1 }
        index += 1
      }
      while index < data.endIndex, data[index].isWhitespaceLetterOrDigitSeparator() {
        index += 1
      }
      let start = index
      while index < data.endIndex, !data[index].isWhitespaceLetterOrDigitSeparator() {
        index += 1
      }
      guard start < index else { return nil }
      return String(decoding: data[start..<index], as: UTF8.self)
    }
    guard readToken() == "P5" else {
      throw PDFError(.malformed, "mutool did not produce a binary PGM")
    }
    guard let width = readToken().flatMap(Int.init),
      let height = readToken().flatMap(Int.init),
      let maxValue = readToken().flatMap(Int.init), maxValue > 0
    else {
      throw PDFError(.malformed, "mutool PGM header is malformed")
    }
    index += 1  // single whitespace after maxval
    let bytesPerSample = maxValue > 255 ? 2 : 1
    var dark = 0
    var offset = index
    for _ in 0..<(width * height) {
      guard offset < data.endIndex else { break }
      let value: Int
      if bytesPerSample == 2, offset + 1 < data.endIndex {
        value = Int(data[offset]) * 256 + Int(data[offset + 1])
        offset += 2
      } else {
        value = Int(data[offset])
        offset += 1
      }
      if value * 2 < maxValue { dark += 1 }
    }
    return dark
  }
}

extension UInt8 {
  fileprivate func isWhitespaceLetterOrDigitSeparator() -> Bool {
    self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
  }
}
