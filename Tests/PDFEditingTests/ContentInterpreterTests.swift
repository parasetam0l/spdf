import Foundation
import PDFCore
import PDFFixtures
@testable import PDFEditing
import Testing

/// P13-005–P13-029: graphics/text state tracking, CTM transforms, clipping
/// bounds, marked content, inline images, nested forms, copy-on-write flags,
/// and unknown-operator preservation.
@Suite("Content interpreter")
struct ContentInterpreterTests {
  private func graph(
    content: String, extraObjects: [PDFObjectID: PDFValue] = [:], pages: Int = 1,
    sharedResources: Bool = false
  ) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(Int64(pages)),
        PDFName("Kids"): .array(
          (0..<pages).map { .reference(PDFObjectID(4 + $0)) }),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ]),
    ]
    for page in 0..<pages {
      let pageID = PDFObjectID(4 + page)
      let contentID = PDFObjectID(100 + page)
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
    }
    for (id, value) in extraObjects { objects[id] = value }
    _ = sharedResources
    return PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  // MARK: - P13-006/P13-015/P13-016/P13-026

  @Test func tracksTransformedTextBaselinesAndInvisibleModes() throws {
    let content = """
      2 0 0 2 100 200 cm
      BT /F1 12 Tf 10 20 Td (Visible) Tj ET
      BT /F1 12 Tf 3 Tr 10 40 Td (Hidden) Tj ET

      """
    let graph = graph(content: content)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let trace = try ContentInterpreter.trace(pageID: pageID, in: graph)
    let texts = trace.draws.filter { $0.kind == .text }
    #expect(texts.count == 2)
    // The CTM scales and translates: the first baseline is (120, 240).
    let visible = try #require(texts.first { $0.text == "Visible" })
    #expect(abs(visible.bounds[0] - 120) < 1)
    // The baseline (240) lies inside the conservative text bounds.
    #expect(visible.bounds[1] <= 240.5 && visible.bounds[3] >= 239.5)
    #expect(visible.fontName == "F1")
    #expect(visible.fontSize == 12)
    #expect(!visible.isInvisibleText)
    let hidden = try #require(texts.first { $0.text == "Hidden" })
    #expect(hidden.isInvisibleText)
    #expect(trace.diagnostics.isEmpty)
  }

  // MARK: - P13-005/P13-008/P13-009/P13-010/P13-017/P13-027

  @Test func tracksStateAcrossNestedFormsAndRestoresIt() throws {
    // A form with its own resources and a nested scale; the page draws it
    // twice with different CTMs and changes the line width between them.
    let formContent = """
      BT /F2 10 Tf 0 0 Td (Form text) Tj ET

      """
    let content = """
      q 1 0 0 1 50 50 cm /Fm1 Do Q
      q 2 0 0 2 100 100 cm /Fm1 Do Q
      5 w 0 0 m 10 10 l S
      1 w 20 20 m 30 30 l S

      """
    let graph = graph(
      content: content,
      extraObjects: [
        PDFObjectID(200): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
        ]),
        PDFObjectID(201): .stream(
          PDFStream(
            dictionary: [
              PDFName("Type"): .name(PDFName("XObject")),
              PDFName("Subtype"): .name(PDFName("Form")),
              PDFName("BBox"): .array([
                .integer(0), .integer(0), .integer(100), .integer(100),
              ]),
              PDFName("Resources"): .dictionary([
                PDFName("Font"): .dictionary([PDFName("F2"): .reference(PDFObjectID(200))])
              ]),
            ], bytes: Data(formContent.utf8))),
      ])
    // The page needs the form in its resources.
    var mutable = graph
    if case .dictionary(var page)? = mutable.objects[PDFObjectID(4)],
      case .dictionary(var resources)? = page[PDFName("Resources")]
    {
      resources[PDFName("XObject")] = .dictionary([
        PDFName("Fm1"): .reference(PDFObjectID(201))
      ])
      page[PDFName("Resources")] = .dictionary(resources)
      mutable.objects[PDFObjectID(4)] = .dictionary(page)
    }
    let pageID = PDFPageTreeObjectID.first
    let trace = try ContentInterpreter.trace(pageID: pageID, in: mutable)
    let forms = trace.draws.filter { $0.kind == .form }
    #expect(forms.count == 2)
    let texts = trace.draws.filter { $0.kind == .text }
    #expect(texts.count == 2)
    // The nested form's font resource resolves through the form's own
    // resources, and the two placements land at different positions.
    #expect(texts.allSatisfy { $0.fontName == "F2" })
    #expect(abs(texts[0].bounds[0] - texts[1].bounds[0]) > 40)
    // Two paths were painted with different widths; state restored between q/Q.
    #expect(trace.draws.filter { $0.kind == .path }.count == 2)
    #expect(trace.diagnostics.isEmpty)
  }

  // MARK: - P13-021/P13-022/P13-028

  @Test func tracksPathsMarkedContentAndInlineImages() throws {
    let content = """
      10 10 100 50 re S
      /Figure <</MCID 7>> BDC
      BT /F1 12 Tf 20 100 Td (Inside) Tj ET
      EMC
      BI /W 1 /H 1 /BPC 8 /CS /G ID x EI
      BT /F1 12 Tf 20 120 Td (After) Tj ET

      """
    let graph = graph(content: content)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let trace = try ContentInterpreter.trace(pageID: pageID, in: graph)
    #expect(trace.draws.contains { $0.kind == .path })
    let span = try #require(trace.markedContent.first)
    #expect(span.mcid == 7)
    #expect(span.tag == "Figure")
    #expect(span.endInstruction > span.startInstruction)
    // The inline image is reported opaque, and the following text survived.
    #expect(trace.diagnostics.contains { $0.kind == .inlineImageOpaque })
    #expect(trace.draws.contains { $0.text == "After" })
  }

  // MARK: - P13-005/P13-007/P13-023/P13-029

  @Test func reportsUnbalancedStateAndPreservesUnknownOperators() throws {
    let content = """
      q
      1 0 0 1 10 10 cm
      Xyz42
      BT /F1 12 Tf 5 5 Td (Kept) Tj

      """
    let graph = graph(content: content)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let trace = try ContentInterpreter.trace(pageID: pageID, in: graph)
    #expect(trace.diagnostics.contains { $0.kind == .unbalancedGraphicsStack })
    #expect(trace.diagnostics.contains { $0.kind == .unbalancedTextObject })
    // The unknown operator is preserved byte-for-byte, and an unrelated edit
    // (a page rotation) leaves the content stream untouched.
    let rotated = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: [pageID], byDegrees: 90)]), to: graph)
    guard case .stream(let before)? = graph.objects[PDFObjectID(100)],
      case .stream(let after)? = rotated.objects[PDFObjectID(100)]
    else {
      Issue.record("content stream missing")
      return
    }
    #expect(before.bytes == after.bytes)
    #expect(String(decoding: before.bytes, as: UTF8.self).contains("Xyz42"))
  }

  @Test func clipBoundsAreConservativeAndSharedResourcesFlagged() throws {
    let content = """
      q 50 50 100 100 re W n
      BT /F1 12 Tf 60 60 Td (Clipped) Tj ET
      Q

      """
    let graph = graph(content: content, pages: 2)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let trace = try ContentInterpreter.trace(pageID: pageIDs[0], in: graph)
    let bounds = try #require(trace.visibleBounds)
    // The clipped text stays inside the clip rectangle.
    #expect(bounds[0] >= 49.5 && bounds[1] >= 49.5)
    #expect(bounds[2] <= 150.5 && bounds[3] <= 150.5)
    // The font resource is referenced by both pages: copy-on-write needed.
    let shared = try ContentInterpreter.sharedResourceNames(pageIDs: pageIDs, in: graph)
    #expect(shared.contains("Font:F1"))
  }
}

