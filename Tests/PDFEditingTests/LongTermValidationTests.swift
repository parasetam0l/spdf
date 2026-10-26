import CryptoKit
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Security
import Testing

/// SIG-04: PAdES/DSS long-term validation evidence. The fixtures generate real
/// CA-signed certificates, OCSP/CRL responses and RFC 3161 tokens at test time
/// (no keys or evidence are committed), so the production parsers and offline
/// trust evaluation are exercised with real cryptographic material.
@Suite("Long-term validation")
struct LongTermValidationTests {
  struct Rig {
    let signer: TestSigningMaterial
    let tsa: EvidenceSigner
    let signerAnchors: [SecCertificate]
    let tsaAnchors: [SecCertificate]
  }

  func makeRig() throws -> Rig? {
    guard let signer = try TestSigningMaterial.make(commonName: "sPDF LTV Signer"),
      let tsa = try EvidenceSigner.make(commonName: "sPDF LTV TSA")
    else { return nil }
    return Rig(
      signer: signer, tsa: tsa,
      signerAnchors: [signer.caCertificate],
      tsaAnchors: [tsa.material.caCertificate])
  }

  func timestampAuthority(_ tsa: EvidenceSigner) -> MockTimestampAuthority {
    MockTimestampAuthority { requestDER in
      let request = try TimestampRequestBuilder.parse(requestDER)
      let token = try EvidenceFixtures.timestampToken(
        imprint: request.imprint, nonce: request.nonce, genTime: Date(), signer: tsa)
      return EvidenceFixtures.timestampResponse(token: token)
    }
  }

  func signedDocument(
    rig: Rig, includeTimestamp: Bool = true
  ) throws -> Data {
    let graph = try PDFParser.parse(PDFFixtures.onePage()).graph
    let options = PDFSigningOptions(
      fieldName: "LTVSignature", pageIndex: 0, rect: [72, 72, 272, 112],
      signingTime: Date())
    if includeTimestamp {
      return try PDFSigningWriter.sign(
        graph, identity: rig.signer.identity, options: options,
        timestamp: PDFTimestampSigningOptions(
          authority: timestampAuthority(rig.tsa), requirement: .required,
          trustedAnchors: rig.tsaAnchors)).data
    }
    return try PDFSigningWriter.sign(graph, identity: rig.signer.identity, options: options)
  }

  func dssOptions(
    rig: Rig, fieldName: String = "LTVSignature", ocspStatus: EvidenceFixtures.OCSPStatus = .good
  ) throws -> PDFLongTermEvidenceOptions {
    let now = Date()
    let signerEvidence = EvidenceSigner(material: rig.signer)
    let ocsp = try EvidenceFixtures.ocspResponse(
      leaf: signerEvidence, status: ocspStatus,
      thisUpdate: now.addingTimeInterval(-60), nextUpdate: now.addingTimeInterval(3_600))
    let crl = try EvidenceFixtures.crl(
      leaf: signerEvidence, revokedLeaf: false,
      thisUpdate: now.addingTimeInterval(-60), nextUpdate: now.addingTimeInterval(3_600))
    return PDFLongTermEvidenceOptions(
      signatureFieldName: fieldName,
      certificatesDER: [
        signerEvidence.leafDER, signerEvidence.issuerDER,
        rig.tsa.leafDER, rig.tsa.issuerDER,
      ],
      ocspResponsesDER: [ocsp], crlsDER: [crl])
  }

