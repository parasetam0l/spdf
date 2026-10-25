import CryptoKit
import Foundation
import PDFCore
import Security

// MARK: - Signer identity

/// SIG-06: a signer identity decoded from the signature's own certificate, so
/// the UI can name who signed even before (or without) cryptographic
/// verification. All fields are display data; validity and trust remain
/// separate statuses on PDFSignatureValidation.
public struct PDFSignatureSignerIdentity: Sendable, Equatable {
  public let commonName: String?
  public let organization: String?
  public let organizationalUnit: String?
  public let emailAddress: String?
  public let issuerCommonName: String?
  /// Uppercase hexadecimal X.509 serial number bytes.
  public let serialNumberHex: String
  public let notBefore: Date?
  public let notAfter: Date?
  /// Uppercase hexadecimal SHA-256 fingerprint of the DER certificate.
  public let sha256Fingerprint: String

  /// The raw Name DER of the certificate's issuer, used to match a CMS
  /// SignerInfo identifier.
  let issuerDER: Data
  /// The raw DER INTEGER (tag, length and content) of the serial number.
  let serialDER: Data
  /// Subject key identifier extension value, when present.
  let subjectKeyIdentifier: Data?

  public init(
    commonName: String?, organization: String?, organizationalUnit: String?,
    emailAddress: String?, issuerCommonName: String?, serialNumberHex: String,
    notBefore: Date?, notAfter: Date?, sha256Fingerprint: String,
    issuerDER: Data = Data(), serialDER: Data = Data(), subjectKeyIdentifier: Data? = nil
  ) {
    self.commonName = commonName
    self.organization = organization
    self.organizationalUnit = organizationalUnit
    self.emailAddress = emailAddress
    self.issuerCommonName = issuerCommonName
    self.serialNumberHex = serialNumberHex
    self.notBefore = notBefore
    self.notAfter = notAfter
    self.sha256Fingerprint = sha256Fingerprint
    self.issuerDER = issuerDER
    self.serialDER = serialDER
    self.subjectKeyIdentifier = subjectKeyIdentifier
  }

  /// A compact one-line identity for lists and signature dictionary metadata.
  public var displayName: String {
    let name = commonName ?? emailAddress ?? organization ?? "Unknown signer"
    guard let organization, commonName != nil, organization != commonName else { return name }
    return "\(name) (\(organization))"
  }

  /// Decode an X.509 certificate into display identity data. Returns nil for
  /// a certificate this bounded parser does not understand.
  public static func certificateDetails(_ certificate: SecCertificate) -> Self? {
    let der = Data(SecCertificateCopyData(certificate) as Data)
    return certificateDetails(der: der)
  }

  public static func certificateDetails(der: Data) -> Self? {
    X509Facts.parse(der: der)?.identity
  }
}

/// Bounded X.509 facts the signature profile needs: subject/issuer display
/// names, serial number, validity, and subject key identifier. Every read is
/// range-checked through DERReader; malformed certificates return nil.
struct X509Facts: Sendable, Equatable {
  let identity: PDFSignatureSignerIdentity

  static func parse(der: Data) -> X509Facts? {
    let bytes = [UInt8](der)
    let limits = PDFLimits()
    do {
      var outer = try DERReader(bytes: bytes)
      let certificate = try outer.readElement(limits: limits)
      guard certificate.tag == 0x30 else { return nil }
      var certificateReader = DERReader(
        bytes: bytes, offset: certificate.content.startIndex,
        end: certificate.content.endIndex)
      let tbs = try certificateReader.readElement(limits: limits)
      guard tbs.tag == 0x30 else { return nil }
      return try parseTBS(bytes: bytes, tbs: tbs, limits: limits)
    } catch {
      return nil
    }
  }

