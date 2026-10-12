import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-001/P22-002/P22-023 evidence: annotation modeling with preserved
/// unknown properties, highlight creation from text quads with a generated
/// appearance, and survival of unsupported annotation types through unrelated
/// edits and saves.
@Suite("Annotations")
struct AnnotationTests {
  @Test func inventoryPreservesUnknownPropertiesAndDirectEntries() throws {
    let (graph, pageID) = try annotatedGraph()
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    #expect(annotations.count == 3)  // the /null entry is skipped

    #expect(annotations[0].objectID == PDFObjectID(100))
    #expect(annotations[0].index == 0)
    #expect(annotations[0].subtype == PDFName("Highlight"))
    #expect(annotations[0].rect == [10, 20, 60, 34])
    #expect(annotations[0].contents == "existing note")
    #expect(annotations[0].author == "Ada")
    #expect(annotations[0].name == "note-1")
    #expect(annotations[0].color == [1, 0.8, 0])
    #expect(annotations[0].opacity == nil)
    #expect(annotations[0].quadPoints?.count == 1)
    #expect(annotations[0].quadPoints?[0] == [10, 34, 60, 34, 10, 20, 60, 20])
    #expect(annotations[0].bounds == [10, 20, 60, 34])
    #expect(
      annotations[0].dictionary[PDFName("MyVendor")]
        == .array([.integer(7), .string(Data("keep".utf8))]))

    #expect(annotations[1].objectID == nil)
    #expect(annotations[1].subtype == PDFName("Square"))
    #expect(annotations[1].bounds == [5, 5, 15, 15])

