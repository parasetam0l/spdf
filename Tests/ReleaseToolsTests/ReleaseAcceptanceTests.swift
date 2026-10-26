import Foundation
import ReleaseTools
import Testing

/// REL-04/REL-05: update/relaunch qualification and owner acceptance/help
/// accuracy records. Owner publication and acceptance cannot be granted here,
/// so the tests pin the blocked/pending behavior as much as the pass path.
@Suite("Release acceptance records")
struct ReleaseAcceptanceTests {
  private func publication(
    version: String = "0.2.0", build: String = "200",
    sourceSHA: String = String(repeating: "a", count: 40),
    feedSignatureValid: Bool = true, appSignatureValid: Bool = true,
    notarized: Bool = true, reference: String = "release-0.2.0"
  ) -> PublishedReleaseEvidence {
    PublishedReleaseEvidence(
      version: version, build: build, sourceSHA: sourceSHA,
      feedURL: "https://github.com/parasetam0l/spdf/releases/latest/download/appcast.xml",
      assetFileName: "sPDF-Editor-0.2.0.dmg",
      assetSHA256: String(repeating: "b", count: 64), assetSizeBytes: 3_200_000,
      feedSignatureValid: feedSignatureValid, appSignatureValid: appSignatureValid,
      notarizedAndStapled: notarized, publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
      publicationReference: reference)
  }

  private func installed(
    version: String = "0.2.0", build: String = "200",
    priorVersion: String = "0.1.0", priorBuild: String = "100",
    path: String = "/Applications/sPDF Editor.app", writable: Bool = true,
    translocated: Bool = false, diskImage: Bool = false, signatureValid: Bool = true
  ) -> InstalledReleaseEvidence {
    InstalledReleaseEvidence(
      installedVersion: version, installedBuild: build, priorVersion: priorVersion,
      priorBuild: priorBuild, installPath: path, installWritable: writable,
      translocated: translocated, onDiskImage: diskImage,
      runningSignatureValid: signatureValid, systemVersion: "14.5",
      architecture: "arm64")
  }

  private func completeInput() -> UpdateRelaunchQualificationInput {
    UpdateRelaunchQualificationInput(
      publication: publication(),
      installed: installed(),
      updateState: DocumentUpdateState(dirtyDocumentCount: 1, windowCount: 1),
      savedRelaunch: RelaunchState(
        openWindowIDs: ["doc-1"], settingsVersion: 1, bookmarkedFileCount: 1),
      restore: RelaunchRestoreEvidence(
        pendingDocumentCount: 1, restoredDocumentCount: 1, restoredSettings: true,
        keptSettingsBackup: false, reopenedSafely: true, recoveryReference: "relaunch-log"),
      interactiveWritebackExercised: true,
      interactiveWritebackReference: "interactive-session-log")
  }

  // MARK: - REL-04

  @Test func withoutOwnerPublicationTheRecordIsBlockedNotPassed() {
    let record = UpdateRelaunchQualification(input: UpdateRelaunchQualificationInput())
    #expect(record.verdict == .blockedOwnerAction)
    #expect(!record.isQualified)
    #expect(record.checks.contains { $0.id == "publication" && $0.status == .blockedOwnerAction })
    #expect(record.checks.contains { $0.id == "relaunch-restore" && $0.status == .notRun })
    #expect(record.markdown().contains("Blocked (owner action)"))
  }

  @Test func completeOwnerEvidenceQualifiesThePath() throws {
    let record = UpdateRelaunchQualification(input: completeInput())
    #expect(record.verdict == .qualified)
    #expect(record.isQualified)
    #expect(record.issues.isEmpty)
    #expect(record.passedChecks.count == record.checks.count)
    #expect(record.checks.allSatisfy { !$0.evidenceReference.isEmpty })
    let json = try record.jsonData()
    let decoded = try JSONDecoder().decode(UpdateRelaunchQualification.self, from: json)
    #expect(decoded.verdict == .qualified)
    #expect(record.markdown().contains("Update/relaunch qualification (REL-04)"))
  }

  @Test func missingRelaunchEvidenceLeavesTheRecordIncomplete() {
    var input = completeInput()
    input.restore = nil
    let record = UpdateRelaunchQualification(input: input)
    #expect(record.verdict == .incomplete)
    #expect(record.checks.contains { $0.id == "relaunch-restore" && $0.status == .notRun })
  }

