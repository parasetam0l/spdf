import CryptoKit
import Foundation
import PDFCore
import Security

/// SIG-02: RFC 3161 timestamp creation, parsing and verification.
///
/// The profile deliberately keeps evidence quality separate from document
/// validity: a timestamp is only reported as accepted (status verified) when
/// the CMS signature over TSTInfo verifies, its message imprint matches the
/// value being timestamped, its declared time is sane, and its signer chain is
/// trusted under the supplied offline anchors. Cryptographic success without a
/// trusted TSA chain is verifiedUntrusted; malformed or mismatched evidence is
/// invalid; a failed fetch is unavailable. None of those states are collapsed
/// into valid.

public enum TimestampHash: String, Sendable, Equatable {
  case sha256
  case sha384
  case sha512

  public var oid: String {
    switch self {
    case .sha256: return "2.16.840.1.101.3.4.2.1"
    case .sha384: return "2.16.840.1.101.3.4.2.2"
    case .sha512: return "2.16.840.1.101.3.4.2.3"
    }
  }

  public var name: String { rawValue }

  public init?(oid: String) {
    switch oid {
    case "2.16.840.1.101.3.4.2.1": self = .sha256
    case "2.16.840.1.101.3.4.2.2": self = .sha384
    case "2.16.840.1.101.3.4.2.3": self = .sha512
    default: return nil
    }
  }

  public func digest(_ data: Data) -> Data {
    switch self {
    case .sha256: return Data(SHA256.hash(data: data))
    case .sha384: return Data(SHA384.hash(data: data))
    case .sha512: return Data(SHA512.hash(data: data))
    }
  }
}

/// One RFC 3161 TimeStampReq. The nonce is kept in its DER INTEGER contents
/// form so a response can be matched byte-for-byte.
public struct TimestampRequest: Sendable, Equatable {
  public let hash: TimestampHash
  public let imprint: Data
  public let nonce: Data?
  public let policyOID: String?
  public let certReq: Bool

  public init(
    hash: TimestampHash = .sha256, imprint: Data, nonce: Data? = nil,
    policyOID: String? = nil, certReq: Bool = true
  ) {
    self.hash = hash
    self.imprint = imprint
    self.nonce = nonce
    self.policyOID = policyOID
    self.certReq = certReq
  }

  /// A nonce suitable for a signing request: 8 random bytes as a positive DER
  /// INTEGER (leading zero when needed).
  public static func randomNonce() -> Data {
    var bytes = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
    bytes[bytes.startIndex] &= 0x7F
    if bytes.first == 0 { bytes[bytes.startIndex] = 1 }
    return bytes
  }
}

public enum TimestampRequestBuilder {
  static let timestampRequestOID = "1.2.840.113549.1.9.16.1.4"

  /// TimeStampReq ::= SEQUENCE { version, messageImprint, reqPolicy OPTIONAL,
  /// nonce OPTIONAL, certReq BOOLEAN DEFAULT FALSE, extensions OPTIONAL }.
  public static func build(_ request: TimestampRequest) -> Data {
    var body = Data()
    body.append(DER.integer(1))
    body.append(DER.sequence([
      DER.sequence([DER.oid(request.hash.oid), DER.null()]),
      DER.octetString(request.imprint),
    ]))
    if let policyOID = request.policyOID { body.append(DER.oid(policyOID)) }
    if let nonce = request.nonce { body.append(DER.integerBytes(nonce)) }
    if request.certReq { body.append(DER.boolean(true)) }
    return DER.element(tag: 0x30, body)
  }

