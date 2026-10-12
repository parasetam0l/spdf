import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P17-021: compound page import — selected pages from another document land
/// in the open one as a single transaction, with collision-free resource
/// remapping, correct ordering, refusal for unsupported inputs, and exact
/// undo.
@Suite("Page import")
struct ImportPagesTests {
  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name)")
    return try Data(contentsOf: url)
  }

  private func pageText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
  }

  @Test func importInsertsRemappedPagesAtTheRequestedIndex() throws {
    // Destination: three pages of "sPDF Editor fixture - page N"; import:
    // one page of "ABCD" (its own font resource also named F1).
    let destination = try PDFParser.parse(PDFFixtures.threePages())
    let importedBytes = try PDFFixtures.textWidthsPages()
    let command = ImportPagesCommand(documentBytes: importedBytes, pageIndices: [0], atIndex: 1)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: destination.graph)

    let pages = try PDFPageTree.pageIDs(in: edited)
    #expect(pages.count == 4)
    #expect(try pageText(edited, pages[0]).contains("page 1"))
    #expect(try pageText(edited, pages[1]) == "ABCD")
    #expect(try pageText(edited, pages[2]).contains("page 2"))
    #expect(try pageText(edited, pages[3]).contains("page 3"))
    // No identity collisions: every page keeps its own resources (the
    // imported page's /F1 and the destination's /F1 are distinct objects).
    guard case .dictionary(let page)? = edited.objects[pages[1]],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let importedFont)? = fonts[PDFName("F1")]
    else {
      Issue.record("imported page resources missing")
      return
    }
    guard case .dictionary(let firstPage)? = edited.objects[pages[0]],
      case .dictionary(let firstResources)? = firstPage[PDFName("Resources")],
      case .dictionary(let firstFonts)? = firstResources[PDFName("Font")],
      case .reference(let destinationFont)? = firstFonts[PDFName("F1")]
    else {
      Issue.record("destination page resources missing")
      return
    }
    #expect(importedFont != destinationFont)
    // The merged graph survives a full write/reparse with the same order.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(try PDFPageTree.pageIDs(in: reparsed.graph).count == 4)
    #expect(try pageText(reparsed.graph, reparsed.pageIDs[1]) == "ABCD")
  }

  @Test func importAppendsAtTheEndAndKeepsMultiplePagesInOrder() throws {
    let destination = try PDFParser.parse(PDFFixtures.onePage())
    let importedBytes = try PDFFixtures.threePages()
    let command = ImportPagesCommand(documentBytes: importedBytes, pageIndices: [2, 0], atIndex: 1)
    let edited = try PDFEditingEngine.commit(PDFTransaction([command]), to: destination.graph)
    let pages = try PDFPageTree.pageIDs(in: edited)
    #expect(pages.count == 3)
    // Imported order follows the selection order (page 3 then page 1).
    #expect(try pageText(edited, pages[1]).contains("page 3"))
    #expect(try pageText(edited, pages[2]).contains("page 1"))
    #expect(try pageText(edited, pages[0]).contains("fixture - page 1"))
  }

  @Test func importRefusesUnsupportedInputs() throws {
    let destination = try PDFParser.parse(PDFFixtures.onePage())
    // Encrypted import bytes.
    let encrypted = try fixture("Encrypted/aes-256-r6.pdf")
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          ImportPagesCommand(documentBytes: encrypted, pageIndices: [0], atIndex: 0)
        ]), to: destination.graph)
    }
    // Signatures refuse too.
    let signed = try fixture("Signed/signed-one-page.pdf")
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          ImportPagesCommand(documentBytes: signed, pageIndices: [0], atIndex: 0)
        ]), to: destination.graph)
    }
    // Bad selections and positions refuse before any mutation.
    let good = try PDFFixtures.textWidthsPages()
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([ImportPagesCommand(documentBytes: good, pageIndices: [], atIndex: 0)]),
        to: destination.graph)
    }
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          ImportPagesCommand(documentBytes: good, pageIndices: [0, 0], atIndex: 0)
        ]), to: destination.graph)
    }
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          ImportPagesCommand(documentBytes: good, pageIndices: [5], atIndex: 0)
        ]), to: destination.graph)
    }
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          ImportPagesCommand(documentBytes: good, pageIndices: [0], atIndex: 9)
        ]), to: destination.graph)
    }
  }

}