  private static func parseTBS(
    bytes: [UInt8], tbs: DERReader.Element, limits: PDFLimits
  ) throws -> X509Facts? {
    var reader = DERReader(
      bytes: bytes, offset: tbs.content.startIndex, end: tbs.content.endIndex)
    var element = try reader.readElement(limits: limits)
    if element.tag == 0xA0 {  // [0] EXPLICIT version
      element = try reader.readElement(limits: limits)
    }
    guard element.tag == 0x02 else { return nil }
    let serialDER = Data(bytes[element.start..<element.content.endIndex])
    let serialHex = element.content.map { String(format: "%02X", $0) }.joined()
    _ = try reader.readElement(limits: limits)  // signature AlgorithmIdentifier
    let issuerElement = try reader.readElement(limits: limits)
    guard issuerElement.tag == 0x30 else { return nil }
    let issuerDER = Data(bytes[issuerElement.start..<issuerElement.content.endIndex])
    let validity = try reader.readElement(limits: limits)
    guard validity.tag == 0x30 else { return nil }
    var validityReader = DERReader(
      bytes: bytes, offset: validity.content.startIndex, end: validity.content.endIndex)
    let notBeforeElement = try validityReader.readElement(limits: limits)
    let notAfterElement = try validityReader.readElement(limits: limits)
    let notBefore = DERReader.time(notBeforeElement.tag, notBeforeElement.content)
    let notAfter = DERReader.time(notAfterElement.tag, notAfterElement.content)
    let subjectElement = try reader.readElement(limits: limits)
    guard subjectElement.tag == 0x30 else { return nil }
    _ = try reader.readElement(limits: limits)  // SubjectPublicKeyInfo
    var subjectKeyIdentifier: Data?
    while !reader.isAtEnd {
      let extra = try reader.readElement(limits: limits)
      if extra.tag == 0xA3 {
        subjectKeyIdentifier = try extensions(bytes: bytes, element: extra, limits: limits)
      }
    }
    let subject = nameFields(bytes: bytes, element: subjectElement, limits: limits)
    let issuer = nameFields(bytes: bytes, element: issuerElement, limits: limits)
    let fingerprint = SHA256.hash(data: Data(bytes)).map {
      String(format: "%02X", $0)
    }.joined()
    let identity = PDFSignatureSignerIdentity(
      commonName: subject["2.5.4.3"], organization: subject["2.5.4.10"],
      organizationalUnit: subject["2.5.4.11"],
      emailAddress: subject["1.2.840.113549.1.9.1"],
      issuerCommonName: issuer["2.5.4.3"], serialNumberHex: serialHex,
      notBefore: notBefore, notAfter: notAfter, sha256Fingerprint: fingerprint,
      issuerDER: issuerDER, serialDER: serialDER,
      subjectKeyIdentifier: subjectKeyIdentifier)
    return X509Facts(identity: identity)
  }

  private static func extensions(
    bytes: [UInt8], element: DERReader.Element, limits: PDFLimits
  ) throws -> Data? {
    var reader = DERReader(
      bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
    let sequence = try reader.readElement(limits: limits)
    guard sequence.tag == 0x30 else { return nil }
    var extensionsReader = DERReader(
      bytes: bytes, offset: sequence.content.startIndex, end: sequence.content.endIndex)
    while !extensionsReader.isAtEnd {
      let extensionElement = try extensionsReader.readElement(limits: limits)
      guard extensionElement.tag == 0x30 else { continue }
      var fieldReader = DERReader(
        bytes: bytes, offset: extensionElement.content.startIndex,
        end: extensionElement.content.endIndex)
      let oidElement = try fieldReader.readElement(limits: limits)
      guard oidElement.tag == 0x06, DERReader.oid(oidElement.content) == "2.5.29.14" else {
        continue
      }
      var next = try fieldReader.readElement(limits: limits)
      if next.tag == 0x01 { next = try fieldReader.readElement(limits: limits) }
      guard next.tag == 0x04 else { continue }
      var octet = DERReader(
        bytes: bytes, offset: next.content.startIndex, end: next.content.endIndex)
      let inner = try octet.readElement(limits: limits)
      guard inner.tag == 0x04 else { continue }
      return Data(bytes[inner.content.startIndex..<inner.content.endIndex])
    }
    return nil
  }

  /// Decode a DER Name into a map keyed by OID (last occurrence wins).
  private static func nameFields(
    bytes: [UInt8], element: DERReader.Element, limits: PDFLimits
  ) -> [String: String] {
    var result: [String: String] = [:]
    guard element.tag == 0x30 else { return result }
    var reader = DERReader(
      bytes: bytes, offset: element.content.startIndex, end: element.content.endIndex)
    while !reader.isAtEnd {
      guard let set = try? reader.readElement(limits: limits), set.tag == 0x31 else { continue }
      var setReader = DERReader(
        bytes: bytes, offset: set.content.startIndex, end: set.content.endIndex)
      while !setReader.isAtEnd {
        guard let pair = try? setReader.readElement(limits: limits), pair.tag == 0x30 else {
          continue
        }
        var pairReader = DERReader(
          bytes: bytes, offset: pair.content.startIndex, end: pair.content.endIndex)
        guard let oid = try? pairReader.readElement(limits: limits), oid.tag == 0x06,
          let value = try? pairReader.readElement(limits: limits),
          let text = string(value, bytes: bytes)
        else { continue }
        result[DERReader.oid(oid.content)] = text
      }
    }
    return result
  }

  private static func string(_ element: DERReader.Element, bytes: [UInt8]) -> String? {
    let content = element.content
    switch element.tag {
    case 0x0C, 0x13, 0x16, 0x12:
      return String(decoding: content, as: UTF8.self)
    case 0x14:
      return String(data: Data(content), encoding: .isoLatin1)
    case 0x1E:
      let data = Data(content)
      guard data.count.isMultiple(of: 2) else { return nil }
      return String(data: data, encoding: .utf16BigEndian)
    default:
      return String(decoding: content, as: UTF8.self)
    }
  }
}

// MARK: - Signature fields

/// SIG-06: one signature field, signed or empty, with its placement and lock
/// facts. The field identity is the canonical AcroForm name.
public struct PDFSignatureFieldInfo: Sendable, Equatable {
  public let name: String
  public let fieldID: PDFObjectID?
  public let widgetID: PDFObjectID?
  public let pageIndex: Int?
  public let rect: [Double]?
  public let isSigned: Bool
  public let signatureObjectID: PDFObjectID?
  public let signature: PDFSignature?
  public let lock: PDFSignatureFieldLock?
  /// The DocMDP permission carried by this field's signature, when it is a
  /// certification signature.
  public let docMDPPermission: Int?

