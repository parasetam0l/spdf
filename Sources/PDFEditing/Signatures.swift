import PDFCore
import CryptoKit
import Foundation
import Security

// MARK: - Inventory

/// P30-003: one signature dictionary found in a document, with the raw
/// dictionary preserved.
public struct PDFSignature: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case signature
    case documentTimestamp
  }

  public let kind: Kind
  public let objectID: PDFObjectID?
  public let fieldName: String?
  public let pageIndex: Int?
  public let subFilter: String?
  public let byteRange: [Int]
  /// Length of the parsed /Contents value in bytes.
  public let contentsByteLength: Int
  public let signingTime: String?
  public let reason: String?
  public let location: String?
  public let name: String?
  /// P30-012: the /DocMDP permission value when a transform reference carries one.
  public let docMDPPermission: Int?
  /// P30-012: number of /Lock dictionaries attached to the field.
  public let fieldLockCount: Int
  public let dictionary: [PDFName: PDFValue]
}

extension PDFSignature {
  static func string(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    if data.count >= 2, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF {
      return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    }
    return String(decoding: data, as: UTF8.self)
  }
}

/// P30-003: signature dictionaries are found through the AcroForm field tree
/// (signature fields with a value) and by scanning for standalone signature or
/// document-timestamp dictionaries.
public enum PDFSignatureInventory {
  public static func signatures(in graph: PDFGraph, limits: PDFLimits = PDFLimits())
    throws -> [PDFSignature]
  {
    let pageIDs = (try? PDFPageTree.pageIDs(in: graph)) ?? []
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    var results: [PDFSignature] = []
    var seen: Set<PDFObjectID> = []

    for field in fields where field.kind == .signature {
      guard case .reference(let valueID)? = field.value,
        case .dictionary(let dictionary)? = graph.objects[valueID],
        dictionary[PDFName("ByteRange")] != nil, dictionary[PDFName("Contents")] != nil
      else { continue }
      seen.insert(valueID)
      results.append(
        signature(
          dictionary: dictionary, objectID: valueID, fieldName: field.name,
          pageIndex: field.widgets.first?.pageIndex, lockCount: fieldLocks(in: graph, field: field)))
    }

    for (id, value) in graph.objects {
      guard case .dictionary(let dictionary) = value, !seen.contains(id) else { continue }
      let type = dictionary[PDFName("Type")].flatMap { value -> String? in
        guard case .name(let name) = value else { return nil }
        return String(decoding: name.bytes, as: UTF8.self)
      }
      let isSignature = dictionary[PDFName("ByteRange")] != nil
        && dictionary[PDFName("Contents")] != nil
      guard isSignature else { continue }
      if type == "DocTimeStamp" {
        results.append(
          signature(
            dictionary: dictionary, objectID: id, fieldName: nil, pageIndex: nil, lockCount: 0))
      } else if type == "Sig" || dictionary[PDFName("Filter")] != nil {
        results.append(
          signature(
            dictionary: dictionary, objectID: id, fieldName: nil, pageIndex: nil, lockCount: 0))
      }
    }
    return results.sorted { ($0.fieldName ?? "") < ($1.fieldName ?? "") }
  }

  private static func fieldLocks(in graph: PDFGraph, field: FormField) -> Int {
    var count = 0
    if case .dictionary(let dictionary)? = field.value, dictionary[PDFName("Lock")] != nil {
      count += 1
    }
    guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
    else { return count }
    if dictionary[PDFName("Lock")] != nil { count += 1 }
    return count
  }

  private static func signature(
    dictionary: [PDFName: PDFValue], objectID: PDFObjectID?, fieldName: String?,
    pageIndex: Int?, lockCount: Int
  ) -> PDFSignature {
    let byteRange: [Int]
    if case .array(let values)? = dictionary[PDFName("ByteRange")] {
      byteRange = values.compactMap { value -> Int? in
        guard case .integer(let raw) = value, let int = Int(exactly: raw) else { return nil }
        return int
      }
    } else {
      byteRange = []
    }
    var contentsLength = 0
    if case .string(let data)? = dictionary[PDFName("Contents")] { contentsLength = data.count }
    let kind: PDFSignature.Kind
    if dictionary[PDFName("Type")] == .name(PDFName("DocTimeStamp")) {
      kind = .documentTimestamp
    } else {
      kind = .signature
    }
    var permission: Int?
    if case .array(let references)? = dictionary[PDFName("Reference")] {
      for reference in references {
        guard case .dictionary(let referenceDictionary) = reference,
          referenceDictionary[PDFName("TransformMethod")] == .name(PDFName("DocMDP")),
          case .dictionary(let parameters)? = referenceDictionary[PDFName("TransformParams")],
          case .integer(let raw)? = parameters[PDFName("P")]
        else { continue }
        permission = Int(exactly: raw)
      }
    }
    let subFilter: String?
    if case .name(let name)? = dictionary[PDFName("SubFilter")] {
      subFilter = String(decoding: name.bytes, as: UTF8.self)
    } else {
      subFilter = nil
    }
    return PDFSignature(
      kind: kind, objectID: objectID, fieldName: fieldName, pageIndex: pageIndex,
      subFilter: subFilter, byteRange: byteRange, contentsByteLength: contentsLength,
      signingTime: PDFSignature.string(dictionary[PDFName("M")]),
      reason: PDFSignature.string(dictionary[PDFName("Reason")]),
      location: PDFSignature.string(dictionary[PDFName("Location")]),
      name: PDFSignature.string(dictionary[PDFName("Name")]),
      docMDPPermission: permission, fieldLockCount: lockCount, dictionary: dictionary)
  }
}

