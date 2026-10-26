import Foundation
import ReleaseTools
import Testing

/// REL-01/REL-02: workflow-level coverage with separate statuses and the
/// remaining-integration evidence register, including the honest release
/// qualification declaration boundary.
@Suite("Release qualification")
struct ReleaseQualificationTests {
  private func row(
    _ id: String, operation: String = "export.docx", documentClass: String = "text-only",
    outputClaim: String = "editable DOCX", status: ReleaseCoverageStatus = .passed,
    evidence: String = "DOCXPackageTests", note: String = ""
  ) -> ReleaseCoverageEntry {
    ReleaseCoverageEntry(
      id: id, operation: operation, documentClass: documentClass,
      outputClaim: outputClaim, status: status, evidence: evidence, note: note)
  }

  private func coverage(_ entries: [ReleaseCoverageEntry]) -> ReleaseCoverageReport {
    ReleaseCoverageReport(entries: entries)
  }

  private func integrationQuestion(
    _ id: String, topic: ReleaseIntegrationTopic = .actualOCRExecution,
    closure: ReleaseIntegrationClosure = .evidence,
    evidence: String = "OCRQualityLiveTests", profile: String = "",
    reason: String = ""
  ) -> ReleaseIntegrationQuestion {
    ReleaseIntegrationQuestion(
      id: id, topic: topic, question: "Question \(id)?", closure: closure,
      evidenceReference: evidence, exclusionProfile: profile, exclusionReason: reason)
  }

  private func closedRegister() -> ReleaseIntegrationRegister {
    ReleaseIntegrationRegister(questions: [
      integrationQuestion("ocr-live"),
      integrationQuestion(
        "crypto-independent", topic: .independentCryptographicValidation,
        evidence: "SignatureValidationTests"),
      integrationQuestion(
        "presentation-wiring", topic: .interactionChangedByNewCode,
        closure: .excluded, evidence: "", profile: "remote PDFimporter",
        reason: "The profile is explicitly unsupported and documented in the boundary."),
    ])
  }

  @Test func statusesAreReportedSeparately() throws {
    let report = coverage([
      row("r1"),
      row("r2", status: .failed, note: "Rendering diverged in appearance mode"),
      row("r3", status: .refused, note: "Unsupported transform profile"),
      row("r4", status: .notTested, evidence: ""),
    ])
    #expect(report.counts.passed == 1)
    #expect(report.counts.failed == 1)
    #expect(report.counts.refused == 1)
    #expect(report.counts.notTested == 1)
    #expect(report.counts.total == 4)
    #expect(report.hasFailures)
    #expect(report.entries(status: .failed).map(\.id) == ["r2"])
    let markdown = report.markdown()
    for status in ["passed", "failed", "refused", "not tested"] {
      #expect(markdown.contains(status))
    }
    #expect(markdown.contains(ReleaseCoverageReport.framingStatement))
    #expect(markdown.lowercased().contains("not an acrobat-replacement percentage"))
    guard let data = try? report.jsonData(),
      let decoded = try? JSONDecoder().decode(ReleaseCoverageReport.self, from: data)
    else {
      Issue.record("The coverage report must encode and decode")
      return
    }
    #expect(decoded == report)
  }

