import CryptoKit
import Foundation
import PDFCore
import Security

/// SIG-04: appends one incremental update to an existing PDF without touching
/// earlier bytes (earlier signatures stay valid). Shared by the DSS and
/// document-timestamp writers.
enum PDFIncrementalAppend {
  static func append(
    _ objects: [PDFObjectID: PDFValue], to source: ParsedPDF, limits: PDFLimits
  ) throws -> Data {
    var output = source.source
    if output.last != 0x0A { output.append(0x0A) }
    let baseLength = output.count
    var body = Data()
    var offsets: [PDFObjectID: Int] = [:]
    for id in objects.keys.sorted() {
      guard let value = objects[id] else { continue }
      offsets[id] = baseLength + body.count
      body.append(Data("\(id.number) \(id.generation) obj\n".utf8))
      body.append(try PDFWriter.serializedValue(value, limits: limits))
      body.append(Data("\nendobj\n".utf8))
    }
    let xrefOffset = baseLength + body.count
    var table = "xref\n0 1\n0000000000 65535 f \n"
    for id in objects.keys.sorted() {
      guard let offset = offsets[id] else { continue }
      table += "\(id.number) 1\n"
      table += String(format: "%010lld %05d n \n", Int64(offset), id.generation)
    }
    var trailer = source.graph.trailer
    let highest = max(
      objects.keys.map(\.number).max() ?? 0,
      source.graph.objects.keys.map(\.number).max() ?? 0)
    trailer[PDFName("Size")] = .integer(Int64(highest) + 1)
    trailer[PDFName("Prev")] = .integer(Int64(try PDFSigningWriter.finalStartXRef(in: source.source)))
    var trailerData = Data("trailer\n".utf8)
    trailerData.append(try PDFWriter.serializedValue(.dictionary(trailer), limits: limits))
    output.append(body)
    output.append(Data(table.utf8))
    output.append(trailerData)
    output.append(Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return output
  }

  static func nextIdentifier(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }

  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    switch value {
    case .reference(let id)?: return graph.objects[id]
    default: return value
    }
  }

  static func streamArray(_ value: PDFValue?, in graph: PDFGraph) -> [PDFValue] {
    guard case .array(let values)? = resolved(value, in: graph) else { return [] }
    return values
  }
}

/// SIG-04: inputs for embedding validation data. The caller supplies evidence
/// already obtained (offline/online is the caller's choice); this writer only
/// files it into the DSS.
public struct PDFLongTermEvidenceOptions: Sendable, Equatable {
  /// The signed field to key the VRI entry for. When nil the document must
  /// contain exactly one signature.
  public let signatureFieldName: String?
  public let certificatesDER: [Data]
  public let ocspResponsesDER: [Data]
  public let crlsDER: [Data]
  /// Optional RFC 3161 token to record as the VRI timestamp evidence.
  public let timestampTokenDER: Data?
  public let timestampTime: Date?

  public init(
    signatureFieldName: String? = nil, certificatesDER: [Data] = [],
    ocspResponsesDER: [Data] = [], crlsDER: [Data] = [],
    timestampTokenDER: Data? = nil, timestampTime: Date? = nil
  ) {
    self.signatureFieldName = signatureFieldName
    self.certificatesDER = certificatesDER
    self.ocspResponsesDER = ocspResponsesDER
    self.crlsDER = crlsDER
    self.timestampTokenDER = timestampTokenDER
    self.timestampTime = timestampTime
  }
}

/// SIG-04: the appended DSS revision plus the exact VRI key and parsed store.
public struct PDFLongTermEvidenceOutcome: Sendable, Equatable {
  public let data: Data
  public let vriKey: String
  public let inventory: PDFDSSInventory

  public init(data: Data, vriKey: String, inventory: PDFDSSInventory) {
    self.data = data
    self.vriKey = vriKey
    self.inventory = inventory
  }
}

/// SIG-04: embed PAdES/DSS validation data by appending an incremental update.
public enum PDFLongTermEvidenceWriter {
  static let maximumCertificates = 64
  static let maximumResponses = 64
  static let maximumEvidenceBytes = 32 * 1_024 * 1_024