enum PDFPageTreeObjectID {
  static let first = PDFObjectID(4)
}

/// P13-023: shadings and patterns are represented conservatively (bounds only,
/// never editable geometry).
@Suite("Interpreter patterns and shadings")
struct InterpreterShadingTests {
  @Test func shadingDrawsAreConservativeAndPatternsListed() throws {
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
      PDFObjectID(4): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("Shading"): .dictionary([PDFName("Sh1"): .dictionary([:])]),
          PDFName("Pattern"): .dictionary([PDFName("P1"): .dictionary([:])]),
        ]),
        PDFName("Contents"): .reference(PDFObjectID(5)),
      ]),
      PDFObjectID(5): .stream(
        PDFStream(
          bytes: Data(
            """
            q 100 0 0 50 200 300 cm /Sh1 sh Q
            /P1 scn 0 0 100 100 re f

            """.utf8))),
    ]
    _ = objects
    let graph = PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let trace = try ContentInterpreter.trace(pageID: pageID, in: graph)
    let shading = try #require(trace.draws.first { $0.kind == .shading })
    // The unit square scaled by the CTM gives conservative bounds.
    #expect(abs(shading.bounds[0] - 200) < 1)
    #expect(abs(shading.bounds[2] - 300) < 1)
    let resources = PDFDocumentInventory.resources(pageID: pageID, in: graph)
    #expect(resources.shadings == ["Sh1"])
    #expect(resources.patterns == ["P1"])
    // The path fill with a pattern color is still a path draw.
    #expect(trace.draws.contains { $0.kind == .path })
  }
}
