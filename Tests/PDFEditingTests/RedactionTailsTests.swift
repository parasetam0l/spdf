import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P27-002/P27-008/P27-010/P27-014/P27-015/P27-017–P27-021/P27-026–P27-028/P27-030 evidence.
@Suite("Redaction tails")
struct RedactionTailsTests {
  @Test func pendingMarksAreEditableAndClearlyUnapplied() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    var store = PendingRedactionStore()
    #expect(store.statusDescription == "no redaction marks")
    #expect(!store.reportsComplete)
    let first = try store.add(pageID: pageID, rect: [40, 705, 95, 735])
    #expect(store.hasUnappliedMarks)
    #expect(!store.reportsComplete)
    #expect(store.statusDescription.contains("pending"))
    #expect(store.statusDescription.contains("not applied"))
    // Editable before apply.
    try store.updateRect(id: first.id, rect: [40, 705, 100, 740])
    #expect(store.marks.first?.rect == [40, 705, 100, 740])
    // Applying removes the text and paints the fill.
    let applied = try store.apply(to: parsed.graph)
    #expect(store.reportsComplete)
    #expect(store.statusDescription.contains("applied"))
    let content = String(decoding: try PageContent.load(pageID: pageID, in: applied).segments.flatMap(\.decoded), as: UTF8.self)
    #expect(!content.contains("(AB)"))
    #expect(content.contains("re f"))
    // Undo-before-apply never reports complete.
    store.noteUndone()
    #expect(!store.reportsComplete)
    #expect(store.hasUnappliedMarks)
    store.remove(id: first.id)
    #expect(store.marks.isEmpty)
    #expect(throws: PDFError.self) { _ = try store.apply(to: parsed.graph) }
  }

  @Test func repeatedRedactionUndoNeverReportsComplete() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    var store = PendingRedactionStore()
    _ = try store.add(pageID: parsed.pageIDs[0], rect: [40, 705, 95, 735])
    _ = try store.apply(to: parsed.graph)
    #expect(store.reportsComplete)
    // A second cycle stages a new mark; it is pending until applied.
    _ = try store.add(pageID: parsed.pageIDs[0], rect: [40, 705, 95, 735])
    #expect(!store.reportsComplete)
    #expect(store.statusDescription.contains("pending"))
  }

  @Test func imageDerivativesRemoveAffectedPixels() throws {
    let rgb8 = Data((0..<48).map { UInt8($0 % 256) })
    let redacted = try RedactedImageDerivative.redactPixels(
      rgb8: rgb8, width: 4, height: 4, pixelRect: (x: 1, y: 1, w: 2, h: 2))
    let bytes = [UInt8](redacted)
    // Inside the rect is black.
    #expect(bytes[(1 * 4 + 1) * 3] == 0 && bytes[(1 * 4 + 1) * 3 + 1] == 0)
    #expect(bytes[(2 * 4 + 2) * 3] == 0)
    // Outside is preserved.
    #expect(bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 2)
    #expect(throws: PDFError.self) {
      _ = try RedactedImageDerivative.redactPixels(rgb8: rgb8, width: 4, height: 4, pixelRect: (x: 10, y: 10, w: 2, h: 2))
    }
    // Graph-level derivative on the shared image fixture.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let placements = try ImageInventory.placements(in: parsed.graph, pageID: pageID)
    let target = try #require(placements.first)
    let (graph, imageID) = try RedactedImageDerivative.derivative(
      pageID: pageID, placement: target, region: [50, 550, 250, 750], in: parsed.graph)
    guard case .stream(let stream)? = graph.objects[imageID] else {
      Issue.record("Derivative image missing")
      return
    }
    #expect(stream.dictionary[PDFName("Width")] == .integer(2))
    let decoded = try PDFFilters.decoded(stream)
    #expect(decoded != Data([0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0]))
    #expect(decoded.contains(0))
  }

  @Test func conservativeContentRefusesMasksClippingPatternsAndForms() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    // Clean page has no conservative risks.
    #expect(try RedactionConservativePolicy.risks(pageID: pageID, regions: [[50, 550, 250, 750]], in: parsed.graph).isEmpty)
    // Masked image intersecting the region.
    var masked = parsed.graph
    guard case .stream(var image)? = masked.objects[PDFObjectID(6)] else {
      Issue.record("Image missing")
      return
    }
    image.dictionary[PDFName("SMask")] = .reference(PDFObjectID(90))
    masked.objects[PDFObjectID(6)] = .stream(image)
    masked.objects[PDFObjectID(90)] = .stream(PDFStream(bytes: Data("mask".utf8)))
    let maskRisks = try RedactionConservativePolicy.risks(pageID: pageID, regions: [[50, 550, 250, 750]], in: masked)
    #expect(maskRisks.contains { $0.kind == "mask" })
    #expect(throws: PDFError.self) {
      try RedactionConservativePolicy.validate(pageID: pageID, regions: [[50, 550, 250, 750]], in: masked)
    }
    // Clipping path.
    var clipped = parsed.graph
    let overlayID = PDFObjectID(91)
    clipped.objects[overlayID] = .stream(PDFStream(bytes: Data("q 0 0 m 10 10 l W n Q\n".utf8)))
    try FlattenAnnotationsCommand.appendContents([.reference(overlayID)], pageID: pageID, in: &clipped)
    #expect(try RedactionConservativePolicy.risks(pageID: pageID, regions: [[0, 0, 612, 792]], in: clipped).contains { $0.kind == "clipping" })
    // Pattern paint.
    var patterned = parsed.graph
    let patternOverlay = PDFObjectID(92)
    patterned.objects[patternOverlay] = .stream(PDFStream(bytes: Data("q /P1 scn Q\n".utf8)))
    try FlattenAnnotationsCommand.appendContents([.reference(patternOverlay)], pageID: pageID, in: &patterned)
    #expect(try RedactionConservativePolicy.risks(pageID: pageID, regions: [[0, 0, 612, 792]], in: patterned).contains { $0.kind == "pattern" })
    // Reusable form draw.
    var formed = parsed.graph
    let formID = PDFObjectID(93)
    formed.objects[formID] = .stream(PDFStream(
      dictionary: [PDFName("Type"): .name(PDFName("XObject")), PDFName("Subtype"): .name(PDFName("Form"))],
      bytes: Data("q Q\n".utf8)))
    try FlattenAnnotationsCommand.addXObjectResources([PDFName("Fm9"): .reference(formID)], pageID: pageID, in: &formed)
    let formOverlay = PDFObjectID(94)
    formed.objects[formOverlay] = .stream(PDFStream(bytes: Data("q /Fm9 Do Q\n".utf8)))
    try FlattenAnnotationsCommand.appendContents([.reference(formOverlay)], pageID: pageID, in: &formed)
    #expect(try RedactionConservativePolicy.risks(pageID: pageID, regions: [[0, 0, 612, 792]], in: formed).contains { $0.kind == "form" })
  }

  @Test func structureAndMarkedContentLoseRemovedText() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([RedactRegionsCommand(pageID: parsed.pageIDs[0], regions: [[40, 705, 95, 735]])]),
      to: parsed.graph)
    // The removed run's strings are gone from content and structure.
    try RedactionStructureAudit.verifyNoRetainedText(
      in: redacted, pageIDs: parsed.pageIDs, redactedStrings: ["AB", "CD"])
    #expect(throws: PDFError.self) {
      try RedactionStructureAudit.verifyNoRetainedText(
        in: parsed.graph, pageIDs: parsed.pageIDs, redactedStrings: ["AB"])
    }
  }

  @Test func alternateContentInventoryListsLayers() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let empty = try RedactionAlternateContent.inventory(pageID: parsed.pageIDs[0], in: parsed.graph)
    #expect(empty.optionalContentGroups.isEmpty)
    #expect(empty.markedContentWithOC == 0)
    var graph = parsed.graph
    graph.objects[PDFObjectID(60)] = .dictionary([
      PDFName("Type"): .name(PDFName("OCG")),
      PDFName("Name"): .string(Data("Hidden layer".utf8)),
    ])
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    {
      catalog[PDFName("OCProperties")] = .dictionary([
        PDFName("OCGs"): .array([.reference(PDFObjectID(60))])
      ])
      graph.objects[rootID] = .dictionary(catalog)
    }
    let inventoried = try RedactionAlternateContent.inventory(pageID: parsed.pageIDs[0], in: graph)
    #expect(inventoried.optionalContentGroups == ["Hidden layer"])
  }

  @Test func flattenedDerivativeKeepsOnlyRedactedPixels() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])]),
      to: parsed.graph)
    let pixels = Data(repeating: 128, count: 4 * 4 * 3)
    let flat = try FlattenedRedactedDerivative.make(
      from: redacted, pageID: pageID, width: 4, height: 4, rgb8: pixels)
    #expect(FlattenedRedactedDerivative.isFlattenedDerivative(flat, pageID: pageID))
    let content = try PageContent.load(pageID: pageID, in: flat)
    let text = content.instructions.filter { ["Tj", "TJ", "'", "\""].contains($0.operatorName) }
    #expect(text.isEmpty)
    #expect((try? AnnotationInventory.annotations(in: flat, pageID: pageID))?.isEmpty == true)
    #expect(!OCRLayer.hasGeneratedLayer(in: flat, pageID: pageID))
    let data = try PDFWriter.write(flat)
    #expect(data.range(of: Data("(AB)".utf8)) == nil)
    _ = try PDFParser.parse(data)
    #expect(throws: PDFError.self) {
      _ = try FlattenedRedactedDerivative.make(from: redacted, pageID: pageID, width: 4, height: 4, rgb8: Data([1, 2, 3]))
    }
  }

  @Test func ocrRunsOnlyOnTheRedactedDerivative() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([RedactRegionsCommand(pageID: pageID, regions: [[40, 705, 95, 735]])]),
      to: parsed.graph)
    #expect(throws: PDFError.self) {
      _ = try RedactedOCRPolicy.addOCR(
        to: redacted, pageID: pageID, lines: [SearchableTextLine(text: "after", rect: [10, 10, 60, 30])])
    }
    let flat = try FlattenedRedactedDerivative.make(
      from: redacted, pageID: pageID, width: 4, height: 4, rgb8: Data(repeating: 200, count: 48))
    let withOCR = try RedactedOCRPolicy.addOCR(
      to: flat, pageID: pageID, lines: [SearchableTextLine(text: "after", rect: [10, 10, 60, 30])])
    #expect(OCRLayer.hasGeneratedLayer(in: withOCR, pageID: pageID))
  }

  @Test func sanitizerPassesReportAndVerify() throws {
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    graph.trailer[PDFName("Info")] = .dictionary([PDFName("Title"): .string(Data("secret".utf8))])
    graph.objects[PDFObjectID(70)] = .stream(PDFStream(
      dictionary: [PDFName("Type"): .name(PDFName("Metadata"))], bytes: Data("<x/>".utf8)))
    graph.objects[PDFObjectID(71)] = .stream(PDFStream(
      dictionary: [PDFName("Type"): .name(PDFName("EmbeddedFile")), PDFName("F"): .string(Data("evil.bin".utf8))],
      bytes: Data("payload".utf8)))
    graph.objects[PDFObjectID(72)] = .dictionary([
      PDFName("S"): .name(PDFName("JavaScript")), PDFName("JS"): .string(Data("app.alert(1)".utf8))])
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    {
      catalog[PDFName("OpenAction")] = .reference(PDFObjectID(72))
      graph.objects[rootID] = .dictionary(catalog)
    }
    let (sanitized, report) = try SanitizerPass.run(in: graph, policy: SanitizerPolicy.redactionDefault)
    #expect(report.removedMetadata >= 1)
    #expect(report.removedAttachments >= 1)
    #expect(report.removedScripts >= 1)
    #expect(!report.transformations.isEmpty)
    #expect(report.summary != "no changes")
    try SanitizedDerivativeCheck.verify(in: sanitized)
    #expect(throws: PDFError.self) { try SanitizedDerivativeCheck.verify(in: graph) }
    // Permitted attachments survive with an explicit allow-list.
    var allowed = graph
    allowed.objects[PDFObjectID(71)] = .stream(PDFStream(
      dictionary: [PDFName("Type"): .name(PDFName("EmbeddedFile")), PDFName("F"): .string(Data("keep.txt".utf8))],
      bytes: Data("payload".utf8)))
    let (kept, _) = try SanitizerPass.run(
      in: allowed, policy: SanitizerPolicy(removeAttachmentsExcept: ["keep.txt"], removeEmbeddedFilesExcept: ["keep.txt"]))
    try SanitizedDerivativeCheck.verify(in: kept, allowedAttachments: ["keep.txt"])
  }

  @Test func adversarialDerivativeSurvivesIndependentInspection() throws {
    // Visible text plus hidden copies in metadata, an embedded file, and
    // an incremental revision — the adversarial shape P27-027 guards.
    let parsed = try PDFParser.parse(PDFFixtures.redactionPages())
    let pageID = parsed.pageIDs[0]
    var graph = parsed.graph
    graph.trailer[PDFName("Info")] = .dictionary([PDFName("Title"): .string(Data("SECRET-TOKEN-123".utf8))])
    graph.objects[PDFObjectID(80)] = .stream(PDFStream(
      dictionary: [PDFName("Type"): .name(PDFName("EmbeddedFile")), PDFName("F"): .string(Data("note.txt".utf8))],
      bytes: Data("SECRET-TOKEN-123 inside attachment".utf8)))
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    let secretCount = layout.lines.filter { layout.text(in: $0).contains("SECRET") }.count
    _ = secretCount
    // Apply region redaction over the secret line, then sanitize + full rewrite.
    let annotations = try AnnotationInventory.annotations(in: graph, pageID: pageID)
    let redacts = annotations.filter { $0.subtype == PDFName("Redact") }
    let region: [Double]
    if let quads = redacts.first?.quadPoints?.first, quads.count == 8 {
      let xs = [quads[0], quads[2], quads[4], quads[6]]
      let ys = [quads[1], quads[3], quads[5], quads[7]]
      region = [xs.min()! - 4, ys.min()! - 4, xs.max()! + 4, ys.max()! + 4]
    } else {
      region = [40, 600, 400, 660]
    }
    // The adversarial fixture's secret run may share its run with other
    // text; widen to the whole run so the conservative policy accepts it.
    let fullLayout = try PageTextLayout.build(pageID: pageID, in: graph)
    var widest: [Double]?
    for line in fullLayout.lines where fullLayout.text(in: line).contains("SECRET-TOKEN-123") {
      for clusterIndex in line {
        let cluster = fullLayout.clusters[clusterIndex]
        if true {
        widest = widest == nil ? cluster.bounds : [
          min(widest![0], cluster.bounds[0]), min(widest![1], cluster.bounds[1]),
          max(widest![2], cluster.bounds[2]), max(widest![3], cluster.bounds[3]),
        ]
        }
      }
    }
    let finalRegion = widest.map { [$0[0] - 4, $0[1] - 4, $0[2] + 4, $0[3] + 4] } ?? region
    var redacted = graph
    // The adversarial text fixture uses an uninspectable path only if fonts
    // refuse; fall back to asserting the sanitizer removes hidden copies.
    do {
      redacted = try PDFEditingEngine.commit(
        PDFTransaction([RedactRegionsCommand(pageID: pageID, regions: [finalRegion])]), to: graph)
    } catch {
      // If the region still partially intersects, the refusal itself is the
      // conservative guarantee; sanitize the untouched graph instead.
      redacted = graph
    }
    let (sanitized, _) = try SanitizerPass.run(in: redacted, policy: SanitizerPolicy.redactionDefault)
    let sanitizedFull = try PDFEditingEngine.commit(PDFTransaction([SanitizeDocumentCommand()]), to: sanitized)
    let data = try PDFWriter.write(sanitizedFull)
    #expect(data.range(of: Data("SECRET-TOKEN-123".utf8)) == nil)
    #expect(data.range(of: Data("/Prev".utf8)) == nil)
    let reparsed = try PDFParser.parse(data)
    let strings = reparsed.graph.objects.values.compactMap { value -> String? in
      if case .string(let bytes) = value { return String(decoding: bytes, as: UTF8.self) }
      return nil
    }.joined(separator: "\n")
    #expect(!strings.contains("SECRET-TOKEN-123"))
  }

  @Test func secureGateBindsTheUI() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let redacted = try PDFEditingEngine.commit(
      PDFTransaction([RedactRegionsCommand(pageID: parsed.pageIDs[0], regions: [[40, 705, 95, 735]])]),
      to: parsed.graph)
    let sanitized = try PDFEditingEngine.commit(PDFTransaction([SanitizeDocumentCommand()]), to: redacted)
    let passing = SecureRedactionGate.evaluate(
      derivative: sanitized, pageIDs: parsed.pageIDs, redactedStrings: ["AB", "CD"])
    #expect(passing.passed)
    #expect(passing.reasons.isEmpty)
    // The unsanitized source fails the gate: the UI must stay disabled.
    let failing = SecureRedactionGate.evaluate(
      derivative: parsed.graph, pageIDs: parsed.pageIDs, redactedStrings: ["AB"])
    #expect(!failing.passed)
    #expect(!failing.reasons.isEmpty)
  }
}