  public init(
    name: String, fieldID: PDFObjectID?, widgetID: PDFObjectID?, pageIndex: Int?,
    rect: [Double]?, isSigned: Bool, signatureObjectID: PDFObjectID?,
    signature: PDFSignature?, lock: PDFSignatureFieldLock?, docMDPPermission: Int?
  ) {
    self.name = name
    self.fieldID = fieldID
    self.widgetID = widgetID
    self.pageIndex = pageIndex
    self.rect = rect
    self.isSigned = isSigned
    self.signatureObjectID = signatureObjectID
    self.signature = signature
    self.lock = lock
    self.docMDPPermission = docMDPPermission
  }
}

/// SIG-06: PDF signature field lock (/Lock or FieldMDP transform parameters).
public struct PDFSignatureFieldLock: Sendable, Equatable {
  public enum Action: String, Sendable, Equatable {
    case all = "All"
    case include = "Include"
    case exclude = "Exclude"
  }

  public let action: Action
  public let fields: [String]

  public init(action: Action, fields: [String] = []) {
    self.action = action
    self.fields = fields
  }

  public init?(dictionary: [PDFName: PDFValue], in graph: PDFGraph) {
    let actionName: String?
    switch FontValue.resolve(dictionary[PDFName("Action")], in: graph) {
    case .name(let name)?:
      actionName = String(decoding: name.bytes, as: UTF8.self)
    case .string(let data)?:
      actionName = String(decoding: data, as: UTF8.self)
    default:
      actionName = nil
    }
    guard let actionName, let action = Action(rawValue: actionName) else { return nil }
    var fields: [String] = []
    if case .array(let values)? = FontValue.resolve(dictionary[PDFName("Fields")], in: graph) {
      for value in values {
        guard case .string(let data)? = FontValue.resolve(value, in: graph) else { continue }
        fields.append(String(decoding: data, as: UTF8.self))
      }
    }
    self.init(action: action, fields: fields)
  }

