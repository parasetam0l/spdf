import CryptoKit
import Foundation
import PDFCore

/// Minimal first-party X.509 field reader for the timestamp/revocation
/// profile. It parses only the fields needed to match a certificate to a CMS
/// signer, an OCSP CertID or a CRL entry: serial, issuer/subject Name DER,
/// validity, SubjectPublicKeyInfo bits and the SubjectKeyIdentifier extension.
/// Signature-path trust still goes through Security's SecTrust.
struct X509CertificateFields: Sendable, Equatable {
  let serialDER: Data
  let issuerDER: Data
  let subjectDER: Data
  let notBefore: Date?
  let notAfter: Date?
  /// Raw subjectPublicKey BIT STRING contents without the unused-bits octet.
  let subjectPublicKeyBits: Data
  let subjectKeyIdentifier: Data?
  /// Extended key usage OIDs, when present.
  let extendedKeyUsage: [String]
  /// Not critical for matching, but timeStamping material is flagged in the
  /// timestamp evidence instead of pretending it was enforced.
  var hasTimeStampingEKU: Bool {
    extendedKeyUsage.contains("1.3.6.1.5.5.7.3.8")
  }

  static let subjectKeyIdentifierOID = "2.5.29.14"
  static let extendedKeyUsageOID = "2.5.29.37"