  public static func parse(_ data: Data, limits: PDFLimits = PDFLimits()) throws
    -> TimestampRequest
  {
    let bytes = [UInt8](data)
    var reader = DERReader(bytes: bytes)
    let sequence = try reader.readElement(limits: limits)
    try DERReader.expect(sequence, tag: 0x30, "Timestamp request is not a SEQUENCE")
    var body = DERReader(
      bytes: bytes, offset: sequence.content.startIndex, end: sequence.content.endIndex)
    let version = try body.readElement(limits: limits)
    try DERReader.expect(version, tag: 0x02, "Timestamp request version is missing")
    guard DERReader.integer(version.content) == 1 else {
      throw PDFError(.unsupported, "Unsupported timestamp request version")
    }
    let imprint = try body.readElement(limits: limits)
    try DERReader.expect(imprint, tag: 0x30, "Timestamp message imprint is missing")
    var imprintReader = DERReader(
      bytes: bytes, offset: imprint.content.startIndex, end: imprint.content.endIndex)
    let algorithm = try imprintReader.readElement(limits: limits)
    try DERReader.expect(algorithm, tag: 0x30, "Timestamp imprint algorithm is missing")
    var algorithmReader = DERReader(
      bytes: bytes, offset: algorithm.content.startIndex, end: algorithm.content.endIndex)
    let algorithmOID = try algorithmReader.readElement(limits: limits)
    try DERReader.expect(algorithmOID, tag: 0x06, "Timestamp imprint algorithm OID is missing")
    guard let hash = TimestampHash(oid: DERReader.oid(algorithmOID.content)) else {
      throw PDFError(.unsupported, "Unsupported timestamp imprint algorithm")
    }
    let hashedMessage = try imprintReader.readElement(limits: limits)
    try DERReader.expect(hashedMessage, tag: 0x04, "Timestamp imprint value is missing")
    let digest = Data(bytes[hashedMessage.content.startIndex..<hashedMessage.content.endIndex])
    var nonce: Data?
    var policyOID: String?
    var certReq = false
    while !body.isAtEnd {
      let element = try body.readElement(limits: limits)
      switch element.tag {
      case 0x02:
        nonce = Data(bytes[element.content.startIndex..<element.content.endIndex])
      case 0x06:
        policyOID = DERReader.oid(element.content)
      case 0x01:
        certReq = element.content.first.map { $0 != 0 } ?? false
      default:
        continue
      }
    }
    return TimestampRequest(
      hash: hash, imprint: digest, nonce: nonce, policyOID: policyOID, certReq: certReq)
  }
}

/// SIG-02 creation seam: the owner supplies an explicitly configured authority;
/// the core never reaches the network by itself.
public protocol TimestampAuthority: Sendable {
  func timestampResponse(for requestDER: Data) throws -> Data
}

public enum TimestampRequirement: String, Sendable, Equatable {
  /// Sign even when the timestamp service is unavailable or its evidence does
  /// not verify; the returned evidence says exactly what happened.
  case optional
  /// Refuse to produce a signature unless a verifiable timestamp token could
  /// be embedded (chain trust may still be unknown offline and is reported).
  case required
}

public struct PDFTimestampSigningOptions: @unchecked Sendable {
  public let authority: any TimestampAuthority
  public let requirement: TimestampRequirement
  public let trustedAnchors: [SecCertificate]
  public let clockSkew: TimeInterval

  public init(
    authority: any TimestampAuthority, requirement: TimestampRequirement = .optional,
    trustedAnchors: [SecCertificate] = [], clockSkew: TimeInterval = 300
  ) {
    self.authority = authority
    self.requirement = requirement
    self.trustedAnchors = trustedAnchors
    self.clockSkew = clockSkew
  }
}

