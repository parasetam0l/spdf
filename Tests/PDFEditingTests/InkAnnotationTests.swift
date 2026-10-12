import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-008 evidence: ink annotations from stroke input with a generated
/// appearance, plus integration with move and delete.
@Suite("Ink annotations")
struct InkAnnotationTests {
  @Test func inkWritesStrokesAppearanceAndPaddedRect() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let strokes: [[Double]] = [
      [100, 100, 120, 140, 160, 150],
      [200, 200, 220, 220],
    ]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddInkCommand(
          pageID: pageID, strokes: strokes, color: [0, 0, 1], borderWidth: 2, contents: "ink")
      ]), to: parsed.graph)
    let annotation = try #require(
      try AnnotationInventory.annotations(in: graph, pageID: pageID).first)
    #expect(annotation.subtype == PDFName("Ink"))
    #expect(annotation.contents == "ink")
    // Union of the points padded by the stroke width.
    #expect(annotation.rect == [98, 98, 222, 222])
    #expect(
      annotation.dictionary[PDFName("InkList")]
        == .array([
          .array([.real(100), .real(100), .real(120), .real(140), .real(160), .real(150)]),
          .array([.real(200), .real(200), .real(220), .real(220)]),
        ]))
    #expect(
      annotation.dictionary[PDFName("BS")]
        == .dictionary([PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(2)]))

    guard case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream(let stream)? = graph.objects[appearanceID]
    else {
      Issue.record("Ink has no appearance")
      return
    }
    let content = String(decoding: stream.bytes, as: UTF8.self)
    #expect(content.contains("0 0 1 RG"))
    #expect(content.contains("2 w"))
    #expect(content.contains("1 J"))
    #expect(content.contains("1 j"))
    #expect(content.contains("2 2 m"))
    #expect(content.contains("22 42 l"))
    #expect(content.contains("62 52 l"))
    #expect(content.contains("102 102 m"))
    #expect(content.contains("122 122 l"))

    let reparsed = try PDFParser.parse(PDFWriter.write(graph))
    #expect(reparsed.graph == graph)
  }

  @Test func inkRefusesInvalidStrokes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }
    refuse(AddInkCommand(pageID: pageID, strokes: []))
    refuse(AddInkCommand(pageID: pageID, strokes: [[100, 100]]))
    refuse(AddInkCommand(pageID: pageID, strokes: [[100, 100, 120]]))
    refuse(AddInkCommand(pageID: pageID, strokes: [[100, 100, .nan, 140]]))
    refuse(AddInkCommand(pageID: pageID, strokes: [[100, 100, 120, 140]], borderWidth: 0))
    refuse(AddInkCommand(pageID: pageID, strokes: [[100, 100, 120, 140]], color: [1, 0]))
    let dense = (0...AddInkCommand.maximumPoints).map { Double($0) }
    refuse(AddInkCommand(pageID: pageID, strokes: [dense]))
  }

  @Test func inkSupportsMoveAndDelete() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddInkCommand(pageID: pageID, strokes: [[100, 100, 200, 100]], borderWidth: 2)
      ]), to: parsed.graph)
    let before = try #require(
      try AnnotationInventory.annotations(in: graph, pageID: pageID).first)
    guard case .dictionary(let ap)? = before.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = ap[PDFName("N")],
      case .stream(let appearance)? = graph.objects[appearanceID]
    else {
      Issue.record("Ink has no appearance")
      return
    }
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveAnnotationCommand(pageID: pageID, annotationIndex: 0, dx: 10, dy: 20)
      ]), to: graph)
    let after = try #require(
      try AnnotationInventory.annotations(in: moved, pageID: pageID).first)
    #expect(after.rect == [108, 118, 212, 122])
    #expect(
      after.dictionary[PDFName("InkList")]
        == .array([.array([.real(110), .real(120), .real(210), .real(120)])]))
    guard case .dictionary(let movedAP)? = after.dictionary[PDFName("AP")],
      case .reference(let movedID)? = movedAP[PDFName("N")],
      case .stream(let movedStream)? = moved.objects[movedID]
    else {
      Issue.record("Moved ink has no appearance")
      return
    }
    #expect(movedStream.bytes == appearance.bytes)

    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]), to: moved)
    #expect(try AnnotationInventory.annotations(in: deleted, pageID: pageID).isEmpty)
    #expect(deleted.objects[appearanceID] == nil)
  }
}
