import DocumentSession
import Foundation
import Testing

/// UX-05/UX-06/UX-07 evidence: interaction budget separation (no overall
/// performance score), conflict decisions that never discard unsaved work, and
/// the isolation decision record with its explicit no-rewrite-without-evidence
/// boundary.
@Suite("Interaction budgets")
struct InteractionBudgetTests {
  private let context = InteractionMeasurementContext(
    hardware: "Test host arm64", inputClass: "synthetic 40-page text PDF",
    methodology: "Synthetic durations; nearest-rank percentiles")

  private func sample(
    _ kind: InteractionKind, _ milliseconds: Double, class documentClass: String = "small"
  ) -> InteractionSample {
    InteractionSample(kind: kind, milliseconds: milliseconds, documentClass: documentClass)
  }

  @Test func distributionsUseNearestRankPercentiles() {
    let distribution = InteractionDistribution([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    #expect(distribution.count == 10)
    #expect(distribution.median == 5)
    #expect(distribution.p95 == 10)
    #expect(distribution.p99 == 10)
    #expect(distribution.maximum == 10)
    #expect(InteractionDistribution([]).count == 0)
    #expect(InteractionDistribution([]).p95 == 0)
  }

  @Test func statusesStaySeparatePerInteractionAndClass() {
    let report = InteractionBudgetReport.evaluate(
      samples: [
        sample(.firstPageDisplay, 40),
        sample(.scroll, 120),  // missed
        sample(.zoom, 90),
        sample(.textPreview, 30, class: "large"),
        // selection and search and cancellation intentionally absent
      ],
      context: context,
      documentClasses: ["small", "large"])
    #expect(report.metCount == 3)  // firstPageDisplay/zoom on small, textPreview on large
    #expect(report.missedCount == 1)
    #expect(report.notMeasuredCount > 0)
    #expect(report.results(kind: .firstPageDisplay).count == 2)
    #expect(report.results(kind: .firstPageDisplay).contains { $0.status == .notMeasured })
    #expect(!report.meetsDeclaredBudgets)
    #expect(!report.isComplete)
    let result = report.results(kind: .scroll).first { $0.documentClass == "small" }
    #expect(result?.status == .missed)
    #expect(result?.distribution?.p95 == 120)
    #expect(result?.budgetP95Milliseconds == 100)
  }

  @Test func cancellationUsesItsOwnOneSecondTarget() {
    let budgets = InteractionBudget.startingTargets()
    #expect(
      budgets.first { $0.kind == .cancellation }?.p95Milliseconds
        == InteractionBudget.cancellationP95Milliseconds)
    let report = InteractionBudgetReport.evaluate(
      samples: [sample(.cancellation, 400)],
      context: context, budgets: budgets, documentClasses: ["small"])
    let cancellation = report.results(kind: .cancellation).first
    #expect(cancellation?.status == .met)
    let ordinary = budgets.first { $0.kind == .firstPageDisplay }
    #expect(ordinary?.p95Milliseconds == InteractionBudget.ordinaryResponseP95Milliseconds)
  }

  @Test func reportCarriesFramingAndNoOverallScore() throws {
    let report = InteractionBudgetReport.evaluate(
      samples: [
        sample(.firstPageDisplay, 50), sample(.scroll, 60), sample(.zoom, 55),
        sample(.textPreview, 25), sample(.selection, 20), sample(.search, 200),
        sample(.cancellation, 400),
      ],
      context: context, documentClasses: ["small"])
    #expect(report.meetsDeclaredBudgets)
    #expect(report.isComplete)
    let markdown = report.markdown()
    #expect(markdown.contains(InteractionBudgetReport.framing))
    #expect(markdown.contains("not a product-wide performance claim"))
    #expect(markdown.lowercased().contains("never averaged into an overall score"))
    #expect(markdown.contains("Test host arm64"))
    #expect(markdown.contains("Met 7, missed 0, not measured 0."))
    guard let data = try? report.jsonData(),
      let decoded = try? JSONDecoder().decode(InteractionBudgetReport.self, from: data)
    else {
      Issue.record("The budget report must encode and decode")
      return
    }
    #expect(decoded == report)
  }

  @Test func missingContextAndInvalidSamplesAreIssuesNotSilentZeros() {
    let report = InteractionBudgetReport.evaluate(
      samples: [
        InteractionSample(kind: .scroll, milliseconds: -1, documentClass: "small")
      ],
      context: InteractionMeasurementContext(hardware: "", inputClass: "", methodology: ""),
      budgets: [])
    #expect(!report.isComplete)
    #expect(report.issues.contains { $0.contains("named hardware") })
    #expect(report.issues.contains { $0.contains("input class") })
    #expect(report.issues.contains { $0.contains("methodology") })
    #expect(report.issues.contains { $0.contains("invalid duration") })
    #expect(report.issues.contains { $0.contains("No interaction budgets") })
    #expect(!report.meetsDeclaredBudgets)
  }
}

@Suite("File coordination policy")
struct FileCoordinationPolicyTests {
  @Test func cleanStateIsTheOnlyUnaskedWrite() {
    let outcome = FileCoordinationPolicy.evaluate(FileCoordinationState(hasUnsavedWork: true))
    #expect(outcome.isSafeToWriteWithoutAsking)
    #expect(!outcome.requiresUserDecision)
    #expect(outcome.preservesUnsavedWork)
    #expect(outcome.resolutions.isEmpty)
  }

