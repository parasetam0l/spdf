import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P21-009/P21-010 evidence: stable app-created groups across save/reopen and
/// move/resize/rotate for image stamps and rectangles, with explicit refusals
/// for unsupported graphic kinds.
@Suite("Added graphics groups and transforms")
struct AddedGraphicsTests {
  private func graph() throws -> PDFGraph {
    try PDFParser.parse(PDFFixtures.threePages()).graph
  }

  private func appendedStreamIDs(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> [PDFObjectID] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      return [id]
    case .array(let items)?:
      return items.compactMap { if case .reference(let id) = $0 { return id } else { return nil } }
    default:
      return []
    }
  }

  /// Content streams appended after `original` (the page's own streams).
  private func newStreamIDs(
    _ graph: PDFGraph, _ pageID: PDFObjectID, original: Set<PDFObjectID>
  ) throws -> [PDFObjectID] {
    try appendedStreamIDs(graph, pageID).filter { !original.contains($0) }
  }

  // MARK: - P21-009 grouping

  @Test func groupsHoldStableIdentityAcrossReopen() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let pixels = Data((0..<(4 * 4 * 3)).map { UInt8($0 % 251) })
    var edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 10, 60, 40]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [100, 100, 150, 150], width: 4, height: 4, rgb8: pixels),
      ]), to: graph)
    let streams = try newStreamIDs(edited, pageID, original: Set(try appendedStreamIDs(
      graph, pageID)))
    #expect(streams.count == 2)

    edited = try PDFEditingEngine.commit(
      PDFTransaction([
        CreateAddedGroupCommand(members: streams, label: "figure", groupID: "group-1")
      ]), to: edited)
    var groups = try AddedGraphicsGroups.list(in: edited)
    #expect(groups == [AddedGroup(id: "group-1", members: streams, label: "figure")])

    // Stable identity across an independent reopen.
    let reopened = try PDFParser.parse(PDFWriter.write(edited))
    groups = try AddedGraphicsGroups.list(in: reopened.graph)
    #expect(groups.count == 1 && groups[0].id == "group-1")
    #expect(groups[0].members == streams)

    // Membership updates and deletion keep the paint on the page.
    let updated = try PDFEditingEngine.commit(
      PDFTransaction([UpdateAddedGroupCommand(groupID: "group-1", members: [streams[0]])]),
      to: reopened.graph)
    #expect(try AddedGraphicsGroups.list(in: updated) == [
      AddedGroup(id: "group-1", members: [streams[0]], label: "figure")
    ])
    let ungrouped = try PDFEditingEngine.commit(
      PDFTransaction([DeleteAddedGroupCommand(groupID: "group-1")]), to: updated)
    #expect(try AddedGraphicsGroups.list(in: ungrouped).isEmpty)
    #expect(
      try newStreamIDs(ungrouped, pageID, original: Set(try appendedStreamIDs(graph, pageID)))
        .count == 2)

    // Duplicate IDs and non-stream members refuse.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([CreateAddedGroupCommand(members: streams, groupID: "group-1")]),
        to: updated)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([CreateAddedGroupCommand(members: [PDFObjectID(999_999)], groupID: "x")]),
        to: graph)
    }
  }

  // MARK: - P21-010 transforms

  @Test func imageStampsMoveResizeAndRotate() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let pixels = Data((0..<(4 * 4 * 3)).map { UInt8($0 % 251) })
    let placed = try PDFEditingEngine.commit(
      PDFTransaction([
        AddImageStampCommand(
          pageID: pageID, rect: [100, 100, 200, 150], width: 4, height: 4, rgb8: pixels)
      ]), to: graph)
    let streamID = try #require(try appendedStreamIDs(placed, pageID).last)
    #expect(try AddedGraphics.kindOf(streamID: streamID, in: placed) == .imageStamp)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: placed) == [100, 100, 200, 150])

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([MoveAddedGraphicCommand(streamID: streamID, dx: 10, dy: -20)]),
      to: placed)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: moved) == [110, 80, 210, 130])

    let resized = try PDFEditingEngine.commit(
      PDFTransaction([ScaleAddedGraphicCommand(streamID: streamID, scaleX: 2, scaleY: 0.5)]),
      to: moved)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: resized) == [110, 80, 310, 105])

    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotateAddedGraphicCommand(streamID: streamID, degrees: 90)]),
      to: resized)
    let bounds = try #require(try AddedGraphics.boundsOf(streamID: streamID, in: rotated))
    #expect(abs((bounds[2] - bounds[0]) - 25) < 1e-6)
    #expect(abs((bounds[3] - bounds[1]) - 200) < 1e-6)
    // The stamp still draws the same image object.
    let beforeImages = try PDFImageInventory.images(in: placed, pageIDs: [pageID])
    let afterImages = try PDFImageInventory.images(in: rotated, pageIDs: [pageID])
    #expect(beforeImages.count == afterImages.count)
    #expect(afterImages.last?.objectID == beforeImages.last?.objectID)
    // Reopening preserves every object (trailer /Size normalization aside:
    // appends predate this command and leave /Size to the writer).
    #expect(try PDFParser.parse(PDFWriter.write(rotated)).graph.objects == rotated.objects)

    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RotateAddedGraphicCommand(streamID: streamID, degrees: 45)]),
        to: placed)
    }
  }

  @Test func rectanglesMoveResizeAndRotateAboutTheirCenter() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let shaped = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 20, 50, 40]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0]))
      ]), to: graph)
    let streamID = try #require(try appendedStreamIDs(shaped, pageID).last)
    #expect(try AddedGraphics.kindOf(streamID: streamID, in: shaped) == .rectangle)

    let moved = try PDFEditingEngine.commit(
      PDFTransaction([MoveAddedGraphicCommand(streamID: streamID, dx: 5, dy: 5)]),
      to: shaped)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: moved) == [15, 25, 55, 45])

    let resized = try PDFEditingEngine.commit(
      PDFTransaction([ScaleAddedGraphicCommand(streamID: streamID, uniformScale: 2)]),
      to: moved)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: resized) == [15, 25, 95, 65])

    // 90 degrees about the center swaps the extents around the same center.
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotateAddedGraphicCommand(streamID: streamID, degrees: 90)]),
      to: resized)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: rotated) == [35, 5, 75, 85])
    #expect(try PDFParser.parse(PDFWriter.write(rotated)).graph.objects == rotated.objects)
  }

  @Test func unsupportedGraphicsRefuseWithReasons() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let shaped = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .ellipse([10, 10, 60, 40]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddTextObjectCommand(pageID: pageID, rect: [10, 100, 200, 130], text: "Caption"),
      ]), to: graph)
    let streams = try newStreamIDs(shaped, pageID, original: Set(try appendedStreamIDs(
      graph, pageID)))
    #expect(streams.count == 2)
    for streamID in streams {
      #expect(try AddedGraphics.kindOf(streamID: streamID, in: shaped) == .unsupported)
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(
          PDFTransaction([MoveAddedGraphicCommand(streamID: streamID, dx: 1, dy: 1)]),
          to: shaped)
      }
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(
          PDFTransaction([
            ScaleAddedGraphicCommand(streamID: streamID, uniformScale: 2)
          ]), to: shaped)
      }
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(
          PDFTransaction([RotateAddedGraphicCommand(streamID: streamID, degrees: 90)]),
          to: shaped)
      }
    }
  }

  @Test func transformReportsItsOwningPage() throws {
    let graph = try graph()
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let shaped = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageIDs[1], shape: .rectangle([0, 0, 10, 10]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0]))
      ]), to: graph)
    let streamID = try #require(try appendedStreamIDs(shaped, pageIDs[1]).last)
    let command = MoveAddedGraphicCommand(streamID: streamID, dx: 2, dy: 3)
    #expect(command.affectedPageIDs(in: shaped) == [pageIDs[1]])
    let moved = try PDFEditingEngine.commit(PDFTransaction([command]), to: shaped)
    #expect(try AddedGraphics.boundsOf(streamID: streamID, in: moved) == [2, 3, 12, 13])
  }

  // MARK: - P12-017 selection inventory

  @Test func nativeImageStreamsRefuseGraphicMutation() throws {
    // Joint-session finding: dragging a document image rewrote its native
    // placement matrix (unknown transform context), moved the picture out
    // of place, and broke the page. Only app-appended streams carrying the
    // provenance marker are selectable or mutable now.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let images = try PDFImageInventory.images(in: parsed.graph, pageIDs: [pageID])
    #expect(!images.isEmpty)
    #expect(try AddedGraphics.selectable(pageID: pageID, in: parsed.graph).isEmpty)
    guard case .dictionary(let page)? = parsed.graph.objects[pageID] else {
      Issue.record("image fixture page is missing")
      return
    }
    let contentID: PDFObjectID
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      contentID = id
    case .array(let items)?:
      guard case .reference(let id)? = items.first else {
        Issue.record("image fixture page has no content stream")
        return
      }
      contentID = id
    default:
      Issue.record("image fixture page has no content stream")
      return
    }
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([MoveAddedGraphicCommand(streamID: contentID, dx: 5, dy: 5)]),
        to: parsed.graph)
      Issue.record("native stream accepted graphic mutation")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func selectableListsSupportedGraphicsInContentOrder() throws {
    let graph = try graph()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let pixels = Data((0..<(4 * 4 * 3)).map { UInt8($0 % 251) })
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddVectorShapeCommand(
          pageID: pageID, shape: .rectangle([10, 10, 60, 40]),
          style: AddedShapeStyle(strokeColor: [0, 0, 0])),
        AddImageStampCommand(
          pageID: pageID, rect: [100, 100, 150, 150], width: 4, height: 4, rgb8: pixels),
        AddTextObjectCommand(pageID: pageID, rect: [200, 200, 300, 220], text: "Caption"),
      ]), to: graph)
    let found = try AddedGraphics.selectable(pageID: pageID, in: edited)
    // The text object is skipped: only image stamps and rectangles select.
    #expect(found.count == 2)
    #expect(found[0].kind == .rectangle)
    #expect(found[0].bounds == [10, 10, 60, 40])
    #expect(found[1].kind == .imageStamp)
    #expect(found[1].bounds == [100, 100, 150, 150])
    // Every entry points at a real content stream of this page.
    let owned = Set(try appendedStreamIDs(edited, pageID))
    #expect(found.allSatisfy { owned.contains($0.streamID) })
    // A page with no app-created content selects nothing.
    let other = try PDFPageTree.pageIDs(in: edited)[1]
    #expect(try AddedGraphics.selectable(pageID: other, in: edited).isEmpty)
  }
}
