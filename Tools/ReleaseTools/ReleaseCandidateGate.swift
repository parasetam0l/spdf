import CryptoKit
import Foundation

// REL-03: candidate production from the chosen final source.
//
// The gate binds one candidate manifest together: source SHA, app/build version,
// required-check evidence (each row bound to the same source SHA), a
// signed/notarized package digest, the observed signing environment, and a
// manifest digest. It never signs or notarizes: producing the signed/notarized
// artifact and installing it for workflow verification is an owner-gated action.
// If the required signing identity/notarization credentials are absent, the gate
// refuses to present the candidate as ready and states the refusal explicitly.

public enum ReleaseGateProfile {
  public static let identifier = "spdf-release-candidate-gate-v1"
  public static let schemaVersion = 1
}

/// REL-03: one required check row. Evidence is only valid for the exact source
/// SHA it was produced from; a row from an older candidate is refused.
public enum ReleaseGateCheckStatus: String, Codable, Sendable, CaseIterable {
  case passed
  case failed
  case refused
  case notRun
}

public struct ReleaseGateCheck: Codable, Sendable, Equatable {
  public let id: String
  public let category: String
  public let command: String
  public let status: ReleaseGateCheckStatus
  public let evidence: String
  /// The source SHA the evidence was produced from.
  public let sourceSHA: String
  public let note: String

  public init(
    id: String, category: String, command: String, status: ReleaseGateCheckStatus,
    evidence: String, sourceSHA: String, note: String = ""
  ) {
    self.id = id
    self.category = category
    self.command = command
    self.status = status
    self.evidence = evidence
    self.sourceSHA = sourceSHA
    self.note = note
  }
}

/// REL-03: environment observation used to refuse a locally "produced" candidate
/// when the identity or notarization credentials are not available. The gate
/// never invokes signing itself.
public struct ReleaseSigningEnvironment: Codable, Sendable, Equatable {
  public let signingIdentityCount: Int
  public let notaryCredentialsConfigured: Bool
  public let codesignAvailable: Bool
  public let staplerAvailable: Bool
  public let gatekeeperAvailable: Bool

  public init(
    signingIdentityCount: Int, notaryCredentialsConfigured: Bool,
    codesignAvailable: Bool, staplerAvailable: Bool, gatekeeperAvailable: Bool
  ) {
    self.signingIdentityCount = signingIdentityCount
    self.notaryCredentialsConfigured = notaryCredentialsConfigured
    self.codesignAvailable = codesignAvailable
    self.staplerAvailable = staplerAvailable
    self.gatekeeperAvailable = gatekeeperAvailable
  }

  public static let none = ReleaseSigningEnvironment(
    signingIdentityCount: 0, notaryCredentialsConfigured: false,
    codesignAvailable: false, staplerAvailable: false, gatekeeperAvailable: false)
}

/// REL-03: the owner-produced package, verified by read-only tools.
public struct ReleaseCandidatePackage: Codable, Sendable, Equatable {
  public let path: String
  public let sha256: String
  public let sourceSHA: String
  public let appVersion: String
  public let signed: Bool
  public let signatureVerified: Bool
  public let notarizationStapled: Bool
  public let gatekeeperAccepted: Bool
  public let teamIdentifier: String

  public init(
    path: String, sha256: String, sourceSHA: String, appVersion: String,
    signed: Bool, signatureVerified: Bool, notarizationStapled: Bool,
    gatekeeperAccepted: Bool, teamIdentifier: String
  ) {
    self.path = path
    self.sha256 = sha256
    self.sourceSHA = sourceSHA
    self.appVersion = appVersion
    self.signed = signed
    self.signatureVerified = signatureVerified
    self.notarizationStapled = notarizationStapled
    self.gatekeeperAccepted = gatekeeperAccepted
    self.teamIdentifier = teamIdentifier
  }
}

/// REL-03: what the gate found. The disposition is separate from the blocker
/// list so "ready for owner signing" is never presented as a verified release.
public enum ReleaseGateDisposition: String, Codable, Sendable, Equatable {
  /// The candidate definition is valid; the owner must sign, notarize, staple,
  /// install and run the changed workflows on the exact candidate.
  case readyForOwnerSigning
  /// A package is bound and its signature, notarization, Gatekeeper result and
  /// owner installation/workflow check were all verified for the same source SHA.
  case verified
  /// At least one blocking condition exists; the candidate must not be claimed.
  case refused
}

