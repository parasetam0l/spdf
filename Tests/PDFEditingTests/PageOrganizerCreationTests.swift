import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PAG-01 evidence: thumbnail organizer metadata (labels, mixed sizes,
/// rotation) and batch page actions that commit as one command/one undo step.
@Suite("Page organizer (PAG-01)")
struct PageOrganizerTests {
  private func pageTexts(_ graph: PDFGraph) throws -> [String] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    return try pageIDs.map { pageID in
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    }
  }

  @Test func pageInfoReportsLabelsSizesAndRotation() throws {
    var graph = PDFFixtures.graph(pages: 3, rotatedLastPage: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // Document labels D-1 ... D-3.
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      Issue.record("Fixture catalog missing")
      return
    }
    let labelsID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[labelsID] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0),
        .dictionary([
          PDFName("S"): .name(PDFName("D")),
          PDFName("P"): .string(Data("D-".utf8)),
        ]),
      ])
    ])
    catalog[PDFName("PageLabels")] = .reference(labelsID)
    graph.objects[catalogID] = .dictionary(catalog)
    let info = try PageOrganizerInfo.pages(in: graph)
    #expect(info.count == pageIDs.count)
    #expect(info.map(\.pageID) == pageIDs)
    #expect(info[0].label == "D-1")
    #expect(info[2].label == "D-3")
    #expect(info[0].physicalLabel == "1")
    #expect(info[2].rotation == 90)
    #expect(info[2].displaySize == [792, 612])
    #expect(info[0].mediaBox == [0, 0, 612, 792])
    #expect(info[1].mediaBox == [0, 0, 595, 842])
  }

  @Test func moveSelectionAsOneBlock() throws {
    let graph = PDFFixtures.graph(pages: 4)
    let pages = try PDFPageTree.pageIDs(in: graph)
    let move = MovePagesCommand(pageIDs: [pages[1], pages[2]], toIndex: 0)
    #expect(move.affectedPageIDs(in: graph) == [pages[1], pages[2]])
    // One transaction, one command.
    let moved = try PDFEditingEngine.commit(PDFTransaction([move]), to: graph)
    let movedPages = try PDFPageTree.pageIDs(in: moved)
    #expect(movedPages == [pages[1], pages[2], pages[0], pages[3]])
    let toEnd = MovePagesCommand(pageIDs: [pages[0]], toIndex: 3)
    let ended = try PDFEditingEngine.commit(PDFTransaction([toEnd]), to: moved)
    let endedPages = try PDFPageTree.pageIDs(in: ended)
    #expect(endedPages.last == pages[0])
    let clamped = MovePagesCommand(pageIDs: [pages[3]], toIndex: 0)
    let front = try PDFEditingEngine.commit(PDFTransaction([clamped]), to: graph)
    let frontPages = try PDFPageTree.pageIDs(in: front)
    #expect(frontPages.first == pages[3])
    #expect(throws: PDFError.self) {
      try MovePagesCommand(pageIDs: [], toIndex: 0).validate(in: graph)
    }
    #expect(throws: PDFError.self) {
      try MovePagesCommand(pageIDs: [pages[0], pages[0]], toIndex: 0).validate(in: graph)
    }
    #expect(throws: PDFError.self) {
      try MovePagesCommand(pageIDs: [pages[0]], toIndex: 99).validate(in: graph)
    }
  }

  @Test func duplicateSelectionAsOneBlock() throws {
    let graph = PDFFixtures.graph(pages: 3)
    let pages = try PDFPageTree.pageIDs(in: graph)
    let before = try pageTexts(graph)
    let duplicate = DuplicatePagesCommand(pageIDs: [pages[0], pages[2]])
    let result = try PDFEditingEngine.commit(PDFTransaction([duplicate]), to: graph)
    let resultPages = try PDFPageTree.pageIDs(in: result)
    #expect(resultPages.count == 5)
    #expect(Array(resultPages.prefix(3)) == pages)
    #expect(resultPages[3] != pages[0] && resultPages[4] != pages[2])
    let texts = try pageTexts(result)
    #expect(texts.count == 5)
    #expect(texts[3] == before[0])
    #expect(texts[4] == before[2])
  }

  @Test func batchActionsComposeInOneTransaction() throws {
    let graph = PDFFixtures.graph(pages: 3)
    let pages = try PDFPageTree.pageIDs(in: graph)
    // A single transaction can carry a batch of organizer commands and still
    // produce one document revision.
    let transaction = PDFTransaction([
      RotatePagesCommand(pageIDs: [pages[0], pages[1]], byDegrees: 90),
      MovePagesCommand(pageIDs: [pages[2]], toIndex: 0),
      DuplicatePagesCommand(pageIDs: [pages[0]]),
    ])
    let result = try PDFEditingEngine.commit(transaction, to: graph)
    let resultPages = try PDFPageTree.pageIDs(in: result)
    #expect(resultPages.count == 4)
    #expect(resultPages[0] == pages[2])
    guard case .dictionary(let first)? = result.objects[pages[0]] else {
      Issue.record("Rotated page missing")
      return
    }
    #expect(first[PDFName("Rotate")] == .integer(90))
    #expect(throws: Never.self) { try result.validate(limits: PDFLimits()) }
    _ = try PDFWriter.write(result)
  }
}

