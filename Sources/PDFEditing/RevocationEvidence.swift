import CryptoKit
import Foundation
import PDFCore
import Security

/// SIG-03: offline-first revocation evidence. OCSP and CRL responses are
/// parsed and their signatures/freshness checked locally; a network failure or
/// a non-successful OCSP response is never reported as a good status, and
/// "not checked" is a distinct state from "checked and good".

public struct PDFRevocationEvidence: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    /// A fresh, signature-valid response says the certificate is not revoked.
    case good
    /// The response says the certificate is revoked.
    case revoked
    /// A response was obtained but its freshness window does not cover now.
    case stale
    /// A response was obtained but could not be trusted or did not identify
    /// the requested certificate (including signature failures).
    case unknown
    /// The check could not be completed (network failure, TSA/responder
    /// refusal). Never treated as good.
    case unavailable
    /// No revocation check was requested; the offline default.
    case notChecked
  }

  public enum Source: String, Sendable, Equatable {
    case ocsp
    case crl
  }

  public enum Freshness: String, Sendable, Equatable {
    case fresh
    case stale
    case future
    case missing
  }

  public let status: Status
  public let source: Source?
  public let thisUpdate: Date?
  public let nextUpdate: Date?
  public let producedAt: Date?
  public let revocationTime: Date?
  public let responderName: String?
  public let serialNumber: String?
  /// The responder/CRL signature verified against a certificate in the
  /// response (or the supplied issuer), independent of chain trust.
  public let signatureValid: Bool
  /// nil when no offline anchors were supplied, so trust could not be decided.
  public let responderTrusted: Bool?
  public let freshness: Freshness?
  public let details: [String]

  public init(
    status: Status, source: Source? = nil, thisUpdate: Date? = nil, nextUpdate: Date? = nil,
    producedAt: Date? = nil, revocationTime: Date? = nil, responderName: String? = nil,
    serialNumber: String? = nil, signatureValid: Bool = false, responderTrusted: Bool? = nil,
    freshness: Freshness? = nil, details: [String] = []
  ) {
    self.status = status
    self.source = source
    self.thisUpdate = thisUpdate
    self.nextUpdate = nextUpdate
    self.producedAt = producedAt
    self.revocationTime = revocationTime
    self.responderName = responderName
    self.serialNumber = serialNumber
    self.signatureValid = signatureValid
    self.responderTrusted = responderTrusted
    self.freshness = freshness
    self.details = details
  }

  public static let notChecked = PDFRevocationEvidence(
    status: .notChecked,
    details: ["Offline evaluation: certificate revocation was not checked"])

  /// True only for a fresh, signature-valid, explicitly-trusted good response.
  /// Stale/unknown/unavailable/notChecked are never conclusive.
  public var isConclusiveGood: Bool {
    status == .good && signatureValid && responderTrusted == true && freshness == .fresh
  }

  public var isConclusiveRevoked: Bool {
    status == .revoked && signatureValid
  }
}

public struct PDFRevocationPolicy: Sendable, Equatable {
  public var clockSkew: TimeInterval
  public var requireFreshness: Bool

  public init(clockSkew: TimeInterval = 300, requireFreshness: Bool = true) {
    self.clockSkew = clockSkew
    self.requireFreshness = requireFreshness
  }

  public static let offline = PDFRevocationPolicy()
}

enum OCSPConstants {
  static let basicResponseOID = "1.3.6.1.5.5.7.48.1.1"
  static let ocspRequestOID = "1.3.6.1.5.5.7.48.1"
  static let sha1OID = "1.3.14.3.2.26"
  static let sha256OID = "2.16.840.1.101.3.4.2.1"
  static let rsaEncryptionOID = "1.2.840.113549.1.1.1"
  static let sha1WithRSAOID = "1.2.840.113549.1.1.5"
  static let sha256WithRSAOID = "1.2.840.113549.1.1.11"
  static let ecdsaWithSHA1OID = "1.2.840.10045.4.1"
  static let ecdsaWithSHA256OID = "1.2.840.10045.4.3.2"
}

struct OCSPParseResult {
  enum CertificateStatus: Sendable, Equatable {
    case good
    case revoked(Date?)
    case unknown
  }

  struct SingleResponse: Sendable, Equatable {
    let hashOID: String
    let issuerNameHash: Data
    let issuerKeyHash: Data
    let serialDER: Data
    let status: CertificateStatus
    let thisUpdate: Date?
    let nextUpdate: Date?
  }