// MARK: - CMS

/// The parsed subset of a CMS SignedData structure that the validation
/// profile needs (P30-006/P30-007).
struct CMSSignedData {
  struct Signer {
    let digestOID: String
    let signatureOID: String
    /// DER of the signed attributes re-tagged as a SET, ready for verification.
    let signedAttributesDER: [UInt8]?
    let signature: Data
    let messageDigest: Data?
    let signingTime: Date?
    let hasTimestampToken: Bool
    /// SIG-01: the SignerInfo certificate identifier (issuerAndSerialNumber).
    let issuerDER: Data?
    let serialDER: Data?
    /// SIG-01: a subjectKeyIdentifier SignerInfo identifier, when used.
    let subjectKeyIdentifier: Data?
  }

  let certificates: [[UInt8]]
  let signers: [Signer]
  let detached: Bool

  static func parse(_ data: Data, limits: PDFLimits = PDFLimits()) throws -> CMSSignedData {
    let bytes = [UInt8](data)
    guard bytes.count <= limits.streamBytes else {
      throw PDFError(.limitExceeded, "Signature contents exceed the configured limit")
    }
    var reader = DERReader(bytes: bytes)
    let contentInfo = try reader.readElement(limits: limits)
    try DERReader.expect(contentInfo, tag: 0x30, "Signature is not a CMS ContentInfo")
    var outer = DERReader(bytes: bytes, offset: contentInfo.content.startIndex, end: contentInfo.content.endIndex)
    let oidElement = try outer.readElement(limits: limits)
    try DERReader.expect(oidElement, tag: 0x06, "Signature has no content type")
    guard DERReader.oid(oidElement.content) == "1.2.840.113549.1.7.2" else {
      throw PDFError(.unsupported, "Only CMS SignedData signatures are supported")
    }
    let explicit = try outer.readElement(limits: limits)
    try DERReader.expect(explicit, tag: 0xA0, "Signature content is missing")
    var explicitReader = DERReader(
      bytes: bytes, offset: explicit.content.startIndex, end: explicit.content.endIndex)
    let signedData = try explicitReader.readElement(limits: limits)
    try DERReader.expect(signedData, tag: 0x30, "SignedData is malformed")
    var signed = DERReader(
      bytes: bytes, offset: signedData.content.startIndex, end: signedData.content.endIndex)

    _ = try signed.readElement(limits: limits)  // version
    let digestAlgorithms = try signed.readElement(limits: limits)
    try DERReader.expect(digestAlgorithms, tag: 0x31, "Digest algorithms are malformed")
    let encap = try signed.readElement(limits: limits)
    try DERReader.expect(encap, tag: 0x30, "Encapsulated content info is malformed")
    var encapReader = DERReader(
      bytes: bytes, offset: encap.content.startIndex, end: encap.content.endIndex)
    let contentType = try encapReader.readElement(limits: limits)
    try DERReader.expect(contentType, tag: 0x06, "Encapsulated content type is missing")
    let detached = encapReader.isAtEnd
      || DERReader.oid(contentType.content) == "1.2.840.113549.1.7.1"

    var certificates: [[UInt8]] = []
    var signerInfos: DERReader.Element?
    while !signed.isAtEnd {
      let element = try signed.readElement(limits: limits)
      switch element.tag {
      case 0xA0:
        var certificatesReader = DERReader(
          bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
        var count = 0
        while !certificatesReader.isAtEnd, count < 64 {
          let certificate = try certificatesReader.readElement(limits: limits)
          certificates.append(Array(bytes[certificate.start..<certificate.content.endIndex]))
          count += 1
        }
      case 0xA1:
        continue  // CRLs are not evaluated offline.
      case 0x31:
        signerInfos = element
      default:
        continue
      }
    }
    guard let signerInfos else {
      throw PDFError(.malformed, "SignedData has no signer infos")
    }
    var signerReader = DERReader(
      bytes: bytes, offset: signerInfos.content.startIndex, end: signerInfos.content.endIndex)
    var signers: [Signer] = []
    while !signerReader.isAtEnd, signers.count < 16 {
      let signer = try signerReader.readElement(limits: limits)
      try DERReader.expect(signer, tag: 0x30, "SignerInfo is malformed")
      signers.append(try parseSigner(bytes: bytes, element: signer, limits: limits))
    }
    guard !signers.isEmpty else {
      throw PDFError(.malformed, "SignedData has no signers")
    }
    return CMSSignedData(certificates: certificates, signers: signers, detached: detached)
  }

  private static func parseSigner(bytes: [UInt8], element: DERReader.Element, limits: PDFLimits)
    throws -> Signer
  {
    var reader = DERReader(
      bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
    _ = try reader.readElement(limits: limits)  // version
    let sid = try reader.readElement(limits: limits)  // issuerAndSerial or [0]
    guard sid.tag == 0x30 || sid.tag == 0x80 else {
      throw PDFError(.malformed, "Signer identifier is malformed")
    }
    var sidIssuerDER: Data?
    var sidSerialDER: Data?
    var sidKeyIdentifier: Data?
    if sid.tag == 0x30 {
      var sidReader = DERReader(
        bytes: bytes, offset: sid.content.startIndex, end: sid.content.endIndex)
      let issuer = try sidReader.readElement(limits: limits)
      let serial = try sidReader.readElement(limits: limits)
      guard issuer.tag == 0x30, serial.tag == 0x02 else {
        throw PDFError(.malformed, "Signer identifier is malformed")
      }
      sidIssuerDER = Data(bytes[issuer.start..<issuer.content.endIndex])
      sidSerialDER = Data(bytes[serial.start..<serial.content.endIndex])
    } else {
      sidKeyIdentifier = Data(bytes[sid.content.startIndex..<sid.content.endIndex])
    }
    let digestAlgorithm = try reader.readElement(limits: limits)
    try DERReader.expect(digestAlgorithm, tag: 0x30, "Digest algorithm is malformed")
    var digestReader = DERReader(
      bytes: bytes, offset: digestAlgorithm.content.startIndex,
      end: digestAlgorithm.content.endIndex)
    let digestOID = try digestReader.readElement(limits: limits)
    try DERReader.expect(digestOID, tag: 0x06, "Digest algorithm OID is missing")

    var signedAttributesDER: [UInt8]?
    var messageDigest: Data?
    var signingTime: Date?
    var hasTimestampToken = false

    var next = try reader.readElement(limits: limits)
    if next.tag == 0xA0 {
      // Signed attributes: re-tag the implicit SET as an explicit SET for the
      // signature input, per CMS.
      var attributes: [UInt8] = [0x31]
      let contentLength = next.content.count
      if contentLength < 0x80 {
        attributes.append(UInt8(contentLength))
      } else if contentLength <= 0xFF {
        attributes.append(contentsOf: [0x81, UInt8(contentLength)])
      } else {
        attributes.append(contentsOf: [0x82, UInt8(contentLength >> 8), UInt8(contentLength & 0xFF)])
      }
      attributes.append(contentsOf: bytes[next.content.startIndex..<next.content.endIndex])
      signedAttributesDER = attributes
      (messageDigest, signingTime) = try parseAttributes(
        bytes: bytes, element: next, limits: limits)
      next = try reader.readElement(limits: limits)
    }
    try DERReader.expect(next, tag: 0x30, "Signature algorithm is malformed")
    var signatureAlgorithmReader = DERReader(
      bytes: bytes, offset: next.content.startIndex, end: next.content.endIndex)
    let signatureOID = try signatureAlgorithmReader.readElement(limits: limits)
    try DERReader.expect(signatureOID, tag: 0x06, "Signature algorithm OID is missing")
    let signatureElement = try reader.readElement(limits: limits)
    try DERReader.expect(signatureElement, tag: 0x04, "Signature value is missing")
    let signature = Data(bytes[signatureElement.content.startIndex..<signatureElement.content.endIndex])

    if !reader.isAtEnd {
      let unsigned = try reader.readElement(limits: limits)
      if unsigned.tag == 0xA1 {
        hasTimestampToken = try containsTimestampToken(bytes: bytes, element: unsigned, limits: limits)
      }
    }
    return Signer(
      digestOID: DERReader.oid(digestOID.content),
      signatureOID: DERReader.oid(signatureOID.content),
      signedAttributesDER: signedAttributesDER, signature: signature,
      messageDigest: messageDigest, signingTime: signingTime,
      hasTimestampToken: hasTimestampToken, issuerDER: sidIssuerDER,
      serialDER: sidSerialDER, subjectKeyIdentifier: sidKeyIdentifier)
  }

  private static func parseAttributes(
    bytes: [UInt8], element: DERReader.Element, limits: PDFLimits
  ) throws -> (messageDigest: Data?, signingTime: Date?) {
    var messageDigest: Data?
    var signingTime: Date?
    var reader = DERReader(
      bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
    while !reader.isAtEnd {
      let attribute = try reader.readElement(limits: limits)
      guard attribute.tag == 0x30 else { continue }
      var attributeReader = DERReader(
        bytes: bytes, offset: attribute.content.startIndex, end: attribute.content.endIndex)
      let type = try attributeReader.readElement(limits: limits)
      guard type.tag == 0x06 else { continue }
      let oid = DERReader.oid(type.content)
      let values = try attributeReader.readElement(limits: limits)
      guard values.tag == 0x31, !values.content.isEmpty else { continue }
      var valuesReader = DERReader(
        bytes: bytes, offset: values.content.startIndex, end: values.content.endIndex)
      let first = try valuesReader.readElement(limits: limits)
      switch oid {
      case "1.2.840.113549.1.9.4":
        if first.tag == 0x04 {
          messageDigest = Data(bytes[first.content.startIndex..<first.content.endIndex])
        }
      case "1.2.840.113549.1.9.5":
        if first.tag == 0x17 || first.tag == 0x18 {
          signingTime = DERReader.time(first.tag, first.content)
        }
      default:
        continue
      }
    }
    return (messageDigest, signingTime)
  }

  private static func containsTimestampToken(
    bytes: [UInt8], element: DERReader.Element, limits: PDFLimits
  ) throws -> Bool {
    var reader = DERReader(
      bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
    while !reader.isAtEnd {
      let attribute = try reader.readElement(limits: limits)
      guard attribute.tag == 0x30 else { continue }
      var attributeReader = DERReader(
        bytes: bytes, offset: attribute.content.startIndex, end: attribute.content.endIndex)
      let type = try attributeReader.readElement(limits: limits)
      guard type.tag == 0x06 else { continue }
      if DERReader.oid(type.content) == "1.2.840.113549.1.9.16.2.14" {
        return true
      }
    }
    return false
  }
}

// MARK: - Validation

/// P30-009/P30-014: cryptographic validity, certificate trust, and revision
/// change status are reported separately; anything unsupported is
/// indeterminate rather than valid.
public struct PDFSignatureValidation: Sendable, Equatable {
  public enum Crypto: String, Sendable, Equatable {
    case valid
    case invalid
    case indeterminate
  }
  public enum Trust: String, Sendable, Equatable {
    case trusted
    case untrusted
    case unknown
    case expired
    case missingAnchor
  }

  public let crypto: Crypto
  public let trust: Trust
  public let digestAlgorithm: String?
  public let signatureAlgorithm: String?
  public let signerName: String?
  public let signerNotAfter: Date?
  /// P30-028: offline validation never checks revocation; this is always false
  /// and reported explicitly.
  public let revocationChecked: Bool
  /// P30-013: whether later revisions changed anything after signing.
  public let unsignedChanges: Bool
  public let changedObjectCount: Int
  public let details: [String]
  /// SIG-06: identity decoded from the certificate named by the CMS
  /// SignerInfo identifier (present even when cryptographic verification
  /// fails, so the UI can still identify the claimed signer).
  public var signerIdentity: PDFSignatureSignerIdentity? = nil
  /// SIG-01: bytes after the last signed range that no signature covers.
  public var uncoveredTrailingBytes: Int = 0
  /// SIG-01: true when the signed ranges reach the end of the file.
  public var signatureCoversWholeFile: Bool = true
}

/// P30-004–P30-014: validation of one signature against the source bytes and
/// the final graph.
public enum PDFSignatureValidator {
  public static func validate(
    _ signature: PDFSignature, source: Data, finalGraph: PDFGraph,
    trustedAnchors: [SecCertificate] = [], limits: PDFLimits = PDFLimits()
  ) -> PDFSignatureValidation {
    var details: [String] = []
    let bytes = [UInt8](source)

    // SIG-01: this profile supports exactly one contents gap (the standard
    // 4-integer ByteRange). Multiple gaps are structurally different; report
    // them as indeterminate rather than guessing which bytes are covered.
    if signature.byteRange.count != 4, signature.byteRange.count >= 4,
      signature.byteRange.count.isMultiple(of: 2)
    {
      details.append(
        "ByteRange uses \(signature.byteRange.count / 2) ranges; only the single-gap profile is supported")
      return PDFSignatureValidation(
        crypto: .indeterminate, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false, unsignedChanges: false,
        changedObjectCount: 0, details: details)
    }

    // P30-004: ByteRange structure.
    guard let gap = validateByteRange(signature, bytes: bytes, details: &details) else {
      return PDFSignatureValidation(
        crypto: .invalid, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false, unsignedChanges: false,
        changedObjectCount: 0, details: details)
    }
    guard signature.contentsByteLength > 0, signature.contentsByteLength <= limits.streamBytes else {
      details.append("Signature contents are empty or excessive")
      return PDFSignatureValidation(
        crypto: .invalid, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false, unsignedChanges: false,
        changedObjectCount: 0, details: details)
    }

    // P30-013: compare the signed revision with the final document.
    let (unsignedChanges, changedCount) = compareRevisions(
      gap: gap, signature: signature, bytes: bytes, finalGraph: finalGraph, limits: limits,
      details: &details)
    let uncoveredTrailingBytes = max(0, bytes.count - gap.coverageEnd)
    let signatureCoversWholeFile = uncoveredTrailingBytes == 0
    if uncoveredTrailingBytes > 0 {
      details.append(
        "\(uncoveredTrailingBytes) byte(s) after the signed ranges are not covered by this signature")
    }

    // P30-006/P30-007: CMS structure.
    let cms: CMSSignedData
    guard case .string(let contents)? = signature.dictionary[PDFName("Contents")] else {
      details.append("Signature contents are missing")
      return PDFSignatureValidation(
        crypto: .invalid, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false,
        unsignedChanges: unsignedChanges, changedObjectCount: changedCount, details: details)
    }
    do {
      cms = try CMSSignedData.parse(contents, limits: limits)
    } catch {
      details.append("Signature CMS structure could not be parsed: \(error.localizedDescription)")
      return PDFSignatureValidation(
        crypto: .invalid, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false,
        unsignedChanges: unsignedChanges, changedObjectCount: changedCount, details: details)
    }
    guard cms.detached else {
      details.append("Only detached CMS signatures are supported")
      return PDFSignatureValidation(
        crypto: .indeterminate, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false,
        unsignedChanges: unsignedChanges, changedObjectCount: changedCount, details: details)
    }
    guard let signer = cms.signers.first else {
      details.append("SignedData has no signers")
      return PDFSignatureValidation(
        crypto: .invalid, trust: .unknown, digestAlgorithm: nil, signatureAlgorithm: nil,
        signerName: nil, signerNotAfter: nil, revocationChecked: false,
        unsignedChanges: unsignedChanges, changedObjectCount: changedCount, details: details)
    }
    if signer.hasTimestampToken {
      details.append("A timestamp token is present but its validation is not implemented")
    }

    // P30-011: supported algorithms only.
    guard let digest = digestAlgorithm(for: signer.digestOID) else {
      details.append("Unsupported digest algorithm \(signer.digestOID)")
      return PDFSignatureValidation(
        crypto: .indeterminate, trust: .unknown, digestAlgorithm: signer.digestOID,
        signatureAlgorithm: signer.signatureOID, signerName: nil, signerNotAfter: nil,
        revocationChecked: false, unsignedChanges: unsignedChanges, changedObjectCount: changedCount,
        details: details)
    }
    guard let keyAlgorithm = keyAlgorithm(for: signer.signatureOID, digest: digest) else {
      details.append("Unsupported signature algorithm \(signer.signatureOID)")
      return PDFSignatureValidation(
        crypto: .indeterminate, trust: .unknown, digestAlgorithm: digest.name,
        signatureAlgorithm: signer.signatureOID, signerName: nil, signerNotAfter: nil,
        revocationChecked: false, unsignedChanges: unsignedChanges, changedObjectCount: changedCount,
        details: details)
    }

    // SIG-01: the SignerInfo certificate identifier must name the
    // certificate that verifies the signature. A signature that verifies under
    // an unrelated embedded certificate is not evidence for the claimed
    // signer, so identification happens before verification.
    var matchedCertificates: [(certificate: SecCertificate, identity: PDFSignatureSignerIdentity)] =
      []
    for certificateDER in cms.certificates {
      guard let certificate = SecCertificateCreateWithData(
        nil, Data(certificateDER) as CFData),
        let identity = PDFSignatureSignerIdentity.certificateDetails(certificate)
      else { continue }
      if let issuerDER = signer.issuerDER, let serialDER = signer.serialDER {
        guard identity.issuerDER == issuerDER, identity.serialDER == serialDER else { continue }
      } else if let keyIdentifier = signer.subjectKeyIdentifier {
        guard identity.subjectKeyIdentifier == keyIdentifier else { continue }
      } else {
        continue
      }
      matchedCertificates.append((certificate, identity))
    }
    guard let matchedIdentity = matchedCertificates.first?.identity else {
      details.append(
        "No embedded certificate matches the SignerInfo certificate identifier; "
          + "the claimed signer cannot be established")
      return PDFSignatureValidation(
        crypto: .indeterminate, trust: .unknown, digestAlgorithm: digest.name,
        signatureAlgorithm: keyAlgorithm.name, signerName: nil, signerNotAfter: nil,
        revocationChecked: false, unsignedChanges: unsignedChanges,
        changedObjectCount: changedCount, details: details)
    }

    // Signed bytes: every ByteRange pair concatenated.
    var signedBytes = Data()
    var rangeIndex = 0
    while rangeIndex + 1 < signature.byteRange.count {
      let start = signature.byteRange[rangeIndex]
      let length = signature.byteRange[rangeIndex + 1]
      guard start >= 0, length >= 0, start + length <= bytes.count else { break }
      signedBytes.append(contentsOf: bytes[start..<(start + length)])
      rangeIndex += 2
    }

    // P30-008: the messageDigest attribute must match the signed bytes.
    let digestValue: Data
    switch digest {
    case .sha256: digestValue = Data(SHA256.hash(data: signedBytes))
    case .sha384: digestValue = Data(SHA384.hash(data: signedBytes))
    case .sha512: digestValue = Data(SHA512.hash(data: signedBytes))
    }
    if let messageDigest = signer.messageDigest {
      guard messageDigest == digestValue else {
        details.append("The signed bytes do not match the signature's message digest")
        return PDFSignatureValidation(
          crypto: .invalid, trust: .unknown, digestAlgorithm: digest.name,
          signatureAlgorithm: signer.signatureOID, signerName: matchedIdentity.displayName,
          signerNotAfter: matchedIdentity.notAfter, revocationChecked: false,
          unsignedChanges: unsignedChanges, changedObjectCount: changedCount, details: details,
          signerIdentity: matchedIdentity, uncoveredTrailingBytes: uncoveredTrailingBytes,
          signatureCoversWholeFile: signatureCoversWholeFile)
      }
    } else {
      details.append("The signature has no signed attributes; the digest is implicit")
    }

    // Verify the signature over the signed attributes (or the signed bytes
    // when no attributes are present) with the embedded certificates.
    let verificationData = signer.signedAttributesDER.map { Data($0) } ?? signedBytes
    var verifiedCertificate: SecCertificate?
    for candidate in matchedCertificates {
      guard let key = SecCertificateCopyKey(candidate.certificate) else { continue }
      var error: Unmanaged<CFError>?
      if SecKeyVerifySignature(
        key, keyAlgorithm.algorithm, verificationData as CFData, signer.signature as CFData, &error)
      {
        verifiedCertificate = candidate.certificate
        break
      }
    }
    guard let certificate = verifiedCertificate else {
      details.append("The certificate named by the SignerInfo does not verify the signature")
      return PDFSignatureValidation(
        crypto: .invalid, trust: .unknown, digestAlgorithm: digest.name,
        signatureAlgorithm: signer.signatureOID, signerName: matchedIdentity.displayName,
        signerNotAfter: matchedIdentity.notAfter, revocationChecked: false,
        unsignedChanges: unsignedChanges, changedObjectCount: changedCount, details: details,
        signerIdentity: matchedIdentity, uncoveredTrailingBytes: uncoveredTrailingBytes,
        signatureCoversWholeFile: signatureCoversWholeFile)
    }

    // P30-010/P30-011: chain evaluation with an explicit offline policy.
    let (trust, notAfter) = evaluateTrust(
      signer: certificate, embedded: cms.certificates, anchors: trustedAnchors,
      details: &details)
    details.append("Offline evaluation: certificate revocation was not checked")

    return PDFSignatureValidation(
      crypto: .valid, trust: trust, digestAlgorithm: digest.name,
      signatureAlgorithm: keyAlgorithm.name,
      signerName: matchedIdentity.displayName,
      signerNotAfter: notAfter, revocationChecked: false, unsignedChanges: unsignedChanges,
      changedObjectCount: changedCount, details: details,
      signerIdentity: matchedIdentity, uncoveredTrailingBytes: uncoveredTrailingBytes,
      signatureCoversWholeFile: signatureCoversWholeFile)
  }

  // MARK: ByteRange (P30-004)

  struct ByteRangeInfo {
    let gapStart: Int
    let gapEnd: Int
    /// End offset of the signed coverage (the last range's end).
    let coverageEnd: Int
    /// SIG-01: bytes after the signed coverage.
    let uncoveredTrailingBytes: Int
  }

  static func validateByteRange(
    _ signature: PDFSignature, bytes: [UInt8], details: inout [String]
  ) -> ByteRangeInfo? {
    let ranges = signature.byteRange
    guard ranges.count >= 2, ranges.count % 2 == 0 else {
      details.append("The signature has no valid ByteRange")
      return nil
    }
    guard ranges[0] == 0 else {
      details.append("The ByteRange does not begin at the start of the file")
      return nil
    }
    var previousEnd = 0
    var gapStart: Int?
    var gapEnd: Int?
    var index = 0
    while index + 1 < ranges.count {
      let start = ranges[index]
      let length = ranges[index + 1]
      guard start >= 0, length >= 0, start <= bytes.count, length <= bytes.count - start else {
        details.append("A ByteRange pair is outside the file")
        return nil
      }
      guard start >= previousEnd else {
        details.append("ByteRange pairs overlap or are out of order")
        return nil
      }
      if index > 0 {
        gapStart = previousEnd
        gapEnd = start
      }
      previousEnd = start + length
      index += 2
    }
    guard previousEnd <= bytes.count else {
      details.append("The ByteRange extends beyond the file")
      return nil
    }
    if previousEnd < bytes.count {
      details.append("The signed ranges end before the end of the file (later revisions exist)")
    }
    guard let gapStart, let gapEnd, gapStart < gapEnd else {
      details.append("The ByteRange has no contents gap")
      return nil
    }
    let gap = ByteRangeInfo(
      gapStart: gapStart, gapEnd: gapEnd, coverageEnd: previousEnd,
      uncoveredTrailingBytes: max(0, bytes.count - previousEnd))
    // The gap must hold exactly the /Contents value (angle brackets optional).
    var contentStart = gap.gapStart
    var contentEnd = gap.gapEnd
    if contentStart < contentEnd, bytes[contentStart] == 0x3C { contentStart += 1 }
    if contentEnd > contentStart, bytes[contentEnd - 1] == 0x3E { contentEnd -= 1 }
    var hexDigits = 0
    for position in contentStart..<contentEnd {
      let byte = bytes[position]
      let isHex = (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
        || (0x61...0x66).contains(byte)
      let isWhitespace = byte == 0x0A || byte == 0x0D || byte == 0x20 || byte == 0x09
      guard isHex || isWhitespace else {
        details.append("The ByteRange gap is not a hexadecimal contents value")
        return nil
      }
      if isHex { hexDigits += 1 }
    }
    guard hexDigits == signature.contentsByteLength * 2 else {
      details.append("The ByteRange gap does not match the parsed /Contents value")
      return nil
    }
    return gap
  }

  // MARK: Revision comparison (P30-013)

  /// SIG-01/SIG-06: reconstruct the document as it existed when this
  /// signature was applied: truncate at the signed coverage end and zero the
  /// contents gap so the prefix parses as a standalone PDF. Later revisions
  /// are absent by construction.
  static func signedRevisionGraph(
    gap: ByteRangeInfo, signature: PDFSignature, bytes: [UInt8], limits: PDFLimits
  ) -> PDFGraph? {
    guard gap.coverageEnd <= bytes.count, gap.gapStart >= 0, gap.gapEnd <= gap.coverageEnd,
      gap.gapStart < gap.gapEnd
    else { return nil }
    var signedBytes = Array(bytes[0..<gap.coverageEnd])
    // The gap holds "<hex>" or a literal string; zero every byte except the
    // delimiters so a parseable but unsigned placeholder remains.
    for position in gap.gapStart..<gap.gapEnd
    where signedBytes[position] != 0x3C && signedBytes[position] != 0x3E
    {
      signedBytes[position] = 0x30
    }
    return (try? PDFParser.parse(Data(signedBytes), limits: limits))?.graph
  }

  static func compareRevisions(
    gap: ByteRangeInfo, signature: PDFSignature, bytes: [UInt8], finalGraph: PDFGraph,
    limits: PDFLimits, details: inout [String]
  ) -> (Bool, Int) {
    guard let signedParsed = signedRevisionGraph(
      gap: gap, signature: signature, bytes: bytes, limits: limits)
    else {
      details.append("The signed revision could not be reconstructed for change comparison")
      return (true, 0)
    }
    var changed = 0
    var ids: Set<PDFObjectID> = []
    for (id, _) in signedParsed.objects { ids.insert(id) }
    for (id, _) in finalGraph.objects { ids.insert(id) }
    for id in ids {
      if id == signature.objectID { continue }  // contents differ by construction
      if signedParsed.objects[id] != finalGraph.objects[id] { changed += 1 }
    }
    if changed > 0 {
      details.append("\(changed) object(s) changed after signing")
    }
    return (changed > 0, changed)
  }

  // MARK: Algorithms

  enum Digest {
    case sha256, sha384, sha512
    var name: String {
      switch self {
      case .sha256: return "SHA-256"
      case .sha384: return "SHA-384"
      case .sha512: return "SHA-512"
      }
    }
  }

  static func digestAlgorithm(for oid: String) -> Digest? {
    switch oid {
    case "2.16.840.1.101.3.4.2.1": return .sha256
    case "2.16.840.1.101.3.4.2.2": return .sha384
    case "2.16.840.1.101.3.4.2.3": return .sha512
    default: return nil
    }
  }

  struct KeyAlgorithm {
    let algorithm: SecKeyAlgorithm
    let name: String
  }

  static func keyAlgorithm(for oid: String, digest: Digest) -> KeyAlgorithm? {
    switch (oid, digest) {
    case ("1.2.840.113549.1.1.1", .sha256), ("1.2.840.113549.1.1.11", .sha256):
      return KeyAlgorithm(algorithm: .rsaSignatureMessagePKCS1v15SHA256, name: "RSA PKCS#1 v1.5 SHA-256")
    case ("1.2.840.113549.1.1.1", .sha384), ("1.2.840.113549.1.1.12", .sha384):
      return KeyAlgorithm(algorithm: .rsaSignatureMessagePKCS1v15SHA384, name: "RSA PKCS#1 v1.5 SHA-384")
    case ("1.2.840.113549.1.1.1", .sha512), ("1.2.840.113549.1.1.13", .sha512):
      return KeyAlgorithm(algorithm: .rsaSignatureMessagePKCS1v15SHA512, name: "RSA PKCS#1 v1.5 SHA-512")
    case ("1.2.840.10045.4.3.2", .sha256):
      return KeyAlgorithm(algorithm: .ecdsaSignatureMessageX962SHA256, name: "ECDSA P-256 SHA-256")
    case ("1.2.840.10045.4.3.3", .sha384):
      return KeyAlgorithm(algorithm: .ecdsaSignatureMessageX962SHA384, name: "ECDSA P-384 SHA-384")
    case ("1.2.840.10045.4.3.4", .sha512):
      return KeyAlgorithm(algorithm: .ecdsaSignatureMessageX962SHA512, name: "ECDSA P-521 SHA-512")
    default:
      return nil
    }
  }

  // MARK: Trust (P30-010)

  static func evaluateTrust(
    signer: SecCertificate, embedded: [[UInt8]], anchors: [SecCertificate],
    details: inout [String]
  ) -> (PDFSignatureValidation.Trust, Date?) {
    var chain: [SecCertificate] = [signer]
    for der in embedded {
      guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
        continue
      }
      chain.append(certificate)
    }
    let policy = SecPolicyCreateBasicX509()
    var trust: SecTrust?
    guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess,
      let trust
    else {
      details.append("The certificate chain could not be constructed")
      return (.untrusted, nil)
    }
    SecTrustSetNetworkFetchAllowed(trust, false)
    if !anchors.isEmpty {
      SecTrustSetAnchorCertificates(trust, anchors as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
    }
    var error: CFError?
    let trusted = SecTrustEvaluateWithError(trust, &error)
    let notAfter = certificateNotAfter(signer)
    if trusted {
      details.append("The certificate chain is trusted under the supplied policy")
      return (.trusted, notAfter)
    }
    let code = error.map { CFErrorGetCode($0) } ?? -1
    if code == errSecCertificateExpired {
      details.append("The signer certificate is expired")
      return (.expired, notAfter)
    }
    if anchors.isEmpty {
      details.append("The chain is not anchored by a trusted root in this offline policy")
      return (.unknown, notAfter)
    }
    details.append("The chain is not anchored by the supplied trusted roots")
    return (.missingAnchor, notAfter)
  }

  static func certificateNotAfter(_ certificate: SecCertificate) -> Date? {
    guard
      let values = SecCertificateCopyValues(
        certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
      let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
      let value = entry[kSecPropertyKeyValue]
    else { return nil }
    if let date = value as? Date { return date }
    if let number = value as? NSNumber {
      // Absolute time (2001 epoch) when a number is returned.
      return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }
    return nil
  }
}
