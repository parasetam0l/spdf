import CryptoKit
import Foundation

/// P41/P42 distribution policy: pure, secret-free update-selection,
/// feed-robustness, install-safety, and release-pipeline rules with their
/// tests in `Tests/ReleaseToolsTests`.
///
/// Nothing here reads secrets, performs network access, or signs anything:
/// workflows and the app supply inputs (feed bytes, asset files, installed
/// versions) and this module decides accept/reject/retry/migrate. Live
/// hosted behavior (real notarization, publication, Sparkle-driven
/// installation) stays owner-gated and is recorded as such in
/// `Docs/Updates.md` and `Docs/Releasing.md`.
public enum DistributionPolicyError: Error, CustomStringConvertible {
  case invalid(String)

  public var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}

// MARK: - P41-014/P41-015 update selection

/// One published update candidate, derived from a validated appcast item
/// plus the release metadata the feed carries.
public struct UpdateCandidate: Sendable, Equatable {
  public var shortVersion: String
  public var buildVersion: String
  public var minimumSystemVersion: String
  public var supportedArchitectures: [String]
  public var isDraft: Bool
  public var isPrerelease: Bool
  public var assetURL: String

  public init(
    shortVersion: String, buildVersion: String, minimumSystemVersion: String,
    supportedArchitectures: [String] = ["arm64"], isDraft: Bool = false,
    isPrerelease: Bool = false, assetURL: String = ""
  ) {
    self.shortVersion = shortVersion
    self.buildVersion = buildVersion
    self.minimumSystemVersion = minimumSystemVersion
    self.supportedArchitectures = supportedArchitectures
    self.isDraft = isDraft
    self.isPrerelease = isPrerelease
    self.assetURL = assetURL
  }
}

public struct InstalledApp: Sendable, Equatable {
  public var buildVersion: String
  public var systemVersion: String
  public var architecture: String

  public init(buildVersion: String, systemVersion: String, architecture: String) {
    self.buildVersion = buildVersion
    self.systemVersion = systemVersion
    self.architecture = architecture
  }
}

public enum UpdateSelection {
  /// Numeric dotted-version comparison ("14.2" < "14.10"; "9" < "10").
  /// Non-numeric segments compare as equal so malformed input fails safe
  /// (treated as incompatible, never as newer).
  public static func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
    let lParts = left.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let rParts = right.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    for index in 0..<max(lParts.count, rParts.count) {
      let l = index < lParts.count ? lParts[index] : "0"
      let r = index < rParts.count ? rParts[index] : "0"
      if let li = Int(l), let ri = Int(r) {
        if li != ri { return li < ri ? .orderedAscending : .orderedDescending }
      } else if l != r {
        return .orderedSame
      }
    }
    return .orderedSame
  }

  public static func isNewerBuild(_ candidate: String, than installed: String) -> Bool {
    if let c = Int(candidate), let i = Int(installed) { return c > i }
    return compareVersions(candidate, installed) == .orderedDescending
  }

  /// P41-014: a candidate installs only when the running system meets its
  /// minimum macOS, the architecture is supported, and its build is newer.
  /// Malformed versions fail safe to ineligible.
  public static func isEligible(_ candidate: UpdateCandidate, for installed: InstalledApp) -> Bool {
    guard !candidate.buildVersion.isEmpty, !candidate.minimumSystemVersion.isEmpty else {
      return false
    }
    guard compareVersions(installed.systemVersion, candidate.minimumSystemVersion)
      != .orderedAscending
    else { return false }
    guard candidate.supportedArchitectures.contains(installed.architecture) else { return false }
    return isNewerBuild(candidate.buildVersion, than: installed.buildVersion)
  }

  /// P41-015: stable installs never select drafts or prereleases. The
  /// newest eligible stable candidate wins; beta channels stay explicit
  /// future work and are never implied by this selection.
  public static func selectStable(
    from candidates: [UpdateCandidate], for installed: InstalledApp
  ) -> UpdateCandidate? {
    let stable = candidates.filter { !$0.isDraft && !$0.isPrerelease }
    let eligible = stable.filter { isEligible($0, for: installed) }
    return eligible.max { left, right in
      compareVersions(left.buildVersion, right.buildVersion) == .orderedAscending
    }
  }
}