  let tbsDER: Data
  let signatureAlgorithmOID: String
  let signature: Data
  let certificates: [[UInt8]]
  let responderNameContent: Data?
  let responderKeyHash: Data?
  let producedAt: Date?
  let responses: [SingleResponse]
}

/// Bounded OCSP response parser (RFC 6960 basic response only).
enum OCSPParser {
  static func parse(_ data: Data, limits: PDFLimits = PDFLimits()) throws -> OCSPParseResult {
    let bytes = [UInt8](data)
    var reader = DERReader(bytes: bytes)
    let response = try reader.readElement(limits: limits)
    try DERReader.expect(response, tag: 0x30, "OCSP response is not a SEQUENCE")
    var responseReader = DERReader(
      bytes: bytes, offset: response.content.startIndex, end: response.content.endIndex)
    let statusElement = try responseReader.readElement(limits: limits)
    guard statusElement.tag == 0x0A || statusElement.tag == 0x02,
      let status = DERReader.integer(statusElement.content)
    else {
      throw PDFError(.malformed, "OCSP response status is malformed")
    }
    guard status == 0 else {
      throw OCSPUnavailable(
        detail: "OCSP responder returned non-success response status \(status)")
    }
    guard !responseReader.isAtEnd else {
      throw OCSPUnavailable(detail: "OCSP response has no responseBytes")
    }
    let responseBytesWrapper = try responseReader.readElement(limits: limits)
    guard responseBytesWrapper.tag == 0xA0 else {
      throw PDFError(.malformed, "OCSP responseBytes wrapper is malformed")
    }
    var wrapperReader = DERReader(
      bytes: bytes, offset: responseBytesWrapper.content.startIndex,
      end: responseBytesWrapper.content.endIndex)
    let responseBytes = try wrapperReader.readElement(limits: limits)
    try DERReader.expect(responseBytes, tag: 0x30, "OCSP responseBytes is malformed")
    var responseBytesReader = DERReader(
      bytes: bytes, offset: responseBytes.content.startIndex, end: responseBytes.content.endIndex)
    let responseType = try responseBytesReader.readElement(limits: limits)
    try DERReader.expect(responseType, tag: 0x06, "OCSP response type is missing")
    guard DERReader.oid(responseType.content) == OCSPConstants.basicResponseOID else {
      throw PDFError(.unsupported, "Only the OCSP basic response profile is supported")
    }
    let basicOctets = try responseBytesReader.readElement(limits: limits)
    try DERReader.expect(basicOctets, tag: 0x04, "OCSP basic response is missing")
    let basicBytes = [UInt8](basicOctets.content)
    var basicReader = DERReader(bytes: basicBytes)
    let basic = try basicReader.readElement(limits: limits)
    try DERReader.expect(basic, tag: 0x30, "OCSP basic response is malformed")
    var basicBody = DERReader(
      bytes: basicBytes, offset: basic.content.startIndex, end: basic.content.endIndex)
    let tbs = try basicBody.readElement(limits: limits)
    try DERReader.expect(tbs, tag: 0x30, "OCSP tbsResponseData is malformed")
    let tbsDER = Data(basicBytes[tbs.start..<tbs.content.endIndex])

    let signatureAlgorithm = try basicBody.readElement(limits: limits)
    try DERReader.expect(signatureAlgorithm, tag: 0x30, "OCSP signature algorithm is malformed")
    var algorithmReader = DERReader(
      bytes: basicBytes, offset: signatureAlgorithm.content.startIndex,
      end: signatureAlgorithm.content.endIndex)
    let algorithmOID = try algorithmReader.readElement(limits: limits)
    try DERReader.expect(algorithmOID, tag: 0x06, "OCSP signature algorithm OID is missing")
    let signatureBits = try basicBody.readElement(limits: limits)
    try DERReader.expect(signatureBits, tag: 0x03, "OCSP signature is missing")
    let signature = Data(signatureBits.content.dropFirst())
    var certificates: [[UInt8]] = []
    if !basicBody.isAtEnd {
      let certsWrapper = try basicBody.readElement(limits: limits)
      if certsWrapper.tag == 0xA0 {
        var certsReader = DERReader(
          bytes: basicBytes, offset: certsWrapper.content.startIndex,
          end: certsWrapper.content.endIndex)
        let list = try certsReader.readElement(limits: limits)
        if list.tag == 0x30 {
          var listReader = DERReader(
            bytes: basicBytes, offset: list.content.startIndex, end: list.content.endIndex)
          var count = 0
          while !listReader.isAtEnd, count < 16 {
            let certificate = try listReader.readElement(limits: limits)
            if certificate.tag == 0x30 {
              certificates.append(
                Array(basicBytes[certificate.start..<certificate.content.endIndex]))
            }
            count += 1
          }
        }
      }
    }

    var tbsReader = DERReader(
      bytes: basicBytes, offset: tbs.content.startIndex, end: tbs.content.endIndex)
    var responderNameContent: Data?
    var responderKeyHash: Data?
    var producedAt: Date?
    var responses: [OCSPParseResult.SingleResponse] = []
    let first = try tbsReader.readElement(limits: limits)
    if first.tag == 0xA0 {  // version [0] EXPLICIT
      // consume the explicit version element; the next element is responderID
    }
    let responderID = first.tag == 0xA0
      ? try tbsReader.readElement(limits: limits) : first
    switch responderID.tag {
    case 0xA1:
      responderNameContent = Data(
        basicBytes[responderID.content.startIndex..<responderID.content.endIndex])
    case 0x82:
      responderKeyHash = Data(
        basicBytes[responderID.content.startIndex..<responderID.content.endIndex])
    default:
      throw PDFError(.malformed, "OCSP responder identifier is malformed")
    }
    let produced = try tbsReader.readElement(limits: limits)
    producedAt = DERReader.time(produced.tag, produced.content)
    let responseList = try tbsReader.readElement(limits: limits)
    try DERReader.expect(responseList, tag: 0x30, "OCSP response list is malformed")
    var listReader = DERReader(
      bytes: basicBytes, offset: responseList.content.startIndex,
      end: responseList.content.endIndex)
    var count = 0
    while !listReader.isAtEnd, count < 16 {
      let single = try listReader.readElement(limits: limits)
      count += 1
      try DERReader.expect(single, tag: 0x30, "OCSP single response is malformed")
      var singleReader = DERReader(
        bytes: basicBytes, offset: single.content.startIndex, end: single.content.endIndex)
      let certID = try singleReader.readElement(limits: limits)
      try DERReader.expect(certID, tag: 0x30, "OCSP CertID is malformed")
      var certIDReader = DERReader(
        bytes: basicBytes, offset: certID.content.startIndex, end: certID.content.endIndex)
      let hashAlgorithm = try certIDReader.readElement(limits: limits)
      try DERReader.expect(hashAlgorithm, tag: 0x30, "OCSP CertID hash algorithm is malformed")
      var hashReader = DERReader(
        bytes: basicBytes, offset: hashAlgorithm.content.startIndex,
        end: hashAlgorithm.content.endIndex)
      let hashOIDElement = try hashReader.readElement(limits: limits)
      try DERReader.expect(hashOIDElement, tag: 0x06, "OCSP CertID hash OID is missing")
      let nameHashElement = try certIDReader.readElement(limits: limits)
      try DERReader.expect(nameHashElement, tag: 0x04, "OCSP issuer name hash is missing")
      let keyHashElement = try certIDReader.readElement(limits: limits)
      try DERReader.expect(keyHashElement, tag: 0x04, "OCSP issuer key hash is missing")
      let serialElement = try certIDReader.readElement(limits: limits)
      try DERReader.expect(serialElement, tag: 0x02, "OCSP serial number is missing")
      let certStatus = try singleReader.readElement(limits: limits)
      let certificateStatus: OCSPParseResult.CertificateStatus
      switch certStatus.tag {
      case 0x80:
        certificateStatus = .good
      case 0xA1:
        // revoked [1] IMPLICIT RevokedInfo: the context tag replaces the
        // RevokedInfo SEQUENCE tag, so its content starts with revocationTime.
        var infoReader = DERReader(
          bytes: basicBytes, offset: certStatus.content.startIndex,
          end: certStatus.content.endIndex)
        let time = try infoReader.readElement(limits: limits)
        certificateStatus = .revoked(DERReader.time(time.tag, time.content))
      case 0x82:
        certificateStatus = .unknown
      default:
        throw PDFError(.malformed, "OCSP certificate status is malformed")
      }
      let thisUpdateElement = try singleReader.readElement(limits: limits)
      let thisUpdate = DERReader.time(thisUpdateElement.tag, thisUpdateElement.content)
      var nextUpdate: Date?
      if !singleReader.isAtEnd {
        let next = try singleReader.readElement(limits: limits)
        if next.tag == 0xA0, !next.content.isEmpty {
          var nextReader = DERReader(
            bytes: basicBytes, offset: next.content.startIndex, end: next.content.endIndex)
          let time = try nextReader.readElement(limits: limits)
          nextUpdate = DERReader.time(time.tag, time.content)
        }
      }
      responses.append(
        OCSPParseResult.SingleResponse(
          hashOID: DERReader.oid(hashOIDElement.content),
          issuerNameHash: Data(
            basicBytes[nameHashElement.content.startIndex..<nameHashElement.content.endIndex]),
          issuerKeyHash: Data(
            basicBytes[keyHashElement.content.startIndex..<keyHashElement.content.endIndex]),
          serialDER: Data(
            basicBytes[serialElement.start..<serialElement.content.endIndex]),
          status: certificateStatus, thisUpdate: thisUpdate, nextUpdate: nextUpdate))
    }
    return OCSPParseResult(
      tbsDER: tbsDER, signatureAlgorithmOID: DERReader.oid(algorithmOID.content),
      signature: signature, certificates: certificates,
      responderNameContent: responderNameContent, responderKeyHash: responderKeyHash,
      producedAt: producedAt, responses: responses)
  }
}