public enum ReleaseGateBlocker: String, Codable, Sendable, CaseIterable {
  case sourceSHAUnresolved
  case sourceTreeDirty
  case requiredCheckMissing
  case requiredCheckNotPassed
  case failedCheck
  case staleCheckEvidence
  case manifestDigestInvalid
  case expectedSourceMismatch
  case expectedVersionMismatch
  case packageMissing
  case packageDigestMismatch
  case packageUnsigned
  case packageSignatureInvalid
  case packageSourceMismatch
  case packageVersionMismatch
  case notarizationNotVerified
  case gatekeeperNotVerified
  case installationNotVerified
  case signingIdentityUnavailable
  case notaryCredentialsUnavailable
  case ownerProductionRequired

  public var title: String {
    switch self {
    case .sourceSHAUnresolved: return "source SHA is not resolved"
    case .sourceTreeDirty: return "source tree has uncommitted changes"
    case .requiredCheckMissing: return "a required check row is missing"
    case .requiredCheckNotPassed: return "a required check did not pass"
    case .failedCheck: return "a check failed"
    case .staleCheckEvidence: return "check evidence belongs to a different source SHA"
    case .manifestDigestInvalid: return "the manifest digest does not match its payload"
    case .expectedSourceMismatch: return "the manifest source SHA is not the expected candidate"
    case .expectedVersionMismatch: return "the manifest app version is not the expected version"
    case .packageMissing: return "no signed/notarized package is bound"
    case .packageDigestMismatch: return "the package digest does not match the manifest"
    case .packageUnsigned: return "the package is not signed"
    case .packageSignatureInvalid: return "the package signature did not verify"
    case .packageSourceMismatch: return "the package was not built from the manifest source SHA"
    case .packageVersionMismatch: return "the package app version does not match the manifest"
    case .notarizationNotVerified: return "notarization/staple verification did not pass"
    case .gatekeeperNotVerified: return "Gatekeeper assessment did not pass"
    case .installationNotVerified: return "installation/workflow verification on the candidate did not pass"
    case .signingIdentityUnavailable: return "no Developer ID signing identity is available"
    case .notaryCredentialsUnavailable: return "notarization credentials are not configured"
    case .ownerProductionRequired: return "signed/notarized candidate production is an owner-gated action"
    }
  }
}

public struct ReleaseGateEvaluation: Codable, Sendable, Equatable {
  public let profileIdentifier: String
  public let disposition: ReleaseGateDisposition
  public let blockers: [ReleaseGateBlocker]
  public let sourceSHA: String
  public let appVersion: String
  public let ownerActionRequired: Bool
  public let summary: String

  public init(
    profileIdentifier: String = ReleaseGateProfile.identifier,
    disposition: ReleaseGateDisposition, blockers: [ReleaseGateBlocker],
    sourceSHA: String, appVersion: String, ownerActionRequired: Bool, summary: String
  ) {
    self.profileIdentifier = profileIdentifier
    self.disposition = disposition
    self.blockers = blockers
    self.sourceSHA = sourceSHA
    self.appVersion = appVersion
    self.ownerActionRequired = ownerActionRequired
    self.summary = summary
  }
}

/// REL-03: the required-check set for this profile. The candidate gate refuses a
/// manifest that does not carry every row bound to its source SHA.
public enum ReleaseGateChecks {
  public static let build = "build"
  public static let focusedTests = "focused-tests"
  public static let appTypecheck = "app-typecheck"
  public static let installationWorkflows = "installation-workflows"

  /// Checks the gate itself can only observe locally; the owner must sign,
  /// notarize, staple and install before the last row can pass.
  public static let requiredIDs = [build, focusedTests, appTypecheck, installationWorkflows]
  public static let ownerOnlyIDs: Set<String> = [installationWorkflows]
}

/// REL-03: the reproducible release-gate definition. Local steps are checks;
/// signing, notarization and installation are owner-gated and are never run by
/// this tool.
public struct ReleaseGateStep: Codable, Sendable, Equatable {
  public enum Stage: String, Codable, Sendable, Equatable {
    case localCheck
    case ownerSigning
    case ownerNotarization
    case ownerInstallVerification
  }

  public let id: String
  public let stage: Stage
  public let command: String
  public let required: Bool
  public let note: String