// MARK: - P41-025 equal/older rejection and manual rollback

public enum UpdateVersionVerdict: Sendable, Equatable {
  case upgrade
  case equalBuild
  case olderBuild
  case incompatibleSystem
  case incompatibleArchitecture
}

public enum UpdateVersionCheck {
  public static func check(_ candidate: UpdateCandidate, for installed: InstalledApp) -> UpdateVersionVerdict
  {
    if UpdateSelection.compareVersions(installed.systemVersion, candidate.minimumSystemVersion)
      == .orderedAscending
    {
      return .incompatibleSystem
    }
    if !candidate.supportedArchitectures.contains(installed.architecture) {
      return .incompatibleArchitecture
    }
    if candidate.buildVersion == installed.buildVersion { return .equalBuild }
    if UpdateSelection.isNewerBuild(candidate.buildVersion, than: installed.buildVersion) {
      return .upgrade
    }
    return .olderBuild
  }

  /// Downgrades never go through the updater: the user reinstalls the older
  /// published DMG by hand. This text is shared by the app guidance and
  /// the release notes.
  public static var rollbackGuidance: String {
    "The updater never downgrades. To return to an older version, download "
      + "that version's published DMG from GitHub Releases, quit sPDF Editor, "
      + "replace the app, and reopen; documents are never touched by "
      + "replacing the app. Back up preferences and recovery state first "
      + "(see Docs/Updates.md)."
  }
}

// MARK: - P41-023 offline, rate-limit, and stale-feed handling

public enum FeedFailure: Sendable, Equatable {
  case offline
  case rateLimited(retryAfterSeconds: Int?)
  case missingFeed
  case staleCachedFeed(ageSeconds: Int)
  case interruptedDownload
}

public enum FeedPolicy {
  /// Bounded backoff with no busy retrying: exponential from 60 s capped
  /// at one hour, honoring the server's Retry-After when larger. Failures
  /// never block document work (`blocksDocumentWork` is always false).
  public static func retryDelay(failures: Int, retryAfterSeconds: Int? = nil) -> TimeInterval {
    let clamped = max(1, failures)
    let backoff = min(3_600.0, 60.0 * pow(2.0, Double(min(clamped, 7) - 1)))
    if let retryAfterSeconds, retryAfterSeconds > 0 {
      return min(3_600.0, max(backoff, Double(retryAfterSeconds)))
    }
    return backoff
  }

  public static func blocksDocumentWork(_ failure: FeedFailure) -> Bool { false }

  public static func describe(_ failure: FeedFailure) -> String {
    switch failure {
    case .offline:
      return "The update check found no network. Document work is unaffected; the next scheduled check retries."
    case .rateLimited(let retryAfter):
      if let retryAfter {
        return "GitHub rate-limited the check. Retrying after \(retryAfter) s; document work is unaffected."
      }
      return "GitHub rate-limited the check. Backing off; document work is unaffected."
    case .missingFeed:
      return "The feed is missing (unpublished release or wrong repository). Check for Updates stays available; document work is unaffected."
    case .staleCachedFeed(let age):
      return "The cached feed is \(age) s old and no fresher copy arrived. The app keeps the installed version; document work is unaffected."
    case .interruptedDownload:
      return "The download was interrupted. The installed app is untouched; retry the download explicitly."
    }
  }
}

// MARK: - P41-016/P42-022 signed-feed and release-note policy