  /// Whether this lock covers a target field name.
  public func locks(_ fieldName: String) -> Bool {
    switch action {
    case .all: return true
    case .include: return fields.contains(fieldName)
    case .exclude: return !fields.contains(fieldName)
    }
  }
}

/// SIG-06: inventory every signature field (empty and signed) in document
/// order, with its lock and certification facts.
public enum PDFSignatureFieldInventory {
  public static func fields(in graph: PDFGraph, limits: PDFLimits = PDFLimits())
    throws -> [PDFSignatureFieldInfo]
  {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let formFields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let signatures = try PDFSignatureInventory.signatures(in: graph, limits: limits)
    let signaturesByID = Dictionary(
      uniqueKeysWithValues: signatures.compactMap { signature in
        signature.objectID.map { ($0, signature) }
      })
    return formFields.filter { $0.kind == .signature }.map { field in
      let valueID: PDFObjectID?
      switch field.value {
      case .reference(let id)?: valueID = id
      default: valueID = nil
      }
      let signature = valueID.flatMap { signaturesByID[$0] }
      var lock: PDFSignatureFieldLock?
      var fieldDictionary: [PDFName: PDFValue] = [:]
      if let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID] {
        fieldDictionary = dictionary
      }
      if case .dictionary(let lockDictionary)? = FontValue.resolve(
        fieldDictionary[PDFName("Lock")], in: graph)
      {
        lock = PDFSignatureFieldLock(dictionary: lockDictionary, in: graph)
      }
      if case .dictionary(let valueDictionary)? = field.value,
        case .dictionary(let lockDictionary)? = FontValue.resolve(
          valueDictionary[PDFName("Lock")], in: graph)
      {
        lock = lock ?? PDFSignatureFieldLock(dictionary: lockDictionary, in: graph)
      }
      let widget = field.widgets.first
      return PDFSignatureFieldInfo(
        name: field.name, fieldID: field.fieldID, widgetID: widget?.objectID,
        pageIndex: widget?.pageIndex, rect: widget?.rect, isSigned: signature != nil,
        signatureObjectID: valueID, signature: signature, lock: lock,
        docMDPPermission: signature?.docMDPPermission)
    }.sorted { $0.name < $1.name }
  }

  /// The certification signature, when the document carries exactly one.
  public static func certificationSignature(
    signatures: [PDFSignature]
  ) -> PDFSignature? {
    signatures.first { $0.docMDPPermission != nil }
  }
}

// MARK: - Permitted incremental signatures

/// SIG-06: what the caller wants to sign.
public enum PDFSignatureSigningTarget: Sendable, Equatable {
  /// Fill an existing empty signature field (an incremental signature).
  case existingField(name: String)
  /// Create a new signature field and sign it.
  case newField(name: String)

  public var fieldName: String {
    switch self {
    case .existingField(let name), .newField(let name): return name
    }
  }
}

/// SIG-06: the permission decision for adding one incremental signature.
public enum PDFSignatureSigningDecision: Sendable, Equatable {
  case allowed
  case refused(reason: String)

  public var isAllowed: Bool {
    if case .allowed = self { return true }
    return false
  }

  public var refusalReason: String? {
    if case .refused(let reason) = self { return reason }
    return nil
  }
}

