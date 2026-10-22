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

  private func taggedFinalRunFixture() throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.fontEmbeddedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var graph = parsed.graph
    let prefix = "ABC ABC "
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Tagged fixture page is missing")
    }
    let font = try #require(IndexedTextFont.resolve(resource: PDFName("F1"), page: page, in: graph))
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
      PDFName("K"): .array([.integer(0), .integer(1)]),
    ])
    graph.objects[PDFObjectID(92)] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0), .array([.reference(PDFObjectID(91)), .reference(PDFObjectID(91))]),
      ]),
    ])
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
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("BT /F1 16 Tf 42 700 Td (".utf8)))
    let middle = Data("A".utf8)
    graph.objects[PDFObjectID(6)] = .stream(PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode")),
        PDFName("DL"): .integer(Int64(middle.count))],
      bytes: try PDFFilters.encodeFlate(middle)))
    graph.objects[PDFObjectID(7)] = .stream(PDFStream(bytes: Data("B) Tj ET".utf8)))
    page[PDFName("Contents")] = .array([
      .reference(PDFObjectID(5)), .reference(PDFObjectID(6)), .reference(PDFObjectID(7)),
    ])
    graph.objects[id] = .dictionary(page)
    let original = try PageContent.load(pageID: id, in: graph)
    #expect(try editable(graph, id) == [true])
    let textShow = try #require(original.instructions.first { $0.operatorName == "Tj" })
    let textShowStart = textShow.operands.first?.span.lowerBound ?? textShow.span.lowerBound
    let textShowSpan = textShowStart..<textShow.span.upperBound
    #expect(original.segmentIndices(for: textShowSpan) == [0, 1, 2])

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
    guard case .stream(let editedMiddle)? = edited.objects[PDFObjectID(6)] else { return }
    #expect(editedMiddle.dictionary[PDFName("Filter")] == .name(PDFName("FlateDecode")))
    #expect(editedMiddle.dictionary[PDFName("DL")] == .integer(
      Int64(try PDFFilters.decoded(editedMiddle).count)))
    #expect(editedRuns.map(\.text) == ["CD"])
    let editedModes = editedRuns.map {
      TextCanvasSupport.renderingMode(at: $0.instructionIndex, in: editedContent)
    }
    #expect(editedModes == [0])
  }
}
