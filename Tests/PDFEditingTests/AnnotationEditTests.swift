import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-011/P22-019/P22-020 evidence: annotation move/resize/style editing
/// with preserved appearances, orphan-aware deletion, and reply preflight.
@Suite("Annotation editing")
struct AnnotationEditTests {
  @Test func moveTranslatesGeometryAndPreservesAppearances() throws {
    let (graph, pageID) = try markedGraph()
    let before = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let highlightAppearance = try appearanceBytes(of: before[0], in: graph)

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveAnnotationCommand(pageID: pageID, annotationIndex: 0, dx: 10, dy: 20)
      ]), to: graph)
    let after = try AnnotationInventory.annotations(in: moved, pageID: pageID)
    #expect(after[0].rect == [52, 730, 72, 750])
    #expect(after[0].quadPoints?[0] == [52, 750, 62, 750, 52, 730, 62, 730])
    #expect(after[0].quadPoints?[1] == [62, 750, 72, 750, 62, 730, 72, 730])
    // The generated appearance stays byte-identical (P22-019).
    #expect(try appearanceBytes(of: after[0], in: moved) == highlightAppearance)
    // Every other annotation is untouched.
    for index in 1..<before.count {
      #expect(after[index].dictionary == before[index].dictionary)
    }

    // Line endpoints move with their annotation.
    let lineMoved = try PDFEditingEngine.commit(
      PDFTransaction([
        MoveAnnotationCommand(pageID: pageID, annotationIndex: 2, dx: -5, dy: 3)
      ]), to: moved)
    let lineAnnotations = try AnnotationInventory.annotations(in: lineMoved, pageID: pageID)
    #expect(
      lineAnnotations[2].dictionary[PDFName("L")]
        == .array([.real(95), .real(103), .real(195), .real(103)]))
    let lineRect = try #require(lineAnnotations[2].rect)
    #expect(approximatelyEqual(lineRect, [94, 98.8, 196, 107.2]))

    let reparsed = try PDFParser.parse(PDFWriter.write(lineMoved))
    #expect(reparsed.graph == lineMoved)
  }

  @Test func resizeScalesRectAndQuadsProportionally() throws {
    let (graph, pageID) = try markedGraph()
    let before = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let appearance = try appearanceBytes(of: before[0], in: graph)

    let resized = try PDFEditingEngine.commit(
      PDFTransaction([
        ResizeAnnotationCommand(pageID: pageID, annotationIndex: 0, rect: [42, 710, 102, 770])
      ]), to: graph)
    let after = try AnnotationInventory.annotations(in: resized, pageID: pageID)
    #expect(after[0].rect == [42, 710, 102, 770])
    #expect(after[0].quadPoints?[0] == [42, 770, 72, 770, 42, 710, 72, 710])
    #expect(after[0].quadPoints?[1] == [72, 770, 102, 770, 72, 710, 102, 710])
    #expect(try appearanceBytes(of: after[0], in: resized) == appearance)
    #expect(after[1].dictionary == before[1].dictionary)

    let reparsed = try PDFParser.parse(PDFWriter.write(resized))
    #expect(reparsed.graph == resized)

    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    refuse(ResizeAnnotationCommand(pageID: pageID, annotationIndex: 0, rect: [10, 10, 10, 40]))
    refuse(ResizeAnnotationCommand(pageID: pageID, annotationIndex: 99, rect: [10, 10, 40, 40]))
    refuse(MoveAnnotationCommand(pageID: pageID, annotationIndex: 99, dx: 1, dy: 1))
    refuse(MoveAnnotationCommand(pageID: pageID, annotationIndex: 0, dx: .nan, dy: 1))
  }

  @Test func styleEditRegeneratesAppearancesForSupportedTypes() throws {
    let (graph, pageID) = try markedGraph()
    let styled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStyleCommand(
          pageID: pageID, annotationIndex: 0, color: [0, 0, 1], opacity: 0.4)
      ]), to: graph)
    let highlight = try #require(
      try AnnotationInventory.annotations(in: styled, pageID: pageID).first)
    #expect(highlight.dictionary[PDFName("C")] == .array([.real(0), .real(0), .real(1)]))
    #expect(highlight.dictionary[PDFName("CA")] == .real(0.4))
    let highlightContent = try appearanceContent(of: highlight, in: styled)
    #expect(highlightContent.contains("0 0 1 rg"))
    #expect(try appearanceState(of: highlight, in: styled)[PDFName("ca")] == .real(0.4))

    // Line style edits rewrite both stroke and arrowhead color.
    let lineStyled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStyleCommand(pageID: pageID, annotationIndex: 2, color: [0, 1, 0])
      ]), to: graph)
    let line = try #require(
      try AnnotationInventory.annotations(in: lineStyled, pageID: pageID)[safe: 2])
    #expect(line.dictionary[PDFName("IC")] == .array([.real(0), .real(1), .real(0)]))
    let lineContent = try appearanceContent(of: line, in: lineStyled)
    #expect(lineContent.contains("0 1 0 RG"))
    #expect(lineContent.contains("0 1 0 rg"))
    #expect(lineContent.contains("h f"))

    // Shapes keep their fill while the border color changes.
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let shapePageID = parsed.pageIDs[0]
    let shaped = try PDFEditingEngine.commit(
      PDFTransaction([
        AddShapeCommand(
          pageID: shapePageID, kind: .square, rect: [100, 100, 200, 160], borderColor: [0, 0, 1],
          fillColor: [1, 1, 0], borderWidth: 2)
      ]), to: parsed.graph)
    let shapeStyled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStyleCommand(pageID: shapePageID, annotationIndex: 0, color: [0, 0.5, 0])
      ]), to: shaped)
    let square = try #require(
      try AnnotationInventory.annotations(in: shapeStyled, pageID: shapePageID).first)
    let squareContent = try appearanceContent(of: square, in: shapeStyled)
    #expect(squareContent.contains("0 0.5 0 RG"))
    #expect(squareContent.contains("1 1 0 rg"))
    #expect(squareContent.contains("2 w"))

    // Ink style edits preserve strokes and rewrite color/opacity.
    let inked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddInkCommand(
          pageID: shapePageID, strokes: [[10, 10, 40, 40, 80, 20]],
          color: [0, 0, 0], borderWidth: 3)
      ]), to: parsed.graph)
    let inkStyled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetAnnotationStyleCommand(
          pageID: shapePageID, annotationIndex: 0, color: [0.8, 0.1, 0.2], opacity: 0.6)
      ]), to: inked)
    let ink = try #require(
      try AnnotationInventory.annotations(in: inkStyled, pageID: shapePageID).first)
    #expect(ink.dictionary[PDFName("C")] == .array([.real(0.8), .real(0.1), .real(0.2)]))
    #expect(ink.dictionary[PDFName("CA")] == .real(0.6))
    let inkContent = try appearanceContent(of: ink, in: inkStyled)
    #expect(inkContent.contains("0.8 0.1 0.2 RG"))
    #expect(inkContent.contains("3 w"))
    let inkReparsed = try PDFParser.parse(PDFWriter.write(inkStyled))
    #expect(inkReparsed.graph == inkStyled)

    let reparsed = try PDFParser.parse(PDFWriter.write(shapeStyled))
    #expect(reparsed.graph == shapeStyled)

    func refuse(_ command: any PDFEditCommand, in graph: PDFGraph) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: graph)
      }
    }
    // Note, free text, and stamp style editing is not supported yet.
    refuse(SetAnnotationStyleCommand(pageID: pageID, annotationIndex: 3, color: [1, 1, 1]), in: graph)
    let freeText = try PDFEditingEngine.commit(
      PDFTransaction([
        AddFreeTextCommand(pageID: shapePageID, rect: [10, 10, 110, 40], text: "x")
      ]), to: parsed.graph)
    refuse(
      SetAnnotationStyleCommand(pageID: shapePageID, annotationIndex: 0, color: [1, 1, 1]),
      in: freeText)
    refuse(
      SetAnnotationStyleCommand(pageID: pageID, annotationIndex: 0, color: nil, opacity: nil),
      in: graph)
    refuse(
      SetAnnotationStyleCommand(pageID: pageID, annotationIndex: 0, opacity: 2), in: graph)
  }

  @Test func deleteRemovesAnnotationAndOrphanObjectsOnly() throws {
    let (graph, pageID) = try markedGraph()
    let before = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let annotationID = try #require(before[0].objectID)
    guard case .dictionary(let appearance)? = before[0].dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")]
    else {
      Issue.record("Highlight has no appearance")
      return
    }
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]), to: graph)
    #expect(deleted.objects[annotationID] == nil)
    #expect(deleted.objects[appearanceID] == nil)
    let after = try AnnotationInventory.annotations(in: deleted, pageID: pageID)
    #expect(
      after.map(\.subtype) == [PDFName("Underline"), PDFName("Line"), PDFName("Text")])
    #expect(after.map(\.index) == [0, 1, 2])
    let reparsed = try PDFParser.parse(PDFWriter.write(deleted))
    #expect(reparsed.graph == deleted)
  }

  @Test func deleteKeepsSharedAppearancesAndRefusesReplies() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    let appearance = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("FormType"): .integer(1),
        PDFName("BBox"): .array([.integer(0), .integer(0), .integer(10), .integer(10)]),
      ], bytes: Data("q Q\n".utf8))
    graph.objects[PDFObjectID(300)] = .stream(appearance)
    graph.objects[PDFObjectID(301)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Highlight")),
      PDFName("Rect"): .array([.integer(10), .integer(10), .integer(20), .integer(20)]),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(300))]),
    ])
    graph.objects[PDFObjectID(302)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Underline")),
      PDFName("Rect"): .array([.integer(30), .integer(30), .integer(40), .integer(40)]),
      PDFName("AP"): .dictionary([PDFName("N"): .reference(PDFObjectID(300))]),
    ])
    func attach(_ items: [PDFValue], to graph: inout PDFGraph) throws {
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "Fixture page is missing")
      }
      page[PDFName("Annots")] = .array(items)
      graph.objects[pageID] = .dictionary(page)
    }
    try attach([.reference(PDFObjectID(301)), .reference(PDFObjectID(302))], to: &graph)

    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]), to: graph)
    #expect(deleted.objects[PDFObjectID(301)] == nil)
    #expect(deleted.objects[PDFObjectID(300)] != nil)  // still shared

    // A reply relationship blocks deletion of its target.
    var replied = graph
    replied.objects[PDFObjectID(303)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Text")),
      PDFName("Rect"): .array([.integer(50), .integer(50), .integer(70), .integer(70)]),
      PDFName("IRT"): .reference(PDFObjectID(301)),
      PDFName("Contents"): .string(Data("reply".utf8)),
    ])
    try attach(
      [.reference(PDFObjectID(301)), .reference(PDFObjectID(302)), .reference(PDFObjectID(303))],
      to: &replied)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]), to: replied)
    }
    // Deleting the reply itself stays allowed.
    let replyDeleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 2)]), to: replied)
    #expect(replyDeleted.objects[PDFObjectID(303)] == nil)
  }

  @Test func deleteHandlesDirectAnnotationEntries() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Fixture page is missing")
    }
    page[PDFName("Annots")] = .array([
      .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Square")),
        PDFName("Rect"): .array([.integer(5), .integer(5), .integer(25), .integer(25)]),
      ])
    ])
    graph.objects[pageID] = .dictionary(page)
    let deleted = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAnnotationCommand(pageID: pageID, annotationIndex: 0)]), to: graph)
    #expect(try AnnotationInventory.annotations(in: deleted, pageID: pageID).isEmpty)
    guard case .dictionary(let deletedPage)? = deleted.objects[pageID] else {
      Issue.record("Page is missing")
      return
    }
    // An emptied direct array is dropped so the page matches its original
    // structure.
    #expect(deletedPage[PDFName("Annots")] == nil)
  }

  private func markedGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let quads: [Double] = [
      42, 730, 52, 730, 42, 710, 52, 710, 52, 730, 62, 730, 52, 710, 62, 710,
    ]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(pageID: pageID, quads: quads, color: [1, 0, 0], opacity: 0.8),
        AddTextMarkupCommand(pageID: pageID, style: .underline, quads: quads, color: [0, 0, 1]),
        AddLineCommand(
          pageID: pageID, from: [100, 100], to: [200, 100], endEnding: .closedArrow,
          color: [0, 0, 0], borderWidth: 2),
        AddNoteCommand(pageID: pageID, at: [300, 400], contents: "note"),
      ]), to: parsed.graph)
    return (graph, pageID)
  }

  private func appearanceBytes(of annotation: Annotation, in graph: PDFGraph) throws -> Data {
    guard case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream(let stream)? = graph.objects[appearanceID]
    else {
      throw PDFError(.malformed, "Annotation has no appearance stream")
    }
    return stream.bytes
  }

  private func appearanceContent(of annotation: Annotation, in graph: PDFGraph) throws -> String {
    String(decoding: try appearanceBytes(of: annotation, in: graph), as: UTF8.self)
  }

  private func appearanceState(of annotation: Annotation, in graph: PDFGraph) throws
    -> [PDFName: PDFValue]
  {
    guard case .dictionary(let appearance)? = annotation.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream(let stream)? = graph.objects[appearanceID],
      case .dictionary(let resources)? = stream.dictionary[PDFName("Resources")],
      case .dictionary(let states)? = resources[PDFName("ExtGState")],
      case .dictionary(let state)? = states[PDFName("GS0")]
    else {
      throw PDFError(.malformed, "Annotation has no graphics state")
    }
    return state
  }

  private func approximatelyEqual(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 1e-9)
    -> Bool
  {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < tolerance }
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