    #expect(annotations[2].objectID == PDFObjectID(101))
    #expect(annotations[2].subtype == PDFName("Movie"))
    #expect(annotations[2].bounds == [0, 0, 100, 100])
    #expect(annotations[2].dictionary[PDFName("VendorFlag")] == .boolean(true))
    #expect(
      annotations[2].dictionary[PDFName("Movie")]
        == .dictionary([PDFName("F"): .string(Data("clip.mov".utf8))]))
  }

  @Test func highlightUsesTextQuadsAndGeneratedAppearance() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let layout = try PageTextLayout.build(pageID: pageID, in: parsed.graph)
    let word = try #require(layout.words.first)
    let clusterBounds = layout.clusters[word].map(\.bounds)
    #expect(clusterBounds == [[42, 710, 52, 730], [52, 710, 62, 730]])
    let quads = AddHighlightCommand.quads(forClusterBounds: clusterBounds)
    #expect(quads.count == clusterBounds.count * 8)
    #expect(
      quads == [
        42, 730, 52, 730, 42, 710, 52, 710,
        52, 730, 62, 730, 52, 710, 62, 710,
      ])

    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: quads, color: [1, 0.84, 0], opacity: 0.5,
          contents: "Reviewed", author: "Ada", modified: "D:20261010120000Z")
      ]), to: parsed.graph)

    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    #expect(annotations.count == 1)
    let highlight = annotations[0]
    #expect(highlight.subtype == PDFName("Highlight"))
    #expect(highlight.quadPoints?.count == clusterBounds.count)
    #expect(highlight.contents == "Reviewed")
    #expect(highlight.author == "Ada")
    #expect(highlight.modified == "D:20261010120000Z")
    #expect(highlight.opacity == 0.5)
    #expect(highlight.color == [1, 0.84, 0])
    let expectedRect: [Double] = [42, 710, 62, 730]
    #expect(highlight.rect == expectedRect)
    #expect(highlight.bounds == expectedRect)

    // The generated appearance is a form XObject in annotation-relative
    // coordinates with a Multiply-blended constant-alpha fill.
    guard case .dictionary(let appearanceDictionary)? = highlight.dictionary[PDFName("AP")],
      case .reference(let appearanceID)? = appearanceDictionary[PDFName("N")],
      case .stream(let appearance)? = graph.objects[appearanceID]
    else {
      Issue.record("Highlight has no appearance stream")
      return
    }
    #expect(appearance.dictionary[PDFName("Subtype")] == .name(PDFName("Form")))
    #expect(
      appearance.dictionary[PDFName("BBox")]
        == .array([
          .integer(0), .integer(0), .real(expectedRect[2] - expectedRect[0]),
          .real(expectedRect[3] - expectedRect[1]),
        ]))
    let content = String(decoding: appearance.bytes, as: UTF8.self)
    #expect(content.contains("1 0.84 0 rg"))
    #expect(content.contains("/GS0 gs"))
    #expect(content.contains("0 20 m"))
    #expect(content.contains("10 20 l"))
    #expect(content.contains("h f"))
    guard case .dictionary(let resources)? = appearance.dictionary[PDFName("Resources")],
      case .dictionary(let states)? = resources[PDFName("ExtGState")],
      case .dictionary(let gs0)? = states[PDFName("GS0")]
    else {
      Issue.record("Highlight appearance has no graphics state")
      return
    }
    #expect(gs0[PDFName("BM")] == .name(PDFName("Multiply")))
    #expect(gs0[PDFName("ca")] == .real(0.5))

    // The written output reparses to the identical graph and inventory.
    let written = try PDFWriter.write(graph)
    let reparsed = try PDFParser.parse(written)
    #expect(reparsed.graph == graph)
    #expect(try AnnotationInventory.annotations(in: reparsed.graph, pageID: pageID) == annotations)
  }

  @Test func unrelatedEditsAndNewHighlightsPreserveExistingAnnotations() throws {
    let (graph, pageID) = try annotatedGraph()
    let before = try AnnotationInventory.annotations(in: graph, pageID: pageID)

    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]), to: graph)
    #expect(try AnnotationInventory.annotations(in: rotated, pageID: pageID) == before)

    // Object identities and raw dictionaries survive a full rewrite.
    let reparsed = try PDFParser.parse(PDFWriter.write(rotated))
    #expect(try AnnotationInventory.annotations(in: reparsed.graph, pageID: pageID) == before)

    // Adding a highlight leaves every existing annotation untouched.
    let highlighted = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(pageID: pageID, quads: [10, 34, 60, 34, 10, 20, 60, 20])
      ]), to: rotated)
    let after = try AnnotationInventory.annotations(in: highlighted, pageID: pageID)
    #expect(after.count == before.count + 1)
    for (old, new) in zip(before, after) {
      #expect(old.dictionary == new.dictionary)
      #expect(old.objectID == new.objectID)
      #expect(old.index == new.index)
    }
    #expect(after.last?.subtype == PDFName("Highlight"))
  }

  @Test func highlightValidationRefusesInvalidInput() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = parsed.pageIDs[0]
    func expectRefusal(_ command: AddHighlightCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }
    expectRefusal(AddHighlightCommand(pageID: pageID, quads: []))
    expectRefusal(AddHighlightCommand(pageID: pageID, quads: [0, 0, 1, 1]))
    expectRefusal(AddHighlightCommand(pageID: pageID, quads: [0, 0, 1, .nan, 0, 1, 1, 1]))
    expectRefusal(
      AddHighlightCommand(pageID: pageID, quads: [0, 0, 1, 1, 0, 1, 1, 1], color: [1, 0]))
    expectRefusal(
      AddHighlightCommand(pageID: pageID, quads: [0, 0, 1, 1, 0, 1, 1, 1], opacity: 1.5))
    expectRefusal(AddHighlightCommand(pageID: PDFObjectID(9_999), quads: [0, 0, 1, 1, 0, 1, 1, 1]))
  }

  /// A page with an indirect highlight (with vendor keys), a direct inline
  /// square, a /null placeholder, and an unsupported /Movie annotation.
  private func annotatedGraph() throws -> (graph: PDFGraph, pageID: PDFObjectID) {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    graph.objects[PDFObjectID(100)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Highlight")),
      PDFName("Rect"): .array([.integer(10), .integer(20), .integer(60), .integer(34)]),
      PDFName("QuadPoints"): .array([
        .integer(10), .integer(34), .integer(60), .integer(34), .integer(10), .integer(20),
        .integer(60), .integer(20),
      ]),
      PDFName("C"): .array([.real(1), .real(0.8), .integer(0)]),
      PDFName("Contents"): .string(Data("existing note".utf8)),
      PDFName("T"): .string(Data("Ada".utf8)),
      PDFName("NM"): .string(Data("note-1".utf8)),
      PDFName("MyVendor"): .array([.integer(7), .string(Data("keep".utf8))]),
    ])
    graph.objects[PDFObjectID(101)] = .dictionary([
      PDFName("Type"): .name(PDFName("Annot")),
      PDFName("Subtype"): .name(PDFName("Movie")),
      PDFName("Rect"): .array([.integer(0), .integer(0), .integer(100), .integer(100)]),
      PDFName("Movie"): .dictionary([PDFName("F"): .string(Data("clip.mov".utf8))]),
      PDFName("VendorFlag"): .boolean(true),
    ])
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Fixture page is missing")
    }
    page[PDFName("Annots")] = .array([
      .reference(PDFObjectID(100)),
      .dictionary([
        PDFName("Subtype"): .name(PDFName("Square")),
        PDFName("Rect"): .array([.integer(5), .integer(5), .integer(15), .integer(15)]),
      ]),
      .null,
      .reference(PDFObjectID(101)),
    ])
    graph.objects[pageID] = .dictionary(page)
    return (graph, pageID)
  }
}
