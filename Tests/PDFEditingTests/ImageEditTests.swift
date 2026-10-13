import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P20-001/004/007/025 evidence: image placement inventory, moves, and
/// per-instance copy-on-write replacement.
@Suite("Image editing")
struct ImageEditTests {
  @Test func inventorySeparatesInstancesFromTheSharedResource() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let page2 = parsed.pageIDs[1]
    let first = try ImageInventory.placements(in: parsed.graph, pageID: page1)
    let second = try ImageInventory.placements(in: parsed.graph, pageID: page2)
    #expect(first.count == 2)
    #expect(second.count == 1)
    #expect(first.allSatisfy { $0.imageID == PDFObjectID(6) })
    #expect(second[0].imageID == PDFObjectID(6))
    #expect(first[0].resourceName == PDFName("Im1"))
    #expect(first[0].matrix == [120, 0, 0, 120, 80, 600])
    #expect(first[0].bounds == [80, 600, 200, 720])
    #expect(first[0].isDirectlyEditable)
    #expect(second[0].bounds == [60, 300, 160, 400])
  }

  @Test func moveRewritesOnlyTheTranslationOperands() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([MoveImageCommand(pageID: page1, placementIndex: 0, dx: 40, dy: -25)]),
      to: parsed.graph)
    let content = try PageContent.load(pageID: page1, in: graph)
    let text = String(decoding: content.bytes, as: UTF8.self)
    #expect(text.contains("120 0 0 120 120 575"))
    #expect(text.contains("80 400"))  // the second placement is untouched

    let moved = try ImageInventory.placements(in: graph, pageID: page1)
    #expect(moved[0].matrix == [120, 0, 0, 120, 120, 575])
    #expect(moved[0].bounds == [120, 575, 240, 695])
    #expect(moved[1].matrix == [120, 0, 0, 120, 80, 400])

    let editedStreamID = content.segments[0].objectID
    for (id, value) in parsed.graph.objects where id != editedStreamID {
      #expect(graph.objects[id] == value)
    }
    let reopened = try PDFParser.parse(PDFWriter.write(graph))
    let reopenedPlacements = try ImageInventory.placements(in: reopened.graph, pageID: page1)
    #expect(reopenedPlacements[0].matrix == [120, 0, 0, 120, 120, 575])
  }

  @Test func moveRefusesUnsupportedMatrixPatterns() throws {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else {
      Issue.record("Content stream missing")
      return
    }
    let altered = String(decoding: stream.bytes, as: UTF8.self)
      .replacingOccurrences(of: "cm\n/Im1 Do", with: "cm\n0 0 m\n/Im1 Do")
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: stream.dictionary, bytes: Data(altered.utf8)))
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          MoveImageCommand(pageID: parsed.pageIDs[0], placementIndex: 0, dx: 10, dy: 10)
        ]), to: parsed.graph)
    }
  }

  @Test func replacementCopiesTheImageAndKeepsOtherPlacements() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let page2 = parsed.pageIDs[1]
    let magenta = Data([255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 0, 255])
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: page1, placementIndex: 0, width: 2, height: 2, rgb8: magenta)
      ]), to: parsed.graph)

    // The original shared image is byte-identical and page 2 still uses it.
    #expect(graph.objects[PDFObjectID(6)] == parsed.graph.objects[PDFObjectID(6)])
    let page2Placements = try ImageInventory.placements(in: graph, pageID: page2)
    #expect(page2Placements[0].imageID == PDFObjectID(6))

    // Page 1's first instance points at a copy with the new samples under a
    // fresh resource name; the second instance still uses the original.
    let page1Placements = try ImageInventory.placements(in: graph, pageID: page1)
    #expect(page1Placements[0].imageID != PDFObjectID(6))
    #expect(page1Placements[0].resourceName == PDFName("Im1-r1"))
    #expect(page1Placements[1].imageID == PDFObjectID(6))
    #expect(page1Placements[1].resourceName == PDFName("Im1"))
    let editedContent = String(
      decoding: try PageContent.load(pageID: page1, in: graph).bytes, as: UTF8.self)
    #expect(editedContent.contains("/Im1-r1 Do"))
    guard case .stream(let copy)? = graph.objects[page1Placements[0].imageID] else {
      Issue.record("Replacement image missing")
      return
    }
    #expect(copy.dictionary[PDFName("Filter")] == .name(PDFName("FlateDecode")))
    #expect(try PDFFilters.decoded(copy) == magenta)
    #expect(graph.trailer[PDFName("Size")] == .integer(9))
    let reopened = try PDFParser.parse(PDFWriter.write(graph))
    #expect(reopened.graph == graph)
  }

  @Test func replacementCopiesSharedResourceObjects() throws {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    graph.objects[PDFObjectID(10)] = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))])
    ])
    for pageID in [PDFObjectID(3), PDFObjectID(4)] {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      page[PDFName("Resources")] = .reference(PDFObjectID(10))
      graph.objects[pageID] = .dictionary(page)
    }
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let page1 = parsed.pageIDs[0]
    let page2 = parsed.pageIDs[1]
    let magenta = Data([255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 0, 255])
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: page1, placementIndex: 0, width: 2, height: 2, rgb8: magenta)
      ]), to: parsed.graph)

    // The shared resources object is unchanged; the page got a private copy.
    #expect(replaced.objects[PDFObjectID(10)] == parsed.graph.objects[PDFObjectID(10)])
    guard case .dictionary(let page1Dict)? = replaced.objects[page1],
      case .reference(let resourcesID)? = page1Dict[PDFName("Resources")]
    else {
      Issue.record("Page 1 resources were not copied")
      return
    }
    #expect(resourcesID != PDFObjectID(10))
    let page2Placements = try ImageInventory.placements(in: replaced, pageID: page2)
    #expect(page2Placements[0].imageID == PDFObjectID(6))
  }

  @Test func replacementRefusesMasksAndForeignColorSpaces() throws {
    let magenta = Data(repeating: 255, count: 12)

    var masked = try PDFParser.parse(PDFFixtures.imagePages()).graph
    guard case .stream(let image)? = masked.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    var maskedDict = image.dictionary
    maskedDict[PDFName("SMask")] = .dictionary([:])
    masked.objects[PDFObjectID(6)] = .stream(
      PDFStream(dictionary: maskedDict, bytes: image.bytes))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageDataCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2, rgb8: magenta)
        ]), to: masked)
    }

    var gray = try PDFParser.parse(PDFFixtures.imagePages()).graph
    guard case .stream(let image2)? = gray.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    var grayDict = image2.dictionary
    grayDict[PDFName("ColorSpace")] = .name(PDFName("DeviceGray"))
    gray.objects[PDFObjectID(6)] = .stream(PDFStream(dictionary: grayDict, bytes: image2.bytes))
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageDataCommand(
            pageID: PDFObjectID(3), placementIndex: 0, width: 2, height: 2, rgb8: magenta)
        ]), to: gray)
    }
  }

  @Test func hitTestingUsesTheExactInverseMatrix() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    #expect(try ImageInventory.placementIndex(at: [140, 660], in: parsed.graph, pageID: page1) == 0)
    #expect(try ImageInventory.placementIndex(at: [140, 460], in: parsed.graph, pageID: page1) == 1)
    #expect(try ImageInventory.placementIndex(at: [20, 40], in: parsed.graph, pageID: page1) == nil)

    // A rotated placement is hit-tested through its inverse matrix.
    var graph = parsed.graph
    guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else {
      Issue.record("Content stream missing")
      return
    }
    let altered = String(decoding: stream.bytes, as: UTF8.self)
      .replacingOccurrences(of: "120 0 0 120 80 600", with: "0 120 -120 0 200 200")
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(dictionary: stream.dictionary, bytes: Data(altered.utf8)))
    let rotated = try PDFParser.parse(PDFWriter.write(graph))
    #expect(
      try ImageInventory.placementIndex(at: [140, 260], in: rotated.graph, pageID: page1) == 0)
    #expect(
      try ImageInventory.placementIndex(at: [240, 260], in: rotated.graph, pageID: page1) == nil)
  }

  @Test func scaleRewritesOnlyTheScaleOperands() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ScaleImageCommand(pageID: page1, placementIndex: 0, scaleX: 2, scaleY: 0.5)
      ]), to: parsed.graph)
    let placements = try ImageInventory.placements(in: graph, pageID: page1)
    #expect(placements[0].matrix == [240, 0, 0, 60, 80, 600])
    #expect(placements[0].bounds == [80, 600, 320, 660])
    #expect(placements[1].matrix == [120, 0, 0, 120, 80, 400])
    let text = String(decoding: try PageContent.load(pageID: page1, in: graph).bytes, as: UTF8.self)
    #expect(text.contains("240 0 0 60 80 600"))

    // Uniform scaling preserves the aspect ratio.
    let uniform = try PDFEditingEngine.commit(
      PDFTransaction([
        ScaleImageCommand(pageID: page1, placementIndex: 1, uniformScale: 0.5)
      ]), to: parsed.graph)
    let uniformPlacements = try ImageInventory.placements(in: uniform, pageID: page1)
    #expect(uniformPlacements[1].matrix == [60, 0, 0, 60, 80, 400])
    #expect(uniformPlacements[0].matrix == [120, 0, 0, 120, 80, 600])
  }

  @Test func formNestedPlacementsComposeMatricesAndRefuseEdits() throws {
    let graph = try formGraph()
    let pageID = PDFObjectID(3)
    let placements = try ImageInventory.placements(in: graph, pageID: pageID)
    #expect(placements.count == 1)
    #expect(placements[0].matrix == [100, 0, 0, 100, 250, 350])
    #expect(placements[0].bounds == [250, 350, 350, 450])
    #expect(placements[0].depth == 1)
    #expect(placements[0].containerObjectID == PDFObjectID(8))
    #expect(!placements[0].isDirectlyEditable)
    #expect(placements[0].contains(point: [300, 400]))

    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([MoveImageCommand(pageID: pageID, placementIndex: 0, dx: 5, dy: 5)]),
        to: graph)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceImageDataCommand(
            pageID: pageID, placementIndex: 0, width: 2, height: 2,
            rgb8: Data(repeating: 255, count: 12))
        ]), to: graph)
    }
  }

  @Test func cyclicFormsAreDetected() throws {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("q /Fm1 Do Q\n".utf8)))
    graph.objects[PDFObjectID(8)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(100), .integer(100)]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(8))])
          ]),
        ], bytes: Data("/Fm1 Do\n".utf8)))
    guard case .dictionary(var page)? = graph.objects[PDFObjectID(3)] else { return }
    page[PDFName("Resources")] = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(8))])
    ])
    graph.objects[PDFObjectID(3)] = .dictionary(page)
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    do {
      _ = try ImageInventory.placements(in: parsed.graph, pageID: PDFObjectID(3))
      Issue.record("Cyclic form reference was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }
  }

  @Test func formNestingDepthIsBounded() throws {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    let levels = 70
    for level in 0..<levels {
      let id = PDFObjectID(100 + level)
      let body = level + 1 < levels ? "/Fm\(level + 1) Do\n" : "/Im1 Do\n"
      let resources: [PDFName: PDFValue] =
        level + 1 < levels
        ? [PDFName("Fm\(level + 1)"): .reference(PDFObjectID(101 + level))]
        : [PDFName("Im1"): .reference(PDFObjectID(6))]
      graph.objects[id] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Form")),
            PDFName("BBox"): .array([.integer(0), .integer(0), .integer(100), .integer(100)]),
            PDFName("Resources"): .dictionary([PDFName("XObject"): .dictionary(resources)]),
          ], bytes: Data(body.utf8)))
    }
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("/Fm0 Do\n".utf8)))
    guard case .dictionary(var page)? = graph.objects[PDFObjectID(3)] else { return }
    page[PDFName("Resources")] = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm0"): .reference(PDFObjectID(100))])
    ])
    graph.objects[PDFObjectID(3)] = .dictionary(page)
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    do {
      _ = try ImageInventory.placements(in: parsed.graph, pageID: PDFObjectID(3))
      Issue.record("Deep form nesting was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
    }
  }

  @Test func rotateRewritesTheMatrixExactly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([RotateImageCommand(pageID: page1, placementIndex: 0, degrees: 90)]),
      to: parsed.graph)
    let placements = try ImageInventory.placements(in: graph, pageID: page1)
    // Center-pivot: the 120x120 footprint stays centered at (140, 660).
    #expect(placements[0].matrix == [0, 120, -120, 0, 200, 600])
    #expect(placements[0].bounds == [80, 600, 200, 720])
    #expect(placements[1].matrix == [120, 0, 0, 120, 80, 400])
    let text = String(decoding: try PageContent.load(pageID: page1, in: graph).bytes, as: UTF8.self)
    #expect(text.contains("0 120 -120 0 200 600"))

    let twice = try PDFEditingEngine.commit(
      PDFTransaction([RotateImageCommand(pageID: page1, placementIndex: 0, degrees: 180)]),
      to: graph)
    let twicePlacements = try ImageInventory.placements(in: twice, pageID: page1)
    #expect(twicePlacements[0].matrix == [0, -120, 120, 0, 80, 720])
    #expect(twicePlacements[0].bounds == [80, 600, 200, 720])
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RotateImageCommand(pageID: page1, placementIndex: 0, degrees: 45)]),
        to: parsed.graph)
    }
  }

  private func formGraph() throws -> PDFGraph {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    graph.objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data("q /Fm1 Do Q\n".utf8)))
    graph.objects[PDFObjectID(8)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(1_000), .integer(1_000)]),
          PDFName("Matrix"): .array([
            .integer(1), .integer(0), .integer(0), .integer(1), .integer(50), .integer(50),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))])
          ]),
        ], bytes: Data("q 100 0 0 100 200 300 cm /Im1 Do Q\n".utf8)))
    guard case .dictionary(var page)? = graph.objects[PDFObjectID(3)] else {
      return graph
    }
    page[PDFName("Resources")] = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(8))])
    ])
    graph.objects[PDFObjectID(3)] = .dictionary(page)
    return try PDFParser.parse(PDFWriter.write(graph)).graph
  }
}
