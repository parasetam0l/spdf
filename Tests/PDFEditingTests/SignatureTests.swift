import CryptoKit
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// P30-001–P30-015/P30-023/P30-027–P30-030 evidence: signature dictionary
/// inventory, ByteRange validation, CMS parsing and cryptographic
/// verification with system primitives, trust reported separately from
/// validity, revision change comparison, and honest indeterminate reporting.
@Suite("Signature validation")
struct SignatureTests {
  private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Signed/\(name)")
    return try Data(contentsOf: url)
  }

  /// The trust anchor for the committed fixtures: the CA certificate embedded
  /// in the signature's CMS chain (no key material is committed).
  private func fixtureAnchorCertificate(_ name: String) throws -> SecCertificate {
    let data = try fixture(name)
    let parsed = try PDFParser.parse(data)
    let signature = try #require(try PDFSignatureInventory.signatures(in: parsed.graph).first)
    guard case .string(let contents)? = signature.dictionary[PDFName("Contents")] else {
      throw PDFError(.malformed, "Signature contents missing")
    }
    let cms = try CMSSignedData.parse(contents)
    let caDER = try #require(cms.certificates.last)
    return try #require(SecCertificateCreateWithData(nil, Data(caDER) as CFData))
  }

  private func signature(
    in graph: PDFGraph
  ) throws -> PDFSignature {
    let signatures = try PDFSignatureInventory.signatures(in: graph)
    return try #require(signatures.first)
  }

  @Test func inventoryFindsTheSignatureField() throws {
    let parsed = try PDFParser.parse(try fixture("signed-one-page.pdf"))
    let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
    #expect(signatures.count == 1)
    let signature = try #require(signatures.first)
    #expect(signature.kind == .signature)
    #expect(signature.fieldName == "Signature1")
    #expect(signature.subFilter == "adbe.pkcs7.detached")
    #expect(signature.byteRange.count == 4)
    #expect(signature.contentsByteLength == 8192)
    #expect(signature.docMDPPermission == nil)
    #expect(signature.fieldLockCount == 0)
  }

  @Test func validSignatureWithExplicitAnchor() throws {
    let data = try fixture("signed-one-page.pdf")
    let parsed = try PDFParser.parse(data)
    let signature = try signature(in: parsed.graph)
    let ca = try fixtureAnchorCertificate("signed-one-page.pdf")
    let validation = PDFSignatureValidator.validate(
      signature, source: data, finalGraph: parsed.graph, trustedAnchors: [ca])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.digestAlgorithm == "SHA-256")
    #expect(validation.signatureAlgorithm?.contains("RSA") == true)
    #expect(validation.signerName?.contains("sPDF Test Signer") == true)
    #expect(validation.signerNotAfter != nil)
    #expect(validation.revocationChecked == false)
    #expect(validation.unsignedChanges == false)
    #expect(validation.details.contains { $0.contains("revocation was not checked") })
  }

  @Test func trustIsReportedSeparatelyFromCryptographicValidity() throws {
    // Without the test anchor the chain is not trusted, but the cryptographic
    // evidence is still valid — the two statuses must not be conflated.
    let data = try fixture("signed-one-page.pdf")
    let parsed = try PDFParser.parse(data)
    let signature = try signature(in: parsed.graph)
    let validation = PDFSignatureValidator.validate(
      signature, source: data, finalGraph: parsed.graph)
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .unknown)
  }

  @Test func tamperedBytesAreDetected() throws {
    var data = try fixture("signed-one-page.pdf")
    // Flip one byte inside the signed ranges (the page content stream).
    let marker = try #require(data.range(of: Data("Signed fixture".utf8)))
    data[marker.lowerBound + 1] ^= 0x20
    let parsed = try PDFParser.parse(data)
    let signature = try signature(in: parsed.graph)
    let ca = try fixtureAnchorCertificate("signed-one-page.pdf")
    let validation = PDFSignatureValidator.validate(
      signature, source: data, finalGraph: parsed.graph, trustedAnchors: [ca])
    #expect(validation.crypto == .invalid)
    #expect(validation.details.contains { $0.contains("message digest") })
  }

  @Test func brokenByteRangesAreDetected() throws {
    let data = try fixture("signed-one-page.pdf")
    let parsed = try PDFParser.parse(data)
    let original = try signature(in: parsed.graph)
    let broken = PDFSignature(
      kind: original.kind, objectID: original.objectID, fieldName: original.fieldName,
      pageIndex: original.pageIndex, subFilter: original.subFilter,
      byteRange: [0, 10, 20, 30], contentsByteLength: original.contentsByteLength,
      signingTime: original.signingTime, reason: original.reason, location: original.location,
      name: original.name, docMDPPermission: original.docMDPPermission,
      fieldLockCount: original.fieldLockCount, dictionary: original.dictionary)
    let validation = PDFSignatureValidator.validate(
      broken, source: data, finalGraph: parsed.graph)
    #expect(validation.crypto == .invalid)
    #expect(!validation.details.isEmpty)
  }

  @Test func laterRevisionsAreReportedAsUnsignedChanges() throws {
    let data = try fixture("signed-then-updated.pdf")
    let parsed = try PDFParser.parse(data)
    let signature = try signature(in: parsed.graph)
    let ca = try fixtureAnchorCertificate("signed-one-page.pdf")
    let validation = PDFSignatureValidator.validate(
      signature, source: data, finalGraph: parsed.graph, trustedAnchors: [ca])
    #expect(validation.crypto == .valid)
    #expect(validation.trust == .trusted)
    #expect(validation.unsignedChanges)
    #expect(validation.changedObjectCount >= 1)
    #expect(validation.details.contains { $0.contains("changed after signing") })
    // The updated revision really is a rotation added after signing.
    guard case .dictionary(let page)? = parsed.graph.objects[parsed.pageIDs[0]],
      case .integer(let rotation)? = page[PDFName("Rotate")]
    else {
      Issue.record("Updated page missing")
      return
    }
    #expect(rotation == 90)
  }

  @Test func unsupportedDigestIsIndeterminateNotValid() throws {
    let data = try fixture("signed-sha1.pdf")
    let parsed = try PDFParser.parse(data)
    let signature = try signature(in: parsed.graph)
    let ca = try fixtureAnchorCertificate("signed-one-page.pdf")
    let validation = PDFSignatureValidator.validate(
      signature, source: data, finalGraph: parsed.graph, trustedAnchors: [ca])
    #expect(validation.crypto == .indeterminate)
    #expect(validation.digestAlgorithm == "1.3.14.3.2.26")
    #expect(validation.details.contains { $0.contains("Unsupported digest") })
  }

  @Test func signedDocumentsRefuseRewritingAndKeepTheirBytes() throws {
    let data = try fixture("signed-one-page.pdf")
    let parsed = try PDFParser.parse(data)
    #expect(parsed.source == data)
    #expect(throws: PDFError.self) {
      _ = try PDFWriter.write(parsed.graph)
    }
  }

  @Test func docMDPPermissionsAndFieldLocksAreInventoried() throws {
    let data = try fixture("signed-one-page.pdf")
    var graph = try PDFParser.parse(data).graph
    // Attach a DocMDP transform reference to the signature and a lock to the
    // field, then re-inventory.
    guard case .dictionary(var signatureDictionary)? = graph.objects[PDFObjectID(8)] else {
      Issue.record("Signature dictionary missing")
      return
    }
    signatureDictionary[PDFName("Reference")] = .array([
      .dictionary([
        PDFName("Type"): .name(PDFName("SigRef")),
        PDFName("TransformMethod"): .name(PDFName("DocMDP")),
        PDFName("TransformParams"): .dictionary([PDFName("P"): .integer(2)]),
      ])
    ])
    graph.objects[PDFObjectID(8)] = .dictionary(signatureDictionary)
    guard case .dictionary(var field)? = graph.objects[PDFObjectID(7)] else {
      Issue.record("Field dictionary missing")
      return
    }
    field[PDFName("Lock")] = .dictionary([
      PDFName("Type"): .name(PDFName("SigFieldLock")),
      PDFName("Action"): .name(PDFName("All")),
    ])
    graph.objects[PDFObjectID(7)] = .dictionary(field)

    let signatures = try PDFSignatureInventory.signatures(in: graph)
    let updated = try #require(signatures.first)
    #expect(updated.docMDPPermission == 2)
    #expect(updated.fieldLockCount == 1)
  }

  @Test func timestampOnlyObjectsAreInventoried() throws {
    // A document-timestamp dictionary is found even without a field.
    var graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    graph.objects[PDFObjectID(40)] = .dictionary([
      PDFName("Type"): .name(PDFName("DocTimeStamp")),
      PDFName("Filter"): .name(PDFName("Adobe.PPKLite")),
      PDFName("SubFilter"): .name(PDFName("ETSI.RFC3161")),
      PDFName("ByteRange"): .array([
        .integer(0), .integer(100), .integer(200), .integer(50),
      ]),
      PDFName("Contents"): .string(Data(repeating: 0, count: 32)),
    ])
    let signatures = try PDFSignatureInventory.signatures(in: graph)
    #expect(signatures.count == 1)
    #expect(signatures.first?.kind == .documentTimestamp)
    #expect(signatures.first?.subFilter == "ETSI.RFC3161")
  }
}
