import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// A11Y-05/A11Y-06 evidence: a navigable report with object links, remediation
/// tools, automatic vs manual separation and rerun-only-affected checks; and an
/// explicit PDF/UA-1 profile whose pass requires machine rules, independent
/// validation and human checks (unavailable validation is never a pass).
@Suite("Accessible report and PDF/UA profile (A11Y-05/06)")
struct AccessibilityReportProfileTests {
  // MARK: Fixtures

  private func taggedGraph(alt: String? = "A red square", withMetadata: Bool = true)
    -> PDFGraph
  {
    var objects: [PDFObjectID: PDFValue] = [:]
    var content = "/Figure <</MCID 0>> BDC\n"
    content += "BT /F1 12 Tf 72 700 Td (Accessible paragraph) Tj ET\n"
    content += "EMC\n"
    var catalog: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
      PDFName("StructTreeRoot"): .reference(PDFObjectID(3)),
      PDFName("MarkInfo"): .dictionary([PDFName("Marked"): .boolean(true)]),
      PDFName("Lang"): .string(Data("en-US".utf8)),
    ]
    if withMetadata {
      catalog[PDFName("ViewerPreferences")] = .dictionary([
        PDFName("DisplayDocTitle"): .boolean(true),
        PDFName("PrintScaling"): .name(PDFName("None")),
      ])
      catalog[PDFName("Metadata")] = .reference(PDFObjectID(31))
      objects[PDFObjectID(30)] = .dictionary([
        PDFName("Title"): .string(Data("Accessible fixture".utf8))
      ])
      let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:pdfuaid="http://www.aiim.org/pdfua/ns/id/"><dc:title><rdf:Alt>\
        <rdf:li xml:lang="x-default">Accessible fixture</rdf:li></rdf:Alt></dc:title>\
        <pdfuaid:part>1</pdfuaid:part></rdf:Description></rdf:RDF></x:xmpmeta>
        """
      objects[PDFObjectID(31)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("Metadata")),
            PDFName("Subtype"): .name(PDFName("XML")),
            PDFName("Length"): .integer(Int64(Data(xmp.utf8).count)),
          ], bytes: Data(xmp.utf8)))
    }
    objects[PDFObjectID(1)] = .dictionary(catalog)
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(1),
      PDFName("Kids"): .array([.reference(PDFObjectID(4))]),
    ])
    objects[PDFObjectID(3)] = .dictionary([
      PDFName("Type"): .name(PDFName("StructTreeRoot")),
      PDFName("ParentTree"): .reference(PDFObjectID(8)),
      PDFName("ParentTreeNextKey"): .integer(1),
      PDFName("K"): .array([.reference(PDFObjectID(20))]),
    ])
    objects[PDFObjectID(4)] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(PDFObjectID(2)),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(612), .integer(792),
      ]),
      PDFName("Resources"): .dictionary([
        PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(6))])
      ]),
      PDFName("Contents"): .reference(PDFObjectID(5)),
      PDFName("StructParents"): .integer(0),
    ])
    objects[PDFObjectID(5)] = .stream(PDFStream(bytes: Data(content.utf8)))
    objects[PDFObjectID(6)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
      PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
    ])
    var figure: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("Figure")),
      PDFName("P"): .reference(PDFObjectID(3)),
      PDFName("Pg"): .reference(PDFObjectID(4)),
      PDFName("K"): .integer(0),
    ]
    if let alt { figure[PDFName("Alt")] = .string(Data(alt.utf8)) }
    objects[PDFObjectID(20)] = .dictionary(figure)
    objects[PDFObjectID(8)] = .dictionary([
      PDFName("Nums"): .array([
        .integer(0), .array([.reference(PDFObjectID(20))]),
      ])
    ])
    var trailer: [PDFName: PDFValue] = [PDFName("Root"): .reference(PDFObjectID(1))]
    if withMetadata { trailer[PDFName("Info")] = .reference(PDFObjectID(30)) }
    return PDFGraph(version: "1.7", objects: objects, trailer: trailer)
  }

  private func pageIDs(_ graph: PDFGraph) throws -> [PDFObjectID] {
    try PDFPageTree.pageIDs(in: graph)
  }

  private func compliantValidator() -> ArchivalValidationResult {
    ArchivalValidationResult(
      validator: "test-verapdf", validatorVersion: "1.0", profileName: "PDF/UA-1",
      isCompliant: true, passedRules: 10, failedRules: 0, failedChecks: 0,
      failingRules: [])
  }

  private func failingValidator() -> ArchivalValidationResult {
    ArchivalValidationResult(
      validator: "test-verapdf", validatorVersion: "1.0", profileName: "PDF/UA-1",
      isCompliant: false, passedRules: 4, failedRules: 1, failedChecks: 2,
      failingRules: [
        ArchivalValidationResult.FailingRule(
          specification: "PDF/UA-1", clause: "7.1", description: "Test failure",
          failedChecks: 2)
      ])
  }

  private var allHumanPass: [String: AccessibilityHumanCheckResult] {
    Dictionary(
      uniqueKeysWithValues: AccessibilityRuleCatalog.manualRules.map {
        ($0.id, AccessibilityHumanCheckResult.pass)
      })
  }

  private func preparedGraph() throws -> PDFGraph {
    var graph = taggedGraph(withMetadata: false)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        PrepareAccessibleProfileCommand(title: "Accessible fixture", language: "en-US")
      ]), to: graph)
    return graph
  }

  // MARK: A11Y-05 tests

  @Test func ruleCatalogSeparatesModesAndDocumentsTestedCases() {
    let rules = AccessibilityRuleCatalog.allRules
    #expect(Set(rules.map(\.id)).count == rules.count)
    let automatic = AccessibilityRuleCatalog.automaticRules
    #expect(!automatic.isEmpty)
    #expect(automatic.allSatisfy { $0.mode == .automatic })
    #expect(automatic.allSatisfy { $0.isClaimed })
    #expect(automatic.allSatisfy { !$0.remediationTools.isEmpty })
    let manual = AccessibilityRuleCatalog.manualRules
    #expect(!manual.isEmpty)
    #expect(manual.allSatisfy { $0.mode == .manual })
    #expect(manual.allSatisfy { $0.isClaimed })
    #expect(manual.allSatisfy { $0.humanQuestion != nil })
    #expect(AccessibilityRuleCatalog.rule(id: "ua.figure.alt") != nil)
  }

  @Test func findingsLinkObjectsAndRemediationTools() throws {
    let graph = taggedGraph(alt: nil)
    let report = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: try pageIDs(graph))
    let outcome = try #require(report.outcome(for: "ua.figure.alt"))
    #expect(outcome.status == .fail)
    let finding = try #require(outcome.findings.first)
    #expect(finding.objects.contains { $0.kind == .structureElement && $0.role == "Figure" })
    #expect(finding.remediationTools.contains(.alternateText))
    #expect(
      finding.remediationHints.contains { $0.contains("Alternate text") })
    #expect(report.report.contains("affected:"))
    #expect(report.report.contains("remedy:"))
  }

  @Test func untaggedDocumentLinksCatalogAndPageObjects() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let report = AccessibilityReportBuilder.build(
      graph: parsed.graph, pageIDs: parsed.pageIDs)
    let structure = try #require(report.outcome(for: "aa.structure.tree"))
    #expect(structure.status == .fail)
    #expect(structure.objects.contains { $0.kind == .catalog })
    let pages = try #require(report.outcome(for: "aa.page.marked"))
    // The untagged fixture may fail at the structure tree before page-level
    // tagging is separately reported; the rule must still be evaluated.
    #expect(pages.status != .unavailable)
    #expect(pages.objects.contains { $0.kind == .page })
  }

  @Test func rerunOnlyAffectedChecks() throws {
    let graph = taggedGraph(alt: nil)
    let pages = try pageIDs(graph)
    let full = AccessibilityReportBuilder.build(graph: graph, pageIDs: pages)
    let selected = ["ua.figure.alt", "aa.structure.tree"]
    let rerun = AccessibilityReportBuilder.rerun(
      ruleIDs: selected, graph: graph, pageIDs: pages)
    #expect(rerun.outcomes.count == 2)
    #expect(Set(rerun.outcomes.map(\.rule.id)) == Set(selected))
    #expect(rerun.rerunRuleIDs == selected)
    #expect(rerun.summaryLines.joined().contains("Rerun limited to affected checks"))
    #expect(rerun.outcome(for: "ua.figure.alt")?.status == .fail)
    #expect(full.outcome(for: "ua.figure.alt")?.status == .fail)
    #expect(rerun.outcome(for: "aa.figure.alt") == nil)
  }

  @Test func manualChecksAreNeverInferredByAutomation() throws {
    let graph = taggedGraph()
    let graphPages = try pageIDs(graph)
    let undecided = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: graphPages)
    #expect(undecided.outcome(for: "manual.altQuality")?.status == .manual)
    #expect(undecided.pendingManualChecks.count == AccessibilityRuleCatalog.manualRules.count)
    #expect(!undecided.manualOutcomes.contains { $0.status == .pass })
    let passed = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: graphPages,
      humanChecks: ["manual.altQuality": true])
    #expect(passed.outcome(for: "manual.altQuality")?.status == .pass)
    let failed = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: graphPages,
      humanChecks: ["manual.altQuality": false])
    #expect(failed.outcome(for: "manual.altQuality")?.status == .fail)
  }

  @Test func unavailableIndependentValidatorIsNeverAPass() throws {
    let graph = taggedGraph()
    let report = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: try pageIDs(graph),
      validatorUnavailableReason: "veraPDF is not installed")
    let outcome = try #require(report.outcome(for: "ua.independentValidator"))
    #expect(outcome.status == .unavailable)
    #expect(outcome.detail.contains("not a pass"))
    #expect(report.report.contains("This is NOT a pass"))
    #expect(report.unavailableChecks.map(\.rule.id).contains("ua.independentValidator"))
  }

  // MARK: A11Y-06 tests

  @Test func profileDeclaresSupportedStandardAndPdfUA2IsUnavailable() {
    let profile = AccessibleOutputProfile()
    #expect(profile.standard == .pdfUA1)
    #expect(AccessibleOutputStandard.supportedStandards == [.pdfUA1])
    #expect(
      AccessibleOutputStandard.unavailableStandards.joined().contains("PDF/UA-2"))
    #expect(profile.summaryLines.joined().contains("PDF/UA-1"))
    #expect(
      profile.requirements.contains { $0.ruleID == "ua.metadata.xmpIdentifier" })
    #expect(
      profile.requirements.contains { $0.kind == .independentValidator })
    #expect(
      profile.requirements.contains { $0.kind == .manualCheck })
  }

  @Test func prepareCommandCompletesMetadataAndPreservesExistingPreferences() throws {
    var graph = taggedGraph(withMetadata: false)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        PrepareAccessibleProfileCommand(title: "Accessible fixture", language: "en-US")
      ]), to: graph)
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else {
      Issue.record("catalog missing")
      return
    }
    #expect(catalog[PDFName("Lang")] == .string(Data("en-US".utf8)))
    #expect(
      PrepareAccessibleProfileCommand.existingTitle(in: graph) == "Accessible fixture")
    guard case .reference(let infoID)? = graph.trailer[PDFName("Info")],
      case .dictionary(let info)? = graph.objects[infoID]
    else {
      Issue.record("Info missing")
      return
    }
    #expect(info[PDFName("Title")] == .string(Data("Accessible fixture".utf8)))
    #expect(
      AccessibilityReportBuilder.viewerDisplayDocTitle(catalog: catalog, graph: graph))
    guard case .reference(let metadataID)? = catalog[PDFName("Metadata")],
      case .stream(let stream)? = graph.objects[metadataID]
    else {
      Issue.record("XMP metadata missing")
      return
    }
    let xmp = String(decoding: stream.bytes, as: UTF8.self)
    #expect(xmp.contains("pdfuaid:part"))
    #expect(xmp.contains("Accessible fixture"))
    let report = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: try pageIDs(graph))
    #expect(report.outcome(for: "ua.metadata.title")?.status == .pass)
    #expect(report.outcome(for: "ua.metadata.displayDocTitle")?.status == .pass)
    #expect(report.outcome(for: "ua.metadata.xmpIdentifier")?.status == .pass)
  }

  @Test func prepareCommandRefusesIncompleteStructureOrMissingEvidence() throws {
    let untagged = try PDFParser.parse(PDFFixtures.onePage())
    #expect(throws: PDFError.self) {
      try PrepareAccessibleProfileCommand(
        title: "No structure", language: "en-US").validate(in: untagged.graph)
    }
    let tagged = taggedGraph(withMetadata: false)
    #expect(throws: PDFError.self) {
      try PrepareAccessibleProfileCommand(
        title: "", language: "en-US").validate(in: tagged)
    }
    #expect(throws: PDFError.self) {
      try PrepareAccessibleProfileCommand(
        title: "Title", language: "e!").validate(in: tagged)
    }
  }

  @Test func profilePassRequiresAutoChecksIndependentValidatorAndHumanChecks() throws {
    let graph = try preparedGraph()
    let pages = try pageIDs(graph)
    let pass = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages,
      humanCheckResults: allHumanPass,
      independentValidator: compliantValidator())
    #expect(pass.verdict == .pass)
    #expect(pass.failedRequirements.isEmpty)
    #expect(pass.unverifiedRequirements.isEmpty)
    #expect(pass.report.contains("Verdict: Pass"))
    #expect(pass.requirements.allSatisfy { $0.status == .pass })

    let unavailable = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages,
      humanCheckResults: allHumanPass,
      validatorUnavailableReason: "veraPDF is not installed")
    #expect(unavailable.verdict == .notVerified)
    #expect(unavailable.validatorUnavailable)
    #expect(unavailable.report.contains("NOT a pass"))

    let validatorFailed = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages,
      humanCheckResults: allHumanPass,
      independentValidator: failingValidator())
    #expect(validatorFailed.verdict == .fail)

    var pending = allHumanPass
    pending["manual.readingOrder"] = .notChecked
    let unchecked = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages,
      humanCheckResults: pending,
      independentValidator: compliantValidator())
    #expect(unchecked.verdict == .notVerified)

    var humanFailed = allHumanPass
    humanFailed["manual.readingOrder"] = .fail
    let failed = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages,
      humanCheckResults: humanFailed,
      independentValidator: compliantValidator())
    #expect(failed.verdict == .fail)
    #expect(
      failed.failedRequirements.contains { $0.requirement.kind == .manualCheck })
  }

  @Test func machineFailureCannotBeMaskedByValidatorOrHumanChecks() throws {
    let graph = taggedGraph(alt: nil)  // figure without /Alt
    let pages = try pageIDs(graph)
    let report = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages,
      humanCheckResults: allHumanPass,
      independentValidator: compliantValidator())
    #expect(report.verdict == .fail)
    #expect(
      report.failedRequirements.contains { $0.requirement.ruleID == "ua.figure.alt" })
    #expect(report.requiredActions.contains { $0.contains("Figure alternate text") })
  }

  @Test func empiricalIndependentValidatorIsRecordedNotAssumed() throws {
    let graph = try preparedGraph()
    let pages = try pageIDs(graph)
    let data = try PDFWriter.write(graph)
    let result = ArchivalDerivative.validateAccessibility(data)
    let human = allHumanPass
    let report = AccessibleOutputProfileValidation.evaluate(
      graph: graph, pageIDs: pages, humanCheckResults: human,
      independentValidator: result,
      validatorUnavailableReason: result == nil ? "veraPDF unavailable" : nil)
    if let result {
      #expect(report.independentValidator?.isCompliant == result.isCompliant)
      #expect(report.validatorUnavailable == false)
      if !result.isCompliant { #expect(report.verdict != .pass) }
    } else {
      #expect(report.validatorUnavailable)
      #expect(report.verdict != .pass)
      #expect(report.report.contains("NOT a pass"))
    }
  }
}
