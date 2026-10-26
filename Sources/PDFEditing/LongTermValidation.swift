import CryptoKit
import Foundation
import PDFCore
import Security

/// SIG-04: the supported long-term validation (PAdES/DSS) profile. The exact
/// supported subset is disclosed everywhere a profile is reported; anything
/// outside it is reported as unsupported rather than guessed at.
public enum PDFLongTermValidationProfile: String, Sendable, Equatable {
  case noSignatures = "No signatures"
  case noEmbeddedEvidence = "Signed without embedded long-term evidence"
  case baselineLT = "PAdES B-LT (DSS/VRI validation data)"
  case baselineLTA = "PAdES B-LTA (B-LT plus document timestamp)"
  case incomplete = "Long-term evidence incomplete"
  case unsupported = "Unsupported long-term profile"
}

/// SIG-04: fixed disclosures for UI, reports and documentation.
public enum PDFLongTermValidationDisclosure {
  public static let supportedProfile = """
    Supported long-term profile (PAdES/DSS subset): a CMS SignedData signature     with the single-gap /ByteRange carrier (adbe.pkcs7.detached, and     ETSI.CAdES.detached when its CMS payload verifies), a signature timestamp     (RFC 3161 token in the SignerInfo unsigned attributes), and embedded     validation data in the document security store: /DSS /Certs, /OCSPs, /CRLs     and a /VRI entry keyed by the SHA-1 hash of the signature /Contents, where     a good OCSP or CRL response for the signer certificate is embedded.     B-LTA additionally requires a verified ETSI.RFC3161 document timestamp     (/Type /DocTimeStamp) covering the revision that contains the DSS evidence.     Validation is offline: no network fetch, no timestamp or revocation service     is contacted, and embedded evidence is used exactly as filed.
    """
  public static let unsupportedProfile = """
    Not supported by this profile: multiple /ByteRange gaps, evidence that must     be fetched from the network, LTV status for signatures without a signature     timestamp, Adobe-specific DSS extensions outside /Certs, /OCSPs, /CRLs and     /VRI, and document timestamps whose TSA chain cannot be evaluated offline.     These cases are reported as incomplete/unsupported, never as long-term valid.
    """
}

/// SIG-04: one DSS /VRI entry.
public struct PDFDSSVRIEntry: Sendable, Equatable {
  public let key: String
  public let certificateDER: [Data]
  public let ocspDER: [Data]
  public let crlDER: [Data]
  public let timestampTokenDER: Data?
  public let timestampTime: Date?

  public init(
    key: String, certificateDER: [Data], ocspDER: [Data], crlDER: [Data],
    timestampTokenDER: Data?, timestampTime: Date?
  ) {
    self.key = key
    self.certificateDER = certificateDER
    self.ocspDER = ocspDER
    self.crlDER = crlDER
    self.timestampTokenDER = timestampTokenDER
    self.timestampTime = timestampTime
  }
}

/// SIG-04: parsed document security store.
public struct PDFDSSInventory: Sendable, Equatable {
  public let hasDSS: Bool
  public let certificateDER: [Data]
  public let ocspDER: [Data]
  public let crlDER: [Data]
  public let vri: [String: PDFDSSVRIEntry]

  public init(
    hasDSS: Bool, certificateDER: [Data], ocspDER: [Data], crlDER: [Data],
    vri: [String: PDFDSSVRIEntry]
  ) {
    self.hasDSS = hasDSS
    self.certificateDER = certificateDER
    self.ocspDER = ocspDER
    self.crlDER = crlDER
    self.vri = vri
  }

  public var certificateCount: Int { certificateDER.count }
  public var ocspCount: Int { ocspDER.count }
  public var crlCount: Int { crlDER.count }
  public var vriCount: Int { vri.count }
  public var isEmpty: Bool {
    certificateDER.isEmpty && ocspDER.isEmpty && crlDER.isEmpty && vri.isEmpty
  }

