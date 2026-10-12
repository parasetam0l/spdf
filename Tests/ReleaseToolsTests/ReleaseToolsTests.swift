import CryptoKit
import Foundation
import ReleaseTools
import Testing

@Suite("Release tools")
struct ReleaseToolsTests {
  @Test func updateSignaturesVerifyAndRejectTalks() throws {
    let key = Curve25519.Signing.PrivateKey()
    let payload = Data("sPDF Editor update payload".utf8)
    let signature = try key.signature(for: payload)
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-signature-\(UUID().uuidString).bin")
    try payload.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(
      try UpdateSignature.verify(
        publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
        signatureBase64: signature.base64EncodedString(), fileURL: file))
    #expect(
      try !UpdateSignature.verify(
        publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
        signatureBase64: Data(repeating: 7, count: 64).base64EncodedString(), fileURL: file))
  }

  @Test func appcastRoundTripsAndValidatesTheAsset() throws {
    let key = Curve25519.Signing.PrivateKey()
    let asset = Data(repeating: 0xAB, count: 4096)
    let assetURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-asset-\(UUID().uuidString).dmg")
    try asset.write(to: assetURL)
    defer { try? FileManager.default.removeItem(at: assetURL) }
    let signature = try key.signature(for: asset).base64EncodedString()
    let item = AppcastItem(
      title: "sPDF Editor 1.0", published: Date(timeIntervalSince1970: 1_700_000_000),
      buildVersion: "1700000000", shortVersion: "1.0", minimumSystemVersion: "14.0",
      releaseNotesHTML: "Notes with & ampersand and ]]> terminator", releaseNotesLink: "https://example.com/notes",
      assetURL: "https://example.com/sPDF-Editor-1.0.dmg", assetLength: asset.count,
      edSignature: signature)
    let xml = Appcast.xml(feedTitle: "sPDF Editor", feedLink: "https://example.com", item: item)
    let data = Data(xml.utf8)
    let entries = try AppcastValidator.validate(
      data: data, assetURL: assetURL, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
    #expect(entries.count == 1)
    #expect(entries[0].buildVersion == "1700000000")
    #expect(entries[0].edSignature == signature)

    // A tampered asset fails signature verification.
    try Data(repeating: 0x01, count: 8).write(to: assetURL)
    #expect(throws: ReleaseToolsError.self) {
      _ = try AppcastValidator.validate(
        data: data, assetURL: assetURL,
        publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
    }
    // A missing signature fails structural validation.
    let unsigned = xml.replacingOccurrences(of: " sparkle:edSignature=\"\(signature)\"", with: "")
    #expect(throws: ReleaseToolsError.self) {
      _ = try AppcastValidator.validate(data: Data(unsigned.utf8))
    }
  }

  @Test func notaryResultsParseAcceptedAndRejected() throws {
    let accepted = Data(#"{"id":"abc-123","status":"Accepted"}"#.utf8)
    let value = try NotaryResult.parse(accepted)
    #expect(value.status == "Accepted" && value.submissionID == "abc-123")
    let rejected = try NotaryResult.parse(Data(#"{"id":"x","status":"Invalid"}"#.utf8))
    #expect(rejected.status == "Invalid")
  }

  @Test func releaseManifestsCapturePackagedMetadata() throws {
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-manifest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: work.appendingPathComponent("sPDF Editor.app/Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleShortVersionString": "1.0", "CFBundleVersion": "42",
      "LSMinimumSystemVersion": "14.0", "CFBundleIdentifier": "com.parasetam0l.spdf",
      "SUPublicEDKey": "public-key",
    ]
    let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: work.appendingPathComponent("sPDF Editor.app/Contents/Info.plist"))
    let dmg = work.appendingPathComponent("sPDF-Editor-1.0.dmg")
    try Data(repeating: 0x5A, count: 128).write(to: dmg)
    defer { try? FileManager.default.removeItem(at: work) }

    let manifest = try ReleaseManifestBuilder.make(
      appURL: work.appendingPathComponent("sPDF Editor.app"), assetURL: dmg,
      assetRemoteURL: "https://example.com/sPDF-Editor-1.0.dmg", signature: "sig")
    #expect(manifest.bundleIdentifier == "com.parasetam0l.spdf")
    #expect(manifest.version == "1.0" && manifest.build == "42")
    #expect(manifest.assetLength == 128 && manifest.assetSHA256.count == 64)
    #expect(manifest.edSignature == "sig")
  }
}

/// P03-023: the private-corpus manifest validates schemas without ever
/// seeing personal content (the sample below is synthetic).
extension ReleaseToolsTests {
  @Test func corpusManifestValidatesSchemaRules() throws {
    let sample = try JSONEncoder().encode(CorpusManifest.sample())
    let manifest = try CorpusManifest.load(data: sample)
    #expect(manifest.version == 1)
    #expect(manifest.documents.count == 1)
    #expect(manifest.documents[0].producer == "Acme Writer")
    func load(_ json: String) throws -> CorpusManifest.Manifest {
      try CorpusManifest.load(data: Data(json.utf8))
    }
    // Absolute paths, parent escapes, duplicates, bad versions/hashes fail.
    #expect(throws: CorpusManifestError.self) {
      try load(
        #"{"version":1,"documents":[{"id":"a","path":"/etc/passwd","producer":"p","producerVersion":"1"}]}"#)
    }
    #expect(throws: CorpusManifestError.self) {
      try load(
        #"{"version":1,"documents":[{"id":"a","path":"../out.pdf","producer":"p","producerVersion":"1"}]}"#)
    }
    #expect(throws: CorpusManifestError.self) {
      try load(
        #"{"version":2,"documents":[]}"#)
    }
    #expect(throws: CorpusManifestError.self) {
      try load(
        #"{"version":1,"documents":[{"id":"a","path":"a.pdf","producer":"p","producerVersion":"1"},{"id":"a","path":"b.pdf","producer":"q","producerVersion":"2"}]}"#)
    }
    #expect(throws: CorpusManifestError.self) {
      try load(
        #"{"version":1,"documents":[{"id":"a","path":"a.pdf","producer":"p","producerVersion":"1","sha256":"xyz"}]}"#)
    }
    #expect(throws: CorpusManifestError.self) {
      try load("not json")
    }
  }
}
