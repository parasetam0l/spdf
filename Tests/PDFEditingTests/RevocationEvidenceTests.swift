import Foundation
import PDFCore
@testable import PDFEditing
import Testing

@Suite("Signature revocation evidence")
struct RevocationEvidenceTests {
  // Evaluated at use time: the temporary CA/leaf are created after the suite
  // is initialized, so a captured "now" can precede the certificate's
  // notBefore and make offline trust evaluation look not-yet-valid.
  private var now: Date { Date() }
  private var freshStart: Date { now.addingTimeInterval(-60) }
  private var freshEnd: Date { now.addingTimeInterval(3_600) }

  @Test func freshOCSPGoodIsConclusive() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good, thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .good, "(evidence.details)")
    #expect(evidence.source == .ocsp)
    #expect(evidence.signatureValid)
    #expect(evidence.responderTrusted == true)
    #expect(evidence.freshness == .fresh)
    #expect(evidence.isConclusiveGood)
    #expect(evidence.serialNumber != nil)
  }

  @Test func revokedOCSPStaysDistinguishable() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let revokedAt = now.addingTimeInterval(-600)
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .revoked(revokedAt), thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .revoked)
    #expect(evidence.revocationTime != nil)
    #expect(evidence.isConclusiveRevoked)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func unknownOCSPIsNotGood() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .unknown, thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .unknown)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func staleOCSPIsNotCurrentEvidence() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good, thisUpdate: now.addingTimeInterval(-7_200),
      nextUpdate: now.addingTimeInterval(-3_600))
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .stale)
    #expect(evidence.freshness == .stale)
    #expect(evidence.signatureValid)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func badOCSPSignatureIsUnknown() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good, thisUpdate: freshStart, nextUpdate: freshEnd,
      tamperSignature: true)
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .unknown)
    #expect(!evidence.signatureValid)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func ocspWithoutAnchorsReportsUnknownTrust() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good, thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      at: now)
    #expect(evidence.status == .good)
    #expect(evidence.signatureValid)
    #expect(evidence.responderTrusted == nil)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func ocspWithWrongAnchorIsUnknown() throws {
    guard let signer = try EvidenceSigner.make(),
      let other = try EvidenceSigner.make(commonName: "Different Anchor")
    else { return }
    defer {
      signer.cleanUp()
      other.cleanUp()
    }
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good, thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateOCSP(
      responseDER: response, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [other.material.caCertificate], at: now)
    #expect(evidence.status == .unknown)
    #expect(evidence.responderTrusted == false)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func freshCRLGoodIsConclusive() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let crl = try EvidenceFixtures.crl(
      leaf: signer, revokedLeaf: false, thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateCRL(
      crlDER: crl, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .good, "(evidence.details)")
    #expect(evidence.source == .crl)
    #expect(evidence.signatureValid)
    #expect(evidence.responderTrusted == true)
    #expect(evidence.freshness == .fresh)
    #expect(evidence.isConclusiveGood)
  }

  @Test func revokedCRLIsConclusive() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let crl = try EvidenceFixtures.crl(
      leaf: signer, revokedLeaf: true, thisUpdate: freshStart, nextUpdate: freshEnd)
    let evidence = PDFRevocationValidator.validateCRL(
      crlDER: crl, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .revoked)
    #expect(evidence.isConclusiveRevoked)
    #expect(evidence.revocationTime != nil)
  }

  @Test func staleCRLIsNotConclusiveGood() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let crl = try EvidenceFixtures.crl(
      leaf: signer, revokedLeaf: false, thisUpdate: now.addingTimeInterval(-7_200),
      nextUpdate: now.addingTimeInterval(-3_600))
    let evidence = PDFRevocationValidator.validateCRL(
      crlDER: crl, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .stale)
    #expect(evidence.freshness == .stale)
    #expect(!evidence.isConclusiveGood)
  }

  @Test func badCRLSignatureIsUnknown() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let crl = try EvidenceFixtures.crl(
      leaf: signer, revokedLeaf: false, thisUpdate: freshStart, nextUpdate: freshEnd,
      tamperSignature: true)
    let evidence = PDFRevocationValidator.validateCRL(
      crlDER: crl, certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      trustedAnchors: [signer.material.caCertificate], at: now)
    #expect(evidence.status == .unknown)
    #expect(!evidence.signatureValid)
  }
}