  public init(
    id: String, stage: Stage, command: String, required: Bool, note: String
  ) {
    self.id = id
    self.stage = stage
    self.command = command
    self.required = required
    self.note = note
  }
}

public enum ReleaseCandidateDefinition {
  public static let steps: [ReleaseGateStep] = [
    ReleaseGateStep(
      id: ReleaseGateChecks.build, stage: .localCheck,
      command: "swift build --package-path <checkout> --product <app-adjacent product>",
      required: true,
      note: "Build the exact source revision; bind the output to the source SHA."),
    ReleaseGateStep(
      id: ReleaseGateChecks.focusedTests, stage: .localCheck,
      command: "swift test --package-path <checkout> --filter <changed rows>",
      required: true,
      note: "Focused suites for the changed rows; record the log path as evidence."),
    ReleaseGateStep(
      id: ReleaseGateChecks.appTypecheck, stage: .localCheck,
      command:
        "swiftc -typecheck -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 "
        + "-sdk <sdk> -I <modules> App/*.swift App/Diagnostics/*.swift",
      required: true,
      note: "Every App source including the changed panels must typecheck."),
    ReleaseGateStep(
      id: "owner-build-archive", stage: .ownerSigning,
      command:
        "xcodebuild archive -project SPDF.xcodeproj -scheme sPDF -configuration Release "
        + "-archivePath <archive>",
      required: false,
      note: "Owner-gated: the tool never archives, signs or claims an unverified candidate."),
    ReleaseGateStep(
      id: "owner-sign-export", stage: .ownerSigning,
      command:
        "xcodebuild -exportArchive ... / codesign --options runtime --timestamp ...",
      required: false,
      note: "Owner-gated: requires a Developer ID identity and its credentials."),
    ReleaseGateStep(
      id: "owner-notarize", stage: .ownerNotarization,
      command:
        "xcrun notarytool submit <package> --wait && xcrun stapler staple <package>",
      required: false,
      note: "Owner-gated: requires notarization credentials; record the submission id."),
    ReleaseGateStep(
      id: "owner-install-workflows", stage: .ownerInstallVerification,
      command:
        "install the stapled candidate on a quarantined test account and run the changed "
        + "workflows; record screenshots/logs bound to the candidate digest",
      required: true,
      note: "Required for the Done criterion; cannot be satisfied before the owner produces "
        + "the signed/notarized candidate."),
  ]

  public static var ownerGatedSteps: [ReleaseGateStep] {
    steps.filter { $0.stage != .localCheck }
  }
}

/// REL-03: one candidate manifest. The manifest digest covers every field except
/// itself, so the SHA/version/check/package binding cannot be edited or
/// recombined across candidates without detection.
public struct ReleaseCandidateManifest: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let profileIdentifier: String
  public let sourceSHA: String
  public let appVersion: String
  public let buildVersion: String
  public let sourceTreeClean: Bool
  public let checks: [ReleaseGateCheck]
  public let package: ReleaseCandidatePackage?
  public let environment: ReleaseSigningEnvironment
  public let manifestSHA256: String

  public init(
    schemaVersion: Int = ReleaseGateProfile.schemaVersion,
    profileIdentifier: String = ReleaseGateProfile.identifier,
    sourceSHA: String, appVersion: String, buildVersion: String,
    sourceTreeClean: Bool, checks: [ReleaseGateCheck],
    package: ReleaseCandidatePackage?, environment: ReleaseSigningEnvironment,
    manifestSHA256: String
  ) {
    self.schemaVersion = schemaVersion
    self.profileIdentifier = profileIdentifier
    self.sourceSHA = sourceSHA
    self.appVersion = appVersion
    self.buildVersion = buildVersion
    self.sourceTreeClean = sourceTreeClean
    self.checks = checks
    self.package = package
    self.environment = environment
    self.manifestSHA256 = manifestSHA256
  }

  public func check(id: String) -> ReleaseGateCheck? {
    checks.first { $0.id == id }
  }
}

public enum ReleaseCandidateGate {
  private struct DigestPayload: Codable {
    let schemaVersion: Int
    let profileIdentifier: String
    let sourceSHA: String
    let appVersion: String
    let buildVersion: String
    let sourceTreeClean: Bool
    let checks: [ReleaseGateCheck]
    let package: ReleaseCandidatePackage?
    let environment: ReleaseSigningEnvironment
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func payload(for manifest: ReleaseCandidateManifest) -> DigestPayload {
    DigestPayload(
      schemaVersion: manifest.schemaVersion,
      profileIdentifier: manifest.profileIdentifier,
      sourceSHA: manifest.sourceSHA,
      appVersion: manifest.appVersion,
      buildVersion: manifest.buildVersion,
      sourceTreeClean: manifest.sourceTreeClean,
      checks: manifest.checks,
      package: manifest.package,
      environment: manifest.environment)
  }

