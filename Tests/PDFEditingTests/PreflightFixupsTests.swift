import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// PRE-04 evidence: configurable rule sets/severities, object navigation, exact
/// staged-fix previews, affected-check reruns and an exportable report.
@Suite("Preflight fixups (PRE-04)")
struct PreflightFixupsTests {
  private func session() throws -> PreflightFixupSession {
    let parsed = try PDFParser.parse(PDFXFixture.printJobPages())
    return PreflightFixupSession(graph: parsed.graph, pageIDs: parsed.pageIDs)
  }

  @Test func ruleSetSeverityOverridesAndEnablement() throws {
    var ruleSet = PreflightRuleSet.printDelivery
    var session = try session()
    session.setRuleSet(ruleSet)
    #expect(session.report.findings.contains { $0.ruleID == "printBoxes" && $0.severity == .error })
    ruleSet.severityOverrides["printBoxes"] = .warning
    session.setRuleSet(ruleSet)
    #expect(session.report.findings.contains { $0.ruleID == "printBoxes" && $0.severity == .warning })
    ruleSet.enabledRuleIDs.remove("outputIntent")
    session.setRuleSet(ruleSet)
    #expect(!session.report.findings.contains { $0.ruleID == "outputIntent" })
  }

  @Test func objectNavigationPointsAtPageAndImageObjects() throws {
    var session = try session()
    var ruleSet = session.ruleSet
    ruleSet.enabledRuleIDs.insert("imageResolution")
    session.setRuleSet(ruleSet)
    let boxFinding = try #require(session.report.findings.first { $0.ruleID == "printBoxes" })
    #expect(boxFinding.pageIndex == 0)
    #expect(boxFinding.navigation.contains("page 1"))
    let imageFinding = try #require(
      session.report.findings.first { $0.ruleID == "imageResolution" })
    #expect(imageFinding.pageIndex == 0)
    #expect(imageFinding.objectID != nil)
    #expect(imageFinding.navigation.contains("object"))
    let annotated = try #require(session.report.findings.first { $0.ruleID == "annotations" })
    #expect(annotated.fixupID == "flattenAnnotations")
  }

  @Test func previewListsExactChangesPerObject() throws {
    var session = try session()
    let boxes = session.preview(.addTrimBoxes)
    #expect(boxes.changes.count == 1)
    #expect(boxes.changes[0].pageIndex == 0)
    #expect(boxes.changes[0].before == "no TrimBox")
    #expect(boxes.changes[0].after == "TrimBox 18x18x594x774")
    let intent = session.preview(.addOutputIntent)
    #expect(intent.changes.first?.before.contains("no output intent") == true)
    _ = try session.apply(.addTrimBoxes)
    #expect(!session.preview(.addTrimBoxes).changes.isEmpty == false)
  }

  @Test func stagedFixRerunsAffectedChecksAndResolvesFindings() throws {
    var session = try session()
    let before = session.report
    let applied = try session.apply(.addTrimBoxes)
    #expect(applied.preview.affectedRuleIDs == ["printBoxes"])
    #expect(applied.resolvedRuleIDs == ["printBoxes"])
    #expect(applied.reportAfter.findings.allSatisfy { $0.ruleID != "printBoxes" })
    #expect(before.findings.contains { $0.ruleID == "printBoxes" })
    _ = try session.apply(.addOutputIntent)
    _ = try session.apply(.addPDFXIdentification)
    #expect(session.report.errors.isEmpty)
    #expect(session.report.findings.allSatisfy { $0.severity != .error })
    let flatten = try session.apply(.flattenAnnotations)
    #expect(flatten.resolvedRuleIDs.contains("annotations"))
    #expect(session.report.findings.allSatisfy { $0.ruleID != "annotations" })
    #expect(session.sourceGraph != session.graph)
  }

  @Test func exportReportCarriesFindingsAndFixChanges() throws {
    var session = try session()
    _ = try session.apply(.addTrimBoxes)
    _ = try session.apply(.addOutputIntent)
    let text = session.exportReport()
    #expect(text.contains("Rule set: Print delivery"))
    #expect(text.contains("Applied fixups"))
    #expect(text.contains("page 1"))
    #expect(text.contains("->"))
    #expect(text.contains("Source document was not modified"))
    #expect(!session.appliedFixups.isEmpty)
  }

  @Test func reusableRuleSetJSONRoundTripAndSaveReopen() throws {
    var ruleSet = PreflightRuleSet.pdfx1a
    ruleSet.minimumImageDPI = 200
    ruleSet.severityOverrides["imageResolution"] = .error
    let data = try ruleSet.exportJSON()
    let restored = try PreflightRuleSet.importJSON(data)
    #expect(restored == ruleSet)
    #expect(restored.severity(for: "imageResolution") == .error)
    var session = try session()
    session.setRuleSet(restored)
    _ = try session.apply(.addTrimBoxes)
    _ = try session.apply(.addOutputIntent)
    _ = try session.apply(.addPDFXIdentification)
    _ = try session.apply(.flattenAnnotations)
    let saved = try PDFWriter.write(session.graph)
    let reopened = try PDFParser.parse(saved)
    #expect(!reopened.graph.objects.isEmpty)
    #expect(try PDFXExporter.plan(
      reopened.graph, pageIDs: reopened.pageIDs, profile: .x4).isExportable)
  }
}