/// SIG-02 verification evidence for one embedded/RFC 3161 timestamp token.
public struct PDFTimestampEvidence: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    /// No timestamp token is present (the signature did not request one).
    case absent
    /// Crypto, imprint, nonce and time verify and the TSA chain is trusted.
    case verified
    /// Crypto/imprint verify but the TSA chain could not be trusted offline.
    case verifiedUntrusted
    /// A token is present but its evidence does not verify.
    case invalid
    /// A timestamp was requested but no response could be obtained.
    case unavailable
  }

  public enum Trust: String, Sendable, Equatable {
    case trusted
    case untrusted
    case expired
    case unknown
    case missingAnchor
  }

  public let status: Status
  public let trust: Trust?
  public let genTime: Date?
  public let policyOID: String?
  public let serialNumber: String?
  public let hashAlgorithm: String?
  public let imprintMatches: Bool
  public let signatureValid: Bool
  public let nonceMatches: Bool
  public let timeIsSane: Bool
  public let signerName: String?
  public let signerNotAfter: Date?
  public let timeStampingEKU: Bool?
  public let details: [String]

  public init(
    status: Status, trust: Trust? = nil, genTime: Date? = nil, policyOID: String? = nil,
    serialNumber: String? = nil, hashAlgorithm: String? = nil, imprintMatches: Bool = false,
    signatureValid: Bool = false, nonceMatches: Bool = true, timeIsSane: Bool = false,
    signerName: String? = nil, signerNotAfter: Date? = nil, timeStampingEKU: Bool? = nil,
    details: [String] = []
  ) {
    self.status = status
    self.trust = trust
    self.genTime = genTime
    self.policyOID = policyOID
    self.serialNumber = serialNumber
    self.hashAlgorithm = hashAlgorithm
    self.imprintMatches = imprintMatches
    self.signatureValid = signatureValid
    self.nonceMatches = nonceMatches
    self.timeIsSane = timeIsSane
    self.signerName = signerName
    self.signerNotAfter = signerNotAfter
    self.timeStampingEKU = timeStampingEKU
    self.details = details
  }

  public static let absent = PDFTimestampEvidence(status: .absent)

  /// True when the token is structurally and cryptographically usable for
  /// embedding; chain trust is reported separately (verifiedUntrusted).
  public var isEmbeddable: Bool {
    status == .verified || status == .verifiedUntrusted
  }

  public var isFullyVerified: Bool { status == .verified }
}

/// A response plus the raw token that the signing writer can embed.
public struct TimestampValidation: Sendable, Equatable {
  public let evidence: PDFTimestampEvidence
  public let tokenDER: Data?

  public init(evidence: PDFTimestampEvidence, tokenDER: Data?) {
    self.evidence = evidence
    self.tokenDER = tokenDER
  }
}

enum TimestampConstants {
  static let signedDataOID = "1.2.840.113549.1.7.2"
  static let tstInfoOID = "1.2.840.113549.1.9.16.1.4"
  static let timestampTokenAttributeOID = "1.2.840.113549.1.9.16.2.14"
}

/// Parsed TSTInfo (RFC 3161 section 2.4.2).
struct TSTInfo: Sendable, Equatable {
  let version: Int
  let policyOID: String
  let hash: TimestampHash
  let imprint: Data
  let serialNumber: String
  let genTime: Date?
  let nonce: Data?
  let tsaNameDER: Data?

  static func parse(_ data: Data, limits: PDFLimits = PDFLimits()) throws -> TSTInfo {
    let bytes = [UInt8](data)
    var reader = DERReader(bytes: bytes)
    let sequence = try reader.readElement(limits: limits)
    try DERReader.expect(sequence, tag: 0x30, "TSTInfo is not a SEQUENCE")
    var body = DERReader(
      bytes: bytes, offset: sequence.content.startIndex, end: sequence.content.endIndex)
    let version = try body.readElement(limits: limits)
    try DERReader.expect(version, tag: 0x02, "TSTInfo version is missing")
    guard DERReader.integer(version.content) == 1 else {
      throw PDFError(.unsupported, "Unsupported TSTInfo version")
    }
    let policy = try body.readElement(limits: limits)
    try DERReader.expect(policy, tag: 0x06, "TSTInfo policy is missing")
    let imprint = try body.readElement(limits: limits)
    try DERReader.expect(imprint, tag: 0x30, "TSTInfo message imprint is missing")
    var imprintReader = DERReader(
      bytes: bytes, offset: imprint.content.startIndex, end: imprint.content.endIndex)
    let algorithm = try imprintReader.readElement(limits: limits)
    try DERReader.expect(algorithm, tag: 0x30, "TSTInfo imprint algorithm is missing")
    var algorithmReader = DERReader(
      bytes: bytes, offset: algorithm.content.startIndex, end: algorithm.content.endIndex)
    let algorithmOID = try algorithmReader.readElement(limits: limits)
    try DERReader.expect(algorithmOID, tag: 0x06, "TSTInfo imprint algorithm OID is missing")
    guard let hash = TimestampHash(oid: DERReader.oid(algorithmOID.content)) else {
      throw PDFError(.unsupported, "Unsupported timestamp imprint algorithm")
    }
    let hashedMessage = try imprintReader.readElement(limits: limits)
    try DERReader.expect(hashedMessage, tag: 0x04, "TSTInfo imprint value is missing")
    let imprintValue = Data(
      bytes[hashedMessage.content.startIndex..<hashedMessage.content.endIndex])
    let serial = try body.readElement(limits: limits)
    try DERReader.expect(serial, tag: 0x02, "TSTInfo serial number is missing")
    let serialText = Data(bytes[serial.content.startIndex..<serial.content.endIndex])
      .map { String(format: "%02X", $0) }.joined()
    let genTimeElement = try body.readElement(limits: limits)
    let genTime = DERReader.time(genTimeElement.tag, genTimeElement.content)
    var nonce: Data?
    while !body.isAtEnd {
      let element = try body.readElement(limits: limits)
      if element.tag == 0x02 {
        nonce = Data(bytes[element.content.startIndex..<element.content.endIndex])
      }
    }
    return TSTInfo(
      version: 1, policyOID: DERReader.oid(policy.content), hash: hash,
      imprint: imprintValue, serialNumber: serialText, genTime: genTime, nonce: nonce,
      tsaNameDER: nil)
  }
}