struct OCSPUnavailable: Error {
  let detail: String
}

enum RevocationCrypto {
  static func secKeyAlgorithm(for oid: String) -> SecKeyAlgorithm? {
    switch oid {
    case OCSPConstants.sha1WithRSAOID, OCSPConstants.rsaEncryptionOID:
      return .rsaSignatureMessagePKCS1v15SHA1
    case OCSPConstants.sha256WithRSAOID:
      return .rsaSignatureMessagePKCS1v15SHA256
    case "1.2.840.113549.1.1.12":
      return .rsaSignatureMessagePKCS1v15SHA384
    case "1.2.840.113549.1.1.13":
      return .rsaSignatureMessagePKCS1v15SHA512
    case OCSPConstants.ecdsaWithSHA1OID:
      return .ecdsaSignatureMessageX962SHA1
    case OCSPConstants.ecdsaWithSHA256OID:
      return .ecdsaSignatureMessageX962SHA256
    case "1.2.840.10045.4.3.3":
      return .ecdsaSignatureMessageX962SHA384
    case "1.2.840.10045.4.3.4":
      return .ecdsaSignatureMessageX962SHA512
    default:
      return nil
    }
  }

  static func verify(
    tbsDER: Data, signature: Data, algorithmOID: String, certificate: SecCertificate
  ) -> Bool {
    guard let algorithm = secKeyAlgorithm(for: algorithmOID),
      let key = SecCertificateCopyKey(certificate)
    else { return false }
    var error: Unmanaged<CFError>?
    return SecKeyVerifySignature(
      key, algorithm, tbsDER as CFData, signature as CFData, &error)
  }

