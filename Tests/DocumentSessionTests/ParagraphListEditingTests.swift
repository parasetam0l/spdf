import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import Testing

/// TXT-05: list edits are one document transaction, undoable, and survive a
/// save/reopen and independent list re-detection.
@Suite("Structured list editing")
struct ParagraphListEditingTests {
  private func fixture() -> PDFGraph {
    var content = Data()
    for line in [
      ("- First item", 72.0, 660.0, 12.0),
      ("- Second item", 72.0, 640.0, 12.0),
      ("- Third item", 72.0, 620.0, 12.0),
      ("1. Alpha", 72.0, 560.0, 12.0),
      ("2. Beta", 72.0, 540.0, 12.0),
      ("3. Gamma", 72.0, 520.0, 12.0),
    ] {
      content.append(
        Data("BT /F1 \(line.3) Tf \(line.1) \(line.2) Td (\(line.0)) Tj ET\n".utf8))
    }
    return PDFGraph(
      objects: [
        PDFObjectID(1): .dictionary([
          PDFName("Type"): .name(PDFName("Catalog")),
          PDFName("Pages"): .reference(PDFObjectID(2)),
        ]),
        PDFObjectID(2): .dictionary([
          PDFName("Type"): .name(PDFName("Pages")),
          PDFName("Count"): .integer(1),
          PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
        ]),
        PDFObjectID(3): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
          ]),
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: content)),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func lists(_ graph: PDFGraph, _ pageID: PDFObjectID) throws
    -> [TextListCandidate]
  {
    let candidates = try ParagraphReconstruction.candidates(
      pageID: pageID, in: graph)
    return ParagraphListReconstruction.lists(from: candidates)
  }

  @Test func listEditsUndoSaveAndReopen() throws {
    let original = try PDFWriter.write(fixture())
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let pageID = try #require(session.pageIDs.first)
    let initialGraph = try #require(session.currentGraph)
    let before = try lists(initialGraph, pageID)
    let bullets = try #require(before.first { $0.style.kind == .bullet })

    let commands = try ParagraphListEditing.commands(
      pageID: pageID, list: bullets, itemIndex: 0,
      operation: .switchToNumbered, in: initialGraph)
    try session.apply(PDFTransaction(commands))
    #expect(session.isDirty)
    let numbered = try PDFParser.parse(try session.bytesForSave())
    let numberedLists = try lists(numbered.graph, pageID)
    let numberedBullets = try #require(
      numberedLists.first {
        $0.style.kind == .ordered && $0.items.first?.text == "First item"
      })
    #expect(
      numberedBullets.items.map(\.text) == ["First item", "Second item", "Third item"],
      "\(numberedLists.map { ($0.style.kind.rawValue, $0.items.map(\.text)) })")
    #expect(numberedBullets.style.format == .arabic)

    session.noteSaved()
    let saved = try session.bytesForSave()
    let reopened = try PDFParser.parse(saved)
    let reopenedLists = try lists(reopened.graph, pageID)
    #expect(
      reopenedLists.contains {
        $0.style.kind == .ordered && $0.items.first?.text == "First item"
      },
      "\(reopenedLists.map { ($0.style.kind.rawValue, $0.items.map(\.text)) })")
    #expect(try session.undo())
    #expect(try session.bytesForSave() == original)
  }

  @Test func addAndRemoveItemsAreSingleUndoSteps() throws {
    let original = try PDFWriter.write(fixture())
    let session = DocumentEditSession()
    session.load(try PDFSource(data: original))
    let pageID = try #require(session.pageIDs.first)
    let initialGraph = try #require(session.currentGraph)
    let bullets = try #require(
      try lists(initialGraph, pageID).first { $0.style.kind == .bullet })
    let added = try ParagraphListEditing.commands(
      pageID: pageID, list: bullets, itemIndex: 0,
      operation: .addItemAfter, in: initialGraph)
    try session.apply(PDFTransaction(added))
    let addedGraph = try #require(session.currentGraph)
    let addedLists = try lists(addedGraph, pageID)
    let addedBullets = try #require(
      addedLists.first { $0.style.kind == .bullet && $0.items.count == 4 })
    #expect(addedBullets.items.map(\.text).contains("New item"))
    let addedReopened = try PDFParser.parse(try session.bytesForSave())
    let reopenedAddedLists = try lists(addedReopened.graph, pageID)
    #expect(reopenedAddedLists.contains { $0.items.count == 4 })
    #expect(try session.undo())
    #expect(try session.bytesForSave() == original)

    let restoredGraph = try #require(session.currentGraph)
    let removed = try ParagraphListEditing.commands(
      pageID: pageID, list: bullets, itemIndex: 1,
      operation: .removeItem, in: restoredGraph)
    try session.apply(PDFTransaction(removed))
    let removedGraph = try #require(session.currentGraph)
    let removedText = try PageTextLayout.build(pageID: pageID, in: removedGraph)
      .clusters.map(\.text).joined()
    #expect(!removedText.contains("Second item"))
    #expect(removedText.contains("First item"))
    #expect(removedText.contains("Third item"))
    let removedReopened = try PDFParser.parse(try session.bytesForSave())
    let reopenedRemovedLists = try lists(removedReopened.graph, pageID)
    #expect(reopenedRemovedLists.contains { $0.items.count == 2 })
    #expect(try session.undo())
    #expect(try session.bytesForSave() == original)
  }
}
