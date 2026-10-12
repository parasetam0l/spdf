import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P26-010/P26-011/P26-012/P26-013/P26-014/P26-023 evidence: invisible
/// Unicode text layers with ToUnicode mappings, duplicate prevention,
/// replacement, and removal.
@Suite("OCR layers")
struct OCRLayerTests {
  @Test func layerWritesInvisibleUnicodeTextWithToUnicode() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [
            SearchableTextLine(text: "Scanned invoice 42", rect: [100, 600, 300, 620], confidence: 0.9),
            SearchableTextLine(text: "Grüße", rect: [100, 560, 200, 580], confidence: 0.8),
          ])
      ]), to: parsed.graph)

    // The marked content stream draws invisible text with the OCR font.
    let streamIDs = OCRLayer.layerStreamIDs(in: graph, pageID: pageID)
    #expect(streamIDs.count == 1)
    guard let streamID = streamIDs.first, case .stream(let stream)? = graph.objects[streamID]
    else {
      Issue.record("OCR layer stream is missing")
      return
    }
    let content = String(decoding: stream.bytes, as: UTF8.self)
    #expect(content.contains("3 Tr"))
    #expect(content.contains("/Focr 20 Tf"))
    #expect(content.contains("1 0 0 1 100 600 Tm"))
    #expect(content.contains("<005300630061006E006E0065006400200069006E0076006F006900630065002000340032>"))
    #expect(content.contains("<0047007200FC00DF0065>"))  // Grüße

    // Font objects: Type0 Identity-H with a CIDFontType2 and a ToUnicode CMap.
    guard let resources = OCRLayer.pageResources(in: graph, pageID: pageID),
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let type0ID)? = fonts[PDFName("Focr")],
      case .dictionary(let type0)? = graph.objects[type0ID],
      case .array(let descendants)? = type0[PDFName("DescendantFonts")],
      case .reference(let cidID) = descendants.first,
      case .dictionary(let cidFont)? = graph.objects[cidID],
      case .reference(let cmapID)? = type0[PDFName("ToUnicode")],
      case .stream(let cmap)? = graph.objects[cmapID]
    else {
      Issue.record("OCR font objects are missing")
      return
    }
    #expect(type0[PDFName("Subtype")] == .name(PDFName("Type0")))
    #expect(type0[PDFName("Encoding")] == .name(PDFName("Identity-H")))
    #expect(cidFont[PDFName("Subtype")] == .name(PDFName("CIDFontType2")))
    #expect(cidFont[PDFName("DW")] == .integer(1000))
    let cmapText = String(decoding: cmap.bytes, as: UTF8.self)
    #expect(cmapText.contains("begincmap"))
    #expect(cmapText.contains("<00FC> <00FC>"))

    // The layer is marked and reparses identically; extraction through
    // independent readers is verified in the Apple interoperability suite
    // (our own layout engine does not decode Type0 text yet).
    #expect(OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID))
    #expect(try PDFParser.parse(PDFWriter.write(graph)).graph == graph)
  }

  @Test func layerRefusesSearchablePagesAndDuplicates() throws {
    let text = try PDFParser.parse(PDFFixtures.textWidthsPages())
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          AddSearchableTextLayerCommand(
            pageID: text.pageIDs[0],
            lines: [SearchableTextLine(text: "x", rect: [10, 10, 50, 30])])
        ]), to: text.graph)
    }

    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let lined = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "first", rect: [10, 10, 50, 30])])
      ]), to: parsed.graph)
    // A duplicate layer refuses without an explicit replace.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          AddSearchableTextLayerCommand(
            pageID: pageID,
            lines: [SearchableTextLine(text: "second", rect: [10, 10, 50, 30])])
        ]), to: lined)
    }
    // Replacing produces exactly one layer stream and one OCR font.
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "second", rect: [10, 10, 50, 30])],
          replacingExistingLayer: true)
      ]), to: lined)
    #expect(OCRLayer.layerStreamIDs(in: replaced, pageID: pageID).count == 1)
    #expect(OCRLayer.layerFontNames(in: replaced, pageID: pageID).count == 1)
    guard let replacedStreamID = OCRLayer.layerStreamIDs(in: replaced, pageID: pageID).first,
      case .stream(let replacedStream)? = replaced.objects[replacedStreamID]
    else {
      Issue.record("Replaced layer stream is missing")
      return
    }
    let replacedContent = String(decoding: replacedStream.bytes, as: UTF8.self)
    #expect(replacedContent.contains("<007300650063006F006E0064>"))  // "second"
    #expect(!replacedContent.contains("<00660069007200730074>"))  // "first"
    #expect(try PDFParser.parse(PDFWriter.write(replaced)).graph == replaced)

    // Beyond-BMP text refuses explicitly.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          AddSearchableTextLayerCommand(
            pageID: pageID,
            lines: [SearchableTextLine(text: "emoji 🙂", rect: [10, 10, 50, 30])],
            replacingExistingLayer: true)
        ]), to: replaced)
    }
  }

  @Test func removeLayerRestoresTheOriginalPage() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let lined = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "temporary", rect: [10, 10, 50, 30])])
      ]), to: parsed.graph)
    let removed = try PDFEditingEngine.commit(
      PDFTransaction([RemoveOCRLayerCommand(pageID: pageID)]), to: lined)
    #expect(!OCRLayer.hasGeneratedLayer(in: removed, pageID: pageID))
    let layout = try PageTextLayout.build(pageID: pageID, in: removed)
    #expect(layout.clusters.isEmpty)
    #expect(try PDFParser.parse(PDFWriter.write(removed)).graph == removed)
    // Removing again refuses.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RemoveOCRLayerCommand(pageID: pageID)]), to: removed)
    }
    // The original content stream and image are untouched.
    guard case .stream(let originalContent)? = parsed.graph.objects[PDFObjectID(5)],
      case .stream(let remainingContent)? = removed.objects[PDFObjectID(5)]
    else {
      Issue.record("Original content stream is missing")
      return
    }
    #expect(originalContent.bytes == remainingContent.bytes)
  }
}
