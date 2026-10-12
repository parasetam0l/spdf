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

  static func detachedSignature(
    signedBytes: Data, identity: SecIdentity, signingTime: Date, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
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

    // Signed attributes: contentType, messageDigest, signingTime.
    let digest = Data(SHA256.hash(data: signedBytes))
    let attributeContent = DER.concatenated([
      DER.sequence([
        DER.oid(contentTypeAttributeOID), DER.set([DER.sequence([DER.oid(dataOID)])]),
      ]),
      DER.sequence([
        DER.oid(messageDigestAttributeOID), DER.set([DER.octetString(digest)]),
      ]),
      DER.sequence([
        DER.oid(signingTimeAttributeOID), DER.set([DER.utcTime(signingTime)]),
      ]),
    ])
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

    guard let (issuerDER, serialDER) = issuerAndSerial(certificate: certificate) else {
      throw PDFError(.malformed, "The signer certificate could not be parsed")
    }
    let signerInfo = DER.sequence([
      DER.integer(1),
      DER.sequence([issuerDER, serialDER]),
      DER.sequence([DER.oid(sha256OID), DER.element(tag: 0x05, Data())]),
      DER.element(tag: 0xA0, attributeContent),
      DER.sequence([DER.oid(signatureOID)]),
      DER.octetString(signature as Data),
    ])

    // Embedded certificates: the signer plus whatever chain the system built.
    var chain: [SecCertificate] = [certificate]
    if let trust = makeTrust(for: certificate),
      let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      !certificates.isEmpty
    {
      chain = certificates
    }
    let certificateSet = DER.element(
      tag: 0xA0,
      DER.concatenated(
        chain.map { Data(SecCertificateCopyData($0) as Data) }
          .sorted { $0.lexicographicallyPrecedes($1) }))

    let signedData = DER.sequence([
      DER.integer(1),
      DER.set([DER.sequence([DER.oid(sha256OID), DER.element(tag: 0x05, Data())])]),
      DER.sequence([DER.oid(dataOID)]),
      certificateSet,
      DER.set([signerInfo]),
    ])
    return DER.sequence([DER.oid(signedDataOID), DER.element(tag: 0xA0, signedData)])
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
