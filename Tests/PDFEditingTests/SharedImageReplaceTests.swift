import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P20-008/P20-012 evidence: deliberate shared-image replacement versus the
/// per-instance copy-on-write path, and the generated image dictionaries.
@Suite("Shared image replacement")
struct SharedImageReplaceTests {
  @Test func sharedReplacementUpdatesEveryReference() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let page2 = parsed.pageIDs[1]
    let before = try ImageInventory.placements(in: parsed.graph, pageID: page1)
    #expect(before.count == 2)
    #expect(before[0].imageID == before[1].imageID)

    let red = Data([255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0])  // 2×2 red
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceSharedImageCommand(
          pageID: page1, placementIndex: 0, width: 2, height: 2, rgb8: red)
      ]), to: parsed.graph)

    let placements = try ImageInventory.placements(in: replaced, pageID: page1)
      + ImageInventory.placements(in: replaced, pageID: page2)
    #expect(placements.count == 3)
    for placement in placements {
      guard case .stream(let image)? = replaced.objects[placement.imageID] else {
        Issue.record("Replaced image is missing")
        return
      }
      #expect(try PDFFilters.decoded(image) == red)
      #expect(image.dictionary[PDFName("Width")] == .integer(2))
      #expect(image.dictionary[PDFName("Height")] == .integer(2))
      #expect(image.dictionary[PDFName("ColorSpace")] == .name(PDFName("DeviceRGB")))
      #expect(image.dictionary[PDFName("BitsPerComponent")] == .integer(8))
      #expect(image.dictionary[PDFName("Filter")] == .name(PDFName("FlateDecode")))
    }
    // The shared object was rewritten in place, so no object was added.
    #expect(replaced.objects.count == parsed.graph.objects.count)
    #expect(try PDFParser.parse(PDFWriter.write(replaced)).graph == replaced)
  }

  @Test func perInstanceReplacementLeavesTheSharedImageAlone() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let page2 = parsed.pageIDs[1]
    let before = try ImageInventory.placements(in: parsed.graph, pageID: page1)
    let sharedID = before[0].imageID
    guard case .stream(let sharedImage)? = parsed.graph.objects[sharedID] else {
      Issue.record("Shared image is missing")
      return
    }
    let originalBytes = try PDFFilters.decoded(sharedImage)

    let red = Data([255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0])
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: page1, placementIndex: 0, width: 2, height: 2, rgb8: red)
      ]), to: parsed.graph)

    let page1Placements = try ImageInventory.placements(in: replaced, pageID: page1)
    let page2Placements = try ImageInventory.placements(in: replaced, pageID: page2)
    #expect(page1Placements[0].imageID != sharedID)
    #expect(page1Placements[1].imageID == sharedID)
    #expect(page2Placements[0].imageID == sharedID)
    guard case .stream(let untouched)? = replaced.objects[sharedID] else {
      Issue.record("Shared image was removed")
      return
    }
    #expect(try PDFFilters.decoded(untouched) == originalBytes)
    guard case .stream(let fresh)? = replaced.objects[page1Placements[0].imageID] else {
      Issue.record("Fresh image is missing")
      return
    }
    #expect(try PDFFilters.decoded(fresh) == red)
    #expect(replaced.objects.count == parsed.graph.objects.count + 1)
  }

  @Test func sharedReplacementRotatesInANewSoftMaskForEveryInstance() throws {
    var graph = try PDFParser.parse(PDFFixtures.imagePages()).graph
    let page1 = PDFObjectID(3)
    let page2 = PDFObjectID(4)
    guard case .stream(let shared)? = graph.objects[PDFObjectID(6)] else {
      Issue.record("Shared image is missing")
      return
    }
    var dictionary = shared.dictionary
    dictionary[PDFName("SMask")] = .reference(PDFObjectID(90))
    graph.objects[PDFObjectID(6)] = .stream(
      PDFStream(dictionary: dictionary, bytes: shared.bytes))
    let alpha = Data([0, 64, 128, 255])
    let replaced = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceSharedImageCommand(
          pageID: page1, placementIndex: 0, width: 2, height: 2,
          rgb8: Data(repeating: 255, count: 12), alpha8: alpha)
      ]), to: graph)

    let placements = try ImageInventory.placements(in: replaced, pageID: page1)
      + ImageInventory.placements(in: replaced, pageID: page2)
    #expect(placements.count == 3)
    #expect(Set(placements.map(\.imageID)) == [PDFObjectID(6)])
    guard case .stream(let image)? = replaced.objects[PDFObjectID(6)],
      case .reference(let maskID)? = image.dictionary[PDFName("SMask")],
      case .stream(let mask)? = replaced.objects[maskID]
    else {
      Issue.record("Shared replacement did not attach its new soft mask")
      return
    }
    #expect(maskID != PDFObjectID(90))
    #expect(try PDFFilters.decoded(mask) == alpha)
    #expect(try PDFParser.parse(PDFWriter.write(replaced)).graph == replaced)
  }

  @Test func sharedReplacementRefusesInvalidInput() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let page1 = parsed.pageIDs[0]
    let red = Data(repeating: 255, count: 12)
    func refuse(_ command: any PDFEditCommand) {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }
    refuse(
      ReplaceSharedImageCommand(pageID: page1, placementIndex: 0, width: 2, height: 2, rgb8: Data(repeating: 1, count: 9)))
    refuse(
      ReplaceSharedImageCommand(pageID: page1, placementIndex: 99, width: 2, height: 2, rgb8: red))
    refuse(
      ReplaceSharedImageCommand(pageID: page1, placementIndex: 0, width: 0, height: 2, rgb8: red))
  }
}