public enum SignedFeedPolicy {
  public static var policyDescription: String {
    "Feeds are validated before use: well-formed RSS with one HTTPS "
      + "enclosure per item, a 64-byte Ed25519 signature per enclosure, an "
      + "enclosure length matching the asset, and a signature that verifies "
      + "against the SUPublicEDKey of the packaged app. Invalid or missing "
      + "signatures are rejected with no unsigned fallback. Edited feeds are "
      + "re-signed and re-validated before upload."
  }

  /// Validate a feed and, when an asset is supplied, its length and EdDSA
  /// signature against the packaged app's public key.
  public static func validate(
    feed: Data, assetURL: URL? = nil, publicKeyBase64: String? = nil
  ) throws -> [AppcastEntry] {
    try AppcastValidator.validate(data: feed, assetURL: assetURL, publicKeyBase64: publicKeyBase64)
  }
}

// MARK: - P41-022 install locations (shared with P40-023)

public enum InstallLocation: Sendable, Equatable {
  case applications
  case userWritableDirectory(path: String)
  case diskImage
  case translocatedOrReadOnly
  case other(path: String)

  /// Pure classification from observable facts; the app layer detects
  /// translocation (quarantine + randomized path) and writability, which
  /// keeps this policy unit-testable without touching /Applications.
  public static func classify(
    appPath: String, isWritable: Bool, isTranslocated: Bool, isOnDiskImage: Bool
  ) -> InstallLocation {
    if isTranslocated || !isWritable { return .translocatedOrReadOnly }
    if isOnDiskImage { return .diskImage }
    if appPath == "/Applications/sPDF Editor.app"
      || appPath.hasPrefix("/Applications/")
    {
      return .applications
    }
    if !appPath.isEmpty { return .userWritableDirectory(path: appPath) }
    return .other(path: appPath)
  }

  public var guidance: String {
    switch self {
    case .applications:
      return "Installed in /Applications: updates install in place after the document checks pass."
    case .userWritableDirectory(let path):
      return
        "Installed at \(path): updates install in place. Prefer /Applications for shared machines."
    case .diskImage:
      return
        "Running from a mounted disk image: copy sPDF Editor to /Applications first; updates cannot install onto the image."
    case .translocatedOrReadOnly:
      return
        "Running translocated or read-only (quarantined download): move sPDF Editor to /Applications, launch it once from there, then check for updates."
    case .other(let path):
      return "Installed at \(path.isEmpty ? "an unknown location" : path): confirm the app launches from a writable location before updating."
    }
  }
}

// MARK: - P41-026 install-failure recovery

public enum InstallProblem: Sendable, Equatable {
  case canceledByUser
  case insufficientDiskSpace(requiredBytes: Int)
  case missingWritePermission
  case interruptedRelaunch
}

public struct InstallRecovery: Sendable, Equatable {
  public var installedAppUsable: Bool
  public var recoverySteps: [String]

  public static func recovery(for problem: InstallProblem) -> InstallRecovery {
    switch problem {
    case .canceledByUser:
      return InstallRecovery(
        installedAppUsable: true,
        recoverySteps: [
          "The installed app is untouched. Re-run Check for Updates… when ready."
        ])
    case .insufficientDiskSpace(let required):
      return InstallRecovery(
        installedAppUsable: true,
        recoverySteps: [
          "The installed app is untouched. Free at least \(required) bytes, then retry the update explicitly."
        ])
    case .missingWritePermission:
      return InstallRecovery(
        installedAppUsable: true,
        recoverySteps: [
          "The installed app is untouched. Move sPDF Editor to a writable location (for example /Applications) or fix ownership, then retry."
        ])
    case .interruptedRelaunch:
      return InstallRecovery(
        installedAppUsable: true,
        recoverySteps: [
          "Launch sPDF Editor from its installed location; open documents recover from autosave/recovery state.",
          "If the new copy fails to launch, replace it with the previous published DMG (see the rollback guidance) and report the failure.",
        ])
    }
  }
}

// MARK: - P41-009 update preferences and P41-028 migration