  public static func appendDSS(
    to source: ParsedPDF, options: PDFLongTermEvidenceOptions,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFLongTermEvidenceOutcome {
    let certificates = options.certificatesDER.filter { !$0.isEmpty }
    let ocsps = options.ocspResponsesDER.filter { !$0.isEmpty }
    let crls = options.crlsDER.filter { !$0.isEmpty }
    guard certificates.count <= maximumCertificates, ocsps.count <= maximumResponses,
      crls.count <= maximumResponses
    else {
      throw PDFError(.limitExceeded, "The DSS evidence has too many entries")
    }
    let totalBytes = (certificates + ocsps + crls).reduce(0) { $0 + $1.count }
      + (options.timestampTokenDER?.count ?? 0)
    guard totalBytes <= maximumEvidenceBytes else {
      throw PDFError(.limitExceeded, "The DSS evidence exceeds the configured size")
    }
    for der in certificates {
      _ = try X509CertificateFields.parse(der, limits: limits)
    }
    let signatures = try PDFSignatureInventory.signatures(in: source.graph, limits: limits)
    let signed = signatures.filter { $0.kind == .signature }
    let target: PDFSignature
    if let name = options.signatureFieldName {
      guard let found = signed.first(where: { $0.fieldName == name }) else {
        throw PDFError(.malformed, "The signed signature field \(name) does not exist")
      }
      target = found
    } else {
      guard signed.count == 1 else {
        throw PDFError(.malformed, "Specify the signature field to key the DSS evidence for")
      }
      target = signed[0]
    }
    guard case .string(let contentsData)? = target.dictionary[PDFName("Contents")] else {
      throw PDFError(.malformed, "The target signature has no /Contents value")
    }
    let vriKey = PDFDSSInventory.signatureContentsHash(contentsData)
    try appendDSS(
      to: source, vriKey: vriKey, certificatesDER: certificates, ocspResponsesDER: ocsps,
      crlsDER: crls, timestampTokenDER: options.timestampTokenDER,
      timestampTime: options.timestampTime, limits: limits)
    let data = try appendData(
      to: source, vriKey: vriKey, certificatesDER: certificates,
      ocspResponsesDER: ocsps, crlsDER: crls, timestampTokenDER: options.timestampTokenDER,
      timestampTime: options.timestampTime, limits: limits)
    let reopened = try PDFParser.parse(data, limits: limits)
    let inventory = PDFDSSInventory.parse(in: reopened.graph, limits: limits)
    return PDFLongTermEvidenceOutcome(data: data, vriKey: vriKey, inventory: inventory)
  }

  static func appendDSS(
    to source: ParsedPDF, vriKey: String, certificatesDER: [Data],
    ocspResponsesDER: [Data], crlsDER: [Data], timestampTokenDER: Data?,
    timestampTime: Date?, limits: PDFLimits
  ) throws {
    _ = try appendData(
      to: source, vriKey: vriKey, certificatesDER: certificatesDER,
      ocspResponsesDER: ocspResponsesDER, crlsDER: crlsDER,
      timestampTokenDER: timestampTokenDER, timestampTime: timestampTime, limits: limits)
  }

  static func appendData(
    to source: ParsedPDF, vriKey: String, certificatesDER: [Data],
    ocspResponsesDER: [Data], crlsDER: [Data], timestampTokenDER: Data?,
    timestampTime: Date?, limits: PDFLimits
  ) throws -> Data {
    guard case .reference(let rootID)? = source.graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = source.graph.objects[rootID]
    else {
      throw PDFError(.malformed, "The catalog is missing for DSS embedding")
    }
    var next = try PDFIncrementalAppend.nextIdentifier(in: source.graph)
    var changed: [PDFObjectID: PDFValue] = [:]
    if (certificatesDER + ocspResponsesDER + crlsDER).reduce(0, { $0 + $1.count })
      > limits.streamBytes * 4
    {
      throw PDFError(.limitExceeded, "The DSS evidence exceeds the stream limit")
    }
    func addStream(_ bytes: Data) -> PDFValue {
      let id = next
      next = PDFObjectID(next.number + 1)
      changed[id] = .stream(PDFStream(bytes: bytes))
      return .reference(id)
    }
    let certificateReferences = certificatesDER.map(addStream)
    let ocspReferences = ocspResponsesDER.map(addStream)
    let crlReferences = crlsDER.map(addStream)
    let timestampReference = timestampTokenDER.map(addStream)

    var dss: [PDFName: PDFValue] = [:]
    var dssID: PDFObjectID?
    switch catalog[PDFName("DSS")] {
    case .reference(let id)?:
      if case .dictionary(let existing)? = source.graph.objects[id], dssID == nil {
        dss = existing
        dssID = id
      }
    case .dictionary(let existing)?:
      dss = existing
    default:
      break
    }
    dss[PDFName("Certs")] = .array(
      PDFIncrementalAppend.streamArray(dss[PDFName("Certs")], in: source.graph)
        + certificateReferences)
    dss[PDFName("OCSPs")] = .array(
      PDFIncrementalAppend.streamArray(dss[PDFName("OCSPs")], in: source.graph)
        + ocspReferences)
    dss[PDFName("CRLs")] = .array(
      PDFIncrementalAppend.streamArray(dss[PDFName("CRLs")], in: source.graph)
        + crlReferences)
    var vri: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? =
      PDFIncrementalAppend.resolved(dss[PDFName("VRI")], in: source.graph)
    {
      vri = existing
    }
    var entry: [PDFName: PDFValue] = [:]
    if case .dictionary(let existing)? = PDFIncrementalAppend.resolved(
      vri[PDFName(vriKey)], in: source.graph)
    {
      entry = existing
    }
    entry[PDFName("Cert")] = .array(
      PDFIncrementalAppend.streamArray(entry[PDFName("Cert")], in: source.graph)
        + certificateReferences)
    entry[PDFName("OCSP")] = .array(
      PDFIncrementalAppend.streamArray(entry[PDFName("OCSP")], in: source.graph)
        + ocspReferences)
    entry[PDFName("CRL")] = .array(
      PDFIncrementalAppend.streamArray(entry[PDFName("CRL")], in: source.graph)
        + crlReferences)
    if let timestampReference {
      entry[PDFName("TS")] = timestampReference
    }
    if let timestampTime {
      entry[PDFName("TU")] = .string(Data(PDFSigningWriter.pdfDate(timestampTime).utf8))
    }
    vri[PDFName(vriKey)] = .dictionary(entry)
    dss[PDFName("VRI")] = .dictionary(vri)
    if let dssID {
      changed[dssID] = .dictionary(dss)
    } else {
      let id = next
      next = PDFObjectID(next.number + 1)
      changed[id] = .dictionary(dss)
      catalog[PDFName("DSS")] = .reference(id)
    }
    changed[rootID] = .dictionary(catalog)
    return try PDFIncrementalAppend.append(changed, to: source, limits: limits)
  }
}

/// SIG-04: options for an archival ETSI.RFC3161 document timestamp.
public struct PDFDocumentTimestampOptions: Sendable, Equatable {
  public let fieldName: String
  public let reservationBytes: Int
  public let reason: String?
  public let signingTime: Date