  /// SIG-04: the VRI key for a signature: SHA-1 of the signature's /Contents
  /// value without the trailing zero padding authors use to reserve space.
  public static func signatureContentsHash(_ contents: Data) -> String {
    var unpadded = contents
    while unpadded.last == 0 { unpadded.removeLast() }
    let digest = Insecure.SHA1.hash(data: unpadded)
    return digest.map { String(format: "%02X", $0) }.joined()
  }

  public func entry(forSignatureContents contents: Data) -> PDFDSSVRIEntry? {
    let key = Self.signatureContentsHash(contents)
    if let exact = vri[key] { return exact }
    // Some producers key the VRI with the padded value; accept that spelling
    // as evidence discovery only (the profile disclosure still says SHA-1 of
    // the contents).
    let paddedKey = Insecure.SHA1.hash(data: contents)
      .map { String(format: "%02X", $0) }.joined()
    return vri[paddedKey]
  }

  static func parse(in graph: PDFGraph, limits: PDFLimits = PDFLimits()) -> PDFDSSInventory {
    guard let rootID = catalogID(in: graph),
      case .dictionary(let catalog)? = graph.objects[rootID]
    else {
      return PDFDSSInventory(
        hasDSS: false, certificateDER: [], ocspDER: [], crlDER: [], vri: [:])
    }
    guard case .dictionary(let dss)? = resolved(catalog[PDFName("DSS")], in: graph) else {
      return PDFDSSInventory(
        hasDSS: false, certificateDER: [], ocspDER: [], crlDER: [], vri: [:])
    }
    let certificates = streamContents(dss[PDFName("Certs")], in: graph, limits: limits)
    let ocsps = streamContents(dss[PDFName("OCSPs")], in: graph, limits: limits)
    let crls = streamContents(dss[PDFName("CRLs")], in: graph, limits: limits)
    var entries: [String: PDFDSSVRIEntry] = [:]
    if case .dictionary(let vri)? = resolved(dss[PDFName("VRI")], in: graph) {
      for (name, value) in vri {
        guard case .dictionary(let entry)? = resolved(value, in: graph) else { continue }
        let key = String(decoding: name.bytes, as: UTF8.self)
        entries[key] = PDFDSSVRIEntry(
          key: key,
          certificateDER: streamContents(entry[PDFName("Cert")], in: graph, limits: limits),
          ocspDER: streamContents(entry[PDFName("OCSP")], in: graph, limits: limits),
          crlDER: streamContents(entry[PDFName("CRL")], in: graph, limits: limits),
          timestampTokenDER: streamContents(entry[PDFName("TS")], in: graph, limits: limits)
            .first,
          timestampTime: dateValue(entry[PDFName("TU")], in: graph))
      }
    }
    return PDFDSSInventory(
      hasDSS: true, certificateDER: certificates, ocspDER: ocsps, crlDER: crls,
      vri: entries)
  }

  static func streamContents(
    _ value: PDFValue?, in graph: PDFGraph, limits: PDFLimits
  ) -> [Data] {
    let array: [PDFValue]
    switch resolved(value, in: graph) {
    case .array(let values)?: array = values
    default: return []
    }
    var result: [Data] = []
    for item in array {
      switch resolved(item, in: graph) {
      case .stream(let stream)?:
        if stream.bytes.count <= limits.streamBytes { result.append(stream.bytes) }
      case .string(let data)?:
        if data.count <= limits.streamBytes { result.append(data) }
      default:
        continue
      }
    }
    return result
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    switch value {
    case .reference(let id)?: return graph.objects[id]
    default: return value
    }
  }

  static func catalogID(in graph: PDFGraph) -> PDFObjectID? {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")] else { return nil }
    return rootID
  }

  static func dateValue(_ value: PDFValue?, in graph: PDFGraph) -> Date? {
    guard case .string(let data)? = resolved(value, in: graph) else { return nil }
    return parsePDFDate(String(decoding: data, as: UTF8.self))
  }