/// SIG-06: a conservative, declared permission profile for incremental
/// signatures. It reads existing certification (DocMDP) permissions and field
/// locks and refuses changes the document explicitly prohibits; it never
/// silently downgrades a certified document.
public enum PDFSignatureSigningPolicy {
  public static func decision(
    in graph: PDFGraph, target: PDFSignatureSigningTarget,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFSignatureSigningDecision {
    let fields = try PDFSignatureFieldInventory.fields(in: graph, limits: limits)
    let signatures = try PDFSignatureInventory.signatures(in: graph, limits: limits)
    let name = target.fieldName
    switch target {
    case .existingField:
      guard let field = fields.first(where: { $0.name == name }) else {
        return .refused(reason: "Signature field \"\(name)\" does not exist")
      }
      guard !field.isSigned else {
        return .refused(reason: "Signature field \"\(name)\" is already signed")
      }
    case .newField:
      guard !fields.contains(where: { $0.name == name }) else {
        return .refused(reason: "A field named \"\(name)\" already exists")
      }
    }

    let certifications = signatures.filter { $0.docMDPPermission != nil }
    if certifications.count > 1 {
      return .refused(
        reason: "The document has multiple certification signatures; adding another is not safe")
    }
    if let certification = certifications.first {
      guard let permission = certification.docMDPPermission else {
        return .refused(reason: "The certification signature has no usable permission value")
      }
      switch permission {
      case 1:
        return .refused(
          reason: "The document is certified with permission 1 (no changes allowed); "
            + "a later signature would invalidate the certification")
      case 2:
        if case .newField = target {
          return .refused(
            reason: "The document is certified with permission 2, which permits signing "
              + "existing fields only; creating a new field would invalidate the certification")
        }
      case 3:
        break
      default:
        return .refused(
          reason: "Certification permission \(permission) is outside the supported 1-3 profile")
      }
    }

    for field in fields where field.isSigned {
      if let lock = field.lock, lock.locks(name) {
        return .refused(
          reason: "The signed field \"\(field.name)\" locks \"\(name)\"; a later signature "
            + "may not fill or add that field")
      }
      if let signature = field.signature {
        for lock in fieldMDPLocks(signature: signature, in: graph) where lock.locks(name) {
          return .refused(
            reason: "A FieldMDP lock from \"\(field.name)\" covers \"\(name)\"; the document "
              + "does not permit that change")
        }
      }
    }
    return .allowed
  }

  static func fieldMDPLocks(
    signature: PDFSignature, in graph: PDFGraph
  ) -> [PDFSignatureFieldLock] {
    guard case .array(let references)? = signature.dictionary[PDFName("Reference")] else {
      return []
    }
    var locks: [PDFSignatureFieldLock] = []
    for reference in references {
      guard case .dictionary(let referenceDictionary) = reference,
        referenceDictionary[PDFName("TransformMethod")] == .name(PDFName("FieldMDP")),
        case .dictionary(let parameters)? = FontValue.resolve(
          referenceDictionary[PDFName("TransformParams")], in: graph)
      else { continue }
      if let lock = PDFSignatureFieldLock(dictionary: parameters, in: graph) {
        locks.append(lock)
      }
    }
    return locks
  }
}

// MARK: - Signed revision report

/// SIG-06: one signed revision in document order, with what changed since the
/// previous signed revision and whether later revisions exist.
public struct PDFSignedRevision: Sendable, Equatable {
  /// 1-based order sorted by covered byte range end.
  public let index: Int
  public let signature: PDFSignature
  public let validation: PDFSignatureValidation
  public let signerIdentity: PDFSignatureSignerIdentity?
  public let signedByteCount: Int
  public let coverageEnd: Int
  public let isCertification: Bool
  public let docMDPPermission: Int?
  public let laterRevisions: Bool
  public let addedObjectCount: Int
  public let modifiedObjectCount: Int
  public let removedObjectCount: Int
  /// Human-readable change summary since the previous signed revision (empty
  /// for the first signature).
  public let changesSincePrevious: [String]

  public var fieldName: String? { signature.fieldName }
}

/// SIG-06: the whole-document signature/revision inspection model.
public struct PDFSignedRevisionReport: Sendable, Equatable {
  public let revisions: [PDFSignedRevision]
  /// Changes after the last signature (unsigned changes).
  public let changesSinceLastSignature: [String]
  public let finalUncoveredByteCount: Int

  public var hasLaterChanges: Bool { !changesSinceLastSignature.isEmpty }
  public var signatureCount: Int { revisions.count }