  /// nil means "no anchors supplied, trust undecidable offline".
  static func trust(
    certificate: SecCertificate, intermediates: [[UInt8]], anchors: [SecCertificate],
    at date: Date?
  ) -> Bool? {
    guard !anchors.isEmpty else { return nil }
    let certificateDER = X509CertificateFields.certificateDER(certificate)
    var chain: [SecCertificate] = [certificate]
    for der in intermediates where Data(der) != certificateDER {
      if let intermediate = X509CertificateFields.certificate(fromDER: Data(der)) {
        chain.append(intermediate)
      }
    }
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(
      chain as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
      let trust
    else { return false }
    SecTrustSetNetworkFetchAllowed(trust, false)
    SecTrustSetAnchorCertificates(trust, anchors as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
    return SecTrustEvaluateWithError(trust, nil)
  }

  static func hash(for oid: String) -> ((Data) -> Data)? {
    switch oid {
    case OCSPConstants.sha1OID: return { Data(Insecure.SHA1.hash(data: $0)) }
    case OCSPConstants.sha256OID: return { Data(SHA256.hash(data: $0)) }
    default: return nil
    }
  }

  static func freshness(
    now: Date, thisUpdate: Date?, nextUpdate: Date?, producedAt: Date?,
    policy: PDFRevocationPolicy
  ) -> (PDFRevocationEvidence.Freshness, [String]) {
    var details: [String] = []
    guard let thisUpdate else {
      details.append("The response has no readable thisUpdate time")
      return (.missing, details)
    }
    if thisUpdate > now.addingTimeInterval(policy.clockSkew) {
      details.append("The response thisUpdate is in the future")
      return (.future, details)
    }
    if let nextUpdate {
      if nextUpdate < now.addingTimeInterval(-policy.clockSkew) {
        details.append("The response nextUpdate has passed")
        return (.stale, details)
      }
    } else if policy.requireFreshness {
      details.append("The response has no nextUpdate; freshness cannot be established")
      return (.missing, details)
    }
    if let producedAt, producedAt > now.addingTimeInterval(policy.clockSkew) {
      details.append("The response producedAt is in the future")
      return (.future, details)
    }
    details.append("The response freshness window covers the validation time")
    return (.fresh, details)
  }

  static func rawContent(of derElement: Data, limits: PDFLimits = PDFLimits()) -> Data? {
    let bytes = [UInt8](derElement)
    var reader = DERReader(bytes: bytes)
    guard let element = try? reader.readElement(limits: limits) else { return nil }
    return Data(bytes[element.content.startIndex..<element.content.endIndex])
  }

  static func certificateSummary(_ certificate: SecCertificate?) -> String? {
    certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
  }
}

/// Minimal OCSP request builder (RFC 6960): one CertID, SHA-1 or SHA-256.
public enum OCSPRequestBuilder {
  public static func build(
    certificateDER: Data, issuerDER: Data, hash: TimestampHash = .sha256,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    let certificate = try X509CertificateFields.parse(certificateDER, limits: limits)
    let issuer = try X509CertificateFields.parse(issuerDER, limits: limits)
    let hashOID: String
    let digest: (Data) -> Data
    switch hash {
    case .sha256:
      hashOID = OCSPConstants.sha256OID
      digest = { Data(SHA256.hash(data: $0)) }
    case .sha384, .sha512:
      throw PDFError(.unsupported, "OCSP requests support SHA-1/SHA-256 CertID hashes here")
    }
    let nameHash = digest(issuer.subjectDER)
    let keyHash = digest(issuer.subjectPublicKeyBits)
    let certID = DER.sequence([
      DER.sequence([DER.oid(hashOID), DER.null()]),
      DER.octetString(nameHash),
      DER.octetString(keyHash),
      DER.integerBytes(RevocationCrypto.rawContent(of: certificate.serialDER) ?? Data()),
    ])
    let request = DER.sequence([certID])
    let tbsRequest = DER.sequence([DER.sequence([request])])
    return DER.sequence([tbsRequest])
  }
}

public enum PDFRevocationValidator {
  /// Parse and verify an OCSP basic response for one certificate. Network is
  /// not touched; the caller supplies the bytes and offline anchors.
  public static func validateOCSP(
    responseDER: Data, certificateDER: Data, issuerDER: Data? = nil,
    trustedAnchors: [SecCertificate] = [], at validationTime: Date = Date(),
    policy: PDFRevocationPolicy = .offline, limits: PDFLimits = PDFLimits()
  ) -> PDFRevocationEvidence {
    var details: [String] = []
    let leaf: X509CertificateFields
    do {
      leaf = try X509CertificateFields.parse(certificateDER, limits: limits)
    } catch {
      return PDFRevocationEvidence(
        status: .unknown, source: .ocsp,
        details: ["The leaf certificate could not be parsed for OCSP matching"])
    }
    let response: OCSPParseResult
    do {
      response = try OCSPParser.parse(responseDER, limits: limits)
    } catch let unavailable as OCSPUnavailable {
      return PDFRevocationEvidence(
        status: .unavailable, source: .ocsp, details: [unavailable.detail])
    } catch {
      return PDFRevocationEvidence(
        status: .unknown, source: .ocsp,
        details: ["The OCSP response could not be parsed: \(error.localizedDescription)"])
    }

    let issuerFields: X509CertificateFields?
    if let issuerDER {
      issuerFields = try? X509CertificateFields.parse(issuerDER, limits: limits)
    } else {
      issuerFields = nil
    }
    var match: OCSPParseResult.SingleResponse?
    var hashOIDUnsupported = false
    for single in response.responses {
      guard let digest = RevocationCrypto.hash(for: single.hashOID) else {
        hashOIDUnsupported = true
        continue
      }
      let expectedNameHash = issuerFields.map { digest($0.subjectDER) } ?? digest(leaf.issuerDER)
      guard single.issuerNameHash == expectedNameHash else { continue }
      if let issuerFields, single.issuerKeyHash != digest(issuerFields.subjectPublicKeyBits) {
        details.append("The OCSP CertID issuer key hash does not match the supplied issuer")
        continue
      }
      guard single.serialDER == leaf.serialDER else { continue }
      match = single
      if issuerFields == nil {
        details.append(
          "The OCSP issuer key hash could not be checked without the issuer certificate")
      }
      break
    }
    if hashOIDUnsupported {
      details.append("The OCSP response uses an unsupported CertID hash algorithm")
    }
    guard let match else {
      return PDFRevocationEvidence(
        status: .unknown, source: .ocsp,
        details: details + ["The OCSP response does not identify this certificate"])
    }

    // Locate and verify the responder certificate.
    var responder: SecCertificate?
    var responderName: String?
    if let issuerDER {
      responderName = RevocationCrypto.certificateSummary(
        X509CertificateFields.certificate(fromDER: issuerDER))
    }
    if let issuerDER, let issuerCertificate = X509CertificateFields.certificate(fromDER: issuerDER),
      RevocationCrypto.verify(
        tbsDER: response.tbsDER, signature: response.signature,
        algorithmOID: response.signatureAlgorithmOID, certificate: issuerCertificate)
    {
      responder = issuerCertificate
      responderName = RevocationCrypto.certificateSummary(issuerCertificate)
    }
    if responder == nil {
      for der in response.certificates {
        let derData = Data(der)
        guard let certificate = X509CertificateFields.certificate(fromDER: derData) else {
          continue
        }
        var matchesIdentifier = true
        if let fields = try? X509CertificateFields.parse(derData, limits: limits) {
          if let nameContent = response.responderNameContent {
            // Accept the standard explicit Name (0x30 wrapper) and a bare Name
            // content produced by lenient responders.
            matchesIdentifier =
              nameContent == fields.subjectDER
              || nameContent == RevocationCrypto.rawContent(of: fields.subjectDER)
          } else if let keyHash = response.responderKeyHash {
            matchesIdentifier = Data(Insecure.SHA1.hash(data: fields.subjectPublicKeyBits)) == keyHash
          }
        }
        guard matchesIdentifier,
          RevocationCrypto.verify(
            tbsDER: response.tbsDER, signature: response.signature,
            algorithmOID: response.signatureAlgorithmOID, certificate: certificate)
        else { continue }
        responder = certificate
        responderName = RevocationCrypto.certificateSummary(certificate)
        break
      }
    }
    let signatureValid = responder != nil
    if !signatureValid {
      details.append("The OCSP response signature does not verify against a known responder")
    }
    let responderTrusted = responder.flatMap {
      RevocationCrypto.trust(
        certificate: $0, intermediates: response.certificates, anchors: trustedAnchors,
        at: response.producedAt ?? validationTime)
    }
    if responderTrusted == false {
      details.append("The OCSP responder chain is not anchored by the supplied trusted roots")
    }
    let (freshness, freshnessDetails) = RevocationCrypto.freshness(
      now: validationTime, thisUpdate: match.thisUpdate, nextUpdate: match.nextUpdate,
      producedAt: response.producedAt, policy: policy)
    details.append(contentsOf: freshnessDetails)

    let status: PDFRevocationEvidence.Status
    var revocationTime: Date?
    if !signatureValid || responderTrusted == false {
      status = .unknown
    } else {
      switch match.status {
      case .good:
        status = freshness == .fresh ? .good : .stale
      case .revoked(let time):
        status = .revoked
        revocationTime = time
      case .unknown:
        status = .unknown
      }
    }
    return PDFRevocationEvidence(
      status: status, source: .ocsp, thisUpdate: match.thisUpdate,
      nextUpdate: match.nextUpdate, producedAt: response.producedAt,
      revocationTime: revocationTime, responderName: responderName,
      serialNumber: leaf.serialDER.map { String(format: "%02X", $0) }.joined(),
      signatureValid: signatureValid, responderTrusted: responderTrusted,
      freshness: freshness, details: details)
  }
}

struct CRLParseResult {
  struct Entry: Sendable, Equatable {
    let serialDER: Data
    let revocationTime: Date?
  }

  let tbsDER: Data
  let signatureAlgorithmOID: String
  let signature: Data
  let issuerDER: Data
  let thisUpdate: Date?
  let nextUpdate: Date?
  let entries: [Entry]
}

/// Bounded X.509 CRL parser (CertificateList / TBSCertList).
enum CRLParser {
  static func parse(_ data: Data, limits: PDFLimits = PDFLimits()) throws -> CRLParseResult {
    let bytes = [UInt8](data)
    var reader = DERReader(bytes: bytes)
    let list = try reader.readElement(limits: limits)
    try DERReader.expect(list, tag: 0x30, "CRL is not a SEQUENCE")
    var body = DERReader(
      bytes: bytes, offset: list.content.startIndex, end: list.content.endIndex)
    let tbs = try body.readElement(limits: limits)
    try DERReader.expect(tbs, tag: 0x30, "CRL TBSCertList is malformed")
    let tbsDER = Data(bytes[tbs.start..<tbs.content.endIndex])
    let signatureAlgorithm = try body.readElement(limits: limits)
    try DERReader.expect(signatureAlgorithm, tag: 0x30, "CRL signature algorithm is malformed")
    var algorithmReader = DERReader(
      bytes: bytes, offset: signatureAlgorithm.content.startIndex,
      end: signatureAlgorithm.content.endIndex)
    let algorithmOID = try algorithmReader.readElement(limits: limits)
    try DERReader.expect(algorithmOID, tag: 0x06, "CRL signature algorithm OID is missing")
    let signatureBits = try body.readElement(limits: limits)
    try DERReader.expect(signatureBits, tag: 0x03, "CRL signature is missing")
    let signature = Data(signatureBits.content.dropFirst())

    var tbsReader = DERReader(
      bytes: bytes, offset: tbs.content.startIndex, end: tbs.content.endIndex)
    var first = try tbsReader.readElement(limits: limits)
    if first.tag == 0x02 {  // optional version
      first = try tbsReader.readElement(limits: limits)
    }
    try DERReader.expect(first, tag: 0x30, "CRL signature algorithm in TBSCertList is malformed")
    let issuer = try tbsReader.readElement(limits: limits)
    try DERReader.expect(issuer, tag: 0x30, "CRL issuer is malformed")
    let issuerDER = Data(bytes[issuer.start..<issuer.content.endIndex])
    let thisUpdateElement = try tbsReader.readElement(limits: limits)
    let thisUpdate = DERReader.time(thisUpdateElement.tag, thisUpdateElement.content)
    var nextUpdate: Date?
    var entries: [CRLParseResult.Entry] = []
    while !tbsReader.isAtEnd {
      let element = try tbsReader.readElement(limits: limits)
      switch element.tag {
      case 0x17, 0x18:
        nextUpdate = DERReader.time(element.tag, element.content)
      case 0x30:
        var entriesReader = DERReader(
          bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
        var count = 0
        while !entriesReader.isAtEnd, count < 10_000 {
          let entry = try entriesReader.readElement(limits: limits)
          count += 1
          try DERReader.expect(entry, tag: 0x30, "CRL entry is malformed")
          var entryReader = DERReader(
            bytes: bytes, offset: entry.content.startIndex, end: entry.content.endIndex)
          let serial = try entryReader.readElement(limits: limits)
          try DERReader.expect(serial, tag: 0x02, "CRL entry serial is missing")
          let date = try entryReader.readElement(limits: limits)
          entries.append(
            CRLParseResult.Entry(
              serialDER: Data(bytes[serial.start..<serial.content.endIndex]),
              revocationTime: DERReader.time(date.tag, date.content)))
        }
      default:
        continue
      }
    }
    return CRLParseResult(
      tbsDER: tbsDER, signatureAlgorithmOID: DERReader.oid(algorithmOID.content),
      signature: signature, issuerDER: issuerDER, thisUpdate: thisUpdate,
      nextUpdate: nextUpdate, entries: entries)
  }
}

extension PDFRevocationValidator {
  /// Parse and verify a DER CRL for one certificate. The issuer certificate is
  /// required to check the CRL signature and trust; no network is touched.
  public static func validateCRL(
    crlDER: Data, certificateDER: Data, issuerDER: Data,
    trustedAnchors: [SecCertificate] = [], at validationTime: Date = Date(),
    policy: PDFRevocationPolicy = .offline, limits: PDFLimits = PDFLimits()
  ) -> PDFRevocationEvidence {
    var details: [String] = []
    let leaf: X509CertificateFields
    do {
      leaf = try X509CertificateFields.parse(certificateDER, limits: limits)
    } catch {
      return PDFRevocationEvidence(
        status: .unknown, source: .crl,
        details: ["The leaf certificate could not be parsed for CRL matching"])
    }
    guard let issuerCertificate = X509CertificateFields.certificate(fromDER: issuerDER),
      let issuerFields = try? X509CertificateFields.parse(issuerDER, limits: limits)
    else {
      return PDFRevocationEvidence(
        status: .unknown, source: .crl,
        details: ["The CRL issuer certificate is required to verify the CRL"])
    }
    let crl: CRLParseResult
    do {
      crl = try CRLParser.parse(crlDER, limits: limits)
    } catch {
      return PDFRevocationEvidence(
        status: .unknown, source: .crl,
        details: ["The CRL could not be parsed: \(error.localizedDescription)"])
    }
    guard crl.issuerDER == issuerFields.subjectDER else {
      return PDFRevocationEvidence(
        status: .unknown, source: .crl,
        details: ["The CRL issuer does not match the supplied issuer certificate"])
    }
    let signatureValid = RevocationCrypto.verify(
      tbsDER: crl.tbsDER, signature: crl.signature,
      algorithmOID: crl.signatureAlgorithmOID, certificate: issuerCertificate)
    if !signatureValid {
      details.append("The CRL signature does not verify against the issuer certificate")
    }
    // Trust is evaluated at the validation clock, not at the CRL thisUpdate:
    // backdated thisUpdate values must not make an expired issuer look valid.
    let issuerTrusted = RevocationCrypto.trust(
      certificate: issuerCertificate, intermediates: [], anchors: trustedAnchors,
      at: validationTime)
    if issuerTrusted == false {
      details.append("The CRL issuer chain is not anchored by the supplied trusted roots")
    }
    let (freshness, freshnessDetails) = RevocationCrypto.freshness(
      now: validationTime, thisUpdate: crl.thisUpdate, nextUpdate: crl.nextUpdate,
      producedAt: nil, policy: policy)
    details.append(contentsOf: freshnessDetails)

    let leafSerial = RevocationCrypto.rawContent(of: leaf.serialDER) ?? leaf.serialDER
    let entry = crl.entries.first {
      (RevocationCrypto.rawContent(of: $0.serialDER) ?? $0.serialDER) == leafSerial
    }
    let status: PDFRevocationEvidence.Status
    var revocationTime: Date?
    if !signatureValid || issuerTrusted == false {
      status = .unknown
    } else if let entry {
      status = .revoked
      revocationTime = entry.revocationTime
    } else if freshness == .fresh {
      status = .good
    } else {
      status = .stale
    }
    return PDFRevocationEvidence(
      status: status, source: .crl, thisUpdate: crl.thisUpdate, nextUpdate: crl.nextUpdate,
      revocationTime: revocationTime,
      responderName: RevocationCrypto.certificateSummary(issuerCertificate),
      serialNumber: leaf.serialDER.map { String(format: "%02X", $0) }.joined(),
      signatureValid: signatureValid, responderTrusted: issuerTrusted,
      freshness: freshness, details: details)
  }
}

/// Explicit networking preferences for revocation checks: disabled by default,
/// and every fetch returns an evidence value (network failure is unavailable,
/// never good).
public struct PDFRevocationNetworkOptions: @unchecked Sendable {
  public let policy: SignatureNetworkPolicy
  public let client: any SignatureNetworkClient

  public init(policy: SignatureNetworkPolicy, client: any SignatureNetworkClient) {
    self.policy = policy
    self.client = client
  }
}

public enum PDFRevocationChecker {
  public static func fetchAndValidateOCSP(
    certificateDER: Data, issuerDER: Data, endpoint: String,
    options: PDFRevocationNetworkOptions, trustedAnchors: [SecCertificate] = [],
    at validationTime: Date = Date(), policy: PDFRevocationPolicy = .offline,
    limits: PDFLimits = PDFLimits()
  ) -> PDFRevocationEvidence {
    do {
      let request = try OCSPRequestBuilder.build(
        certificateDER: certificateDER, issuerDER: issuerDER, limits: limits)
      let response = try SignatureNetworkService.fetchOCSP(
        requestDER: request, endpoint: endpoint, policy: options.policy,
        client: options.client)
      return PDFRevocationValidator.validateOCSP(
        responseDER: response, certificateDER: certificateDER, issuerDER: issuerDER,
        trustedAnchors: trustedAnchors, at: validationTime, policy: policy, limits: limits)
    } catch {
      return PDFRevocationEvidence(
        status: .unavailable, source: .ocsp,
        details: ["The OCSP check could not be completed: \(error.localizedDescription)"])
    }
  }

  public static func fetchAndValidateCRL(
    certificateDER: Data, issuerDER: Data, endpoint: String,
    options: PDFRevocationNetworkOptions, trustedAnchors: [SecCertificate] = [],
    at validationTime: Date = Date(), policy: PDFRevocationPolicy = .offline,
    limits: PDFLimits = PDFLimits()
  ) -> PDFRevocationEvidence {
    do {
      let crl = try SignatureNetworkService.fetchCRL(
        endpoint: endpoint, policy: options.policy, client: options.client)
      return PDFRevocationValidator.validateCRL(
        crlDER: crl, certificateDER: certificateDER, issuerDER: issuerDER,
        trustedAnchors: trustedAnchors, at: validationTime, policy: policy, limits: limits)
    } catch {
      return PDFRevocationEvidence(
        status: .unavailable, source: .crl,
        details: ["The CRL check could not be completed: \(error.localizedDescription)"])
    }
  }
}
