import AppKit
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing

@Suite("Direct page text editing interop")
struct DirectTextInteropTests {
  @Test @MainActor func standardFontParagraphErasurePreservesFollowingTextForEveryVariant() throws {
    let text = "A paragraph with ordinary words."
    for family in RewritePageTextCommand.standardFonts.sorted() {
      let (base, pageID) = try graph(content: "BT /SPDFText 16 Tf 42 700 Td (\(text)) Tj ( Adjacent) Tj ET")
      var source = base
      guard case .dictionary(let page)? = source.objects[pageID],
        case .dictionary(let resources)? = page[PDFName("Resources")],
        case .dictionary(let fonts)? = resources[PDFName("Font")],
        case .reference(let fontID)? = fonts.values.first,
        case .dictionary(var font)? = source.objects[fontID]
      else { throw CocoaError(.fileReadCorruptFile) }
      font[PDFName("BaseFont")] = .name(PDFName(family))
      source.objects[fontID] = .dictionary(font)
      let advance = try #require(NativeParagraphEditing.standardAdvance(text, family: family, size: 16))
      let edited = try PDFEditingEngine.commit(PDFTransaction([
        RewritePageTextCommand(pageID: pageID, originalText: [0: text],
          lines: [.init(text: "Replacement", x: 42, baseline: 600)],
          fontSize: 16, color: [0, 0, 0], standardFontAdvances: [0: advance])
      ]), to: source)
      let before = try bounds("Adjacent", in: source)
      let after = try bounds("Adjacent", in: edited)
      #expect(abs(before.minX - after.minX) < 0.02, "\(family) adjacent pen must stay fixed")
      #expect(abs(before.minY - after.minY) < 0.02, "\(family) adjacent baseline must stay fixed")
    }
  }
  @Test @MainActor func paragraphRewriteRemovesOldTextAndPreservesAdjacentPenAndGraphics() throws {
    let one = "Original first paragraph line"
    let two = "Original second paragraph line"
    let (original, pageID) = try graph(content: """
      0.2 0.6 0.8 rg 30 620 480 100 re f 0 g
      BT /SPDFText 16 Tf 42 700 Td (\(one)) Tj ( Neighbor one) Tj
      0 -22 Td (\(two)) Tj ( Neighbor two) Tj ET
      2 0 0 2 10 20 cm
      """)
    let advanceOne = try #require(NativeParagraphEditing.standardAdvance(one, family: "Helvetica", size: 16))
    let advanceTwo = try #require(NativeParagraphEditing.standardAdvance(two, family: "Helvetica", size: 16))
    let originalBytes = try PDFWriter.write(original)
    let lines = [PageTextLine(text: "Longer edited paragraph", x: 68, baseline: 600),
      PageTextLine(text: "with a second wrapped line.", x: 68, baseline: 578)]
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [0: one, 2: two], lines: lines,
      fontSize: 18, color: [0.1, 0.2, 0.8], standardFontAdvances: [0: advanceOne, 2: advanceTwo])
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: original)
    #expect(try PDFWriter.write(original) == originalBytes)
    let reader = try #require(PDFDocument(data: PDFWriter.write(edited)))
    #expect(reader.string?.contains("Original") == false)
    #expect(reader.string?.contains("Longer edited paragraph") == true)
    for neighbor in ["Neighbor one", "Neighbor two"] {
      let before = try bounds(neighbor, in: original)
      let after = try bounds(neighbor, in: edited)
      #expect(abs(before.minX - after.minX) < 0.02)
      #expect(abs(before.minY - after.minY) < 0.02)
    }
    let replacement = try bounds("Longer edited paragraph", in: edited)
    #expect(abs(replacement.minX - 68) < 0.01)
    #expect(replacement.minY > 593 && replacement.maxY < 622)
    // The final page cm must not double the saved position or font size.
    let attributes = try #require(reader.page(at: 0)?.selection(for: replacement)?.attributedString)
    let font = try #require(attributes.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(abs(font.pointSize - 18) < 0.1)
  }

  @Test @MainActor func sameStyleParagraphRewritePreservesPDFKitReadingOrder() throws {
    let firstText = "Original "
    let secondText = "phrase"
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var original = parsed.graph
    guard case .dictionary(let page)? = original.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .stream? = original.objects[contentID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")]
    else { throw CocoaError(.fileReadCorruptFile) }
    original.objects[contentID] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 0>> BDC
      BT /F1 16 Tf 42 700 Td (\(firstText)) Tj (\(secondText)) Tj ET
      EMC
      /P <</MCID 1>> BDC
      BT /F1 16 Tf 42 660 Td (Independent neighbor) Tj ET
      EMC
      """.utf8)))
    original.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    let firstAdvance = try #require(
      NativeParagraphEditing.standardAdvance(firstText, family: "Helvetica", size: 16))
    let secondAdvance = try #require(
      NativeParagraphEditing.standardAdvance(secondText, family: "Helvetica", size: 16))
    let originalDocument = try #require(PDFDocument(data: PDFWriter.write(original)))
    let originalPageText = try #require(originalDocument.page(at: 0)?.string)
    let originalParagraph = try #require(originalPageText.range(of: "Original phrase"))
    let originalNeighbor = try #require(originalPageText.range(of: "Independent neighbor"))
    #expect(originalParagraph.lowerBound < originalNeighbor.lowerBound)
    let edited = try PDFEditingEngine.commit(PDFTransaction([
      RewritePageTextCommand(
        pageID: pageID, originalText: [0: firstText, 1: secondText],
        lines: [.init(text: "Replacement phrase", x: 42, baseline: 700)],
        fontSize: 16, color: [0, 0, 0],
        standardFontAdvances: [0: firstAdvance, 1: secondAdvance])
    ]), to: original)
    let document = try #require(PDFDocument(data: PDFWriter.write(edited)))
    let pageText = try #require(document.page(at: 0)?.string)
    let replacement = try #require(pageText.range(of: "Replacement phrase"))
    let neighbor = try #require(pageText.range(of: "Independent neighbor"))
    #expect(replacement.lowerBound < neighbor.lowerBound)
  }

  @Test @MainActor func taggedFragmentRewritePreservesSpacingAndReadingOrder() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var original = parsed.graph
    guard case .dictionary(let page)? = original.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")]
    else { throw CocoaError(.fileReadCorruptFile) }

    original.objects[contentID] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 0>> BDC
      BT /F1 16 Tf 42 700 Td (A) Tj (BC) Tj ET
      EMC
      /P <</MCID 1>> BDC
      BT /F1 16 Tf 42 660 Td (Independent neighbor) Tj ET
      EMC
      """.utf8)))
    original.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    if let fixturePath = ProcessInfo.processInfo.environment["SPDF_TAGGED_FRAGMENT_FIXTURE_OUTPUT"] {
      let fixtureURL = URL(fileURLWithPath: fixturePath)
      try FileManager.default.createDirectory(
        at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PDFWriter.write(original).write(to: fixtureURL, options: .atomic)
    }

    func glyphWidth(_ character: String) throws -> Double {
      try #require(NativeParagraphEditing.standardAdvance(
        character, family: "Helvetica", size: 1_000))
    }
    let regular = PageTextFormat(font: .helvetica, size: 16)
    let cSpacing = 0.2
    let bSpacing = -0.2
    let cX = 42.0
    let cAdvance = try glyphWidth("C") * 16 / 1_000
    let bAdvance = try glyphWidth("B") * 16 / 1_000
    let bX = cX + cAdvance + cSpacing
    let aX = bX + bAdvance + bSpacing
    let line = PageTextLine(text: "CBA", x: 42, baseline: 700, segments: [
      .init(text: "C", x: cX,
        format: PageTextFormat(font: .helvetica, size: 16, characterSpacing: cSpacing)),
      .init(text: "B", x: bX,
        format: PageTextFormat(font: .helvetica, size: 16, characterSpacing: bSpacing)),
      .init(text: "A", x: aX, format: regular),
    ])
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [0: "A", 1: "BC"], lines: [line],
      fontSize: 16, color: [0, 0, 0], standardFontAdvances: [
        0: try #require(NativeParagraphEditing.standardAdvance("A", family: "Helvetica", size: 16)),
        1: try #require(NativeParagraphEditing.standardAdvance("BC", family: "Helvetica", size: 16)),
      ])
    let sourceRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: original)
    #expect(sourceRuns.map(\.text) == ["A", "BC", "Independent neighbor"])
    #expect(sourceRuns.first?.format == regular)
    let sourceDocument = try #require(PDFDocument(data: PDFWriter.write(original)))
    let sourcePage = try #require(sourceDocument.page(at: 0))
    let blocks = try PageTextEditing.blocks(pageID: pageID, in: original)
    let discovered = NativeParagraphEditing.targets(
      from: blocks, pageID: pageID, graph: original, page: sourcePage, pageIndex: 0)
    let discoveredParagraph = try #require(
      discovered.first { $0.paragraph != nil && $0.text == "ABC" })
    let paragraph = try #require(discoveredParagraph.paragraph)
    #expect(paragraph.originalText == [0: "A", 1: "BC"])
    let hiddenPreview = try PageTextEditing.hidingParagraph(
      pageID: pageID, originalText: paragraph.originalText,
      standardFontAdvances: paragraph.standardFontAdvances, in: original)
    #expect(try PDFWriter.write(hiddenPreview).count > 0)
    try command.validate(in: original)

    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: original)
    let document = try #require(PDFDocument(data: PDFWriter.write(edited)))
    let pageText = try #require(document.page(at: 0)?.string)
    let replacement = try #require(pageText.range(of: "CBA"))
    let neighbor = try #require(pageText.range(of: "Independent neighbor"))
    #expect(replacement.lowerBound < neighbor.lowerBound)

    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let reopenedPageID = try #require(reopened.pageIDs.first)
    let reopenedSourceRuns = try PageTextEditing.sourceRuns(
      pageID: reopenedPageID, in: reopened.graph)
    let replacementRuns = Array(reopenedSourceRuns.prefix(3))
    #expect(replacementRuns.map(\.text) == ["C", "B", "A"])
    #expect(abs(replacementRuns[0].x - cX) < 0.002)
    #expect(abs(replacementRuns[1].x - bX) < 0.002)
    #expect(abs(replacementRuns[2].x - aX) < 0.002)

    let reopenedPage = try #require(document.page(at: 0))
    let reopenedBlocks = try PageTextEditing.blocks(pageID: reopenedPageID, in: reopened.graph)
    let reopenedTargets = NativeParagraphEditing.targets(
      from: reopenedBlocks, pageID: reopenedPageID, graph: reopened.graph,
      page: reopenedPage, pageIndex: 0)
    #expect(reopenedTargets.contains { $0.paragraph != nil && $0.text == "CBA" })

    guard case .stream(let editedContent)? = edited.objects[contentID] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let serializedContent = String(decoding: editedContent.bytes, as: UTF8.self)
    #expect(serializedContent.contains("(C)"))
    #expect(serializedContent.contains("(B)"))
    #expect(serializedContent.contains("(A)"))
    #expect(serializedContent.contains("Independent neighbor"))
  }

  @Test @MainActor func taggedParagraphRewriteKeepsMultilineMCIDBoundaries() throws {
    let firstText = "Original paragraph keeps several ordinary words "
    let secondText = "across two separate lines"
    let editedFirst = String(firstText.reversed())
    let editedSecond = String(secondText.reversed())
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var original = parsed.graph
    guard case .dictionary(let page)? = original.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .stream? = original.objects[contentID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")]
    else { throw CocoaError(.fileReadCorruptFile) }
    original.objects[contentID] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 1>> BDC
      BT /F1 16 Tf 42 700 Td (\(firstText)) Tj ET
      EMC
      /P <</MCID 3>> BDC
      BT /F2 16 Tf 42 680 Td (\(secondText)) Tj ET
      EMC
      BT /F1 12 Tf 42 640 Td (Independent neighbor) Tj ET
      """.utf8)))
    original.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    var updatedPage = page
    var updatedResources = resources
    var updatedFonts = fonts
    updatedFonts[PDFName("F2")] = .reference(fontID)
    updatedResources[PDFName("Font")] = .dictionary(updatedFonts)
    updatedPage[PDFName("Resources")] = .dictionary(updatedResources)
    original.objects[pageID] = .dictionary(updatedPage)
    original.objects[PDFObjectID(22)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("P")),
      PDFName("P"): .reference(PDFObjectID(20)),
      PDFName("Pg"): .reference(PDFObjectID(3)),
      PDFName("C"): .name(PDFName("Body")),
      PDFName("K"): .array([.integer(1), .integer(3)]),
    ])
    original.objects[PDFObjectID(25)] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0), .array([
          .reference(PDFObjectID(21)), .reference(PDFObjectID(22)),
          .reference(PDFObjectID(23)), .reference(PDFObjectID(22)),
        ]),
        .integer(1), .reference(PDFObjectID(24)),
        .integer(2), .reference(PDFObjectID(42)),
      ])
    ])
    let firstAdvance = try #require(
      NativeParagraphEditing.standardAdvance(firstText, family: "Helvetica", size: 16))
    let secondAdvance = try #require(
      NativeParagraphEditing.standardAdvance(secondText, family: "Helvetica", size: 16))
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [0: firstText, 1: secondText], lines: [
        .init(text: editedFirst, x: 42, baseline: 700),
        .init(text: editedSecond, x: 42, baseline: 680),
      ],
      fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: [0: firstAdvance, 1: secondAdvance])
    let validator = try PageTextRewriteValidator(pageID: pageID, in: original)
    #expect(validator.canPreserveMarkedContentOrder(runIndices: [0, 1]))
    let sourceDocument = try #require(PDFDocument(data: PDFWriter.write(original)))
    let sourcePage = try #require(sourceDocument.page(at: 0))
    let blocks = try PageTextEditing.blocks(pageID: pageID, in: original)
    let targets = NativeParagraphEditing.targets(
      from: blocks, pageID: pageID, graph: original, page: sourcePage, pageIndex: 0)
    #expect(targets.contains {
      $0.paragraph?.originalText == [0: firstText, 1: secondText]
    })
    try command.validate(in: original)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: original)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let reopenedPageID = try #require(reopened.pageIDs.first)
    let inventory = try PDFStructureInspector.inspect(in: reopened.graph, pageIDs: reopened.pageIDs)
    let paragraph = try #require(inventory.elements.first { $0.objectID == PDFObjectID(22) })
    #expect(try PDFStructureText.text(
      of: paragraph, pageIDs: reopened.pageIDs, in: reopened.graph)
      == "\(editedFirst)\n\(editedSecond)")
    let document = try #require(PDFDocument(data: PDFWriter.write(edited)))
    #expect(try #require(document.page(at: 0)?.string).contains("Independent neighbor"))
    #expect(inventory.pageMCIDs[0].contains(1))
    #expect(inventory.pageMCIDs[0].contains(3))
    let rewrittenRuns = try PageTextEditing.sourceRuns(pageID: reopenedPageID, in: reopened.graph)
    #expect(rewrittenRuns.prefix(editedFirst.count + editedSecond.count)
      .map(\.text).joined() == editedFirst + editedSecond)

    var reordered = original
    guard case .dictionary(var paragraphElement)? = reordered.objects[PDFObjectID(22)] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    paragraphElement[PDFName("K")] = .array([.integer(3), .integer(1)])
    reordered.objects[PDFObjectID(22)] = .dictionary(paragraphElement)
    let reorderedValidator = try PageTextRewriteValidator(pageID: pageID, in: reordered)
    #expect(!reorderedValidator.canPreserveMarkedContentOrder(runIndices: [0, 1]))
    #expect(throws: PDFError.self) { try command.validate(in: reordered) }
  }

  @Test @MainActor func taggedSingleLineRewriteKeepsFinalSourceWhitespace() throws {
    let firstText = "Original"
    let secondText = "phrase "
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var graph = parsed.graph
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")]
    else { throw CocoaError(.fileReadCorruptFile) }

    let firstAdvance = try #require(
      NativeParagraphEditing.standardAdvance(firstText, family: "Helvetica", size: 16))
    let spaceAdvance = try #require(
      NativeParagraphEditing.standardAdvance(" ", family: "Helvetica", size: 16))
    var updatedPage = page
    var updatedResources = resources
    var updatedFonts = fonts
    updatedFonts[PDFName("F2")] = .reference(fontID)
    updatedResources[PDFName("Font")] = .dictionary(updatedFonts)
    updatedPage[PDFName("Resources")] = .dictionary(updatedResources)
    graph.objects[pageID] = .dictionary(updatedPage)
    graph.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    graph.objects[contentID] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 1>> BDC
      BT /F1 16 Tf 42 700 Td (\(firstText)) Tj ET
      EMC
      /P <</MCID 3>> BDC
      BT /F2 16 Tf 1 0 0 1 \(42 + firstAdvance + spaceAdvance) 700 Tm (\(secondText)) Tj ET
      EMC
      """.utf8)))

    guard case .dictionary(var paragraphElement)? = graph.objects[PDFObjectID(22)],
      case .dictionary(var parentTree)? = graph.objects[PDFObjectID(25)],
      case .array(var numberTreeEntries)? = parentTree[PDFName("Nums")],
      numberTreeEntries.count > 1,
      case .array(var pageParents) = numberTreeEntries[1],
      pageParents.indices.contains(1)
    else { throw CocoaError(.fileReadCorruptFile) }
    paragraphElement[PDFName("K")] = .array([.integer(1), .integer(3)])
    graph.objects[PDFObjectID(22)] = .dictionary(paragraphElement)
    pageParents[1] = .reference(PDFObjectID(22))
    numberTreeEntries[1] = .array(pageParents)
    parentTree[PDFName("Nums")] = .array(numberTreeEntries)
    graph.objects[PDFObjectID(25)] = .dictionary(parentTree)

    let sourceRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: graph)
    #expect(sourceRuns.prefix(2).map(\.text) == [firstText, secondText])
    let sourceDocument = try #require(PDFDocument(data: PDFWriter.write(graph)))
    let sourcePage = try #require(sourceDocument.page(at: 0))
    let blocks = try PageTextEditing.blocks(pageID: pageID, in: graph)
    let targets = NativeParagraphEditing.targets(
      from: blocks, pageID: pageID, graph: graph, page: sourcePage, pageIndex: 0)
    let target = try #require(targets.first { $0.paragraph != nil && $0.text == "Original phrase" })
    let targetParagraph = try #require(target.paragraph)
    #expect(targetParagraph.sourceRunOutputCounts == [0: firstText.count + 1, 1: secondText.count])
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: targetParagraph.originalText,
      lines: [.init(text: "Reworded phrase", x: 42, baseline: 700)],
      fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: targetParagraph.standardFontAdvances,
      sourceRunOutputCounts: targetParagraph.sourceRunOutputCounts)
    try command.validate(in: graph)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let reopenedPageID = try #require(reopened.pageIDs.first)
    let rewrittenRuns = try PageTextEditing.sourceRuns(pageID: reopenedPageID, in: reopened.graph)
    #expect(rewrittenRuns.map(\.text).joined() == "Reworded phrase ")
  }

  @Test @MainActor func taggedPartialTJInstructionIsRefused() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageID = try #require(parsed.pageIDs.first)
    var graph = parsed.graph
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")]
    else { throw CocoaError(.fileReadCorruptFile) }
    graph.objects[fontID] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    graph.objects[contentID] = .stream(PDFStream(bytes: Data("""
      /P <</MCID 1>> BDC
      BT /F1 16 Tf 42 700 Td [(Kept ) (neighbor)] TJ ET
      EMC
      """.utf8)))
    let runs = try PageTextEditing.sourceRuns(pageID: pageID, in: graph)
    #expect(runs.prefix(2).map(\.text) == ["Kept ", "neighbor"])
    let first = try #require(runs.first)
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [first.index: first.text],
      lines: [.init(text: "Edited", x: first.x, baseline: first.baseline)],
      fontSize: first.format.size, color: first.format.color)
    #expect(throws: PDFError.self) { try command.validate(in: graph) }
  }

  @Test @MainActor func paragraphRewriteRefusesStaleGlyphAndUnsupportedClippingState() throws {
    let text = "A complete source paragraph line"
    let (original, pageID) = try graph(content: """
      q 30 600 400 140 re 40 610 20 20 re W* n
      BT /SPDFText 16 Tf 42 700 Td (\(text)) Tj ET Q
      """)
    let advance = try #require(NativeParagraphEditing.standardAdvance(text, family: "Helvetica", size: 16))
    let command = RewritePageTextCommand(
      pageID: pageID, originalText: [0: text],
      lines: [.init(text: "Replacement", x: 42, baseline: 700)], fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: [0: advance])
    #expect(throws: PDFError.self) { try command.validate(in: original) }
    let (plain, _) = try graph(content: "BT /SPDFText 16 Tf 42 700 Td (Different text) Tj ET")
    #expect(throws: PDFError.self) { try command.validate(in: plain) }
    let (supported, _) = try graph(content: "BT /SPDFText 16 Tf 42 700 Td (\(text)) Tj ET")
    let missingGlyph = RewritePageTextCommand(
      pageID: pageID, originalText: [0: text],
      lines: [.init(text: "Unavailable glyph: 🐈", x: 42, baseline: 700)],
      fontSize: 16, color: [0, 0, 0], standardFontAdvances: [0: advance])
    #expect(throws: PDFError.self) { try missingGlyph.validate(in: supported) }
    var repeated = supported
    if case .dictionary(var dictionary)? = repeated.objects[pageID],
      let contents = dictionary[PDFName("Contents")]
    {
      if case .array(let streams) = contents {
        dictionary[PDFName("Contents")] = .array(streams + streams)
      } else {
        dictionary[PDFName("Contents")] = .array([contents, contents])
      }
      repeated.objects[pageID] = .dictionary(dictionary)
    }
    let repeatedCommand = RewritePageTextCommand(
      pageID: pageID, originalText: [0: text],
      lines: [.init(text: "Replacement", x: 42, baseline: 700)],
      fontSize: 16, color: [0, 0, 0], standardFontAdvances: [0: advance])
    #expect(throws: PDFError.self) { try repeatedCommand.validate(in: repeated) }
  }

  @Test @MainActor func paragraphRewriteMeasuresAStandardFontAddedByFormatting() throws {
    let originalText = "Original paragraph"
    let (original, pageID) = try graph(content: """
      BT /SPDFText 16 Tf 42 700 Td (\(originalText)) Tj ET
      BT /SPDFText 16 Tf 42 660 Td (Independent neighbor) Tj ET
      """)
    let regular = PageTextFormat(font: .helvetica, size: 16)
    let emphasized = PageTextFormat(
      font: .timesBoldItalic, size: 18, color: [0.8, 0.1, 0.2])
    let standardAdvance = try #require(
      NativeParagraphEditing.standardAdvance(originalText, family: "Helvetica", size: 16))
    let replacement = PageTextLine(text: "Keep these words.", x: 42, baseline: 700,
      segments: [
        .init(text: "Keep ", x: 42, format: regular),
        .init(text: "these words.", x: 80, format: emphasized),
      ])
    let command = RewritePageTextCommand(pageID: pageID, originalText: [0: originalText],
      lines: [replacement], fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: [0: standardAdvance])
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: original)
    let reader = try #require(PDFDocument(data: PDFWriter.write(edited)))
    #expect(reader.string?.contains("Keep these words.") == true)
    #expect(reader.string?.contains("Independent neighbor") == true)

    let collision = RewritePageTextCommand(pageID: pageID, originalText: [0: originalText],
      lines: [PageTextLine(text: replacement.text, x: 42, baseline: 660,
        segments: replacement.segments)], fontSize: 16, color: [0, 0, 0],
      standardFontAdvances: [0: standardAdvance])
    do {
      try collision.validate(in: original)
      Issue.record("A formatted paragraph overlapped an independent text block")
    } catch let error as PDFError {
      #expect(error.message.contains("overlap another text block"))
    }
  }

  @Test @MainActor func nativeParagraphGroupingRequiresAFullWrappingRoundTrip() throws {
    let font = try #require(NSFont(name: "Helvetica", size: 16))
    let text = "A natural paragraph can be edited directly on the page with automatic wrapping and predictable saved line positions."
    let lines = NativeParagraphEditing.wrappedLines(text, font: font, width: 265)
    #expect(lines.count >= 3)
    let instructions = lines.enumerated().map { index, line in
      "1 0 0 1 42 \(700 - index * 22) Tm (\(line)) Tj"
    }.joined(separator: "\n")
    let (original, pageID) = try graph(content: "BT /SPDFText 16 Tf\n\(instructions)\nET")
    let reader = try #require(PDFDocument(data: PDFWriter.write(original)))
    let page = try #require(reader.page(at: 0))
    let blocks = try lines.enumerated().map { index, line in
      let rect = try bounds(line, in: original)
      return PageTextTarget(pageIndex: 0, runIndex: index,
        rect: [rect.minX, rect.minY, rect.maxX, rect.maxY], text: line,
        style: .init(fontFamily: "Helvetica", fontSize: 16, fillColor: [0, 0, 0]))
    }
    let grouped = NativeParagraphEditing.targets(from: blocks, pageID: pageID, graph: original, page: page)
    let paragraph = try #require(grouped.first?.paragraph)
    #expect(grouped.count == 1)
    #expect(grouped[0].text == text)
    #expect(paragraph.originalText.count == lines.count)
    // Nearby short labels are separate objects even when aligned.
    let labels = blocks.enumerated().map { index, block in
      PageTextTarget(pageIndex: 0, runIndex: index, rect: block.rect,
        text: "Label \(index)", style: block.style)
    }
    #expect(NativeParagraphEditing.targets(from: labels, pageID: pageID, graph: original, page: page)
      .allSatisfy { $0.paragraph == nil })
  }
  private func graph(content: String) throws -> (PDFGraph, PDFObjectID) {
    let parsed = try PDFParser.parse(BlankPDF.data())
    let page = parsed.pageIDs[0]
    let authored = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(pageID: page, rect: [40, 650, 450, 700], text: "Fixture")
      ]), to: parsed.graph)
    var result = authored
    guard case .dictionary(let dictionary)? = result.objects[page],
      case .dictionary(let resources)? = dictionary[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")], let font = fonts.keys.first
    else { throw CocoaError(.fileReadCorruptFile) }
    let stream: PDFObjectID
    switch dictionary[PDFName("Contents")] {
    case .reference(let id)?: stream = id
    case .array(let entries)?:
      guard case .reference(let id)? = entries.last else { throw CocoaError(.fileReadCorruptFile) }
      stream = id
    default: throw CocoaError(.fileReadCorruptFile)
    }
    let actual = content.replacingOccurrences(
      of: "/SPDFText ", with: "/\(String(decoding: font.bytes, as: UTF8.self)) ")
    result.objects[stream] = .stream(PDFStream(bytes: Data(actual.utf8)))
    return (result, page)
  }

  private func bounds(_ needle: String, in graph: PDFGraph) throws -> CGRect {
    let document = try #require(PDFDocument(data: PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    let text = try #require(page.string) as NSString
    let range = text.range(of: needle)
    #expect(range.location != NSNotFound)
    return try #require(page.selection(for: range)).bounds(for: page)
  }

  @Test func movingMiddleTextPreservesAdjacentAdvancesAndNextLine() throws {
    let (original, page) = try graph(
      content: """
        BT /SPDFText 16 Tf 42 700 Td (Before ) Tj (Moving) Tj ( After) Tj
        0 -40 Td (Next line) Tj ET
        """)
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveTextCommand(pageID: page, runIndex: 1, dx: 50, dy: -30)
      ]), to: original)
    let before = try bounds("Moving", in: original)
    let after = try bounds("Moving", in: moved)
    #expect(abs(after.minX - before.minX - 50) < 0.1)
    #expect(abs(after.minY - before.minY + 30) < 0.1)
    for neighbor in ["Before", "After", "Next line"] {
      let a = try bounds(neighbor, in: original)
      let b = try bounds(neighbor, in: moved)
      #expect(abs(a.minX - b.minX) < 0.1)
      #expect(abs(a.minY - b.minY) < 0.1)
    }
  }

  @Test func movementUsesPageCoordinatesThroughGraphicsTransforms() throws {
    let (original, page) = try graph(
      content: """
        q 2 0 0 1.5 12 20 cm
        BT /SPDFText 16 Tf 42 420 Td (Moving) Tj ET Q
        BT /SPDFText 16 Tf 42 600 Td (Neighbor) Tj ET
        """)
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveTextCommand(pageID: page, runIndex: 0, dx: 50, dy: -30)
      ]), to: original)
    let a = try bounds("Moving", in: original)
    let b = try bounds("Moving", in: moved)
    #expect(abs(b.minX - a.minX - 50) < 0.1)
    #expect(abs(b.minY - a.minY + 30) < 0.1)
    #expect(try bounds("Neighbor", in: moved) == bounds("Neighbor", in: original))
  }

  @Test func transientHiddenTextPreservesSourceAndFollowingPen() throws {
    let (original, page) = try graph(
      content: """
        0.2 0.6 0.8 rg 30 660 400 70 re f 0 g
        BT /SPDFText 16 Tf 42 700 Td (Before ) Tj (Moving) Tj ( After) Tj ET
        """)
    let originalBytes = try PDFWriter.write(original)
    let preview = try PageTextEditing.hidingBlock(pageID: page, runIndex: 1, in: original)
    #expect(try PDFWriter.write(original) == originalBytes)
    #expect(try bounds("After", in: preview) == bounds("After", in: original))
    // A real reader still processes the invisible run's original advances.
    let document = try #require(PDFDocument(data: PDFWriter.write(preview)))
    #expect(document.string?.contains("Before Moving After") == true)
    // Render in an independent engine: background pixels remain identical,
    // while the active glyph region loses its black ink.
    func pixels(_ graph: PDFGraph) throws -> [UInt8] {
      let data = try PDFWriter.write(graph)
      let provider = try #require(CGDataProvider(data: data as CFData))
      let pdf = try #require(CGPDFDocument(provider))
      let page = try #require(pdf.page(at: 1))
      let context = try #require(
        CGContext(
          data: nil, width: 600, height: 850,
          bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 600, height: 850))
      context.drawPDFPage(page)
      let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      return Array(UnsafeBufferPointer(start: bytes, count: 600 * 850 * 4))
    }
    func darkPixels(_ bytes: [UInt8], rect: CGRect) -> Int {
      var count = 0
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          let offset = (849 - y) * 2400 + x * 4
          if bytes[offset] < 35 && bytes[offset + 1] < 35 && bytes[offset + 2] < 35 { count += 1 }
        }
      }
      return count
    }
    let area = try bounds("Moving", in: original).insetBy(dx: -1, dy: -1)
    let beforePixels = try pixels(original)
    let previewPixels = try pixels(preview)
    #expect(darkPixels(beforePixels, rect: area) > 15)
    #expect(darkPixels(previewPixels, rect: area) == 0)
    var changedOutside = 0
    for y in 0..<850 {
      for x in 0..<600 where !area.contains(CGPoint(x: x, y: y)) {
        let offset = (849 - y) * 2400 + x * 4
        if beforePixels[offset..<offset + 4] != previewPixels[offset..<offset + 4] {
          changedOutside += 1
        }
      }
    }
    #expect(changedOutside == 0)
  }

  @Test func stylingMiddleTextDoesNotRestyleItsNeighbors() throws {
    let (original, page) = try graph(
      content: """
        BT /SPDFText 16 Tf 42 700 Td (Before ) Tj (Moving) Tj ( After) Tj ET
        """)
    let styled = try PDFEditingEngine.commit(
      PDFTransaction([
        ChangeTextStyleCommand(
          pageID: page, runIndex: 1,
          style: TextStyleChange(fontSize: 22, fillColor: [1, 0, 0]))
      ]), to: original)
    let document = try #require(PDFDocument(data: PDFWriter.write(styled)))
    let text = try #require(document.page(at: 0)?.attributedString)
    for (needle, size) in [("Before", 16.0), ("Moving", 22.0), ("After", 16.0)] {
      let range = (text.string as NSString).range(of: needle)
      let font = try #require(
        text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
      #expect(abs(font.pointSize - size) < 0.1)
    }
  }
  @Test func directPreviewRefusesTransformsAndSpacingItCannotMatch() throws {
    for content in [
      "BT /SPDFText 16 Tf 0 1 -1 0 200 200 Tm (Rotated) Tj ET",
      "BT /SPDFText 16 Tf 42 700 Td 2 Tc (Spaced) Tj ET",
      "BT /SPDFText 16 Tf 42 700 Td [(Kerned) -120 (text)] TJ ET",
    ] {
      let (original, page) = try graph(content: content)
      let bytes = try PDFWriter.write(original)
      #expect(throws: PDFError.self) {
        try PageTextEditing.hidingBlock(pageID: page, runIndex: 0, in: original)
      }
      #expect(try PDFWriter.write(original) == bytes)
    }
  }

  @Test func coincidentRotatedShowsHaveDeterministicReadingOrder() throws {
    let (original, page) = try graph(
      content: """
        BT /SPDFText 16 Tf 0 1 -1 0 200 200 Tm (First) Tj ET
        BT /SPDFText 16 Tf 0 1 -1 0 200 200 Tm (Other) Tj ET
        """)
    let expected = try PageTextLayout.build(pageID: page, in: original).clusters.map(\.text)
    for _ in 0..<20 {
      #expect(try PageTextLayout.build(pageID: page, in: original).clusters.map(\.text) == expected)
      let reopened = try PDFParser.parse(PDFWriter.write(original))
      #expect(
        try PageTextLayout.build(pageID: reopened.pageIDs[0], in: reopened.graph).clusters.map(
          \.text) == expected)
    }
  }

}
