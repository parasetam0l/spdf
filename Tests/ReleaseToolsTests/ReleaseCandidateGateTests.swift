import Foundation
import ReleaseTools
import Testing

/// REL-03: candidate binding, SHA/version/check/package manifest discipline and
/// the refusal to claim an unverified signed candidate.
struct ReleaseCandidateGateTests {
  private let sha = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

  private func check(
    _ id: String, status: ReleaseGateCheckStatus = .passed, sha: String? = nil
  ) -> ReleaseGateCheck {
    ReleaseGateCheck(
      id: id, category: "local", command: "swift test", status: status,
      evidence: "evidence/\(id).log", sourceSHA: sha ?? self.sha)
  }

  private func checks(
    installation: ReleaseGateCheckStatus = .notRun
  ) -> [ReleaseGateCheck] {
    [
      check(ReleaseGateChecks.build),
      check(ReleaseGateChecks.focusedTests),
      check(ReleaseGateChecks.appTypecheck),
      check(ReleaseGateChecks.installationWorkflows, status: installation),
    ]
  }

  private func environment(
    identity: Int = 1, notary: Bool = true
  ) -> ReleaseSigningEnvironment {
    ReleaseSigningEnvironment(
      signingIdentityCount: identity, notaryCredentialsConfigured: notary,
      codesignAvailable: true, staplerAvailable: true, gatekeeperAvailable: true)
  }

  private func package(
    signed: Bool = true, signature: Bool = true, notarized: Bool = true,
    gatekeeper: Bool = true, version: String = "0.1.0", sha: String? = nil
  ) -> ReleaseCandidatePackage {
    ReleaseCandidatePackage(
      path: "build/sPDF-0.1.0.dmg",
      sha256: String(repeating: "b", count: 64), sourceSHA: sha ?? self.sha,
      appVersion: version, signed: signed, signatureVerified: signature,
      notarizationStapled: notarized, gatekeeperAccepted: gatekeeper,
      teamIdentifier: "TEAM123456")
  }

  private func manifest(
    checks: [ReleaseGateCheck], package: ReleaseCandidatePackage? = nil,
    environment: ReleaseSigningEnvironment? = nil, clean: Bool = true
  ) throws -> ReleaseCandidateManifest {
    try ReleaseCandidateGate.makeManifest(
      sourceSHA: sha, appVersion: "0.1.0", buildVersion: "42",
      sourceTreeClean: clean, checks: checks, package: package,
      environment: environment ?? self.environment())
  }

  @Test func manifestDigestIsDeterministicAndStable() throws {
    let first = try manifest(checks: checks())
    let second = try manifest(checks: checks())
    #expect(first == second)
    #expect(first.manifestSHA256.count == 64)
    #expect(first.manifestSHA256 == second.manifestSHA256)
    let encoded = try ReleaseCandidateGate.encoded(first)
    let loaded = try ReleaseCandidateGate.load(data: encoded)
    #expect(loaded == first)
    let reencoded = try ReleaseCandidateGate.encoded(loaded)
    #expect(encoded == reencoded)
  }

