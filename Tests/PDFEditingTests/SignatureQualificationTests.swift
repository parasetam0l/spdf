import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// SIG-01: independent qualification of the current signing and validation
/// profile. Every case that claims cryptographic validity is cross-checked by
/// the system openssl CMS verifier against the exact signed byte ranges; the
/// app's own read-only panel output is never treated as cryptographic proof.
/// When SPDF_SIG_QUALIFICATION_DIR is set, the artifacts are also written there
/// for poppler pdfsig / qpdf / mutool inspection.
@Suite("Signature qualification")
struct SignatureQualificationTests {
  private func signingTime() -> Date { Date(timeIntervalSince1970: 1_767_225_600) }

  private func material(
    _ algorithm: TestSigningMaterial.Algorithm = .rsa2048,
    commonName: String = "sPDF Test Signer"
  ) throws -> TestSigningMaterial {
    try #require(try TestSigningMaterial.make(algorithm: algorithm, commonName: commonName))
  }

  private func firstSignature(in data: Data) throws -> PDFSignature {
    let parsed = try PDFParser.parse(data)
    return try #require(try PDFSignatureInventory.signatures(in: parsed.graph).first)
  }

  private func saveArtifact(_ data: Data, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["SPDF_SIG_QUALIFICATION_DIR"]
    else { return }
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? data.write(to: url.appendingPathComponent(name))
  }

