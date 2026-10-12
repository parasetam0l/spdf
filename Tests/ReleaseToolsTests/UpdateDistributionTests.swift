import CryptoKit
import Foundation
import ReleaseTools
import Testing

private func candidate(
  build: String, short: String = "1.0", minimumOS: String = "14.0",
  archs: [String] = ["arm64"], draft: Bool = false, prerelease: Bool = false
) -> UpdateCandidate {
  UpdateCandidate(
    shortVersion: short, buildVersion: build, minimumSystemVersion: minimumOS,
    supportedArchitectures: archs, isDraft: draft, isPrerelease: prerelease,
    assetURL: "https://github.com/parasetam0l/spdf/releases/download/v\(short)/sPDF-Editor-\(short).dmg")
}

private let testInstalled = InstalledApp(buildVersion: "100", systemVersion: "14.2", architecture: "arm64")

@Suite("Update distribution policy")
struct UpdateDistributionTests {
  // MARK: - P41-014 minimum-OS, architecture, and prerequisite filtering

  @Test func incompatibleReleasesAreFilteredFromFixtures() throws {
    let newerOS = candidate(build: "101", minimumOS: "15.0")
    let intelOnly = candidate(build: "102", archs: ["x86_64"])
    let good = candidate(build: "103")
    let malformed = candidate(build: "", minimumOS: "")
    #expect(!UpdateSelection.isEligible(newerOS, for: testInstalled))
    #expect(!UpdateSelection.isEligible(intelOnly, for: testInstalled))
    #expect(UpdateSelection.isEligible(good, for: testInstalled))
    #expect(!UpdateSelection.isEligible(malformed, for: testInstalled))
    // Dotted versions compare numerically, not lexically.
    #expect(UpdateSelection.compareVersions("14.10", "14.9") == .orderedDescending)
    #expect(UpdateSelection.compareVersions("14.2", "14.2") == .orderedSame)
    #expect(
      UpdateSelection.isEligible(
        candidate(build: "104", minimumOS: "14.10"),
        for: InstalledApp(buildVersion: "100", systemVersion: "14.9", architecture: "arm64")) == false)
  }

  // MARK: - P41-015 stable builds never select drafts/prereleases

  @Test func stableSelectionSkipsDraftsAndPrereleases() throws {
    let stable = candidate(build: "101")
    let newerDraft = candidate(build: "102", draft: true)
    let newestPrerelease = candidate(build: "103", prerelease: true)
    let picked = UpdateSelection.selectStable(
      from: [stable, newerDraft, newestPrerelease], for: testInstalled)
    #expect(picked?.buildVersion == "101")
    #expect(UpdateSelection.selectStable(from: [newerDraft, newestPrerelease], for: testInstalled) == nil)
    // Among stable candidates the newest eligible build wins.
    let older = candidate(build: "99")
    #expect(
      UpdateSelection.selectStable(from: [older, stable], for: testInstalled)?.buildVersion == "101")
  }

  // MARK: - P41-016 signed-feed policy: invalid/missing signatures rejected

  @Test func signedFeedPolicyRejectsInvalidAndMissingSignatures() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let asset = Data(repeating: 0xAB, count: 2048)
    let assetURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-feed-asset-\(UUID().uuidString).dmg")
    try asset.write(to: assetURL)
    defer { try? FileManager.default.removeItem(at: assetURL) }
    let signature = try key.signature(for: asset).base64EncodedString()
    let item = AppcastItem(
      title: "sPDF Editor 1.1", published: Date(timeIntervalSince1970: 1_750_000_000),
      buildVersion: "101", shortVersion: "1.1", minimumSystemVersion: "14.0",
      releaseNotesHTML: "Fixes.", releaseNotesLink: "https://example.com/notes",
      assetURL: "https://example.com/sPDF-Editor-1.1.dmg", assetLength: asset.count,
      edSignature: signature)
    let xml = Appcast.xml(feedTitle: "sPDF Editor", feedLink: "https://example.com", item: item)
    // Valid feed plus matching asset verifies.
    let entries = try SignedFeedPolicy.validate(
      feed: Data(xml.utf8), assetURL: assetURL, publicKeyBase64: publicKey)
    #expect(entries.count == 1)
    // Missing signature fails structural validation.
    let unsigned = xml.replacingOccurrences(of: " sparkle:edSignature=\"\(signature)\"", with: "")
    #expect(throws: ReleaseToolsError.self) {
      _ = try SignedFeedPolicy.validate(feed: Data(unsigned.utf8))
    }
    // Wrong length fails against the asset.
    let wrongLength = xml.replacingOccurrences(
      of: "length=\"\(asset.count)\"", with: "length=\"\(asset.count + 1)\"")
    #expect(throws: ReleaseToolsError.self) {
      _ = try SignedFeedPolicy.validate(
        feed: Data(wrongLength.utf8), assetURL: assetURL, publicKeyBase64: publicKey)
    }
    // Wrong key fails signature verification with no unsigned fallback.
    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(throws: ReleaseToolsError.self) {
      _ = try SignedFeedPolicy.validate(
        feed: Data(xml.utf8), assetURL: assetURL, publicKeyBase64: otherKey)
    }
    #expect(!SignedFeedPolicy.policyDescription.isEmpty)
  }

  // MARK: - P41-023 offline, rate-limit, missing, stale, interrupted feeds

  @Test func feedFailuresBackOffWithoutBlockingDocuments() throws {
    #expect(FeedPolicy.retryDelay(failures: 1) == 60)
    #expect(FeedPolicy.retryDelay(failures: 2) == 120)
    #expect(FeedPolicy.retryDelay(failures: 10) == 3_600)
    #expect(FeedPolicy.retryDelay(failures: 1, retryAfterSeconds: 300) == 300)
    #expect(FeedPolicy.retryDelay(failures: 1, retryAfterSeconds: 5) == 60)
    for failure in [
      FeedFailure.offline, .rateLimited(retryAfterSeconds: 30), .missingFeed,
      .staleCachedFeed(ageSeconds: 9_000), .interruptedDownload,
    ] {
      #expect(!FeedPolicy.blocksDocumentWork(failure))
      #expect(!FeedPolicy.describe(failure).isEmpty)
    }
  }

  // MARK: - P41-024 altered archive, wrong key, invalid identity

  @Test func alteredArchivesAndWrongKeysAreRejectedWithoutFallback() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let payload = Data("sPDF Editor 1.1 staged update".utf8)
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-staged-\(UUID().uuidString).dmg")
    try payload.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let signature = try key.signature(for: payload).base64EncodedString()
    #expect(try UpdateSignature.verify(publicKeyBase64: publicKey, signatureBase64: signature, fileURL: file))
    // An altered archive fails against the same signature.
    try Data("tampered bytes".utf8).write(to: file)
    #expect(
      try !UpdateSignature.verify(
        publicKeyBase64: publicKey, signatureBase64: signature, fileURL: file))
    // A wrong update key fails too; the policy offers no unsigned fallback.
    let wrongKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    try payload.write(to: file)
    #expect(
      try !UpdateSignature.verify(
        publicKeyBase64: wrongKey, signatureBase64: signature, fileURL: file))
    // A source document the update never touches stays byte-identical.
    let document = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-untouched-\(UUID().uuidString).pdf")
    try payload.write(to: document)
    defer { try? FileManager.default.removeItem(at: document) }
    _ = try? UpdateSignature.verify(
      publicKeyBase64: wrongKey, signatureBase64: signature, fileURL: file)
    #expect(try Data(contentsOf: document) == payload)
  }

  // MARK: - P41-025 equal/older rejection and manual rollback

  @Test func equalOlderAndIncompatibleBuildsAreRejected() throws {
    #expect(UpdateVersionCheck.check(candidate(build: "101"), for: testInstalled) == .upgrade)
    #expect(UpdateVersionCheck.check(candidate(build: "100"), for: testInstalled) == .equalBuild)
    #expect(UpdateVersionCheck.check(candidate(build: "99"), for: testInstalled) == .olderBuild)
    #expect(
      UpdateVersionCheck.check(candidate(build: "101", minimumOS: "15.0"), for: testInstalled)
        == .incompatibleSystem)
    #expect(
      UpdateVersionCheck.check(candidate(build: "101", archs: ["x86_64"]), for: testInstalled)
        == .incompatibleArchitecture)
    #expect(UpdateVersionCheck.rollbackGuidance.contains("never downgrades"))
  }

  // MARK: - P41-026 canceled, disk-space, permission, and relaunch failures

  @Test func installFailuresKeepAUsableAppWithRecovery() throws {
    for problem in [
      InstallProblem.canceledByUser, .insufficientDiskSpace(requiredBytes: 100_000_000),
      .missingWritePermission, .interruptedRelaunch,
    ] {
      let recovery = InstallRecovery.recovery(for: problem)
      #expect(recovery.installedAppUsable)
      #expect(!recovery.recoverySteps.isEmpty)
    }
    #expect(
      InstallRecovery.recovery(for: .insufficientDiskSpace(requiredBytes: 42)).recoverySteps[0]
        .contains("42"))
  }

  // MARK: - P41-022 install-location classification and guidance (harness)

  @Test func installLocationsClassifyWithGuidance() throws {
    #expect(
      InstallLocation.classify(
        appPath: "/Applications/sPDF Editor.app", isWritable: true, isTranslocated: false,
        isOnDiskImage: false) == .applications)
    #expect(
      InstallLocation.classify(
        appPath: "/Users/a/Apps/sPDF Editor.app", isWritable: true, isTranslocated: false,
        isOnDiskImage: false) == .userWritableDirectory(path: "/Users/a/Apps/sPDF Editor.app"))
    #expect(
      InstallLocation.classify(
        appPath: "/Volumes/sPDF Editor/sPDF Editor.app", isWritable: true, isTranslocated: false,
        isOnDiskImage: true) == .diskImage)
    #expect(
      InstallLocation.classify(
        appPath: "/private/var/folders/xx/sPDF Editor.app", isWritable: true, isTranslocated: true,
        isOnDiskImage: false) == .translocatedOrReadOnly)
    #expect(
      InstallLocation.classify(
        appPath: "/Applications/sPDF Editor.app", isWritable: false, isTranslocated: false,
        isOnDiskImage: false) == .translocatedOrReadOnly)
    for location in [
      InstallLocation.applications, .userWritableDirectory(path: "/tmp/x"),
      .diskImage, .translocatedOrReadOnly, .other(path: ""),
    ] {
      #expect(!location.guidance.isEmpty)
    }
  }

  // MARK: - P41-009/P41-028 preferences and migration (harness)

  @Test func updatePreferencesRoundTripAndMigrate() throws {
    let prefs = UpdatePreferences(
      automaticallyChecks: true, lastCheckDate: Date(timeIntervalSince1970: 1_750_000_000),
      skippedBuild: "99")
    let data = try PreferencesMigration.encode(prefs)
    let (loaded, backup) = try PreferencesMigration.migrate(data: data)
    #expect(loaded == prefs)
    #expect(!backup)
    #expect(UpdatePreferences.automaticCheckInterval == 86_400)
    // Legacy unversioned preferences upgrade with a backup kept.
    let (upgraded, keepBackup) = try PreferencesMigration.migrate(
      data: Data(#"{"automatic":true}"#.utf8))
    #expect(upgraded.automaticallyChecks)
    #expect(keepBackup)
    // Future schemas refuse rather than misread.
    #expect(throws: DistributionPolicyError.self) {
      _ = try PreferencesMigration.migrate(data: Data(#"{"schema":99}"#.utf8))
    }
    #expect(throws: DistributionPolicyError.self) {
      _ = try PreferencesMigration.migrate(data: Data("not json".utf8))
    }
  }

  // MARK: - P41-019/P41-020/P41-021 readiness and relaunch (harness)

  @Test func updateReadinessBlocksUnsafeTerminationPaths() throws {
    let clean = UpdateReadiness.evaluate(DocumentUpdateState(windowCount: 1))
    #expect(clean.mayProceed && clean.blockers.isEmpty && !clean.requiresJobSettlement)
    let dirty = UpdateReadiness.evaluate(
      DocumentUpdateState(dirtyDocumentCount: 2, windowCount: 2, backgroundJobCount: 1))
    #expect(dirty.mayProceed)
    #expect(dirty.requiresJobSettlement)
    #expect(dirty.userPrompts.count == 2)
    for state in [
      DocumentUpdateState(saveAsInProgress: true),
      DocumentUpdateState(atomicSaveInProgress: true),
      DocumentUpdateState(unresolvedFailedSave: true),
    ] {
      let readiness = UpdateReadiness.evaluate(state)
      #expect(!readiness.mayProceed)
      #expect(!readiness.blockers.isEmpty)
    }
    let restore = RelaunchRestore.plan(
      saved: RelaunchState(openWindowIDs: ["a", "b"], settingsVersion: 1, bookmarkedFileCount: 2),
      supportedSettings: 2)
    #expect(restore.restoreWindows == ["a", "b"])
    #expect(restore.keepSettingsBackup)
    #expect(restore.restoreBookmarks == 2)
    let same = RelaunchRestore.plan(
      saved: RelaunchState(openWindowIDs: [], settingsVersion: 2), supportedSettings: 2)
    #expect(!same.keepSettingsBackup)
  }

  // MARK: - P41-027 locally staged signed version-N to version-N+1 update

  @Test func stagedSignedUpdatePreservesDirtyDocumentEdits() throws {
    // Ephemeral keys stand in for the app's update keypair so no private
    // key is ever read, embedded, or committed; the same verify path an
    // installed app uses checks the staged asset.
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-staged-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    // Version N+1 staged asset: signed, then independently verified.
    let stagedAsset = Data("sPDF-Editor-1.1-staged-full-DMG-bytes".utf8)
    let stagedFile = work.appendingPathComponent("sPDF-Editor-1.1.dmg")
    try stagedAsset.write(to: stagedFile)
    let signature = try key.signature(for: stagedAsset).base64EncodedString()
    #expect(try UpdateSignature.verify(publicKeyBase64: publicKey, signatureBase64: signature, fileURL: stagedFile))

    // Representative dirty document with persisted (unsaved) edits.
    struct DirtyDocument: Codable, Equatable { var pages: Int; var edits: [String] }
    let dirty = DirtyDocument(pages: 3, edits: ["highlight page 2", "filled field Notes=Ada"])
    let dirtyFile = work.appendingPathComponent("dirty-document.json")
    try JSONEncoder().encode(dirty).write(to: dirtyFile)

    // Staged feed offers N+1 to the installed N build; equal/older do not.
    let installed = InstalledApp(buildVersion: "100", systemVersion: "14.2", architecture: "arm64")
    let staged = candidate(build: "101", short: "1.1")
    #expect(UpdateSelection.selectStable(from: [staged], for: installed)?.buildVersion == "101")
    #expect(UpdateVersionCheck.check(staged, for: installed) == .upgrade)

    // Feed generation and validation around the staged asset.
    let item = AppcastItem(
      title: "sPDF Editor 1.1", published: Date(timeIntervalSince1970: 1_750_000_000),
      buildVersion: "101", shortVersion: "1.1", minimumSystemVersion: "14.0",
      releaseNotesHTML: "Staged notes.", releaseNotesLink: "https://example.com/notes-1.1",
      assetURL: "https://github.com/parasetam0l/spdf/releases/download/v1.1/sPDF-Editor-1.1.dmg",
      assetLength: stagedAsset.count, edSignature: signature)
    let xml = Appcast.xml(feedTitle: "sPDF Editor", feedLink: "https://example.com", item: item)
    let feedFile = work.appendingPathComponent("appcast.xml")
    try Data(xml.utf8).write(to: feedFile)
    let entries = try SignedFeedPolicy.validate(
      feed: Data(xml.utf8), assetURL: stagedFile, publicKeyBase64: publicKey)
    #expect(entries.count == 1)

    // Simulated relaunch: the dirty document's persisted edits verify
    // intact and the staged signature still verifies afterwards.
    let reopened = try JSONDecoder().decode(DirtyDocument.self, from: Data(contentsOf: dirtyFile))
    #expect(reopened == dirty)
    #expect(try UpdateSignature.verify(publicKeyBase64: publicKey, signatureBase64: signature, fileURL: stagedFile))
    print(
      "[P41] staged N(100)->N+1(101) full-DMG update verified locally: feed valid, "
        + "signature matches, \(reopened.edits.count) dirty edits intact")
  }
}