  @Test func longTermEvidenceUpgradesSignedPDFToBaselineLT() throws {
    let rig = try #require(try makeRig())
    defer {
      rig.signer.cleanUp()
      rig.tsa.cleanUp()
    }
    let signed = try signedDocument(rig: rig)
    let signedParsed = try PDFParser.parse(signed)
    let outcome = try PDFLongTermEvidenceWriter.appendDSS(
      to: signedParsed, options: dssOptions(rig: rig))
    #expect(outcome.inventory.hasDSS)
    #expect(outcome.inventory.certificateCount == 4)
    #expect(outcome.inventory.ocspCount == 1)
    #expect(outcome.inventory.crlCount == 1)
    #expect(outcome.vriKey.count == 40)
    #expect(outcome.data.prefix(signed.count) == signed)

    let reopened = try PDFParser.parse(outcome.data)
    let report = PDFLongTermValidationValidator.report(
      in: reopened, trustedAnchors: rig.signerAnchors,
      timestampTrustedAnchors: rig.tsaAnchors)
    #expect(report.profile == .baselineLT)
    #expect(report.isLongTermValid)
    #expect(report.dss.certificateCount == 4)
    #expect(report.dss.vri.count == 1)
    #expect(report.dss.entry(forSignatureContents: contents(of: reopened, field: "LTVSignature")
      ?? Data()) != nil)
    #expect(report.signatures.count == 1)
    let signature = try #require(report.signatures.first)
    #expect(signature.status == .longTermComplete)
    #expect(signature.hasVRIEntry)
    #expect(signature.signerCertificateEmbedded)
    #expect(signature.signatureTimestamp.isEmbeddable)
    #expect(signature.revocation.isConclusiveGood)
    #expect(signature.revocation.source == .ocsp)
    #expect(signature.cryptoValid)
    #expect(report.documentTimestamps.isEmpty)
    #expect(report.warnings.contains { $0.contains("B-LT") })
    #expect(report.disclosure.contains("PAdES/DSS subset"))
    #expect(report.disclosure.contains("B-LTA"))
    #expect(report.plainText.contains("Long-term profile: PAdES B-LT"))

    // The earlier signature still verifies: DSS is an incremental update.
    let signatureModel = try #require(
      PDFSignatureInventory.signatures(in: reopened.graph).first)
    let validation = PDFSignatureValidator.validate(
      signatureModel, source: outcome.data, finalGraph: reopened.graph,
      trustedAnchors: rig.signerAnchors, timestampTrustedAnchors: rig.tsaAnchors)
    #expect(validation.crypto == .valid)
    #expect(validation.timestamp.isEmbeddable)
  }

  @Test func documentTimestampUpgradesBaselineLTToLTA() throws {
    let rig = try #require(try makeRig())
    defer {
      rig.signer.cleanUp()
      rig.tsa.cleanUp()
    }
    let signed = try signedDocument(rig: rig)
    let dssOutcome = try PDFLongTermEvidenceWriter.appendDSS(
      to: try PDFParser.parse(signed), options: dssOptions(rig: rig))
    let dssParsed = try PDFParser.parse(dssOutcome.data)
    let timestampOutcome = try PDFDocumentTimestampWriter.appendDocumentTimestamp(
      to: dssParsed, authority: timestampAuthority(rig.tsa),
      options: PDFDocumentTimestampOptions(fieldName: "ArchivalTimestamp"),
      trustedAnchors: rig.tsaAnchors)
    #expect(timestampOutcome.evidence.isEmbeddable)
    #expect(timestampOutcome.evidence.isFullyVerified)
    #expect(timestampOutcome.data.prefix(dssOutcome.data.count) == dssOutcome.data)

    let reopened = try PDFParser.parse(timestampOutcome.data)
    let timestamps = try PDFSignatureInventory.signatures(in: reopened.graph)
      .filter { $0.kind == .documentTimestamp }
    #expect(timestamps.count == 1)
    #expect(timestamps.first?.subFilter == "ETSI.RFC3161")
    let report = PDFLongTermValidationValidator.report(
      in: reopened, trustedAnchors: rig.signerAnchors,
      timestampTrustedAnchors: rig.tsaAnchors)
    #expect(report.profile == .baselineLTA)
    #expect(report.isLongTermValid)
    #expect(report.documentTimestamps.count == 1)
    let timestamp = try #require(report.documentTimestamps.first)
    #expect(timestamp.isValid)
    #expect(timestamp.coversWholeFile)
    #expect(timestamp.imprintMatches)
    #expect(report.plainText.contains("PAdES B-LTA"))
  }

  @Test func signedWithoutDSSIsNotLongTermValid() throws {
    let rig = try #require(try makeRig())
    defer {
      rig.signer.cleanUp()
      rig.tsa.cleanUp()
    }
    let signed = try signedDocument(rig: rig)
    let report = PDFLongTermValidationValidator.report(
      in: try PDFParser.parse(signed), trustedAnchors: rig.signerAnchors,
      timestampTrustedAnchors: rig.tsaAnchors)
    #expect(report.profile == .noEmbeddedEvidence)
    #expect(!report.isLongTermValid)
    #expect(!report.dss.hasDSS)
    #expect(report.signatures.first?.status == .missingEvidence)
    #expect(report.warnings.contains { $0.contains("no DSS") })
    #expect(report.disclosure.contains("B-LT"))
  }

  @Test func missingSignatureTimestampKeepsEvidenceIncomplete() throws {
    let rig = try #require(try makeRig())
    defer {
      rig.signer.cleanUp()
      rig.tsa.cleanUp()
    }
    let signed = try signedDocument(rig: rig, includeTimestamp: false)
    let outcome = try PDFLongTermEvidenceWriter.appendDSS(
      to: try PDFParser.parse(signed), options: dssOptions(rig: rig))
    let report = PDFLongTermValidationValidator.report(
      in: try PDFParser.parse(outcome.data), trustedAnchors: rig.signerAnchors,
      timestampTrustedAnchors: rig.tsaAnchors)
    #expect(report.profile == .incomplete)
    #expect(!report.isLongTermValid)
    let signature = try #require(report.signatures.first)
    #expect(signature.status == .missingTimestamp)
    #expect(!signature.signatureTimestamp.isEmbeddable)
    #expect(signature.cryptoValid)
  }

  @Test func revokedEmbeddedOCSPIsNeverLongTermValid() throws {
    let rig = try #require(try makeRig())
    defer {
      rig.signer.cleanUp()
      rig.tsa.cleanUp()
    }
    let signed = try signedDocument(rig: rig)
    let options = try dssOptions(rig: rig, ocspStatus: .revoked(Date()))
    let outcome = try PDFLongTermEvidenceWriter.appendDSS(
      to: try PDFParser.parse(signed), options: options)
    let report = PDFLongTermValidationValidator.report(
      in: try PDFParser.parse(outcome.data), trustedAnchors: rig.signerAnchors,
      timestampTrustedAnchors: rig.tsaAnchors)
    #expect(report.profile == .incomplete)
    #expect(!report.isLongTermValid)
    let signature = try #require(report.signatures.first)
    #expect(signature.status == .revoked)
    #expect(signature.revocation.isConclusiveRevoked)
  }

  @Test func evidenceEmbeddingRequiresAUniqueOrNamedSignature() throws {
    let rig = try #require(try makeRig())
    defer {
      rig.signer.cleanUp()
      rig.tsa.cleanUp()
    }
    let signed = try signedDocument(rig: rig)
    let parsed = try PDFParser.parse(signed)
    do {
      _ = try PDFLongTermEvidenceWriter.appendDSS(
        to: parsed,
        options: PDFLongTermEvidenceOptions(
          signatureFieldName: "NoSuchSignature",
          certificatesDER: [EvidenceSigner(material: rig.signer).leafDER]))
      Issue.record("DSS evidence for an unknown field must be refused")
    } catch let error as PDFError {
      #expect(error.kind == .malformed)
    }
  }

  @Test func profileDisclosuresNameTheExactSupportedSubset() {
    let text = PDFLongTermValidationDisclosure.supportedProfile
    #expect(text.contains("PAdES/DSS subset"))
    #expect(text.contains("/DSS"))
    #expect(text.contains("/VRI"))
    #expect(text.contains("SHA-1"))
    #expect(text.contains("B-LTA"))
    #expect(text.contains("offline"))
    let unsupported = PDFLongTermValidationDisclosure.unsupportedProfile
    #expect(unsupported.contains("multiple /ByteRange gaps"))
    #expect(unsupported.contains("never as long-term valid"))
  }

  func contents(of parsed: ParsedPDF, field: String) -> Data? {
    let signatures = (try? PDFSignatureInventory.signatures(in: parsed.graph)) ?? []
    guard let signature = signatures.first(where: { $0.fieldName == field }),
      case .string(let data)? = signature.dictionary[PDFName("Contents")]
    else { return nil }
    return data
  }
}
