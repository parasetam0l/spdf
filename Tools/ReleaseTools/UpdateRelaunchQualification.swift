import Foundation

/// REL-04: a reproducible update/relaunch qualification record.
///
/// The live feed, signed publication, installation and reopened app are owner
/// actions: this type cannot perform them and never reports them as passed on
/// its own. It evaluates the evidence an owner gate records, runs the shipped
/// eligibility/readiness/relaunch rules against that evidence, and reports each
/// check separately (passed / failed / not-run / blocked on the owner). Only a
/// record with every required check passed and an explicit owner publication
/// and reopen reference is qualified.
public enum QualificationCheckStatus: String, Codable, Sendable, CaseIterable {
  case passed
  case failed
  case notRun
  case blockedOwnerAction

  public var displayName: String {
    switch self {
    case .passed: return "Passed"
    case .failed: return "Failed"
    case .notRun: return "Not run"
    case .blockedOwnerAction: return "Blocked (owner action)"
    }
  }
}

public struct QualificationCheck: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var status: QualificationCheckStatus
  /// Where the evidence lives. Required for a passed or failed check.
  public var evidenceReference: String
  public var detail: String

  public init(
    id: String, title: String, status: QualificationCheckStatus,
    evidenceReference: String = "", detail: String
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.evidenceReference = evidenceReference
    self.detail = detail
  }
}

/// The publication facts the owner's release process recorded. Absence of any
/// required field keeps the live-feed checks blocked instead of guessed.
public struct PublishedReleaseEvidence: Codable, Sendable, Equatable {
  public var version: String
  public var build: String
  public var sourceSHA: String
  public var feedURL: String
  public var assetFileName: String
  public var assetSHA256: String
  public var assetSizeBytes: Int
  public var feedSignatureValid: Bool
  public var appSignatureValid: Bool
  public var notarizedAndStapled: Bool
  public var publishedAt: Date
  public var publicationReference: String

  public init(
    version: String, build: String, sourceSHA: String, feedURL: String,
    assetFileName: String, assetSHA256: String, assetSizeBytes: Int,
    feedSignatureValid: Bool, appSignatureValid: Bool, notarizedAndStapled: Bool,
    publishedAt: Date, publicationReference: String
  ) {
    self.version = version
    self.build = build
    self.sourceSHA = sourceSHA
    self.feedURL = feedURL
    self.assetFileName = assetFileName
    self.assetSHA256 = assetSHA256
    self.assetSizeBytes = assetSizeBytes
    self.feedSignatureValid = feedSignatureValid
    self.appSignatureValid = appSignatureValid
    self.notarizedAndStapled = notarizedAndStapled
    self.publishedAt = publishedAt
    self.publicationReference = publicationReference
  }

  public var isComplete: Bool {
    !version.isEmpty && !build.isEmpty && sourceSHA.count >= 40 && feedURL.hasPrefix("https://")
      && !assetFileName.isEmpty && assetSHA256.count == 64
      && assetSizeBytes > 0 && feedSignatureValid && appSignatureValid
      && notarizedAndStapled && !publicationReference.isEmpty
  }
}

/// The installed-copy facts observed by the app smoke/tools.
public struct InstalledReleaseEvidence: Codable, Sendable, Equatable {
  public var installedVersion: String
  public var installedBuild: String
  /// Version/build that was replaced by this update; defaults to the installed
  /// values (which makes an equal-build candidate ineligible).
  public var priorVersion: String
  public var priorBuild: String
  public var installPath: String
  public var installWritable: Bool
  public var translocated: Bool
  public var onDiskImage: Bool
  public var runningSignatureValid: Bool
  public var systemVersion: String
  public var architecture: String

  public init(
    installedVersion: String, installedBuild: String, priorVersion: String = "",
    priorBuild: String = "", installPath: String, installWritable: Bool,
    translocated: Bool, onDiskImage: Bool, runningSignatureValid: Bool,
    systemVersion: String, architecture: String
  ) {
    self.installedVersion = installedVersion
    self.installedBuild = installedBuild
    self.priorVersion = priorVersion.isEmpty ? installedVersion : priorVersion
    self.priorBuild = priorBuild.isEmpty ? installedBuild : priorBuild
    self.installPath = installPath
    self.installWritable = installWritable
    self.translocated = translocated
    self.onDiskImage = onDiskImage
    self.runningSignatureValid = runningSignatureValid
    self.systemVersion = systemVersion
    self.architecture = architecture
  }
}

