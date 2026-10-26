import Foundation
import PDFCore
import Security

// MARK: - DocMDP permission profile

/// SIG-04: a DocMDP certification permission (PDF 1.7 Table 254). sPDF can
/// author the P1-P3 profile and enforces the standard allowance when it adds a
/// later signature. The declared limits and the representative workflows are
/// in `PDFSigningWorkflowGuide`; the app never claims an unsupported profile.
public enum PDFDocMDPPermission: Int, CaseIterable, Sendable, Equatable, Comparable {
  /// P1: the certified document is final; later signatures are refused.
  case noChanges = 1
  /// P2: filling existing form fields and signing existing signature fields.
  case formFillAndSign = 2
  /// P3: P2 plus annotations/comments.
  case formFillSignAndAnnotate = 3

  public var permissionValue: Int { rawValue }

  public var shortName: String { "P\(rawValue)" }

  /// The standard change categories this permission allows after
  /// certification. Every other `PDFCertificationChange` is disallowed.
  public var allowedChanges: [PDFCertificationChange] {
    switch self {
    case .noChanges:
      return []
    case .formFillAndSign:
      return [.fillExistingFormFields, .signExistingSignatureFields]
    case .formFillSignAndAnnotate:
      return [.fillExistingFormFields, .signExistingSignatureFields, .addAnnotations]
    }
  }

  public func allows(_ change: PDFCertificationChange) -> Bool {
    allowedChanges.contains(change)
  }

