import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P27-001–P27-029 evidence: region redaction with a conservative supported
/// policy (text, image draws, annotations, form fields), explicit refusals
/// for content the profile cannot remove safely, and whole-document
/// sanitization that prunes unreachable objects for a full rewrite.
@Suite("Redaction and sanitization")
struct RedactionTests {
  private func decodedContent(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let bytes = content.segments.flatMap(\.decoded)
    return String(decoding: bytes, as: UTF8.self)
  }

  @Test func redactsFullyCoveredTextAndPaintsFill() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    #expect(try decodedContent(parsed.graph, pageID).contains("(AB)"))

    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])
      ]), to: parsed.graph)

    // P27-005: the targeted text codes are gone from the content stream.
    let content = try decodedContent(redacted, pageID)
    #expect(!content.contains("(AB)"))
    #expect(!content.contains("(CD)"))
    #expect(try PageTextLayout.build(pageID: pageID, in: redacted).clusters.isEmpty)

    // The visible fill is painted over the region.
    #expect(content.contains("rg"))
    #expect(content.contains("re f"))
    let reloaded = try PageContent.load(pageID: pageID, in: redacted)
    #expect(reloaded.segments.count == 2)

    // P27-022-adjacent: the redacted graph still writes and reparses.
    let data = try PDFWriter.write(redacted)
    let reparsed = try PDFParser.parse(data)
    #expect(reparsed.pageIDs == parsed.pageIDs)
  }

  @Test func refusesPartialTextRunCoverage() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 55, 735]])
        ]), to: parsed.graph)
      Issue.record("A partially covered text run was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("partially intersect"))
    }
  }

  @Test func refusesUninspectableFontText() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .dictionary(let resources)? = page[PDFName("Resources")],
      case .dictionary(let fonts)? = resources[PDFName("Font")],
      case .reference(let fontID)? = fonts[PDFName("F1")],
      case .dictionary(var font)? = graph.objects[fontID]
    else {
      Issue.record("Fixture font missing")
      return
    }
    font[PDFName("Encoding")] = .name(PDFName("MacExpertEncoding"))
    graph.objects[fontID] = .dictionary(font)
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])
        ]), to: graph)
      Issue.record("Text in an uninspectable font was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("cannot inspect"))
    }
  }

  @Test func redactsTextBesideVectorAndRefusesVectorIntersection() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = parsed.pageIDs[0]

    // The blue rule sits at y 660–664; text line 1 at y 710–734.
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[40, 700, 570, 745]])
      ]), to: parsed.graph)
    let content = try decodedContent(redacted, pageID)
    #expect(!content.contains("sPDF Editor fixture - page 1"))
    #expect(content.contains("re f"))

    // P27-011: a region that intersects painted vector content is refused.
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactRegionsCommand(pageID: pageID, regions: [[40, 650, 200, 680]])
        ]), to: parsed.graph)
      Issue.record("Vector intersection was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("vector graphics"))
    }
  }

  @Test func removesIntersectingImageDrawsAndKeepsSharedResources() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let placements = try ImageInventory.placements(in: parsed.graph, pageID: pageID)
    #expect(placements.count == 2)

    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[50, 550, 250, 750]])
      ]), to: parsed.graph)

    // P27-007/P27-009: only the intersecting draw is removed; the shared
    // image object is never rewritten because page 2 still uses it.
    let remaining = try ImageInventory.placements(in: redacted, pageID: pageID)
    #expect(remaining.count == 1)
    #expect(remaining[0].bounds == [80, 400, 200, 520])
    #expect(redacted.objects[PDFObjectID(6)] != nil)
    #expect(
      try ImageInventory.placements(in: redacted, pageID: parsed.pageIDs[1]).count == 1)
    #expect(try decodedContent(redacted, pageID).components(separatedBy: " Do").count == 2)
  }

  @Test func removesUnreferencedImageObjectsOnSanitize() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    var graph = parsed.graph
    for (pageID, region) in [
      (parsed.pageIDs[0], [50.0, 550, 250, 750]),
      (parsed.pageIDs[0], [50.0, 350, 250, 550]),
      (parsed.pageIDs[1], [50.0, 250, 250, 450]),
    ] {
      graph = try PDFEditingEngine.commit(
        PDFTransaction([RedactRegionsCommand(pageID: pageID, regions: [region])]), to: graph)
    }
    #expect(try ImageInventory.placements(in: graph, pageID: parsed.pageIDs[0]).isEmpty)
    #expect(try ImageInventory.placements(in: graph, pageID: parsed.pageIDs[1]).isEmpty)
    #expect(graph.objects[PDFObjectID(6)] != nil)

    // P27-023/P27-025: sanitizing prunes the now-unreferenced image object and
    // the written output retains no original pixel data.
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: graph)
    #expect(sanitized.objects[PDFObjectID(6)] == nil)
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0])) == nil)
    let reparsed = try PDFParser.parse(data)
    let hasImage = reparsed.graph.objects.values.contains { value in
      if case .stream(let stream) = value,
        stream.dictionary[PDFName("Subtype")] == .name(PDFName("Image"))
      {
        return true
      }
      return false
    }
    #expect(!hasImage)
  }

  @Test func removesIntersectingAnnotationsAndRefusesReplies() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let quads: [Double] = [42, 730, 62, 730, 42, 710, 62, 710]
    let withMark = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(pageID: pageID, quads: quads, contents: "target"),
        AddHighlightCommand(pageID: pageID, quads: [400, 730, 420, 730, 400, 710, 420, 710]),
      ]), to: parsed.graph)
    #expect(try AnnotationInventory.annotations(in: withMark, pageID: pageID).count == 2)

    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])
      ]), to: withMark)
    // P27-012: the intersecting mark is removed, the outside mark survives.
    let remaining = try AnnotationInventory.annotations(in: redacted, pageID: pageID)
    #expect(remaining.count == 1)
    #expect(remaining[0].rect == [400, 710, 420, 730])

    // A parent with replies is refused rather than silently orphaning them.
    let withReply = try PDFEditingEngine.commit(
      PDFTransaction([
        AddHighlightCommand(pageID: pageID, quads: quads, contents: "target"),
        AddReplyCommand(pageID: pageID, annotationIndex: 0, text: "reply"),
      ]), to: parsed.graph)
    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])
        ]), to: withReply)
      Issue.record("Redaction of an annotation with replies was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("replies"))
    }
  }

  @Test func removesIntersectingFormFields() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let pageID = parsed.pageIDs[0]
    let before = try FormInventory.fields(in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(before.contains { $0.name == "agree" })

    // The agree checkbox widget sits at [100, 480, 120, 500].
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[90, 470, 130, 510]])
      ]), to: parsed.graph)

    // P27-013: the whole intersecting field is removed; others are intact.
    let after = try FormInventory.fields(in: redacted, pageIDs: parsed.pageIDs)
    #expect(!after.contains { $0.name == "agree" })
    #expect(after.contains { $0.name == "name" })
    #expect(after.contains { $0.name == "notes" })
    let annotations = try AnnotationInventory.annotations(in: redacted, pageID: pageID)
    #expect(!annotations.contains { $0.objectID == PDFObjectID(131) })
  }

  @Test func refusesNestedFormContent() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    let formID = PDFObjectID(90)
    graph.objects[formID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Type"): .name(PDFName("XObject")),
          PDFName("Subtype"): .name(PDFName("Form")),
          PDFName("BBox"): .array([
            .integer(0), .integer(0), .integer(100), .integer(100),
          ]),
        ], bytes: Data("q Q\n".utf8)))
    try FlattenAnnotationsCommand.addXObjectResources(
      [PDFName("Fm1"): .reference(formID)], pageID: pageID, in: &graph)
    let overlayID = PDFObjectID(91)
    graph.objects[overlayID] = .stream(PDFStream(bytes: Data("q /Fm1 Do Q\n".utf8)))
    try FlattenAnnotationsCommand.appendContents([.reference(overlayID)], pageID: pageID, in: &graph)

    do {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactRegionsCommand(pageID: pageID, regions: [[40, 700, 570, 745]])
        ]), to: graph)
      Issue.record("Nested form content was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("form XObject"))
    }
  }

  @Test func sanitizePrunesUnreachableObjectsAndWritesWithoutEarlierRevisions() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    graph.objects[PDFObjectID(90)] = .dictionary([
      PDFName("Marker"): .string(Data("SECRET-MARKER".utf8))
    ])

    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([
        RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])
      ]), to: graph)
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: redacted)

    // P27-023: the unreachable marker object is gone; reachable ones stay.
    #expect(sanitized.objects[PDFObjectID(90)] == nil)
    #expect(sanitized.objects[PDFObjectID(4)] != nil)
    #expect(sanitized.objects[PDFObjectID(5)] != nil)

    // P27-022/P27-024: the full rewrite carries no earlier revisions and no
    // removed text.
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data("SECRET-MARKER".utf8)) == nil)
    #expect(data.range(of: Data("(AB)".utf8)) == nil)
    #expect(data.range(of: Data("(CD)".utf8)) == nil)
    #expect(data.range(of: Data("/Prev".utf8)) == nil)
    _ = try PDFParser.parse(data)
  }
}

