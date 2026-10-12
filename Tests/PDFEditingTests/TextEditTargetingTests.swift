import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P12-012 text-edit slice: mapping a selection rectangle to the text run the
/// app then replaces through native input.
@Suite("Text edit targeting")
struct TextEditTargetingTests {
  @Test func selectionMapsToItsTextRun() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let first = try TextEditTargeting.run(
      atSelectionBounds: [42, 710, 62, 730], in: parsed.graph, pageID: pageID)
    #expect(first?.runIndex == 0)
    #expect(first?.text == "AB")

    let second = try TextEditTargeting.run(
      atSelectionBounds: [72, 710, 82, 730], in: parsed.graph, pageID: pageID)
    #expect(second?.runIndex == 1)
    #expect(second?.text == "CD")

    // Off-text and malformed selections resolve to nothing.
    #expect(
      try TextEditTargeting.run(
        atSelectionBounds: [500, 500, 520, 520], in: parsed.graph, pageID: pageID) == nil)
    #expect(
      try TextEditTargeting.run(atSelectionBounds: [1, 2, 3], in: parsed.graph, pageID: pageID)
        == nil)
    #expect(
      try TextEditTargeting.run(
        atSelectionBounds: [.nan, 710, 62, 730], in: parsed.graph, pageID: pageID) == nil)

    // Conservative geometry (standard-14 without /Widths) still resolves the
    // run through the nearest-baseline fallback.
    let three = try PDFParser.parse(PDFFixtures.threePages())
    let conservative = try TextEditTargeting.run(
      atSelectionBounds: [42, 704.48, 243.38, 728.48], in: three.graph,
      pageID: three.pageIDs[0])
    #expect(conservative?.runIndex == 0)
    #expect(conservative?.text == "sPDF Editor fixture - page 1")

    // The target feeds the existing replacement command.
    let target = try #require(first)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: target.runIndex, replacement: "Edited")
      ]), to: parsed.graph)
    let content = try PageContent.load(pageID: pageID, in: edited)
    let text = String(decoding: content.bytes, as: UTF8.self)
    // Rebuilt TJ arrays serialize strings as hex: "Edited" = 456469746564.
    #expect(text.contains("<456469746564>"))
    #expect(!text.contains("<4142>"))
    #expect(text.contains("<4344>"))
  }

  @Test func pointTargetingProvidesRunGeometry() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let target = try TextEditTargeting.runTarget(
      atPoint: [47, 720], in: parsed.graph, pageID: pageID)
    #expect(target?.runIndex == 0)
    #expect(target?.text == "AB")
    #expect(target?.rect == [42, 710, 62, 730])
    #expect(
      try TextEditTargeting.runTarget(atPoint: [500, 500], in: parsed.graph, pageID: pageID)
        == nil)

    // Conservative metrics still resolve near the run and refuse far away.
    let three = try PDFParser.parse(PDFFixtures.threePages())
    let conservative = try TextEditTargeting.runTarget(
      atPoint: [100, 718], in: three.graph, pageID: three.pageIDs[0])
    #expect(conservative?.runIndex == 0)
    #expect(conservative?.text == "sPDF Editor fixture - page 1")
    #expect(conservative?.rect == [42, 710, 42, 734])
    #expect(
      try TextEditTargeting.runTarget(
        atPoint: [500, 718], in: three.graph, pageID: three.pageIDs[0]) == nil)
  }

  @Test func targetsCarryTheRunInputStyle() throws {
    // Helvetica 20 pt, default black fill: the style matches the run.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let target = try #require(
      try TextEditTargeting.runTarget(atPoint: [47, 720], in: parsed.graph, pageID: pageID))
    #expect(target.style.fontFamily == "Helvetica")
    #expect(target.style.fontSize == 20)
    #expect(target.style.fillColor == [0, 0, 0])
    // The selection-bounds path carries the same style.
    let selected = try #require(
      try TextEditTargeting.run(
        atSelectionBounds: [42, 710, 62, 730], in: parsed.graph, pageID: pageID))
    #expect(selected.style == target.style)

    // An explicit RGB fill resolves to the same components.
    let red = try #require(
      try TextEditTargeting.runTarget(
        atPoint: [50, 720], in: redGraph(), pageID: redPageID()))
    #expect(red.style.fontFamily == "Helvetica")
    #expect(red.style.fontSize == 20)
    #expect(red.style.fillColor == [1, 0, 0])
  }

  @Test func selectionIdentityPreservesOrInvalidatesAcrossEdits() throws {
    // P17-016/P17-017: the identity of a selected run survives an edit
    // through that run (with the new text) and reports obsolescence with a
    // reason when the page or run disappears.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let target = try #require(
      try TextEditTargeting.runTarget(atPoint: [47, 720], in: parsed.graph, pageID: pageID))
    let identity = SelectionIdentity(pageID: pageID, runIndex: target.runIndex, text: target.text)
    guard case .preserved(let originalText, let originalRect) = identity.resolve(in: parsed.graph)
    else {
      Issue.record("identity did not resolve before the edit")
      return
    }
    #expect(originalText == "AB")
    #expect(originalRect == target.rect)

    // An edit through the run preserves the identity with the new text.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: target.runIndex, replacement: "Longer")
      ]), to: parsed.graph)
    guard case .preserved(let newText, let newRect) = identity.resolve(in: edited) else {
      Issue.record("identity did not survive the edit")
      return
    }
    #expect(newText == "Longer")
    #expect(newRect != nil)

    // A stale run index is obsolete with a reason.
    let stale = SelectionIdentity(pageID: pageID, runIndex: 99, text: "x")
    guard case .obsolete(let reason) = stale.resolve(in: edited) else {
      Issue.record("stale run index was not obsolete")
      return
    }
    #expect(reason.contains("run"))
    // A page removed from the tree is obsolete even though its object may
    // still exist (retention policy). A separate multi-page fixture so the
    // delete itself is legal.
    let three = try PDFParser.parse(PDFFixtures.threePages())
    let doomedPage = three.pageIDs[0]
    let doomedIdentity = SelectionIdentity(pageID: doomedPage, runIndex: 0, text: "sPDF")
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [doomedPage])]), to: three.graph)
    guard case .obsolete(let pageReason) = doomedIdentity.resolve(in: deleted) else {
      Issue.record("deleted page identity was not obsolete")
      return
    }
    #expect(pageReason.contains("page"))
  }

  private func redGraph() throws -> PDFGraph {
    let content = "1 0 0 rg BT /F1 20 Tf 42 710 Td (Red) Tj ET\n"
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(4))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func redPageID() -> PDFObjectID { PDFObjectID(3) }
}