/// Versioned update preferences. The schema version travels with the data
/// so older and newer app copies never misread each other silently.
public struct UpdatePreferences: Codable, Sendable, Equatable {
  public static let currentSchema = 1
  public static let automaticCheckInterval: TimeInterval = 86_400

  public var schema: Int
  public var automaticallyChecks: Bool
  public var lastCheckDate: Date?
  public var skippedBuild: String?

  public init(
    schema: Int = UpdatePreferences.currentSchema, automaticallyChecks: Bool = false,
    lastCheckDate: Date? = nil, skippedBuild: String? = nil
  ) {
    self.schema = schema
    self.automaticallyChecks = automaticallyChecks
    self.lastCheckDate = lastCheckDate
    self.skippedBuild = skippedBuild
  }
}

public enum PreferencesMigration {
  /// Migrate stored preferences: the current schema loads as-is; the
  /// legacy unversioned shape (`{"automatic": Bool}`) upgrades with a
  /// backup kept; unknown future schemas refuse so a newer app's data is
  /// never silently misread by an older one.
  public static func migrate(data: Data) throws -> (preferences: UpdatePreferences, keepBackup: Bool)
  {
    let decoder = JSONDecoder()
    if let current = try? decoder.decode(UpdatePreferences.self, from: data) {
      guard current.schema == UpdatePreferences.currentSchema else {
        throw DistributionPolicyError.invalid(
          "Unsupported preferences schema \(current.schema); kept for a newer app copy.")
      }
      return (current, false)
    }
    struct Legacy: Decodable { var automatic: Bool }
    if let legacy = try? decoder.decode(Legacy.self, from: data) {
      return (UpdatePreferences(automaticallyChecks: legacy.automatic), true)
    }
    throw DistributionPolicyError.invalid("Update preferences are not recognized JSON.")
  }

  public static func encode(_ preferences: UpdatePreferences) throws -> Data {
    var normalized = preferences
    normalized.schema = UpdatePreferences.currentSchema
    return try JSONEncoder().encode(normalized)
  }
}

// MARK: - P41-019/P41-020/P41-021 update readiness and relaunch state

/// A snapshot of document work the app hands to the updater gate. The app
/// collects it from NSDocument state; this module only evaluates it, which
/// keeps the rules unit-testable without a running app.
public struct DocumentUpdateState: Sendable, Equatable {
  public var dirtyDocumentCount: Int
  public var saveAsInProgress: Bool
  public var windowCount: Int
  public var backgroundJobCount: Int
  public var atomicSaveInProgress: Bool
  public var unresolvedFailedSave: Bool

  public init(
    dirtyDocumentCount: Int = 0, saveAsInProgress: Bool = false, windowCount: Int = 0,
    backgroundJobCount: Int = 0, atomicSaveInProgress: Bool = false,
    unresolvedFailedSave: Bool = false
  ) {
    self.dirtyDocumentCount = dirtyDocumentCount
    self.saveAsInProgress = saveAsInProgress
    self.windowCount = windowCount
    self.backgroundJobCount = backgroundJobCount
    self.atomicSaveInProgress = atomicSaveInProgress
    self.unresolvedFailedSave = unresolvedFailedSave
  }
}

public struct UpdateReadiness: Sendable, Equatable {
  /// Whether the updater may proceed to termination once the user confirms.
  public var mayProceed: Bool
  /// Prompts the normal termination path must still show (never bypassed).
  public var userPrompts: [String]
  /// Conditions that must clear first; non-empty means `mayProceed` is false.
  public var blockers: [String]
  /// Whether background jobs must be finished or cancelled first.
  public var requiresJobSettlement: Bool

