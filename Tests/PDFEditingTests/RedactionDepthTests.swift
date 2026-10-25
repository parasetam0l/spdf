import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// RED-03/RED-04 evidence: reviewed overlay text/reason codes/colors are paint
/// only and exactly match the plan; repeated-page regions stage one range; the
/// broadened removal profile safely removes whole image draws (including masked
/// and scanned images), fully covered reusable-form invocations and fully
/// covered vector paint, and refuses what it cannot isolate.
@Suite("Redaction depth (RED-03/RED-04)")
struct RedactionDepthTests {
  private func contentBytes(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    let content = try PageContent.load(pageID: pageID, in: graph)
    return String(decoding: content.segments.flatMap(\.decoded), as: UTF8.self)
  }

  private func pageText(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> String {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    return layout.lines.map { layout.text(in: $0) }.joined(separator: "\n")
  }

  private func abRects(_ graph: PDFGraph, _ pageID: PDFObjectID) throws -> [[Double]] {
    let layout = try PageTextLayout.buildForParagraphEditing(pageID: pageID, in: graph)
    let matches = TextSearch.search(query: "AB", in: layout)
    let match = try #require(matches.first)
    return layout.clusters[match.clusterRange].map(\.bounds)
  }

  private func replacePageContent(
    _ graph: PDFGraph, pageID: PDFObjectID, content: String
  ) -> PDFGraph {
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else { return graph }
    let id = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[id] = .stream(PDFStream(bytes: Data(content.utf8)))
    page[PDFName("Contents")] = .reference(id)
    graph.objects[pageID] = .dictionary(page)
    return graph
  }

  private func overlay(
    text: String? = "REDACTED", reason: String? = "privileged", color: [Double] = [0, 0, 0]
  ) -> RedactionOverlayOptions {
    RedactionOverlayOptions(
      paintsOverlay: true, fillColor: color, textColor: [1, 1, 1],
      replacementText: text,
      reasonCode: reason.flatMap { RedactionReasonCode.preset(named: $0) },
      showsReasonCode: reason != nil, fontSize: 8)
  }

  // MARK: RED-03 overlay and repeated regions

  @Test func overlayPaintsExactlyTheReviewedTextAndReasonCode() throws {
    let parsed = try PDFParser.parse(PDFFixtures.maskedImagePages())
    let pageID = parsed.pageIDs[0]
    var store = RedactionMarkStore()
    let mark = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[200, 200, 300, 300]])
    let options = overlay(reason: "privileged", color: [0.7, 0, 0])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs, overlay: options)
    let entry = try #require(plan.entries.first)
    #expect(entry.overlayText == ["REDACTED", "Privileged"])
    #expect(plan.overlay == options)
    #expect(plan.disclosures.contains { $0.contains("overlay") })
    #expect(plan.disclosures.contains { $0.contains("removed whether") })
    let command = try #require(plan.command(marks: store.pendingMarks))
    #expect(command.overlay == options)
    #expect(command.requiresFullRewriteOnSave)
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let raw = try contentBytes(applied, pageID)
    // The image draw under the region is removed and the overlay fill/text are
    // painted exactly as the plan listed.
    #expect(!raw.contains("/Mask1 Do"))
    #expect(raw.contains("re f"))
    #expect(raw.contains("(REDACTED)"))
    #expect(raw.contains("(Privileged)"))
    let text = try pageText(applied, pageID)
    #expect(text.contains("REDACTED"))
    #expect(text.contains("Privileged"))
    for line in entry.overlayText {
      #expect(text.contains(line))
    }
    #expect(mark.kind == .region)
    // Sanitize + write keeps the overlay and prunes the removed image object.
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    let data = try PDFWriter.write(sanitized)
    let reopened = try PDFParser.parse(data)
    let reopenedText = try pageText(reopened.graph, reopened.pageIDs[0])
    #expect(reopenedText.contains("REDACTED"))
    #expect(reopenedText.contains("Privileged"))
  }

  @Test func overlayIsSeparateFromRemovalAndCanBeDisabledOrMadeFillOnly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let rects = try abRects(parsed.graph, pageID)
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .text, pageID: pageID, pageIndex: 0, rects: rects, matchedText: "AB")
    // No overlay paint at all: the removal still happens.
    let none = RedactionOverlayOptions(paintsOverlay: false)
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs, overlay: none)
    let entry = try #require(plan.entries.first)
    #expect(entry.overlayText.isEmpty)
    #expect(!entry.paintsFill)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let raw = try contentBytes(applied, pageID)
    #expect(!raw.contains("(AB)"))
    #expect(!raw.contains("re f"))
    #expect(!(try pageText(applied, pageID)).contains("REDACTED"))
    #expect(try pageText(applied, pageID) == "CD")
    // The RED-01 default stays fill-only: no text overlay unless requested.
    let fillOnlyCommand = RedactMarksCommand(
      marks: store.pendingMarks, options: RedactionApplicationOptions())
    let fillOnly = try PDFEditingEngine.commit(
      PDFTransaction([fillOnlyCommand]), to: parsed.graph)
    let fillRaw = try contentBytes(fillOnly, pageID)
    #expect(fillRaw.contains("re f"))
    #expect(!fillRaw.contains("REDACTED"))
  }

  @Test func overlayValidationRefusesUnprintableOrUnfittingText() throws {
    #expect(throws: PDFError.self) {
      try RedactionOverlayOptions(replacementText: "REDACTED", fontSize: 1).validate()
    }
    #expect(throws: PDFError.self) {
      try RedactionOverlayOptions(fillColor: [1.4, 0, 0]).validate()
    }
    #expect(throws: PDFError.self) {
      try RedactionOverlayOptions(replacementText: "redacted ✓").validate()
    }
    #expect(throws: PDFError.self) {
      try RedactionReasonCode(code: "custom", label: String(repeating: "x", count: 81))
        .validate()
    }
    #expect(RedactionReasonCode.preset(named: "privileged")?.label == "Privileged")
    // A short text mark cannot fit a long replacement string: the plan refuses
    // before apply instead of partially painting.
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[80, 600, 90, 606]])
    let long = RedactionOverlayOptions(
      replacementText: "THIS REPLACEMENT TEXT IS FAR TOO LONG FOR THE MARK", fontSize: 30)
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs, overlay: long)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal?.contains("does not fit") == true)
    #expect(!plan.canApply)
  }

  @Test func repeatedPageRegionsStageOneRangeAndApplyInOneTransaction() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageIDs = parsed.pageIDs
    var store = RedactionMarkStore()
    let marks = try store.addRepeatedRegion(
      pageIDs: pageIDs, pageRange: "1-2", rects: [[40, 40, 260, 90]])
    #expect(marks.count == 2)
    #expect(store.pendingCount == 2)
    #expect(Set(marks.map(\.pageID)) == Set([pageIDs[0], pageIDs[1]]))
    #expect(throws: PDFError.self) {
      _ = try store.addRepeatedRegion(
        pageIDs: pageIDs, pageRange: "9-12", rects: [[0, 0, 10, 10]])
    }
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: pageIDs,
      overlay: overlay(text: "REDACTED", reason: nil))
    #expect(plan.readyCount == 2)
    #expect(plan.canApply)
    let command = try #require(plan.command(marks: store.pendingMarks))
    #expect(command.affectedPageIDs(in: parsed.graph) == [pageIDs[0], pageIDs[1]])
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    for pageID in [pageIDs[0], pageIDs[1]] {
      #expect(try pageText(applied, pageID).contains("REDACTED"))
    }
    // The third page was not marked and keeps its original text.
    #expect(try pageText(applied, pageIDs[2]).contains("fixture - page 3"))
    // The two marks were applied by one command (one transaction = one Undo
    // at the session layer; the session-level invariant is covered by the
    // RED-01 workflow tests).
    #expect(command.affectedPageIDs(in: parsed.graph).count == 2)
  }

  // MARK: RED-04 broadened removal

  @Test func maskedAndScannedImageDrawsAreRemovedWholeAndTheirObjectsPruned() throws {
    let masked = try PDFParser.parse(PDFFixtures.maskedImagePages())
    let maskedPage = masked.pageIDs[0]
    // The old region policy refused masked image draws; the broadened profile
    // removes the whole draw (mask and soft mask travel with it).
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .region, pageID: maskedPage, pageIndex: 0,
      rects: [[200, 200, 300, 300], [200, 400, 300, 500]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: masked.graph, pageIDs: masked.pageIDs)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal == nil)
    #expect(entry.images == 2)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: masked.graph)
    #expect(try PDFImageInventory.images(in: applied, pageIDs: masked.pageIDs).isEmpty)
    let raw = try contentBytes(applied, maskedPage)
    #expect(!raw.contains("/Mask1 Do"))
    #expect(!raw.contains("/Photo1 Do"))
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    for objectNumber in [6, 7, 8] {
      #expect(sanitized.objects[PDFObjectID(objectNumber)] == nil)
    }

    let scanned = try PDFParser.parse(PDFFixtures.scannedPages())
    let scanPage = scanned.pageIDs[0]
    var scanStore = RedactionMarkStore()
    _ = try scanStore.add(
      kind: .region, pageID: scanPage, pageIndex: 0, rects: [[72, 72, 540, 720]])
    let scanCommand = try #require(
      try RedactionMarkPlanner.plan(
        store: scanStore, graph: scanned.graph, pageIDs: scanned.pageIDs
      ).command(marks: scanStore.pendingMarks))
    let scanApplied = try PDFEditingEngine.commit(
      PDFTransaction([scanCommand]), to: scanned.graph)
    #expect(
      try PDFImageInventory.images(in: scanApplied, pageIDs: scanned.pageIDs).isEmpty)
    let scanSanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: scanApplied)
    #expect(scanSanitized.objects[PDFObjectID(5)] == nil)
    #expect(!(try contentBytes(scanApplied, scanPage).contains("/Scan1 Do")))
  }

  @Test func aRegionOverPartOfAnImageRemovesTheWholeImageDraw() throws {
    let parsed = try PDFParser.parse(PDFFixtures.maskedImagePages())
    let pageID = parsed.pageIDs[0]
    // The region covers only a corner of the stencil-mask draw; the whole draw
    // is removed and the plan says so before apply.
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[200, 200, 240, 240]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal == nil)
    #expect(entry.notes.contains { $0.contains("Whole intersecting") || $0.contains("image") })
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let raw = try contentBytes(applied, pageID)
    #expect(!raw.contains("/Mask1 Do"))
    // The unrelated SMask image draw outside the region remains.
    #expect(raw.contains("/Photo1 Do"))
  }

  @Test func reusableFormPaintIsRemovedWhenFullyCoveredAndRefusedWhenPartial() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formXObjectPages())
    let pageID = parsed.pageIDs[0]
    let before = try ContentInterpreter.trace(pageID: pageID, in: parsed.graph)
    #expect(before.draws.filter { $0.kind == .form }.count == 2)

    // Partial coverage refuses before mutation.
    var partialStore = RedactionMarkStore()
    _ = try partialStore.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[100, 600, 150, 650]])
    let partialPlan = try RedactionMarkPlanner.plan(
      store: partialStore, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let partialEntry = try #require(partialPlan.entries.first)
    #expect(partialEntry.refusal?.contains("partially intersect reusable form") == true)
    #expect(!partialPlan.canApply)

    // A region covering one whole invocation removes exactly that draw.
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[100, 600, 200, 700]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal == nil)
    #expect(entry.images == 1)
    #expect(entry.removalItems.contains { $0.contains("form XObject") })
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let after = try ContentInterpreter.trace(pageID: pageID, in: applied)
    #expect(after.draws.filter { $0.kind == .form }.count == 1)
    let raw = try contentBytes(applied, pageID)
    #expect(raw.contains("/Fm1 Do"))
    // The form object is still reachable from the second draw and page 2.
    #expect(applied.objects[PDFObjectID(6)] != nil)
  }

  @Test func fullyCoveredVectorPaintIsRemovedAndComplexPaintRefuses() throws {
    let base = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = base.pageIDs[0]
    let vector = "0 0 0 rg q 1 0 0 1 100 100 cm 0 0 50 50 re f Q\n"
    let vectorGraph = replacePageContent(base.graph, pageID: pageID, content: vector)
    let noOverlay = RedactionOverlayOptions(paintsOverlay: false)
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[100, 100, 160, 160]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: vectorGraph, pageIDs: base.pageIDs, overlay: noOverlay)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal == nil)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: vectorGraph)
    let raw = try contentBytes(applied, pageID)
    #expect(!raw.contains("0 0 50 50 re"))
    #expect(!raw.contains(" re f"))

    // Partial coverage of the same path refuses.
    var partialStore = RedactionMarkStore()
    _ = try partialStore.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[100, 100, 120, 120]])
    let partialPlan = try RedactionMarkPlanner.plan(
      store: partialStore, graph: vectorGraph, pageIDs: base.pageIDs, overlay: noOverlay)
    #expect(
      partialPlan.entries.first?.refusal?.contains("partially intersect vector paint") == true)

    // Tiling pattern paint refuses rather than leaving partial paint.
    let pattern = "q /Pattern cs /P1 scn 0 0 50 50 re f Q\n"
    let patternGraph = replacePageContent(base.graph, pageID: pageID, content: pattern)
    var patternStore = RedactionMarkStore()
    _ = try patternStore.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[0, 0, 100, 100]])
    let patternPlan = try RedactionMarkPlanner.plan(
      store: patternStore, graph: patternGraph, pageIDs: base.pageIDs, overlay: noOverlay)
    #expect(patternPlan.entries.first?.refusal?.contains("pattern paint") == true)

    // Gradient shading refuses.
    let shading = "q 0 0 100 100 re W n 0 0 100 100 sh Q\n"
    let shadingGraph = replacePageContent(base.graph, pageID: pageID, content: shading)
    var shadingStore = RedactionMarkStore()
    _ = try shadingStore.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[10, 10, 50, 50]])
    let shadingPlan = try RedactionMarkPlanner.plan(
      store: shadingStore, graph: shadingGraph, pageIDs: base.pageIDs, overlay: noOverlay)
    #expect(shadingPlan.entries.first?.refusal?.contains("shading") == true)

    // Inline images cannot be inspected and refuse.
    let inline = "q BI /W 1 /H 1 /CS /G /BPC 8 ID \u{00} EI Q\n"
    let inlineGraph = replacePageContent(base.graph, pageID: pageID, content: inline)
    var inlineStore = RedactionMarkStore()
    _ = try inlineStore.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[0, 0, 200, 200]])
    let inlinePlan = try RedactionMarkPlanner.plan(
      store: inlineStore, graph: inlineGraph, pageIDs: base.pageIDs, overlay: noOverlay)
    #expect(inlinePlan.entries.first?.refusal?.contains("inline image") == true)
  }

  @Test func ocrTextOverAScanIsMarkableAndRemovesTheRaster() throws {
    let scanned = try PDFParser.parse(PDFFixtures.scannedPages())
    let pageID = scanned.pageIDs[0]
    let withLayer = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "SECRET-SCAN", rect: [100, 600, 300, 640])])
      ]), to: scanned.graph)
    let request = RedactionSearchRequest(
      scope: .page, pageIDs: scanned.pageIDs, currentPageIndex: 0,
      queries: ["SECRET-SCAN"], includeHiddenText: true)
    let preview = try RedactionSearch.preview(request, in: withLayer)
    let hit = try #require(preview.hits.first)
    #expect(hit.isHidden)
    #expect(hit.isEligible)
    #expect(hit.requiresRasterRemoval)
    #expect(hit.rasterNote?.contains("scan") == true)
    var queue = RedactionReviewQueue(hits: preview.hits)
    var store = RedactionMarkStore()
    #expect(try queue.addSelectedHits(to: &store) == 1)
    let mark = try #require(store.pendingMarks.first)
    #expect(mark.removesRasterPaint)
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: withLayer, pageIDs: scanned.pageIDs)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal == nil)
    #expect(entry.notes.contains { $0.contains("scan") })
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: withLayer)
    #expect(try PDFImageInventory.images(in: applied, pageIDs: scanned.pageIDs).isEmpty)
    #expect(!(try contentBytes(applied, pageID).contains("/Scan1 Do")))
    // Full rewrite prunes the scanned image object; the text layer is gone too.
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    #expect(sanitized.objects[PDFObjectID(5)] == nil)
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data("SECRET-SCAN".utf8)) == nil)
  }

  @Test func stagingAndPlanningTheBroadenedProfileNeverMutate() throws {
    let parsed = try PDFParser.parse(PDFFixtures.maskedImagePages())
    let pageID = parsed.pageIDs[0]
    let baselineGraph = parsed.graph
    let baselineData = try PDFWriter.write(parsed.graph)
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[200, 200, 300, 300]])
    _ = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(parsed.graph == baselineGraph)
    #expect(try PDFWriter.write(parsed.graph) == baselineData)
  }

}
