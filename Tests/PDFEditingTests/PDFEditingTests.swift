import Foundation
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// P17/P23 evidence: semantic commands, staged atomic transactions, and the
/// first real page edit (rotation) with verification.
@Suite("Editing engine")
struct PDFEditingTests {
  @Test func rotatePagesAdjustsRotateAndNormalizes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]), to: parsed.graph)
    #expect(rotation(in: rotated, page: pageID) == 90)

    // Accumulation wraps and never stores out-of-range values. The fixture
    // stores an explicit /Rotate 0, and representation is preserved.
    let accumulated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 270)]), to: rotated)
    #expect(rotation(in: accumulated, page: pageID) == 0)
    #expect(accumulated == parsed.graph)
    #expect(rotated.objects[PDFObjectID(5)] == parsed.graph.objects[PDFObjectID(5)])

    // Rotating back restores the original representation exactly.
    let back = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: -90)]), to: rotated)
    #expect(back == parsed.graph)
    guard case .dictionary(let page) = back.objects[pageID] else {
      Issue.record("Page dictionary missing")
      return
    }
    #expect(page[PDFName("Rotate")] == .integer(0))

    // A page with no /Rotate key returns to having no key.
    var withoutRotation = parsed.graph
    guard case .dictionary(var pageWithoutRotation)? = withoutRotation.objects[pageID] else {
      Issue.record("Page dictionary missing")
      return
    }
    pageWithoutRotation.removeValue(forKey: PDFName("Rotate"))
    withoutRotation.objects[pageID] = .dictionary(pageWithoutRotation)
    let positive = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]),
      to: withoutRotation)
    #expect(rotation(in: positive, page: pageID) == 90)
    let neutral = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: -90)]), to: positive)
    #expect(rotation(in: neutral, page: pageID) == 0)
    // A second stateless command normalizes to an explicit zero; exact
    // no-key restoration comes from transaction snapshots at session level.
    #expect(rotation(in: neutral, page: pageID) != nil)
  }

  @Test func rotatedOutputRoundTripsAndPreservesOtherObjects() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: parsed.pageIDs, byDegrees: 90)]),
      to: parsed.graph)
    let data = try PDFWriter.write(graph)
    let reopened = try PDFParser.parse(data)
    #expect(reopened.pageIDs == parsed.pageIDs)
    #expect(reopened.graph == graph)
    for id in parsed.graph.objects.keys where !parsed.pageIDs.contains(id) {
      #expect(reopened.graph.objects[id] == parsed.graph.objects[id])
    }
  }

  @Test func invalidCommandsFailWithoutPartialMutation() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = parsed.pageIDs[0]

    // Invalid degrees, empty targets, duplicate targets, and non-page targets.
    for command in [
      RotatePagesCommand(pageIDs: [pageID], byDegrees: 45),
      RotatePagesCommand(pageIDs: [], byDegrees: 90),
      RotatePagesCommand(pageIDs: [pageID, pageID], byDegrees: 90),
      RotatePagesCommand(pageIDs: [PDFObjectID(3)], byDegrees: 90),
      RotatePagesCommand(pageIDs: [PDFObjectID(99)], byDegrees: 90),
    ] {
      #expect(throws: PDFError.self) {
        _ = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
      }
    }

    // A failing command in a multi-command transaction leaves everything
    // unchanged: the valid first command is never published.
    let mixed = PDFTransaction([
      RotatePagesCommand(pageIDs: [pageID], byDegrees: 90),
      RotatePagesCommand(pageIDs: [PDFObjectID(3)], byDegrees: 90),
    ])
    do {
      _ = try PDFEditingEngine.commit(mixed, to: parsed.graph)
      Issue.record("Mixed transaction was committed")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }
    let original = try PDFParser.parse(PDFFixtures.onePage())
    #expect(parsed.graph == original.graph)

    // Post-command graph validation also refuses broken results.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(PDFTransaction([BrokenGraphCommand()]), to: parsed.graph)
    }
    // Empty transactions are refused.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(PDFTransaction([]), to: parsed.graph)
    }
  }

  @Test func multiPageTransactionCommitsAtomically() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        RotatePagesCommand(pageIDs: [parsed.pageIDs[0]], byDegrees: 90),
        RotatePagesCommand(pageIDs: [parsed.pageIDs[1], parsed.pageIDs[2]], byDegrees: 180),
      ]), to: parsed.graph)
    #expect(rotation(in: graph, page: parsed.pageIDs[0]) == 90)
    #expect(rotation(in: graph, page: parsed.pageIDs[1]) == 180)
    #expect(rotation(in: graph, page: parsed.pageIDs[2]) == (90 + 180) % 360)
    try graph.validate()
  }

  private func rotation(in graph: PDFGraph, page: PDFObjectID) -> Int? {
    guard case .dictionary(let dictionary)? = graph.objects[page],
      case .integer(let raw)? = dictionary[PDFName("Rotate")]
    else { return nil }
    return Int(raw)
  }
}

/// Test-only command that breaks the page tree so post-command validation
/// must refuse the staged graph.
private struct BrokenGraphCommand: PDFEditCommand {
  var name: String { "Break Graph" }
  func validate(in graph: PDFGraph) throws {}
  func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .reference(let root)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[root]
    else { return graph }
    catalog[PDFName("Pages")] = .reference(PDFObjectID(999))
    graph.objects[root] = .dictionary(catalog)
    return graph
  }
}