  /// Bounded PDF date parser for a VRI /TU value ("D:YYYYMMDDHHmmSS+HH'mm'").
  static func parsePDFDate(_ text: String) -> Date? {
    var value = text
    if value.hasPrefix("D:") { value.removeFirst(2) }
    let digits = Array(value.prefix(14))
    guard digits.count >= 4 else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      guard range.upperBound <= digits.count else { return nil }
      var result = 0
      for index in range {
        guard let digit = digits[index].wholeNumberValue else { return nil }
        result = result * 10 + digit
      }
      return result
    }
    guard let year = number(0..<min(4, digits.count)) else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = digits.count >= 6 ? number(4..<6) : 1
    components.day = digits.count >= 8 ? number(6..<8) : 1
    components.hour = digits.count >= 10 ? number(8..<10) : 0
    components.minute = digits.count >= 12 ? number(10..<12) : 0
    components.second = digits.count >= 14 ? number(12..<14) : 0
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar.date(from: components)
  }
}

/// SIG-04: per-signature long-term completeness, independent of visual trust.
public struct PDFLongTermSignatureEvidence: Sendable, Equatable {
  public enum Status: String, Sendable, Equatable {
    case longTermComplete = "Long-term complete"
    case invalidSignature = "Signature does not verify"
    case unsupportedProfile = "Unsupported signature carrier"
    case missingTimestamp = "No signature timestamp"
    case missingCertificates = "Signer certificate not embedded"
    case missingEvidence = "No DSS/VRI evidence"
    case revoked = "Certificate revoked in embedded evidence"
    case missingRevocation = "No conclusive embedded revocation evidence"
  }

  public let fieldName: String
  public let objectID: PDFObjectID?
  public let contentsHash: String
  public let signerName: String?
  public let status: Status
  public let hasVRIEntry: Bool
  public let signerCertificateEmbedded: Bool
  public let signatureTimestamp: PDFTimestampEvidence
  public let revocation: PDFRevocationEvidence
  public let cryptoValid: Bool
  public let coversWholeFile: Bool
  public let unsignedChanges: Bool
  public let details: [String]

  public init(
    fieldName: String, objectID: PDFObjectID?, contentsHash: String, signerName: String?,
    status: Status, hasVRIEntry: Bool, signerCertificateEmbedded: Bool,
    signatureTimestamp: PDFTimestampEvidence, revocation: PDFRevocationEvidence,
    cryptoValid: Bool, coversWholeFile: Bool, unsignedChanges: Bool, details: [String]
  ) {
    self.fieldName = fieldName
    self.objectID = objectID
    self.contentsHash = contentsHash
    self.signerName = signerName
    self.status = status
    self.hasVRIEntry = hasVRIEntry
    self.signerCertificateEmbedded = signerCertificateEmbedded
    self.signatureTimestamp = signatureTimestamp
    self.revocation = revocation
    self.cryptoValid = cryptoValid
    self.coversWholeFile = coversWholeFile
    self.unsignedChanges = unsignedChanges
    self.details = details
  }

  public var isLongTermComplete: Bool { status == .longTermComplete }
}

/// SIG-04: one archival/document timestamp token.
public struct PDFDocumentTimestampEvidence: Sendable, Equatable {
  public let objectID: PDFObjectID?
  public let fieldName: String?
  public let status: PDFTimestampEvidence.Status
  public let trust: PDFTimestampEvidence.Trust?
  public let genTime: Date?
  public let coversWholeFile: Bool
  public let imprintMatches: Bool
  public let details: [String]

  public init(
    objectID: PDFObjectID?, fieldName: String?, status: PDFTimestampEvidence.Status,
    trust: PDFTimestampEvidence.Trust?, genTime: Date?, coversWholeFile: Bool,
    imprintMatches: Bool, details: [String]
  ) {
    self.objectID = objectID
    self.fieldName = fieldName
    self.status = status
    self.trust = trust
    self.genTime = genTime
    self.coversWholeFile = coversWholeFile
    self.imprintMatches = imprintMatches
    self.details = details
  }

