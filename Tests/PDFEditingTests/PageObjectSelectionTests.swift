import CoreGraphics
import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// IMG-04/IMG-05 evidence: the declared page-content profile, mixed selection
/// composition, marquee/hit testing and the eligibility refusal matrix.
@Suite("Mixed page-object selection")
struct PageObjectSelectionTests {
  @Test func profileSelectsMixedObjectsAndSkipsMarksAndUnsupportedShapes() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let before = Set(try PageObjectContent.pageContents(pageID, in: graph))
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, text: "Hello box"),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 120, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [200, 200, 260, 250], width: 2, height: 2,
          rgb8: Data(repeating: 128, count: 12)),
        AddTextObjectCommand(pageID: pageID, rect: [300, 100, 420, 130], text: "Legacy text"),
        AddVectorShapeCommand(
          pageID: pageID, shape: .ellipse([60, 140, 160, 190]),
          style: AddedShapeStyle(strokeColor: [1, 0, 0])),
        AddTextObjectCommand(pageID: pageID, rect: [300, 200, 420, 230], text: "Watermark"),
      ]), to: graph)
    let added = try PageObjectContent.pageContents(pageID, in: graph).filter {
      !before.contains($0)
    }
    #expect(added.count == 6)
    // Turn the last added text stream into a page-mark stream: mark sets stay
    // outside mixed selection and are edited through the page-mark commands.
    let markStreamID = added[5]
    guard case .stream(var markStream)? = graph.objects[markStreamID] else {
      Issue.record("mark stream missing")
      return
    }
    markStream.dictionary[PDFName("SPDFMark")] = .string(Data("mark-1".utf8))
    graph.objects[markStreamID] = .stream(markStream)

    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    #expect(refs.map(\.kind) == [.authoredTextBox, .rectangle, .imageStamp, .addedText])
    #expect(refs.allSatisfy { $0.pageID == pageID })
    #expect(refs.map(\.streamIndex) == [0, 1, 2, 3].map { $0 + 1 })
    let box = try #require(refs.first)
    #expect(box.streamID == added[0])
    #expect(box.resizeRule == .uniformOnly)
    #expect(box.bounds.count == 4 && box.bounds[0] == 100 && box.bounds[2] >= 220)
    let textObject = try #require(refs.last)
    #expect(textObject.kind == .addedText)
    #expect(textObject.resizeRule == .never)
    #expect(!textObject.supports(.resize))
    #expect(textObject.supports(.move))
    #expect(textObject.bounds[0] >= 299 && textObject.bounds[2] <= 430)

    // The unsupported ellipse gets an actionable refusal instead of a
    // fabricated selection entry.
    let refusals = try PageObjectSelectionProfile.refusals(pageID: pageID, in: graph)
    #expect(refusals.count == 1)
    #expect(refusals[0].reason.contains("vector shape"))
    #expect(refusals[0].bounds == [60, 140, 160, 190])

    // Empty pages select nothing.
    let secondPage = try PDFPageTree.pageIDs(in: graph)[1]
    let emptyPageObjects = try PageObjectSelectionProfile.selectable(
      pageID: secondPage, in: graph)
    #expect(emptyPageObjects.isEmpty)
  }

  @Test func documentImagePlacementsJoinTheProfileWhenDirectlyEditable() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: parsed.graph)
    #expect(refs.count == 2)
    #expect(refs.allSatisfy { $0.kind == .documentImage })
    #expect(refs.allSatisfy { $0.streamID == nil && $0.imagePlacementIndex != nil })
    #expect(refs.map(\.imagePlacementIndex) == [0, 1])
    let placements = try ImageInventory.placements(in: parsed.graph, pageID: pageID)
    #expect(refs.map(\.bounds) == placements.map(\.bounds))
    #expect(refs.allSatisfy { $0.resizeRule == .free })
    // Document images move and resize but never delete, duplicate, reorder or
    // group: those would rewrite original page content or shared resources.
    #expect(refs.allSatisfy { $0.supports(.move) && $0.supports(.resize) })
    #expect(refs.allSatisfy {
      !$0.supports(.delete) && !$0.supports(.duplicate) && !$0.supports(.reorder)
        && !$0.supports(.group)
    })
    // The second fixture page carries one directly drawable placement of its
    // own; every entry still resolves to a real image placement.
    let secondPage = parsed.pageIDs[1]
    let secondRefs = try PageObjectSelectionProfile.selectable(
      pageID: secondPage, in: parsed.graph)
    #expect(secondRefs.count == 1)
    #expect(secondRefs.allSatisfy { $0.kind == .documentImage })
    #expect(secondRefs[0].bounds == [60, 300, 160, 400])
  }

  @Test func marqueeAndHitTestingRespectPaintOrderAndContainment() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 120, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [200, 200, 260, 250], width: 2, height: 2,
          rgb8: Data(repeating: 64, count: 12)),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([90, 60, 160, 140]),
          style: AddedShapeStyle(fillColor: [0, 0, 1])),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    #expect(refs.count == 3)
    let rectangle = refs[0]
    let stamp = refs[1]
    let overlapping = refs[2]

    let rectangleHit = try PageObjectSelectionProfile.object(
      at: [60, 60], pageID: pageID, in: graph)
    #expect(rectangleHit == rectangle)
    let stampHit = try PageObjectSelectionProfile.object(
      at: [230, 230], pageID: pageID, in: graph)
    #expect(stampHit == stamp)
    // The later rectangle paints over the first one and wins the hit test.
    let overlappingHit = try PageObjectSelectionProfile.object(
      at: [100, 70], pageID: pageID, in: graph)
    #expect(overlappingHit == overlapping)
    let emptyHit = try PageObjectSelectionProfile.object(
      at: [500, 500], pageID: pageID, in: graph)
    #expect(emptyHit == nil)

    let first = try #require(
      try PageObjectSelectionProfile.marquee(
        pageID: pageID, rect: [40, 40, 130, 100], in: graph))
    #expect(first.members.map(\.kind) == [.rectangle, .rectangle])
    let bothStamps = try #require(
      try PageObjectSelectionProfile.marquee(
        pageID: pageID, rect: [40, 40, 300, 300], in: graph))
    #expect(bothStamps.count == 3)
    let fullyContained = try #require(
      try PageObjectSelectionProfile.marquee(
        pageID: pageID, rect: [40, 40, 300, 300], mode: .containing, in: graph))
    #expect(fullyContained.count == 3)
    // A marquee that only clips the stamp selects nothing when full
    // containment is requested.
    let clipped = try PageObjectSelectionProfile.marquee(
      pageID: pageID, rect: [195, 195, 210, 210], mode: .containing, in: graph)
    #expect(clipped == nil)
    #expect(
      try PageObjectSelectionProfile.marquee(
        pageID: pageID, rect: [10, 10, 10, 10], in: graph) == nil)
  }

  @Test func shiftCompositionTogglesAndRefusesCrossPageMembers() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageIDs[0], shape: .rectangle([10, 10, 30, 30]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageIDs[0], shape: .rectangle([50, 50, 80, 80]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageIDs[1], shape: .rectangle([10, 10, 30, 30]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
      ]), to: graph)
    let firstPage = try PageObjectSelectionProfile.selectable(
      pageID: pageIDs[0], in: graph)
    let secondPage = try PageObjectSelectionProfile.selectable(
      pageID: pageIDs[1], in: graph)
    #expect(firstPage.count == 2 && secondPage.count == 1)

    var selection = try PageObjectSelection.make([firstPage[0]])
    #expect(selection.count == 1)
    let expanded = try #require(try selection.toggling(firstPage[1]))
    #expect(expanded.count == 2)
    #expect(expanded.isMixed == false)
    selection = expanded
    let shrunk = try #require(try selection.toggling(firstPage[1]))
    #expect(shrunk.count == 1)
    let emptied = try shrunk.toggling(shrunk.members[0])
    #expect(emptied == nil)
    #expect(throws: PDFError.self) {
      _ = try shrunk.toggling(secondPage[0])
    }
    #expect(throws: PDFError.self) {
      _ = try PageObjectSelection.make([firstPage[0], secondPage[0]])
    }
    #expect(throws: PDFError.self) {
      _ = try PageObjectSelection.make([])
    }
  }

  @Test func eligibilityRefusalsAreActionablePerCapability() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        authoredTextCommand(pageID: pageID, text: "Box"),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 120, 90]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [200, 200, 260, 250], width: 2, height: 2,
          rgb8: Data(repeating: 200, count: 12)),
        AddTextObjectCommand(pageID: pageID, rect: [300, 100, 420, 130], text: "Legacy"),
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    #expect(refs.count == 4)
    let box = refs[0]
    let rectangle = refs[1]
    let stamp = refs[2]
    let legacy = refs[3]

    // Graphics-only selection: every capability is available.
    let graphics = try PageObjectSelection.make([rectangle, stamp])
    #expect(graphics.resizeRule == .free)
    for capability in PageObjectCapability.allCases {
      #expect(graphics.supports(capability))
      #expect(graphics.refusal(for: capability) == nil)
    }
    #expect(graphics.label == "2 objects (1 image stamp, 1 rectangle)")

    // Text box + graphics: resize must stay uniform, everything else works.
    let mixed = try PageObjectSelection.make([box, rectangle])
    #expect(mixed.isMixed)
    #expect(mixed.resizeRule == .uniformOnly)
    #expect(mixed.supports(.resize))
    #expect(mixed.supports(.delete) && mixed.supports(.duplicate))
    #expect(mixed.label.contains("2 objects"))

    // A legacy text object supports move only.
    let legacySelection = try PageObjectSelection.make([legacy, stamp])
    #expect(legacySelection.resizeRule == nil)
    #expect(!legacySelection.supports(.resize))
    #expect(
      legacySelection.refusal(for: .resize)?.contains("moving only") == true)
    #expect(legacySelection.supports(.delete))

    // Document images refuse deletion/duplication/reordering/grouping with a
    // reason that names the original page content.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let imagePage = parsed.pageIDs[0]
    let images = try PageObjectSelectionProfile.selectable(
      pageID: imagePage, in: parsed.graph)
    let imageSelection = try PageObjectSelection.make([images[0]])
    for capability in [
      PageObjectCapability.delete, .duplicate, .reorder, .group,
    ] {
      #expect(!imageSelection.supports(capability))
      let refusal = try #require(imageSelection.refusal(for: capability))
      #expect(refusal.contains("original page content"))
    }
    #expect(imageSelection.supports(.move) && imageSelection.supports(.resize))
    #expect(imageSelection.resizeRule == .free)
  }

  @Test func groupedMembersExpandToTheWholeGroup() throws {
    var graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let before = Set(try PageObjectContent.pageContents(pageID, in: graph))
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 10, 40, 40]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([50, 50, 80, 80]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
      ]), to: graph)
    let streams = try PageObjectContent.pageContents(pageID, in: graph).filter {
      !before.contains($0)
    }
    #expect(streams.count == 2)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        CreateAddedGroupCommand(members: streams, label: "pair", groupID: "pair")
      ]), to: graph)
    let refs = try PageObjectSelectionProfile.selectable(pageID: pageID, in: graph)
    #expect(refs.allSatisfy { $0.groupID == "pair" })
    let single = try PageObjectSelection.make([refs[0]])
    let expanded = try PageObjectSelectionProfile.expandingGroups(single, in: graph)
    #expect(expanded.count == 2)
    #expect(expanded.members.map(\.identity) == refs.map(\.identity))
    let members = try PageObjectSelectionProfile.groupMembers(
      streamID: streams[0], in: graph)
    #expect(members == streams)
  }

  // MARK: - Fixtures

  private func authoredTextCommand(pageID: PDFObjectID, text: String = "Hello box")
    -> AddPageTextLinesCommand
  {
    let format = PageTextFormat(font: .helvetica, size: 12, color: [0, 0, 0])
    let segment = PageTextSegment(text: text, x: 100, format: format, width: 54)
    let line = PageTextLine(
      text: text, x: 100, baseline: 300, segments: [segment], endsParagraph: true)
    let box = PageTextBox(
      x: 100, firstBaseline: 300, width: 160, lineSpacing: 14.4, wraps: true)
    return AddPageTextLinesCommand(pageID: pageID, lines: [line], box: box)
  }
}