/// What the relaunch actually restored. Expected counts come from the pending
/// work snapshot; a zero-document relaunch passes only when zero were pending.
public struct RelaunchRestoreEvidence: Codable, Sendable, Equatable {
  public var pendingDocumentCount: Int
  public var restoredDocumentCount: Int
  public var restoredSettings: Bool
  public var keptSettingsBackup: Bool
  public var reopenedSafely: Bool
  public var recoveryReference: String

  public init(
    pendingDocumentCount: Int, restoredDocumentCount: Int, restoredSettings: Bool,
    keptSettingsBackup: Bool, reopenedSafely: Bool, recoveryReference: String
  ) {
    self.pendingDocumentCount = pendingDocumentCount
    self.restoredDocumentCount = restoredDocumentCount
    self.restoredSettings = restoredSettings
    self.keptSettingsBackup = keptSettingsBackup
    self.reopenedSafely = reopenedSafely
    self.recoveryReference = recoveryReference
  }
}

/// The qualification input. Nil evidence means the owner has not produced it;
/// the matching checks stay blocked rather than invented.
public struct UpdateRelaunchQualificationInput: Sendable, Equatable {
  public var publication: PublishedReleaseEvidence?
  public var installed: InstalledReleaseEvidence?
  public var updateState: DocumentUpdateState?
  public var savedRelaunch: RelaunchState?
  public var restore: RelaunchRestoreEvidence?
  public var supportedSettingsVersion: Int
  /// True only when live interactive save-cancel/writeback was exercised.
  public var interactiveWritebackExercised: Bool
  public var interactiveWritebackReference: String

  public init(
    publication: PublishedReleaseEvidence? = nil,
    installed: InstalledReleaseEvidence? = nil,
    updateState: DocumentUpdateState? = nil,
    savedRelaunch: RelaunchState? = nil,
    restore: RelaunchRestoreEvidence? = nil,
    supportedSettingsVersion: Int = 1,
    interactiveWritebackExercised: Bool = false,
    interactiveWritebackReference: String = ""
  ) {
    self.publication = publication
    self.installed = installed
    self.updateState = updateState
    self.savedRelaunch = savedRelaunch
    self.restore = restore
    self.supportedSettingsVersion = supportedSettingsVersion
    self.interactiveWritebackExercised = interactiveWritebackExercised
    self.interactiveWritebackReference = interactiveWritebackReference
  }
}

public struct UpdateRelaunchQualification: Codable, Sendable, Equatable {
  public enum Verdict: String, Codable, Sendable {
    case qualified
    case incomplete
    case failed
    case blockedOwnerAction
  }

  public static let claimStatement =
    "This record qualifies the update/relaunch path only when the owner's published "
    + "signed release evidence and the reopened-app evidence are present and every "
    + "required check passes. Publication remains the owner's action; this record does "
    + "not publish, install or relaunch anything, and it is not an Acrobat-replacement "
    + "or notarization claim."

  public static let notClaimed: [String] = [
    "Performing the publication, download, installation or relaunch (owner actions).",
    "Independent third-party security review of the updater.",
    "Owner workflow acceptance (REL-05, recorded separately).",
    "Any behavior of a release not represented by the evidence references above.",
  ]

  public let checks: [QualificationCheck]
  public let verdict: Verdict
  public let issues: [String]