@Suite("Signature revocation network and validation evidence")
struct RevocationIntegrationTests {
  @Test func disabledNetworkNeverCallsClient() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let counter = EvidenceCounter()
    let client = StubNetworkClient(response: Data([1]), counter: counter)
    let evidence = PDFRevocationChecker.fetchAndValidateOCSP(
      certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      endpoint: "https://ocsp.example.com",
      options: PDFRevocationNetworkOptions(policy: .disabled, client: client))
    #expect(evidence.status == .unavailable)
    #expect(counter.count == 0)
    #expect(!evidence.isConclusiveGood)
    #expect(evidence.details.first?.contains("disabled") == true, "\(evidence.details)")
  }

  @Test func networkFailureIsUnavailableNotGood() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let counter = EvidenceCounter()
    let client = StubNetworkClient(
      failure: PDFError(.unsupported, "network down in test"), counter: counter)
    let evidence = PDFRevocationChecker.fetchAndValidateOCSP(
      certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      endpoint: "https://ocsp.example.com",
      options: PDFRevocationNetworkOptions(
        policy: SignatureNetworkPolicy(
          isEnabled: true, allowedEndpoints: ["https://ocsp.example.com"]),
        client: client))
    #expect(counter.count == 1)
    #expect(evidence.status == .unavailable)
    #expect(!evidence.isConclusiveGood)
    #expect(evidence.details.first?.contains("could not be completed") == true)
  }

  @Test func enabledNetworkFetchesAndValidatesOCSP() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let counter = EvidenceCounter()
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good,
      thisUpdate: Date().addingTimeInterval(-60),
      nextUpdate: Date().addingTimeInterval(3_600))
    let client = StubNetworkClient(response: response, counter: counter)
    let evidence = PDFRevocationChecker.fetchAndValidateOCSP(
      certificateDER: signer.leafDER, issuerDER: signer.issuerDER,
      endpoint: "https://ocsp.example.com",
      options: PDFRevocationNetworkOptions(
        policy: SignatureNetworkPolicy(
          isEnabled: true, allowedEndpoints: ["https://ocsp.example.com"]),
        client: client),
      trustedAnchors: [signer.material.caCertificate])
    #expect(counter.count == 1)
    #expect(evidence.status == .good)
    #expect(evidence.isConclusiveGood)
  }

  @Test func validationCarriesExplicitRevocationEvidence() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let signed = try EvidenceFixtures.signedBlankPDF(identity: signer.material.identity)
    let signature = try #require(
      try PDFSignatureInventory.signatures(in: signed.graph).first)
    let good = PDFRevocationEvidence(
      status: .good, source: .ocsp, signatureValid: true, responderTrusted: true,
      freshness: .fresh)
    let withGood = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate], revocationEvidence: good)
    #expect(withGood.revocationChecked)
    #expect(withGood.revocation.status == .good)
    #expect(withGood.revocation.isConclusiveGood)
    #expect(withGood.details.contains { $0.contains("Revocation evidence") })

    let stale = PDFRevocationEvidence(
      status: .stale, source: .ocsp, signatureValid: true, responderTrusted: true,
      freshness: .stale)
    let withStale = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate], revocationEvidence: stale)
    #expect(withStale.revocationChecked)
    #expect(withStale.revocation.status == .stale)
    #expect(!withStale.revocation.isConclusiveGood)

    let unavailable = PDFRevocationEvidence(
      status: .unavailable, source: .ocsp,
      details: ["network failed"])
    let withUnavailable = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate], revocationEvidence: unavailable)
    #expect(withUnavailable.revocationChecked == false)
    #expect(withUnavailable.revocation.status == .unavailable)
    #expect(withUnavailable.details.contains { $0.contains("not valid evidence") })

    let offline = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate])
    #expect(!offline.revocationChecked)
    #expect(offline.revocation.status == .notChecked)
  }

  @Test func expiredAndNotYetValidBoundariesAreExplicit() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let signed = try EvidenceFixtures.signedBlankPDF(identity: signer.material.identity)
    let signature = try #require(
      try PDFSignatureInventory.signatures(in: signed.graph).first)
    let now = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate])
    #expect(now.trust == .trusted)
    let notAfter = try #require(now.signerNotAfter)
    let notBefore = try #require(now.signerNotBefore)

    let expired = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate],
      validationTime: notAfter.addingTimeInterval(3_600))
    #expect(expired.trust == .expired)
    #expect(expired.signerNotAfter == notAfter)
    #expect(expired.details.contains { $0.contains("expired at the validation time") })
    #expect(expired.details.contains { $0.contains("Signer certificate validity") })

    let notYet = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate],
      validationTime: notBefore.addingTimeInterval(-3_600))
    #expect(notYet.trust == .expired)
    #expect(
      notYet.details.contains { $0.contains("not valid yet") }, "\(notYet.details)")
  }

  @Test func untrustedChainStaysUnknownWithOfflineDetails() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let signed = try EvidenceFixtures.signedBlankPDF(identity: signer.material.identity)
    let signature = try #require(
      try PDFSignatureInventory.signatures(in: signed.graph).first)
    let validation = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph, trustedAnchors: [])
    #expect(validation.trust == .unknown)
    #expect(validation.details.contains { $0.contains("not anchored by a trusted root") })
  }
}

@Suite("Revocation independent verification")
struct RevocationIndependentTests {
  @Test func opensslAcceptsOCSPAndCRLFixtures() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let now = Date()
    let response = try EvidenceFixtures.ocspResponse(
      leaf: signer, status: .good, thisUpdate: now.addingTimeInterval(-60),
      nextUpdate: now.addingTimeInterval(3_600))
    if let verified = try EvidenceFixtures.opensslVerifiesOCSP(response, signer: signer) {
      #expect(verified, "OpenSSL rejected the generated OCSP response")
    }
    let crl = try EvidenceFixtures.crl(
      leaf: signer, revokedLeaf: false, thisUpdate: now.addingTimeInterval(-60),
      nextUpdate: now.addingTimeInterval(3_600))
    if let verified = try EvidenceFixtures.opensslVerifiesCRL(crl, signer: signer) {
      #expect(verified, "OpenSSL rejected the generated CRL")
    }
  }
}
