import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// SIG-06: signature-field selection, signer identity, signed-revision
/// inspection and permitted incremental signatures.
@Suite("Signature fields and revisions")
struct SignatureMultiSignerTests {
  private func signingTime() -> Date { Date(timeIntervalSince1970: 1_767_225_600) }

  private func material(
    _ algorithm: TestSigningMaterial.Algorithm = .rsa2048,
    commonName: String = "sPDF Test Signer"
  ) throws -> TestSigningMaterial {
    try #require(try TestSigningMaterial.make(algorithm: algorithm, commonName: commonName))
  }

  /// A one-page document with the requested empty signature fields.
  private func documentWithEmptyFields(_ names: [String]) throws -> ParsedPDF {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let pageID = try #require(parsed.pageIDs.first)
    var graph = parsed.graph
    for (index, name) in names.enumerated() {
      graph = try PDFEditingEngine.commit(
        PDFTransaction([
          AddSignatureFieldCommand(
            pageID: pageID,
            rect: [72, 120 - Double(index) * 60, 272, 160 - Double(index) * 60],
            name: name)
        ]), to: graph)
    }
    return try PDFParser.parse(PDFWriter.write(graph))
  }

  private func signature(named name: String, in graph: PDFGraph) throws -> PDFSignature {
    let fields = try PDFSignatureFieldInventory.fields(in: graph)
    let field = try #require(fields.first { $0.name == name })
    return try #require(field.signature)
  }