  @Test func coverageGroupsByOperationDocumentClassAndOutputClaim() {
    let report = coverage([
      row("a", operation: "export.docx", documentClass: "text-only", outputClaim: "edit"),
      row("b", operation: "export.docx", documentClass: "text-only", outputClaim: "edit",
        status: .failed, note: "Font fallback diverges"),
      row("c", operation: "export.docx", documentClass: "scanned",
        outputClaim: "edit", status: .notTested, evidence: ""),
      row("d", operation: "export.presentation", documentClass: "text-only",
        outputClaim: "editable slides", status: .refused,
        evidence: "PresentationExportTests",
        note: "Page has unsupported vector content"),
    ])
    let byOperation = Dictionary(uniqueKeysWithValues: report.grouped(.operation))
    #expect(byOperation["export.docx"]?.passed == 1)
    #expect(byOperation["export.docx"]?.failed == 1)
    #expect(byOperation["export.docx"]?.notTested == 1)
    #expect(byOperation["export.presentation"]?.refused == 1)
    let byClass = Dictionary(uniqueKeysWithValues: report.grouped(.documentClass))
    #expect(byClass["text-only"]?.total == 3)
    #expect(byClass["scanned"]?.notTested == 1)
    let byClaim = Dictionary(uniqueKeysWithValues: report.grouped(.outputClaim))
    #expect(byClaim["edit"]?.total == 3)
    #expect(byClaim["editable slides"]?.refused == 1)
    let markdown = report.markdown()
    #expect(markdown.contains("## By operation"))
    #expect(markdown.contains("## By documentClass"))
    #expect(markdown.contains("## By outputClaim"))
  }

  @Test func inconsistentCoverageRowsAreListedNotScored() {
    let report = coverage([
      row("dup"),
      row("dup"),
      row("no-evidence", status: .passed, evidence: ""),
      row("no-reason-failed", status: .failed, note: ""),
      row("no-reason-refused", status: .refused, note: ""),
      row("empty-op", operation: ""),
    ])
    #expect(!report.isConsistent)
    #expect(report.issues.contains { $0.contains("Duplicate") })
    #expect(report.issues.contains { $0.contains("without evidence") })
    #expect(report.issues.contains { $0.contains("Failed coverage row no-reason-failed") })
    #expect(report.issues.contains { $0.contains("Refused coverage row no-reason-refused") })
    #expect(report.issues.contains { $0.contains("empty operation") })
    // A refused row can be consistent when it has evidence and an explanation.
    let refusedOnly = coverage([
      row("refused", status: .refused, evidence: "suite",
        note: "Unsupported profile")
    ])
    #expect(refusedOnly.isConsistent)
  }

  @Test func integrationRegisterSeparatesEvidenceExclusionAndOpenItems() throws {
    let register = closedRegister()
    #expect(register.evidenceQuestions.count == 2)
    #expect(register.excludedQuestions.count == 1)
    #expect(register.openCount == 0)
    #expect(register.isClosed)
    #expect(register.isConsistent)
    #expect(!register.blocksReleaseQualification)
    #expect(register.questions(for: .actualOCRExecution).map(\.id) == ["ocr-live"])
    #expect(register.questions(for: .independentCryptographicValidation).count == 1)
    let markdown = register.markdown()
    #expect(markdown.contains("actualOCRExecution"))
    #expect(markdown.contains("Excluded profile: remote PDFimporter"))
    #expect(markdown.contains(ReleaseIntegrationRegister.replayPolicy))
    #expect(markdown.contains("P48-009"))

    var open = register.questions
    open.append(
      integrationQuestion("still-open", topic: .interactionChangedByNewCode, closure: .open,
        evidence: ""))
    let withOpen = ReleaseIntegrationRegister(questions: open)
    #expect(!withOpen.isClosed)
    #expect(withOpen.openCount == 1)
    #expect(withOpen.blocksReleaseQualification)
    guard let data = try? withOpen.jsonData(),
      let decoded = try? JSONDecoder().decode(ReleaseIntegrationRegister.self, from: data)
    else {
      Issue.record("The integration register must encode and decode")
      return
    }
    #expect(decoded == withOpen)
  }

  @Test func inconsistentIntegrationQuestionsAreListed() {
    let register = ReleaseIntegrationRegister(questions: [
      integrationQuestion("dup"),
      integrationQuestion("dup"),
      integrationQuestion("no-reference", closure: .evidence, evidence: ""),
      integrationQuestion("no-exclusion", closure: .excluded, evidence: "", profile: "", reason: ""),
    ])
    #expect(!register.isConsistent)
    #expect(register.blocksReleaseQualification)
    #expect(register.issues.contains { $0.contains("Duplicate") })
    #expect(register.issues.contains { $0.contains("no reference") })
    #expect(register.issues.contains { $0.contains("without a profile") })
  }

