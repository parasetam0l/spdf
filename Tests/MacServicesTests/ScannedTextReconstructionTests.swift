import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import Testing

@Suite("Scanned text reconstruction")
struct ScannedTextReconstructionTests {
  struct Fixture {
    var graph: PDFGraph
    let pageIDs: [PDFObjectID]
    let imageIDs: [PDFObjectID]
    let raster: ScanRaster
  }

  func fixture() throws -> Fixture {
    let raster = try ScanTestSupport.raster(
      lines: [
        .init(text: "SCAN TEXT", baseline: 560, x: 48),
        .init(text: "SECOND LINE", baseline: 480, x: 48),
      ], background: 240)
    let built = try ScanTestSupport.graph(scans: [raster])
    var graph = built.graph
    try ScanTestSupport.addOCRLayer(
      to: &graph, pageID: built.pageIDs[0],
      lines: [
        .init(text: "SCAN TEXT", baseline: 560, x: 48),
        .init(text: "SECOND LINE", baseline: 480, x: 48),
      ])
    return Fixture(
      graph: graph, pageIDs: built.pageIDs, imageIDs: built.imageIDs, raster: raster)
  }

  func word(
    _ text: String, in fixture: Fixture
  ) throws -> ScannedWord {
    let words = try ScannedTextReconstructionService.words(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph)
    return try #require(words.first { $0.text == text })
  }

  @Test func wordsExposeGeneratedLayerAndRequireOCRText() throws {
    let fixture = try fixture()
    let words = try ScannedTextReconstructionService.words(
      pageIndex: 0, pageID: fixture.pageIDs[0], in: fixture.graph)
    #expect(words.map(\.text) == ["SCAN", "TEXT", "SECOND", "LINE"])
    #expect(words.allSatisfy { $0.rect[2] > $0.rect[0] && $0.rect[3] > $0.rect[1] })
    #expect(words[0].rect[0] < words[1].rect[0])

    let plain = try ScanTestSupport.graph(scans: [fixture.raster])
    let plainPage = try PDFPageTree.pageIDs(in: plain.graph)[0]
    do {
      _ = try ScannedTextReconstructionService.words(
        pageIndex: 0, pageID: plainPage, in: plain.graph)
      Issue.record("Expected a refusal for a page without a generated OCR layer")
    } catch let refusal as ScannedTextRefusal {
      #expect(refusal.message.contains("no editable recognized text"))
    }
  }

  @Test func previewErasesPixelsWithoutMutating() throws {
    let fixture = try fixture()
    let target = try word("SCAN", in: fixture)
    let before = try ScanTestSupport.savedBytes(fixture.graph)
    let plan = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: fixture.pageIDs[0], word: target, replacement: "CLEAN",
      in: fixture.graph)
    #expect(plan.preview.isSupported)
    #expect(plan.command != nil)
    #expect(plan.transaction != nil)
    #expect(plan.preview.beforePNG != nil)
    #expect(plan.preview.afterPNG != nil)
    #expect((plan.preview.erasedInkRatio ?? 0) > 0)
    // Preview never mutates the document graph.
    #expect(try ScanTestSupport.savedBytes(fixture.graph) == before)