  public var isValid: Bool { status == .verified || status == .verifiedUntrusted }
  public var isFullyVerified: Bool { status == .verified }
}

/// SIG-04: the long-term validation report. This is evidence-only: it never
/// relayers a drawn mark as a certificate signature and never fetches data.
public struct PDFLongTermValidationReport: Sendable, Equatable {
  public let profile: PDFLongTermValidationProfile
  public let disclosure: String
  public let dss: PDFDSSInventory
  public let signatures: [PDFLongTermSignatureEvidence]
  public let documentTimestamps: [PDFDocumentTimestampEvidence]
  public let warnings: [String]

  public init(
    profile: PDFLongTermValidationProfile, disclosure: String, dss: PDFDSSInventory,
    signatures: [PDFLongTermSignatureEvidence],
    documentTimestamps: [PDFDocumentTimestampEvidence], warnings: [String]
  ) {
    self.profile = profile
    self.disclosure = disclosure
    self.dss = dss
    self.signatures = signatures
    self.documentTimestamps = documentTimestamps
    self.warnings = warnings
  }

  public var isLongTermValid: Bool {
    (profile == .baselineLT || profile == .baselineLTA)
      && signatures.allSatisfy(\.isLongTermComplete)
      && (profile != .baselineLTA || documentTimestamps.contains { $0.isValid })
  }

  public var summaryLines: [String] {
    var lines = [
      "Long-term profile: \(profile.rawValue)",
      "DSS: \(dss.certificateCount) certificate(s), \(dss.ocspCount) OCSP response(s), "
        + "\(dss.crlCount) CRL(s), \(dss.vriCount) VRI entr\(dss.vriCount == 1 ? "y" : "ies")",
    ]
    lines.append(contentsOf: signatures.map { evidence in
      "\(evidence.fieldName): \(evidence.status.rawValue)"
        + (evidence.signatureTimestamp.genTime.map {
          " (timestamp \($0.timeIntervalSince1970))"
        } ?? "")
    })
    if !documentTimestamps.isEmpty {
      lines.append("Document timestamps: \(documentTimestamps.count)")
    }
    return lines
  }

  public var plainText: String {
    (summaryLines + warnings + ["", disclosure]).joined(separator: "\n")
  }
}

/// SIG-04: offline long-term validation using the embedded DSS evidence.
public enum PDFLongTermValidationValidator {
  public static func report(
    in source: ParsedPDF, trustedAnchors: [SecCertificate] = [],
    timestampTrustedAnchors: [SecCertificate] = [], validationTime: Date = Date(),
    limits: PDFLimits = PDFLimits()
  ) -> PDFLongTermValidationReport {
    report(
      in: source.graph, sourceData: source.source, trustedAnchors: trustedAnchors,
      timestampTrustedAnchors: timestampTrustedAnchors, validationTime: validationTime,
      limits: limits)
  }

