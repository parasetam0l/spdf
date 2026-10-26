import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// REV-05/REV-06 evidence: comparison scopes and categories, repeated-page
/// alignment audit with manual pairing, and scan/layout qualification that
/// preserves uncertainty instead of claiming fake equality.
@Suite("Comparison alignment and qualification (REV-05/06)")
struct ComparisonQualificationTests {
  private func parsed(_ data: Data) throws -> (graph: PDFGraph, source: Data) {
    let parsed = try PDFParser.parse(data)
    return (parsed.graph, data)
  }

  private func source(of graph: PDFGraph) throws -> Data {
    try PDFWriter.write(graph)
  }

  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private func evidence(
    for result: PDFComparisonResult, ratio: (Int) -> Double, tolerance: Int = 2
  ) -> [ComparisonRasterEvidence] {
    var records: [ComparisonRasterEvidence] = []
    for (ordinal, pair) in result.pageMapping.enumerated() {
      guard let left = pair.leftIndex, let right = pair.rightIndex else { continue }
      records.append(
        ComparisonRasterEvidence(
          leftPageIndex: left, rightPageIndex: right,
          changedPixelRatio: ratio(ordinal), tolerance: tolerance, width: 400, height: 520))
    }
    return records
  }

  // MARK: REV-05 scopes and categories

  @Test func scopePresetsSelectTheComparedChannels() throws {
    let base = try parsed(PDFFixtures.threePages())
    #expect(ComparisonScopePreset.matching(ComparisonScopePreset.content.options) == .content)
    // Metadata exists only in the graph, so the full scope must see it while
    // the content preset must not.
    var leftGraph = base.graph
    var rightGraph = base.graph
    leftGraph.objects[PDFObjectID(80)] = .dictionary([
      PDFName("Title"): .string(Data("Left title".utf8))
    ])
    rightGraph.objects[PDFObjectID(81)] = .dictionary([
      PDFName("Title"): .string(Data("Right title".utf8))
    ])
    leftGraph.trailer[PDFName("Info")] = .reference(PDFObjectID(80))
    rightGraph.trailer[PDFName("Info")] = .reference(PDFObjectID(81))
    let left = (leftGraph, base.source)
    let right = (rightGraph, base.source)
    let content = try PDFComparison.compare(
      left: left, right: right, options: ComparisonScopePreset.content.options)
    #expect(content.changes(kinds: [.metadataChanged]).isEmpty)
    let full = try PDFComparison.compare(
      left: left, right: right, options: ComparisonScopePreset.full.options)
    #expect(!full.changes(kinds: [.metadataChanged]).isEmpty)
    #expect(ComparisonScopePreset.content.options.scopeSummary.contains("Content"))
  }