/// PAG-08 evidence: multi-image/text/clipboard creation with explicit page
/// size, orientation and margins.
@Suite("PDF creation options (PAG-08)")
struct PDFCreationOptionTests {
  private func raster(width: Int, height: Int, color: UInt8 = 120) -> ImagePDFCreation.Source {
    ImagePDFCreation.Source(
      width: width, height: height,
      rgb8: Data(repeating: color, count: width * height * 3))
  }

  private func parsed(_ result: PDFCreationResult) throws -> ParsedPDF {
    try PDFParser.parse(result.data)
  }

  private func pageSizes(_ graph: PDFGraph) throws -> [[Double]] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    return try pageIDs.map { pageID in
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let values)? = page[PDFName("MediaBox")]
      else { return [] }
      let numbers = values.compactMap { value -> Double? in
        if case .integer(let raw) = value { return Double(raw) }
        if case .real(let raw) = value { return raw }
        return nil
      }
      guard numbers.count == 4 else { return [] }
      return [abs(numbers[2] - numbers[0]), abs(numbers[3] - numbers[1])]
    }
  }

  @Test func multiImageCreationHonorsSizeOrientationAndMargins() throws {
    let sources = [
      raster(width: 200, height: 100, color: 200),
      raster(width: 100, height: 200, color: 80),
    ]
    let result = try MultiImagePDFCreation.make(
      sources: sources, options: PDFCreationPageOptions(margins: 36))
    #expect(result.pageCount == 2)
    let parsed = try parsed(result)
    let sizes = try pageSizes(parsed.graph)
    #expect(sizes[0] == [792, 612])
    #expect(sizes[1] == [612, 792])
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    for (index, pageID) in pageIDs.enumerated() {
      let placements = try ImageInventory.placements(in: parsed.graph, pageID: pageID)
      let rect = try #require(placements.first?.bounds)
      #expect(rect[0] >= 36 - 0.01)
      #expect(rect[1] >= 36 - 0.01)
      #expect(rect[2] <= sizes[index][0] - 36 + 0.01)
      #expect(rect[3] <= sizes[index][1] - 36 + 0.01)
    }
  }

  @Test func explicitOrientationAndA4() throws {
    let landscape = try MultiImagePDFCreation.make(
      sources: [raster(width: 300, height: 100)],
      options: PDFCreationPageOptions(
        pageSize: .a4, orientation: .portrait, margins: 72))
    let landscapeParsed = try parsed(landscape)
    let size = try #require(try pageSizes(landscapeParsed.graph).first)
    #expect(abs(size[0] - 595.276) < 0.01)
    #expect(abs(size[1] - 841.89) < 0.01)
    let forced = try MultiImagePDFCreation.make(
      sources: [raster(width: 100, height: 300)],
      options: PDFCreationPageOptions(
        pageSize: .letter, orientation: .landscape, margins: 0))
    let forcedParsed = try parsed(forced)
    let forcedSizes = try pageSizes(forcedParsed.graph)
    #expect(forcedSizes.first == [792, 612])
  }

  @Test func originalSizeUsesImageDimensions() throws {
    let result = try MultiImagePDFCreation.make(
      sources: [raster(width: 144, height: 72)],
      options: PDFCreationPageOptions(pageSize: .original, margins: 6))
    let originalParsed = try parsed(result)
    let originalSizes = try pageSizes(originalParsed.graph)
    #expect(originalSizes.first == [144, 72])
  }

  @Test func invalidCreationInputsAreRefused() throws {
    #expect(throws: PDFError.self) {
      _ = try MultiImagePDFCreation.make(
        sources: [], options: PDFCreationPageOptions())
    }
    #expect(throws: PDFError.self) {
      _ = try MultiImagePDFCreation.make(
        sources: [ImagePDFCreation.Source(width: 2, height: 2, rgb8: Data([1, 2, 3]))],
        options: PDFCreationPageOptions())
    }
    #expect(throws: PDFError.self) {
      _ = try MultiImagePDFCreation.make(
        sources: [raster(width: 10, height: 10)],
        options: PDFCreationPageOptions(margins: -1))
    }
    #expect(throws: PDFError.self) {
      _ = try MultiImagePDFCreation.make(
        sources: [raster(width: 10, height: 10)],
        options: PDFCreationPageOptions(pageSize: .letter, margins: 400))
    }
  }

  @Test func textCreationAppliesPageSizeOrientationAndMargins() throws {
    let text = (0..<40).map { "Line \($0 + 1) of the clipboard report." }
      .joined(separator: "\n")
    let result = try TextPDFCreationWithLayout.make(
      text: text,
      options: PDFCreationPageOptions(
        pageSize: .a4, orientation: .landscape, margins: 48, textFontSize: 10))
    #expect(result.pageCount >= 1)
    let parsed = try parsed(result)
    let sizes = try pageSizes(parsed.graph)
    #expect(sizes.allSatisfy { abs($0[0] - 841.89) < 0.01 && abs($0[1] - 595.276) < 0.01 })
    let pageIDs = try PDFPageTree.pageIDs(in: parsed.graph)
    let layout = try PageTextLayout.build(pageID: pageIDs[0], in: parsed.graph)
    let bounds = layout.clusters.map(\.bounds)
    #expect(!bounds.isEmpty)
    #expect((bounds.map { $0[0] }.min() ?? 0) >= 48 - 1)
    #expect((bounds.map { $0[1] }.min() ?? 0) >= 48 - 1)
    let extracted = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(extracted.contains("Line 1"))
  }

  @Test func clipboardCreationHandlesTextImagesAndEmpty() throws {
    let text = try ClipboardPDFCreation.make(
      .text("Clipboard text\nwith two lines"),
      options: PDFCreationPageOptions(pageSize: .letter, margins: 36))
    #expect(text.pageCount >= 1)
    let textParsed = try parsed(text)
    let textPageIDs = try PDFPageTree.pageIDs(in: textParsed.graph)
    let layout = try PageTextLayout.build(pageID: textPageIDs[0], in: textParsed.graph)
    let extracted = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(extracted.contains("Clipboard text"))
    let images = try ClipboardPDFCreation.make(
      .images([raster(width: 40, height: 30, color: 10)]),
      options: PDFCreationPageOptions(margins: 18))
    #expect(images.pageCount == 1)
    #expect(throws: PDFError.self) {
      _ = try ClipboardPDFCreation.make(.empty, options: PDFCreationPageOptions())
    }
    #expect(throws: PDFError.self) {
      _ = try ClipboardPDFCreation.make(
        .text("   "), options: PDFCreationPageOptions())
    }
    #expect(throws: PDFError.self) {
      _ = try ClipboardPDFCreation.make(
        .text("text"), options: PDFCreationPageOptions(pageSize: .original))
    }
  }
}
