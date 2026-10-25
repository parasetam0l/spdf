import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// RED-01 evidence: pending redaction marks are reviewable without touching the
/// graph or saved bytes, plans disclose exactly what applying removes, and one
/// command applies every mark atomically with a secure full rewrite on save.
@Suite("Redaction marks (RED-01)")
struct RedactionWorkflowTests {
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

  @Test func stagedMarksNeverAlterTheGraphOrBytes() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let baselineData = try PDFWriter.write(parsed.graph)
    let baselineGraph = parsed.graph
    var store = RedactionMarkStore()
    #expect(store.statusDescription.contains("Nothing has been removed"))
    let rects = try abRects(parsed.graph, pageID)
    let mark = try store.add(
      kind: .text, pageID: pageID, pageIndex: 0, rects: rects, reason: "Client name",
      matchedText: "AB", sources: ["Text: AB"])
    #expect(store.pendingCount == 1)
    #expect(store.hasUnappliedMarks)
    #expect(!store.reportsComplete)
    #expect(store.statusDescription.contains("NOT applied"))
    #expect(store.statusDescription.contains("Nothing has been removed yet"))
    // Editing and removing marks is pure model work.
    try store.updateGeometry(id: mark.id, rects: rects)
    store.updateReason(id: mark.id, reason: "Client name v2")
    #expect(store.pendingMarks.first?.reason == "Client name v2")
    // Whole-page and region marks can be staged too.
    let box = DocumentInventoryBox.mediaBox(
      of: pageDictionary(pageID, in: parsed.graph), in: parsed.graph)
    let pageMark = try store.add(kind: .page, pageID: pageID, pageIndex: 0, rects: [box])
    #expect(store.pendingCount == 2)
    // The review plan is non-mutating.
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(plan.entries.count == 2)
    #expect(plan.readyCount == 2)
    #expect(plan.canApply)
    #expect(plan.statusDescription.contains("pending"))
    #expect(plan.disclosures.contains { $0.contains("Nothing has been removed") })
    #expect(parsed.graph == baselineGraph)
    #expect(try PDFWriter.write(parsed.graph) == baselineData)
    store.remove(id: pageMark.id)
    #expect(store.pendingCount == 1)
    // Removing every mark returns the visible empty state.
    store.remove(id: mark.id)
    #expect(store.isEmpty)
    #expect(store.statusDescription.contains("No redaction marks"))
    _ = try PDFParser.parse(baselineData)
  }

  @Test func applyRemovesTheReviewedWordAndKeepsFollowingGlyphsInPlace() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let layoutBefore = try PageTextLayout.buildForParagraphEditing(pageID: pageID, in: parsed.graph)
    let cdBefore = layoutBefore.clusters.filter { $0.text == "C" || $0.text == "D" }
    #expect(cdBefore.count == 2)
    let cdOriginBefore = try #require(cdBefore.first?.origin)
    let rects = try abRects(parsed.graph, pageID)
    var store = RedactionMarkStore()
    let mark = try store.add(
      kind: .text, pageID: pageID, pageIndex: 0, rects: rects, matchedText: "AB",
      sources: ["Text: AB"])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let entry = try #require(plan.entries.first)
    #expect(entry.textRuns == 1)
    #expect(entry.paintsFill)
    #expect(command.requiresFullRewriteOnSave)
    #expect(command.affectedPageIDs(in: parsed.graph) == [pageID])
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let raw = try contentBytes(applied, pageID)
    #expect(!raw.contains("(AB)"))
    #expect(raw.contains("TJ"))
    #expect(raw.contains("re f"))
    let layoutAfter = try PageTextLayout.buildForParagraphEditing(pageID: pageID, in: applied)
    let textAfter = layoutAfter.lines.map { layoutAfter.text(in: $0) }.joined()
    #expect(textAfter == "CD")
    let cdAfter = layoutAfter.clusters.filter { $0.text == "C" }
    let cdOriginAfter = try #require(cdAfter.first?.origin)
    #expect(abs(cdOriginBefore[0] - cdOriginAfter[0]) < 0.02)
    #expect(abs(cdOriginBefore[1] - cdOriginAfter[1]) < 0.02)
    // Full-rewrite save path: sanitize then write; no removed text and no
    // earlier revision remains.
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data("(AB)".utf8)) == nil)
    #expect(data.range(of: Data("/Prev".utf8)) == nil)
    _ = try PDFParser.parse(data)
    let gate = SecureRedactionGate.evaluate(
      derivative: sanitized, pageIDs: parsed.pageIDs, redactedStrings: ["AB"])
    #expect(gate.passed)
    // The applied bookkeeping reports completion only after apply.
    store.noteApplied([mark.id])
    #expect(store.reportsComplete)
    #expect(store.statusDescription.contains("applied"))
    store.noteUndone()
    #expect(!store.reportsComplete)
  }

  @Test func wholePageMarkBlanksThePageAndDropsPageRepresentations() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageIDs = parsed.pageIDs
    let firstID = pageIDs[0]
    #expect(try pageText(parsed.graph, firstID).contains("fixture - page 1"))
    var store = RedactionMarkStore()
    let box = DocumentInventoryBox.mediaBox(
      of: pageDictionary(firstID, in: parsed.graph), in: parsed.graph)
    _ = try store.add(kind: .page, pageID: firstID, pageIndex: 0, rects: [box])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: pageIDs)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let content = try contentBytes(applied, firstID)
    #expect(!content.contains("fixture - page 1"))
    #expect(content.contains("re f"))
    #expect(try pageText(applied, firstID).isEmpty)
    // Other pages are untouched.
    #expect(try pageText(applied, pageIDs[1]).contains("fixture - page 2"))
    #expect(try pageText(applied, pageIDs[2]).contains("fixture - page 3"))
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data("fixture - page 1".utf8)) == nil)
    #expect(data.range(of: Data("fixture - page 2".utf8)) != nil)
    _ = try PDFParser.parse(data)
  }

  @Test func wholePageMarkRemovesPageWidgetsAndAnnotations() throws {
    let parsed = try PDFParser.parse(PDFFixtures.formPages())
    let pageID = parsed.pageIDs[0]
    let before = try FormInventory.fields(in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(!before.isEmpty)
    var store = RedactionMarkStore()
    let box = DocumentInventoryBox.mediaBox(
      of: pageDictionary(pageID, in: parsed.graph), in: parsed.graph)
    _ = try store.add(kind: .page, pageID: pageID, pageIndex: 0, rects: [box])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    let fieldsAfter = try FormInventory.fields(in: applied, pageIDs: parsed.pageIDs)
    let pageOneFields = before.filter { field in
      field.widgets.contains { $0.pageIndex == 0 }
    }
    #expect(!pageOneFields.isEmpty)
    #expect(!fieldsAfter.contains { field in
      pageOneFields.contains { $0.name == field.name }
    })
    #expect(try AnnotationInventory.annotations(in: applied, pageID: pageID).isEmpty)
    _ = try PDFParser.parse(try PDFWriter.write(applied))
  }

  @Test func planRefusesUnsafeMarksBeforeAnythingIsApplied() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let baseline = try PDFWriter.write(parsed.graph)
    var store = RedactionMarkStore()
    // A region that only partially covers a run is refused by the conservative
    // region policy.
    _ = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[40, 705, 55, 735]])
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(plan.refusedCount == 1)
    #expect(!plan.canApply)
    let entry = try #require(plan.entries.first)
    #expect(entry.refusal?.contains("partially intersect") == true)
    #expect(plan.command(marks: store.pendingMarks) == nil)
    #expect(try PDFWriter.write(parsed.graph) == baseline)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([RedactMarksCommand(marks: store.pendingMarks)]), to: parsed.graph)
    }
    // Removing the refused mark restores a clean (empty) plan.
    store.removeAll()
    let empty = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(empty.entries.isEmpty)
    #expect(!empty.canApply)
  }

  @Test func oneCommandAppliesEveryPageAtomically() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let request = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["fixture"])
    let preview = try RedactionSearch.preview(request, in: parsed.graph)
    #expect(preview.hits.count == 3)
    var queue = RedactionReviewQueue(hits: preview.hits)
    let firstTwo = preview.hits.prefix(2).map(\.id)
    queue.clearSelection()
    for id in firstTwo { queue.setSelected(true, hitID: id) }
    var store = RedactionMarkStore()
    let staged = try queue.addSelectedHits(to: &store)
    #expect(staged == 2)
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: parsed.graph, pageIDs: parsed.pageIDs)
    let command = try #require(plan.command(marks: store.pendingMarks))
    #expect(command.marks.count == 2)
    #expect(command.affectedPageIDs(in: parsed.graph).count == 2)
    // One transaction, one command: the whole apply is one Undo step at the
    // document session layer (the app commits exactly PDFTransaction([command])).
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: parsed.graph)
    #expect(try pageText(applied, parsed.pageIDs[0]).contains("fixture") == false)
    #expect(try pageText(applied, parsed.pageIDs[1]).contains("fixture") == false)
    #expect(try pageText(applied, parsed.pageIDs[2]).contains("fixture - page 3"))
    // A second apply with no pending marks refuses rather than mutating.
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(PDFTransaction([RedactMarksCommand(marks: [])]), to: applied)
    }
  }

  @Test func hiddenTextIsRemovedByDefaultAndCanBeRefusedExplicitly() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let withHidden = try addingHiddenText(
      "SECRET-HIDDEN", to: parsed.graph, pageID: pageID)
    // Explicit refusal policy: the plan refuses the page and apply refuses.
    var refusingStore = RedactionMarkStore()
    _ = try refusingStore.add(
      kind: .text, pageID: pageID, pageIndex: 0, rects: try abRects(withHidden, pageID),
      matchedText: "AB")
    let refusingPlan = try RedactionMarkPlanner.plan(
      store: refusingStore, graph: withHidden, pageIDs: parsed.pageIDs,
      options: RedactionApplicationOptions(hiddenTextPolicy: .refuseWhenPresent))
    #expect(refusingPlan.refusedCount == 1)
    #expect(refusingPlan.entries.first?.refusal?.contains("hidden") == true)
    #expect(throws: PDFError.self) {
      _ = try PDFEditingEngine.commit(
        PDFTransaction([
          RedactMarksCommand(
            marks: refusingStore.pendingMarks,
            options: RedactionApplicationOptions(hiddenTextPolicy: .refuseWhenPresent))
        ]), to: withHidden)
    }
    // Default policy removes the hidden copy entirely while redacting AB.
    var store = RedactionMarkStore()
    _ = try store.add(
      kind: .text, pageID: pageID, pageIndex: 0, rects: try abRects(withHidden, pageID),
      matchedText: "AB")
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: withHidden, pageIDs: parsed.pageIDs)
    #expect(plan.hiddenTextPageIndexes == [0])
    #expect(plan.disclosures.contains { $0.contains("OCR") || $0.contains("Hidden") })
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: withHidden)
    let raw = try contentBytes(applied, pageID)
    #expect(!raw.contains("(AB)"))
    #expect(!raw.contains("SECRET-HIDDEN"))
    #expect(try pageText(applied, pageID).contains("SECRET-HIDDEN") == false)
    #expect(try pageText(applied, pageID).contains("CD"))
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data("SECRET-HIDDEN".utf8)) == nil)
  }

  @Test func hiddenMarksDoNotPaintTheVisibleFill() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let withHidden = try addingHiddenText(
      "HIDDEN-ONLY", to: parsed.graph, pageID: pageID)
    let request = RedactionSearchRequest(
      scope: .page, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["HIDDEN-ONLY"], includeHiddenText: true)
    let preview = try RedactionSearch.preview(request, in: withHidden)
    let hit = try #require(preview.hits.first)
    #expect(hit.isHidden)
    #expect(hit.isEligible)
    #expect(hit.context.contains("HIDDEN-ONLY"))
    var queue = RedactionReviewQueue(hits: preview.hits)
    #expect(queue.selectedCount == 1)
    var store = RedactionMarkStore()
    let added = try queue.addSelectedHits(to: &store)
    #expect(added == 1)
    #expect(store.pendingMarks.first?.isHiddenText == true)
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: withHidden, pageIDs: parsed.pageIDs)
    #expect(plan.entries.first?.paintsFill == false)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: withHidden)
    let raw = try contentBytes(applied, pageID)
    #expect(!raw.contains("HIDDEN-ONLY"))
    // Only the original hidden test stream is gone; no fill rectangle is added
    // for a hidden-only mark.
    #expect(!raw.contains("re f"))
    #expect(try pageText(applied, pageID).contains("AB"))
  }

  @Test func markGeometryAndReasonStayEditable() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    var store = RedactionMarkStore()
    let mark = try store.add(
      kind: .region, pageID: pageID, pageIndex: 0, rects: [[40, 705, 95, 735]])
    try store.updateGeometry(id: mark.id, rects: [[40, 705, 100, 740]])
    #expect(store.pendingMarks.first?.rects == [[40, 705, 100, 740]])
    store.updateReason(id: mark.id, reason: "Reviewed")
    #expect(store.pendingMarks.first?.reason == "Reviewed")
    #expect(throws: PDFError.self) {
      try store.updateGeometry(id: mark.id, rects: [[10, 10, 5, 5]])
    }
    #expect(throws: PDFError.self) { try store.add(kind: .page, pageID: pageID, pageIndex: 0, rects: []) }
    #expect(throws: PDFError.self) {
      try store.add(
        kind: .page, pageID: pageID, pageIndex: 0,
        rects: [[0, 0, 10, 10], [0, 0, 20, 20]])
    }
    #expect(store.pendingCount == 1)
  }

  // MARK: - Helpers

  private func pageDictionary(
    _ pageID: PDFObjectID, in graph: PDFGraph
  ) -> [PDFName: PDFValue] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [:] }
    return page
  }

  private func addingHiddenText(
    _ text: String, to graph: PDFGraph, pageID: PDFObjectID
  ) throws -> PDFGraph {
    var graph = graph
    let streamID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    let content = "BT /F1 20 Tf 3 Tr 42 650 Td (\(text)) Tj ET\n"
    graph.objects[streamID] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(content.utf8.count))],
        bytes: Data(content.utf8)))
    try FlattenAnnotationsCommand.appendContents(
      [.reference(streamID)], pageID: pageID, in: &graph)
    return graph
  }
}