  public static func report(
    in graph: PDFGraph, sourceData: Data, trustedAnchors: [SecCertificate] = [],
    timestampTrustedAnchors: [SecCertificate] = [], validationTime: Date = Date(),
    limits: PDFLimits = PDFLimits()
  ) -> PDFLongTermValidationReport {
    let dss = PDFDSSInventory.parse(in: graph, limits: limits)
    let signatures = (try? PDFSignatureInventory.signatures(in: graph, limits: limits)) ?? []
    let timestampAnchors = timestampTrustedAnchors.isEmpty
      ? trustedAnchors : timestampTrustedAnchors
    var warnings: [String] = []
    var documentTimestamps: [PDFDocumentTimestampEvidence] = []
    for signature in signatures where signature.kind == .documentTimestamp {
      documentTimestamps.append(
        documentTimestampEvidence(
          signature, sourceData: sourceData, anchors: timestampAnchors,
          validationTime: validationTime, limits: limits))
    }
    var evidence: [PDFLongTermSignatureEvidence] = []
    for (index, signature) in signatures.enumerated() where signature.kind == .signature {
      evidence.append(
        signatureEvidence(
          signature, index: index, graph: graph, sourceData: sourceData, dss: dss,
          trustedAnchors: trustedAnchors, timestampAnchors: timestampAnchors,
          validationTime: validationTime, limits: limits))
    }
    if dss.hasDSS && dss.vri.isEmpty && !dss.isEmpty {
      warnings.append("The DSS has default evidence arrays but no /VRI entries.")
    }
    if !dss.hasDSS && !evidence.isEmpty {
      warnings.append(
        "This document has no DSS; signatures are not long-term verifiable from embedded evidence.")
    }
    for timestamp in documentTimestamps where !timestamp.isValid {
      warnings.append("A document timestamp is present but its evidence does not verify.")
    }
    let profile = classify(
      evidence: evidence, documentTimestamps: documentTimestamps, dss: dss)
    if profile == .baselineLTA && !documentTimestamps.contains(where: { $0.isValid }) {
      warnings.append("B-LTA requires a verified document timestamp.")
    }
    if profile == .baselineLT {
      warnings.append(
        "The profile is B-LT: validation data is embedded but no archival document timestamp is present.")
    }
    return PDFLongTermValidationReport(
      profile: profile,
      disclosure: profile == .unsupported
        ? PDFLongTermValidationDisclosure.unsupportedProfile
        : PDFLongTermValidationDisclosure.supportedProfile,
      dss: dss, signatures: evidence, documentTimestamps: documentTimestamps,
      warnings: warnings)
  }

  static func classify(
    evidence: [PDFLongTermSignatureEvidence],
    documentTimestamps: [PDFDocumentTimestampEvidence], dss: PDFDSSInventory
  ) -> PDFLongTermValidationProfile {
    guard !evidence.isEmpty else { return .noSignatures }
    if evidence.contains(where: { $0.status == .unsupportedProfile }) {
      return .unsupported
    }
    let complete = evidence.allSatisfy(\.isLongTermComplete)
    if complete {
      return documentTimestamps.contains(where: { $0.isValid }) ? .baselineLTA : .baselineLT
    }
    if !dss.hasDSS || (dss.isEmpty && evidence.allSatisfy({ !$0.signerCertificateEmbedded })) {
      return .noEmbeddedEvidence
    }
    return .incomplete
  }

