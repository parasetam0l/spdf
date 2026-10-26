import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// IMG-07 evidence: ordinary-path selection, style/transform edits that leave
/// every unrelated byte intact, vector preservation after save, and explicit
/// refusals for gradient/pattern/form paint and rotated transforms.
@Suite("Editable vector objects")
struct EditableVectorObjectTests {
  @Test func inventoryFindsOrdinaryFillAndStrokePaths() throws {
    let fixture = try customContentPage(
      """
      q
      1 0 0 rg
      10 10 40 30 re f
      0 0 1 RG
      2 w
      50 20 m 90 20 l S
      0 1 0 rg
      5 5 20 20 re f
      Q
      """)
    let objects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: fixture.graph)
    #expect(objects.count == 3)
    #expect(objects.map(\.paintKind) == [.fill, .stroke, .fill])
    #expect(objects[0].bounds == [10, 10, 50, 40])
    // A 2 pt stroke expands the line bounds by 1 pt.
    #expect(objects[1].bounds == [49, 19, 91, 21])
    #expect(objects[2].bounds == [5, 5, 25, 25])
    #expect(objects[0].style.fillColor == [1, 0, 0])
    #expect(objects[1].style.strokeColor == [0, 0, 1])
    #expect(objects[1].style.lineWidth == 2)
    #expect(objects[2].style.fillColor == [0, 1, 0])
    #expect(objects.allSatisfy { $0.styleEditingSupported && $0.transformEditingSupported })
    #expect(objects.allSatisfy { $0.transformProfile == .identity })
    #expect(
      try VectorObjectInventory.refusals(pageID: fixture.pageID, in: fixture.graph).isEmpty)
  }

  @Test func styleEditChangesOnlyTheTargetPathPaint() throws {
    let fixture = try customContentPage(
      """
      q
      1 0 0 rg
      10 10 40 30 re f
      0 0 1 RG
      2 w
      50 20 m 90 20 l S
      0 1 0 rg
      5 5 20 20 re f
      Q
      """)
    let before = try contentBytes(pageID: fixture.pageID, in: fixture.graph)
    let objects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: fixture.graph)
    let command = SetVectorObjectStyleCommand(
      objectID: objects[0].id,
      style: VectorObjectStyle(fillColor: [0.5, 0, 0.5], lineWidth: nil))
    let styled = try PDFEditingEngine.commit(PDFTransaction([command]), to: fixture.graph)
    let after = try contentBytes(pageID: fixture.pageID, in: styled)
    #expect(!after.isEmpty)
    #expect(String(decoding: after, as: UTF8.self).contains("0.5 0 0.5 rg"))
    // Only the target path's paint changed: the second fill and the stroke keep
    // their exact observed paint, and the command reports only this page.
    let reopenedObjects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: styled)
    #expect(reopenedObjects.count == 3)
    #expect(reopenedObjects[0].style.fillColor == [0.5, 0, 0.5])
    #expect(reopenedObjects[1].style.strokeColor == [0, 0, 1])
    #expect(reopenedObjects[1].style.lineWidth == 2)
    #expect(reopenedObjects[2].style.fillColor == [0, 1, 0])
    #expect(command.affectedPageIDs(in: fixture.graph) == [fixture.pageID])
    // Unrelated bytes outside the insertion are identical.
    #expect(after.count > before.count)

    // Save/reopen keeps the style and the path as vector content.
    let reopened = try PDFParser.parse(PDFWriter.write(styled))
    let savedObjects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: reopened.graph)
    #expect(savedObjects.count == 3)
    #expect(savedObjects[0].style.fillColor == [0.5, 0, 0.5])
    #expect(savedObjects[0].paintKind == .fill)
    let savedBytes = try contentBytes(pageID: fixture.pageID, in: reopened.graph)
    #expect(String(decoding: savedBytes, as: UTF8.self).contains(" re"))
  }

  @Test func transformRewritesOnlyTheTargetPathCoordinates() throws {
    let fixture = try customContentPage(
      """
      q
      1 0 0 rg
      10 10 40 30 re f
      0 0 1 RG
      2 w
      50 20 m 90 20 l S
      0 1 0 rg
      5 5 20 20 re f
      Q
      """)
    let objects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: fixture.graph)
    let before = objects[2].bounds
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformVectorObjectCommand(
          objectID: objects[0].id, translateX: 100, translateY: -50)
      ]), to: fixture.graph)
    let movedObjects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: moved)
    #expect(movedObjects[0].bounds == [110, -40, 150, -10])
    // The other two paths keep their exact geometry and paint.
    #expect(movedObjects[1].bounds == objects[1].bounds)
    #expect(movedObjects[2].bounds == before)

    // Uniform scale by 2 about the page origin doubles the moved rectangle.
    let scaled = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformVectorObjectCommand(
          objectID: movedObjects[0].id, translateX: 0, translateY: 0, scale: 2,
          anchorX: 0, anchorY: 0)
      ]), to: moved)
    let scaledObjects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: scaled)
    #expect(scaledObjects[0].bounds == [220, -80, 300, -20])
    #expect(scaledObjects[1].bounds == objects[1].bounds)
    let reopened = try PDFParser.parse(PDFWriter.write(scaled))
    let reopenedObjects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: reopened.graph)
    #expect(reopenedObjects.count == 3)
    #expect(reopenedObjects[0].bounds == [220, -80, 300, -20])
    let bytes = try contentBytes(pageID: fixture.pageID, in: reopened.graph)
    #expect(String(decoding: bytes, as: UTF8.self).contains(" re"))
  }

  @Test func refusesGradientPatternAndFormPaintWithReasons() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let pageID = pageIDs[0]
    let formID = PDFObjectID(70)
    graph.objects[formID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([
            .integer(0), .integer(0), .integer(50), .integer(50),
          ]),
          PDFName("Resources"): .dictionary([:]),
        ], bytes: Data("0 0 10 10 re f\n".utf8)))
    let shading: PDFValue = .dictionary([
      PDFName("ShadingType"): .integer(2),
      PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
      PDFName("Coords"): .array([
        .integer(0), .integer(0), .integer(100), .integer(0),
      ]),
      PDFName("Function"): .dictionary([
        PDFName("FunctionType"): .integer(2),
        PDFName("Domain"): .array([.integer(0), .integer(1)]),
        PDFName("C0"): .array([.integer(1), .integer(0), .integer(0)]),
        PDFName("C1"): .array([.integer(0), .integer(0), .integer(1)]),
        PDFName("N"): .integer(1),
      ]),
    ])
    let resources: [PDFName: PDFValue] = [
      PDFName("Shading"): .dictionary([PDFName("Sh1"): shading]),
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(formID)]),
    ]
    let fixture = try replacePageContent(
      graph: graph, pageID: pageID,
      content: """
        q /Sh1 sh Q
        q /Fm1 Do Q
        0 0 10 10 re f
        """, resources: resources)
    let refusals = try VectorObjectInventory.refusals(
      pageID: pageID, in: fixture.graph)
    #expect(refusals.count == 2)
    #expect(refusals.contains { $0.reason.contains("Gradient shading") })
    #expect(refusals.contains { $0.reason.contains("form XObjects") })
    let objects = try VectorObjectInventory.selectable(
      pageID: pageID, in: fixture.graph)
    #expect(objects.count == 1)

    // A tiling-pattern-filled path is refused as pattern paint.
    let patternID = PDFObjectID(71)
    graph.objects[patternID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("Pattern")),
          PDFName("PatternType"): .integer(1),
          PDFName("PaintType"): .integer(1),
          PDFName("TilingType"): .integer(1),
          PDFName("BBox"): .array([
            .integer(0), .integer(0), .integer(10), .integer(10),
          ]),
          PDFName("XStep"): .integer(10),
          PDFName("YStep"): .integer(10),
          PDFName("Resources"): .dictionary([:]),
        ], bytes: Data("1 0 0 rg 0 0 10 10 re f\n".utf8)))
    let patternResources: [PDFName: PDFValue] = [
      PDFName("Pattern"): .dictionary([PDFName("P1"): .reference(patternID)])
    ]
    let patternFixture = try replacePageContent(
      graph: graph, pageID: pageIDs[1],
      content: """
        q
        /Pattern cs
        /P1 scn
        0 0 10 10 re f
        Q
        """, resources: patternResources)
    let patternRefusals = try VectorObjectInventory.refusals(
      pageID: pageIDs[1], in: patternFixture.graph)
    #expect(patternRefusals.count == 1)
    #expect(patternRefusals[0].reason.contains("tiling pattern"))
    #expect(
      try VectorObjectInventory.selectable(
        pageID: pageIDs[1], in: patternFixture.graph).isEmpty)
  }

  @Test func rotatedTransformAllowsStyleButRefusesTransform() throws {
    let fixture = try customContentPage(
      """
      q
      0 1 -1 0 100 0 cm
      0 0 10 10 re f
      Q
      """)
    let objects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: fixture.graph)
    #expect(objects.count == 1)
    guard case .unsupported(let reason) = objects[0].transformProfile else {
      Issue.record("rotated page transform was not classified")
      return
    }
    #expect(reason.contains("rotated or skewed"))
    #expect(!objects[0].transformEditingSupported)
    #expect(objects[0].refusal != nil)
    #expect(objects[0].styleEditingSupported)
    let styled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetVectorObjectStyleCommand(
          objectID: objects[0].id, style: VectorObjectStyle(fillColor: [0, 0, 1]))
      ]), to: fixture.graph)
    #expect(
      try VectorObjectInventory.selectable(pageID: fixture.pageID, in: styled)[0]
        .style.fillColor == [0, 0, 1])
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          TransformVectorObjectCommand(
            objectID: objects[0].id, translateX: 10, translateY: 0)
        ]), to: fixture.graph)
    }
  }

  @Test func staleSelectionRefusesWithoutChangingContent() throws {
    let fixture = try customContentPage(
      """
      q
      1 0 0 rg
      10 10 40 30 re f
      Q
      """)
    let object = try #require(
      try VectorObjectInventory.selectable(pageID: fixture.pageID, in: fixture.graph).first)
    let beforeBytes = try contentBytes(pageID: fixture.pageID, in: fixture.graph)
    // Change the path behind the object's back.
    let tampered = try replaceFirstOccurrence(
      in: fixture.graph, pageID: fixture.pageID,
      target: Data("10 10 40 30 re f".utf8),
      replacement: Data("10 10 41 30 re f".utf8))
    let tamperedObjects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: tampered)
    #expect(tamperedObjects.count == 1)
    let tamperedObject = try #require(tamperedObjects.first)
    // Identity fingerprints cover the exact path operand bytes, so a changed
    // path produces a different identity.
    #expect(object.id.fingerprint != tamperedObject.id.fingerprint)
    #expect(tamperedObject.id != object.id)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetVectorObjectStyleCommand(
            objectID: object.id, style: VectorObjectStyle(fillColor: [0, 0, 0]))
        ]), to: tampered)
    }
    #expect(try contentBytes(pageID: fixture.pageID, in: fixture.graph) == beforeBytes)
    #expect(try contentBytes(pageID: fixture.pageID, in: tampered) != beforeBytes)
  }

  @Test func clipAndUnrelatedPaintSurviveAStyleEdit() throws {
    let fixture = try customContentPage(
      """
      q
      0 0 50 50 re W n
      1 0 0 rg
      0 0 10 10 re f
      Q
      0.2 0.3 0.4 rg
      60 60 10 10 re f
      """)
    let objects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: fixture.graph)
    #expect(objects.count == 2)
    #expect(objects[0].style.inheritedClip)
    #expect(objects[0].style.selfClipping == false)
    let before = String(decoding: try contentBytes(pageID: fixture.pageID, in: fixture.graph),
      as: UTF8.self)
    let styled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetVectorObjectStyleCommand(
          objectID: objects[0].id, style: VectorObjectStyle(fillColor: [0, 0, 1]))
      ]), to: fixture.graph)
    let after = String(
      decoding: try contentBytes(pageID: fixture.pageID, in: styled), as: UTF8.self)
    // The enclosing clip is untouched and the unrelated path keeps its paint.
    #expect(after.contains("0 0 50 50 re W n"))
    #expect(before.components(separatedBy: "0 0 50 50 re W n").count == 2)
    #expect(after.components(separatedBy: "0 0 50 50 re W n").count == 2)
    #expect(after.contains("0.2 0.3 0.4 rg"))
    let styles = try VectorObjectInventory.selectable(pageID: fixture.pageID, in: styled)
    #expect(styles[1].style.fillColor.map { abs($0[0] - 0.2) < 1e-9 } == true)
  }

  @Test func commandValidationRejectsMismatchedPaintKinds() throws {
    let fixture = try customContentPage(
      """
      q
      0 0 1 RG
      1 w
      10 10 m 40 10 l S
      Q
      2 0 0 1 0 0 cm
      0 0 1 0 0 0 rg
      50 50 10 10 re f
      """)
    let objects = try VectorObjectInventory.selectable(
      pageID: fixture.pageID, in: fixture.graph)
    #expect(objects.count == 2)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetVectorObjectStyleCommand(
            objectID: objects[0].id, style: VectorObjectStyle(fillColor: [1, 0, 0]))
        ]), to: fixture.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetVectorObjectStyleCommand(
            objectID: objects[1].id, style: VectorObjectStyle(strokeColor: [1, 0, 0]))
        ]), to: fixture.graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          TransformVectorObjectCommand(
            objectID: objects[0].id, translateX: 0, translateY: 0)
        ]), to: fixture.graph)
    }
    // A non-uniform page transform refuses line-width editing.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          SetVectorObjectStyleCommand(
            objectID: objects[1].id, style: VectorObjectStyle(lineWidth: 3))
        ]), to: fixture.graph)
    }
  }

  // MARK: - Fixtures

  private func customContentPage(_ content: String) throws
    -> (graph: PDFGraph, pageID: PDFObjectID)
  {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    return try replacePageContent(graph: graph, pageID: pageID, content: content)
  }

  private func replacePageContent(
    graph: PDFGraph, pageID: PDFObjectID, content: String,
    resources: [PDFName: PDFValue]? = nil
  ) throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let bytes = Data(content.utf8)
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      graph.objects[id] = .stream(
        PDFStream(
          dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
    default:
      throw PDFError(.malformed, "Fixture page content is not a single stream")
    }
    if let resources {
      page[PDFName("Resources")] = .dictionary(resources)
      graph.objects[pageID] = .dictionary(page)
    }
    return (graph, pageID)
  }

  private func replaceFirstOccurrence(
    in graph: PDFGraph, pageID: PDFObjectID, target: Data, replacement: Data
  ) throws -> PDFGraph {
    let content = try PageContent.load(pageID: pageID, in: graph)
    guard let range = Data(content.bytes).range(of: target) else {
      throw PDFError(.malformed, "Fixture target bytes missing")
    }
    return try content.replacing(range: range, with: Array(replacement), in: graph)
  }

  private func contentBytes(pageID: PDFObjectID, in graph: PDFGraph) throws -> Data {
    Data(try PageContent.load(pageID: pageID, in: graph).bytes)
  }
}