/// P03-022: the visible-but-unsanitized redaction fixture — a black
/// rectangle and a Redact annotation over text that stays live in the
/// content stream with its pre-redaction revision still in the file.
extension RedactionTests {
  @Test func unsanitizedRedactionKeepsAHiddenAndHistoricalCopy() throws {
    let data = try PDFFixtures.redactionPages()
    let parsed = try PDFParser.parse(data)
    let pageID = parsed.pageIDs[0]
    // The hidden copy: extraction still finds the "redacted" secret.
    let content = try PageContent.load(pageID: pageID, in: parsed.graph)
    let layout = try PageTextLayout.build(in: content, graph: parsed.graph)
    let text = layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
    #expect(text.contains("SECRET-TOKEN-123"))
    // The visible copy: a Redact annotation with quad points over the secret.
    let annotations = try AnnotationInventory.annotations(in: parsed.graph, pageID: pageID)
    let redacts = annotations.filter { $0.subtype == PDFName("Redact") }
    #expect(redacts.count == 1)
    #expect((redacts.first?.quadPoints?.count ?? 0) == 1)
    // The historical copy: two revisions chained through /Prev, with the
    // superseded content stream still present in the file.
    let raw = String(decoding: data, as: UTF8.self)
    #expect(raw.components(separatedBy: "startxref").count == 3)
    #expect(raw.contains("/Prev"))
    // The paint itself is in the live stream (visible), the text beside it.
    #expect(try decodedContent(parsed.graph, pageID).contains("re f"))
  }
}