  public init(
    fieldName: String = "DocumentTimestamp", reservationBytes: Int = 16_384,
    reason: String? = nil, signingTime: Date = Date()
  ) {
    self.fieldName = fieldName
    self.reservationBytes = reservationBytes
    self.reason = reason
    self.signingTime = signingTime
  }
}

/// SIG-04: the new PDF revision plus the verified archival timestamp evidence.
public struct PDFDocumentTimestampOutcome: Sendable {
  public let data: Data
  public let evidence: PDFTimestampEvidence
  public let tokenDER: Data

  public init(data: Data, evidence: PDFTimestampEvidence, tokenDER: Data) {
    self.data = data
    self.evidence = evidence
    self.tokenDER = tokenDER
  }
}

/// SIG-04: append an ETSI.RFC3161 document timestamp covering the whole file
/// (including earlier DSS evidence). The TSA is supplied by the caller through
/// the SIG-02 TimestampAuthority seam; earlier bytes are never rewritten.
public enum PDFDocumentTimestampWriter {
  public static func appendDocumentTimestamp(
    to source: ParsedPDF, authority: any TimestampAuthority,
    options: PDFDocumentTimestampOptions = PDFDocumentTimestampOptions(),
    trustedAnchors: [SecCertificate] = [], limits: PDFLimits = PDFLimits()
  ) throws -> PDFDocumentTimestampOutcome {
    guard options.reservationBytes >= 1_024, options.reservationBytes <= 1_048_576 else {
      throw PDFError(.malformed, "The document timestamp reservation is out of bounds")
    }
    guard case .reference(let rootID)? = source.graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = source.graph.objects[rootID]
    else {
      throw PDFError(.malformed, "The catalog is missing for a document timestamp")
    }
    var next = try PDFIncrementalAppend.nextIdentifier(in: source.graph)
    let signatureID = next
    next = PDFObjectID(next.number + 1)
    var changed: [PDFObjectID: PDFValue] = [:]

    var signatureDictionary: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("DocTimeStamp")),
      PDFName("Filter"): .name(PDFName("Adobe.PPKLite")),
      PDFName("SubFilter"): .name(PDFName("ETSI.RFC3161")),
      PDFName("ByteRange"): .array([
        .integer(0), .integer(Int64(PDFSigningWriter.byteRangeSentinel)),
        .integer(Int64(PDFSigningWriter.byteRangeSentinel)),
        .integer(Int64(PDFSigningWriter.byteRangeSentinel)),
      ]),
      PDFName("Contents"): .string(Data(repeating: 0, count: options.reservationBytes)),
      PDFName("M"): .string(Data(PDFSigningWriter.pdfDate(options.signingTime).utf8)),
      PDFName("FT"): .name(PDFName("Sig")),
      PDFName("T"): .string(Data(options.fieldName.utf8)),
    ]
    if let reason = options.reason {
      signatureDictionary[PDFName("Reason")] = .string(Data(reason.utf8))
    }
    changed[signatureID] = .dictionary(signatureDictionary)