  @Test func everyConflictSurfacesAndKeepsWork() {
    let states: [FileCoordinationState] = [
      FileCoordinationState(sourceChangedExternally: true, hasUnsavedWork: true),
      FileCoordinationState(cloudConflictPresent: true, hasUnsavedWork: true),
      FileCoordinationState(fileMoved: true, hasUnsavedWork: true),
      FileCoordinationState(fileMissing: true, hasUnsavedWork: true),
      FileCoordinationState(
        availableBytes: 10, requiredBytes: 100, hasUnsavedWork: true),
      FileCoordinationState(writeWasInterrupted: true, hasUnsavedWork: true),
    ]
    for state in states {
      let outcome = FileCoordinationPolicy.evaluate(state)
      #expect(!outcome.isSafeToWriteWithoutAsking)
      #expect(outcome.requiresUserDecision)
      #expect(outcome.preservesUnsavedWork)
      #expect(!outcome.resolutions.isEmpty)
      #expect(!outcome.messages.isEmpty)
      // Every decision either keeps a copy/draft, retries or asks; none is a
      // silent overwrite.
      let silentOverwrite = outcome.resolutions.contains {
        $0.decision == .proceedNormally || $0.decision == .overwriteAfterConfirmation
      }
      #expect(!silentOverwrite)
    }
    #expect(FileCoordinationPolicy.guarantees.count >= 3)
  }

  @Test func conflictDecisionsAreSpecific() {
    let external = FileCoordinationPolicy.evaluate(
      FileCoordinationState(sourceChangedExternally: true, hasUnsavedWork: true))
    #expect(
      external.decisions[.externalModification] == .saveCopyWithPreservedDraft)
    let cleanExternal = FileCoordinationPolicy.evaluate(
      FileCoordinationState(sourceChangedExternally: true))
    #expect(cleanExternal.decisions[.externalModification] == .reloadFromDisk)

    let cloud = FileCoordinationPolicy.evaluate(
      FileCoordinationState(cloudConflictPresent: true, hasUnsavedWork: true))
    #expect(cloud.decisions[.cloudVersionConflict] == .resolveCloudConflictExplicitly)

    let lowDisk = FileCoordinationPolicy.evaluate(
      FileCoordinationState(availableBytes: 1, requiredBytes: 2, hasUnsavedWork: true))
    #expect(lowDisk.decisions[.lowDiskSpace] == .retryAfterSpaceAvailable)
    #expect(lowDisk.messages.contains { $0.contains("1 bytes available") })

    let interrupted = FileCoordinationPolicy.evaluate(
      FileCoordinationState(writeWasInterrupted: true, hasUnsavedWork: true))
    #expect(interrupted.decisions[.interruptedWrite] == .retryInterruptedWrite)

    let movedClean = FileCoordinationPolicy.evaluate(FileCoordinationState(fileMoved: true))
    #expect(movedClean.decisions[.movedFile] == .adoptMovedFile)
    let missingDirty = FileCoordinationPolicy.evaluate(
      FileCoordinationState(fileMissing: true, hasUnsavedWork: true))
    #expect(missingDirty.decisions[.missingFile] == .reportMissingFile)
  }

  @Test func lowDiskNeedsBothByteCounts() {
    let unknown = FileCoordinationPolicy.evaluate(
      FileCoordinationState(availableBytes: 5, hasUnsavedWork: true))
    #expect(unknown.decisions[.lowDiskSpace] == nil)
    #expect(unknown.isSafeToWriteWithoutAsking)
    let exact = FileCoordinationPolicy.evaluate(
      FileCoordinationState(availableBytes: 100, requiredBytes: 100))
    #expect(exact.decisions[.lowDiskSpace] == nil)
    #expect(FileCoordinationState(availableBytes: 99, requiredBytes: 100).lowDiskSpace)
  }

