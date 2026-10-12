import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P19-016/P19-017/P19-019: multi-column boundaries, downstream repositioning
/// of following text, and annotation updates when layout moves.
@Suite("Paragraph downstream")
struct ParagraphDownstreamTests {
  private func fixture(annotations: Bool = false) -> PDFGraph {
    var content = Data()
    content.append(Data("BT /F1 12 Tf 42 660 Td (Left column line one) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 640 Td (Left column line two) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 340 660 Td (Right column top) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 340 640 Td (Right column bottom) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 560 Td (Following line) Tj ET\n".utf8))
    content.append(Data("BT /F1 12 Tf 42 100 Td (Far line) Tj ET\n".utf8))
    var page: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("Resources"): .dictionary([
        PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
      ]),
      PDFName("Contents"): .reference(PDFObjectID(5)),
    ]
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ]),
      PDFObjectID(5): .stream(PDFStream(bytes: content)),
    ]
    if annotations {
      objects[PDFObjectID(6)] = .dictionary([
        PDFName("Type"): .name(PDFName("Annot")),
        PDFName("Subtype"): .name(PDFName("Link")),
        PDFName("Rect"): .array([
          .integer(42), .integer(552), .integer(180), .integer(572),
        ]),
        PDFName("A"): .dictionary([
          PDFName("S"): .name(PDFName("URI")),
          PDFName("URI"): .string(Data("https://example.invalid/next".utf8)),
        ]),
      ])
      page[PDFName("Annots")] = .array([.reference(PDFObjectID(6))])
    }
    objects[PDFObjectID(4)] = .dictionary(page)
    return PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  private func baselines(_ graph: PDFGraph, pageID: PDFObjectID) throws -> [String: Double] {
    let runs = try TextRunIndexer.runs(
      in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    var result: [String: Double] = [:]
    for run in runs {
      let text = run.text.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      result[text] = run.baselineY
    }
    return result
  }

  @Test func multiColumnBoundariesSplitBlocks() throws {
    let graph = fixture()
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    // The two columns share baselines but never merge into one block.
    let left = try #require(candidates.first { $0.text.contains("Left column line one") })
    let right = try #require(candidates.first { $0.text.contains("Right column top") })
    #expect(left.runIndices != right.runIndices)
    #expect(!left.text.contains("Right column"))
    #expect(left.bounds[2] < 200)
    #expect(right.bounds[0] > 300)
    // Reflowing the left column leaves the right column's text untouched.
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: left,
          replacement: "Reflowed left column text that wraps further down the column.",
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: graph)
    let text = try PageTextLayout.build(pageID: pageID, in: edited).clusters.map(\.text).joined()
    #expect(text.contains("Right column top"))
    #expect(text.contains("Right column bottom"))
    #expect(text.contains("Reflowed"))
  }

  @Test func downstreamShiftMovesFollowingTextAndAnnotations() throws {
    let graph = fixture(annotations: true)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let left = try #require(
      try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
        .first { $0.text.contains("Left column line one") })
    // The replacement grows the paragraph by about two lines.
    let replacement = Array(repeating: "grown", count: 24).joined(separator: " ")
    let result = try ParagraphReflow.plan(
      pageID: pageID, candidate: left, replacement: replacement, in: graph,
      options: ParagraphReflowOptions(
        overflow: .allow, allowLowConfidence: true, downstreamShift: true))
    #expect(result.plan.downstreamDelta > 20)
    #expect(result.plan.downstreamText.count == 1)
    #expect(result.plan.downstreamAnnotations.count == 1)

    let before = try baselines(graph, pageID: pageID)
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: left, replacement: replacement,
          options: ParagraphReflowOptions(
            overflow: .allow, allowLowConfidence: true, downstreamShift: true))
      ]), to: graph)
    let after = try baselines(edited, pageID: pageID)
    // The following line moved down by the delta; the far line did not.
    let delta = result.plan.downstreamDelta
    #expect(abs((after["Following line"] ?? 0) - ((before["Following line"] ?? 0) - delta)) < 0.01)
    #expect(after["Far line"] == before["Far line"])
    // The link annotation moved with its line.
    guard case .dictionary(let annotation)? = edited.objects[PDFObjectID(6)],
      case .array(let rect)? = annotation[PDFName("Rect")], rect.count == 4
    else {
      Issue.record("Annotation missing")
      return
    }
    // Rect is [x0, y0, x1, y1].
    var y0: Double?
    switch rect[1] {
    case .integer(let raw): y0 = Double(raw)
    case .real(let raw): y0 = raw
    default: y0 = nil
    }
    guard let y0 else {
      Issue.record("Annotation y is not numeric")
      return
    }
    #expect(abs(y0 - (552 - delta)) < 0.01)
    // The link target is preserved.
    guard case .dictionary(let action)? = annotation[PDFName("A")],
      case .string(let uri)? = action[PDFName("URI")]
    else {
      Issue.record("Link action missing")
      return
    }
    #expect(String(decoding: uri, as: UTF8.self) == "https://example.invalid/next")
  }

  @Test func downstreamShiftKeepsStructureReferencesValid() throws {
    let parsed = try PDFParser.parse(PDFFixtures.taggedPages())
    let pageID = parsed.pageIDs[0]
    let paragraph = try #require(
      try ParagraphReconstruction.candidates(pageID: pageID, in: parsed.graph)
        .first { $0.structureRole == "P" })
    let replacement = "Tagged paragraph text replaced with a longer sentence that wraps."
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: paragraph, replacement: replacement,
          options: ParagraphReflowOptions(
            overflow: .allow, allowLowConfidence: true, downstreamShift: true))
      ]), to: parsed.graph)
    let inventory = try PDFStructureInspector.inspect(in: edited, pageIDs: parsed.pageIDs)
    #expect(inventory.issues.isEmpty)
    #expect(inventory.elements.contains { $0.role == "P" })
    #expect(inventory.pageMCIDs[0].contains(1))
    // The figure's image draw is not a text run and stays put.
    let content = try PageContent.load(pageID: pageID, in: edited)
    #expect(content.instructions.contains { $0.operatorName == "Do" })
  }
}