    var acroForm: [PDFName: PDFValue]
    var acroFormID: PDFObjectID?
    switch catalog[PDFName("AcroForm")] {
    case .reference(let id)?:
      if case .dictionary(let existing)? = source.graph.objects[id] {
        acroForm = existing
        acroFormID = id
      } else {
        acroForm = [:]
      }
    case .dictionary(let existing)?:
      acroForm = existing
    default:
      acroForm = [:]
    }
    var fields = PDFIncrementalAppend.streamArray(acroForm[PDFName("Fields")], in: source.graph)
    fields.append(.reference(signatureID))
    acroForm[PDFName("Fields")] = .array(fields)
    acroForm[PDFName("SigFlags")] = .integer(3)
    if let acroFormID {
      changed[acroFormID] = .dictionary(acroForm)
    } else {
      let id = next
      next = PDFObjectID(next.number + 1)
      changed[id] = .dictionary(acroForm)
      catalog[PDFName("AcroForm")] = .reference(id)
    }
    changed[rootID] = .dictionary(catalog)

    var output = try PDFIncrementalAppend.append(changed, to: source, limits: limits)
    let sentinelText = "\(PDFSigningWriter.byteRangeSentinel) "
      + "\(PDFSigningWriter.byteRangeSentinel) "
      + "\(PDFSigningWriter.byteRangeSentinel)"
    let sentinelPattern = Data(sentinelText.utf8)
    guard let sentinelRange = output.range(of: sentinelPattern) else {
      throw PDFError(.malformed, "The document timestamp ByteRange markers are missing")
    }
    let zeros = Data(repeating: 0x30, count: options.reservationBytes * 2)
    guard let contentsRange = output.range(
      of: zeros, in: sentinelRange.upperBound..<output.count)
    else {
      throw PDFError(.malformed, "The document timestamp contents reservation is missing")
    }
    let lt = contentsRange.lowerBound - 1
    let gt = contentsRange.upperBound
    guard lt >= 0, output[lt] == 0x3C, gt < output.count, output[gt] == 0x3E else {
      throw PDFError(.malformed, "The document timestamp contents reservation is malformed")
    }
    // Patch the fixed-width ByteRange before computing the digest; the patched
    // values are part of the covered bytes and no longer change afterwards.
    let values = [lt, gt + 1, output.count - (gt + 1)]
    var position = sentinelRange.lowerBound
    for value in values {
      let text = String(format: "%010d", value)
      output.replaceSubrange(position..<(position + 10), with: Data(text.utf8))
      position += 11
    }
    var covered = Data(output[0..<lt])
    covered.append(output[(gt + 1)...])
    let digest = Data(SHA256.hash(data: covered))
    let request = TimestampRequest(imprint: digest, nonce: TimestampRequest.randomNonce())
    let response = try authority.timestampResponse(
      for: TimestampRequestBuilder.build(request))
    let validation = TimestampValidator.validateResponse(
      response, request: request, trustedAnchors: trustedAnchors,
      validationTime: options.signingTime, limits: limits)
    guard let token = validation.tokenDER, validation.evidence.isEmbeddable else {
      throw PDFError(
        .malformed,
        "The timestamp authority did not return embeddable evidence: "
          + validation.evidence.details.joined(separator: "; "))
    }
    guard token.count * 2 <= options.reservationBytes * 2 else {
      throw PDFError(.malformed, "The timestamp token does not fit the reservation")
    }
    let hex = token.map { String(format: "%02X", $0) }.joined()
    let padded = hex + String(repeating: "0", count: options.reservationBytes * 2 - hex.count)
    output.replaceSubrange((lt + 1)..<gt, with: Data(padded.utf8))
    return PDFDocumentTimestampOutcome(
      data: output, evidence: validation.evidence, tokenDER: token)
  }
}