  @Test func declarationBindsSHAVersionAndReadyVerdict() throws {
    let declaration = try ReleaseQualificationDeclaration(
      sourceSHA: String(repeating: "a", count: 40), appVersion: "0.1.7",
      coverage: coverage([row("r1"), row("r2", status: .notTested, evidence: "")]),
      integration: closedRegister())
    #expect(declaration.verdict == .readyForCandidateBuild)
    #expect(declaration.isReadyForCandidateBuild)
    #expect(declaration.blockers.isEmpty)
    #expect(declaration.sourceSHA == String(repeating: "a", count: 40))
    #expect(declaration.appVersion == "0.1.7")
    let markdown = declaration.markdown()
    #expect(markdown.contains(ReleaseQualificationDeclaration.claimStatement))
    for item in ReleaseQualificationDeclaration.notClaimed {
      #expect(markdown.contains(item))
    }
    #expect(markdown.contains("Verdict: readyForCandidateBuild"))
    guard let data = try? declaration.jsonData(),
      let decoded = try? JSONDecoder().decode(
        ReleaseQualificationDeclaration.self, from: data)
    else {
      Issue.record("The declaration must encode and decode")
      return
    }
    #expect(decoded == declaration)
    let second = try declaration.jsonData()
    #expect(data == second)
  }

  @Test func declarationBlocksOnFailuresOpenQuestionsAndInconsistencies() throws {
    let failedCoverage = coverage([
      row("r1"),
      row("r2", status: .failed, note: "Layout regression"),
    ])
    let failed = try ReleaseQualificationDeclaration(
      sourceSHA: String(repeating: "b", count: 64), appVersion: "0.1.7",
      coverage: failedCoverage, integration: closedRegister())
    #expect(failed.verdict == .blocked)
    #expect(failed.blockers.contains { $0.contains("failed coverage") })
    #expect(failed.blockers.contains { $0.contains("r2") })

    var openQuestions = closedRegister().questions
    openQuestions.append(
      integrationQuestion("open-1", topic: .interactionChangedByNewCode, closure: .open, evidence: ""))
    let open = try ReleaseQualificationDeclaration(
      sourceSHA: String(repeating: "c", count: 40), appVersion: "0.1.7",
      coverage: coverage([row("r1")]),
      integration: ReleaseIntegrationRegister(questions: openQuestions))
    #expect(open.verdict == .blocked)
    #expect(open.blockers.contains { $0.contains("open integration") })
    #expect(open.blockers.contains { $0.contains("open-1") })

    let inconsistent = try ReleaseQualificationDeclaration(
      sourceSHA: String(repeating: "d", count: 40), appVersion: "0.1.7",
      coverage: coverage([row("bad", status: .passed, evidence: "")]),
      integration: closedRegister())
    #expect(inconsistent.verdict == .blocked)
    #expect(inconsistent.blockers.contains { $0.contains("consistency") })

    let markdown = failed.markdown()
    #expect(markdown.contains("## Blockers"))
    #expect(markdown.contains("Source SHA: \(String(repeating: "b", count: 64))"))
  }

  @Test func declarationRefusesMissingOrMalformedIdentity() {
    let validCoverage = coverage([row("r1")])
    #expect(throws: ReleaseToolsError.self) {
      _ = try ReleaseQualificationDeclaration(
        sourceSHA: "not-a-sha", appVersion: "0.1.7", coverage: validCoverage,
        integration: closedRegister())
    }
    #expect(throws: ReleaseToolsError.self) {
      _ = try ReleaseQualificationDeclaration(
        sourceSHA: String(repeating: "e", count: 39), appVersion: "0.1.7",
        coverage: validCoverage, integration: closedRegister())
    }
    #expect(throws: ReleaseToolsError.self) {
      _ = try ReleaseQualificationDeclaration(
        sourceSHA: String(repeating: "e", count: 40), appVersion: "  ",
        coverage: validCoverage, integration: closedRegister())
    }
  }
}