  public static func evaluate(_ state: DocumentUpdateState) -> UpdateReadiness {
    var blockers: [String] = []
    var prompts: [String] = []
    if state.saveAsInProgress {
      blockers.append("A Save As panel is open: finish or cancel it before updating.")
    }
    if state.atomicSaveInProgress {
      blockers.append("A verified save is in flight: let it finish before updating.")
    }
    if state.unresolvedFailedSave {
      blockers.append(
        "A save failed and is unresolved: retry, Save As…, or revert before updating.")
    }
    if state.dirtyDocumentCount > 0 {
      prompts.append(
        "\(state.dirtyDocumentCount) dirty document(s) will be offered Save / Don't Save / Cancel through the normal termination path; a canceled save cancels the update.")
    }
    if state.windowCount > 1 {
      prompts.append(
        "\(state.windowCount) windows are open: every window goes through the same save decision.")
    }
    return UpdateReadiness(
      mayProceed: blockers.isEmpty,
      userPrompts: prompts,
      blockers: blockers,
      requiresJobSettlement: state.backgroundJobCount > 0)
  }
}

/// What survives an update relaunch: window identities, settings, and
/// file-access bookmarks. Protected documents still follow keychain and
/// recovery rules (no passwords travel here).
public struct RelaunchState: Codable, Sendable, Equatable {
  public var schema: Int
  public var openWindowIDs: [String]
  public var settingsVersion: Int
  public var bookmarkedFileCount: Int

  public init(
    schema: Int = 1, openWindowIDs: [String] = [], settingsVersion: Int = 1,
    bookmarkedFileCount: Int = 0
  ) {
    self.schema = schema
    self.openWindowIDs = openWindowIDs
    self.settingsVersion = settingsVersion
    self.bookmarkedFileCount = bookmarkedFileCount
  }
}

public enum RelaunchRestore {
  /// Restore windows, settings, and bookmarks saved before the update,
  /// keeping a rollback-compatible backup of the previous schema when the
  /// versions differ.
  public static func plan(
    saved: RelaunchState, supportedSettings: Int
  ) -> (restoreWindows: [String], keepSettingsBackup: Bool, restoreBookmarks: Int) {
    let backup = saved.settingsVersion != supportedSettings
    return (saved.openWindowIDs, backup, saved.bookmarkedFileCount)
  }
}

// MARK: - P42-006 monotonic build versions

public enum BuildVersionPolicy {
  /// Reject duplicate or moved release tags before any work starts.
  public static func isDuplicateTag(_ tag: String, existingTags: [String]) -> Bool {
    existingTags.contains(tag)
  }

  /// The next build number is one above the highest previously published
  /// numeric build (the release workflow passes `date +%s`; reruns and
  /// repair jobs must never reuse a lower number).
  public static func nextBuild(after previousBuilds: [String], now: Int = Int(Date().timeIntervalSince1970))
    -> String
  {
    let highest = previousBuilds.compactMap(Int.init).max() ?? 0
    return String(max(highest + 1, now))
  }

  public static func isMonotonic(_ build: String, after previousBuilds: [String]) -> Bool {
    guard let value = Int(build) else { return false }
    let highest = previousBuilds.compactMap(Int.init).max() ?? 0
    return value > highest
  }
}

// MARK: - P42-014 notary resume before resubmission

public enum NotaryOutcome: Sendable, Equatable {
  case accepted
  case inProgress
  case rejected
  case timeout
  case authenticationFailure
  case transientServiceError
}

public enum NotaryAction: Sendable, Equatable {
  case accept
  case waitAndResume(submissionID: String)
  case resumeByIDBeforeResubmitting(submissionID: String)
  case fixAuthentication
  case refuseToAdvance(reason: String)
}

public enum NotaryResume {
  /// Timeouts, rejections, and transient errors resume status by
  /// submission ID before any resubmission; authentication failures stop
  /// for credential repair; anything else refuses to advance.
  public static func action(for outcome: NotaryOutcome, submissionID: String?) -> NotaryAction {
    switch outcome {
    case .accepted:
      return .accept
    case .inProgress:
      return .waitAndResume(submissionID: submissionID ?? "")
    case .timeout, .transientServiceError:
      guard let submissionID, !submissionID.isEmpty else {
        return .refuseToAdvance(reason: "No submission ID to resume; refusing blind resubmission.")
      }
      return .resumeByIDBeforeResubmitting(submissionID: submissionID)
    case .rejected:
      if let submissionID, !submissionID.isEmpty {
        return .resumeByIDBeforeResubmitting(submissionID: submissionID)
      }
      return .refuseToAdvance(reason: "Rejected without a submission ID; refusing to advance.")
    case .authenticationFailure:
      return .fixAuthentication
    }
  }
}