public enum TimestampValidator {
  /// Verify an RFC 3161 response against the request that produced it and
  /// return the token to embed plus its evidence.
  public static func validateResponse(
    _ response: Data, request: TimestampRequest, trustedAnchors: [SecCertificate] = [],
    validationTime: Date = Date(), clockSkew: TimeInterval = 300,
    limits: PDFLimits = PDFLimits()
  ) -> TimestampValidation {
    let token: Data
    do {
      let bytes = [UInt8](response)
      var reader = DERReader(bytes: bytes)
      let sequence = try reader.readElement(limits: limits)
      try DERReader.expect(sequence, tag: 0x30, "TimeStampResp is not a SEQUENCE")
      var body = DERReader(
        bytes: bytes, offset: sequence.content.startIndex, end: sequence.content.endIndex)
      let statusInfo = try body.readElement(limits: limits)
      try DERReader.expect(statusInfo, tag: 0x30, "TimeStampResp status is missing")
      var statusReader = DERReader(
        bytes: bytes, offset: statusInfo.content.startIndex, end: statusInfo.content.endIndex)
      let statusElement = try statusReader.readElement(limits: limits)
      try DERReader.expect(statusElement, tag: 0x02, "TimeStampResp status value is missing")
      guard let status = DERReader.integer(statusElement.content) else {
        throw PDFError(.malformed, "TimeStampResp status is malformed")
      }
      guard status == 0 || status == 1 else {
        return TimestampValidation(
          evidence: PDFTimestampEvidence(
            status: .invalid,
            details: ["The timestamp authority refused the request (status \(status))"]),
          tokenDER: nil)
      }
      guard !body.isAtEnd else {
        return TimestampValidation(
          evidence: PDFTimestampEvidence(
            status: .invalid, details: ["The timestamp response has no token"]),
          tokenDER: nil)
      }
      let tokenElement = try body.readElement(limits: limits)
      token = Data(bytes[tokenElement.start..<tokenElement.content.endIndex])
    } catch {
      return TimestampValidation(
        evidence: PDFTimestampEvidence(
          status: .invalid,
          details: ["The timestamp response could not be parsed: \(error.localizedDescription)"]),
        tokenDER: nil)
    }
    let evidence = verify(
      tokenDER: token, expectedImprint: request.imprint, signedValue: nil,
      expectedNonce: request.nonce, expectedHash: request.hash,
      trustedAnchors: trustedAnchors, validationTime: validationTime, clockSkew: clockSkew,
      limits: limits)
    return TimestampValidation(
      evidence: evidence, tokenDER: evidence.isEmbeddable ? token : nil)
  }

