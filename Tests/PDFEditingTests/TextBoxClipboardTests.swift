import Foundation
import PDFCore
import PDFFixtures
import PDFKit
import Testing

@testable import PDFEditing

/// TXT-10: authored text boxes can be lifted into a clipboard value and
/// inserted on another page as a new editable box, as one Undo-able command.
@Suite("Text box clipboard")
struct TextBoxClipboardTests {
  private func standardBox(
    _ text: String = "Copied box", x: Double = 60, baseline: Double = 700,
    width: Double = 300
  ) -> (lines: [PageTextLine], box: PageTextBox) {
    let format = PageTextFormat(font: .helvetica, size: 14)
    let line = PageTextLine(
      text: text, x: x, baseline: baseline,
      segments: [PageTextSegment(text: text, x: x, format: format, width: 80)],
      endsParagraph: true)
    return ([line], PageTextBox(
      x: x, firstBaseline: baseline, width: width, lineSpacing: 16, wraps: true))
  }

  private func dejavu() throws -> CustomTextFont {
    let program = try #require(Data(base64Encoded: FontFixtureData.subsetProgramBase64))
    return CustomTextFont(program: program, familyName: "DejaVuSans")
  }

  @Test func pasteAcrossPagesKeepsContentAndStyle() throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    let source = pages[0], destination = pages[2]
    let base = standardBox()
    let seeded = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(pageID: source, lines: base.lines, box: base.box)
      ]), to: graph)
    let boxes = try AuthoredPageTextBoxes.read(pageID: source, in: seeded)
    let authored = try #require(boxes.first)
    let clipboard = try TextBoxCopy.clipboard(
      from: authored, pageID: source, in: seeded)
    #expect(clipboard.isCopySafe)
    #expect(clipboard.text == "Copied box")

    let placed = try TextBoxPaste.placed(
      clipboard, on: destination, in: seeded, offsetX: 24, offsetY: -50)
    #expect(abs(placed.box.x - 84) < 0.001)
    #expect(abs(placed.box.firstBaseline - 650) < 0.001)
    #expect(abs(placed.lines[0].x - 84) < 0.001)
    #expect(placed.box.allowsLineX(placed.lines[0].x))

    let command = try TextBoxPaste.command(
      clipboard, on: destination, in: seeded, offsetX: 24, offsetY: -50)
    let pasted = try PDFEditingEngine.commit(PDFTransaction([command]), to: seeded)
    let bytes = try PDFWriter.write(pasted)
    let reopened = try #require(PDFDocument(data: bytes))
    let occurrences = (reopened.string ?? "").components(separatedBy: "Copied box").count - 1
    #expect(occurrences == 2)
    let reparsed = try PDFParser.parse(bytes)
    let destinationBoxes = try AuthoredPageTextBoxes.read(
      pageID: destination, in: reparsed.graph)
    #expect(destinationBoxes.count == 1)
    #expect(destinationBoxes.first?.lines.first?.text == "Copied box")
    // The continued editable profile claims the pasted box.
    let blocks = try PageTextEditing.blocks(pageID: destination, in: reparsed.graph)
    #expect(blocks.contains { $0.text.contains("Copied box") })
    // The insertion is exactly one command, so one Undo removes it entirely.
    #expect(PDFTransaction([command]).commands.count == 1)
  }

  @Test func pasteIsClampedInsideTheDestinationPage() throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    let destination = pages[2]
    let clipboard = TextBoxClipboard(
      lines: standardBox().lines, box: standardBox().box)
    let placed = try TextBoxPaste.placed(
      clipboard, on: destination, in: graph, offsetX: 10_000, offsetY: 10_000)
    guard case .dictionary(let page)? = graph.objects[destination] else {
      Issue.record("missing page")
      return
    }
    let media = DocumentInventoryBox.mediaBox(of: page, in: graph)
    #expect(placed.box.x >= media.minX + TextBoxPaste.margin - 0.001)
    #expect(placed.box.x + placed.box.width <= media.maxX - TextBoxPaste.margin + 0.001)
    #expect((placed.lines.map(\.baseline).max() ?? 0) <= media.maxY - 2 + 0.001)
    #expect((placed.lines.map(\.baseline).min() ?? 0) >= media.minY + 2 - 0.001)

    let lowered = try TextBoxPaste.placed(
      clipboard, on: destination, in: graph, offsetX: -10_000, offsetY: -10_000)
    #expect((lowered.lines.map(\.baseline).min() ?? 0) >= media.minY + 2 - 0.001)
    #expect(lowered.box.x >= media.minX + TextBoxPaste.margin - 0.001)
  }

  @Test func boxesWiderThanTheDestinationAreRefused() throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    let base = standardBox(width: 1_800)
    let clipboard = TextBoxClipboard(lines: base.lines, box: base.box)
    #expect(throws: PDFError.self) {
      _ = try TextBoxPaste.placed(clipboard, on: pages[0], in: graph)
    }
  }

  @Test func originalPDFFontsAreRefusedBeforeCopying() throws {
    let format = PageTextFormat(
      font: .helvetica, size: 14,
      sourceFont: PageTextSourceFont(resource: PDFName("F1"), name: "ArialMT"))
    let line = PageTextLine(
      text: "AB", x: 60, baseline: 700,
      segments: [PageTextSegment(text: "AB", x: 60, format: format, width: 20)],
      endsParagraph: false)
    let box = PageTextBox(x: 60, firstBaseline: 700, width: 200, lineSpacing: 16)
    let authored = AuthoredPageTextBox(box: box, lines: [line], originalText: [:])
    #expect(authored.lines[0].segments[0].format.sourceFont != nil)
    let clipboard = TextBoxClipboard(lines: authored.lines, box: authored.box)
    #expect(clipboard.unsafeFormat?.fontName == "ArialMT")
    // The synthetic page has no F1 font resource or embedded program, so the
    // copy is refused instead of silently restyling the text.
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    #expect(throws: PDFError.self) {
      _ = try TextBoxCopy.clipboard(from: authored, pageID: pages[0], in: graph)
    }
  }

  @Test func selectionResolvesTheSmallestAuthoredBox() throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    let page = pages[0]
    let alpha = standardBox("Alpha", x: 60, baseline: 700)
    let beta = standardBox("Beta", x: 60, baseline: 600)
    let seeded = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(pageID: page, lines: alpha.lines, box: alpha.box),
        AddPageTextLinesCommand(pageID: page, lines: beta.lines, box: beta.box),
      ]), to: graph)
    let boxes = try AuthoredPageTextBoxes.read(pageID: page, in: seeded)
    #expect(boxes.count == 2)
    let betaBox = try #require(boxes.first { $0.lines.first?.text == "Beta" })
    let bounds = TextBoxCopy.bounds(of: betaBox)
    let inside = [bounds[0] + 1, bounds[1] + 1, bounds[2] - 1, bounds[3] - 1]
    let clipboard = try TextBoxCopy.clipboard(
      pageID: page, in: seeded, selectionBounds: inside)
    #expect(clipboard?.text == "Beta")
    let elsewhere = [bounds[0] + 400, bounds[1] + 400, bounds[0] + 460, bounds[1] + 460]
    #expect(try TextBoxCopy.clipboard(
      pageID: page, in: seeded, selectionBounds: elsewhere) == nil)
  }

  @Test func licensedFontProgramTravelsWithThePastedBox() throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pages = try PDFPageTree.pageIDs(in: graph)
    let source = pages[0], destination = pages[2]
    let format = PageTextFormat(
      font: .helvetica, size: 14, customFont: try dejavu())
    let line = PageTextLine(
      text: "ABC", x: 60, baseline: 700,
      segments: [PageTextSegment(text: "ABC", x: 60, format: format, width: 30)],
      endsParagraph: true)
    let box = PageTextBox(x: 60, firstBaseline: 700, width: 200, lineSpacing: 16)
    let seeded = try PDFEditingEngine.commit(
      PDFTransaction([
        AddPageTextLinesCommand(pageID: source, lines: [line], box: box)
      ]), to: graph)
    let authored = try #require(
      try AuthoredPageTextBoxes.read(pageID: source, in: seeded).first)
    let clipboard = try TextBoxCopy.clipboard(
      from: authored, pageID: source, in: seeded)
    #expect(clipboard.isCopySafe)
    let command = try TextBoxPaste.command(clipboard, on: destination, in: seeded)
    let pasted = try PDFEditingEngine.commit(PDFTransaction([command]), to: seeded)
    let bytes = try PDFWriter.write(pasted)
    let reopened = try #require(PDFDocument(data: bytes))
    let occurrences = (reopened.string ?? "").components(separatedBy: "ABC").count - 1
    #expect(occurrences == 2)
    // The licensed program is embedded on the destination page as well.
    guard case .dictionary(let page)? = pasted.objects[destination],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")]
    else {
      Issue.record("destination font resources missing")
      return
    }
    let embeddedTrueType = fonts.values.contains { value in
      guard case .reference(let id) = value,
        case .dictionary(let font)? = pasted.objects[id]
      else { return false }
      return font[PDFName("Subtype")] == .name(PDFName("TrueType"))
    }
    #expect(embeddedTrueType)
  }
}
