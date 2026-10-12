import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-003/P22-004/P22-006/P22-007 evidence: underline/strikeout markup,
/// sticky notes, square/circle shapes, and line/arrow annotations on the
/// shared appearance foundation.
@Suite("Markup annotations")
struct MarkupAnnotationTests {
  @Test func underlineAndStrikeoutStrokeBaselineAndMiddleLines() throws {
    let (graph, pageID, quads, _) = try textFixture()
    let underlined = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextMarkupCommand(
          pageID: pageID, style: .underline, quads: quads, color: [1, 0, 0], opacity: 0.8,
          contents: "underline")
      ]), to: graph)
    let annotations = try AnnotationInventory.annotations(in: underlined, pageID: pageID)
    #expect(annotations.count == 1)
    #expect(annotations[0].subtype == PDFName("Underline"))
    #expect(annotations[0].contents == "underline")
    #expect(
      annotations[0].quadPoints == [
        [42, 730, 52, 730, 42, 710, 52, 710], [52, 730, 62, 730, 52, 710, 62, 710],
      ])
    #expect(annotations[0].rect == [42, 710, 62, 730])
    let content = try appearanceContent(of: annotations[0], in: underlined)
    #expect(content.contains("1 0 0 RG"))
    #expect(content.contains("1.2 w"))
    #expect(content.contains("0 0.6 m"))
    #expect(content.contains("10 0.6 l"))
    #expect(content.contains("10 0.6 m"))
    #expect(content.contains("20 0.6 l"))

    let struck = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextMarkupCommand(
          pageID: pageID, style: .strikeout, quads: quads, color: [0, 0, 1], opacity: 1)
      ]), to: graph)
    let strikeAnnotations = try AnnotationInventory.annotations(in: struck, pageID: pageID)
    #expect(strikeAnnotations[0].subtype == PDFName("StrikeOut"))
    let strikeContent = try appearanceContent(of: strikeAnnotations[0], in: struck)
    #expect(strikeContent.contains("0 0 1 RG"))
    #expect(strikeContent.contains("0 10 m"))
    #expect(strikeContent.contains("20 10 l"))

    // Full-write round trip keeps the graph identical.
    let written = try PDFParser.parse(PDFWriter.write(struck))
    #expect(written.graph == struck)
  }

  @Test func noteGeneratesIconAppearanceAndLogicalFields() throws {
    let (graph, pageID, _, _) = try textFixture()
    let noted = try PDFEditingEngine.commit(
      PDFTransaction([
        AddNoteCommand(
          pageID: pageID, at: [300, 400], contents: "Please review", author: "Ada",
          modified: "D:20261010120000Z", color: [1, 0.84, 0])
      ]), to: graph)
    let annotation = try #require(
      try AnnotationInventory.annotations(in: noted, pageID: pageID).first)
    #expect(annotation.subtype == PDFName("Text"))
    #expect(annotation.rect == [300, 400, 320, 420])
    #expect(annotation.contents == "Please review")
    #expect(annotation.author == "Ada")
    #expect(annotation.modified == "D:20261010120000Z")
    #expect(annotation.iconName == PDFName("Comment"))
    #expect(annotation.dictionary[PDFName("Open")] == .boolean(false))
    let content = try appearanceContent(of: annotation, in: noted)
    #expect(content.contains("1 0.84 0 rg"))
    #expect(content.contains("0 0 20 20 re f"))
    #expect(content.contains("0.5 0.5 19 19 re S"))
    #expect(content.contains("h f"))
  }

  @Test func shapesWriteBorderInteriorAndAppearancePaths() throws {
    let (graph, pageID, _, _) = try textFixture()
    let squared = try PDFEditingEngine.commit(
      PDFTransaction([
        AddShapeCommand(
          pageID: pageID, kind: .square, rect: [100, 100, 200, 160], borderColor: [0, 0, 1],
          fillColor: [1, 1, 0], borderWidth: 2, contents: "box")
      ]), to: graph)
    let square = try #require(
      try AnnotationInventory.annotations(in: squared, pageID: pageID).first)
    #expect(square.subtype == PDFName("Square"))
    #expect(square.rect == [100, 100, 200, 160])
    #expect(square.dictionary[PDFName("IC")] == .array([.real(1), .real(1), .real(0)]))
    #expect(
      square.dictionary[PDFName("BS")]
        == .dictionary([PDFName("Type"): .name(PDFName("Border")), PDFName("W"): .real(2)]))
    #expect(
      square.dictionary[PDFName("Border")] == .array([.integer(0), .integer(0), .real(2)]))
    let squareContent = try appearanceContent(of: square, in: squared)
    #expect(squareContent.contains("1 1 0 rg"))
    #expect(squareContent.contains("0 0 1 RG"))
    #expect(squareContent.contains("2 w"))
    #expect(squareContent.contains("1 1 98 58 re"))
    #expect(squareContent.contains("B"))

    let circled = try PDFEditingEngine.commit(
      PDFTransaction([
        AddShapeCommand(
          pageID: pageID, kind: .circle, rect: [100, 100, 200, 160], borderColor: [0, 0, 0],
          borderWidth: 1)
      ]), to: graph)
    let circle = try #require(
      try AnnotationInventory.annotations(in: circled, pageID: pageID).first)
    #expect(circle.subtype == PDFName("Circle"))
    #expect(circle.dictionary[PDFName("IC")] == nil)
    let circleContent = try appearanceContent(of: circle, in: circled)
    #expect(circleContent.contains(" c\n"))
    #expect(circleContent.contains("S"))
    #expect(!circleContent.contains(" re"))
  }

  @Test func lineWritesEndingsAndArrowheadGeometry() throws {
    let (graph, pageID, _, _) = try textFixture()
    let lined = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLineCommand(
          pageID: pageID, from: [100, 100], to: [200, 100], endEnding: .closedArrow,
          color: [1, 0, 0], borderWidth: 2, contents: "arrow")
      ]), to: graph)
    let line = try #require(try AnnotationInventory.annotations(in: lined, pageID: pageID).first)
    #expect(line.subtype == PDFName("Line"))
    #expect(
      line.dictionary[PDFName("L")] == .array([.real(100), .real(100), .real(200), .real(100)]))
    #expect(
      line.dictionary[PDFName("LE")]
        == .array([.name(PDFName("None")), .name(PDFName("ClosedArrow"))]))
    #expect(line.dictionary[PDFName("IC")] == .array([.real(1), .real(0), .real(0)]))
    let rect = try #require(line.rect)
    #expect(abs(rect[0] - 99) < 1e-9 && abs(rect[1] - 95.8) < 1e-9)
    #expect(abs(rect[2] - 201) < 1e-9 && abs(rect[3] - 104.2) < 1e-9)
    let content = try appearanceContent(of: line, in: lined)
    #expect(content.contains("1 0 0 RG"))
    #expect(content.contains("2 w"))
    #expect(content.contains("1 4.2 m"))
    #expect(content.contains("101 4.2 l"))
    #expect(content.contains("93 7.4 l"))
    #expect(content.contains("93 1 l"))
    #expect(content.contains("h f"))

    // Reversing the direction puts the arrowhead at the start.
    let reversed = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLineCommand(
          pageID: pageID, from: [200, 100], to: [100, 100], startEnding: .closedArrow,
          endEnding: .none)
      ]), to: graph)
    let reversedLine = try #require(
      try AnnotationInventory.annotations(in: reversed, pageID: pageID).first)
    #expect(
      reversedLine.dictionary[PDFName("LE")]
        == .array([.name(PDFName("ClosedArrow")), .name(PDFName("None"))]))
    let reversedContent = try appearanceContent(of: reversedLine, in: reversed)
    #expect(reversedContent.contains("h f"))
  }

  @Test func markupCommandsRefuseInvalidInput() throws {
    let (graph, pageID, quads, _) = try textFixture()
    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    refuse(AddTextMarkupCommand(pageID: pageID, style: .underline, quads: []))
    refuse(AddTextMarkupCommand(pageID: pageID, style: .underline, quads: quads, color: [1, 0]))
    refuse(AddTextMarkupCommand(pageID: pageID, style: .underline, quads: quads, opacity: 2))
    refuse(AddTextMarkupCommand(pageID: PDFObjectID(9_999), style: .underline, quads: quads))
    refuse(AddNoteCommand(pageID: pageID, at: [0, 0], contents: "   "))
    refuse(AddNoteCommand(pageID: pageID, at: [0, 0], contents: "x", size: 200))
    refuse(AddNoteCommand(pageID: pageID, at: [0, 0, 1], contents: "x"))
    refuse(AddShapeCommand(pageID: pageID, kind: .square, rect: [10, 10, 10, 40]))
    refuse(AddShapeCommand(pageID: pageID, kind: .circle, rect: [10, 10, 40, 40], borderWidth: 0))
    refuse(AddLineCommand(pageID: pageID, from: [10, 10], to: [10, 10]))
    refuse(
      AddLineCommand(pageID: pageID, from: [10, 10], to: [20, 10], endEnding: .none, borderWidth: 0)
    )
  }

  /// Existing annotations keep their raw dictionaries and object identities
  /// when new markup is appended (P22-023).
  @Test func newMarkupPreservesExistingAnnotations() throws {
    let (graph, pageID, quads, _) = try textFixture()
    let noted = try PDFEditingEngine.commit(
      PDFTransaction([AddNoteCommand(pageID: pageID, at: [10, 10], contents: "existing")]),
      to: graph)
    let before = try AnnotationInventory.annotations(in: noted, pageID: pageID)

    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextMarkupCommand(pageID: pageID, style: .underline, quads: quads),
        AddShapeCommand(pageID: pageID, kind: .square, rect: [200, 200, 260, 240]),
        AddLineCommand(pageID: pageID, from: [300, 300], to: [400, 340]),
      ]), to: noted)
    let after = try AnnotationInventory.annotations(in: marked, pageID: pageID)
    #expect(after.count == before.count + 3)
    #expect(after[0] == before[0])
    #expect(after.map(\.subtype) == [
      PDFName("Text"), PDFName("Underline"), PDFName("Square"), PDFName("Line"),
    ])
  }

  private func textFixture() throws
    -> (graph: PDFGraph, pageID: PDFObjectID, quads: [Double], rect: [Double])
  {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let word = try #require(layout.words.first)
    let bounds = layout.clusters[word].map(\.bounds)
    return (
      parsed.graph, pageID, AddHighlightCommand.quads(forClusterBounds: bounds), [42, 710, 62, 730]
    )
  }

  private func appearanceContent(of annotation: Annotation, in graph: PDFGraph) throws -> String {
    guard case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream(let stream)? = graph.objects[appearanceID]
    else {
      throw PDFError(.malformed, "Annotation has no appearance stream")
    }
    return String(decoding: stream.bytes, as: UTF8.self)
  }
}