  /// Verify an embedded timestamp token's CMS signature, imprint, nonce, time
  /// and offline trust. `signedValue` is the value the token timestamps (for a
  /// signature timestamp: the SignerInfo signature octets).
  public static func validate(
    tokenDER: Data, over signedValue: Data, expectedNonce: Data? = nil,
    expectedHash: TimestampHash? = nil, trustedAnchors: [SecCertificate] = [],
    validationTime: Date = Date(), clockSkew: TimeInterval = 300,
    limits: PDFLimits = PDFLimits()
  ) -> PDFTimestampEvidence {
    verify(
      tokenDER: tokenDER, expectedImprint: nil, signedValue: signedValue,
      expectedNonce: expectedNonce, expectedHash: expectedHash,
      trustedAnchors: trustedAnchors, validationTime: validationTime, clockSkew: clockSkew,
      limits: limits)
  }

  static func verify(
    tokenDER: Data, expectedImprint: Data?, signedValue: Data?, expectedNonce: Data?,
    expectedHash: TimestampHash?, trustedAnchors: [SecCertificate], validationTime: Date,
    clockSkew: TimeInterval, limits: PDFLimits
  ) -> PDFTimestampEvidence {
    var details: [String] = []
    do {
      let cms = try CMSSignedData.parse(tokenDER, limits: limits)
      guard !cms.detached, let eContent = cms.eContent else {
        throw PDFError(.malformed, "The timestamp token has no encapsulated TSTInfo")
      }
      let tstInfo = try TSTInfo.parse(eContent, limits: limits)
      guard let signer = cms.signers.first else {
        throw PDFError(.malformed, "The timestamp token has no signer")
      }
      guard expectedHash == nil || expectedHash == tstInfo.hash else {
        throw PDFError(.unsupported, "The timestamp imprint algorithm is not the requested one")
      }
      let imprintMatches: Bool
      if let expectedImprint {
        imprintMatches = tstInfo.imprint == expectedImprint
      } else if let signedValue {
        imprintMatches = tstInfo.hash.digest(signedValue) == tstInfo.imprint
      } else {
        imprintMatches = false
      }
      let nonceMatches = expectedNonce == nil || expectedNonce == tstInfo.nonce
      var signatureValid = false
      var timeStampingEKU: Bool?
      var signerName: String?
      var signerNotAfter: Date?
      var trust: PDFTimestampEvidence.Trust?
      if let digest = PDFSignatureValidator.digestAlgorithm(for: signer.digestOID),
        let keyAlgorithm = PDFSignatureValidator.keyAlgorithm(
          for: signer.signatureOID, digest: digest)
      {
        let verificationData = signer.signedAttributesDER.map { Data($0) } ?? eContent
        if let messageDigest = signer.messageDigest {
          let expectedDigest: Data
          switch digest {
          case .sha256: expectedDigest = Data(SHA256.hash(data: eContent))
          case .sha384: expectedDigest = Data(SHA384.hash(data: eContent))
          case .sha512: expectedDigest = Data(SHA512.hash(data: eContent))
          }
          if messageDigest != expectedDigest {
            details.append("The timestamp token message digest does not match its TSTInfo")
          }
        }
        var candidates: [SecCertificate] = []
        for certificateDER in cms.certificates {
          guard let certificate = X509CertificateFields.certificate(fromDER: Data(certificateDER)),
            let identity = PDFSignatureSignerIdentity.certificateDetails(certificate)
          else { continue }
          if let issuerDER = signer.issuerDER, let serialDER = signer.serialDER {
            guard identity.issuerDER == issuerDER, identity.serialDER == serialDER else {
              continue
            }
          } else if let keyIdentifier = signer.subjectKeyIdentifier {
            guard identity.subjectKeyIdentifier == keyIdentifier else { continue }
          } else {
            continue
          }
          candidates.append(certificate)
        }
        var matchedCertificate: SecCertificate?
        for candidate in candidates {
          guard let key = SecCertificateCopyKey(candidate) else { continue }
          var error: Unmanaged<CFError>?
          if SecKeyVerifySignature(
            key, keyAlgorithm.algorithm, verificationData as CFData,
            signer.signature as CFData, &error)
          {
            signatureValid = true
            matchedCertificate = candidate
            signerName = (SecCertificateCopySubjectSummary(candidate) as String?)
            if let fields = try? X509CertificateFields.parse(
              X509CertificateFields.certificateDER(candidate), limits: limits)
            {
              signerNotAfter = fields.notAfter
              timeStampingEKU = fields.hasTimeStampingEKU
            }
            break
          }
        }
        if !signatureValid {
          details.append("The timestamp token signer does not verify the CMS signature")
        }
        if let matchedCertificate {
          trust = evaluateTimestampTrust(
            signer: matchedCertificate, embedded: cms.certificates, anchors: trustedAnchors,
            at: tstInfo.genTime, details: &details)
        } else {
          details.append("The timestamp signer certificate is missing from the token")
        }
      } else {
        details.append("The timestamp token uses an unsupported signature/digest algorithm")
      }

      let timeIsSane: Bool
      if let genTime = tstInfo.genTime {
        timeIsSane = genTime <= validationTime.addingTimeInterval(clockSkew)
        if !timeIsSane {
          details.append("The timestamp time is later than the validation time")
        }
      } else {
        timeIsSane = false
        details.append("The timestamp token has no readable generation time")
      }
      if trust == .expired {
        details.append("The timestamp signer certificate was not valid at the timestamp time")
      }
      if timeStampingEKU == false {
        details.append(
          "The timestamp signer certificate has no timeStamping extended key usage; "
            + "offline evaluation records this but does not use it as a substitute for trust")
      }
      let structural = signatureValid && imprintMatches && nonceMatches && timeIsSane
      let status: PDFTimestampEvidence.Status
      if !structural {
        status = .invalid
      } else if trust == .trusted {
        status = .verified
      } else {
        status = .verifiedUntrusted
      }
      return PDFTimestampEvidence(
        status: status, trust: trust, genTime: tstInfo.genTime, policyOID: tstInfo.policyOID,
        serialNumber: tstInfo.serialNumber, hashAlgorithm: tstInfo.hash.name,
        imprintMatches: imprintMatches, signatureValid: signatureValid,
        nonceMatches: nonceMatches, timeIsSane: timeIsSane, signerName: signerName,
        signerNotAfter: signerNotAfter, timeStampingEKU: timeStampingEKU, details: details)
    } catch {
      return PDFTimestampEvidence(
        status: .invalid,
        details: ["The timestamp token could not be verified: \(error.localizedDescription)"])
    }
  }