// MARK: - P42-021 compatible appcast history

public struct HistoricRelease: Sendable, Equatable {
  public var shortVersion: String
  public var buildVersion: String
  public var minimumSystemVersion: String
  public var isDraft: Bool
  public var isPrerelease: Bool
  public var assetURL: String

  public init(
    shortVersion: String, buildVersion: String, minimumSystemVersion: String,
    isDraft: Bool = false, isPrerelease: Bool = false, assetURL: String = ""
  ) {
    self.shortVersion = shortVersion
    self.buildVersion = buildVersion
    self.minimumSystemVersion = minimumSystemVersion
    self.isDraft = isDraft
    self.isPrerelease = isPrerelease
    self.assetURL = assetURL
  }
}

public enum FeedHistory {
  /// The stable feed keeps full archives only: drafts and prereleases never
  /// appear, and older-baseline releases stay listed below newer ones so
  /// compatible history survives a macOS/app baseline change. Newest first.
  public static func stableItems(from releases: [HistoricRelease]) -> [HistoricRelease] {
    releases.filter { !$0.isDraft && !$0.isPrerelease }.sorted { left, right in
      UpdateSelection.compareVersions(left.buildVersion, right.buildVersion) == .orderedDescending
    }
  }
}

// MARK: - P42-025 idempotent reruns

public struct PublishedAsset: Sendable, Equatable {
  public var name: String
  public var sha256: String
  public var length: Int

  public init(name: String, sha256: String, length: Int) {
    self.name = name
    self.sha256 = sha256
    self.length = length
  }
}

public enum RerunAction: Sendable, Equatable {
  /// Identical bytes already published: reuse them, never re-upload.
  case reusePublished
  /// Same name with different bytes: refuse rather than replace a release.
  case refuseReplacement(reason: String)
  /// Nothing published under this name: upload.
  case upload
  /// The appcast may be re-signed and re-uploaded (trusted repair only);
  /// binaries never are.
  case resignFeed
}

public enum RerunPolicy {
  public static func assetAction(existing: PublishedAsset?, name: String, sha256: String, length: Int)
    -> RerunAction
  {
    guard let existing else { return .upload }
    guard existing.name == name else { return .upload }
    if existing.sha256 == sha256 && existing.length == length { return .reusePublished }
    return .refuseReplacement(
      reason:
        "Published asset \(name) already exists with different bytes; a corrected binary is a new, higher version.")
  }

  public static func mayClobberAsset(named name: String) -> Bool {
    // Only the feed itself may be re-signed/repaired in place; every
    // binary name is immutable once published.
    name == "appcast.xml"
  }
}

// MARK: - P42-026 upload and post-publication verification

public enum UploadVerification {
  /// Verify an uploaded asset before trusting it: HTTPS URL on the release
  /// host under an immutable version path, byte length match, SHA-256
  /// match, and an EdDSA signature that verifies against the packaged
  /// app's public key.
  public static func verify(
    asset: Data, expectedLength: Int, expectedSHA256: String,
    signatureBase64: String, publicKeyBase64: String, fileURL: URL, downloadURL: String
  ) throws {
    guard let url = URL(string: downloadURL), url.scheme == "https" else {
      throw DistributionPolicyError.invalid("The download URL is not HTTPS: \(downloadURL)")
    }
    guard downloadURL.contains("/releases/download/") else {
      throw DistributionPolicyError.invalid(
        "The download URL is not an immutable version-specific release asset: \(downloadURL)")
    }
    guard asset.count == expectedLength else {
      throw DistributionPolicyError.invalid(
        "Length mismatch: asset has \(asset.count) bytes, expected \(expectedLength).")
    }
    try asset.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let digest = sha256Hex(asset)
    guard digest == expectedSHA256.lowercased() else {
      throw DistributionPolicyError.invalid("SHA-256 mismatch for the uploaded asset.")
    }
    let valid = try UpdateSignature.verify(
      publicKeyBase64: publicKeyBase64, signatureBase64: signatureBase64, fileURL: fileURL)
    guard valid else {
      throw DistributionPolicyError.invalid("The final signature does not match the asset.")
    }
  }

