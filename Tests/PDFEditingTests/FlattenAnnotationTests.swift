import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P22-022/P22-028 evidence: explicit annotation flattening burns generated
/// appearances into page content, removes the interactivity, keeps visible
/// marks, and leaves links untouched.
@Suite("Annotation flattening")
struct FlattenAnnotationTests {
  @Test func flattenBurnsAppearancesAndKeepsLinks() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(
          pageID: pageID, quads: [42, 730, 62, 730, 42, 710, 62, 710], contents: "mark"),
        AddShapeCommand(
          pageID: pageID, kind: .square, rect: [100, 100, 200, 160], borderColor: [0, 0, 1],
          fillColor: [1, 1, 0], borderWidth: 2),
        AddNoteCommand(pageID: pageID, at: [300, 400], contents: "note"),
        AddLinkCommand(
          pageID: pageID, rect: [10, 10, 60, 30], target: .uri("https://example.com")),
      ]), to: parsed.graph)
    let before = try AnnotationInventory.annotations(in: marked, pageID: pageID)
    #expect(before.count == 4)
    let appearanceIDs = before.compactMap { annotation -> PDFObjectID? in
      guard case .dictionary(let ap)? = annotation.dictionary[PDFName("AP")],
        case .reference(let id)? = ap[PDFName("N")]
      else { return nil }
      return id
    }
    #expect(appearanceIDs.count == 3)
    var appearanceBytes: [PDFObjectID: Data] = [:]
    for id in appearanceIDs {
      guard case .stream(let stream)? = marked.objects[id] else { continue }
      appearanceBytes[id] = stream.bytes
    }

    let flattened = try PDFEditingEngine.commit(
      PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: marked)
    let after = try AnnotationInventory.annotations(in: flattened, pageID: pageID)
    #expect(after.count == 1)
    #expect(after[0].subtype == PDFName("Link"))

    // Appearances survive byte-identically and are referenced by page
    // resources under unique names.
    for id in appearanceIDs {
      guard case .stream(let stream)? = flattened.objects[id] else {
        Issue.record("Flattened appearance was removed")
        return
      }
      #expect(stream.bytes == appearanceBytes[id])
    }
    guard case .dictionary(let page)? = flattened.objects[pageID],
      case .array(let contents)? = page[PDFName("Contents")]
    else {
      Issue.record("Flattened page content is missing")
      return
    }
    #expect(contents.count == 4)  // original stream plus three flattened streams
    let flattenedStreams = contents.dropFirst().compactMap { value -> PDFStream? in
      guard case .reference(let id) = value, case .stream(let stream)? = flattened.objects[id]
      else { return nil }
      return stream
    }
    #expect(flattenedStreams.count == 3)
    let firstContent = String(decoding: flattenedStreams[0].bytes, as: UTF8.self)
    #expect(firstContent.contains("1 0 0 1 42 710 cm"))
    #expect(firstContent.contains("/FmFlatten1 Do"))
    #expect(firstContent.contains("q"))
    #expect(firstContent.contains("Q"))

    guard case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let xobjects)? = resources[PDFName("XObject")]
    else {
      Issue.record("Flattened resources are missing")
      return
    }
    #expect(Set(xobjects.keys) == [PDFName("FmFlatten1"), PDFName("FmFlatten2"), PDFName("FmFlatten3")])
    for (_, value) in xobjects {
      guard case .reference(let id) = value else {
        Issue.record("Flattened resource is not a reference")
        return
      }
      #expect(appearanceIDs.contains(id))
    }

    // Annotation objects are gone; the page reparses identically.
    for annotation in before where annotation.subtype != PDFName("Link") {
      if let objectID = annotation.objectID {
        #expect(flattened.objects[objectID] == nil)
      }
    }
    #expect(try PDFParser.parse(PDFWriter.write(flattened)).graph == flattened)
  }

  @Test func flattenRefusesPagesWithoutGeneratedAppearances() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = parsed.pageIDs[0]
    let linked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddLinkCommand(
          pageID: pageID, rect: [10, 10, 60, 30], target: .uri("https://example.com"))
      ]), to: parsed.graph)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: linked)
    }
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([FlattenAnnotationsCommand(pageID: parsed.pageIDs[1])]), to: parsed.graph)
    }
    #expect(
      FlattenAnnotationsCommand.flattenablePageIDs(in: linked, pageIDs: parsed.pageIDs).isEmpty)
    #expect(
      FlattenAnnotationsCommand.flattenablePageIDs(in: parsed.graph, pageIDs: parsed.pageIDs)
        .isEmpty)
  }

  @Test func flattenHandlesArrayContentsAndReferencedResources() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    // Move page resources into their own object and wrap contents in an array.
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      Issue.record("Fixture page is missing")
      return
    }
    if case .dictionary(let resources)? = page[PDFName("Resources")] {
      graph.objects[PDFObjectID(50)] = .dictionary(resources)
      page[PDFName("Resources")] = .reference(PDFObjectID(50))
    }
    if case .reference(let contentID)? = page[PDFName("Contents")] {
      page[PDFName("Contents")] = .array([.reference(contentID)])
    }
    graph.objects[pageID] = .dictionary(page)
    let marked = try PDFEditingEngine.commit(
      PDFTransaction([
        AddShapeCommand(
          pageID: pageID, kind: .circle, rect: [200, 200, 260, 240], borderColor: [1, 0, 0])
      ]), to: graph)
    let flattened = try PDFEditingEngine.commit(
      PDFTransaction([FlattenAnnotationsCommand(pageID: pageID)]), to: marked)
    guard case .dictionary(let flatPage)? = flattened.objects[pageID],
      case .array(let contents)? = flatPage[PDFName("Contents")],
      case .reference(let resourcesID)? = flatPage[PDFName("Resources")],
      case .dictionary(let resources)? = flattened.objects[resourcesID],
      case .dictionary(let xobjects)? = resources[PDFName("XObject")]
    else {
      Issue.record("Flattened array-content page is malformed")
      return
    }
    #expect(contents.count == 2)
    #expect(xobjects[PDFName("FmFlatten1")] != nil)
    #expect(try PDFParser.parse(PDFWriter.write(flattened)).graph == flattened)
  }
}