    let replacement = try #require(plan.preview.replacementRaster)
    let placement = try #require(
      ImageInventory.placements(in: fixture.graph, pageID: fixture.pageIDs[0]).first)
    let mapping = try ScannedTextPixelMapping.pixelRect(
      pageRect: target.rect, imageWidth: replacement.width,
      imageHeight: replacement.height, placementMatrix: placement.localMatrix)
    let region = CGRect(
      x: mapping.x0, y: mapping.y0, width: mapping.x1 - mapping.x0,
      height: mapping.y1 - mapping.y0)
    // Original glyph pixels are gone: the erased box is flat background.
    #expect(ScanInkAnalysis.inkPixelCount(replacement, region: region) == 0)
    // Pixels outside the padded word box are preserved byte for byte.
    let original = try ScanTestSupport.firstRaster(
      pageID: fixture.pageIDs[0], in: fixture.graph)
    // Match the service padding: max(2, boxSize / 6) on each axis.
    let padX = max(2, (mapping.x1 - mapping.x0) / 6) + 1
    let padY = max(2, (mapping.y1 - mapping.y0) / 6) + 1
    var outsideEqual = true
    var checked = 0
    for y in 0..<replacement.height {
      for x in 0..<replacement.width {
        let insideBox = x >= mapping.x0 - padX && x < mapping.x1 + padX
          && y >= mapping.y0 - padY && y < mapping.y1 + padY
        if insideBox { continue }
        checked += 1
        if replacement.pixel(x: x, y: y) != original.pixel(x: x, y: y) {
          outsideEqual = false
          break
        }
      }
      if !outsideEqual { break }
    }
    #expect(checked > 0)
    #expect(outsideEqual)
  }

  @Test func appliedReconstructionChangesVisibleAndSearchableTextCoherently() throws {
    let fixture = try fixture()
    let target = try word("SCAN", in: fixture)
    let plan = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: fixture.pageIDs[0], word: target, replacement: "CLEAN",
      in: fixture.graph)
    let transaction = try #require(plan.transaction)
    let preview = plan.preview
    let replacementRaster = try #require(preview.replacementRaster)
    let cleanedGraph = try PDFEditingEngine.commit(transaction, to: fixture.graph)
    let reopened = try ScanTestSupport.reopened(cleanedGraph)
    let saved = try ScanTestSupport.firstRaster(
      pageID: fixture.pageIDs[0], in: reopened)
    #expect(saved.rgb8 == replacementRaster.rgb8)

    // Searchable/selectable text: the visible replacement appears exactly once
    // and the removed scan word is gone from page text.
    let pageText = try ScanTestSupport.pageText(reopened).lowercased()
    #expect(pageText.contains("clean"))
    #expect(!pageText.contains("scan"))
    #expect(pageText.contains("second line"))
    // The generated layer keeps the untouched words and drops the old one.
    let layerText = TextProvenance.recognizedLayerText(
      pageID: fixture.pageIDs[0], in: reopened)?.lowercased()
    #expect(layerText?.contains("scan") != true)
    #expect(layerText?.contains("text") == true)
    #expect(layerText?.contains("second line") == true)

    // The replacement is a real visible standard-font run, not a hidden copy.
    let runs = try PageTextEditing.sourceRuns(pageID: fixture.pageIDs[0], in: reopened)
    let run = try #require(runs.first { $0.text == "CLEAN" })
    #expect(run.format.sourceFont == nil)
    #expect(run.format.font == .helvetica)

    // Editable: a normal text-edit command can rewrite the reconstructed run.
    var editable = reopened
    let replace = ReplaceTextCommand(
      pageID: fixture.pageIDs[0], runIndex: run.index, replacement: "EDITED")
    try replace.validate(in: editable)
    editable = try replace.apply(to: editable)
    let edited = try ScanTestSupport.reopened(editable)
    let editedText = try ScanTestSupport.pageText(edited).lowercased()
    #expect(editedText.contains("edited"))
    #expect(!editedText.contains("clean"))
  }

  @Test func explicitRefusalsForUnsupportedPaintAndBackground() throws {
    // Unsupported characters are refused before any work.
    let fixture = try fixture()
    let target = try word("SCAN", in: fixture)
    let cjk = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: fixture.pageIDs[0], word: target, replacement: "東京",
      in: fixture.graph)
    #expect(!cjk.preview.isSupported)
    #expect(cjk.preview.refusal?.message.contains("standard fonts") == true)

    // Masked scan images are refused explicitly.
    var masked = fixture
    if case .stream(var stream)? = masked.graph.objects[masked.imageIDs[0]] {
      stream.dictionary[PDFName("SMask")] = .dictionary([:])
      masked.graph.objects[masked.imageIDs[0]] = .stream(stream)
    } else {
      Issue.record("The synthetic scan image is missing")
    }
    let maskedPlan = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: fixture.pageIDs[0], word: target, replacement: "CLEAN",
      in: masked.graph)
    #expect(!maskedPlan.preview.isSupported)
    #expect(maskedPlan.preview.refusal?.message.lowercased().contains("mask") == true)

    // Vector paint overlapping the word is refused rather than damaged.
    var painted = fixture
    if case .dictionary(let page)? = painted.graph.objects[painted.pageIDs[0]],
      case .array(let contents)? = page[PDFName("Contents")],
      case .reference(let contentID)? = contents.first,
      case .stream(let content)? = painted.graph.objects[contentID]
    {
      var bytes = content.bytes
      bytes.append(Data("q 1 0 0 rg 0 520 400 80 re f Q\n".utf8))
      painted.graph.objects[contentID] = .stream(
        PDFStream(dictionary: content.dictionary, bytes: bytes))
    } else {
      Issue.record("The synthetic page content is missing")
    }
    let paintedPlan = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: fixture.pageIDs[0], word: target, replacement: "CLEAN",
      in: painted.graph)
    #expect(!paintedPlan.preview.isSupported)
    #expect(paintedPlan.preview.refusal?.message.lowercased().contains("vector paint") == true)

    // A photo-like background behind the word is refused.
    let noisy = try ScanTestSupport.raster(
      lines: [.init(text: "SCAN TEXT", baseline: 560, x: 48)], background: 240,
      darkInkAround: (x: 100, y: 125, radius: 42))
    let noisyBuilt = try ScanTestSupport.graph(scans: [noisy])
    var noisyGraph = noisyBuilt.graph
    try ScanTestSupport.addOCRLayer(
      to: &noisyGraph, pageID: noisyBuilt.pageIDs[0],
      lines: [.init(text: "SCAN TEXT", baseline: 560, x: 48)])
    let noisyWords = try ScannedTextReconstructionService.words(
      pageIndex: 0, pageID: noisyBuilt.pageIDs[0], in: noisyGraph)
    let noisyWord = try #require(noisyWords.first { $0.text == "SCAN" })
    let noisyPlan = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: noisyBuilt.pageIDs[0], word: noisyWord,
      replacement: "CLEAN", in: noisyGraph)
    #expect(!noisyPlan.preview.isSupported)
    #expect(
      noisyPlan.preview.refusal?.message.lowercased().contains("background") == true)
  }

  @Test func ambiguousScanImageIsRefused() throws {
    let raster = try ScanTestSupport.raster(
      lines: [.init(text: "SCAN TEXT", baseline: 560, x: 48)], background: 240)
    let second = try ScanTestSupport.raster(
      lines: [.init(text: "SECOND", baseline: 400, x: 48)], background: 240)
    var graph = try ScanTestSupport.ambiguousGraph(first: raster, second: second)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    try ScanTestSupport.addOCRLayer(
      to: &graph, pageID: pageID,
      lines: [.init(text: "SCAN TEXT", baseline: 560, x: 48)])
    let words = try ScannedTextReconstructionService.words(
      pageIndex: 0, pageID: pageID, in: graph)
    let target = try #require(words.first { $0.text == "SCAN" })
    let plan = ScannedTextReconstructionService.plan(
      pageIndex: 0, pageID: pageID, word: target, replacement: "CLEAN", in: graph)
    #expect(!plan.preview.isSupported)
    #expect(plan.preview.refusal?.message.lowercased().contains("unambiguous") == true)
  }
}