  @Test func fieldInventoryDistinguishesEmptyAndSignedFields() throws {
    let material = try material()
    defer { material.cleanUp() }
    var source = try documentWithEmptyFields(["Approval", "Reviewer"])
    let unsignedFields = try PDFSignatureFieldInventory.fields(in: source.graph)
    #expect(unsignedFields.map(\.name) == ["Approval", "Reviewer"])
    #expect(unsignedFields.allSatisfy { !$0.isSigned })
    #expect(unsignedFields.allSatisfy { $0.rect != nil && $0.pageIndex == 0 })

    let signed = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(
        signingTime: signingTime(), existingFieldName: "Approval"))
    #expect(signed.starts(with: source.source))
    source = try PDFParser.parse(signed)
    let fields = try PDFSignatureFieldInventory.fields(in: source.graph)
    let approval = try #require(fields.first { $0.name == "Approval" })
    let reviewer = try #require(fields.first { $0.name == "Reviewer" })
    #expect(approval.isSigned)
    #expect(!reviewer.isSigned)
    #expect(approval.signature?.fieldName == "Approval")
    // SIG-06: the generated dictionary names the signer from its certificate.
    #expect(approval.signature?.name?.contains("sPDF Test Signer") == true)
  }

  @Test func signingAnExistingFieldValidatesAndKeepsOriginalBytes() throws {
    let material = try material()
    defer { material.cleanUp() }
    let source = try documentWithEmptyFields(["Approval"])
    let unsigned = source.source
    let signed = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(
        reason: "approved", signingTime: signingTime(), existingFieldName: "Approval"))
    #expect(signed.starts(with: unsigned))
    let parsed = try PDFParser.parse(signed)
    let signature = try signature(named: "Approval", in: parsed.graph)
    #expect(signature.reason == "approved")
    #expect(signature.subFilter == "adbe.pkcs7.detached")
    let validation = PDFSignatureValidator.validate(
      signature, source: signed, finalGraph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.unsignedChanges == false)
    #expect(validation.signatureCoversWholeFile)
    #expect(validation.uncoveredTrailingBytes == 0)
    // The decoded signer identity is the certificate's subject, separately
    // from the cryptographic and trust statuses.
    let identity = try #require(validation.signerIdentity)
    #expect(identity.commonName == "sPDF Test Signer")
    #expect(identity.organization == "sPDF Editor")
    #expect(identity.serialNumberHex.isEmpty == false)
    #expect(identity.sha256Fingerprint.count == 64)
    #expect(identity.notAfter != nil)
    #expect(identity.issuerCommonName == "sPDF Test CA")
    try SignatureQualificationSupport.verifyWithOpenSSL(
      data: signed, signature: signature, caPEM: material.caPEM)
  }

  @Test func policyRefusesCertifiedChangesAndHonorsLocks() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    // Insert a certification signature dictionary with an explicit DocMDP
    // permission on a copy of the fixture graph (this is a permission-policy
    // unit test; cryptographic validity is covered elsewhere).
    func graph(withPermission permission: Int) throws -> PDFGraph {
      var graph = parsed.graph
      let signatures = try PDFSignatureInventory.signatures(in: graph)
      _ = signatures
      let id = PDFObjectID(70)
      graph.objects[id] = .dictionary([
        PDFName("Type"): .name(PDFName("Sig")),
        PDFName("Filter"): .name(PDFName("Adobe.PPKLite")),
        PDFName("SubFilter"): .name(PDFName("adbe.pkcs7.detached")),
        PDFName("ByteRange"): .array([
          .integer(0), .integer(10), .integer(20), .integer(10),
        ]),
        PDFName("Contents"): .string(Data(repeating: 0, count: 64)),
        PDFName("Reference"): .array([
          .dictionary([
            PDFName("Type"): .name(PDFName("SigRef")),
            PDFName("TransformMethod"): .name(PDFName("DocMDP")),
            PDFName("TransformParams"): .dictionary([PDFName("P"): .integer(Int64(permission))]),
          ])
        ]),
      ])
      // Reference the certification signature from a real field so the
      // inventory sees it exactly like a parsed document.
      let pageID = try #require(parsed.pageIDs.first)
      for (index, name) in ["Certifier", "Later", "Locked", "Other"].enumerated() {
        graph = try PDFEditingEngine.commit(
          PDFTransaction([
            AddSignatureFieldCommand(
              pageID: pageID,
              rect: [72, 300 - Double(index) * 50, 272, 340 - Double(index) * 50],
              name: name)
          ]), to: graph)
      }
      let fields = try FormInventory.fields(
        in: graph, pageIDs: try PDFPageTree.pageIDs(in: graph))
      let field = try #require(fields.first { $0.name == "Certifier" })
      guard case .dictionary(var fieldDictionary)? = field.fieldID.flatMap({ graph.objects[$0] })
      else { Issue.record("field missing"); return graph }
      fieldDictionary[PDFName("V")] = .reference(id)
      graph.objects[field.fieldID!] = .dictionary(fieldDictionary)
      return graph
    }

    let p1 = try graph(withPermission: 1)
    // Permission 1 permits no changes at all: both targets are refused.
    let p1Existing = try PDFSignatureSigningPolicy.decision(
      in: p1, target: .existingField(name: "Later"))
    #expect(!p1Existing.isAllowed)
    #expect(p1Existing.refusalReason?.contains("permission 1") == true)
    #expect(!(try PDFSignatureSigningPolicy.decision(
      in: p1, target: .newField(name: "Added"))).isAllowed)

    let p2 = try graph(withPermission: 2)
    #expect(try PDFSignatureSigningPolicy.decision(
      in: p2, target: .existingField(name: "Later")) == .allowed)
    // Permission 2 permits signing existing fields, not creating fields.
    #expect(!(try PDFSignatureSigningPolicy.decision(
      in: p2, target: .newField(name: "Added"))).isAllowed)

    let p3 = try graph(withPermission: 3)
    #expect(try PDFSignatureSigningPolicy.decision(
      in: p3, target: .newField(name: "Added")) == .allowed)

    // Field locks: an Include lock refuses exactly the named fields.
    var locked = try graph(withPermission: 3)
    let signatures = try PDFSignatureInventory.signatures(in: locked)
    let certification = try #require(signatures.first { $0.docMDPPermission != nil })
    guard case .dictionary(var signatureDictionary)? = certification.objectID.flatMap({
      locked.objects[$0]
    }) else { Issue.record("certification missing"); return }
    signatureDictionary[PDFName("Reference")] = .array([
      .dictionary([
        PDFName("Type"): .name(PDFName("SigRef")),
        PDFName("TransformMethod"): .name(PDFName("FieldMDP")),
        PDFName("TransformParams"): .dictionary([
          PDFName("Action"): .name(PDFName("Include")),
          PDFName("Fields"): .array([.string(Data("Locked".utf8))]),
        ]),
      ])
    ])
    locked.objects[certification.objectID!] = .dictionary(signatureDictionary)
    // The certification field itself is signed, so the policy sees a lock.
    #expect(!(try PDFSignatureSigningPolicy.decision(
      in: locked, target: .existingField(name: "Locked"))).isAllowed)
    #expect(try PDFSignatureSigningPolicy.decision(
      in: locked, target: .existingField(name: "Other")) == .allowed)
  }

  @Test func revisionReportDescribesEachSignatureAndItsChanges() throws {
    let material = try material()
    defer { material.cleanUp() }
    var source = try documentWithEmptyFields(["First", "Second"])
    for name in ["First", "Second"] {
      let signed = try PDFSigningWriter.signIncremental(
        source, identity: material.identity,
        options: PDFSigningOptions(signingTime: signingTime(), existingFieldName: name))
      source = try PDFParser.parse(signed)
    }
    let report = PDFSignedRevisionReport.build(
      source: source.source, graph: source.graph,
      trustedAnchors: [material.caCertificate])
    #expect(report.revisions.count == 2)
    let first = report.revisions[0]
    let second = report.revisions[1]
    #expect(first.fieldName == "First")
    #expect(second.fieldName == "Second")
    #expect(first.index == 1 && second.index == 2)
    #expect(first.coverageEnd < second.coverageEnd)
    #expect(first.signedByteCount > 0 && second.signedByteCount > first.signedByteCount)
    #expect(first.laterRevisions)
    #expect(!second.laterRevisions)
    #expect(first.validation.crypto == .valid)
    #expect(second.validation.crypto == .valid)
    #expect(first.validation.unsignedChanges)
    #expect(!second.validation.unsignedChanges)
    #expect(first.signerIdentity?.commonName == "sPDF Test Signer")
    // The second signature's revision adds a signature field/widget and a
    // signature dictionary; the report names the change instead of just a
    // count.
    #expect(!second.changesSincePrevious.isEmpty)
    #expect(
      second.changesSincePrevious.contains { $0.contains("signature") || $0.contains("annotation") })
    #expect(report.changesSinceLastSignature.isEmpty)
    #expect(report.finalUncoveredByteCount == 0)
  }

  @Test func signerIdentityIsDecodedFromAClaimedCertificateWhenVerificationFails() throws {
    let material = try material()
    defer { material.cleanUp() }
    let source = try documentWithEmptyFields(["Approval"])
    let signed = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(signingTime: signingTime(), existingFieldName: "Approval"))
    var tampered = signed
    let marker = try #require(tampered.range(of: Data("Digitally signed".utf8)))
    tampered[marker.lowerBound] ^= 0x01
    let parsed = try PDFParser.parse(tampered)
    let signature = try signature(named: "Approval", in: parsed.graph)
    let validation = PDFSignatureValidator.validate(
      signature, source: tampered, finalGraph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .invalid)
    // SIG-06: the claimed signer is still identifiable from the certificate
    // named by the SignerInfo, even though the bytes no longer verify.
    #expect(validation.signerIdentity?.commonName == "sPDF Test Signer")
    #expect(validation.signerName?.contains("sPDF Test Signer") == true)
  }

  @Test func signingRefusesMissingSignedOrLockedTargets() throws {
    let material = try material()
    defer { material.cleanUp() }
    var source = try documentWithEmptyFields(["Approval"])
    #expect(throws: PDFError.self) {
      _ = try PDFSigningWriter.signIncremental(
        source, identity: material.identity,
        options: PDFSigningOptions(signingTime: signingTime(), existingFieldName: "Missing"))
    }
    source = try PDFParser.parse(
      try PDFSigningWriter.signIncremental(
        source, identity: material.identity,
        options: PDFSigningOptions(signingTime: signingTime(), existingFieldName: "Approval")))
    #expect(throws: PDFError.self) {
      _ = try PDFSigningWriter.signIncremental(
        source, identity: material.identity,
        options: PDFSigningOptions(signingTime: signingTime(), existingFieldName: "Approval"))
    }
    // A full rewrite of an already-signed graph is refused; adding another
    // signature must be incremental.
    #expect(throws: PDFError.self) {
      _ = try PDFSigningWriter.sign(
        source.graph, identity: material.identity,
        options: PDFSigningOptions(fieldName: "Other", signingTime: signingTime()))
    }
  }

  @Test func ecdsaIdentitySignsExistingFieldAndValidatesIndependently() throws {
    let material = try material(.ecP256)
    defer { material.cleanUp() }
    let source = try documentWithEmptyFields(["EC"])
    let signed = try PDFSigningWriter.signIncremental(
      source, identity: material.identity,
      options: PDFSigningOptions(signingTime: signingTime(), existingFieldName: "EC"))
    let parsed = try PDFParser.parse(signed)
    let signature = try signature(named: "EC", in: parsed.graph)
    let validation = PDFSignatureValidator.validate(
      signature, source: signed, finalGraph: parsed.graph,
      trustedAnchors: [material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.signatureAlgorithm?.contains("ECDSA") == true)
    #expect(validation.signerIdentity?.commonName == "sPDF Test Signer")
    try SignatureQualificationSupport.verifyWithOpenSSL(
      data: signed, signature: signature, caPEM: material.caPEM)
  }
}
