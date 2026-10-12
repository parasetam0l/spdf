import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P17-005: content streams shared between pages are copied before an edit,
/// so writing one page never changes another; unshared content is untouched.
@Suite("Content copy-on-write")
struct ContentCopyOnWriteTests {
  /// Two pages sharing one content stream object (object 5).
  private func sharedContentGraph() -> PDFGraph {
    let content = "BT /F1 24 Tf 42 710 Td (Shared text) Tj ET\n"
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(2),
          PDFName("Kids"): .array([.reference(PDFObjectID(3)), .reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content.utf8))),
        PDFObjectID(6): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func text(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    String(decoding: try PageContent.load(pageID: pageID, in: graph).bytes, as: UTF8.self)
  }

  @Test func sharedContentIsCopiedBeforeTextEdit() throws {
    let graph = sharedContentGraph()
    let pages = try PDFPageTree.pageIDs(in: graph)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pages[0], runIndex: 0, replacement: "Edited")
      ]), to: graph)
    // The edited page shows the replacement; the other page is untouched.
    #expect(try text(edited, pages[0]).contains("Edited"))
    #expect(try text(edited, pages[1]).contains("Shared text"))
    #expect(!(try text(edited, pages[1]).contains("Edited")))
    // The other page still references the original stream object, byte-equal.
    guard case .dictionary(let otherPage)? = edited.objects[pages[1]],
      case .reference(let originalID)? = otherPage[PDFName("Contents")],
      case .stream(let original)? = edited.objects[originalID],
      case .dictionary(let editedPage)? = edited.objects[pages[0]],
      case .reference(let copyID)? = editedPage[PDFName("Contents")]
    else {
      Issue.record("content references missing")
      return
    }
    #expect(originalID == PDFObjectID(5))
    #expect(copyID != originalID)
    #expect(original.bytes == Data("BT /F1 24 Tf 42 710 Td (Shared text) Tj ET\n".utf8))
    // The copy is a real stream with the edited bytes.
    guard case .stream(let copy)? = edited.objects[copyID] else {
      Issue.record("copy is not a stream")
      return
    }
    #expect(String(decoding: copy.bytes, as: UTF8.self).contains("Edited"))
    // The edit survives a full write/reparse.
    let reparsed = try PDFParser.parse(try PDFWriter.write(edited))
    #expect(try text(reparsed.graph, pages[0]).contains("Edited"))
    #expect(try text(reparsed.graph, pages[1]).contains("Shared text"))
  }

  @Test func unsharedContentIsNotRewritten() throws {
    // A page whose content is private keeps the same object identity: the
    // copy-on-write rule never churns the graph for the common case.
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = parsed.pageIDs[0]
    let before = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]), to: parsed.graph)
    guard case .dictionary(let page)? = before.objects[pageID],
      case .reference(let contentID)? = page[PDFName("Contents")]
    else {
      Issue.record("content reference missing")
      return
    }
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: "Edited")
      ]), to: before)
    guard case .dictionary(let editedPage)? = edited.objects[pageID],
      case .reference(let editedContentID)? = editedPage[PDFName("Contents")]
    else {
      Issue.record("edited content reference missing")
      return
    }
    #expect(editedContentID == contentID)
    #expect(edited.objects.count == before.objects.count)
  }

  @Test func redactionCopiesSharedContentBeforeRemoving() throws {
    let graph = sharedContentGraph()
    let pages = try PDFPageTree.pageIDs(in: graph)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pages[0], regions: [[40, 705, 260, 735]])
      ]), to: graph)
    // The redacted page lost the text; the other page keeps it in full.
    #expect(!(try text(edited, pages[0]).contains("Shared text")))
    #expect(try text(edited, pages[1]).contains("Shared text"))
  }
}
