import CryptoKit
import Foundation
import ReleaseTools
import Testing

@Suite("Release pipeline policy")
struct ReleasePipelineTests {
  // MARK: - P42-006 serialized, monotonic build versions

  @Test func buildVersionsAreMonotonicAndTagsUnique() throws {
    #expect(BuildVersionPolicy.isDuplicateTag("v1.1", existingTags: ["v1.0", "v1.1"]))
    #expect(!BuildVersionPolicy.isDuplicateTag("v1.2", existingTags: ["v1.0", "v1.1"]))
    #expect(BuildVersionPolicy.nextBuild(after: ["100", "101"], now: 50) == "102")
    #expect(BuildVersionPolicy.nextBuild(after: [], now: 1_750_000_000) == "1750000000")
    #expect(BuildVersionPolicy.isMonotonic("102", after: ["100", "101"]))
    #expect(!BuildVersionPolicy.isMonotonic("101", after: ["100", "101"]))
    #expect(!BuildVersionPolicy.isMonotonic("abc", after: ["100"]))
  }

  // MARK: - P42-014 notary resume before resubmission

  @Test func notaryOutcomesResumeBeforeResubmitting() throws {
    #expect(NotaryResume.action(for: .accepted, submissionID: "a") == .accept)
    #expect(NotaryResume.action(for: .inProgress, submissionID: "a") == .waitAndResume(submissionID: "a"))
    #expect(
      NotaryResume.action(for: .timeout, submissionID: "abc-123")
        == .resumeByIDBeforeResubmitting(submissionID: "abc-123"))
    #expect(
      NotaryResume.action(for: .transientServiceError, submissionID: "abc-123")
        == .resumeByIDBeforeResubmitting(submissionID: "abc-123"))
    #expect(
      NotaryResume.action(for: .rejected, submissionID: "abc-123")
        == .resumeByIDBeforeResubmitting(submissionID: "abc-123"))
    #expect(NotaryResume.action(for: .authenticationFailure, submissionID: "a") == .fixAuthentication)
    // Blind resubmission without an ID is refused.
    if case .refuseToAdvance = NotaryResume.action(for: .timeout, submissionID: nil) {
    } else {
      #expect(Bool(false), "a timeout without a submission ID must refuse blind resubmission")
    }
    if case .refuseToAdvance = NotaryResume.action(for: .rejected, submissionID: "") {
    } else {
      #expect(Bool(false), "a rejection without a submission ID must refuse to advance")
    }
  }

  // MARK: - P42-021 compatible appcast history across baseline changes

  @Test func stableFeedKeepsCompatibleHistory() throws {
    let releases = [
      HistoricRelease(shortVersion: "1.2", buildVersion: "102", minimumSystemVersion: "15.0"),
      HistoricRelease(shortVersion: "1.1", buildVersion: "101", minimumSystemVersion: "14.0"),
      HistoricRelease(shortVersion: "1.3-beta", buildVersion: "103", minimumSystemVersion: "15.0", isPrerelease: true),
      HistoricRelease(shortVersion: "1.4-draft", buildVersion: "104", minimumSystemVersion: "15.0", isDraft: true),
      HistoricRelease(shortVersion: "1.0", buildVersion: "100", minimumSystemVersion: "14.0"),
    ]
    let stable = FeedHistory.stableItems(from: releases)
    #expect(stable.map(\.buildVersion) == ["102", "101", "100"])
    // The older-baseline release survives below the newer one.
    #expect(stable.last?.minimumSystemVersion == "14.0")
  }

  // MARK: - P42-022 signed-feed policy with official-tool semantics

  @Test func feedResigningRevalidatesBeforeUpload() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let asset = Data(repeating: 0xCD, count: 1024)
    let assetURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-resign-\(UUID().uuidString).dmg")
    try asset.write(to: assetURL)
    defer { try? FileManager.default.removeItem(at: assetURL) }
    func feed(title: String, signature: String, length: Int) -> String {
      Appcast.xml(
        feedTitle: "sPDF Editor", feedLink: "https://example.com",
        item: AppcastItem(
          title: title, published: Date(timeIntervalSince1970: 1_750_000_000),
          buildVersion: "101", shortVersion: "1.1", minimumSystemVersion: "14.0",
          releaseNotesHTML: "Notes.", releaseNotesLink: "https://example.com/notes",
          assetURL: "https://example.com/sPDF-Editor-1.1.dmg", assetLength: length,
          edSignature: signature))
    }
    let signature = try key.signature(for: asset).base64EncodedString()
    // Edited feed content (retitled) re-signed and re-validated.
    let edited = feed(title: "sPDF Editor 1.1 (repaired notes)", signature: signature, length: asset.count)
    #expect(
      try SignedFeedPolicy.validate(
        feed: Data(edited.utf8), assetURL: assetURL, publicKeyBase64: publicKey).count == 1)
    // The same edited feed with the old signature over different bytes fails.
    try Data(repeating: 0xEE, count: 1024).write(to: assetURL)
    #expect(throws: ReleaseToolsError.self) {
      _ = try SignedFeedPolicy.validate(
        feed: Data(edited.utf8), assetURL: assetURL, publicKeyBase64: publicKey)
    }
  }

  // MARK: - P42-025 idempotent reruns preserve published bytes

  @Test func rerunsReuseOrRefuseInsteadOfReplacing() throws {
    let published = PublishedAsset(name: "sPDF-Editor-1.1.dmg", sha256: "aa", length: 100)
    #expect(RerunPolicy.assetAction(existing: published, name: published.name, sha256: "aa", length: 100) == .reusePublished)
    if case .refuseReplacement = RerunPolicy.assetAction(
      existing: published, name: published.name, sha256: "bb", length: 100)
    {
    } else {
      #expect(Bool(false), "same name with different bytes must refuse replacement")
    }
    #expect(
      RerunPolicy.assetAction(existing: published, name: "other.dmg", sha256: "aa", length: 100)
        == .upload)
    #expect(RerunPolicy.assetAction(existing: nil, name: "new.dmg", sha256: "aa", length: 1) == .upload)
    #expect(RerunPolicy.mayClobberAsset(named: "appcast.xml"))
    #expect(!RerunPolicy.mayClobberAsset(named: "sPDF-Editor-1.1.dmg"))
  }

  // MARK: - P42-026 upload verification (secret-free half; publication pending)

  @Test func uploadedAssetsVerifyHashesURLsAndSignatures() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let asset = Data("published DMG bytes".utf8)
    let signature = try key.signature(for: asset).base64EncodedString()
    let sha = UploadVerification.sha256Hex(asset)
    #expect(sha.count == 64)
    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-upload-\(UUID().uuidString).dmg")
    try UploadVerification.verify(
      asset: asset, expectedLength: asset.count, expectedSHA256: sha,
      signatureBase64: signature, publicKeyBase64: publicKey, fileURL: scratch,
      downloadURL:
        "https://github.com/parasetam0l/spdf/releases/download/v1.1/sPDF-Editor-1.1.dmg")
    // Length, hash, signature, and URL violations all fail.
    #expect(throws: DistributionPolicyError.self) {
      try UploadVerification.verify(
        asset: asset, expectedLength: asset.count + 1, expectedSHA256: sha,
        signatureBase64: signature, publicKeyBase64: publicKey, fileURL: scratch,
        downloadURL: "https://github.com/parasetam0l/spdf/releases/download/v1.1/x.dmg")
    }
    #expect(throws: DistributionPolicyError.self) {
      try UploadVerification.verify(
        asset: asset, expectedLength: asset.count, expectedSHA256: String(repeating: "0", count: 64),
        signatureBase64: signature, publicKeyBase64: publicKey, fileURL: scratch,
        downloadURL: "https://github.com/parasetam0l/spdf/releases/download/v1.1/x.dmg")
    }
    #expect(throws: DistributionPolicyError.self) {
      try UploadVerification.verify(
        asset: asset, expectedLength: asset.count, expectedSHA256: sha,
        signatureBase64: Data(repeating: 9, count: 64).base64EncodedString(),
        publicKeyBase64: publicKey, fileURL: scratch,
        downloadURL: "https://github.com/parasetam0l/spdf/releases/download/v1.1/x.dmg")
    }
    #expect(throws: DistributionPolicyError.self) {
      try UploadVerification.verify(
        asset: asset, expectedLength: asset.count, expectedSHA256: sha,
        signatureBase64: signature, publicKeyBase64: publicKey, fileURL: scratch,
        downloadURL: "http://example.com/sPDF-Editor-1.1.dmg")
    }
    #expect(throws: DistributionPolicyError.self) {
      try UploadVerification.verify(
        asset: asset, expectedLength: asset.count, expectedSHA256: sha,
        signatureBase64: signature, publicKeyBase64: publicKey, fileURL: scratch,
        downloadURL: "https://github.com/parasetam0l/spdf/releases/latest/download/appcast.xml")
    }
  }

  // MARK: - P42-027 pipeline failure drills never advance incomplete releases

  @Test func pipelineFailuresRefuseToAdvance() throws {
    #expect(throws: DistributionPolicyError.self) {
      try PipelineGate.checkSecrets(["A"], required: ["A", "B"])
    }
    try PipelineGate.checkSecrets(["A", "B"], required: ["A", "B"])
    #expect(throws: DistributionPolicyError.self) {
      try PipelineGate.checkSignatureValid(false, stage: "nested signing")
    }
    #expect(throws: DistributionPolicyError.self) {
      try PipelineGate.checkNotaryAccepted("Invalid", submissionID: "x")
    }
    try PipelineGate.checkNotaryAccepted("Accepted", submissionID: "x")
    #expect(throws: DistributionPolicyError.self) {
      try PipelineGate.checkUploadComplete(uploadedBytes: 10, expectedBytes: 100)
    }
    #expect(throws: DistributionPolicyError.self) {
      try PipelineGate.checkCanceled(true)
    }
    try PipelineGate.checkCanceled(false)
    // A drill across every stage: each failing input throws, so the
    // pipeline cannot advance past any incomplete stage.
    let stages: [PipelineStage] = [
      .secrets, .certificateImport, .archive, .nestedSigning, .notarization, .packaging,
      .upload, .cleanup,
    ]
    #expect(stages.count == 8)
    for stage in stages {
      #expect(throws: DistributionPolicyError.self) {
        switch stage {
        case .secrets:
          try PipelineGate.checkSecrets([], required: ["SPARKLE_PRIVATE_KEY"])
        case .certificateImport, .archive, .nestedSigning:
          try PipelineGate.checkSignatureValid(false, stage: "\(stage)")
        case .notarization:
          try PipelineGate.checkNotaryAccepted("Rejected", submissionID: "drill")
        case .packaging, .upload:
          try PipelineGate.checkUploadComplete(uploadedBytes: 0, expectedBytes: 1)
        case .cleanup:
          try PipelineGate.checkCanceled(true)
        }
      }
    }
  }

  // MARK: - P42-029 certificate expiry, key backup/rotation, bridge releases

  @Test func certificateAndKeyRotationPolicy() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let expiry = Date(timeIntervalSince1970: 1_750_000_000 + 30 * 86_400)
    #expect(SigningIdentityPolicy.daysUntilExpiry(expiry: expiry, now: now) == 30)
    #expect(SigningIdentityPolicy.needsRenewal(expiry: expiry, now: now, warnWithinDays: 60))
    #expect(!SigningIdentityPolicy.needsRenewal(expiry: expiry, now: now, warnWithinDays: 7))
    #expect(
      SigningIdentityPolicy.daysUntilExpiry(
        expiry: Date(timeIntervalSince1970: 1_700_000_000), now: now) < 0)
    // Rotation: old verifies old, new verifies new, new does not claim old.
    let oldKey = Curve25519.Signing.PrivateKey()
    let newKey = Curve25519.Signing.PrivateKey()
    let oldAsset = Data("1.0 bytes".utf8)
    let newAsset = Data("1.1 bytes".utf8)
    let oldSig = try oldKey.signature(for: oldAsset)
    let newSig = try newKey.signature(for: newAsset)
    #expect(
      SigningIdentityPolicy.rotationAccepts(
        oldKeyVerifiesOldAsset: oldKey.publicKey.isValidSignature(oldSig, for: oldAsset),
        newKeyVerifiesNewAsset: newKey.publicKey.isValidSignature(newSig, for: newAsset),
        newKeyVerifiesOldAsset: newKey.publicKey.isValidSignature(oldSig, for: oldAsset)))
    #expect(
      !SigningIdentityPolicy.rotationAccepts(
        oldKeyVerifiesOldAsset: true, newKeyVerifiesNewAsset: true,
        newKeyVerifiesOldAsset: true))
    #expect(!SigningIdentityPolicy.backupRule.isEmpty)
  }
}
