import CryptoKit
import Foundation
import PDFCore
@testable import PDFEditing
import Security
import Testing

@Suite("RFC 3161 timestamps")
struct TimestampTests {
  private func token(
    over value: Data, nonce: Data? = nil, genTime: Date = Date(), signer: EvidenceSigner
  ) throws -> Data {
    try EvidenceFixtures.timestampToken(
      imprint: Data(SHA256.hash(data: value)), nonce: nonce, genTime: genTime, signer: signer)
  }

  @Test func requestRoundTripsCompleteMessage() throws {
    let nonce = TimestampRequest.randomNonce()
    let request = TimestampRequest(
      hash: .sha256, imprint: Data(SHA256.hash(data: Data("signed value".utf8))),
      nonce: nonce, policyOID: "1.3.6.1.4.1.99999.1", certReq: true)
    let der = TimestampRequestBuilder.build(request)
    let parsed = try TimestampRequestBuilder.parse(der)
    #expect(parsed == request)
    #expect(parsed.nonce == nonce)
    #expect(parsed.policyOID == request.policyOID)
    #expect(parsed.certReq)
  }

  @Test func validTokenVerifiesWithOfflineTrust() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    let nonce = TimestampRequest.randomNonce()
    let evidence = TimestampValidator.validate(
      tokenDER: try token(over: value, nonce: nonce, signer: tsa),
      over: value, expectedNonce: nonce,
      trustedAnchors: [tsa.material.caCertificate])
    #expect(evidence.status == .verified)
    #expect(evidence.trust == .trusted)
    #expect(evidence.signatureValid)
    #expect(evidence.imprintMatches)
    #expect(evidence.nonceMatches)
    #expect(evidence.timeIsSane)
    #expect(evidence.genTime != nil)
    #expect(evidence.policyOID == EvidenceFixtures.policyOID)
    #expect(evidence.isEmbeddable)
    #expect(evidence.isFullyVerified)
  }

  @Test func untrustedChainIsNotAcceptedAsVerified() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    let evidence = TimestampValidator.validate(
      tokenDER: try token(over: value, signer: tsa), over: value)
    #expect(evidence.status == .verifiedUntrusted)
    #expect(evidence.trust == .unknown)
    #expect(evidence.signatureValid)
    #expect(evidence.imprintMatches)
    #expect(evidence.isEmbeddable)
    #expect(!evidence.isFullyVerified)
  }

  @Test func wrongImprintIsInvalid() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    let token = try EvidenceFixtures.timestampToken(
      imprint: Data(SHA256.hash(data: Data("different value".utf8))), nonce: nil,
      genTime: Date(), signer: tsa)
    let evidence = TimestampValidator.validate(
      tokenDER: token, over: value, trustedAnchors: [tsa.material.caCertificate])
    #expect(evidence.status == .invalid)
    #expect(!evidence.imprintMatches)
    #expect(!evidence.isEmbeddable)
  }

  @Test func tamperedSignatureIsInvalid() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    var tokenBytes = [UInt8](try token(over: value, signer: tsa))
    tokenBytes[tokenBytes.count - 1] ^= 0xFF
    let evidence = TimestampValidator.validate(
      tokenDER: Data(tokenBytes), over: value,
      trustedAnchors: [tsa.material.caCertificate])
    #expect(evidence.status == .invalid)
    #expect(!evidence.signatureValid)
  }

  @Test func wrongNonceIsInvalid() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    let token = try token(over: value, nonce: Data([0x01, 0x02]), signer: tsa)
    let evidence = TimestampValidator.validate(
      tokenDER: token, over: value, expectedNonce: Data([0x03, 0x04]),
      trustedAnchors: [tsa.material.caCertificate])
    #expect(evidence.status == .invalid)
    #expect(!evidence.nonceMatches)
  }

  @Test func futureTimestampIsInvalid() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    let future = Date().addingTimeInterval(3_600)
    let evidence = TimestampValidator.validate(
      tokenDER: try token(over: value, genTime: future, signer: tsa),
      over: value, trustedAnchors: [tsa.material.caCertificate])
    #expect(evidence.status == .invalid)
    #expect(!evidence.timeIsSane)
  }

  @Test func expiredTsaAtGenerationTimeIsVerifiedUntrusted() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("signed document bytes".utf8)
    // The test certificate is valid for two days; generate a token three days
    // ahead and validate at that time so the TSA chain is expired there.
    let future = Date().addingTimeInterval(3 * 86_400)
    let evidence = TimestampValidator.validate(
      tokenDER: try token(over: value, genTime: future, signer: tsa),
      over: value, trustedAnchors: [tsa.material.caCertificate],
      validationTime: future.addingTimeInterval(1))
    #expect(evidence.status == .verifiedUntrusted)
    #expect(evidence.trust == .expired)
    #expect(evidence.signatureValid)
    #expect(evidence.imprintMatches)
  }

  @Test func rejectedResponseIsInvalidWithoutToken() throws {
    let response = EvidenceFixtures.timestampResponse(token: Data(), granted: false)
    let request = TimestampRequest(imprint: Data(repeating: 1, count: 32))
    let validation = TimestampValidator.validateResponse(response, request: request)
    #expect(validation.evidence.status == .invalid)
    #expect(validation.tokenDER == nil)
    #expect(validation.evidence.details.first?.contains("refused") == true)
  }

  @Test func validResponseReturnsEmbeddableToken() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("response timestamp value".utf8)
    let nonce = TimestampRequest.randomNonce()
    let request = TimestampRequest(
      imprint: Data(SHA256.hash(data: value)), nonce: nonce)
    let token = try EvidenceFixtures.timestampToken(
      imprint: request.imprint, nonce: nonce, genTime: Date(), signer: tsa)
    let response = EvidenceFixtures.timestampResponse(token: token)
    let validation = TimestampValidator.validateResponse(
      response, request: request, trustedAnchors: [tsa.material.caCertificate])
    #expect(validation.evidence.status == .verified)
    #expect(validation.tokenDER == token)
  }

  @Test func signerEmbedsVerifiableTimestampEvidence() throws {
    guard let signer = try EvidenceSigner.make(commonName: "sPDF Timestamp Signer"),
      let tsa = try EvidenceSigner.make(commonName: "sPDF Test TSA")
    else { return }
    defer {
      signer.cleanUp()
      tsa.cleanUp()
    }
    let parsed = try PDFParser.parse(BlankPDF.data(format: .letter))
    let options = PDFSigningOptions(
      fieldName: "TimestampSignature", pageIndex: 0, rect: [72, 72, 272, 112],
      signingTime: Date())
    let authority = MockTimestampAuthority { requestDER in
      let request = try TimestampRequestBuilder.parse(requestDER)
      let token = try EvidenceFixtures.timestampToken(
        imprint: request.imprint, nonce: request.nonce, genTime: Date(), signer: tsa)
      return EvidenceFixtures.timestampResponse(token: token)
    }
    let outcome = try PDFSigningWriter.sign(
      parsed.graph, identity: signer.material.identity, options: options,
      timestamp: PDFTimestampSigningOptions(
        authority: authority, requirement: .required,
        trustedAnchors: [tsa.material.caCertificate]))
    #expect(outcome.timestamp.status == .verified)
    #expect(outcome.timestamp.isFullyVerified)

    let finalGraph = try PDFParser.parse(outcome.data).graph
    let signature = try #require(
      try PDFSignatureInventory.signatures(in: finalGraph).first)
    let validation = PDFSignatureValidator.validate(
      signature, source: outcome.data, finalGraph: finalGraph,
      trustedAnchors: [signer.material.caCertificate],
      timestampTrustedAnchors: [tsa.material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.timestamp.status == .verified)
    #expect(validation.timestamp.genTime != nil)
    #expect(validation.timestamp.imprintMatches)
    #expect(validation.timestamp.signatureValid)
    #expect(validation.revocationChecked == false)
    #expect(validation.revocation.status == .notChecked)
  }

  @Test func requiredTimestampFailureRefusesToSign() throws {
    guard let signer = try EvidenceSigner.make(commonName: "sPDF Timestamp Signer") else {
      return
    }
    defer { signer.cleanUp() }
    let parsed = try PDFParser.parse(BlankPDF.data(format: .letter))
    let options = PDFSigningOptions(
      fieldName: "TimestampSignature", pageIndex: 0, rect: [72, 72, 272, 112])
    let authority = MockTimestampAuthority { _ in
      throw PDFError(.unsupported, "TSA offline in test")
    }
    #expect(throws: PDFError.self) {
      _ = try PDFSigningWriter.sign(
        parsed.graph, identity: signer.material.identity, options: options,
        timestamp: PDFTimestampSigningOptions(authority: authority, requirement: .required))
    }
  }

  @Test func optionalTimestampFailureSignsWithUnavailableEvidence() throws {
    guard let signer = try EvidenceSigner.make(commonName: "sPDF Timestamp Signer") else {
      return
    }
    defer { signer.cleanUp() }
    let parsed = try PDFParser.parse(BlankPDF.data(format: .letter))
    let options = PDFSigningOptions(
      fieldName: "TimestampSignature", pageIndex: 0, rect: [72, 72, 272, 112])
    let authority = MockTimestampAuthority { _ in
      throw PDFError(.unsupported, "TSA offline in test")
    }
    let outcome = try PDFSigningWriter.sign(
      parsed.graph, identity: signer.material.identity, options: options,
      timestamp: PDFTimestampSigningOptions(authority: authority, requirement: .optional))
    #expect(outcome.timestamp.status == .unavailable)
    #expect(!outcome.timestamp.isEmbeddable)
    let finalGraph = try PDFParser.parse(outcome.data).graph
    let signature = try #require(
      try PDFSignatureInventory.signatures(in: finalGraph).first)
    let validation = PDFSignatureValidator.validate(
      signature, source: outcome.data, finalGraph: finalGraph,
      trustedAnchors: [signer.material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.timestamp.status == .absent)
  }

  @Test func signatureWithoutTimestampReportsAbsent() throws {
    guard let signer = try EvidenceSigner.make() else { return }
    defer { signer.cleanUp() }
    let signed = try EvidenceFixtures.signedBlankPDF(identity: signer.material.identity)
    let signature = try #require(
      try PDFSignatureInventory.signatures(in: signed.graph).first)
    let validation = PDFSignatureValidator.validate(
      signature, source: signed.data, finalGraph: signed.graph,
      trustedAnchors: [signer.material.caCertificate])
    #expect(validation.timestamp.status == .absent)
    #expect(!validation.timestamp.signatureValid)
  }
}

