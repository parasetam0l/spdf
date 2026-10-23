import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

@Suite("Paragraph graphics eligibility")
struct ParagraphGraphicsStateTests {
  private func fixture(_ parts: [String], spaces: [PDFName: PDFValue]? = nil,
    state: [PDFName: PDFValue]? = nil) throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    var graph = parsed.graph
    let id = parsed.pageIDs[0]
    guard case .dictionary(var page)? = graph.objects[id],
      case .dictionary(var resources)? = page[PDFName("Resources")] else {
      throw PDFError(.malformed, "Missing fixture resources")
    }
    if let spaces { resources[PDFName("ColorSpace")] = .reference(PDFObjectID(80)); graph.objects[PDFObjectID(80)] = .dictionary(spaces) }
    if let state { resources[PDFName("ExtGState")] = .dictionary([PDFName("GS"): .reference(PDFObjectID(81))]); graph.objects[PDFObjectID(81)] = .dictionary(state) }
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[id] = .dictionary(page)
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data((parts.joined(separator: "\n") + "\n").utf8)))
    return (graph, id)
  }
  private func show(_ text: String, y: Int = 700) -> String {
    "BT /F1 16 Tf 1 0 0 1 42 \(y) Tm (\(text)) Tj ET"
  }
  private func editable(_ graph: PDFGraph, _ id: PDFObjectID) throws -> [Bool] {
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: id, in: graph), graph: graph)
    let validator = try PageTextRewriteValidator(pageID: id, in: graph)
    return runs.enumerated().map { index, run in
      (try? validator.validate(originalText: [index: run.text], fontSize: 16, color: run.fillColor)) != nil
    }
  }

  private func taggedFinalRunFixture(
    singleScopeWordSpacing: Double? = nil,
    trailingSpaceNeighbor: Bool = false
  ) throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.fontEmbeddedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var graph = parsed.graph
    let prefix = "ABC ABC "
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Tagged fixture page is missing")
    }
    let font = try #require(IndexedTextFont.resolve(resource: PDFName("F1"), page: page, in: graph))
    if trailingSpaceNeighbor {
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
        BT /F1 12 Tf 42 660 Td
        /P <</MCID 0>> BDC
        (AB) Tj
        (C ) Tj
        EMC
        (ABC) Tj
        ET
        """.utf8)))
    } else if let singleScopeWordSpacing {
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
        /P <</MCID 0>> BDC
        BT /F1 12 Tf \(singleScopeWordSpacing) Tw 42 660 Td [(ABC ) 20 (ABC)] TJ ET
        EMC
        """.utf8)))
    } else {
      let codes = try #require(font.encode(prefix))
      let prefixWidth = try #require(font.advance(of: codes, fontSize: 12,
        charSpacing: 0, wordSpacing: 0, horizontalScale: 100))
      let finalRunX = 42 + prefixWidth
      graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
        /P <</MCID 0>> BDC
        BT /F1 12 Tf 42 660 Td (ABC ABC ) Tj ET
        EMC
        /P <</MCID 1>> BDC
        BT /F1 12 Tf \(finalRunX) 660 Td (ABC) Tj ET
        EMC
        """.utf8)))
    }

    guard case .dictionary(var catalog)? = graph.objects[PDFObjectID(1)],
      case .dictionary(var page)? = graph.objects[pageID]
    else { throw PDFError(.malformed, "Tagged fixture catalog or page is missing") }
    catalog[PDFName("StructTreeRoot")] = .reference(PDFObjectID(90))
    catalog[PDFName("MarkInfo")] = .dictionary([PDFName("Marked"): .boolean(true)])
    graph.objects[PDFObjectID(1)] = .dictionary(catalog)
    page[PDFName("StructParents")] = .integer(0)
    graph.objects[pageID] = .dictionary(page)
    graph.objects[PDFObjectID(90)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructTreeRoot")),
      PDFName("K"): .reference(PDFObjectID(91)),
      PDFName("ParentTree"): .reference(PDFObjectID(92)),
      PDFName("ParentTreeNextKey"): .integer(1),
    ])
    graph.objects[PDFObjectID(91)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("P")),
      PDFName("P"): .reference(PDFObjectID(90)),
      PDFName("Pg"): .reference(pageID),
      PDFName("K"): singleScopeWordSpacing == nil && !trailingSpaceNeighbor
        ? .array([.integer(0), .integer(1)]) : .integer(0),
    ])
    graph.objects[PDFObjectID(92)] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0), .array(singleScopeWordSpacing == nil && !trailingSpaceNeighbor
          ? [.reference(PDFObjectID(91)), .reference(PDFObjectID(91))]
          : [.reference(PDFObjectID(91))]),
      ]),
    ])
    return (graph, pageID)
  }

  private func taggedSubsetFallbackFixture() throws -> (PDFGraph, PDFObjectID) {
    var (graph, pageID) = try taggedFinalRunFixture()
    guard case .dictionary(var page)? = graph.objects[pageID],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var fonts)? = resources[PDFName("Font")],
      case .reference(let originalFontID)? = fonts[PDFName("F1")],
      case .dictionary(var sourceFont)? = graph.objects[originalFontID],
      case .dictionary(var encoding)? = sourceFont[PDFName("Encoding")],
      case .dictionary(var structureElement)? = graph.objects[PDFObjectID(91)],
      case .dictionary(var parentTree)? = graph.objects[PDFObjectID(92)]
    else {
      throw PDFError(.malformed, "Tagged subset fixture is incomplete")
    }

    // F1 cannot encode C because its encoding maps that code to space and its
    // ToUnicode map omits C. F2 is a separate Type0 subset of the same face,
    // so it exercises fallback across distinct embedded font programs and
    // different WinAnsi / Identity-H encodings.
    encoding[PDFName("Differences")] = .array([
      .integer(1), .name(PDFName("fi")), .integer(67), .name(PDFName("space")),
    ])
    sourceFont[PDFName("Encoding")] = .dictionary(encoding)
    sourceFont[PDFName("ToUnicode")] = .reference(PDFObjectID(93))
    graph.objects[PDFObjectID(93)] = .stream(PDFStream(bytes: Data("""
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
      /CMapName /SubsetSource def
      /CMapType 2 def
      1 begincodespacerange
      <00> <FF>
      endcodespacerange
      3 beginbfchar
      <20> <0020>
      <41> <0041>
      <42> <0042>
      endbfchar
      endcmap
      CMapName currentdict /CMap defineresource pop
      end
      end
      """.utf8)))
    guard case .stream(let sourceProgram)? = graph.objects[PDFObjectID(7)] else {
      throw PDFError(.malformed, "Tagged subset font program is missing")
    }
    let composite = try CompositeFontWriter.write(
      program: sourceProgram.bytes, baseName: "DejaVuSans", covering: "ABC ")
    guard composite.fontFile.bytes != sourceProgram.bytes else {
      throw PDFError(.malformed, "Tagged fallback fixture subsets must use distinct programs")
    }
    guard let compositeAB = composite.encode("AB") else {
      throw PDFError(.malformed, "Tagged composite subset cannot encode its source text")
    }
    let compositeABHex = compositeAB.map { String(format: "%02X", $0) }.joined()
    let compositeFontID = PDFObjectID(95)
    let compositeDescendantID = PDFObjectID(96)
    let compositeDescriptorID = PDFObjectID(97)
    let compositeProgramID = PDFObjectID(98)
    let compositeToUnicodeID = PDFObjectID(99)
    let compositeCIDToGIDID = PDFObjectID(100)
    guard case .dictionary(var compositeFont) = composite.type0Dictionary(
      descendant: compositeDescendantID, toUnicode: compositeToUnicodeID,
      baseName: composite.baseName),
      case .dictionary(var compositeDescendant) = composite.descendant,
      case .dictionary(var compositeDescriptor) = composite.descriptor
    else {
      throw PDFError(.malformed, "Tagged composite subset could not be assembled")
    }
    let subsetInspector = try TrueTypeInspector.inspect(composite.fontFile.bytes)
    var cidToGIDBytes = [UInt8](repeating: 0, count: composite.encoding.count * 2)
    for (scalar, cid) in composite.encoding {
      guard let glyphID = subsetInspector.unicodeToGlyph[scalar],
        cid >= 0, cid < composite.encoding.count,
        glyphID >= 0, glyphID <= Int(UInt16.max)
      else { throw PDFError(.malformed, "Tagged composite subset mapping is incomplete") }
      cidToGIDBytes[cid * 2] = UInt8((glyphID >> 8) & 0xFF)
      cidToGIDBytes[cid * 2 + 1] = UInt8(glyphID & 0xFF)
    }
    compositeDescendant[PDFName("FontDescriptor")] = .reference(compositeDescriptorID)
    compositeDescriptor[PDFName("FontFile2")] = .reference(compositeProgramID)
    compositeDescendant[PDFName("CIDToGIDMap")] = .reference(compositeCIDToGIDID)
    compositeFont[PDFName("DescendantFonts")] = .array([.reference(compositeDescendantID)])
    compositeFont[PDFName("ToUnicode")] = .reference(compositeToUnicodeID)
    graph.objects[PDFObjectID(94)] = .dictionary(sourceFont)
    graph.objects[compositeFontID] = .dictionary(compositeFont)
    graph.objects[compositeDescendantID] = .dictionary(compositeDescendant)
    graph.objects[compositeDescriptorID] = .dictionary(compositeDescriptor)
    graph.objects[compositeProgramID] = .stream(composite.fontFile)
    graph.objects[compositeToUnicodeID] = .stream(composite.toUnicode)
    graph.objects[compositeCIDToGIDID] = .stream(PDFStream(bytes: Data(cidToGIDBytes)))
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 0>> BDC
      BT /F1 12 Tf
      1 0 0 1 42 660 Tm (AB) Tj
      1 0 0 1 42 640 Tm (AB) Tj
      /F2 12 Tf
      1 0 0 1 42 620 Tm <\(compositeABHex)> Tj
      ET
      EMC
      """.utf8)))
    fonts[PDFName("F1")] = .reference(PDFObjectID(94))
    fonts[PDFName("F2")] = .reference(compositeFontID)
    resources[PDFName("Font")] = .dictionary(fonts)
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
    structureElement[PDFName("K")] = .integer(0)
    graph.objects[PDFObjectID(91)] = .dictionary(structureElement)
    parentTree[PDFName("Nums")] = .array([
      .integer(0), .array([.reference(PDFObjectID(91))]),
    ])
    graph.objects[PDFObjectID(92)] = .dictionary(parentTree)
    return (graph, pageID)
  }

  @Test(arguments: ["0 g", "0.2 0.3 0.4 rg"])
  func deviceColorResetRecoversOnlyFillColor(reset: String) throws {
    let (graph, id) = try fixture(["/Custom cs 0 0 1 scn", show("AB"), reset, show("CD", y: 678)])
    #expect(try editable(graph, id) == [false, true])
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: id, in: graph), graph: graph)
    let command = RewritePageTextCommand(pageID: id, originalText: [1: "CD"],
      lines: [.init(text: "DC", x: 42, baseline: 678)], fontSize: 16, color: runs[1].fillColor)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let after = try TextRunIndexer.runs(in: PageContent.load(pageID: id, in: reopened.graph), graph: reopened.graph)
    #expect(after.filter { !$0.text.isEmpty }.map(\.text) == ["AB", "DC"])
    #expect(after.last?.fillColor == runs[1].fillColor)
    #expect(edited.objects[PDFObjectID(4)] == graph.objects[PDFObjectID(4)])

    let (alpha, alphaID) = try fixture(["/GS gs", show("AB")],
      state: [PDFName("ca"): .real(0.5)])
    #expect(try editable(alpha, alphaID) == [true])
    let alphaRun = try #require(
      TextRunIndexer.runs(in: PageContent.load(pageID: alphaID, in: alpha), graph: alpha).first)
    #expect(abs(alphaRun.fillAlpha - 0.5) < 0.0001)
    let alphaEdit = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(
        pageID: alphaID, originalText: [0: alphaRun.text],
        lines: [.init(text: "CD", x: 42, baseline: 700)],
        fontSize: 16, color: alphaRun.fillColor)
    ]), to: alpha)
    let alphaReopened = try PDFParser.parse(PDFWriter.write(alphaEdit))
    let alphaRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: alphaID, in: alphaReopened.graph),
      graph: alphaReopened.graph)
    #expect(abs((alphaRuns.last?.fillAlpha ?? 0) - 0.5) < 0.0001)
    let (clip, clipID) = try fixture(["0 0 m 30 0 l 0 30 l h W n /Custom cs", reset, show("AB")])
    #expect(try editable(clip, clipID) == [false])
  }

  @Test func colorKnowledgeFollowsGraphicsStateStack() throws {
    let (unknown, id) = try fixture(["/Custom cs", show("A"), "q 0 g", show("B"), "Q", show("C")])
    #expect(try editable(unknown, id) == [false, true, false])
    let (known, other) = try fixture(["0 g", show("A"), "q /Custom cs", show("B"), "Q", show("C")])
    #expect(try editable(known, other) == [true, false, true])
  }

  @Test(arguments: ["0 0 g", "2 g", "-1 g", "0 0 rg", "0 0 1.1 rg", "0.5 sc", "0.5 scn"])
  func malformedOrUnresolvedColorsDoNotRecover(reset: String) throws {
    let (graph, id) = try fixture(["/Custom cs", reset, show("AB")])
    #expect(try editable(graph, id) == [false])
  }

  @Test func deviceDefaultsCannotBypassCustomColorRestrictions() throws {
    for (name, reset) in [("DefaultGray", "0 g"), ("DefaultRGB", "0 0 0 rg"),
      ("DefaultCMYK", "0 0 0 1 k")] {
      let (graph, id) = try fixture([reset, show("AB")],
        spaces: [PDFName(name): .reference(PDFObjectID(82))])
      #expect(try editable(graph, id) == [false])
    }
    let (rgb, rgbID) = try fixture(["0 g", show("AB")],
      spaces: [PDFName("DefaultRGB"): .reference(PDFObjectID(82))])
    #expect(try editable(rgb, rgbID) == [true])

    var (icc, iccID) = try fixture(["0 0 0 rg", show("AB")],
      spaces: [PDFName("DefaultRGB"): .array([
        .name(PDFName("ICCBased")), .reference(PDFObjectID(82)),
      ])])
    icc.objects[PDFObjectID(82)] = .stream(PDFStream(
      dictionary: [PDFName("N"): .integer(3), PDFName("Length"): .integer(0)],
      bytes: Data()))
    #expect(try editable(icc, iccID) == [true])
  }

  @Test func opaqueSettingsDoNotClearAnEarlierUnknownGraphicsState() throws {
    let harmless: [PDFName: PDFValue] = [PDFName("SA"): .boolean(false), PDFName("SM"): .real(0.02),
      PDFName("OP"): .boolean(false), PDFName("op"): .boolean(false), PDFName("OPM"): .integer(1)]
    let (graph, id) = try fixture(["/Unknown gs /GS gs 0 g", show("AB")], state: harmless)
    #expect(try editable(graph, id) == [false])
    let (malformed, malformedID) = try fixture(["/GS /Extra gs 0 g", show("AB")], state: harmless)
    #expect(try editable(malformed, malformedID) == [false])
  }

  @Test func overprintAllowsSourceColorButRefusesColorChange() throws {
    let (graph, id) = try fixture(["/GS gs", show("AB")], state: [
      PDFName("OP"): .boolean(true), PDFName("op"): .boolean(true),
      PDFName("OPM"): .integer(1), PDFName("AIS"): .boolean(false),
      PDFName("SMask"): .name(PDFName("None")), PDFName("CA"): .integer(1),
      PDFName("ca"): .integer(1),
    ])
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: id, in: graph), graph: graph)
    let validator = try PageTextRewriteValidator(pageID: id, in: graph)
    try validator.validate(originalText: [0: runs[0].text], fontSize: 16,
      color: runs[0].fillColor)
    do {
      try validator.validate(originalText: [0: runs[0].text], fontSize: 16,
        color: [0.8, 0.1, 0.1])
      Issue.record("Overprint-enabled text accepted a color change")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func whitespaceOnlyGlyphBoundsDoNotTriggerInkCollision() throws {
    let (graph, id) = try fixture([show("AB"), show(" ", y: 711)])
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: id, in: graph), graph: graph)
    let clusters = try PageTextLayout.build(pageID: id, in: graph).clusters
    #expect(runs.count == 2)
    #expect(clusters.contains { $0.runIndex == 1 && $0.isWhitespace })
    let command = RewritePageTextCommand(pageID: id, originalText: [0: runs[0].text],
      lines: [.init(text: "C", x: 42, baseline: 700)], fontSize: 16,
      color: runs[0].fillColor)

    try command.validate(in: graph)
  }

  @Test func taggedFinalInstructionCanGrowAndShrinkAfterExactPrefix() throws {
    let (graph, pageID) = try taggedFinalRunFixture()
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    let selected = runs.enumerated().filter {
      $0.element.text == "ABC ABC " || $0.element.text == "ABC"
    }
    #expect(selected.map(\.element.text) == ["ABC ABC ", "ABC"])
    let originalText = Dictionary(uniqueKeysWithValues: selected.map { ($0.offset, $0.element.text) })
    let replacement = "ABC ABC ABC ABC"
    let edit = RewritePageTextCommand(pageID: pageID, originalText: originalText,
      lines: [.init(text: replacement, x: 42, baseline: 660)], fontSize: 12, color: [0, 0, 0])
    let validator = try PageTextRewriteValidator(pageID: pageID, in: graph)
    #expect(validator.canPreserveMarkedContentOrder(runIndices: selected.map(\.offset)))
    try edit.validateSource(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(edited))
    let savedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: reparsed.graph), graph: reparsed.graph)
    #expect(savedRuns.map(\.text).joined() == replacement)
    let inventory = try PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.issues.isEmpty)
    let layout = try PageTextLayout.build(pageID: pageID, in: reparsed.graph)
    let order = try #require(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: layout, in: reparsed.graph, limits: PDFLimits()))
    #expect(order.map { layout.clusters[$0].text }.joined().contains(replacement))

    let grownSource = Dictionary(uniqueKeysWithValues: savedRuns.enumerated().map {
      ($0.offset, $0.element.text)
    })
    let shrink = RewritePageTextCommand(pageID: pageID, originalText: grownSource,
      lines: [.init(text: "ABC ABC ABC", x: 42, baseline: 660)],
      fontSize: 12, color: [0, 0, 0])
    let shortened = try PDFEditingEngine.commit(PDFTransaction([shrink]), to: reparsed.graph)
    let shortenedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: shortened), graph: shortened)
    #expect(shortenedRuns.map(\.text).joined() == "ABC ABC ABC")

    let changedPrefix = RewritePageTextCommand(pageID: pageID, originalText: originalText,
      lines: [.init(text: "CBC ABC ABC ABC", x: 42, baseline: 660)],
      fontSize: 12, color: [0, 0, 0])
    #expect(throws: PDFError.self) { try changedPrefix.validate(in: graph) }
  }

  @Test func taggedPointSizeEditTrimsTerminalSourceSpaceAndPreservesNeighbor() throws {
    let (graph, pageID) = try taggedFinalRunFixture(trailingSpaceNeighbor: true)
    let sourceRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(sourceRuns.map(\.text) == ["AB", "C ", "ABC"])
    #expect(sourceRuns.map(\.fontSize) == [12, 12, 12])
    let sourceNeighborX = sourceRuns[2].baselineX

    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Tagged fixture page is missing")
    }
    let font = try #require(IndexedTextFont.resolve(
      resource: sourceRuns[0].fontResource, page: page, in: graph))
    let format = PageTextFormat(size: 10, color: sourceRuns[0].fillColor,
      sourceFont: PageTextSourceFont(resource: sourceRuns[0].fontResource, name: font.baseFont),
      characterSpacing: sourceRuns[0].charSpacing, opacity: sourceRuns[0].fillAlpha)
    let line = PageTextLine(text: "ABC", x: 42, baseline: 660,
      segments: [PageTextSegment(text: "ABC", x: 42, format: format)])
    let edit = RewritePageTextCommand(pageID: pageID, originalText: [0: "AB", 1: "C "],
      lines: [line], fontSize: 10, color: sourceRuns[0].fillColor,
      box: PageTextBox(x: 42, firstBaseline: 660, width: 100, lineSpacing: 12, wraps: false))

    try edit.validate(in: graph)
    let written = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(written))
    let savedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: reparsed.graph), graph: reparsed.graph)

    #expect(savedRuns.map(\.text) == ["AB", "C ", "ABC"])
    if savedRuns.count == 3 {
      #expect(abs(savedRuns[0].fontSize - 10) < 0.02)
      #expect(abs(savedRuns[1].fontSize - 10) < 0.02)
      #expect(abs(savedRuns[2].fontSize - 12) < 0.02)
      #expect(abs(savedRuns[2].baselineX - sourceNeighborX) < 0.02)
    }
    let inventory = try PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.issues.isEmpty)
  }

  @Test func taggedFirstInstructionCanShortenByRemovingItsLeadingPrefix() throws {
    let (graph, pageID) = try taggedFinalRunFixture()
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(runs.map(\.text) == ["ABC ABC ", "ABC"])
    let originalText = Dictionary(uniqueKeysWithValues: runs.enumerated().map {
      ($0.offset, $0.element.text)
    })
    let edit = RewritePageTextCommand(pageID: pageID, originalText: originalText,
      lines: [.init(text: "C ABC ABC", x: 42, baseline: 660)],
      fontSize: 12, color: runs[0].fillColor)

    try edit.validate(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(edited))
    let content = try PageContent.load(pageID: pageID, in: reparsed.graph)
    let savedRuns = try TextRunIndexer.runs(in: content, graph: reparsed.graph)
    #expect(savedRuns.map(\.text).joined() == "C ABC ABC")

    let markedRanges = StructureTaggingAssistant.markedRanges(in: content)
      .filter { $0.mcid != nil }
      .sorted { $0.instructions.lowerBound < $1.instructions.lowerBound }
    #expect(markedRanges.compactMap(\.mcid) == [0, 1])
    let textByMCID = markedRanges.map { range in
      savedRuns.filter { range.instructions.contains($0.instructionIndex) }
        .map(\.text).joined()
    }
    #expect(textByMCID == ["C ABC ", "ABC"])

    let inventory = try PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.issues.isEmpty)
    let layout = try PageTextLayout.build(pageID: pageID, in: reparsed.graph)
    let order = try #require(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: layout, in: reparsed.graph, limits: PDFLimits()))
    #expect(order.map { layout.clusters[$0].text }.joined() == "C ABC ABC")

    let nonPrefixShortening = RewritePageTextCommand(pageID: pageID, originalText: originalText,
      lines: [.init(text: "C ABC AB", x: 42, baseline: 660)],
      fontSize: 12, color: runs[0].fillColor)
    #expect(throws: PDFError.self) { try nonPrefixShortening.validate(in: graph) }
  }

  @Test func oneLineTaggedParagraphPreservesExplicitWordSpacing() throws {
    let (graph, pageID) = try taggedFinalRunFixture(singleScopeWordSpacing: 2)
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(runs.map(\.text).joined() == "ABC ABC")
    #expect(runs.allSatisfy { abs($0.wordSpacing - 2) < 1e-8 })
    let originalText = Dictionary(uniqueKeysWithValues: runs.enumerated().map {
      ($0.offset, $0.element.text)
    })
    let edit = RewritePageTextCommand(pageID: pageID, originalText: originalText,
      lines: [.init(text: "CBA CBA", x: 42, baseline: 660)],
      fontSize: 12, color: runs[0].fillColor)

    try edit.validate(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(edited))
    let savedContent = try PageContent.load(pageID: pageID, in: reparsed.graph)
    let savedRuns = try TextRunIndexer.runs(in: savedContent, graph: reparsed.graph)
    #expect(savedRuns.map(\.text).joined() == "CBA CBA")
    #expect(savedRuns.allSatisfy { abs($0.wordSpacing - 2) < 1e-8 })
    let inventory = try PDFStructureInspector.inspect(in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.issues.isEmpty)
    let layout = try PageTextLayout.build(pageID: pageID, in: reparsed.graph)
    let order = try #require(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: layout, in: reparsed.graph, limits: PDFLimits()))
    #expect(order.map { layout.clusters[$0].text }.joined().contains("CBA CBA"))
  }

  @Test func taggedParagraphUsesAnotherSameFaceSubsetForMissingGlyph() throws {
    let (graph, pageID) = try taggedSubsetFallbackFixture()
    let runs = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(runs.map(\.text) == ["AB", "AB", "AB"])
    #expect(runs.map(\.fontResource) == [PDFName("F1"), PDFName("F1"), PDFName("F2")])
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Tagged subset page is missing")
    }
    let sourceFont = try #require(IndexedTextFont.resolve(
      resource: PDFName("F1"), page: page, in: graph))
    let candidateFont = try #require(IndexedTextFont.resolve(
      resource: PDFName("F2"), page: page, in: graph))
    #expect(sourceFont.encode("C") == nil)
    #expect(candidateFont.encode("C") != nil)

    let selected = Dictionary(uniqueKeysWithValues: runs.enumerated().map {
      ($0.offset, $0.element.text)
    })
    let sourceStyle = PageTextFormat(size: 12, color: runs[0].fillColor,
      sourceFont: .init(resource: PDFName("F1"), name: sourceFont.baseFont))
    let edit = RewritePageTextCommand(pageID: pageID, originalText: selected, lines: [
      .init(text: "AC", x: 42, baseline: 660,
        segments: [.init(text: "AC", x: 42, format: sourceStyle)]),
      .init(text: "AB", x: 42, baseline: 640),
      .init(text: "AB", x: 42, baseline: 620),
    ], fontSize: 12, color: runs[0].fillColor)
    try edit.validate(in: graph)

    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(edited))
    let savedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: reparsed.graph), graph: reparsed.graph)
    #expect(savedRuns.map(\.text) == ["A", "C", "AB", "AB"])
    #expect(savedRuns.map(\.fontResource) == [
      PDFName("F1"), PDFName("F2"), PDFName("F1"), PDFName("F2"),
    ])
    let inventory = try PDFStructureInspector.inspect(
      in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.issues.isEmpty)
    let layout = try PageTextLayout.build(pageID: pageID, in: reparsed.graph)
    let order = try #require(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: layout, in: reparsed.graph, limits: PDFLimits()))
    #expect(order.map { layout.clusters[$0].text }.joined() == "ACABAB")
  }

  @Test func subsetFallbackSkipsAbsentSourceGlyphAndEmitsCompatibleSubset() throws {
    var (graph, pageID) = try taggedSubsetFallbackFixture()
    guard case .dictionary(var simpleFont)? = graph.objects[PDFObjectID(94)],
      case .array(var widths)? = simpleFont[PDFName("Widths")],
      case .stream(let toUnicode)? = graph.objects[PDFObjectID(93)],
      widths.indices.contains(67 - 32),
      case .dictionary(let page)? = graph.objects[pageID]
    else { throw PDFError(.malformed, "Subset metric fixture is incomplete") }

    // The simple subset can decode C through WinAnsi, but its zero declared
    // width means C is not a glyph in that embedded subset profile.
    widths[67 - 32] = .integer(0)
    simpleFont[PDFName("Widths")] = .array(widths)
    graph.objects[PDFObjectID(94)] = .dictionary(simpleFont)
    let cmap = String(decoding: toUnicode.bytes, as: UTF8.self)
      .replacingOccurrences(of: "3 beginbfchar\n", with: "4 beginbfchar\n")
      .replacingOccurrences(of: "<42> <0042>\n", with: "<42> <0042>\n<43> <0043>\n")
    graph.objects[PDFObjectID(93)] = .stream(PDFStream(bytes: Data(cmap.utf8)))

    let source = try #require(IndexedTextFont.resolve(
      resource: PDFName("F1"), page: page, in: graph))
    let candidate = try #require(IndexedTextFont.resolve(
      resource: PDFName("F2"), page: page, in: graph))
    #expect(source.encode("C") != nil)
    #expect(source.profile?.glyphs["C"] == nil)
    #expect(candidate.profile?.glyphs["C"] != nil)

    let glyph = PageTextLineWriter.inlineGlyph("C", preferredResource: PDFName("F1"),
      preferredFont: source, sourceText: "ABC",
      availableFonts: [PDFName("F1"): source, PDFName("F2"): candidate])
    #expect(glyph?.resource == PDFName("F2"))
    #expect(glyph?.glyph.text == "C")

    let format = PageTextFormat(size: 12, color: [0, 0, 0],
      sourceFont: .init(resource: PDFName("F1"), name: source.baseFont))
    var written = graph
    try PageTextLineWriter.append([
      .init(text: "ABC", x: 42, baseline: 660,
        segments: [.init(text: "ABC", x: 42, format: format)]),
    ], box: PageTextBox(x: 42, firstBaseline: 660, width: 120, lineSpacing: 16, wraps: false),
      pageID: pageID, defaultFont: source, defaultSize: 12, defaultColor: [0, 0, 0],
      in: &written)
    let reopened = try PDFParser.parse(PDFWriter.write(written))
    let authored = try #require(AuthoredPageTextBoxes.read(pageID: pageID, in: reopened.graph)
      .first(where: { $0.lines.map(\.text).joined() == "ABC" }))
    #expect(authored.lines[0].segments.map(\.text) == ["AB", "C"])
    #expect(authored.lines[0].segments.compactMap { $0.format.sourceFont?.resource }
      == [PDFName("F1"), PDFName("F2")])
  }

  @Test func oneLineTaggedParagraphUsesSameFaceSubsetForMissingGlyph() throws {
    var (graph, pageID) = try taggedSubsetFallbackFixture()
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 0>> BDC
      BT /F1 12 Tf 1 0 0 1 42 660 Tm (AB) Tj ET
      EMC
      """.utf8)))
    let runs = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(runs.map(\.text) == ["AB"])
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Tagged subset page is missing")
    }
    let sourceFont = try #require(IndexedTextFont.resolve(
      resource: PDFName("F1"), page: page, in: graph))
    let sourceStyle = PageTextFormat(size: 12, color: runs[0].fillColor,
      sourceFont: .init(resource: PDFName("F1"), name: sourceFont.baseFont))
    let edit = RewritePageTextCommand(pageID: pageID, originalText: [0: "AB"], lines: [
      .init(text: "AC", x: 42, baseline: 660,
        segments: [.init(text: "AC", x: 42, format: sourceStyle)]),
    ], fontSize: 12, color: runs[0].fillColor)
    try edit.validate(in: graph)

    let edited = try PDFEditingEngine.commit(PDFTransaction([edit]), to: graph)
    let reparsed = try PDFParser.parse(PDFWriter.write(edited))
    let savedRuns = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: reparsed.graph), graph: reparsed.graph)
    #expect(savedRuns.map(\.text) == ["A", "C"])
    #expect(savedRuns.map(\.fontResource) == [PDFName("F1"), PDFName("F2")])
    let inventory = try PDFStructureInspector.inspect(
      in: reparsed.graph, pageIDs: reparsed.pageIDs)
    #expect(inventory.issues.isEmpty)
    let layout = try PageTextLayout.build(pageID: pageID, in: reparsed.graph)
    let order = try #require(TextReadingOrder.structureClusterOrder(
      pageID: pageID, layout: layout, in: reparsed.graph, limits: PDFLimits()))
    #expect(order.map { layout.clusters[$0].text }.joined() == "AC")
  }

  @Test func collisionPreflightMeasuresCompatibleSubsetGlyphs() throws {
    var (graph, pageID) = try taggedSubsetFallbackFixture()
    guard case .stream(let stream)? = graph.objects[PDFObjectID(5)],
      case .dictionary(var page)? = graph.objects[pageID],
      case .dictionary(var catalog)? = graph.objects[PDFObjectID(1)] else {
      throw PDFError(.malformed, "Subset collision fixture is incomplete")
    }
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(
      bytes: stream.bytes + Data("\nBT /F1 12 Tf 350 500 Tm (AB) Tj ET\n".utf8)))
    page.removeValue(forKey: PDFName("StructParents"))
    catalog.removeValue(forKey: PDFName("StructTreeRoot"))
    catalog.removeValue(forKey: PDFName("MarkInfo"))
    graph.objects[pageID] = .dictionary(page)
    graph.objects[PDFObjectID(1)] = .dictionary(catalog)

    let runs = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    #expect(runs.count == 4)
    guard case .dictionary(let updatedPage)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Subset collision page is missing")
    }
    let sourceFont = try #require(IndexedTextFont.resolve(
      resource: PDFName("F1"), page: updatedPage, in: graph))
    let format = PageTextFormat(size: 12, color: runs[0].fillColor,
      sourceFont: .init(resource: PDFName("F1"), name: sourceFont.baseFont))
    let edit = RewritePageTextCommand(pageID: pageID, originalText: [0: "AB"], lines: [
      .init(text: "AC", x: 42, baseline: 660,
        segments: [.init(text: "AC", x: 42, format: format)]),
    ], fontSize: 12, color: runs[0].fillColor)
    try edit.validate(in: graph)
  }

  @Test func paragraphPreviewAcrossStreamsKeepsSharedContentAndNeighbors() throws {
    var (graph, id) = try fixture([show("AB")])
    guard case .dictionary(var page)? = graph.objects[id],
      case .dictionary(var pages)? = graph.objects[PDFObjectID(2)] else { return }
    let shared = graph.objects[PDFObjectID(5)]
    let other = PDFObjectID(90)
    graph.objects[other] = .dictionary(page)
    pages[PDFName("Kids")] = .array([.reference(id), .reference(other)])
    pages[PDFName("Count")] = .integer(2)
    graph.objects[PDFObjectID(2)] = .dictionary(pages)
    page[PDFName("Contents")] = .array([.reference(PDFObjectID(5)), .reference(PDFObjectID(6)), .reference(PDFObjectID(7))])
    graph.objects[id] = .dictionary(page)
    graph.objects[PDFObjectID(6)] = .stream(PDFStream(bytes: Data((show("CD", y: 678) + "\n").utf8)))
    graph.objects[PDFObjectID(7)] = .stream(PDFStream(bytes: Data(show("ABCD", y: 600).utf8)))
    let hidden = try PageTextEditing.hidingParagraph(pageID: id, originalText: [0: "AB", 1: "CD"],
      standardFontAdvances: [:], in: graph)
    #expect(hidden.objects[PDFObjectID(5)] == shared)
    #expect(hidden.objects[other] == graph.objects[other])
    #expect(hidden.objects[PDFObjectID(7)] == graph.objects[PDFObjectID(7)])
    #expect(hidden.objects[PDFObjectID(4)] == graph.objects[PDFObjectID(4)])
    let reopened = try PDFParser.parse(PDFWriter.write(hidden))
    let content = try PageContent.load(pageID: id, in: reopened.graph)
    let runs = try TextRunIndexer.runs(in: content, graph: reopened.graph)
    #expect(runs.map(\.text) == ["AB", "CD", "ABCD"])
    #expect(runs.map { TextCanvasSupport.renderingMode(at: $0.instructionIndex, in: content) } == [3, 3, 0])
    let otherContent = try PageContent.load(pageID: other, in: reopened.graph)
    #expect(try TextRunIndexer.runs(in: otherContent, graph: reopened.graph).map(\.text) == ["AB"])
    #expect(TextCanvasSupport.renderingMode(at: 3, in: otherContent) == 0)

    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: id, originalText: [0: "AB", 1: "CD"],
        lines: [.init(text: "DCBA", x: 42, baseline: 700)], fontSize: 16, color: [0, 0, 0])
    ]), to: graph)
    #expect(edited.objects[PDFObjectID(5)] == shared)
    #expect(edited.objects[other] == graph.objects[other])
    #expect(try TextRunIndexer.runs(in: PageContent.load(pageID: id, in: edited), graph: edited)
      .filter { !$0.text.isEmpty }.map(\.text) == ["ABCD", "DCBA"])
  }

  @Test func aTextInstructionCrossingStreamBoundariesCanBePreviewedAndEdited() throws {
    var (graph, id) = try fixture(["BT /F1 16 Tf 42 700 Td (AB)"])
    guard case .dictionary(var page)? = graph.objects[id] else { return }
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(
      bytes: Data("BT /F1 16 Tf 42 700 Td ".utf8)))
    let compressedArrayID = PDFObjectID(900)
    let numberArrayID = PDFObjectID(901)
    let operatorStreamID = PDFObjectID(902)
    let firstArrayPart = Data("[(AB) ".utf8)
    graph.objects[compressedArrayID] = .stream(PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode")),
        PDFName("DL"): .integer(Int64(firstArrayPart.count))],
      bytes: try PDFFilters.encodeFlate(firstArrayPart)))
    graph.objects[numberArrayID] = .stream(PDFStream(bytes: Data("0 ".utf8)))
    graph.objects[operatorStreamID] = .stream(PDFStream(bytes: Data("] TJ ET".utf8)))
    page[PDFName("Contents")] = .array([
      .reference(PDFObjectID(5)), .reference(compressedArrayID), .reference(numberArrayID),
      .reference(operatorStreamID),
    ])
    graph.objects[id] = .dictionary(page)
    let original = try PageContent.load(pageID: id, in: graph)
    #expect(try editable(graph, id) == [true])
    let textShow = try #require(original.instructions.first { $0.operatorName == "TJ" })
    let textShowStart = textShow.operands.first?.span.lowerBound ?? textShow.span.lowerBound
    let textShowSpan = textShowStart..<textShow.span.upperBound
    #expect(original.segmentIndices(for: textShowSpan) == [1, 2, 3])

    // Grow the complete text-show instruction enough to expose any
    // length-proportional remapping that would cut a replacement token.
    let longer = try original.replacing(
      range: textShowSpan, with: Array("[(CROSS-STREAM EDIT CHECK) 0] TJ".utf8), in: graph)
    let longerReopened = try PDFParser.parse(PDFWriter.write(longer))
    let longerContent = try PageContent.load(pageID: id, in: longerReopened.graph)
    #expect(try TextRunIndexer.runs(in: longerContent, graph: longerReopened.graph).map(\.text)
      == ["CROSS-STREAM EDIT CHECK"])
    #expect(longer.objects[PDFObjectID(5)] == graph.objects[PDFObjectID(5)])
    guard case .stream(let longerCompressed)? = longer.objects[compressedArrayID] else { return }
    #expect(String(decoding: try PDFFilters.decoded(longerCompressed), as: UTF8.self)
      == "[(CROSS-STREAM EDIT CHECK) 0] TJ")
    guard case .stream(let longerEmpty)? = longer.objects[numberArrayID] else { return }
    #expect(try PDFFilters.decoded(longerEmpty).isEmpty)
    #expect(longerCompressed.dictionary[PDFName("Filter")] == .name(PDFName("FlateDecode")))
    #expect(longerCompressed.dictionary[PDFName("DL")] == .integer(
      Int64(try PDFFilters.decoded(longerCompressed).count)))

    let hidden = try PageTextEditing.hidingParagraph(pageID: id, originalText: [0: "AB"],
      standardFontAdvances: [:], in: graph)
    let hiddenReopened = try PDFParser.parse(PDFWriter.write(hidden))
    let hiddenContent = try PageContent.load(pageID: id, in: hiddenReopened.graph)
    let hiddenRuns = try TextRunIndexer.runs(in: hiddenContent, graph: hiddenReopened.graph)
    #expect(hiddenRuns.map(\.text) == ["AB"])
    let hiddenModes = hiddenRuns.map {
      TextCanvasSupport.renderingMode(at: $0.instructionIndex, in: hiddenContent)
    }
    #expect(hiddenModes == [3])

    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(pageID: id, originalText: [0: "AB"],
        lines: [.init(text: "CD", x: 42, baseline: 700)], fontSize: 16, color: [0, 0, 0])
    ]), to: graph)
    let editedReopened = try PDFParser.parse(PDFWriter.write(edited))
    let editedContent = try PageContent.load(pageID: id, in: editedReopened.graph)
    let editedRuns = try TextRunIndexer.runs(in: editedContent, graph: editedReopened.graph)
    guard case .stream(let editedCompressed)? = edited.objects[compressedArrayID] else { return }
    #expect(editedCompressed.dictionary[PDFName("Filter")] == .name(PDFName("FlateDecode")))
    #expect(editedCompressed.dictionary[PDFName("DL")] == .integer(
      Int64(try PDFFilters.decoded(editedCompressed).count)))
    #expect(editedRuns.map(\.text) == ["CD"])
    let editedModes = editedRuns.map {
      TextCanvasSupport.renderingMode(at: $0.instructionIndex, in: editedContent)
    }
    #expect(editedModes == [0])
  }
}