  @Test func rsaSigningQualifiesAgainstOpenSSL() throws {
    let material = try material(.rsa2048)
    defer { material.cleanUp() }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let data = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(
        fieldName: "RSA", reason: "qualification", signingTime: signingTime()))
    let parsed = try PDFParser.parse(data)
    let sig = try firstSignature(in: data)
    let validation = PDFSignatureValidator.validate(
      sig, source: data, finalGraph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.digestAlgorithm == "SHA-256")
    #expect(validation.signatureAlgorithm?.contains("RSA") == true)
    #expect(validation.signerIdentity?.commonName == "sPDF Test Signer")
    #expect(validation.signerIdentity?.issuerCommonName == "sPDF Test CA")
    #expect(validation.uncoveredTrailingBytes == 0)
    #expect(validation.signatureCoversWholeFile)
    let independent = try SignatureQualificationSupport.opensslVerify(
      data: data, signature: sig, caPEM: material.caPEM)
    #expect(independent.succeeded, "openssl rejected: \(independent.message)")
    saveArtifact(data, name: "rsa-valid.pdf")
    saveArtifact(material.caPEM, name: "rsa-ca.pem")
    #expect(try SignatureQualificationSupport.qpdfCheck(data))
    // Independent reader (poppler pdfsig) reports a valid signature and the
    // SHA-256 digest; a missing tool is a skip, never a pass claim.
    if let report = try SignatureQualificationSupport.pdfsigReport(data) {
      #expect(report.contains("Signature is Valid."), "pdfsig report: \(report)")
      #expect(report.contains("SHA-256"), "pdfsig report: \(report)")
    }
  }

  @Test func ecdsaP256SigningQualifiesAgainstOpenSSL() throws {
    let material = try material(.ecP256)
    defer { material.cleanUp() }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let data = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(fieldName: "EC", signingTime: signingTime()))
    let parsed = try PDFParser.parse(data)
    let sig = try firstSignature(in: data)
    let validation = PDFSignatureValidator.validate(
      sig, source: data, finalGraph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.digestAlgorithm == "SHA-256")
    #expect(validation.signatureAlgorithm?.contains("ECDSA") == true)
    let independent = try SignatureQualificationSupport.opensslVerify(
      data: data, signature: sig, caPEM: material.caPEM)
    #expect(independent.succeeded, "openssl rejected: \(independent.message)")
    saveArtifact(data, name: "ecdsa-valid.pdf")
    saveArtifact(material.caPEM, name: "ecdsa-ca.pem")
    #expect(try SignatureQualificationSupport.qpdfCheck(data))
    if let report = try SignatureQualificationSupport.pdfsigReport(data) {
      #expect(report.contains("Signature is Valid."), "pdfsig report: \(report)")
      #expect(report.contains("SHA-256"), "pdfsig report: \(report)")
    }
  }

  @Test func tamperedSignedByteIsRejectedByBothValidators() throws {
    let material = try material()
    defer { material.cleanUp() }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let signed = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Tamper", signingTime: signingTime()))
    // Flip one byte inside the signed ranges (page content text).
    var tampered = signed
    let marker = try #require(tampered.range(of: Data("fixture".utf8)))
    tampered[marker.lowerBound + 1] ^= 0x20
    let parsed = try PDFParser.parse(tampered)
    let tamperedSignature = try #require(
      try PDFSignatureInventory.signatures(in: parsed.graph).first)
    let validation = PDFSignatureValidator.validate(
      tamperedSignature, source: tampered, finalGraph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .invalid)
    #expect(validation.details.contains { $0.contains("message digest") })
    let independent = try SignatureQualificationSupport.opensslVerify(
      data: tampered, signature: tamperedSignature, caPEM: material.caPEM)
    #expect(!independent.succeeded)
    if let report = try SignatureQualificationSupport.pdfsigReport(tampered) {
      #expect(
        report.contains("Digest Mismatch") || report.contains("Signature is Invalid"),
        "pdfsig report: \(report)")
    }
    saveArtifact(tampered, name: "tampered-signed-byte.pdf")
  }

  @Test func tamperedSignatureValueAndByteRangeAreRejected() throws {
    let material = try material()
    defer { material.cleanUp() }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let signed = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Tamper", signingTime: signingTime()))
    let sig = try firstSignature(in: signed)
    let signedBytes = try SignatureQualificationSupport.signedBytes(
      data: signed, signature: sig)

    // 1) Flip a hex nibble inside /Contents: the CMS signature no longer
    // matches the covered bytes (or fails to parse as DER).
    var contentsTampered = signed
    let gap = try #require(SignatureQualificationSupport.contentsGap(in: signed, signature: sig))
    // Corrupt one byte of the actual CMS signature value (located through the
    // CMS parser) rather than a certificate or padding byte: the covered
    // bytes stay identical, so only the signature verification can notice.
    let originalCMS = try #require(SignatureQualificationSupport.cmsDER(sig))
    let parsedCMS = try CMSSignedData.parse(originalCMS)
    let signatureBytes = try #require(parsedCMS.signers.first?.signature)
    let signatureRange = try #require(originalCMS.range(of: signatureBytes))
    let byteOffset = signatureRange.lowerBound + signatureBytes.count / 2
    let nibble = gap.lowerBound + byteOffset * 2
    // Hex digit flip inside the signature value.
    contentsTampered[nibble] = contentsTampered[nibble] == 0x41 ? 0x42 : 0x41
    let contentsParsed = try PDFParser.parse(contentsTampered)
    let contentsSignature = try #require(
      try PDFSignatureInventory.signatures(in: contentsParsed.graph).first)
    let contentsValidation = PDFSignatureValidator.validate(
      contentsSignature, source: contentsTampered, finalGraph: contentsParsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(
      contentsValidation.crypto != .valid,
      "tampered CMS is never valid (got \(contentsValidation.crypto), details: \(contentsValidation.details))")
    let tamperedCMS = try #require(SignatureQualificationSupport.cmsDER(contentsSignature))
    let contentsIndependent = try SignatureQualificationSupport.opensslVerifyBytes(
      cms: tamperedCMS, signedBytes: signedBytes, caPEM: material.caPEM)
    #expect(!contentsIndependent.succeeded)
    saveArtifact(contentsTampered, name: "tampered-contents.pdf")

    // 2) Move the first covered range end by one byte: the covered bytes
    // change, so the message digest no longer matches.
    var byteRangeTampered = signed
    let second = try #require(
      SignatureQualificationSupport.secondIntegerRange(in: byteRangeTampered))
    let text = String(decoding: byteRangeTampered[second], as: UTF8.self)
    let value = Int(text) ?? 0
    let replacement = String(format: "%010d", max(0, value - 1))
    byteRangeTampered.replaceSubrange(second, with: Data(replacement.utf8))
    let rangeParsed = try PDFParser.parse(byteRangeTampered)
    let rangeSignature = try #require(
      try PDFSignatureInventory.signatures(in: rangeParsed.graph).first)
    let rangeValidation = PDFSignatureValidator.validate(
      rangeSignature, source: byteRangeTampered, finalGraph: rangeParsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(rangeValidation.crypto == .invalid)
    saveArtifact(byteRangeTampered, name: "tampered-byterange.pdf")
  }

  @Test func trailingBytesAndLaterRevisionsAreReportedSeparately() throws {
    let material = try material()
    defer { material.cleanUp() }
    // Two incremental signatures: the first covers only the revision it
    // signed, the second covers the whole file (including the first).
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let firstData = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(fieldName: "First", signingTime: signingTime()))
    let firstParsed = try PDFParser.parse(firstData)
    let secondData = try PDFSigningWriter.signIncremental(
      firstParsed, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Second", signingTime: signingTime()))
    let second = try PDFParser.parse(secondData)
    let signatures = try PDFSignatureInventory.signatures(in: second.graph)
    let first = try #require(signatures.first { $0.fieldName == "First" })
    let last = try #require(signatures.first { $0.fieldName == "Second" })

    let firstValidation = PDFSignatureValidator.validate(
      first, source: secondData, finalGraph: second.graph,
      trustedAnchors: [material.caCertificate])
    #expect(firstValidation.crypto == .valid)
    #expect(!firstValidation.signatureCoversWholeFile)
    #expect(firstValidation.uncoveredTrailingBytes > 0)
    #expect(firstValidation.unsignedChanges)
    #expect(firstValidation.changedObjectCount >= 1)
    let firstIndependent = try SignatureQualificationSupport.opensslVerify(
      data: secondData, signature: first, caPEM: material.caPEM)
    #expect(firstIndependent.succeeded, "openssl rejected the first signature: \(firstIndependent.message)")

    let lastValidation = PDFSignatureValidator.validate(
      last, source: secondData, finalGraph: second.graph,
      trustedAnchors: [material.caCertificate])
    #expect(lastValidation.crypto == .valid)
    #expect(lastValidation.signatureCoversWholeFile)
    #expect(lastValidation.uncoveredTrailingBytes == 0)
    #expect(!lastValidation.unsignedChanges)
    let lastIndependent = try SignatureQualificationSupport.opensslVerify(
      data: secondData, signature: last, caPEM: material.caPEM)
    #expect(lastIndependent.succeeded, "openssl rejected the last signature: \(lastIndependent.message)")
    saveArtifact(secondData, name: "later-revision-pair.pdf")

    // The committed later-revision fixture: cryptographically valid, but an
    // object changed after signing (the page was rotated incrementally).
    let fixtureDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Signed")
    let updatedData = try Data(
      contentsOf: fixtureDirectory.appendingPathComponent("signed-then-updated.pdf"))
    let updated = try PDFParser.parse(updatedData)
    let updatedSignature = try #require(
      try PDFSignatureInventory.signatures(in: updated.graph).first)
    let updatedValidation = PDFSignatureValidator.validate(
      updatedSignature, source: updatedData, finalGraph: updated.graph, trustedAnchors: [])
    #expect(updatedValidation.crypto == .valid)
    #expect(updatedValidation.unsignedChanges)
    #expect(updatedValidation.changedObjectCount >= 1)
    #expect(!updatedValidation.signatureCoversWholeFile)
  }

  @Test func twoIncrementalSignaturesEachQualifyIndependently() throws {
    let material = try material()
    defer { material.cleanUp() }
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let first = try PDFSigningWriter.signIncremental(
      parsed, identity: material.identity,
      options: PDFSigningOptions(fieldName: "First", signingTime: signingTime()))
    let parsedFirst = try PDFParser.parse(first)
    let second = try PDFSigningWriter.signIncremental(
      parsedFirst, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Second", signingTime: signingTime()))
    let final = try PDFParser.parse(second)
    let signatures = try PDFSignatureInventory.signatures(in: final.graph)
    #expect(signatures.count == 2)
    for sig in signatures {
      let validation = PDFSignatureValidator.validate(
        sig, source: second, finalGraph: final.graph,
        trustedAnchors: [material.caCertificate])
      #expect(validation.crypto == .valid)
      #expect(validation.trust == .trusted)
      let independent = try SignatureQualificationSupport.opensslVerify(
        data: second, signature: sig, caPEM: material.caPEM)
      #expect(independent.succeeded, "openssl rejected: \(independent.message)")
    }
    let firstName = try #require(signatures.first { $0.fieldName == "First" })
    let secondName = try #require(signatures.first { $0.fieldName == "Second" })
    let firstValidation = PDFSignatureValidator.validate(
      firstName, source: second, finalGraph: final.graph,
      trustedAnchors: [material.caCertificate])
    let secondValidation = PDFSignatureValidator.validate(
      secondName, source: second, finalGraph: final.graph,
      trustedAnchors: [material.caCertificate])
    #expect(firstValidation.unsignedChanges)
    #expect(!secondValidation.unsignedChanges)
    #expect(secondValidation.signatureCoversWholeFile)
    #expect(!firstValidation.signatureCoversWholeFile)
    #expect(try SignatureQualificationSupport.qpdfCheck(second))
    if let report = try SignatureQualificationSupport.pdfsigReport(second) {
      let validCount = report.components(separatedBy: "Signature is Valid.").count - 1
      #expect(validCount == 2, "pdfsig report: \(report)")
      #expect(report.contains("Not total document signed"))
      #expect(report.contains("Total document signed"))
    }
    saveArtifact(second, name: "two-signatures.pdf")
  }

  @Test func generatedCMSUsesCanonicalStrictDERAttributes() throws {
    let material = try material()
    defer { material.cleanUp() }
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let data = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(fieldName: "DER", signingTime: signingTime()))
    let sig = try firstSignature(in: data)
    let cmsDER = try #require(SignatureQualificationSupport.cmsDER(sig))
    let cms = try CMSSignedData.parse(cmsDER)
    let signer = try #require(cms.signers.first)
    let attributes = try #require(signer.signedAttributesDER)
    let limits = PDFLimits()
    var setReader = try DERReader(bytes: attributes)
    let set = try setReader.readElement(limits: limits)
    #expect(set.tag == 0x31)
    var reader = DERReader(
      bytes: attributes, offset: set.content.startIndex, end: set.content.endIndex)
    var encodings: [Data] = []
    var contentTypeValueTag: UInt8?
    while !reader.isAtEnd {
      let attribute = try reader.readElement(limits: limits)
      encodings.append(Data(attributes[attribute.start..<attribute.content.endIndex]))
      var attributeReader = DERReader(
        bytes: attributes, offset: attribute.content.startIndex, end: attribute.content.endIndex)
      let type = try attributeReader.readElement(limits: limits)
      let values = try attributeReader.readElement(limits: limits)
      guard type.tag == 0x06,
        DERReader.oid(type.content) == CMSSigner.contentTypeAttributeOID,
        values.tag == 0x31
      else { continue }
      var valueReader = DERReader(
        bytes: attributes, offset: values.content.startIndex, end: values.content.endIndex)
      let value = try valueReader.readElement(limits: limits)
      contentTypeValueTag = value.tag
    }
    // RFC 5652: contentType's AttributeValue is the ContentType OID itself.
    // An extra SEQUENCE here is accepted by OpenSSL but rejected by strict
    // independent CMS parsers (the SIG-01 poppler/NSS defect).
    #expect(contentTypeValueTag == 0x06)
    // DER SET OF elements are ordered by their complete encodings.
    #expect(encodings.sorted { $0.lexicographicallyPrecedes($1) } == encodings)
  }

  @Test func unsupportedEvidenceIsIndeterminateNeverValid() throws {
    let material = try material()
    defer { material.cleanUp() }
    let fixtureDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Signed")
    let signedFixture = try Data(
      contentsOf: fixtureDirectory.appendingPathComponent("signed-one-page.pdf"))

    // SHA-1 signature fixture: outside the supported digest profile.
    let sha1Data = try Data(
      contentsOf: fixtureDirectory.appendingPathComponent("signed-sha1.pdf"))
    let sha1 = try PDFParser.parse(sha1Data)
    let sha1Signature = try #require(
      try PDFSignatureInventory.signatures(in: sha1.graph).first)
    let sha1Validation = PDFSignatureValidator.validate(
      sha1Signature, source: sha1Data, finalGraph: sha1.graph, trustedAnchors: [])
    #expect(sha1Validation.crypto == .indeterminate)
    #expect(sha1Validation.details.contains { $0.contains("Unsupported digest") })

    // A multi-gap ByteRange is outside the declared single-gap profile.
    let parsed = try PDFParser.parse(signedFixture)
    let original = try #require(try PDFSignatureInventory.signatures(in: parsed.graph).first)
    let multiGap = PDFSignature(
      kind: original.kind, objectID: original.objectID, fieldName: original.fieldName,
      pageIndex: original.pageIndex, subFilter: original.subFilter,
      byteRange: [0, 10, 20, 10, 40, 10], contentsByteLength: original.contentsByteLength,
      signingTime: original.signingTime, reason: original.reason, location: original.location,
      name: original.name, docMDPPermission: original.docMDPPermission,
      fieldLockCount: original.fieldLockCount, dictionary: original.dictionary)
    let multiGapValidation = PDFSignatureValidator.validate(
      multiGap, source: signedFixture, finalGraph: parsed.graph, trustedAnchors: [])
    #expect(multiGapValidation.crypto == .indeterminate)
    #expect(multiGapValidation.details.contains { $0.contains("single-gap") })

    // A ByteRange that does not start at the beginning of the file is unsafe.
    let notFromStart = PDFSignature(
      kind: original.kind, objectID: original.objectID, fieldName: original.fieldName,
      pageIndex: original.pageIndex, subFilter: original.subFilter,
      byteRange: [10, 100, 200, 50], contentsByteLength: original.contentsByteLength,
      signingTime: original.signingTime, reason: original.reason, location: original.location,
      name: original.name, docMDPPermission: original.docMDPPermission,
      fieldLockCount: original.fieldLockCount, dictionary: original.dictionary)
    let notFromStartValidation = PDFSignatureValidator.validate(
      notFromStart, source: signedFixture, finalGraph: parsed.graph, trustedAnchors: [])
    #expect(notFromStartValidation.crypto == .invalid)
    #expect(notFromStartValidation.details.contains { $0.contains("begin at the start") })

    // A claimed signer whose SignerInfo names a different certificate must not
    // be accepted just because some embedded certificate verifies the bytes.
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let validSigned = try PDFSigningWriter.sign(
      graph, identity: material.identity,
      options: PDFSigningOptions(fieldName: "Claimed", signingTime: signingTime()))
    let validSignature = try firstSignature(in: validSigned)
    let signedBytes = try SignatureQualificationSupport.signedBytes(
      data: validSigned, signature: validSignature)
    let otherMaterial = try self.material(commonName: "Other Signer")
    defer { otherMaterial.cleanUp() }
    let mismatchedCMS = try CMSSigner.detachedSignature(
      signedBytes: signedBytes, identity: material.identity, signingTime: signingTime(),
      signerIdentifierCertificate: otherMaterial.caCertificate)
    let mismatched = try SignatureQualificationSupport.replacingContents(
      validSigned, signature: validSignature, cms: mismatchedCMS)
    let mismatchedParsed = try PDFParser.parse(mismatched)
    let mismatchedSignature = try #require(
      try PDFSignatureInventory.signatures(in: mismatchedParsed.graph).first)
    let mismatchedValidation = PDFSignatureValidator.validate(
      mismatchedSignature, source: mismatched, finalGraph: mismatchedParsed.graph,
      trustedAnchors: [material.caCertificate, otherMaterial.caCertificate])
    #expect(mismatchedValidation.crypto == .indeterminate)
    #expect(mismatchedValidation.details.contains { $0.contains("matches the SignerInfo") })
    saveArtifact(mismatched, name: "signer-identifier-mismatch.pdf")
  }
}