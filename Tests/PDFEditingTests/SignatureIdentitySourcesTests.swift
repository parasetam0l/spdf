import CryptoKit
import Foundation
import PDFCore
@testable import PDFEditing
import Security
import Testing

@Suite("Signing identity sources")
struct SignatureIdentitySourcesTests {
  private func makeTemporaryKeychain() throws -> SecKeychain {
    let path = NSTemporaryDirectory() + "spdf-identity-" + UUID().uuidString + ".keychain"
    var keychain: SecKeychain?
    guard SecKeychainCreate(path, 4, "test", false, nil, &keychain) == errSecSuccess,
      let keychain
    else {
      throw PDFError(.unsupported, "Could not create an identity test keychain")
    }
    return keychain
  }

  private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-identity-file-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func certificateDER(of identity: SecIdentity) throws -> Data {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
      let certificate
    else { throw PDFError(.malformed, "The test identity has no certificate") }
    return SecCertificateCopyData(certificate) as Data
  }

  private func fingerprint(of identity: SecIdentity) throws -> String {
    let der = try certificateDER(of: identity)
    return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
  }

  @Test func importedPKCS12BecomesUsableSigningIdentity() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let keychain = try makeTemporaryKeychain()
    defer { SecKeychainDelete(keychain) }
    let p12 = material.directory.appendingPathComponent("identity.p12")
    let source = try PDFSigningIdentityCatalog.importFile(
      at: p12, passphrase: "test", destinationKeychain: keychain)
    #expect(source.kind == .importedPKCS12)
    #expect(source.canSign)
    #expect(source.identity != nil)
    #expect(source.origin == "identity.p12")
    #expect(source.tokenID == nil)
    #expect(source.privateKeyAvailable)
    #expect(source.selectionWarning == nil)
    #expect(source.fingerprintSHA256 == (try fingerprint(of: material.identity)))

    let parsed = try PDFParser.parse(BlankPDF.data(format: .letter))
    let options = PDFSigningOptions(
      fieldName: "ImportedIdentity", pageIndex: 0, rect: [72, 72, 272, 112])
    let identity = try source.signingIdentity()
    let data = try PDFSigningWriter.sign(parsed.graph, identity: identity, options: options)
    let graph = try PDFParser.parse(data).graph
    let signatures = try PDFSignatureInventory.signatures(in: graph)
    #expect(signatures.count == 1)
    let validation = PDFSignatureValidator.validate(
      signatures[0], source: data, finalGraph: graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
  }

  @Test func catalogListsImportedAndKeychainIdentitiesClearly() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let keychain = try makeTemporaryKeychain()
    defer { SecKeychainDelete(keychain) }
    let p12 = material.directory.appendingPathComponent("identity.p12")
    let imported = try PDFSigningIdentityCatalog.importFile(
      at: p12, passphrase: "test", destinationKeychain: keychain)
    let listed = PDFSigningIdentityCatalog.available(searchKeychains: [keychain])
    let match = listed.first { $0.fingerprintSHA256 == imported.fingerprintSHA256 }
    #expect(match != nil, "The imported PKCS#12 identity was not enumerated")
    #expect(match?.canSign == true)
    #expect(match?.identity != nil)