  private static func canonicalDigest(_ manifest: ReleaseCandidateManifest) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256(try encoder.encode(payload(for: manifest)))
  }

  /// Build a manifest and bind its digest in one deterministic step.
  public static func makeManifest(
    sourceSHA: String, appVersion: String, buildVersion: String,
    sourceTreeClean: Bool, checks: [ReleaseGateCheck],
    package: ReleaseCandidatePackage?, environment: ReleaseSigningEnvironment
  ) throws -> ReleaseCandidateManifest {
    let draft = ReleaseCandidateManifest(
      sourceSHA: sourceSHA, appVersion: appVersion, buildVersion: buildVersion,
      sourceTreeClean: sourceTreeClean, checks: checks, package: package,
      environment: environment, manifestSHA256: "")
    return ReleaseCandidateManifest(
      schemaVersion: draft.schemaVersion, profileIdentifier: draft.profileIdentifier,
      sourceSHA: draft.sourceSHA, appVersion: draft.appVersion,
      buildVersion: draft.buildVersion, sourceTreeClean: draft.sourceTreeClean,
      checks: draft.checks, package: draft.package, environment: draft.environment,
      manifestSHA256: try canonicalDigest(draft))
  }

  public static func encoded(_ manifest: ReleaseCandidateManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
    return try encoder.encode(manifest)
  }

  public static func load(data: Data) throws -> ReleaseCandidateManifest {
    try JSONDecoder().decode(ReleaseCandidateManifest.self, from: data)
  }

  public static func write(_ manifest: ReleaseCandidateManifest, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded(manifest).write(to: url, options: .atomic)
  }