  @Test func whitespaceScopesSeparateFormattingFromContent() throws {
    let left = try parsed(PDFFixtures.threePages())
    let pageID = try PDFPageTree.pageIDs(in: left.graph)[0]
    let rightGraph = try commit(
      [
        ReplaceTextCommand(
          pageID: pageID, runIndex: 1,
          replacement: "Original  Swift-generated   content. No personal data.")
      ], to: left.graph)
    let right = (rightGraph, left.source)
    let content = try PDFComparison.compare(
      left: left, right: right, options: ComparisonScopePreset.content.options)
    #expect(content.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    let formatting = try PDFComparison.compare(
      left: left, right: right, options: ComparisonScopePreset.formatting.options)
    #expect(!formatting.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
  }

  @Test func changeCategoriesClassifyKinds() throws {
    #expect(
      ComparisonClassification.category(of: .textChanged) == .content)
    #expect(
      ComparisonClassification.category(of: .pageReordered) == .pageStructure)
    #expect(
      ComparisonClassification.category(of: .pageBoxOrRotation) == .formatting)
    #expect(
      ComparisonClassification.category(of: .metadataChanged) == .documentStatus)
    #expect(
      ComparisonClassification.category(of: .uncertainty) == .uncertainty)
    let changes = [
      PDFComparisonChange(
        kind: .textChanged, leftPageIndex: 0, rightPageIndex: 0, summary: "text",
        leftBounds: nil, rightBounds: nil, isOCRSourced: false),
      PDFComparisonChange(
        kind: .imageMoved, leftPageIndex: 0, rightPageIndex: 0, summary: "image",
        leftBounds: nil, rightBounds: nil, isOCRSourced: false),
    ]
    #expect(changes[0].category == .content)
    #expect(changes[1].category == .formatting)
    #expect(
      ComparisonClassification.categories(in: changes) == [.content, .formatting])
  }

  // MARK: REV-05 alignment audit and manual pairing

  @Test func insertedRepeatedPageIsAuditedWithoutTextCascade() throws {
    let left = try parsed(PDFFixtures.threePages())
    let pageIDs = try PDFPageTree.pageIDs(in: left.graph)
    var rightGraph = try commit(
      [DuplicatePageCommand(pageID: pageIDs[0])], to: left.graph)
    let duplicatedPages = try PDFPageTree.pageIDs(in: rightGraph)
    rightGraph = try commit(
      [MovePagesCommand(pageIDs: [duplicatedPages[1]], toIndex: 0)], to: rightGraph)
    let right = (rightGraph, try source(of: rightGraph))
    let result = try PDFComparison.compare(left: left, right: right)
    #expect(result.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    #expect(result.changes(kinds: [.pageInserted]).count == 1)
    let audit = try PDFComparisonAlignment.audit(left: left, right: right)
    #expect(audit.rightRepeatedGroups.count == 1)
    #expect(audit.isAmbiguous)
    #expect(!audit.warnings.isEmpty)
    #expect(!audit.summaryLines.isEmpty)
    try PDFComparisonAlignment.validate(
      mapping: audit.suggestedMapping, leftPageCount: 3, rightPageCount: 4)
  }

  @Test func suggestedMappingPairsRepeatedPagesWithoutCascade() throws {
    let base = try parsed(PDFFixtures.threePages())
    let pageIDs = try PDFPageTree.pageIDs(in: base.graph)
    var repeatedGraph = try commit(
      [DuplicatePageCommand(pageID: pageIDs[0])], to: base.graph)
    let duplicatedPages = try PDFPageTree.pageIDs(in: repeatedGraph)
    repeatedGraph = try commit(
      [MovePagesCommand(pageIDs: [duplicatedPages[1]], toIndex: 3)], to: repeatedGraph)
    let left = (repeatedGraph, try source(of: repeatedGraph))
    let movedGraph = try commit(
      [MovePagesCommand(pageIDs: [duplicatedPages[1]], toIndex: 0)], to: repeatedGraph)
    let right = (movedGraph, try source(of: movedGraph))
    let automatic = try PDFComparison.compare(left: left, right: right)
    #expect(automatic.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    let audit = try PDFComparisonAlignment.audit(left: left, right: right)
    #expect(!audit.leftRepeatedGroups.isEmpty || !audit.rightRepeatedGroups.isEmpty)
    #expect(audit.ambiguousPageCount > 0)
    try PDFComparisonAlignment.validate(
      mapping: audit.suggestedMapping, leftPageCount: 4, rightPageCount: 4)
    let suggested = try PDFComparison.compare(
      left: left, right: right, mappingOverride: audit.suggestedMapping)
    #expect(suggested.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    let structural = suggested.changes(
      kinds: [.pageInserted, .pageDeleted, .pageReordered])
    #expect(structural.isEmpty)
  }

  @Test func manualPairingOverrideIsValidatedAndApplied() throws {
    let left = try parsed(PDFFixtures.threePages())
    let pageIDs = try PDFPageTree.pageIDs(in: left.graph)
    let rightGraph = try commit(
      [MovePagesCommand(pageIDs: [pageIDs[0]], toIndex: 2)], to: left.graph)
    let right = (rightGraph, try source(of: rightGraph))
    let audit = try PDFComparisonAlignment.audit(left: left, right: right)
    try PDFComparisonAlignment.validate(
      mapping: audit.suggestedMapping, leftPageCount: 3, rightPageCount: 3)
    // A user can pair the moved pages explicitly, marking the pairs as matched;
    // the override is then used verbatim and produces no reorder cascade.
    let manual = [
      PDFComparisonResult.PagePair(leftIndex: 0, rightIndex: 2, status: .matched),
      PDFComparisonResult.PagePair(leftIndex: 1, rightIndex: 0, status: .matched),
      PDFComparisonResult.PagePair(leftIndex: 2, rightIndex: 1, status: .matched),
    ]
    let overridden = try PDFComparison.compare(
      left: left, right: right, mappingOverride: manual)
    #expect(overridden.pageMapping == manual)
    #expect(overridden.changes(kinds: [.pageReordered]).isEmpty)
    #expect(overridden.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    // Duplicate or out-of-range pairings are rejected.
    var duplicate = manual
    duplicate.append(
      PDFComparisonResult.PagePair(leftIndex: 0, rightIndex: nil, status: .deleted))
    #expect(throws: PDFError.self) {
      try PDFComparisonAlignment.validate(
        mapping: duplicate, leftPageCount: 3, rightPageCount: 3)
    }
    #expect(throws: PDFError.self) {
      try PDFComparisonAlignment.validate(
        mapping: [
          PDFComparisonResult.PagePair(leftIndex: 0, rightIndex: 9, status: .matched)
        ], leftPageCount: 3, rightPageCount: 3)
    }
    #expect(throws: PDFError.self) {
      try PDFComparisonAlignment.validate(
        mapping: [
          PDFComparisonResult.PagePair(leftIndex: nil, rightIndex: nil, status: .uncertain)
        ], leftPageCount: 3, rightPageCount: 3)
    }
    // Correcting one left page releases the previously paired right page.
    let corrected = PDFComparisonAlignment.correctedMapping(
      manual, leftIndex: 0, toRightIndex: 2)
    let zeroPair = corrected.first { $0.leftIndex == 0 }
    #expect(zeroPair?.rightIndex == 2)
    #expect(corrected.filter { $0.leftIndex != 0 && $0.rightIndex == 2 }.isEmpty)
  }

  // MARK: REV-06 qualification

  @Test func scanPagesWithoutTextAreNeverReportedAsEquality() throws {
    let scan = try parsed(PDFFixtures.scannedPages())
    let result = try PDFComparison.compare(left: scan, right: scan)
    #expect(result.changes.isEmpty)
    let records = evidence(for: result) { _ in 0 }
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: scan, right: scan, rasterEvidence: records)
    #expect(qualification.pages.count == 1)
    #expect(qualification.pages[0].verdict == .textUnavailable)
    #expect(qualification.pages[0].leftTextSource == .unavailable)
    #expect(qualification.pagesWithoutTextEvidence.count == 1)
    #expect(
      qualification.findings.contains { $0.kind == .textExtractionUnavailable })
    #expect(
      qualification.qualifiedChanges.contains {
        $0.kind == .uncertainty && $0.summary.contains("not proof of equality")
      })
    #expect(
      qualification.summaryLines.joined().contains("NOT reported as proof of equality"))
    #expect(qualification.report.contains("comparison qualification"))
  }

  @Test func scanNoiseIsDistinguishedFromMeaningfulRasterChange() throws {
    let images = try parsed(PDFFixtures.imagePages())
    let result = try PDFComparison.compare(left: images, right: images)
    let records = evidence(for: result) { ordinal in
      ordinal == 0 ? 0.001 : 0.05
    }
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: images, right: images, rasterEvidence: records)
    #expect(qualification.pages.count == 2)
    #expect(qualification.pages[0].verdict == .textUnavailable)
    #expect(qualification.pages[0].rasterStatus == .withinNoise)
    #expect(
      qualification.pages[0].findings.contains { $0.kind == .rasterNoiseOnly })
    #expect(qualification.pages[1].verdict == .visualChangeUnverified)
    #expect(qualification.pages[1].rasterStatus == .changed)
    #expect(
      qualification.pages[1].findings.contains {
        $0.kind == .rasterChangeConfirmed && $0.summary.contains("visual change")
      })
    #expect(
      qualification.summaryLines.joined().contains("scan-noise floor"))
  }

  @Test func renderingOnlyDifferenceIsNotAContentChange() throws {
    let document = try parsed(PDFFixtures.threePages())
    let result = try PDFComparison.compare(left: document, right: document)
    let records = evidence(for: result) { _ in 0.05 }
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: document, right: document, rasterEvidence: records)
    #expect(
      qualification.pages.allSatisfy {
        $0.verdict == .confirmedRenderingDifference
      })
    #expect(
      qualification.findings.contains { $0.kind == .renderingOnlyDifference })
    #expect(
      qualification.qualifiedChanges.contains {
        $0.kind == .uncertainty && $0.summary.contains("rendering/formatting")
      })
  }

  @Test func ocrTextDifferencesNeedRasterCorroboration() throws {
    let base = try parsed(PDFFixtures.imagePages())
    let pageIDs = try PDFPageTree.pageIDs(in: base.graph)
    let leftGraph = try commit(
      [
        AddSearchableTextLayerCommand(
          pageID: pageIDs[0],
          lines: [
            SearchableTextLine(text: "scanned alpha", rect: [10, 10, 90, 30], confidence: 0.9)
          ])
      ], to: base.graph)
    let rightGraph = try commit(
      [
        AddSearchableTextLayerCommand(
          pageID: pageIDs[0],
          lines: [
            SearchableTextLine(text: "scanned beta", rect: [10, 10, 90, 30], confidence: 0.9)
          ])
      ], to: base.graph)
    let left = (leftGraph, try source(of: leftGraph))
    let right = (rightGraph, try source(of: rightGraph))
    let result = try PDFComparison.compare(left: left, right: right)
    #expect(
      !result.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    let records = evidence(for: result) { _ in 0 }
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: left, right: right, rasterEvidence: records)
    #expect(qualification.pages[0].leftTextSource == .generatedOCR)
    #expect(qualification.pages[0].verdict == .unconfirmedOCRChange)
    #expect(
      qualification.pages[0].findings.contains { $0.kind == .ocrDifferenceUnconfirmed })
    #expect(
      qualification.summaryLines.joined().contains("OCR"))
    // With a meaningful raster corroboration the same OCR difference is
    // upgraded to a confirmed content change.
    let corroborated = try PDFComparisonQualification.qualify(
      result: result, left: left, right: right,
      rasterEvidence: evidence(for: result) { _ in 0.05 })
    #expect(corroborated.pages[0].verdict == .confirmedContentChange)
  }

  @Test func pageWithoutExtractableTextIsNotReportedAsUnchanged() throws {
    let left = try parsed(PDFFixtures.threePages())
    let pageID = try PDFPageTree.pageIDs(in: left.graph)[0]
    // Remove both text runs from the right page: the page still exists but has
    // no extractable text evidence at all.
    let rightGraph = try commit(
      [
        ReplaceTextCommand(pageID: pageID, runIndex: 0, replacement: ""),
        ReplaceTextCommand(pageID: pageID, runIndex: 1, replacement: ""),
      ], to: left.graph)
    let right = (rightGraph, try source(of: rightGraph))
    let result = try PDFComparison.compare(left: left, right: right)
    // Removing the text changes the alignment signature: the comparison
    // reports a structural difference instead of inventing an equal pair.
    #expect(
      !result.changes(
        kinds: [.pageDeleted, .pageInserted, .textRemoved, .textChanged]
      ).isEmpty)
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: left, right: right)
    // The page pair cannot be compared by text, so it is recorded as unpaired
    // rather than silently claimed equal.
    #expect(
      qualification.pages.contains {
        $0.verdict == .unpaired && ($0.leftPageIndex == 0 || $0.rightPageIndex == 0)
      })
    #expect(
      !qualification.pages.contains {
        $0.verdict == .noDifferenceWithTextEvidence
          && ($0.leftPageIndex == 0 || $0.rightPageIndex == 0)
      })
    #expect(qualification.summaryLines.joined().contains("unpaired"))
  }

  @Test func complexTwoColumnLayoutKeepsUncertainty() throws {
    let twoColumn = try parsed(PDFFixtures.twoColumnPages())
    let result = try PDFComparison.compare(left: twoColumn, right: twoColumn)
    #expect(result.changes(kinds: [.textAdded, .textRemoved, .textChanged]).isEmpty)
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: twoColumn, right: twoColumn,
      rasterEvidence: evidence(for: result) { _ in 0 })
    #expect(qualification.pages.count == 1)
    #expect(qualification.pages[0].verdict == .complexLayoutUncertain)
    #expect(qualification.pages[0].findings.contains { $0.kind == .complexLayout })
    #expect(
      qualification.summaryLines.joined().contains("multi-column"))
  }

  @Test func unpairedInsertedPageIsRecorded() throws {
    let left = try parsed(PDFFixtures.threePages())
    let rightGraph = try commit(
      [InsertBlankPageCommand(atIndex: 1, width: 612, height: 792)], to: left.graph)
    let right = (rightGraph, try source(of: rightGraph))
    let result = try PDFComparison.compare(left: left, right: right)
    let qualification = try PDFComparisonQualification.qualify(
      result: result, left: left, right: right)
    #expect(qualification.pages.contains { $0.verdict == .unpaired })
    #expect(qualification.findings.contains { $0.kind == .unpairedPage })
    #expect(qualification.summaryLines.joined().contains("unpaired"))
  }

  @Test func invalidEvidenceThresholdsAreRefused() throws {
    let document = try parsed(PDFFixtures.threePages())
    let result = try PDFComparison.compare(left: document, right: document)
    #expect(throws: PDFError.self) {
      _ = try PDFComparisonQualification.qualify(
        result: result, left: document, right: document,
        options: ComparisonQualificationOptions(
          scanNoiseRatio: 0.2, meaningfulChangeRatio: 0.1))
    }
  }
}