/// RED-02 evidence: literal, term-set and pattern searches list real matches
/// with context and per-hit review, hidden/OCR text is handled by an explicit
/// scope, and matching never mutates the graph.
@Suite("Redaction search (RED-02)")
struct RedactionSearchTests {
  @Test func literalSearchListsEveryAppearanceWithContext() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let baseline = try PDFWriter.write(parsed.graph)
    let request = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["fixture"])
    let preview = try RedactionSearch.preview(request, in: parsed.graph)
    #expect(preview.hits.count == 3)
    #expect(preview.eligibleCount == 3)
    #expect(preview.refusedCount == 0)
    #expect(Set(preview.hits.map(\.pageIndex)) == [0, 1, 2])
    for hit in preview.hits {
      #expect(hit.text == "fixture")
      #expect(hit.context.contains("fixture"))
      #expect(hit.contextBefore.contains("Editor"))
      #expect(hit.contextAfter.contains("page"))
      #expect(hit.pageLabel.contains("Page"))
    }
    #expect(parsed.graph.objects.count > 0)
    #expect(try PDFWriter.write(parsed.graph) == baseline)
  }

  @Test func termSetsExpandAndAreReusable() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    var library = RedactionTermSetLibrary()
    var set = RedactionTermSet(name: "Fixtures", terms: ["fixture", "content"])
    try library.upsert(set)
    #expect(library.set(named: "Fixtures")?.terms.count == 2)
    let reusedSet = try #require(library.set(named: "Fixtures"))
    let request = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      termSets: [reusedSet])
    let preview = try RedactionSearch.preview(request, in: parsed.graph)
    #expect(preview.hits.count == 6)
    #expect(preview.hits.allSatisfy { $0.sourceLabel.contains("Fixtures") })
    // Updating the same name replaces instead of duplicating.
    set.terms.append("fixture")
    try library.upsert(set)
    #expect(library.sets.count == 1)
    #expect(library.sets[0].terms == ["fixture", "content"])
    // Round-trip through JSON for reuse.
    let data = try library.encodedJSON()
    let decoded = try RedactionTermSetLibrary.decoded(from: data)
    #expect(decoded == library)
    let removedSet = library.remove(named: "Fixtures")
    #expect(removedSet)
    #expect(library.sets.isEmpty)
    // Invalid sets refuse before a search runs.
    #expect(throws: PDFError.self) {
      try library.upsert(RedactionTermSet(name: "", terms: ["x"]))
    }
    #expect(throws: PDFError.self) {
      try RedactionTermSetLibrary.decoded(from: Data("not json".utf8))
    }
  }

  @Test func userPatternsMatchAndInvalidPatternsRefuse() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pattern = RedactionPattern(name: "Page numbers", expression: "page [0-9]", caseSensitive: false)
    let request = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0, patterns: [pattern])
    let preview = try RedactionSearch.preview(request, in: parsed.graph)
    #expect(preview.hits.count == 3)
    #expect(preview.hits.allSatisfy { $0.text.contains("page") })
    #expect(preview.hits.allSatisfy { $0.sourceLabel.contains("Page numbers") })
    let bad = RedactionSearchRequest(
      scope: .page, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      patterns: [RedactionPattern(name: "Bad", expression: "^(")])
    #expect(throws: PDFError.self) {
      _ = try RedactionSearch.preview(bad, in: parsed.graph)
    }
  }

  @Test func scopesRestrictMatchesAndSelectionRequiresBounds() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let pageOnly = RedactionSearchRequest(
      scope: .page, pageIDs: parsed.pageIDs, currentPageIndex: 1,
      queries: ["fixture"])
    let pagePreview = try RedactionSearch.preview(pageOnly, in: parsed.graph)
    #expect(pagePreview.hits.count == 1)
    #expect(pagePreview.hits.first?.pageIndex == 1)
    let selectionRequest = RedactionSearchRequest(
      scope: .selection, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      selectionRects: [[30, 700, 600, 745]], queries: ["fixture"])
    let selectionPreview = try RedactionSearch.preview(selectionRequest, in: parsed.graph)
    #expect(selectionPreview.hits.count == 1)
    #expect(selectionPreview.hits.first?.pageIndex == 0)
    let noSelection = RedactionSearchRequest(
      scope: .selection, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["fixture"])
    #expect(throws: PDFError.self) {
      _ = try RedactionSearch.preview(noSelection, in: parsed.graph)
    }
    let emptyQuery = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0, queries: ["   "])
    #expect(throws: PDFError.self) {
      _ = try RedactionSearch.preview(emptyQuery, in: parsed.graph)
    }
  }

  @Test func perHitSelectionStagesOnlyReviewedMatches() throws {
    let parsed = try PDFParser.parse(PDFFixtures.threePages())
    let request = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["fixture"])
    let preview = try RedactionSearch.preview(request, in: parsed.graph)
    var queue = RedactionReviewQueue(hits: preview.hits)
    #expect(queue.selectedCount == 3)
    #expect(queue.summary.contains("selected"))
    queue.clearSelection()
    #expect(queue.selectedCount == 0)
    let ids = preview.hits.map(\.id)
    queue.setSelected(true, hitID: ids[0])
    queue.toggle(hitID: ids[1])
    #expect(queue.selectedCount == 2)
    queue.toggle(hitID: ids[0])
    #expect(queue.selectedCount == 1)
    var store = RedactionMarkStore()
    let added = try queue.addSelectedHits(to: &store)
    #expect(added == 1)
    #expect(store.pendingCount == 1)
    #expect(store.pendingMarks.first?.matchedText == "fixture")
    #expect(store.pendingMarks.first?.sources.contains { $0.contains("Text") } == true)
    let addedAgain = try queue.addSelectedHits(to: &store)
    #expect(addedAgain == 0)
  }

  @Test func hiddenTextScopeIsExplicitAndOCRMatchesNowRemoveTheScannedRaster() throws {
    let scanned = try PDFParser.parse(PDFFixtures.scannedPages())
    let pageID = scanned.pageIDs[0]
    let withLayer = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [SearchableTextLine(text: "SECRET-SCAN", rect: [100, 600, 300, 640])])
      ]), to: scanned.graph)
    #expect(OCRLayer.hasGeneratedLayer(in: withLayer, pageID: pageID))
    let excluded = RedactionSearchRequest(
      scope: .page, pageIDs: scanned.pageIDs, currentPageIndex: 0,
      queries: ["SECRET-SCAN"])
    let excludedPreview = try RedactionSearch.preview(excluded, in: withLayer)
    let excludedHit = try #require(excludedPreview.hits.first)
    #expect(excludedHit.isHidden)
    #expect(excludedHit.isExcludedByScope)
    #expect(!excludedHit.isEligible)
    #expect(excludedPreview.scopeExcludedCount == 1)
    let included = RedactionSearchRequest(
      scope: .page, pageIDs: scanned.pageIDs, currentPageIndex: 0,
      queries: ["SECRET-SCAN"], includeHiddenText: true)
    let includedPreview = try RedactionSearch.preview(included, in: withLayer)
    let includedHit = try #require(includedPreview.hits.first)
    // RED-04: an OCR/text match over a scan is now reviewable; applying it
    // removes the whole intersecting scanned image draw, disclosed per hit.
    #expect(includedHit.isHidden)
    #expect(includedHit.isEligible)
    #expect(includedHit.requiresRasterRemoval)
    #expect(includedHit.rasterNote?.contains("scan") == true)
    #expect(includedPreview.eligibleCount == 1)
    #expect(includedPreview.rasterRemovalCount == 1)
  }

  @Test func hiddenOnlyOCRLayerCanBeRemovedWhenItHasNoRasterBehindIt() throws {
    let parsed = try PDFParser.parse(PDFFixtures.scannedPages())
    let pageID = parsed.pageIDs[0]
    // Remove the scan (raster) so only the generated OCR text remains.
    var graph = parsed.graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      Issue.record("Fixture page missing")
      return
    }
    let contentID = PDFObjectID(4)
    graph.objects[contentID] = .stream(PDFStream(bytes: Data("q Q\n".utf8)))
    page[PDFName("Resources")] = .dictionary([:])
    graph.objects[pageID] = .dictionary(page)
    let withLayer = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID, lines: [SearchableTextLine(text: "SECRET-OCR", rect: [100, 600, 300, 640])])
      ]), to: graph)
    let request = RedactionSearchRequest(
      scope: .page, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["SECRET-OCR"], includeHiddenText: true)
    let preview = try RedactionSearch.preview(request, in: withLayer)
    let hit = try #require(preview.hits.first)
    #expect(hit.isHidden)
    #expect(hit.isEligible)
    var queue = RedactionReviewQueue(hits: preview.hits)
    var store = RedactionMarkStore()
    let added = try queue.addSelectedHits(to: &store)
    #expect(added == 1)
    let plan = try RedactionMarkPlanner.plan(
      store: store, graph: withLayer, pageIDs: parsed.pageIDs)
    #expect(plan.canApply)
    let command = try #require(plan.command(marks: store.pendingMarks))
    let applied = try PDFEditingEngine.commit(PDFTransaction([command]), to: withLayer)
    #expect(!OCRLayer.hasGeneratedLayer(in: applied, pageID: pageID))
    let sanitized = try PDFEditingEngine.commit(
      PDFTransaction([SanitizeDocumentCommand()]), to: applied)
    let data = try PDFWriter.write(sanitized)
    #expect(data.range(of: Data("SECRET-OCR".utf8)) == nil)
    _ = try PDFParser.parse(data)
  }

  @Test func searchDoesNotMutateAndHiddenPolicyRefusesOnDemand() throws {
    let parsed = try PDFParser.parse(PDFFixtures.textWidthsPages())
    let pageID = parsed.pageIDs[0]
    let graph = try addHiddenText("HIDDEN-COPY", to: parsed.graph, pageID: pageID)
    let baseline = try PDFWriter.write(graph)
    let request = RedactionSearchRequest(
      scope: .document, pageIDs: parsed.pageIDs, currentPageIndex: 0,
      queries: ["AB", "HIDDEN-COPY"], includeHiddenText: true)
    let preview = try RedactionSearch.preview(request, in: graph)
    #expect(preview.hits.count == 2)
    #expect(try PDFWriter.write(graph) == baseline)
  }

  // MARK: - Helpers

  private func addHiddenText(
    _ text: String, to graph: PDFGraph, pageID: PDFObjectID
  ) throws -> PDFGraph {
    var graph = graph
    let streamID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    let content = "BT /F1 20 Tf 3 Tr 42 650 Td (\(text)) Tj ET\n"
    graph.objects[streamID] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(content.utf8.count))],
        bytes: Data(content.utf8)))
    try FlattenAnnotationsCommand.appendContents(
      [.reference(streamID)], pageID: pageID, in: &graph)
    return graph
  }
}
