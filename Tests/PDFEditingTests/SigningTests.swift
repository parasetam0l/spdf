import CryptoKit
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// P30-016–P30-022/P30-025/P30-026 evidence: keychain identity use without
/// exposing private keys, deterministic ByteRange reservation, embedding
/// without changing covered bytes, incremental signing with original bytes
/// preserved, multiple signatures, reservation failures, and independent
/// verification with openssl.
@Suite("Signature generation")
struct SigningTests {
  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Signed/\(name)")
    return try Data(contentsOf: url)
  }

  private func signingTime() -> Date { Date(timeIntervalSince1970: 1_767_225_600) }

  private func signature(in graph: PDFGraph) throws -> PDFSignature {
    try #require(try PDFSignatureInventory.signatures(in: graph).first)
  }

  @Test func signingRoundTripValidatesIndependently() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }

    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let data = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(
        fieldName: "Signature1", pageIndex: 0, rect: [72, 72, 272, 112],
        reason: "unit test", signingTime: signingTime()))

    let parsed = try PDFParser.parse(data)
    let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
    #expect(signatures.count == 1)
    let signature = try #require(signatures.first)
    #expect(signature.fieldName == "Signature1")
    #expect(signature.pageIndex == 0)
    #expect(signature.reason == "unit test")
    #expect(signature.subFilter == "adbe.pkcs7.detached")
    // P30-017: the field is placed with a generated appearance.
    let fields = try FormInventory.fields(in: parsed.graph, pageIDs: parsed.pageIDs)
    #expect(fields.contains { $0.name == "Signature1" && $0.kind == .signature })
    let field = try #require(fields.first { $0.name == "Signature1" })
    guard let widgetID = field.widgets.first?.objectID,
      case .dictionary(let widget)? = parsed.graph.objects[widgetID],
      case .dictionary(let appearance)? = widget[PDFName("AP")],
      case .reference(let appearanceID)? = appearance[PDFName("N")],
      case .stream(let stream)? = parsed.graph.objects[appearanceID]
    else {
      Issue.record("Signature appearance missing")
      return
    }
    #expect(!(try PDFFilters.decoded(stream)).isEmpty)

    let validation = PDFSignatureValidator.validate(
      signature, source: data, finalGraph: parsed.graph, trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.unsignedChanges == false)
    #expect(validation.signatureAlgorithm?.contains("RSA") == true)

    // P30-026: an independent validator (openssl) accepts the signature.
    try verifyWithOpenSSL(data: data, caPEM: material.caPEM)
  }

  @Test func incrementalSigningPreservesOriginalBytes() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }

    let original = try PDFFixtures.onePage()
    let parsed = try PDFParser.parse(original)
    let signed = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(
        fieldName: "Approval", pageIndex: 0, signingTime: signingTime()))
    // P30-020: the original bytes are an exact prefix of the output.
    #expect(signed.starts(with: original))
    #expect(signed.count > original.count)

    let reparsed = try PDFParser.parse(signed)
    let signature = try signature(in: reparsed.graph)
    #expect(signature.fieldName == "Approval")
    let validation = PDFSignatureValidator.validate(
      signature, source: signed, finalGraph: reparsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.unsignedChanges == false)
    try verifyWithOpenSSL(data: signed, caPEM: material.caPEM)
  }

  @Test func multipleSignaturesAcrossRevisions() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }

    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let first = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(fieldName: "First", pageIndex: 0, signingTime: signingTime()))
    let parsedFirst = try PDFParser.parse(first)
    let second = try PDFSigningWriter.signIncremental(
      parsedFirst, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Second", pageIndex: 0, signingTime: signingTime()))

    let reparsed = try PDFParser.parse(second)
    let signatures = try PDFSignatureInventory.signatures(in: reparsed.graph)
    #expect(signatures.count == 2)
    #expect(signatures.compactMap(\.fieldName).sorted() == ["First", "Second"])
    let anchor = material.caCertificate
    for signature in signatures {
      let validation = PDFSignatureValidator.validate(
        signature, source: second, finalGraph: reparsed.graph, trustedAnchors: [anchor])
      #expect(validation.crypto == .valid)
    }
    // The first signature reports the later revision as unsigned changes.
    let firstSignature = try #require(signatures.first { $0.fieldName == "First" })
    let firstValidation = PDFSignatureValidator.validate(
      firstSignature, source: second, finalGraph: reparsed.graph, trustedAnchors: [anchor])
    #expect(firstValidation.unsignedChanges)
    let secondSignature = try #require(signatures.first { $0.fieldName == "Second" })
    let secondValidation = PDFSignatureValidator.validate(
      secondSignature, source: second, finalGraph: reparsed.graph, trustedAnchors: [anchor])
    #expect(!secondValidation.unsignedChanges)
  }

  @Test func insufficientReservationFailsWithoutOutput() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }

    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let before = graph
    do {
      _ = try PDFSigningWriter.sign(
        graph, identity: material.identity,
        options: PDFSigningOptions(
          fieldName: "TooSmall", pageIndex: 0, reservationBytes: 512,
          signingTime: signingTime()))
      Issue.record("An undersized signature reservation was accepted")
    } catch let error as PDFError {
      #expect(error.kind == .limitExceeded)
      #expect(error.message.contains("reserved"))
    }
    // The input graph is untouched by the failed attempt.
    #expect(graph == before)
  }

  @Test func fieldNameCollisionsAndEncryptedSourcesRefuse() throws {
    let material = try #require(try TestSigningMaterial.make())
    defer { material.cleanUp() }

    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let signed = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Signature1", signingTime: signingTime()))
    let reparsed = try PDFParser.parse(signed)
    #expect(throws: PDFError.self) {
      _ = try PDFSigningWriter.signIncremental(
        reparsed, identity: material.identity,
        options: PDFSigningOptions(fieldName: "Signature1", signingTime: signingTime()))
    }

    let encryptedURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Encrypted/aes-256-r6.pdf")
    let encrypted = try PDFParser.parse(try Data(contentsOf: encryptedURL), password: "abc")
    #expect(throws: PDFError.self) {
      _ = try PDFSigningWriter.signIncremental(
        encrypted, identity: material.identity,
        options: PDFSigningOptions(fieldName: "Encrypted", signingTime: signingTime()))
    }
  }

  // MARK: Independent verification (P30-026)

  private func verifyWithOpenSSL(data: Data, caPEM: Data) throws {
    let openssl = "/usr/bin/openssl"
    guard FileManager.default.isExecutableFile(atPath: openssl) else { return }
    let parsed = try PDFParser.parse(data)
    let signature = try signature(in: parsed.graph)
    guard case .string(let cms)? = signature.dictionary[PDFName("Contents")] else {
      Issue.record("Signature contents missing")
      return
    }
    // Trim the zero padding to the DER length.
    var cmsDER = cms
    while cmsDER.count > 2, cmsDER.last == 0, cmsDER[cmsDER.count - 2] == 0 {
      cmsDER = cmsDER.dropLast()
    }
    let bytes = [UInt8](data)
    var signedBytes = Data()
    var index = 0
    while index + 1 < signature.byteRange.count {
      let start = signature.byteRange[index]
      let length = signature.byteRange[index + 1]
      signedBytes.append(contentsOf: bytes[start..<(start + length)])
      index += 2
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-signing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cmsURL = directory.appendingPathComponent("signature.der")
    let contentURL = directory.appendingPathComponent("signed.bin")
    let caURL = directory.appendingPathComponent("ca.pem")
    try cmsDER.write(to: cmsURL)
    try signedBytes.write(to: contentURL)
    try caPEM.write(to: caURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: openssl)
    process.arguments = [
      "cms", "-verify", "-binary", "-inform", "DER", "-in", cmsURL.path, "-content",
      contentURL.path, "-CAfile", caURL.path, "-purpose", "any", "-out", "/dev/null",
    ]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "openssl rejected the signature: \(errorOutput)")
  }
}