  public var summary: String {
    switch self {
    case .noChanges:
      return "P1 locks the document after certification: no later signature or change is allowed."
    case .formFillAndSign:
      return "P2 permits filling existing form fields and signing existing signature fields."
    case .formFillSignAndAnnotate:
      return "P3 permits P2 changes plus annotations and comments."
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// A permission read from an existing signature, when it is one this
  /// profile understands. Values outside 1...3 are reported as unsupported
  /// instead of being rounded or treated as a permission.
  public init?(permissionValue: Int) { self.init(rawValue: permissionValue) }
}

/// SIG-04: one kind of change a certification permission may or may not
/// allow. The first three are the standard DocMDP allowances; the remaining
/// categories are never allowed by a certification and are listed so the UI
/// can state exactly what is denied.
public enum PDFCertificationChange: String, CaseIterable, Sendable, Equatable {
  case fillExistingFormFields
  case signExistingSignatureFields
  case addAnnotations
  case createNewSignatureFields
  case modifyExistingContent
  case pageOrDocumentStructure

  public var displayName: String {
    switch self {
    case .fillExistingFormFields: return "Fill existing form fields"
    case .signExistingSignatureFields: return "Sign existing signature fields"
    case .addAnnotations: return "Add or edit annotations and comments"
    case .createNewSignatureFields: return "Create new signature fields"
    case .modifyExistingContent: return "Modify existing page content"
    case .pageOrDocumentStructure: return "Change pages, metadata or document structure"
    }
  }

  /// True for the three categories the PDF DocMDP profile can allow.
  public var isStandardCertificationAllowance: Bool {
    switch self {
    case .fillExistingFormFields, .signExistingSignatureFields, .addAnnotations: return true
    case .createNewSignatureFields, .modifyExistingContent, .pageOrDocumentStructure:
      return false
    }
  }
}

// MARK: - Authoring limits

/// SIG-04: the DocMDP/FieldMDP choices sPDF is allowed to author. An empty
/// certification permission means an ordinary signature; an empty field lock
/// means no FieldMDP transform. The writer refuses everything else instead of
/// writing a dictionary another reader could misread.
public struct PDFSignatureAuthoring: Sendable, Equatable {
  /// The 1...256 bounded FieldMDP name list.
  public static let maximumLockedFields = 256
  /// Bounded UTF-8 length for one FieldMDP field name.
  public static let maximumFieldNameBytes = 256

  public let certificationPermission: PDFDocMDPPermission?
  public let fieldLock: PDFSignatureFieldLock?

  public init(
    certificationPermission: PDFDocMDPPermission? = nil,
    fieldLock: PDFSignatureFieldLock? = nil
  ) {
    self.certificationPermission = certificationPermission
    self.fieldLock = fieldLock
  }

  public static let plain = PDFSignatureAuthoring()

  public var isCertification: Bool { certificationPermission != nil }

  /// The limits in user-facing form, shared by the authoring UI and the
  /// workflow guide.
  public static let declaredLimits = [
    "Certification is limited to the first signature of an unsigned, unencrypted document.",
    "At most one DocMDP declaration is authored; a catalog /Perms /DocMDP entry is never replaced.",
    "FieldMDP supports All, Include and Exclude with at most 256 existing form fields.",
    "Every FieldMDP name must be an existing, unique form-field name of at most 256 UTF-8 bytes.",
    "All takes no field names; Include and Exclude require at least one name.",
    "The signed signature declares its transform in /Reference; the field carries /Lock "
      + "and the catalog carries /Perms /DocMDP for the certification.",
  ]

  /// Validate this authoring request against a document before any bytes are
  /// produced. Every failure is a declared profile limit, not a crash or a
  /// silently weakened signature.
  public func validate(in graph: PDFGraph, limits: PDFLimits = PDFLimits()) throws {
    if certificationPermission != nil {
      guard graph.trailer[PDFName("Encrypt")] == nil else {
        throw PDFError(
          .unsupported, "Certification can be authored only on an unencrypted document")
      }
      let signatures = try PDFSignatureInventory.signatures(in: graph, limits: limits)
      guard signatures.isEmpty else {
        throw PDFError(
          .unsupported,
          "A certification signature must be the document's first signature; "
            + "this document already has \(signatures.count) signature(s)")
      }
      guard !Self.declaresDocMDP(in: graph) else {
        throw PDFError(
          .unsupported,
          "The document catalog already declares a DocMDP permission; "
            + "sPDF refuses to replace an existing certification declaration")
      }
    }
    if let fieldLock {
      try Self.validate(fieldLock: fieldLock, in: graph, limits: limits)
    }
  }

  /// Validate one FieldMDP lock against the document's current form fields.
  public static func validate(
    fieldLock: PDFSignatureFieldLock, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws {
    switch fieldLock.action {
    case .all:
      guard fieldLock.fields.isEmpty else {
        throw PDFError(
          .malformed,
          "The All field-lock action locks every field and must not name individual fields")
      }
    case .include, .exclude:
      guard !fieldLock.fields.isEmpty else {
        throw PDFError(
          .malformed,
          "The \(fieldLock.action.rawValue) field-lock action needs at least one field name")
      }
      guard fieldLock.fields.count <= maximumLockedFields else {
        throw PDFError(
          .limitExceeded,
          "A field lock may name at most \(maximumLockedFields) fields")
      }
      var seen = Set<String>()
      for name in fieldLock.fields {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name, !name.isEmpty else {
          throw PDFError(
            .malformed,
            "Field-lock names must be non-empty and must not carry leading or trailing whitespace")
        }
        guard !name.contains("\n"), !name.contains("\r") else {
          throw PDFError(.malformed, "Field-lock names must not contain line breaks")
        }
        guard name.utf8.count <= maximumFieldNameBytes else {
          throw PDFError(
            .limitExceeded,
            "Field-lock names are limited to \(maximumFieldNameBytes) UTF-8 bytes")
        }
        guard seen.insert(name).inserted else {
          throw PDFError(.malformed, "Field-lock names must be unique")
        }
      }
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let existing = Set(try FormInventory.fields(in: graph, pageIDs: pageIDs).map(\.name))
      for name in fieldLock.fields where !existing.contains(name) {
        throw PDFError(
          .unsupported,
          "Field-lock names must refer to existing form fields; "
            + "\"\(name)\" is not a form field in this document")
      }
    }
  }

  /// True when the catalog already carries a DocMDP reference, even without a
  /// readable signature (an external certifier's declaration is never replaced).
  static func declaresDocMDP(in graph: PDFGraph) -> Bool {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .dictionary(let permissions)? = FontValue.resolve(
        catalog[PDFName("Perms")], in: graph)
    else { return false }
    return permissions[PDFName("DocMDP")] != nil
  }
}

// MARK: - Certification report

/// SIG-04: one authored or inherited FieldMDP lock, with where it was read
/// from so the UI can explain the evidence instead of only the conclusion.
public struct PDFFieldMDPLockReport: Sendable, Equatable {
  public enum Source: String, Sendable, Equatable {
    case fieldDictionary
    case signatureTransform
  }

  public let signingFieldName: String?
  public let source: Source
  public let lock: PDFSignatureFieldLock

  public init(signingFieldName: String?, source: Source, lock: PDFSignatureFieldLock) {
    self.signingFieldName = signingFieldName
    self.source = source
    self.lock = lock
  }

  public var displayName: String {
    switch lock.action {
    case .all: return "All fields locked"
    case .include: return "Locked fields: " + lock.fields.joined(separator: ", ")
    case .exclude:
      return "All fields except " + lock.fields.joined(separator: ", ") + " locked"
    }
  }
}

/// SIG-04: the certification state of one document.
public enum PDFCertificationState: Sendable, Equatable {
  case notCertified
  case certified
  case multipleCertifications
  case unsupportedPermission(Int)
}

/// SIG-04: what the certification permits, which FieldMDP locks exist, and
/// what changed after the signed revision. Display-only: it never turns a
/// later change into a valid one and never reports a missing permission as P3.
public struct PDFCertificationReport: Sendable, Equatable {
  public let state: PDFCertificationState
  public let permission: PDFDocMDPPermission?
  public let certificationFieldName: String?
  public let certificationSignature: PDFSignature?
  public let allowedChanges: [PDFCertificationChange]
  public let deniedChanges: [PDFCertificationChange]
  public let fieldLocks: [PDFFieldMDPLockReport]
  public let laterChanges: [String]
  public let validation: PDFSignatureValidation?

  public var isCertified: Bool { state == .certified }

  public func allows(_ change: PDFCertificationChange) -> Bool {
    allowedChanges.contains(change)
  }

  /// Locks that cover a field name, from either the field dictionary or a
  /// signature transform.
  public func locks(covering fieldName: String) -> [PDFFieldMDPLockReport] {
    fieldLocks.filter { $0.lock.locks(fieldName) }
  }

  public var lockedFieldNames: [String] {
    Array(Set(fieldLocks.flatMap(\.lock.fields))).sorted()
  }

  public static func read(
    source: Data, graph: PDFGraph, trustedAnchors: [SecCertificate] = [],
    limits: PDFLimits = PDFLimits()
  ) -> PDFCertificationReport {
    let fields = (try? PDFSignatureFieldInventory.fields(in: graph, limits: limits)) ?? []
    let signatures = (try? PDFSignatureInventory.signatures(in: graph, limits: limits)) ?? []
    let certifications = signatures.filter { $0.docMDPPermission != nil }
    var state = PDFCertificationState.notCertified
    var permission: PDFDocMDPPermission?
    var certificationSignature: PDFSignature?
    if certifications.count > 1 {
      state = .multipleCertifications
    } else if let certification = certifications.first {
      certificationSignature = certification
      if let raw = certification.docMDPPermission,
        let value = PDFDocMDPPermission(rawValue: raw)
      {
        permission = value
        state = .certified
      } else {
        state = .unsupportedPermission(certification.docMDPPermission ?? 0)
      }
    }
    let allowed: [PDFCertificationChange]
    switch state {
    case .notCertified:
      allowed = PDFCertificationChange.allCases
    case .certified:
      allowed = permission?.allowedChanges ?? []
    case .multipleCertifications, .unsupportedPermission:
      allowed = []
    }
    var locks: [PDFFieldMDPLockReport] = []
    for field in fields {
      guard let lock = field.lock else { continue }
      let entry = PDFFieldMDPLockReport(
        signingFieldName: field.name, source: .fieldDictionary, lock: lock)
      if !locks.contains(entry) { locks.append(entry) }
    }
    for signature in signatures {
      for lock in PDFSignatureSigningPolicy.fieldMDPLocks(signature: signature, in: graph) {
        let entry = PDFFieldMDPLockReport(
          signingFieldName: signature.fieldName, source: .signatureTransform, lock: lock)
        if !locks.contains(entry) { locks.append(entry) }
      }
    }
    var laterChanges: [String] = []
    if !signatures.isEmpty {
      let revisions = PDFSignedRevisionReport.build(
        source: source, graph: graph, trustedAnchors: trustedAnchors, limits: limits)
      laterChanges = revisions.changesSinceLastSignature
      if revisions.finalUncoveredByteCount > 0 {
        laterChanges.append(
          "\(revisions.finalUncoveredByteCount) byte(s) after the last signature are not covered")
      }
    }
    let validation = certificationSignature.map {
      PDFSignatureValidator.validate(
        $0, source: source, finalGraph: graph, trustedAnchors: trustedAnchors, limits: limits)
    }
    return PDFCertificationReport(
      state: state, permission: permission,
      certificationFieldName: certificationSignature?.fieldName,
      certificationSignature: certificationSignature,
      allowedChanges: allowed,
      deniedChanges: PDFCertificationChange.allCases.filter { !allowed.contains($0) },
      fieldLocks: locks, laterChanges: laterChanges, validation: validation)
  }
}