  /// Evaluate one manifest. This is the release gate: no checklist count or
  /// partial package is ever reported as a verified candidate.
  public static func validate(
    _ manifest: ReleaseCandidateManifest,
    expectedSourceSHA: String? = nil,
    expectedAppVersion: String? = nil,
    expectedPackageSHA256: String? = nil
  ) throws -> ReleaseGateEvaluation {
    var blockers: Set<ReleaseGateBlocker> = []

    let sourceSHA = manifest.sourceSHA.trimmingCharacters(in: .whitespacesAndNewlines)
    if sourceSHA.isEmpty { blockers.insert(.sourceSHAUnresolved) }
    if sourceSHA.count < 7 { blockers.insert(.sourceSHAUnresolved) }
    if !manifest.sourceTreeClean { blockers.insert(.sourceTreeDirty) }
    if !manifest.profileIdentifier.isEmpty,
      manifest.profileIdentifier != ReleaseGateProfile.identifier
    {
      blockers.insert(.manifestDigestInvalid)
    }
    if let expectedSourceSHA, expectedSourceSHA != manifest.sourceSHA {
      blockers.insert(.expectedSourceMismatch)
    }
    if let expectedAppVersion, expectedAppVersion != manifest.appVersion {
      blockers.insert(.expectedVersionMismatch)
    }
    if let expectedPackageSHA256, let package = manifest.package,
      package.sha256 != expectedPackageSHA256
    {
      blockers.insert(.packageDigestMismatch)
    }
    if (try? canonicalDigest(manifest)) != manifest.manifestSHA256 {
      blockers.insert(.manifestDigestInvalid)
    }

    for id in ReleaseGateChecks.requiredIDs {
      let ownerOnly = ReleaseGateChecks.ownerOnlyIDs.contains(id)
      guard let row = manifest.check(id: id) else {
        if ownerOnly {
          blockers.insert(.installationNotVerified)
        } else {
          blockers.insert(.requiredCheckMissing)
        }
        continue
      }
      if row.sourceSHA != manifest.sourceSHA {
        blockers.insert(.staleCheckEvidence)
      }
      switch row.status {
      case .passed:
        break
      case .failed:
        blockers.insert(.failedCheck)
      case .refused, .notRun:
        if ownerOnly {
          blockers.insert(.installationNotVerified)
        } else {
          blockers.insert(.requiredCheckNotPassed)
        }
      }
    }
    for row in manifest.checks where row.status == .failed {
      blockers.insert(.failedCheck)
    }

    let environment = manifest.environment
    if environment.signingIdentityCount == 0 {
      blockers.insert(.signingIdentityUnavailable)
    }
    if !environment.notaryCredentialsConfigured {
      blockers.insert(.notaryCredentialsUnavailable)
    }

    var packageVerified = false
    if let package = manifest.package {
      if !package.signed { blockers.insert(.packageUnsigned) }
      if !package.signatureVerified { blockers.insert(.packageSignatureInvalid) }
      if package.sourceSHA != manifest.sourceSHA {
        blockers.insert(.packageSourceMismatch)
      }
      if package.appVersion != manifest.appVersion {
        blockers.insert(.packageVersionMismatch)
      }
      if package.sha256.count != 64 || package.sha256.contains(where: { !$0.isHexDigit }) {
        blockers.insert(.packageDigestMismatch)
      }
      if !package.notarizationStapled {
        blockers.insert(.notarizationNotVerified)
      }
      if !package.gatekeeperAccepted {
        blockers.insert(.gatekeeperNotVerified)
      }
      packageVerified = package.signed && package.signatureVerified
        && package.notarizationStapled && package.gatekeeperAccepted
        && package.sourceSHA == manifest.sourceSHA
        && package.appVersion == manifest.appVersion
        && package.sha256.count == 64
    } else {
      blockers.insert(.packageMissing)
    }

    let installationPassed =
      manifest.check(id: ReleaseGateChecks.installationWorkflows)?.status == .passed
    if !installationPassed { blockers.insert(.installationNotVerified) }

    let hardBlockers: Set<ReleaseGateBlocker> = [
      .sourceSHAUnresolved, .sourceTreeDirty, .requiredCheckMissing,
      .requiredCheckNotPassed, .failedCheck, .staleCheckEvidence,
      .manifestDigestInvalid, .expectedSourceMismatch, .expectedVersionMismatch,
      .packageDigestMismatch, .packageUnsigned, .packageSignatureInvalid,
      .packageSourceMismatch, .packageVersionMismatch,
      .notarizationNotVerified, .gatekeeperNotVerified,
    ]
    let disposition: ReleaseGateDisposition
    if !blockers.isDisjoint(with: hardBlockers) {
      disposition = .refused
    } else if packageVerified && installationPassed {
      disposition = .verified
    } else if manifest.package != nil {
      disposition = .readyForOwnerSigning
      blockers.insert(.ownerProductionRequired)
    } else {
      // No package yet. Without a signing identity the gate refuses rather than
      // implying a candidate can be produced here; with one it is ready for the
      // owner to sign/notarize/staple/install and re-run the gate with the package.
      if environment.signingIdentityCount == 0 {
        disposition = .refused
      } else {
        disposition = .readyForOwnerSigning
      }
      blockers.insert(.ownerProductionRequired)
    }
    if disposition != .verified {
      if environment.signingIdentityCount == 0 {
        blockers.insert(.signingIdentityUnavailable)
      }
      if !environment.notaryCredentialsConfigured {
        blockers.insert(.notaryCredentialsUnavailable)
      }
      blockers.insert(.ownerProductionRequired)
    }
    let ordered = ReleaseGateBlocker.allCases.filter { blockers.contains($0) }
    let ownerActionRequired = disposition != .verified
    var summaryParts: [String] = [
      "Candidate \(manifest.sourceSHA.isEmpty ? "<unresolved>" : manifest.sourceSHA) "
        + "(version \(manifest.appVersion)): \(disposition.rawValue).",
    ]
    if ordered.isEmpty {
      summaryParts.append("No blockers.")
    } else {
      summaryParts.append(
        "Blockers: " + ordered.map(\.title).joined(separator: "; ") + ".")
    }
    if ownerActionRequired {
      summaryParts.append(
        "Signing, notarization and installation verification on the exact candidate are "
          + "owner-gated actions; this manifest never represents a signed candidate.")
    }
    return ReleaseGateEvaluation(
      disposition: disposition, blockers: ordered, sourceSHA: manifest.sourceSHA,
      appVersion: manifest.appVersion, ownerActionRequired: ownerActionRequired,
      summary: summaryParts.joined(separator: " "))
  }
}

