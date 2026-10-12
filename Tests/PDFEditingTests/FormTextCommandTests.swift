import Foundation
import PDFCore
import PDFFixtures
import Testing

@testable import PDFEditing

/// P18-017 evidence: text inside a reusable form (Form XObject) is indexed
/// against the form's own resources, replaced byte-surgically in the form
/// stream, and copied before the edit when the form is shared, so other
/// pages keep the original bytes.
@Suite("Form text editing")
struct FormTextCommandTests {
  /// Two pages sharing one text-bearing form; the form carries its own
  /// font resources so page resources stay minimal.
  private func sharedFormDocument() throws -> (data: Data, pages: [PDFObjectID]) {
    let formBytes = Data(
      """
      BT /F1 12 Tf 10 700 Td (Shared form line) Tj ET
      BT /F1 12 Tf 10 680 Td [(Kern) -120 (el kept)] TJ ET
      """.utf8)
    let form = PDFStream(
      dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("BBox"): .array([.integer(0), .integer(0), .integer(300), .integer(800)]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(8))])
        ]),
      ],
      bytes: formBytes)
    let draw1 = Data("q 1 0 0 1 50 50 cm /Fm1 Do Q\n".utf8)
    let draw2 = Data("q 2 0 0 2 100 100 cm /Fm1 Do Q\n".utf8)
    let xobjects: PDFValue = .dictionary([
      PDFName("XObject"): .dictionary([PDFName("Fm1"): .reference(PDFObjectID(6))])
    ])
    let media: PDFValue = .array([.integer(0), .integer(0), .integer(612), .integer(792)])
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
          PDFName("MediaBox"): media,
          PDFName("Resources"): xobjects,
          PDFName("Contents"): .reference(PDFObjectID(5)),
        ]),
        PDFObjectID(4): .dictionary([
          PDFName("Type"): .name(PDFName("Page")),
          PDFName("Parent"): .reference(PDFObjectID(2)),
          PDFName("MediaBox"): media,
          PDFName("Resources"): xobjects,
          PDFName("Contents"): .reference(PDFObjectID(7)),
        ]),
        PDFObjectID(5): .stream(PDFStream(bytes: draw1)),
        PDFObjectID(6): .stream(form),
        PDFObjectID(7): .stream(PDFStream(bytes: draw2)),
        PDFObjectID(8): .dictionary([
          PDFName("Type"): .name(PDFName("Font")),
          PDFName("Subtype"): .name(PDFName("Type1")),
          PDFName("BaseFont"): .name(PDFName("Helvetica")),
          PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
          PDFName("FirstChar"): .integer(32),
          PDFName("LastChar"): .integer(126),
          PDFName("Widths"): .array((32...126).map { code in
            .integer(code == 32 ? 250 : 500)
          }),
          PDFName("FontDescriptor"): .reference(PDFObjectID(9)),
        ]),
        PDFObjectID(9): .dictionary([
          PDFName("Type"): .name(PDFName("FontDescriptor")),
          PDFName("FontName"): .name(PDFName("Helvetica")),
          PDFName("MissingWidth"): .integer(250),
        ]),
      ],
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    let data = try PDFWriter.write(graph)
    let parsed = try PDFParser.parse(data)
    #expect(parsed.pageIDs.count == 2)
    return (data, parsed.pageIDs)
  }

  @Test func formRunsAreIndexedAgainstFormResources() throws {
    let fixture = try sharedFormDocument()
    let parsed = try PDFParser.parse(fixture.data)
    let loaded = try FormTextContent.load(
      pageID: fixture.pages[0], resource: PDFName("Fm1"), in: parsed.graph)
    #expect(loaded.formID == PDFObjectID(6))
    #expect(!loaded.usedPageFallback)
    #expect(loaded.runs.count == 3)
    #expect(loaded.runs[0].text == "Shared form line")
    #expect(loaded.runs[1].text == "Kern")
    #expect(loaded.runs[2].text == "el kept")
  }

  @Test func replaceFormTextRewritesOnlyTheFormStream() throws {
    let fixture = try sharedFormDocument()
    let parsed = try PDFParser.parse(fixture.data)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: fixture.pages[0], runIndex: 0, replacement: "Edited form line",
          formResource: PDFName("Fm1"))
      ]), to: parsed.graph)
    // The edited page's form carries the replacement…
    let loaded = try FormTextContent.load(
      pageID: fixture.pages[0], resource: PDFName("Fm1"), in: graph)
    #expect(loaded.runs[0].text == "Edited form line")
    // …while both page content streams stay byte-identical.
    for (beforeID, afterID) in [(5, 5), (7, 7)] {
      guard case .stream(let before)? = parsed.graph.objects[PDFObjectID(beforeID)],
        case .stream(let after)? = graph.objects[PDFObjectID(afterID)]
      else {
        Issue.record("page content stream missing")
        continue
      }
      #expect(before.bytes == after.bytes)
    }
    // The font object is untouched.
    #expect(graph.objects[PDFObjectID(8)] == parsed.graph.objects[PDFObjectID(8)])
    // The result reparses with the replacement visible.
    let reparsed = try PDFParser.parse(PDFWriter.write(graph))
    let reloaded = try FormTextContent.load(
      pageID: reparsed.pageIDs[0], resource: PDFName("Fm1"), in: reparsed.graph)
    #expect(reloaded.runs[0].text == "Edited form line")
  }

  @Test func sharedFormIsCopiedBeforeTheEdit() throws {
    let fixture = try sharedFormDocument()
    let parsed = try PDFParser.parse(fixture.data)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: fixture.pages[0], runIndex: 0, replacement: "Edited form line",
          formResource: PDFName("Fm1"))
      ]), to: parsed.graph)
    let first = try FormTextContent.load(
      pageID: fixture.pages[0], resource: PDFName("Fm1"), in: graph)
    let second = try FormTextContent.load(
      pageID: fixture.pages[1], resource: PDFName("Fm1"), in: graph)
    // The edit privatized the form: the pages now address different objects.
    #expect(first.formID != second.formID)
    #expect(first.runs[0].text == "Edited form line")
    // The second page still reads the original shared bytes.
    #expect(second.formID == PDFObjectID(6))
    #expect(second.runs[0].text == "Shared form line")
    guard case .stream(let original)? = parsed.graph.objects[PDFObjectID(6)],
      case .stream(let kept)? = graph.objects[PDFObjectID(6)]
    else {
      Issue.record("original form stream missing")
      return
    }
    #expect(kept.bytes == original.bytes)
  }

  @Test func unsharedFormKeepsItsIdentity() throws {
    let fixture = try sharedFormDocument()
    var parsed = try PDFParser.parse(fixture.data)
    // Detach the second page onto its own form copy first.
    var graph = parsed.graph
    let copy = PDFObjectID(9)
    guard case .stream(let form)? = graph.objects[PDFObjectID(6)] else {
      Issue.record("form stream missing")
      return
    }
    graph.objects[copy] = .stream(form)
    guard case .dictionary(var page)? = graph.objects[parsed.pageIDs[1]],
      case .dictionary(var resources)? = page[PDFName("Resources")],
      case .dictionary(var xobjects)? = resources[PDFName("XObject")]
    else {
      Issue.record("page resources missing")
      return
    }
    xobjects[PDFName("Fm1")] = .reference(copy)
    resources[PDFName("XObject")] = .dictionary(xobjects)
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[parsed.pageIDs[1]] = .dictionary(page)
    parsed = try PDFParser.parse(PDFWriter.write(graph))
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: parsed.pageIDs[0], runIndex: 0, replacement: "Edited form line",
          formResource: PDFName("Fm1"))
      ]), to: parsed.graph)
    let loaded = try FormTextContent.load(
      pageID: parsed.pageIDs[0], resource: PDFName("Fm1"), in: edited)
    // Nothing else addresses the form, so no copy is made.
    #expect(loaded.formID == PDFObjectID(6))
    #expect(loaded.runs[0].text == "Edited form line")
  }

  @Test func unknownFormResourceRefusesExplicitly() throws {
    let fixture = try sharedFormDocument()
    let parsed = try PDFParser.parse(fixture.data)
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(
            pageID: fixture.pages[0], runIndex: 0, replacement: "x",
            formResource: PDFName("Nope"))
        ]), to: parsed.graph)
    }
  }

  @Test func formTJMemberKeepsFollowingTextInPlace() throws {
    let fixture = try sharedFormDocument()
    let parsed = try PDFParser.parse(fixture.data)
    let before = try FormTextContent.load(
      pageID: fixture.pages[0], resource: PDFName("Fm1"), in: parsed.graph)
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(
          pageID: fixture.pages[0], runIndex: 1, replacement: "Kerned",
          formResource: PDFName("Fm1"))
      ]), to: parsed.graph)
    let after = try FormTextContent.load(
      pageID: fixture.pages[0], resource: PDFName("Fm1"), in: graph)
    #expect(after.runs[1].text == "Kerned")
    #expect(after.runs[2].text == "el kept")
    // The untouched first run keeps its exact bytes.
    #expect(
      before.content.bytes[before.runs[0].stringSpan]
        == after.content.bytes[after.runs[0].stringSpan])
  }

  @Test func formOverflowRefusalMeasuresTheFixedBox() throws {
    let fixture = try sharedFormDocument()
    let parsed = try PDFParser.parse(fixture.data)
    let command = ReplaceTextCommand(
      pageID: fixture.pages[0], runIndex: 0,
      replacement: "This replacement is far wider than the run allows here",
      overflowPolicy: .refuse, formResource: PDFName("Fm1"))
    let report = try command.previewOverflow(in: parsed.graph)
    #expect(!report.fits)
    #expect(report.overflow > 0)
    #expect(throws: PDFError.self) {
      try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    }
    // The refused commit leaves the graph untouched.
    let loaded = try FormTextContent.load(
      pageID: fixture.pages[0], resource: PDFName("Fm1"), in: parsed.graph)
    #expect(loaded.runs[0].text == "Shared form line")
  }
}