  public init(input: UpdateRelaunchQualificationInput) {
    var checks: [QualificationCheck] = []
    var issues: [String] = []

    func add(
      _ id: String, _ title: String, _ status: QualificationCheckStatus,
      reference: String = "", _ detail: String
    ) {
      if (status == .passed || status == .failed), reference.isEmpty {
        issues.append("Check \(id) is \(status.rawValue) without an evidence reference")
      }
      checks.append(
        QualificationCheck(
          id: id, title: title, status: status, evidenceReference: reference,
          detail: detail))
    }

    // 1. Owner publication.
    if let publication = input.publication, publication.isComplete {
      add(
        "publication", "Owner-published signed release recorded", .passed,
        reference: publication.publicationReference,
        "Version " + publication.version + " build " + publication.build
          + " from " + publication.sourceSHA + " is published at " + publication.feedURL + ".")
    } else if let publication = input.publication {
      add(
        "publication", "Owner-published signed release recorded", .failed,
        reference: publication.publicationReference,
        "The publication evidence is incomplete (feed/signature/digest/reference).")
    } else {
      add(
        "publication", "Owner-published signed release recorded", .blockedOwnerAction,
        "No owner publication evidence was recorded; publication is the owner's action.")
    }

    // 2. Candidate eligibility and monotonic versions.
    if let publication = input.publication, let installed = input.installed {
      let candidate = UpdateCandidate(
        shortVersion: publication.version, buildVersion: publication.build,
        minimumSystemVersion: installed.systemVersion,
        supportedArchitectures: [installed.architecture], isDraft: false,
        isPrerelease: false,
        assetURL: "https://github.com/parasetam0l/spdf/releases/download/v"
          + publication.version + "/" + publication.assetFileName)
      let priorApp = InstalledApp(
        buildVersion: installed.priorBuild, systemVersion: installed.systemVersion,
        architecture: installed.architecture)
      let newer = UpdateSelection.isNewerBuild(publication.build, than: installed.priorBuild)
      let verdict = UpdateVersionCheck.check(candidate, for: priorApp)
      if newer, verdict != .olderBuild, verdict != .equalBuild, verdict != .incompatibleSystem {
        add(
          "eligibility", "Published candidate is newer and eligible", .passed,
          reference: publication.publicationReference,
          "Published build " + publication.build + " is newer than installed "
            + installed.installedBuild + "; selection accepted it.")
      } else {
        add(
          "eligibility", "Published candidate is newer and eligible", .failed,
          reference: publication.publicationReference,
          "Build/version eligibility failed: newer=\(newer), verdict=\(verdict).")
      }
    } else {
      add(
        "eligibility", "Published candidate is newer and eligible", .notRun,
        "Eligibility needs both publication and installed-copy evidence.")
    }

    // 3. Signed feed and asset verification.
    if let publication = input.publication {
      if publication.feedSignatureValid && publication.appSignatureValid,
        publication.assetSHA256.count == 64, publication.assetSizeBytes > 0
      {
        add(
          "signatures", "Feed, asset digest and app signature verified", .passed,
          reference: publication.publicationReference,
          "EdDSA feed signature, 64-byte SHA-256 asset digest and Developer ID app "
            + "signature are recorded as verified for " + publication.assetFileName + ".")
      } else {
        add(
          "signatures", "Feed, asset digest and app signature verified", .failed,
          reference: publication.publicationReference,
          "Signature/digest evidence is missing or invalid.")
      }
    } else {
      add(
        "signatures", "Feed, asset digest and app signature verified", .blockedOwnerAction,
        "Signatures can only be verified against the owner's published assets.")
    }

    // 4. Install location guidance.
    if let installed = input.installed {
      let location = InstallLocation.classify(
        appPath: installed.installPath, isWritable: installed.installWritable,
        isTranslocated: installed.translocated, isOnDiskImage: installed.onDiskImage)
      switch location {
      case .applications, .userWritableDirectory:
        if installed.runningSignatureValid {
          add(
            "install-location", "Installed app can be updated in place", .passed,
            reference: installed.installPath, location.guidance)
        } else {
          add(
            "install-location", "Installed app can be updated in place", .failed,
            reference: installed.installPath,
            "The runnable copy's signature is not valid; do not update from it.")
        }
      case .diskImage, .translocatedOrReadOnly, .other:
        add(
          "install-location", "Installed app can be updated in place", .failed,
          reference: installed.installPath, location.guidance)
      }
    } else {
      add(
        "install-location", "Installed app can be updated in place", .notRun,
        "No installed-copy evidence.")
    }

    // 5. Document/job readiness gate.
    if let state = input.updateState {
      let readiness = UpdateReadiness.evaluate(state)
      if readiness.mayProceed {
        add(
          "readiness", "Document and job gate permits the update", .passed,
          reference: "DocumentUpdateState",
          "No blockers; " + (readiness.requiresJobSettlement ? "jobs must settle first; " : "")
            + readiness.userPrompts.joined(separator: " "))
      } else {
        add(
          "readiness", "Document and job gate permits the update", .failed,
          reference: "DocumentUpdateState", readiness.blockers.joined(separator: " "))
      }
    } else {
      add(
        "readiness", "Document and job gate permits the update", .notRun,
        "No pending-work snapshot was recorded.")
    }

    // 6. Relaunch state plan and restore.
    if let saved = input.savedRelaunch, let restore = input.restore {
      let plan = RelaunchRestore.plan(
        saved: saved, supportedSettings: input.supportedSettingsVersion)
      var failures: [String] = []
      if restore.restoredDocumentCount != restore.pendingDocumentCount {
        failures.append(
          "restored \(restore.restoredDocumentCount) of \(restore.pendingDocumentCount) pending document(s)")
      }
      if plan.restoreWindows != saved.openWindowIDs {
        failures.append("window identities were not restored")
      }
      if saved.settingsVersion != input.supportedSettingsVersion,
        !restore.keptSettingsBackup
      {
        failures.append("settings schema changed without keeping a backup")
      }
      if !restore.reopenedSafely {
        failures.append("the updated app did not reopen safely")
      }
      let reference = restore.recoveryReference
      if failures.isEmpty {
        add(
          "relaunch-restore", "Pending documents/settings restore safely after relaunch", .passed,
          reference: reference,
          "\(restore.restoredDocumentCount) document(s) and settings restored; backup kept: "
            + (restore.keptSettingsBackup ? "yes" : "no") + ".")
      } else {
        add(
          "relaunch-restore", "Pending documents/settings restore safely after relaunch", .failed,
          reference: reference, failures.joined(separator: "; "))
      }
    } else {
      add(
        "relaunch-restore", "Pending documents/settings restore safely after relaunch", .notRun,
        "No relaunch/restore evidence was recorded.")
    }

    // 7. Reinstalled version confirmation.
    if let publication = input.publication, let installed = input.installed {
      if installed.installedVersion == publication.version
        && installed.installedBuild == publication.build
      {
        add(
          "reopened-version", "The intended signed release is the running release", .passed,
          reference: input.restore?.recoveryReference ?? publication.publicationReference,
          "Running " + installed.installedVersion + " (" + installed.installedBuild
            + ") matches the published release.")
      } else {
        add(
          "reopened-version", "The intended signed release is the running release", .failed,
          reference: publication.publicationReference,
          "Running " + installed.installedVersion + " (" + installed.installedBuild
            + ") does not match published " + publication.version + " ("
            + publication.build + ").")
      }
    } else {
      add(
        "reopened-version", "The intended signed release is the running release", .notRun,
        "Needs publication and reopened-app evidence.")
    }

    // 8. Interactive writeback (the app-level save decision wiring).
    if input.interactiveWritebackExercised {
      if input.interactiveWritebackReference.isEmpty {
        issues.append("The interactive writeback check passed without an evidence reference")
        add(
          "interactive-writeback", "Normal save/cancel path wired to the update gate", .failed,
          "A claimed interactive pass has no reference.")
      } else {
        add(
          "interactive-writeback", "Normal save/cancel path wired to the update gate", .passed,
          reference: input.interactiveWritebackReference,
          "A canceled save aborted the update in a real interactive session.")
      }
    } else {
      add(
        "interactive-writeback", "Normal save/cancel path wired to the update gate", .notRun,
        "The save-cancel/writeback path needs an interactive session and has not run here.")
    }

    let failed = checks.filter { $0.status == .failed }
    let blocked = checks.filter { $0.status == .blockedOwnerAction }
    let notRun = checks.filter { $0.status == .notRun }
    let verdict: Verdict
    if !failed.isEmpty {
      verdict = .failed
    } else if !blocked.isEmpty {
      verdict = .blockedOwnerAction
    } else if !notRun.isEmpty {
      verdict = .incomplete
    } else {
      verdict = .qualified
    }
    self.checks = checks
    self.verdict = verdict
    self.issues = issues
  }

  public var passedChecks: [QualificationCheck] { checks.filter { $0.status == .passed } }
  public var isQualified: Bool { verdict == .qualified }

  public func markdown() -> String {
    var lines = [
      "# Update/relaunch qualification (REL-04)", "",
      UpdateRelaunchQualification.claimStatement, "",
      "Verdict: \(verdict.rawValue)",
      "",
      "| Check | Status | Evidence | Detail |",
      "| --- | --- | --- | --- |",
    ]
    for check in checks {
      lines.append(
        "| \(check.title) | \(check.status.displayName) | "
          + "\(check.evidenceReference.isEmpty ? "—" : check.evidenceReference) | "
          + "\(check.detail) |")
    }
    if !issues.isEmpty {
      lines.append("")
      lines.append("## Record issues")
      for issue in issues { lines.append("- " + issue) }
    }
    lines.append("")
    lines.append("## Not claimed")
    for item in UpdateRelaunchQualification.notClaimed { lines.append("- " + item) }
    return lines.joined(separator: "\n")
  }

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}