  @Test func combinedConflictsKeepPrecedenceAndAllNotes() throws {
    let state = FileCoordinationState(
      sourceChangedExternally: true, cloudConflictPresent: true, fileMoved: true,
      availableBytes: 1, requiredBytes: 10, writeWasInterrupted: true,
      hasUnsavedWork: true, recoveryRecordAvailable: true)
    #expect(
      state.conflicts
        == [.cloudVersionConflict, .interruptedWrite, .lowDiskSpace, .movedFile,
          .externalModification])
    let outcome = FileCoordinationPolicy.evaluate(state)
    #expect(outcome.resolutions.map(\.conflict) == state.conflicts)
    #expect(outcome.messages.count == state.conflicts.count)
    #expect(outcome.preservesUnsavedWork)
    guard let data = try? JSONEncoder().encode(outcome),
      let decoded = try? JSONDecoder().decode(FileCoordinationOutcome.self, from: data)
    else {
      Issue.record("The coordination outcome must encode and decode")
      return
    }
    #expect(decoded == outcome)
  }
}

@Suite("Process isolation decision")
struct ProcessIsolationDecisionTests {
  @Test func declaredRecordCoversEveryBoundaryAndClaimsNoIsolation() throws {
    let record = ProcessIsolationDecisionRecord.declared()
    #expect(record.isComplete)
    #expect(record.issues.isEmpty)
    #expect(record.keepInProcessCount == 4)
    #expect(record.deferredCount == 2)
    #expect(record.isolateDecisionCount == 0)
    #expect(!record.claimsImplementedIsolation)
    let markdown = record.markdown()
    #expect(markdown.contains(ProcessIsolationDecisionRecord.currentState))
    #expect(markdown.contains(ProcessIsolationDecisionRecord.containmentStatement))
    #expect(markdown.contains(ProcessIsolationDecisionRecord.noRewriteWithoutEvidence))
    #expect(markdown.contains("No XPC worker boundary is implemented"))
    #expect(markdown.contains("needed: Measured catastrophic malformed-input evidence"))
    guard let data = try? record.jsonData(),
      let decoded = try? JSONDecoder().decode(
        ProcessIsolationDecisionRecord.self, from: data)
    else {
      Issue.record("The isolation record must encode and decode")
      return
    }
    #expect(decoded == record)
  }

  @Test func isolationClaimsRequireMeasuredEvidenceAndLimits() {
    let unsupported = ProcessIsolationDecisionRecord(entries: [
      IsolationDecisionEntry(
        boundary: .parsingUntrustedFiles, decision: .isolateInWorkerProcess,
        rationale: "No evidence yet", failureContainment: "Worker", evidenceReference: "",
        evidenceStatus: .notMeasured)
    ])
    #expect(!unsupported.isComplete)
    #expect(unsupported.issues.contains { $0.contains("without measured evidence") })
    #expect(unsupported.issues.contains { $0.contains("no declared limits") })
  }

  @Test func deferredAndInProcessEntriesNeedTheirDeclarations() {
    let missing = ProcessIsolationDecisionRecord(entries: [
      IsolationDecisionEntry(
        boundary: .decodingFilters, decision: .deferWithEvidence,
        rationale: "Later", failureContainment: "Local", evidenceReference: ""),
      IsolationDecisionEntry(
        boundary: .pageRendering, decision: .keepInProcess,
        rationale: "Display", declaredResourceLimits: [], cancellation: "",
        failureContainment: ""),
    ])
    #expect(!missing.isComplete)
    #expect(missing.issues.contains { $0.contains("does not name the evidence") })
    #expect(missing.issues.contains { $0.contains("no declared limits") })
    #expect(missing.issues.contains { $0.contains("no containment") })
    // Every boundary is reported missing too.
    #expect(missing.issues.filter { $0.contains("missing from the record") }.count == 4)
  }

  @Test func duplicateBoundariesAreReported() {
    let record = ProcessIsolationDecisionRecord(entries: [
      IsolationDecisionEntry(
        boundary: .parsingUntrustedFiles, decision: .deferWithEvidence,
        rationale: "A", failureContainment: "Local", evidenceReference: "needed"),
      IsolationDecisionEntry(
        boundary: .parsingUntrustedFiles, decision: .keepInProcess,
        rationale: "B", declaredResourceLimits: ["PDFLimits"],
        cancellation: "Task cancellation", failureContainment: "Local"),
    ])
    #expect(record.issues.contains { $0.contains("Duplicate isolation boundary") })
    #expect(!record.isComplete)
  }
}