  @Test func readinessAndInstallLocationRulesAreEnforced() {
    var blockedSave = completeInput()
    blockedSave.updateState = DocumentUpdateState(saveAsInProgress: true)
    #expect(UpdateRelaunchQualification(input: blockedSave).verdict == .failed)

    var diskImage = completeInput()
    diskImage.installed = installed(path: "/Volumes/sPDF/sPDF Editor.app", diskImage: true)
    let diskRecord = UpdateRelaunchQualification(input: diskImage)
    #expect(diskRecord.verdict == .failed)
    #expect(diskRecord.checks.contains {
      $0.id == "install-location" && $0.detail.contains("disk image")
    })

    var translocated = completeInput()
    translocated.installed = installed(translocated: true)
    #expect(UpdateRelaunchQualification(input: translocated).verdict == .failed)
  }

  @Test func restoreMismatchAndInteractiveClaimWithoutReferenceFail() {
    var lostDocument = completeInput()
    lostDocument.restore = RelaunchRestoreEvidence(
      pendingDocumentCount: 2, restoredDocumentCount: 1, restoredSettings: true,
      keptSettingsBackup: false, reopenedSafely: true, recoveryReference: "relaunch-log")
    let lost = UpdateRelaunchQualification(input: lostDocument)
    #expect(lost.verdict == .failed)
    #expect(lost.checks.contains {
      $0.id == "relaunch-restore" && $0.detail.contains("restored 1 of 2")
    })

    var unbackedInteractive = completeInput()
    unbackedInteractive.interactiveWritebackReference = ""
    let unbacked = UpdateRelaunchQualification(input: unbackedInteractive)
    #expect(unbacked.verdict == .failed)
    #expect(unbacked.issues.contains { $0.contains("without an evidence reference") })
  }

  @Test func olderOrEqualPublishedBuildsAreRefused() {
    var older = completeInput()
    older.publication = publication(version: "0.1.9", build: "80")
    let record = UpdateRelaunchQualification(input: older)
    #expect(record.verdict == .failed)
    #expect(record.checks.contains { $0.id == "eligibility" && $0.status == .failed })
  }

  // MARK: - REL-05

  private func acceptedWorkflow(
    _ id: String, selectors: [String] = ["exportDOCX:"],
    status: WorkflowAcceptanceStatus = .ownerAccepted
  ) -> WorkflowAcceptance {
    WorkflowAcceptance(
      id: id, workflow: "Workflow " + id, status: status,
      ownerReference: status == .ownerAccepted ? "owner-acceptance-log" : "",
      selectors: selectors)
  }

  private func backedClaim(
    _ id: String, document: String = "Docs/Exports.md",
    backing: [String] = ["exportDOCX:"], symbols: [String] = [],
    review: String = "help-review-log"
  ) -> HelpClaim {
    HelpClaim(
      id: id, document: document, claim: "Exports a DOCX document.",
      referencedSymbols: symbols, backingSelectors: backing, reviewReference: review)
  }

  private func acceptanceInput(
    workflows: [WorkflowAcceptance]? = nil, claims: [HelpClaim]? = nil
  ) -> OwnerAcceptanceInput {
    OwnerAcceptanceInput(
      appVersion: "0.2.0",
      sourceSHA: String(repeating: "c", count: 40),
      workflows: workflows ?? [acceptedWorkflow("w1")],
      helpClaims: claims ?? [backedClaim("h1")],
      exposedSelectors: ["exportDOCX:", "showAccessibleReadingPanel:"],
      approvedCoreReferences: [],
      knownExceptions: ["Update qualification for prerelease channel is out of scope."])
  }

  @Test func completeOwnerAcceptanceWithBackedHelpIsAccepted() throws {
    let report = OwnerAcceptanceReport(input: acceptanceInput())
    #expect(report.verdict == .ownerAccepted)
    #expect(report.isOwnerAccepted)
    #expect(report.failedChecks.isEmpty)
    #expect(!report.markdown().contains("## Record issues"))
    let json = try report.jsonData()
    let decoded = try JSONDecoder().decode(OwnerAcceptanceReport.self, from: json)
    #expect(decoded.verdict == .ownerAccepted)
  }

  @Test func pendingOwnerOrUnbackedHelpBlocksAcceptance() {
    let pending = OwnerAcceptanceReport(
      input: acceptanceInput(workflows: [acceptedWorkflow("w1", status: .pendingOwner)]))
    #expect(pending.verdict == .pendingOwner)
    #expect(pending.issues.contains { $0.contains("pending owner acceptance") })

    let unbacked = OwnerAcceptanceReport(
      input: acceptanceInput(claims: [backedClaim("h1", backing: [])]))
    #expect(unbacked.verdict == .blocked)
    #expect(unbacked.issues.contains { $0.contains("no shipped backing selector") })

    let missingBacking = OwnerAcceptanceReport(
      input: acceptanceInput(claims: [backedClaim("h1", backing: ["exportRTF:"])]))
    #expect(missingBacking.verdict == .blocked)
    #expect(missingBacking.issues.contains { $0.contains("absent from the shipped inventory") })
  }

  @Test func helpMustNotPromiseUnexposedCoreHelpers() {
    let report = OwnerAcceptanceReport(
      input: acceptanceInput(
        claims: [backedClaim("h1", symbols: ["UpdateSignature.verify"])]))
    #expect(report.verdict == .blocked)
    #expect(report.issues.contains { $0.contains("unexposed helper") })
    #expect(report.markdown().contains("unexposed helper"))
  }

  @Test func ownerAcceptedWithoutReferenceOrExclusionReasonIsInvalid() {
    var unreferenced = acceptedWorkflow("w1")
    unreferenced.ownerReference = ""
    let report = OwnerAcceptanceReport(
      input: acceptanceInput(workflows: [unreferenced]))
    #expect(report.verdict == .blocked)
    #expect(report.issues.contains { $0.contains("without a reference") })

    let excluded = WorkflowAcceptance(
      id: "w2", workflow: "Remote import", status: .excluded,
      exclusionReason: "", selectors: [])
    let excludedReport = OwnerAcceptanceReport(
      input: acceptanceInput(workflows: [excluded]))
    #expect(excludedReport.verdict == .blocked)
    #expect(excludedReport.issues.contains { $0.contains("excluded without a reason") })
  }

  @Test func unknownSelectorsAndUnreviewedClaimsAreCaught() {
    let unknownSelector = OwnerAcceptanceReport(
      input: acceptanceInput(workflows: [acceptedWorkflow("w1", selectors: ["hiddenHelper:"])]))
    #expect(unknownSelector.verdict == .blocked)
    #expect(unknownSelector.issues.contains { $0.contains("not in the shipped inventory") })

    let unreviewed = OwnerAcceptanceReport(
      input: acceptanceInput(claims: [backedClaim("h1", review: "")]))
    #expect(unreviewed.verdict == .blocked)
    #expect(unreviewed.issues.contains { $0.contains("not reviewed with a reference") })
  }
}
