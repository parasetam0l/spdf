import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// IMG-02 evidence: enclosing-matrix resolution and copy-on-write isolation for
/// images inside Form XObjects. The fixtures deliberately share one form
/// between two draws on a page and between two pages so an accidental in-place
/// form edit would be visible in the other instances.
@Suite("Nested and transformed image instances")
struct ImageInstanceEditingTests {
  // MARK: - Fixtures

  /// Two pages share one form (page 1 draws it twice, page 2 once). The form
  /// has a non-identity matrix, a rectangular clip and an inner `q…cm…Do…Q`
  /// placement.
  private func sharedFormGraph() throws -> PDFGraph {
    let image = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Image")),
        PDFName("Width"): .integer(2),
        PDFName("Height"): .integer(2),
        PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
        PDFName("BitsPerComponent"): .integer(8),
      ], bytes: Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]))
    let inner = """
      q
      10 10 180 180 re
      W n
      q
      100 0 0 100 25 30 cm
      /Im1 Do
      Q
      Q
      """ + "\n"
    let form = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("BBox"): .array([
          .integer(0), .integer(0), .integer(200), .integer(200),
        ]),
        PDFName("Matrix"): .array([
          .real(1.5), .integer(0), .integer(0), .real(1.5), .integer(10), .integer(20),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))])
        ]),
      ], bytes: Data(inner.utf8))
    let content1 = "q\n/Fm1 Do\nQ\nq\n/Fm1 Do\nQ\n"
    let content2 = "q\n/Fm1 Do\nQ\n"
    let resources: PDFValue = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(8))])
    ])
    let graph = PDFGraph(
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
          PDFName("Resources"): resources,
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): .array([
            .integer(0), .integer(0), .integer(612), .integer(792),
          ]),
          PDFName("Resources"): resources,
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: Data(content1.utf8))),
        PDFObjectID(6): .stream(image),
        PDFObjectID(7): .stream(PDFStream(bytes: Data(content2.utf8))),
        PDFObjectID(8): .stream(form),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    return try PDFParser.parse(PDFWriter.write(graph)).graph
  }

  /// Page 1 -> FormOuter -> FormInner -> image. FormInner is also reachable
  /// from page 2 through the same outer form.
  private func depthTwoGraph() throws -> PDFGraph {
    var graph = try sharedFormGraph()
    // Wrap the existing form (8) in a second form (9) used by the page.
    graph.objects[PDFObjectID(9)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(400), .integer(400)]),
          PDFName("Matrix"): .array([
            .integer(2), .integer(0), .integer(0), .integer(2), .integer(30), .integer(40),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(8))])
          ]),
        ], bytes: Data("q\n/Fm1 Do\nQ\n".utf8)))
    for pageID in [PDFObjectID(3), PDFObjectID(4)] {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      page[PDFName("Resources")] = .dictionary([
        PDFName("XObject"): .dictionary([PDFName("Outer"): .reference(PDFObjectID(9))])
      ])
      graph.objects[pageID] = .dictionary(page)
    }
    graph.objects[PDFObjectID(5)] = .stream(
      PDFStream(bytes: Data("q\n/Outer Do\nQ\nq\n/Outer Do\nQ\n".utf8)))
    graph.objects[PDFObjectID(7)] = .stream(
      PDFStream(bytes: Data("q\n/Outer Do\nQ\n".utf8)))
    return try PDFParser.parse(PDFWriter.write(graph)).graph
  }

  private func page1() -> PDFObjectID { PDFObjectID(3) }
  private func page2() -> PDFObjectID { PDFObjectID(4) }

  private func expectApprox(_ actual: [Double], _ expected: [Double], tolerance: Double = 0.01) {
    #expect(actual.count == expected.count,
      "expected \(expected.count) components, got \(actual.count)")
    guard actual.count == expected.count else { return }
    for (a, e) in zip(actual, expected) {
      #expect(abs(a - e) <= tolerance, "expected \(expected), got \(actual)")
    }
  }

  private func formBytes(_ graph: PDFGraph, _ id: PDFObjectID) throws -> Data {
    guard case .stream(let stream)? = graph.objects[id] else {
      throw PDFError(.malformed, "Missing form")
    }
    return stream.bytes
  }

  // MARK: - Resolution

  @Test func resolveComposesEnclosingFormMatrixAndChain() throws {
    let graph = try sharedFormGraph()
    let placements = try ImageInventory.placements(in: graph, pageID: page1())
    #expect(placements.count == 2)
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: page1(), placementIndex: 0, in: graph)
    #expect(path.isNested)
    #expect(path.depth == 1)
    #expect(path.steps.count == 1)
    #expect(path.steps[0].formObjectID == PDFObjectID(8))
    #expect(path.steps[0].resourceNameInParent == PDFName("Fm1"))
    #expect(path.steps[0].drawInstructionIndex == 1)
    #expect(path.localMatrix == [100, 0, 0, 100, 25, 30])
    #expect(path.outerMatrix == [1.5, 0, 0, 1.5, 10, 20])
    #expect(path.matrix == [150, 0, 0, 150, 47.5, 65])
    #expect(path.bounds == [47.5, 65, 197.5, 215])
    #expect(path.isDirectlyTransformable)
    #expect(path.refusal == nil)
  }

  @Test func depthTwoPathRecordsEveryEnclosingForm() throws {
    let graph = try depthTwoGraph()
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: page1(), placementIndex: 0, in: graph)
    #expect(path.depth == 2)
    #expect(path.steps.map(\.formObjectID) == [PDFObjectID(9), PDFObjectID(8)])
    #expect(path.steps.map(\.resourceNameInParent) == [PDFName("Outer"), PDFName("Fm1")])
    // outer matrix = parent page * outer form matrix * inner form matrix
    #expect(path.outerMatrix == [3, 0, 0, 3, 50, 80])
    #expect(path.matrix == [300, 0, 0, 300, 125, 170])
  }

  // MARK: - Transform through the chain

  @Test func nestedMoveCopiesOnlyTheSelectedFormInstance() throws {
    var before = try sharedFormGraph()
    let beforeForm = try formBytes(before, PDFObjectID(8))
    let beforePage2 = try PageContent.load(pageID: page2(), in: before).bytes
    let beforeImage = before.objects[PDFObjectID(6)]

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .move(dx: 20, dy: -10))
      ]), to: before)

    let placed = try ImageInventory.placements(in: moved, pageID: page1())
    #expect(placed.count == 2)
    expectApprox(placed[0].matrix, [150, 0, 0, 150, 67.5, 55])
    // The other draw of the same form on the same page is untouched.
    #expect(placed[1].matrix == [150, 0, 0, 150, 47.5, 65])
    // The same form on page 2 is untouched.
    let other = try ImageInventory.placements(in: moved, pageID: page2())
    #expect(other[0].matrix == [150, 0, 0, 150, 47.5, 65])
    #expect(try formBytes(moved, PDFObjectID(8)) == beforeForm)
    #expect(try PageContent.load(pageID: page2(), in: moved).bytes == beforePage2)
    #expect(moved.objects[PDFObjectID(6)] == beforeImage)
    // A fresh copied form exists and the target page addresses it.
    let copiedFormIDs = moved.objects.keys.filter { id in
      before.objects[id] == nil && moved.objects[id] != nil
        && (try? formBytes(moved, id)).map {
          $0.contains(Data("180 180 re".utf8))
        } == true
    }
    #expect(copiedFormIDs.count == 1)
    let copied = try formBytes(moved, copiedFormIDs[0])
    // The local matrix moved in form space by pageDelta / outerScale.
    #expect(String(decoding: copied, as: UTF8.self).contains("38.333333 23.333333 cm"))
    // The original clip remains part of the instance.
    #expect(String(decoding: copied, as: UTF8.self).contains("10 10 180 180 re"))
  }

  @Test func nestedScaleRotateAndFlipKeepTheOtherInstancesIntact() throws {
    let graph = try sharedFormGraph()
    let scaled = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .scale(scaleX: 2, scaleY: 0.5))
      ]), to: graph)
    let scaledPlacements = try ImageInventory.placements(in: scaled, pageID: page1())
    #expect(scaledPlacements[0].matrix == [300, 0, 0, 75, 47.5, 65])
    #expect(scaledPlacements[1].matrix == [150, 0, 0, 150, 47.5, 65])

    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .rotate(degrees: 90))
      ]), to: graph)
    let rotatedPlacements = try ImageInventory.placements(in: rotated, pageID: page1())
    #expect(rotatedPlacements[0].matrix == [0, 150, -150, 0, 197.5, 65])
    #expect(rotatedPlacements[0].bounds == rotatedPlacements[1].bounds)
    #expect(rotatedPlacements[1].matrix == [150, 0, 0, 150, 47.5, 65])

    let flipped = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .flip(horizontal: true))
      ]), to: graph)
    let flippedPlacements = try ImageInventory.placements(in: flipped, pageID: page1())
    #expect(flippedPlacements[0].matrix == [-150, 0, 0, 150, 197.5, 65])
    #expect(flippedPlacements[1].matrix == [150, 0, 0, 150, 47.5, 65])
  }

  @Test func depthTwoMoveCopiesEveryEnclosingForm() throws {
    let graph = try depthTwoGraph()
    let beforeOuter = try formBytes(graph, PDFObjectID(9))
    let beforeInner = try formBytes(graph, PDFObjectID(8))
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .move(dx: 9, dy: 6))
      ]), to: graph)
    let placed = try ImageInventory.placements(in: moved, pageID: page1())
    #expect(placed[0].matrix == [300, 0, 0, 300, 134, 176])
    #expect(placed.count == 2)
    #expect(placed[1].matrix == [300, 0, 0, 300, 125, 170])
    #expect(try formBytes(moved, PDFObjectID(9)) == beforeOuter)
    #expect(try formBytes(moved, PDFObjectID(8)) == beforeInner)
    #expect(try ImageInventory.placements(in: moved, pageID: page2())[0].matrix
      == [300, 0, 0, 300, 125, 170])
  }

  // MARK: - Copy-on-write of shared page resources and content streams

  @Test func sharedPageContentAndResourcesAreCopiedForTheEditedPage() throws {
    var graph = try sharedFormGraph()
    // Both pages reference one resources object and one content stream.
    graph.objects[PDFObjectID(10)] = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(8))])
    ])
    for pageID in [page1(), page2()] {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      page[PDFName("Resources")] = .reference(PDFObjectID(10))
      page[PDFName("Contents")] = .reference(PDFObjectID(5))
      graph.objects[pageID] = .dictionary(page)
    }
    let parsed = try PDFParser.parse(PDFWriter.write(graph))
    let beforeSharedContent = try PageContent.load(pageID: page2(), in: parsed.graph).bytes
    let beforeResources = parsed.graph.objects[PDFObjectID(10)]

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .move(dx: 4, dy: 4))
      ]), to: parsed.graph)
    // The other page keeps the original content stream and resources object.
    #expect(try PageContent.load(pageID: page2(), in: moved).bytes == beforeSharedContent)
    #expect(moved.objects[PDFObjectID(10)] == beforeResources)
    guard case .dictionary(let page1Dict)? = moved.objects[page1()],
      case .reference(let resourcesID)? = page1Dict[PDFName("Resources")]
    else {
      Issue.record("Page 1 resources were not copied")
      return
    }
    #expect(resourcesID != PDFObjectID(10))
    // Page 2 still sees the unmodified shared form chain.
    let p2 = try ImageInventory.placements(in: moved, pageID: page2())
    #expect(p2[0].matrix == [150, 0, 0, 150, 47.5, 65])
  }

  // MARK: - Non-destructive crop through the chain

  @Test func nestedCropWrapsOnlyTheTargetDrawAndKeepsTheOriginalClip() throws {
    let graph = try sharedFormGraph()
    let beforeForm = try formBytes(graph, PDFObjectID(8))
    let beforeClip = try ImageInventory.placements(in: graph, pageID: page1())[1].clippingBounds
    let cropped = try PDFEditingEngine.commit(
      PDFTransaction([
        CropImageInstanceCommand(
          pageID: page1(), placementIndex: 0, unitRect: [0.25, 0.25, 0.75, 0.75])
      ]), to: graph)
    let placed = try ImageInventory.placements(in: cropped, pageID: page1())
    #expect(placed.count == 2)
    #expect(placed[0].hasSupportedClipping)
    expectApprox(placed[0].clippingBounds ?? [], [85, 102.5, 160, 177.5])
    // The unselected draw keeps the original form and clip.
    #expect(placed[1].clippingBounds == beforeClip)
    #expect(try formBytes(cropped, PDFObjectID(8)) == beforeForm)
  }

  // MARK: - IMG-03 conversion through the nested chain

  @Test func nestedRGBConversionCopiesTheFormChainForOneInstance() throws {
    let graph = try sharedFormGraph()
    let beforeImage = graph.objects[PDFObjectID(6)]
    let beforeForm = try formBytes(graph, PDFObjectID(8))
    let replacement = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    let converted = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageInstanceWithConversionCommand(
          pageID: page1(), placementIndex: 0, width: 2, height: 2, rgb8: replacement)
      ]), to: graph)
    let page1Placements = try ImageInventory.placements(in: converted, pageID: page1())
    let page2Placements = try ImageInventory.placements(in: converted, pageID: page2())
    #expect(page1Placements.count == 2)
    #expect(page1Placements[0].imageID != PDFObjectID(6))
    #expect(page1Placements[0].matrix == [150, 0, 0, 150, 47.5, 65])
    #expect(page1Placements[1].imageID == PDFObjectID(6))
    #expect(page2Placements[0].imageID == PDFObjectID(6))
    #expect(converted.objects[PDFObjectID(6)] == beforeImage)
    #expect(try formBytes(converted, PDFObjectID(8)) == beforeForm)
    guard case .stream(let image)? = converted.objects[page1Placements[0].imageID] else {
      Issue.record("Converted nested image is missing")
      return
    }
    #expect(image.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")))
    #expect(try PDFFilters.decoded(image) == replacement)
    let reopened = try PDFParser.parse(PDFWriter.write(converted))
    let reopenedPlacements = try ImageInventory.placements(
      in: reopened.graph, pageID: page1())
    #expect(reopenedPlacements[0].imageID == page1Placements[0].imageID)
    #expect(reopenedPlacements[1].imageID == PDFObjectID(6))
  }

  // MARK: - Page-level instances still use the same command

  @Test func pageLevelInstanceTransformsWithEnclosingPageMatrix() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: parsed.pageIDs[0], placementIndex: 0, transform: .move(dx: 10, dy: 10))
      ]), to: parsed.graph)
    let placements = try ImageInventory.placements(in: moved, pageID: parsed.pageIDs[0])
    #expect(placements[0].matrix == [120, 0, 0, 120, 90, 610])
    #expect(placements[1].matrix == [120, 0, 0, 120, 80, 400])
  }

  // MARK: - Explicit refusals

  @Test func unsafeSharedLocalMatrixIsRefused() throws {
    var graph = try sharedFormGraph()
    graph.objects[PDFObjectID(8)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(200), .integer(200)]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))])
          ]),
        ], bytes: Data("q 100 0 0 100 20 20 cm /Im1 Do /Im1 Do Q\n".utf8)))
    let graph2 = try PDFParser.parse(PDFWriter.write(graph)).graph
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: page1(), placementIndex: 0, in: graph2)
    #expect(!path.isDirectlyTransformable)
    #expect(path.refusal?.contains("q <matrix> cm /Name Do Q") == true)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          TransformImageInstanceCommand(
            pageID: page1(), placementIndex: 0, transform: .move(dx: 1, dy: 1))
        ]), to: graph2)
    }
  }

  @Test func singularEnclosingMatrixIsRefused() throws {
    var graph = try sharedFormGraph()
    graph.objects[PDFObjectID(8)] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([.integer(0), .integer(0), .integer(200), .integer(200)]),
          PDFName("Matrix"): .array([
            .integer(0), .integer(0), .integer(0), .integer(1), .integer(0), .integer(0),
          ]),
          PDFName("Resources"): .dictionary([
            PDFName("XObject"): .dictionary([PDFName("Im1"): .reference(PDFObjectID(6))])
          ]),
        ], bytes: Data("q 100 0 0 100 25 30 cm /Im1 Do Q\n".utf8)))
    let graph2 = try PDFParser.parse(PDFWriter.write(graph)).graph
    let path = try ImageInstanceEditingSupport.resolve(
      pageID: page1(), placementIndex: 0, in: graph2)
    #expect(path.refusal?.contains("singular") == true)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          TransformImageInstanceCommand(
            pageID: page1(), placementIndex: 0, transform: .move(dx: 1, dy: 1))
        ]), to: graph2)
    }
  }

  // MARK: - App nested-image smoke geometry

  /// Mirrors the workspace-smoke fixture: a placed image wrapped in a reusable
  /// Form XObject that is the page's only image. This pins the exact matrices
  /// and clip the App smoke asserts after the routing hooks are wired.
  private func appSmokeNestedGraph() throws -> PDFGraph {
    let blank = try PDFParser.parse(BlankPDF.data(format: .letter))
    let pageID = blank.pageIDs[0]
    var graph = try PDFEditingEngine.commit(
      PDFTransaction([
        PlaceImageCommand(
          pageID: pageID, rect: [250, 340, 350, 440], width: 2, height: 2,
          rgb8: Data([40, 120, 220, 40, 120, 220, 40, 120, 220, 40, 120, 220]))
      ]), to: blank.graph)
    func dictionary(_ value: PDFValue?, in graph: PDFGraph) -> [PDFName: PDFValue]? {
      switch value {
      case .dictionary(let value)?: return value
      case .reference(let id)?:
        guard case .dictionary(let value)? = graph.objects[id] else { return nil }
        return value
      default: return nil
      }
    }
    guard case .dictionary(var page)? = graph.objects[pageID],
      let pageResources = dictionary(page[PDFName("Resources")], in: graph)
    else { throw PDFError(.malformed, "Smoke fixture has no page resources") }
    let contentIDs: [PDFObjectID]
    switch page[PDFName("Contents")] {
    case .reference(let id)?: contentIDs = [id]
    case .array(let values)?:
      contentIDs = values.compactMap {
        if case .reference(let id) = $0 { return id }
        return nil
      }
    default: contentIDs = []
    }
    var imageContent = Data()
    for id in contentIDs {
      guard case .stream(let stream)? = graph.objects[id] else {
        throw PDFError(.malformed, "Smoke fixture content is missing")
      }
      imageContent.append(stream.bytes)
      imageContent.append(10)
    }
    let formID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    let wrapperID = PDFObjectID(formID.number + 1)
    graph.objects[formID] = .stream(PDFStream(dictionary: [
      PDFName("Type"): .name(PDFName("XObject")),
      PDFName("Subtype"): .name(PDFName("Form")),
      PDFName("BBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
      PDFName("Resources"): .dictionary(pageResources),
    ], bytes: imageContent))
    var pageResourcesWithForm = pageResources
    var xObjects = dictionary(pageResources[PDFName("XObject")], in: graph) ?? [:]
    xObjects[PDFName("NestedForm")] = .reference(formID)
    pageResourcesWithForm[PDFName("XObject")] = .dictionary(xObjects)
    page[PDFName("Resources")] = .dictionary(pageResourcesWithForm)
    page[PDFName("Contents")] = .reference(wrapperID)
    graph.objects[pageID] = .dictionary(page)
    graph.objects[wrapperID] = .stream(
      PDFStream(bytes: Data("q /NestedForm Do Q\n".utf8)))
    try graph.validate()
    let withText = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextObjectCommand(
          pageID: pageID, rect: [220, 360, 430, 410], text: "Nested image overlap",
          style: AddedTextStyle(size: 18))
      ]), to: graph)
    return try PDFParser.parse(PDFWriter.write(withText)).graph
  }

  @Test func appSmokeNestedImageEditsMatchTheWiredSmokeAssertions() throws {
    let graph = try appSmokeNestedGraph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let baseline = try ImageInventory.placements(in: graph, pageID: pageID)
    #expect(baseline.count == 1)
    #expect(baseline[0].depth == 1)
    #expect(baseline[0].matrix == [100, 0, 0, 100, 250, 340])
    let formID = try #require(baseline[0].containerObjectID)
    guard case .stream(let originalForm)? = graph.objects[formID] else {
      Issue.record("Smoke fixture lost its form")
      return
    }
    let originalImageID = baseline[0].imageID

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: pageID, placementIndex: 0, transform: .move(dx: 12, dy: 8))
      ]), to: graph)
    let movedPlacement = try #require(
      ImageInventory.placements(in: moved, pageID: pageID).first)
    #expect(movedPlacement.matrix == [100, 0, 0, 100, 262, 348])
    #expect(movedPlacement.imageID == originalImageID)
    if case .stream(let movedForm)? = moved.objects[formID] {
      #expect(movedForm.bytes == originalForm.bytes)
    } else {
      Issue.record("Original form was removed")
    }

    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: pageID, placementIndex: 0, transform: .rotate(degrees: 90))
      ]), to: graph)
    let rotatedPlacement = try #require(
      ImageInventory.placements(in: rotated, pageID: pageID).first)
    #expect(rotatedPlacement.matrix == [0, 100, -100, 0, 350, 340])

    let cropped = try PDFEditingEngine.commit(
      PDFTransaction([
        CropImageInstanceCommand(
          pageID: pageID, placementIndex: 0, unitRect: [0.25, 0.25, 0.75, 0.75])
      ]), to: graph)
    let croppedPlacement = try #require(
      ImageInventory.placements(in: cropped, pageID: pageID).first)
    #expect(croppedPlacement.hasSupportedClipping)
    #expect(croppedPlacement.clippingBounds == [275, 365, 325, 415])
    if case .stream(let croppedForm)? = cropped.objects[formID] {
      #expect(croppedForm.bytes == originalForm.bytes)
    } else {
      Issue.record("Original form was removed by crop")
    }
  }

  // MARK: - Save/reopen stability

  @Test func isolatedNestedEditSurvivesSaveReopen() throws {
    let graph = try sharedFormGraph()
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        TransformImageInstanceCommand(
          pageID: page1(), placementIndex: 0, transform: .move(dx: 15, dy: 12))
      ]), to: graph)
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    let placed = try ImageInventory.placements(in: reopened.graph, pageID: page1())
    expectApprox(placed[0].matrix, [150, 0, 0, 150, 62.5, 77])
    #expect(placed[1].matrix == [150, 0, 0, 150, 47.5, 65])
    #expect(try ImageInventory.placements(in: reopened.graph, pageID: page2())[0].matrix
      == [150, 0, 0, 150, 47.5, 65])
    #expect(try PageContent.load(pageID: page1(), in: reopened.graph).bytes.count > 0)
  }
}
