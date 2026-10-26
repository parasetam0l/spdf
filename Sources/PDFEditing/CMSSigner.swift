import CryptoKit
import Foundation
import PDFCore
import Security

/// P30-016/P30-025: signing identities come from the system keychain through
/// Security framework APIs; private keys never leave those APIs and are never
/// copied into our models.
public enum PDFSigningIdentity {
  public struct Available: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    public let commonName: String
  }

  /// Identities available in the search list, for an explicit picker.
  public static func availableIdentities() -> [Available] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnRef as String: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let identities = result as? [SecIdentity]
    else { return [] }
    return identities.compactMap { identity in
      var certificate: SecCertificate?
      guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
        let certificate
      else { return nil }
      let name = (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unnamed identity"
      return Available(identity: identity, certificate: certificate, commonName: name)
    }
  }

  public static func certificate(of identity: SecIdentity) -> SecCertificate? {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess else { return nil }
    return certificate
  }
}

/// P30-019: builds a detached CMS SignedData signature (RSA PKCS#1 v1.5 or
/// ECDSA X9.62 over SHA-256) with signed attributes and the embedded signer
/// chain. The signature is produced by `SecKeyCreateSignature`; the private
/// key never leaves the Security framework.
enum CMSSigner {
  static let signedDataOID = "1.2.840.113549.1.7.2"
  static let dataOID = "1.2.840.113549.1.7.1"
  static let sha256OID = "2.16.840.1.101.3.4.2.1"
  static let contentTypeAttributeOID = "1.2.840.113549.1.9.3"
  static let messageDigestAttributeOID = "1.2.840.113549.1.9.4"
  static let signingTimeAttributeOID = "1.2.840.113549.1.9.5"
  static let rsaEncryptionOID = "1.2.840.113549.1.1.1"
  static let ecdsaWithSHA256OID = "1.2.840.10045.4.3.2"

  /// SIG-02: signature material prepared before an optional RFC 3161 token is
  /// requested. The signature covers the signed attributes, so a token can be
  /// requested over the signature octets and embedded without re-signing.
  struct PreparedDetachedSignature {
    let identifierIssuerDER: Data
    let identifierSerialDER: Data
    let signedAttributeContent: Data
    let signature: Data
    let signatureOID: String
    let digestOID: String
    let signatureAlgorithm: Data
    let certificates: [SecCertificate]

    func cms(timestampToken: Data?) -> Data {
      var signerParts: [Data] = [
        DER.integer(1),
        DER.sequence([identifierIssuerDER, identifierSerialDER]),
        DER.sequence([DER.oid(digestOID), DER.null()]),
        DER.element(tag: 0xA0, signedAttributeContent),
        signatureAlgorithm,
        DER.octetString(signature),
      ]
      if let timestampToken {
        // RFC 3161 signature timestamp attribute (id-aa-timeStampToken) as an
        // unsigned attribute on the SignerInfo. Its value is the complete
        // timestamp-token ContentInfo; unsigned attributes do not change the
        // signed-attribute signature.
        let attribute = DER.sequence([
          DER.oid(TimestampConstants.timestampTokenAttributeOID),
          DER.set([timestampToken]),
        ])
        signerParts.append(DER.element(tag: 0xA1, attribute))
      }
      let signerInfo = DER.sequence(signerParts)
      let certificateSet = DER.element(
        tag: 0xA0,
        DER.concatenated(
          certificates.map { Data(SecCertificateCopyData($0) as Data) }
            .sorted { $0.lexicographicallyPrecedes($1) }))
      let signedData = DER.sequence([
        DER.integer(1),
        DER.set([DER.sequence([DER.oid(digestOID), DER.null()])]),
        DER.sequence([DER.oid(dataOID)]),
        certificateSet,
        DER.set([signerInfo]),
      ])
      return DER.sequence([DER.oid(signedDataOID), DER.element(tag: 0xA0, signedData)])
    }
  }

  /// - Parameter signerIdentifierCertificate: test-only seam: name a
  ///   different certificate in the SignerInfo identifier while signing with
  ///   the identity's key, to prove validation rejects mismatched identities.
  static func detachedSignature(
    signedBytes: Data, identity: SecIdentity, signingTime: Date,
    signerIdentifierCertificate: SecCertificate? = nil, timestampToken: Data? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    let prepared = try prepareDetachedSignature(
      signedBytes: signedBytes, identity: identity, signingTime: signingTime,
      signerIdentifierCertificate: signerIdentifierCertificate, limits: limits)
    return prepared.cms(timestampToken: timestampToken)
  }

  static func prepareDetachedSignature(
    signedBytes: Data, identity: SecIdentity, signingTime: Date,
    signerIdentifierCertificate: SecCertificate? = nil, limits: PDFLimits = PDFLimits()
  ) throws -> PreparedDetachedSignature {
    guard let certificate = PDFSigningIdentity.certificate(of: identity) else {
      throw PDFError(.unsupported, "The signing identity has no certificate")
    }
    var privateKey: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess, let privateKey else {
      throw PDFError(.unsupported, "The signing identity has no private key")
    }
    guard let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
      let keyType = attributes[kSecAttrKeyType] as? String
    else {
      throw PDFError(.unsupported, "The signing key type could not be determined")
    }
    let isRSA = keyType == (kSecAttrKeyTypeRSA as String)
    let isEC = keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)
    guard isRSA || isEC else {
      throw PDFError(.unsupported, "Only RSA and EC signing keys are supported")
    }