  @Test func readyForOwnerSigningNeedsOwnerArtifactsAndInstallation() throws {
    let value = try manifest(
      checks: checks(installation: .notRun), environment: environment())
    let evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .readyForOwnerSigning)
    #expect(evaluation.ownerActionRequired)
    #expect(evaluation.blockers.contains(.packageMissing))
    #expect(evaluation.blockers.contains(.installationNotVerified))
    #expect(evaluation.blockers.contains(.ownerProductionRequired))
    #expect(evaluation.summary.contains("owner-gated"))
  }

  @Test func refusesWhenSigningIdentityIsUnavailable() throws {
    let value = try manifest(
      checks: checks(installation: .notRun),
      environment: environment(identity: 0, notary: false))
    let evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.signingIdentityUnavailable))
    #expect(evaluation.blockers.contains(.notaryCredentialsUnavailable))
    #expect(evaluation.summary.contains("owner-gated"))
  }

  @Test func refusesDirtySourceTree() throws {
    let value = try manifest(checks: checks(), clean: false)
    let evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.sourceTreeDirty))
  }

  @Test func refusesMissingFailedOrStaleChecks() throws {
    var rows = checks()
    rows.removeAll { $0.id == ReleaseGateChecks.appTypecheck }
    var evaluation = try ReleaseCandidateGate.validate(try manifest(checks: rows))
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.requiredCheckMissing))

    rows = checks()
    rows[0] = check(ReleaseGateChecks.build, status: .failed)
    evaluation = try ReleaseCandidateGate.validate(try manifest(checks: rows))
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.failedCheck))

    rows = checks()
    rows[1] = check(ReleaseGateChecks.focusedTests, sha: "ffeeddccbbaa99887766554433221100ffeeddcc")
    evaluation = try ReleaseCandidateGate.validate(try manifest(checks: rows))
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.staleCheckEvidence))
  }

  @Test func refusesUnboundOrTamperedManifest() throws {
    let value = try manifest(checks: checks())
    let tampered = ReleaseCandidateManifest(
      sourceSHA: "1111111111111111111111111111111111111111",
      appVersion: value.appVersion, buildVersion: value.buildVersion,
      sourceTreeClean: value.sourceTreeClean, checks: value.checks,
      package: value.package, environment: value.environment,
      manifestSHA256: value.manifestSHA256)
    let evaluation = try ReleaseCandidateGate.validate(tampered)
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.manifestDigestInvalid))

    let mismatch = try ReleaseCandidateGate.validate(
      value, expectedSourceSHA: "2222222222222222222222222222222222222222")
    #expect(mismatch.disposition == .refused)
    #expect(mismatch.blockers.contains(.expectedSourceMismatch))
    let versionMismatch = try ReleaseCandidateGate.validate(
      value, expectedAppVersion: "9.9.9")
    #expect(versionMismatch.blockers.contains(.expectedVersionMismatch))
  }

  @Test func verifiedCandidateRequiresSignedNotarizedInstalledPackage() throws {
    let value = try manifest(
      checks: checks(installation: .passed), package: package(),
      environment: environment())
    let evaluation = try ReleaseCandidateGate.validate(
      value, expectedPackageSHA256: String(repeating: "b", count: 64))
    #expect(evaluation.disposition == .verified)
    #expect(!evaluation.ownerActionRequired)
    #expect(evaluation.blockers.isEmpty)
    #expect(evaluation.summary.contains("verified"))
  }

  @Test func refusesUnsignedUnstapledOrWrongSourcePackage() throws {
    var value = try manifest(
      checks: checks(installation: .passed),
      package: package(signed: false, signature: false),
      environment: environment())
    var evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.packageUnsigned))
    #expect(evaluation.blockers.contains(.packageSignatureInvalid))

    value = try manifest(
      checks: checks(installation: .passed),
      package: package(notarized: false, gatekeeper: false),
      environment: environment())
    evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.notarizationNotVerified))
    #expect(evaluation.blockers.contains(.gatekeeperNotVerified))

    value = try manifest(
      checks: checks(installation: .passed),
      package: package(sha: "3333333333333333333333333333333333333333"),
      environment: environment())
    evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .refused)
    #expect(evaluation.blockers.contains(.packageSourceMismatch))
  }

  @Test func verifiedPackageWithoutInstallationRowStaysOwnerGated() throws {
    let value = try manifest(
      checks: checks(installation: .notRun), package: package(),
      environment: environment())
    let evaluation = try ReleaseCandidateGate.validate(value)
    #expect(evaluation.disposition == .readyForOwnerSigning)
    #expect(evaluation.ownerActionRequired)
    #expect(evaluation.blockers.contains(.installationNotVerified))
    #expect(evaluation.blockers.contains(.ownerProductionRequired))
  }

  @Test func releaseGateDefinitionDeclaresOwnerGatedSteps() {
    #expect(ReleaseCandidateDefinition.steps.count == 7)
    let ownerGated = ReleaseCandidateDefinition.ownerGatedSteps
    #expect(ownerGated.count == 4)
    #expect(ownerGated.contains { $0.stage == .ownerSigning })
    #expect(ownerGated.contains { $0.stage == .ownerNotarization })
    #expect(ownerGated.contains {
      $0.stage == .ownerInstallVerification && $0.required
    })
    #expect(ReleaseGateChecks.requiredIDs == [
      ReleaseGateChecks.build, ReleaseGateChecks.focusedTests,
      ReleaseGateChecks.appTypecheck, ReleaseGateChecks.installationWorkflows,
    ])
    #expect(ReleaseGateChecks.ownerOnlyIDs == [ReleaseGateChecks.installationWorkflows])
  }
}