  static func parse(_ der: Data, limits: PDFLimits = PDFLimits()) throws -> X509CertificateFields {
    let bytes = [UInt8](der)
    guard bytes.count <= limits.tokenBytes else {
      throw PDFError(.limitExceeded, "Certificate exceeds the configured limit")
    }
    var reader = DERReader(bytes: bytes)
    let certificate = try reader.readElement(limits: limits)
    try DERReader.expect(certificate, tag: 0x30, "Certificate is not a SEQUENCE")
    var certificateReader = DERReader(
      bytes: bytes, offset: certificate.content.startIndex, end: certificate.content.endIndex)
    let tbs = try certificateReader.readElement(limits: limits)
    try DERReader.expect(tbs, tag: 0x30, "TBSCertificate is malformed")
    var tbsReader = DERReader(
      bytes: bytes, offset: tbs.content.startIndex, end: tbs.content.endIndex)

    var first = try tbsReader.readElement(limits: limits)
    if first.tag == 0xA0 {
      first = try tbsReader.readElement(limits: limits)
    }
    try DERReader.expect(first, tag: 0x02, "Certificate serial number is missing")
    let serialDER = Data(bytes[first.start..<first.content.endIndex])

    let signatureAlgorithm = try tbsReader.readElement(limits: limits)
    try DERReader.expect(signatureAlgorithm, tag: 0x30, "Certificate signature algorithm is malformed")

    let issuer = try tbsReader.readElement(limits: limits)
    try DERReader.expect(issuer, tag: 0x30, "Certificate issuer is malformed")
    let issuerDER = Data(bytes[issuer.start..<issuer.content.endIndex])

    let validity = try tbsReader.readElement(limits: limits)
    try DERReader.expect(validity, tag: 0x30, "Certificate validity is malformed")
    var validityReader = DERReader(
      bytes: bytes, offset: validity.content.startIndex, end: validity.content.endIndex)
    let notBeforeElement = try validityReader.readElement(limits: limits)
    let notAfterElement = try validityReader.readElement(limits: limits)
    let notBefore = (notBeforeElement.tag == 0x17 || notBeforeElement.tag == 0x18)
      ? DERReader.time(notBeforeElement.tag, notBeforeElement.content) : nil
    let notAfter = (notAfterElement.tag == 0x17 || notAfterElement.tag == 0x18)
      ? DERReader.time(notAfterElement.tag, notAfterElement.content) : nil

    let subject = try tbsReader.readElement(limits: limits)
    try DERReader.expect(subject, tag: 0x30, "Certificate subject is malformed")
    let subjectDER = Data(bytes[subject.start..<subject.content.endIndex])

    let subjectPublicKeyInfo = try tbsReader.readElement(limits: limits)
    try DERReader.expect(
      subjectPublicKeyInfo, tag: 0x30, "Certificate SubjectPublicKeyInfo is malformed")
    var spkiReader = DERReader(
      bytes: bytes, offset: subjectPublicKeyInfo.content.startIndex,
      end: subjectPublicKeyInfo.content.endIndex)
    _ = try spkiReader.readElement(limits: limits)  // algorithm
    let publicKey = try spkiReader.readElement(limits: limits)
    try DERReader.expect(publicKey, tag: 0x03, "Certificate public key bits are malformed")
    guard let unusedBits = publicKey.content.first, unusedBits <= 7 else {
      throw PDFError(.malformed, "Certificate public key bits are malformed")
    }
    let subjectPublicKeyBits = Data(publicKey.content.dropFirst())

    var subjectKeyIdentifier: Data?
    var extendedKeyUsage: [String] = []
    while !tbsReader.isAtEnd {
      let element = try tbsReader.readElement(limits: limits)
      guard element.tag == 0xA3 else { continue }
      var extensionsReader = DERReader(
        bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
      let extensions = try extensionsReader.readElement(limits: limits)
      guard extensions.tag == 0x30 else { continue }
      var listReader = DERReader(
        bytes: bytes, offset: extensions.content.startIndex, end: extensions.content.endIndex)
      while !listReader.isAtEnd {
        let extensionElement = try listReader.readElement(limits: limits)
        guard extensionElement.tag == 0x30 else { continue }
        var extensionReader = DERReader(
          bytes: bytes, offset: extensionElement.content.startIndex,
          end: extensionElement.content.endIndex)
        let oidElement = try extensionReader.readElement(limits: limits)
        guard oidElement.tag == 0x06 else { continue }
        let oid = DERReader.oid(oidElement.content)
        if !extensionReader.isAtEnd {
          let critical = try extensionReader.readElement(limits: limits)
          if critical.tag == 0x01 { }  // critical flag is not needed for matching
        }
        guard !extensionReader.isAtEnd else { continue }
        let valueElement = try extensionReader.readElement(limits: limits)
        guard valueElement.tag == 0x04 else { continue }
        let value = Data(bytes[valueElement.content.startIndex..<valueElement.content.endIndex])
        switch oid {
        case subjectKeyIdentifierOID:
          var valueReader = DERReader(bytes: [UInt8](value))
          if let keyIdentifier = try? valueReader.readElement(limits: limits), keyIdentifier.tag == 0x04 {
            subjectKeyIdentifier = Data([UInt8](value)[keyIdentifier.content.startIndex..<keyIdentifier.content.endIndex])
          }
        case extendedKeyUsageOID:
          var valueReader = DERReader(bytes: [UInt8](value))
          if let usages = try? valueReader.readElement(limits: limits), usages.tag == 0x30 {
            var usagesReader = DERReader(
              bytes: [UInt8](value), offset: usages.content.startIndex, end: usages.content.endIndex)
            while !usagesReader.isAtEnd {
              if let usage = try? usagesReader.readElement(limits: limits), usage.tag == 0x06 {
                extendedKeyUsage.append(DERReader.oid(usage.content))
              } else {
                break
              }
            }
          }
        default:
          continue
        }
      }
    }

    return X509CertificateFields(
      serialDER: serialDER, issuerDER: issuerDER, subjectDER: subjectDER,
      notBefore: notBefore, notAfter: notAfter,
      subjectPublicKeyBits: subjectPublicKeyBits,
      subjectKeyIdentifier: subjectKeyIdentifier, extendedKeyUsage: extendedKeyUsage)
  }

  static func certificate(fromDER der: Data) -> SecCertificate? {
    SecCertificateCreateWithData(nil, der as CFData)
  }

  static func certificateDER(_ certificate: SecCertificate) -> Data {
    SecCertificateCopyData(certificate) as Data
  }

  /// OCSP CertID hashes: SHA-1 by default, SHA-256 when the responder uses it.
  enum OCSPHash: String, Sendable, Equatable {
    case sha1 = "1.3.14.3.2.26"
    case sha256 = "2.16.840.1.101.3.4.2.1"

    var digest: (Data) -> Data {
      switch self {
      case .sha1: return { Data(Insecure.SHA1.hash(data: $0)) }
      case .sha256: return { Data(SHA256.hash(data: $0)) }
      }
    }
  }

  func issuerNameHash(_ algorithm: OCSPHash) -> Data {
    algorithm.digest(issuerDER)
  }

  func issuerKeyHash(_ algorithm: OCSPHash) -> Data {
    algorithm.digest(subjectPublicKeyBits)
  }
}