  public static func build(
    source: Data, graph: PDFGraph, trustedAnchors: [SecCertificate] = [],
    limits: PDFLimits = PDFLimits()
  ) -> PDFSignedRevisionReport {
    let signatures = (try? PDFSignatureInventory.signatures(in: graph, limits: limits)) ?? []
    var entries: [(signature: PDFSignature, coverageEnd: Int, signedBytes: Int, graph: PDFGraph?)] =
      []
    for signature in signatures.prefix(32) {
      var byteRangeDetails: [String] = []
      let info = PDFSignatureValidator.validateByteRange(
        signature, bytes: [UInt8](source), details: &byteRangeDetails)
      guard let info else { continue }
      var signedBytes = 0
      var index = 0
      while index + 1 < signature.byteRange.count {
        signedBytes += max(0, signature.byteRange[index + 1])
        index += 2
      }
      let signedGraph = PDFSignatureValidator.signedRevisionGraph(
        gap: info, signature: signature, bytes: [UInt8](source), limits: limits)
      entries.append((signature, info.coverageEnd, signedBytes, signedGraph))
    }
    entries.sort { $0.coverageEnd < $1.coverageEnd }
    var revisions: [PDFSignedRevision] = []
    var previousGraph: PDFGraph?
    for (offset, entry) in entries.enumerated() {
      let validation = PDFSignatureValidator.validate(
        entry.signature, source: source, finalGraph: graph, trustedAnchors: trustedAnchors,
        limits: limits)
      let diff: RevisionDiff
      if let previousGraph, let signedGraph = entry.graph {
        diff = RevisionDiff.between(from: previousGraph, to: signedGraph, source: source)
      } else {
        diff = RevisionDiff()
      }
      let isLast = offset == entries.count - 1
      revisions.append(
        PDFSignedRevision(
          index: offset + 1, signature: entry.signature, validation: validation,
          signerIdentity: validation.signerIdentity, signedByteCount: entry.signedBytes,
          coverageEnd: entry.coverageEnd,
          isCertification: entry.signature.docMDPPermission != nil,
          docMDPPermission: entry.signature.docMDPPermission,
          laterRevisions: entry.coverageEnd < source.count
            || (isLast ? false : (entries[offset + 1].coverageEnd > entry.coverageEnd)),
          addedObjectCount: diff.added, modifiedObjectCount: diff.modified,
          removedObjectCount: diff.removed,
          changesSincePrevious: diff.summary))
      previousGraph = entry.graph
    }
    var finalChanges: [String] = []
    var finalUncovered = 0
    if let last = entries.last {
      finalUncovered = max(0, source.count - last.coverageEnd)
      if let lastGraph = last.graph {
        let excluded = last.signature.objectID.map { Set([$0]) } ?? []
        let diff = RevisionDiff.between(
          from: lastGraph, to: graph, source: source, excluding: excluded)
        finalChanges = diff.summary
      } else if finalUncovered > 0 {
        finalChanges = ["later bytes after the last signature could not be compared"]
      }
    }
    return PDFSignedRevisionReport(
      revisions: revisions, changesSinceLastSignature: finalChanges,
      finalUncoveredByteCount: finalUncovered)
  }

}

/// Object-level change summary between two revisions.
struct RevisionDiff: Sendable, Equatable {
  var added = 0
  var modified = 0
  var removed = 0
  var summary: [String] = []

  static func between(
    from old: PDFGraph, to new: PDFGraph, source: Data,
    excluding excluded: Set<PDFObjectID> = []
  ) -> RevisionDiff {
    var diff = RevisionDiff()
    var categories: [String: Int] = [:]
    func classify(_ id: PDFObjectID, _ value: PDFValue, _ verb: String) {
      let category = objectCategory(value)
      categories["\(category) \(verb)", default: 0] += 1
      if category == "page", case .dictionary(let oldDictionary)? = old.objects[id],
        case .dictionary(let newDictionary)? = new.objects[id]
      {
        if oldDictionary[PDFName("Rotate")] != newDictionary[PDFName("Rotate")] {
          categories["page rotation changed", default: 0] += 1
        }
      }
    }
    for (id, value) in new.objects where !excluded.contains(id) && old.objects[id] == nil {
      diff.added += 1
      classify(id, value, "added")
    }
    for (id, _) in old.objects where !excluded.contains(id) && new.objects[id] == nil {
      diff.removed += 1
    }
    for (id, value) in new.objects {
      guard !excluded.contains(id), let previous = old.objects[id], previous != value else {
        continue
      }
      diff.modified += 1
      classify(id, value, "modified")
    }
    diff.summary = categories.keys.sorted().prefix(12).map { key in
      "\(categories[key] ?? 1) \(key)"
    }
    return diff
  }

  private static func objectCategory(_ value: PDFValue) -> String {
    guard case .dictionary(let dictionary) = value else {
      if case .stream = value { return "content stream" }
      return "object"
    }
    if let type = dictionary[PDFName("Type")], case .name(let name) = type {
      switch String(decoding: name.bytes, as: UTF8.self) {
      case "Sig", "DocTimeStamp": return "digital signature"
      case "Page": return "page"
      case "Catalog": return "catalog"
      case "Font": return "font"
      case "Annot", "Widget": return "annotation"
      case "AcroForm": return "form"
      default: break
      }
    }
    if dictionary[PDFName("Subtype")] == .name(PDFName("Widget")) {
      return dictionary[PDFName("FT")] == .name(PDFName("Sig"))
        ? "signature field" : "annotation"
    }
    if dictionary[PDFName("FT")] == .name(PDFName("Sig")) { return "signature field" }
    if dictionary[PDFName("Fields")] != nil { return "form" }
    return "object"
  }
}