    // Signed attributes: contentType, messageDigest, signingTime. A SET OF
    // must carry its elements in DER (byte-lexicographic) order; strict CMS
    // parsers such as NSS used by independent readers reject unsorted sets
    // even when lenient ones accept the signature.
    let digest = Data(SHA256.hash(data: signedBytes))
    let signedAttributeElements: [Data] = [
      // AttributeValue for contentType is the ContentType OID itself; wrapping
      // it in a SEQUENCE is accepted by OpenSSL but rejected as malformed by
      // strict independent CMS parsers (NSS, as used by poppler/pdfsig).
      DER.sequence([
        DER.oid(contentTypeAttributeOID), DER.set([DER.oid(dataOID)]),
      ]),
      DER.sequence([
        DER.oid(messageDigestAttributeOID), DER.set([DER.octetString(digest)]),
      ]),
      DER.sequence([
        DER.oid(signingTimeAttributeOID), DER.set([DER.utcTime(signingTime)]),
      ]),
    ].sorted { $0.lexicographicallyPrecedes($1) }
    let attributeContent = DER.concatenated(signedAttributeElements)
    let signedAttributes = DER.element(tag: 0x31, attributeContent)

    let algorithm: SecKeyAlgorithm =
      isRSA ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        privateKey, algorithm, signedAttributes as CFData, &error)
    else {
      throw PDFError(.unsupported, "The signing key refused the operation")
    }
    let signatureOID = isRSA ? rsaEncryptionOID : ecdsaWithSHA256OID

    let identifierCertificate = signerIdentifierCertificate ?? certificate
    guard
      let (issuerDER, serialDER) = issuerAndSerial(certificate: identifierCertificate)
    else {
      throw PDFError(.malformed, "The signer certificate could not be parsed")
    }
    // SIG-01: RFC 3279 requires rsaEncryption parameters to be an explicit
    // NULL. Some independent CMS parsers (NSS/poppler) reject an absent
    // parameter set even though lenient ones default it; ECDSA parameters
    // must stay absent.
    let signatureAlgorithm: Data
    if isRSA {
      signatureAlgorithm = DER.sequence([
        DER.oid(signatureOID), DER.element(tag: 0x05, Data()),
      ])
    } else {
      signatureAlgorithm = DER.sequence([DER.oid(signatureOID)])
    }
    // Embedded certificates: the signer plus whatever chain the system built.
    var chain: [SecCertificate] = [certificate]
    if let trust = makeTrust(for: certificate),
      let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      !certificates.isEmpty
    {
      chain = certificates
    }
    return PreparedDetachedSignature(
      identifierIssuerDER: issuerDER, identifierSerialDER: serialDER,
      signedAttributeContent: attributeContent, signature: signature as Data,
      signatureOID: signatureOID, digestOID: sha256OID,
      signatureAlgorithm: signatureAlgorithm, certificates: chain)
  }

  static func makeTrust(for certificate: SecCertificate) -> SecTrust? {
    let policy = SecPolicyCreateBasicX509()
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess else {
      return nil
    }
    return trust
  }

  /// Extracts the issuer Name and serialNumber DER from a certificate so the
  /// SignerInfo can reference the signer.
  static func issuerAndSerial(certificate: SecCertificate) -> (Data, Data)? {
    let der = Data(SecCertificateCopyData(certificate) as Data)
    let bytes = [UInt8](der)
    let limits = PDFLimits()
    guard var reader = try? DERReader(bytes: bytes),
      let certificateSequence = try? reader.readElement(limits: limits),
      certificateSequence.tag == 0x30
    else { return nil }
    var content = DERReader(
      bytes: bytes, offset: certificateSequence.content.startIndex,
      end: certificateSequence.content.endIndex)
    guard let tbs = try? content.readElement(limits: limits), tbs.tag == 0x30 else { return nil }
    var tbsReader = DERReader(
      bytes: bytes, offset: tbs.content.startIndex, end: tbs.content.endIndex)
    guard var first = try? tbsReader.readElement(limits: limits) else { return nil }
    if first.tag == 0xA0 {
      guard let next = try? tbsReader.readElement(limits: limits) else { return nil }
      first = next
    }
    // TBSCertificate: version?, serialNumber, signature, issuer, ...
    guard first.tag == 0x02 else { return nil }
    guard let signature = try? tbsReader.readElement(limits: limits), signature.tag == 0x30,
      let issuer = try? tbsReader.readElement(limits: limits), issuer.tag == 0x30
    else { return nil }
    let serial = Data(bytes[first.start..<first.content.endIndex])
    let issuerDER = Data(bytes[issuer.start..<issuer.content.endIndex])
    return (issuerDER, serial)
  }
}