  static func evaluateTimestampTrust(
    signer: SecCertificate, embedded: [[UInt8]], anchors: [SecCertificate],
    at date: Date?, details: inout [String]
  ) -> PDFTimestampEvidence.Trust {
    let signerDER = X509CertificateFields.certificateDER(signer)
    var chain: [SecCertificate] = [signer]
    for der in embedded {
      guard Data(der) != signerDER,
        let certificate = X509CertificateFields.certificate(fromDER: Data(der))
      else { continue }
      chain.append(certificate)
    }
    let policy = SecPolicyCreateBasicX509()
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess,
      let trust
    else {
      details.append("The timestamp certificate chain could not be constructed")
      return .untrusted
    }
    SecTrustSetNetworkFetchAllowed(trust, false)
    if !anchors.isEmpty {
      SecTrustSetAnchorCertificates(trust, anchors as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
    }
    if let date {
      SecTrustSetVerifyDate(trust, date as CFDate)
    }
    var error: CFError?
    if SecTrustEvaluateWithError(trust, &error) {
      details.append("The timestamp signer chain is trusted at the timestamp time")
      return .trusted
    }
    let code = error.map { CFErrorGetCode($0) } ?? -1
    if code == errSecCertificateExpired {
      return .expired
    }
    if anchors.isEmpty {
      details.append("The timestamp chain is not anchored by an offline trusted root")
      return .unknown
    }
    details.append("The timestamp chain is not anchored by the supplied trusted roots")
    return .missingAnchor
  }
}