  public static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - P42-027 pipeline failure drills (never advance an incomplete release)

public enum PipelineStage: Sendable, Equatable {
  case secrets
  case certificateImport
  case archive
  case nestedSigning
  case notarization
  case packaging
  case upload
  case cleanup
}

public enum PipelineGate {
  public static func checkSecrets(_ present: Set<String>, required: Set<String>) throws {
    let missing = required.subtracting(present)
    guard missing.isEmpty else {
      throw DistributionPolicyError.invalid(
        "Missing repository secrets: \(missing.sorted().joined(separator: ", ")).")
    }
  }

  public static func checkSignatureValid(_ valid: Bool, stage: String) throws {
    guard valid else {
      throw DistributionPolicyError.invalid("\(stage): signature check failed; refusing to advance.")
    }
  }

  public static func checkNotaryAccepted(_ status: String, submissionID: String) throws {
    guard status == "Accepted" else {
      throw DistributionPolicyError.invalid(
        "Notarization ended with status '\(status)' (id \(submissionID)); refusing to advance.")
    }
  }

  public static func checkUploadComplete(uploadedBytes: Int, expectedBytes: Int) throws {
    guard uploadedBytes == expectedBytes, expectedBytes > 0 else {
      throw DistributionPolicyError.invalid(
        "Partial upload (\(uploadedBytes)/\(expectedBytes) bytes); refusing to advance.")
    }
  }

  /// Every stage's failure refuses to advance: the drill matrix calls each
  /// gate with failing input and requires a throw, plus a canceled run
  /// that cleans up without publishing.
  public static func checkCanceled(_ canceled: Bool) throws {
    if canceled {
      throw DistributionPolicyError.invalid("The run was canceled; cleaned up without publishing.")
    }
  }
}

// MARK: - P42-029 certificate expiry, key backup/rotation, bridge releases

public struct SigningIdentityPolicy {
  /// Whole days from `now` until `expiry`; negative when expired.
  public static func daysUntilExpiry(expiry: Date, now: Date) -> Int {
    Int((expiry.timeIntervalSince1970 - now.timeIntervalSince1970) / 86_400)
  }

  public static func needsRenewal(expiry: Date, now: Date, warnWithinDays: Int = 60) -> Bool {
    daysUntilExpiry(expiry: expiry, now: now) <= warnWithinDays
  }

  /// Key rotation acceptance: the new key verifies new assets, the old key
  /// still verifies previously published assets, and the new key must not
  /// retroactively claim old assets. Bridge releases stay signed with the
  /// still-trusted key until the feed policy changes.
  public static func rotationAccepts(
    oldKeyVerifiesOldAsset: Bool, newKeyVerifiesNewAsset: Bool, newKeyVerifiesOldAsset: Bool
  ) -> Bool {
    oldKeyVerifiesOldAsset && newKeyVerifiesNewAsset && !newKeyVerifiesOldAsset
  }

  public static var backupRule: String {
    "The Sparkle private key lives in the owner's keychain with an offline "
      + "backup outside the repository; the repository holds only the public "
      + "half (SUPublicEDKey). Losing the private key requires a compatible "
      + "bridge release signed with the still-trusted Apple identity that "
      + "introduces the new update key before the old one is retired."
  }
}