  static func signatureEvidence(
    _ signature: PDFSignature, index: Int, graph: PDFGraph, sourceData: Data,
    dss: PDFDSSInventory, trustedAnchors: [SecCertificate],
    timestampAnchors: [SecCertificate], validationTime: Date, limits: PDFLimits
  ) -> PDFLongTermSignatureEvidence {
    let contents = signatureContents(signature)
    let contentsHash = PDFDSSInventory.signatureContentsHash(contents)
    let vri = dss.entry(forSignatureContents: contents)
    let fieldName = signature.fieldName ?? "Signature \(index + 1)"
    var details: [String] = []
    let supportedCarriers = ["adbe.pkcs7.detached", "ETSI.CAdES.detached"]
    let carrierSupported = signature.subFilter.map { supportedCarriers.contains($0) } ?? false
    let first = PDFSignatureValidator.validate(
      signature, source: sourceData, finalGraph: graph, trustedAnchors: trustedAnchors,
      timestampTrustedAnchors: timestampAnchors, revocationEvidence: nil,
      validationTime: validationTime, limits: limits)
    let signingCert = signerCertificate(
      contents: contents, certificates: (vri?.certificateDER ?? []) + dss.certificateDER,
      limits: limits)
    let issuerCert = signingCert.flatMap { cert in
      issuerCertificate(for: cert, in: (vri?.certificateDER ?? []) + dss.certificateDER,
                        limits: limits)
    }
    let evidenceTime = first.timestamp.genTime ?? validationTime
    let embeddedOcsp = vri?.ocspDER ?? dss.ocspDER
    let embeddedCrl = vri?.crlDER ?? dss.crlDER
    let revocation = embeddedRevocation(
      certificateDER: signingCert, issuerDER: issuerCert,
      ocspResponses: embeddedOcsp, crls: embeddedCrl, trustedAnchors: trustedAnchors,
      validationTime: evidenceTime, limits: limits)
    let second = PDFSignatureValidator.validate(
      signature, source: sourceData, finalGraph: graph, trustedAnchors: trustedAnchors,
      timestampTrustedAnchors: timestampAnchors, revocationEvidence: revocation,
      validationTime: validationTime, limits: limits)
    let signerEmbedded = signingCert.map { candidate in
      dss.certificateDER.contains { existing in
        existing.elementsEqual(candidate)
      }
    } ?? false
    if !carrierSupported {
      details.append("Only adbe.pkcs7.detached/ETSI.CAdES.detached carriers are supported.")
    }
    if vri == nil {
      details.append("No VRI entry was found; default DSS arrays were used.")
    }
    if signingCert == nil {
      details.append("The signer certificate could not be identified from the CMS payload.")
    }
    if let timestamp = vri?.timestampTime {
      details.append("VRI timestamp time: \(timestamp.timeIntervalSince1970)")
    }
    let status: PDFLongTermSignatureEvidence.Status
    if !carrierSupported {
      status = .unsupportedProfile
    } else if second.crypto != .valid {
      status = .invalidSignature
    } else if !first.timestamp.isEmbeddable {
      status = .missingTimestamp
    } else if !dss.hasDSS {
      status = .missingEvidence
    } else if !signerEmbedded {
      status = .missingCertificates
    } else if revocation.isConclusiveRevoked {
      status = .revoked
    } else if revocation.isConclusiveGood {
      status = .longTermComplete
    } else if vri == nil && embeddedOcsp.isEmpty && embeddedCrl.isEmpty {
      status = .missingEvidence
    } else {
      status = .missingRevocation
    }
    return PDFLongTermSignatureEvidence(
      fieldName: fieldName, objectID: signature.objectID, contentsHash: contentsHash,
      signerName: first.signerName ?? second.signerName, status: status,
      hasVRIEntry: vri != nil, signerCertificateEmbedded: signerEmbedded,
      signatureTimestamp: first.timestamp, revocation: revocation,
      cryptoValid: second.crypto == .valid, coversWholeFile: second.signatureCoversWholeFile,
      unsignedChanges: second.unsignedChanges, details: details + second.details)
  }

  static func documentTimestampEvidence(
    _ signature: PDFSignature, sourceData: Data, anchors: [SecCertificate],
    validationTime: Date, limits: PDFLimits
  ) -> PDFDocumentTimestampEvidence {
    let bytes = [UInt8](sourceData)
    var details: [String] = []
    guard signature.byteRange.count == 4, signature.byteRange[0] == 0,
      signature.byteRange[1] <= bytes.count, signature.byteRange[2] <= bytes.count,
      signature.byteRange[3] <= bytes.count, signature.byteRange[2] + signature.byteRange[3]
        == bytes.count
    else {
      return PDFDocumentTimestampEvidence(
        objectID: signature.objectID, fieldName: signature.fieldName, status: .invalid,
        trust: nil, genTime: nil, coversWholeFile: false, imprintMatches: false,
        details: ["The document timestamp ByteRange does not cover the whole file"])
    }
    var covered = Data(bytes[0..<signature.byteRange[1]])
    covered.append(contentsOf: bytes[signature.byteRange[2]..<bytes.count - 1 + 1])
    let token = Array(signatureContents(signature))
    let trimmed = trimPadding(token)
    guard !trimmed.isEmpty else {
      return PDFDocumentTimestampEvidence(
        objectID: signature.objectID, fieldName: signature.fieldName, status: .absent,
        trust: nil, genTime: nil, coversWholeFile: true, imprintMatches: false,
        details: ["The document timestamp has no token"])
    }
    let evidence = TimestampValidator.validate(
      tokenDER: Data(trimmed), over: covered, trustedAnchors: anchors,
      validationTime: validationTime, limits: limits)
    details.append(contentsOf: evidence.details)
    return PDFDocumentTimestampEvidence(
      objectID: signature.objectID, fieldName: signature.fieldName,
      status: evidence.status, trust: evidence.trust, genTime: evidence.genTime,
      coversWholeFile: true, imprintMatches: evidence.imprintMatches, details: details)
  }