    let sourceMaterialIdentities = PDFSigningIdentityCatalog.available(
      searchKeychains: [material.keychain])
    let materialMatch = sourceMaterialIdentities.first {
      $0.fingerprintSHA256 == (try? fingerprint(of: material.identity))
    }
    #expect(materialMatch != nil, "The test keychain identity was not enumerated")
    #expect(materialMatch?.canSign == true)
  }

  @Test func certificateOnlyPEMAndDERCannotSign() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let expectedFingerprint = try fingerprint(of: material.identity)

    let pemURL = material.directory.appendingPathComponent("leaf.pem")
    let pemSource = try PDFSigningIdentityCatalog.importFile(at: pemURL, passphrase: nil)
    #expect(pemSource.kind == .certificateOnly)
    #expect(!pemSource.canSign)
    #expect(pemSource.identity == nil)
    #expect(pemSource.fingerprintSHA256 == expectedFingerprint)
    #expect(pemSource.selectionWarning?.contains("no private key") == true)
    #expect(throws: PDFError.self) { _ = try pemSource.signingIdentity() }

    let derURL = try temporaryFile("identity.cer", try certificateDER(of: material.identity))
    defer { try? FileManager.default.removeItem(at: derURL.deletingLastPathComponent()) }
    let derSource = try PDFSigningIdentityCatalog.importFile(at: derURL, passphrase: nil)
    #expect(derSource.kind == .certificateOnly)
    #expect(!derSource.canSign)
    #expect(derSource.fingerprintSHA256 == expectedFingerprint)
    #expect(derSource.origin == "identity.cer")
  }

  @Test func missingAndWrongPKCS12PassphraseRefuseWithoutImport() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let keychain = try makeTemporaryKeychain()
    defer { SecKeychainDelete(keychain) }
    let p12 = material.directory.appendingPathComponent("identity.p12")

    do {
      _ = try PDFSigningIdentityCatalog.importFile(
        at: p12, passphrase: nil, destinationKeychain: keychain)
      Issue.record("A passphrase-less PKCS#12 import should refuse")
    } catch let error as PDFError {
      #expect(error.kind == .passwordRequired)
    }

    do {
      _ = try PDFSigningIdentityCatalog.importFile(
        at: p12, passphrase: "wrong", destinationKeychain: keychain)
      Issue.record("A wrong PKCS#12 passphrase should refuse")
    } catch let error as PDFError {
      #expect(error.kind == .incorrectPassword)
    }
    let afterFailure = PDFSigningIdentityCatalog.available(searchKeychains: [keychain])
    #expect(afterFailure.isEmpty, "A failed import left an identity behind")
  }

  @Test func unsupportedAndEmptyFilesRefuseClearly() throws {
    let textURL = try temporaryFile("notes.txt", Data("not a certificate".utf8))
    defer { try? FileManager.default.removeItem(at: textURL.deletingLastPathComponent()) }
    do {
      _ = try PDFSigningIdentityCatalog.importFile(at: textURL, passphrase: nil)
      Issue.record("A .txt file should not import as an identity")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("PKCS#12"))
    }

    let emptyURL = try temporaryFile("empty.p12", Data())
    defer { try? FileManager.default.removeItem(at: emptyURL.deletingLastPathComponent()) }
    do {
      _ = try PDFSigningIdentityCatalog.importFile(at: emptyURL, passphrase: "x")
      Issue.record("An empty identity file should refuse")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }

    let badPEM = Data("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n".utf8)
    let badURL = try temporaryFile("bad.pem", badPEM)
    defer { try? FileManager.default.removeItem(at: badURL.deletingLastPathComponent()) }
    do {
      _ = try PDFSigningIdentityCatalog.importFile(at: badURL, passphrase: nil)
      Issue.record("A malformed PEM should refuse")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
    }
  }

  @Test func tokenAndSourceKindsAreClassifiedClearly() {
    let secureEnclave = PDFSigningIdentityCatalog.kind(
      tokenID: kSecAttrTokenIDSecureEnclave as String, importKind: nil)
    #expect(secureEnclave == .secureEnclave)
    #expect(secureEnclave.isHardwareBacked)
    #expect(secureEnclave.displayName == "Secure Enclave")

    let smartCard = PDFSigningIdentityCatalog.kind(
      tokenID: "com.apple.ctk.token.smartcard-1", importKind: nil)
    #expect(smartCard == .hardwareToken)
    #expect(smartCard.isHardwareBacked)
    #expect(smartCard.canHoldPrivateKey)

    #expect(
      PDFSigningIdentityCatalog.kind(tokenID: nil, importKind: .importedPKCS12)
        == .importedPKCS12)
    #expect(PDFSigningIdentityCatalog.kind(tokenID: nil, importKind: nil) == .keychain)
    #expect(
      PDFSigningIdentityCatalog.kind(tokenID: nil, importKind: .certificateOnly)
        == .certificateOnly)
    #expect(!PDFSigningIdentityKind.certificateOnly.canHoldPrivateKey)
    #expect(PDFSigningIdentityKind.certificateOnly.displayName == "Certificate only")
  }

  @Test func unusableSelectionRefusesBeforeWritingOutput() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let pemURL = material.directory.appendingPathComponent("leaf.pem")
    let certificateOnly = try PDFSigningIdentityCatalog.importFile(
      at: pemURL, passphrase: nil)
    let outputDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-identity-no-output-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let output = outputDirectory.appendingPathComponent("signed.pdf")

    do {
      let identity = try certificateOnly.signingIdentity()
      let parsed = try PDFParser.parse(BlankPDF.data(format: .letter))
      let data = try PDFSigningWriter.sign(
        parsed.graph, identity: identity, options: PDFSigningOptions(
          fieldName: "UnusableCertificate", pageIndex: 0, rect: [72, 72, 272, 112]))
      try data.write(to: output)
      Issue.record("A certificate-only source should not sign")
    } catch let error as PDFError {
      #expect(error.kind == .unsupported)
      #expect(error.message.contains("no private key") || error.message.contains("cannot sign"))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test func importedSourceDescriptionShowsOriginAndKind() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let source = try PDFSigningIdentityCatalog.importFile(
      at: material.directory.appendingPathComponent("identity.p12"),
      passphrase: "test",
      destinationKeychain: try makeTemporaryKeychain())
    #expect(source.sourceDescription.contains("Imported PKCS#12"))
    #expect(source.sourceDescription.contains("identity.p12"))
    #expect(source.validityDescription.contains("Valid"))
    #expect(source.displayName == (PDFSignatureSignerIdentity.certificateDetails(
      source.certificate)?.commonName ?? source.commonName))
  }

  @Test func existingIdentityCanBeClassifiedForHostFlows() throws {
    guard let material = try TestSigningMaterial.make() else { return }
    defer { material.cleanUp() }
    let source = try #require(PDFSigningIdentityCatalog.source(for: material.identity))
    #expect(source.canSign)
    #expect(source.identity != nil)
    #expect(source.kind == .keychain || source.kind.isHardwareBacked)
    #expect(source.fingerprintSHA256 == (try fingerprint(of: material.identity)))
  }
}