@Suite("RFC 3161 independent verification")
struct TimestampIndependentTests {
  @Test func opensslAcceptsEmbeddedTimestampToken() throws {
    guard let tsa = try EvidenceSigner.make(commonName: "sPDF Independent TSA") else { return }
    defer { tsa.cleanUp() }
    let value = Data("independent timestamp payload".utf8)
    let token = try EvidenceFixtures.timestampToken(
      imprint: Data(SHA256.hash(data: value)), nonce: nil, genTime: Date(), signer: tsa)
    guard let verified = try EvidenceFixtures.opensslVerifiesTimestampToken(
      token, caPEM: tsa.material.caPEM)
    else { return }
    #expect(verified, "OpenSSL rejected the generated RFC 3161 token")
  }
}

@Suite("RFC 3161 incremental signing")
struct TimestampIncrementalTests {
  @Test func incrementalSignerEmbedsVerifiableTimestamp() throws {
    guard let signer = try EvidenceSigner.make(commonName: "sPDF Incremental Signer"),
      let tsa = try EvidenceSigner.make(commonName: "sPDF Incremental TSA")
    else { return }
    defer {
      signer.cleanUp()
      tsa.cleanUp()
    }
    let source = try PDFParser.parse(BlankPDF.data(format: .letter))
    let options = PDFSigningOptions(
      fieldName: "IncrementalTimestamp", pageIndex: 0, rect: [72, 72, 272, 112])
    let authority = MockTimestampAuthority { requestDER in
      let request = try TimestampRequestBuilder.parse(requestDER)
      let token = try EvidenceFixtures.timestampToken(
        imprint: request.imprint, nonce: request.nonce, genTime: Date(), signer: tsa)
      return EvidenceFixtures.timestampResponse(token: token)
    }
    let outcome = try PDFSigningWriter.signIncremental(
      source, identity: signer.material.identity, options: options,
      timestamp: PDFTimestampSigningOptions(
        authority: authority, requirement: .required,
        trustedAnchors: [tsa.material.caCertificate]))
    #expect(outcome.timestamp.status == .verified)
    #expect(outcome.data.starts(with: source.source))
    let finalGraph = try PDFParser.parse(outcome.data).graph
    let signature = try PDFSignatureInventory.signatures(in: finalGraph).first
    let present = try #require(signature)
    let validation = PDFSignatureValidator.validate(
      present, source: outcome.data, finalGraph: finalGraph,
      trustedAnchors: [signer.material.caCertificate],
      timestampTrustedAnchors: [tsa.material.caCertificate])
    #expect(validation.crypto == .valid)
    #expect(validation.timestamp.status == .verified)
  }
}