/// Test-only helper: generates a throwaway CA, leaf, and PKCS#12 with openssl
/// at test time (no private key is committed) and imports the identity into a
/// temporary keychain so the user's keychain is never touched.
struct TestSigningMaterial {
  let identity: SecIdentity
  let caCertificate: SecCertificate
  let caPEM: Data
  let keychain: SecKeychain
  let directory: URL

  func cleanUp() {
    SecKeychainDelete(keychain)
    try? FileManager.default.removeItem(at: directory)
  }

  static func make() throws -> TestSigningMaterial? {
    let openssl = "/usr/bin/openssl"
    guard FileManager.default.isExecutableFile(atPath: openssl) else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-signing-keys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func run(_ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: openssl)
      process.arguments = arguments
      process.standardError = Pipe()
      process.standardOutput = Pipe()
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw PDFError(.malformed, "openssl \(arguments.first ?? "") failed")
      }
    }
    let caKey = directory.appendingPathComponent("ca.key").path
    let caPEMPath = directory.appendingPathComponent("ca.pem").path
    let leafKey = directory.appendingPathComponent("leaf.key").path
    let leafCSR = directory.appendingPathComponent("leaf.csr").path
    let leafPEM = directory.appendingPathComponent("leaf.pem").path
    let p12Path = directory.appendingPathComponent("identity.p12").path
    try run([
      "req", "-x509", "-newkey", "rsa:2048", "-keyout", caKey, "-out", caPEMPath, "-days", "2",
      "-nodes", "-sha256", "-subj", "/CN=sPDF Test CA/O=sPDF Editor",
    ])
    try run([
      "req", "-newkey", "rsa:2048", "-keyout", leafKey, "-out", leafCSR, "-nodes", "-sha256",
      "-subj", "/CN=sPDF Test Signer/O=sPDF Editor",
    ])
    try run([
      "x509", "-req", "-in", leafCSR, "-CA", caPEMPath, "-CAkey", caKey, "-CAcreateserial",
      "-out", leafPEM, "-days", "2", "-sha256",
    ])
    try run([
      "pkcs12", "-export", "-out", p12Path, "-inkey", leafKey, "-in", leafPEM, "-certfile",
      caPEMPath, "-passout", "pass:test", "-name", "sPDF Test Signer",
    ])
    let p12 = try Data(contentsOf: URL(fileURLWithPath: p12Path))
    let caPEM = try Data(contentsOf: URL(fileURLWithPath: caPEMPath))
    guard let caCertificate = certificate(fromPEM: caPEM) else {
      try? FileManager.default.removeItem(at: directory)
      return nil
    }
    let keychainPath = NSTemporaryDirectory() + "spdf-signing-\(UUID().uuidString).keychain"
    var keychain: SecKeychain?
    guard
      SecKeychainCreate(keychainPath, 4, "test", false, nil, &keychain) == errSecSuccess,
      let keychain
    else {
      try? FileManager.default.removeItem(at: directory)
      return nil
    }
    let options: [String: Any] = [
      kSecImportExportPassphrase as String: "test",
      kSecImportExportKeychain as String: keychain,
    ]
    var items: CFArray?
    guard SecPKCS12Import(p12 as CFData, options as CFDictionary, &items) == errSecSuccess,
      let array = items as? [[String: Any]],
      let value = array.first?[kSecImportItemIdentity as String]
    else {
      SecKeychainDelete(keychain)
      try? FileManager.default.removeItem(at: directory)
      return nil
    }
    return TestSigningMaterial(
      identity: value as! SecIdentity, caCertificate: caCertificate, caPEM: caPEM,
      keychain: keychain, directory: directory)
  }

  static func certificate(fromPEM pem: Data) -> SecCertificate? {
    let text = String(decoding: pem, as: UTF8.self)
    let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded: base64) else { return nil }
    return SecCertificateCreateWithData(nil, der as CFData)
  }
}