  static func signatureContents(_ signature: PDFSignature) -> Data {
    guard case .string(let data)? = signature.dictionary[PDFName("Contents")] else {
      return Data()
    }
    return data
  }

  static func trimPadding(_ data: [UInt8]) -> [UInt8] {
    var end = data.count
    while end > 0, data[end - 1] == 0 { end -= 1 }
    return Array(data[0..<end])
  }

  static func signerCertificate(
    contents: Data, certificates: [Data], limits: PDFLimits
  ) -> Data? {
    guard let cms = try? CMSSignedData.parse(contents, limits: limits) else { return nil }
    for signer in cms.signers {
      for der in certificates {
        guard let fields = try? X509CertificateFields.parse(der, limits: limits) else {
          continue
        }
        if let issuer = signer.issuerDER, let serial = signer.serialDER,
          fields.issuerDER == issuer, fields.serialDER == serial
        {
          return der
        }
        if let ski = signer.subjectKeyIdentifier, let certSKI = fields.subjectKeyIdentifier,
          ski == certSKI
        {
          return der
        }
      }
    }
    return nil
  }

  static func issuerCertificate(for certificate: Data, in certificates: [Data], limits: PDFLimits)
    -> Data?
  {
    guard let leaf = try? X509CertificateFields.parse(certificate, limits: limits) else {
      return nil
    }
    for der in certificates where !der.elementsEqual(certificate) {
      guard let candidate = try? X509CertificateFields.parse(der, limits: limits) else {
        continue
      }
      if candidate.subjectDER == leaf.issuerDER { return der }
    }
    return nil
  }

  static func embeddedRevocation(
    certificateDER: Data?, issuerDER: Data?, ocspResponses: [Data], crls: [Data],
    trustedAnchors: [SecCertificate], validationTime: Date, limits: PDFLimits
  ) -> PDFRevocationEvidence {
    guard let certificateDER else { return .notChecked }
    var best: PDFRevocationEvidence?
    for response in ocspResponses {
      let evidence = PDFRevocationValidator.validateOCSP(
        responseDER: response, certificateDER: certificateDER, issuerDER: issuerDER,
        trustedAnchors: trustedAnchors, at: validationTime, limits: limits)
      if evidence.isConclusiveGood || evidence.isConclusiveRevoked { return evidence }
      if best == nil || evidence.status != .unavailable { best = evidence }
    }
    var crlIssuer = issuerDER
    if crlIssuer == nil,
      let leaf = try? X509CertificateFields.parse(certificateDER, limits: limits)
    {
      crlIssuer = leaf.issuerDER
    }
    for response in crls {
      guard let crlIssuer else { continue }
      let evidence = PDFRevocationValidator.validateCRL(
        crlDER: response, certificateDER: certificateDER, issuerDER: crlIssuer,
        trustedAnchors: trustedAnchors, at: validationTime, limits: limits)
      if evidence.isConclusiveGood || evidence.isConclusiveRevoked { return evidence }
      if best == nil || evidence.status != .unavailable { best = evidence }
    }
    return best ?? .notChecked
  }
}
