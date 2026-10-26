import Foundation
import PDFCore

// MARK: - Permission set

/// SIG-08: the doc-level permissions a reusable security preset can grant.
/// The eight flags map to PDF 1.7 Table 22 permission bits; reserved bits are
/// always written per the standard and never exposed here.
public struct PDFPermissionSet: Sendable, Equatable, Hashable, Codable {
  /// Bit 3: print at low resolution.
  public var printing: Bool
  /// Bit 12: print at high resolution (requires printing).
  public var highQualityPrinting: Bool
  /// Bit 4: modify document content and structure.
  public var modification: Bool
  /// Bit 5: copy or extract content other than accessibility extraction.
  public var copying: Bool
  /// Bit 6: add or modify annotations.
  public var annotation: Bool
  /// Bit 9: fill existing form fields.
  public var formFilling: Bool
  /// Bit 10: extract content for accessibility.
  public var extraction: Bool
  /// Bit 11: assemble pages (insert, rotate, delete, split).
  public var assembly: Bool

  public init(
    printing: Bool = false, highQualityPrinting: Bool = false,
    modification: Bool = false, copying: Bool = false,
    annotation: Bool = false, formFilling: Bool = false,
    extraction: Bool = false, assembly: Bool = false
  ) {
    self.printing = printing
    self.highQualityPrinting = highQualityPrinting
    self.modification = modification
    self.copying = copying
    self.annotation = annotation
    self.formFilling = formFilling
    self.extraction = extraction
    self.assembly = assembly
  }

  /// Every permission granted (the PDF default P = -4 profile).
  public static let unrestricted = PDFPermissionSet(
    printing: true, highQualityPrinting: true, modification: true, copying: true,
    annotation: true, formFilling: true, extraction: true, assembly: true)

  /// View-only with accessibility extraction, which readers expect to keep
  /// usable for assistive technology.
  public static let viewOnly = PDFPermissionSet(extraction: true)

  /// Read the semantic permission bits from an encryption dictionary's /P.
  public init(permissions: Int32) {
    printing = permissions & 4 != 0
    modification = permissions & 8 != 0
    copying = permissions & 16 != 0
    annotation = permissions & 32 != 0
    formFilling = permissions & 256 != 0
    extraction = permissions & 512 != 0
    assembly = permissions & 1024 != 0
    highQualityPrinting = permissions & 2048 != 0
  }

  /// The semantic permission bits without the reserved positions.
  public var permissionsValue: Int32 {
    var value: Int32 = 0
    if printing { value |= 4 }
    if modification { value |= 8 }
    if copying { value |= 16 }
    if annotation { value |= 32 }
    if formFilling { value |= 256 }
    if extraction { value |= 512 }
    if assembly { value |= 1024 }
    if highQualityPrinting { value |= 2048 }
    return value
  }

  /// Table 22 requires bits 1-2 clear and bits 7-8 and 13-32 set. This is the
  /// exact value `PDFEncryptionOptions` writes.
  public var normalizedPermissions: Int32 {
    (permissionsValue | Int32(bitPattern: 0xFFFF_F0C0)) & ~Int32(3)
  }

  /// High-quality printing is meaningful only when printing is allowed; an
  /// authored preset may not contradict itself.
  public var isValid: Bool { !highQualityPrinting || printing }

  /// The allowed permission categories in display order, for presets and
  /// policy reports.
  public var allowedSummary: [String] {
    var result: [String] = []
    if printing {
      result.append(highQualityPrinting ? "Print (high quality)" : "Print (standard quality)")
    }
    if modification { result.append("Modify content") }
    if copying { result.append("Copy or extract content") }
    if annotation { result.append("Add or edit comments") }
    if formFilling { result.append("Fill existing forms") }
    if extraction { result.append("Accessibility extraction") }
    if assembly { result.append("Assemble pages") }
    return result
  }

  public var isUnrestricted: Bool { self == Self.unrestricted }
}

// MARK: - Protected operations

/// SIG-08: one operation whose allowance must be enforced consistently for a
/// protected document. Permission-gated operations derive their answer from
/// `PDFPermissionSet`; security-changing operations require owner
/// authentication and never apply to encrypted signing.
public enum PDFProtectedOperation: String, CaseIterable, Sendable, Codable, Hashable {
  case printLowResolution
  case printHighResolution
  case copyContent
  case extractForAccessibility
  case modifyContent
  case annotate
  case fillForms
  case assemblePages
  case signDocument
  case changeSecurity
  case removeProtection
  case exportDecryptedCopy

  public var title: String {
    switch self {
    case .printLowResolution: return "Print"
    case .printHighResolution: return "Print at high quality"
    case .copyContent: return "Copy or extract content"
    case .extractForAccessibility: return "Accessibility extraction"
    case .modifyContent: return "Modify content"
    case .annotate: return "Add or edit comments"
    case .fillForms: return "Fill forms"
    case .assemblePages: return "Assemble pages"
    case .signDocument: return "Digitally sign"
    case .changeSecurity: return "Change password or permissions"
    case .removeProtection: return "Remove protection"
    case .exportDecryptedCopy: return "Export an unencrypted copy"
    }
  }

  /// The permission bit this operation needs, when it is permission-gated.
  /// Content modification grants annotate/fill/assemble as well, per Table 22.
  public func isAllowed(by permissions: PDFPermissionSet) -> Bool {
    switch self {
    case .printLowResolution: return permissions.printing
    case .printHighResolution: return permissions.printing && permissions.highQualityPrinting
    case .copyContent: return permissions.copying
    case .extractForAccessibility: return permissions.extraction
    case .modifyContent: return permissions.modification
    case .annotate: return permissions.modification || permissions.annotation
    case .fillForms: return permissions.modification || permissions.formFilling
    case .assemblePages: return permissions.modification || permissions.assembly
    case .signDocument, .changeSecurity, .removeProtection, .exportDecryptedCopy:
      return false
    }
  }
}

/// SIG-08: the decision for one protected operation, with the reason a write
/// or export path would refuse it.
public enum PDFSecurityDecision: Sendable, Equatable {
  case allowed
  case denied(reason: String)

  public var isAllowed: Bool { if case .allowed = self { return true }; return false }

  public var refusalReason: String? {
    if case .denied(let reason) = self { return reason }
    return nil
  }
}

/// SIG-08: one displayable row of the current document's security policy.
public struct PDFSecurityPolicyRow: Sendable, Equatable {
  public let operation: PDFProtectedOperation
  public let decision: PDFSecurityDecision
  /// True when only the owner password (not a permission bit) unlocks this.
  public let ownerRequired: Bool

  public init(
    operation: PDFProtectedOperation, decision: PDFSecurityDecision, ownerRequired: Bool
  ) {
    self.operation = operation
    self.decision = decision
    self.ownerRequired = ownerRequired
  }
}

/// SIG-08: the read-only security policy of one opened document. The policy is
/// derived from the parsed encryption dictionary and whether the supplied
/// password authenticated as the owner; it is the single place callers ask
/// whether an operation is permitted, so export/decryption/signing restrictions
/// cannot drift between panels.
public struct PDFDocumentSecurityPolicy: Sendable, Equatable {
  public let encryption: PDFEncryptionInfo?
  public let isOwner: Bool

  public init(encryption: PDFEncryptionInfo?, isOwner: Bool) {
    self.encryption = encryption
    self.isOwner = isOwner
  }

  /// Read the policy from a parsed document. A protected document that has
  /// not been authenticated (`encryptionIsOwner` nil) is treated as a user
  /// session, never as the owner.
  public init(parsed: ParsedPDF) {
    self.init(encryption: parsed.encryption, isOwner: parsed.encryptionIsOwner ?? false)
  }

  public var isEncrypted: Bool { encryption != nil }

  /// The semantic permissions; nil for an unencrypted document.
  public var permissions: PDFPermissionSet? {
    encryption.map { PDFPermissionSet(permissions: $0.permissions) }
  }

  public var profile: PDFEncryptionInfo.Profile? { encryption?.profile }

  /// Editing a protected document requires the owner password or the
  /// modification permission. This matches `PDFEncryptionState.allowsEditing`
  /// and the session gate the App uses for edits.
  public var editSessionAllowed: Bool {
    guard let encryption else { return true }
    return isOwner || encryption.allowsModification
  }

  /// Signing an encrypted document is refused by the signing writer; this is
  /// a declared profile limit, not a permission bit.
  public var signingAllowed: Bool { !isEncrypted }

  /// Password/permission changes, removal and decrypted exports require the
  /// owner password on a protected document.
  public var securityChangeRequiresOwner: Bool { isEncrypted }

  public func decision(for operation: PDFProtectedOperation) -> PDFSecurityDecision {
    guard let encryption else {
      switch operation {
      case .removeProtection, .exportDecryptedCopy, .changeSecurity:
        return .denied(
          reason: "This document is not encrypted; there is no protection to change or "
            + "remove.")
      default:
        return .allowed
      }
    }
    switch operation {
    case .signDocument:
      return .denied(
        reason: "Signing an encrypted document is outside the supported profile; "
          + "export an authorized unencrypted copy first.")
    case .changeSecurity, .removeProtection, .exportDecryptedCopy:
      if isOwner { return .allowed }
      return .denied(
        reason: "The owner password is required to change protection or export "
          + "unencrypted content from this document.")
    default:
      if isOwner { return .allowed }
      let permissions = PDFPermissionSet(permissions: encryption.permissions)
      if operation.isAllowed(by: permissions) { return .allowed }
      return .denied(
        reason: "This document's security policy does not permit: \(operation.title).")
    }
  }

  public func allows(_ operation: PDFProtectedOperation) -> Bool {
    decision(for: operation).isAllowed
  }

  /// Every operation with its decision, for the policy panel and tests.
  public var rows: [PDFSecurityPolicyRow] {
    PDFProtectedOperation.allCases.map { operation in
      PDFSecurityPolicyRow(
        operation: operation, decision: decision(for: operation),
        ownerRequired: isEncrypted && securityChangeRequiresOwner
          && (operation == .changeSecurity || operation == .removeProtection
            || operation == .exportDecryptedCopy))
    }
  }

  /// A short attributed summary for panels.
  public var summary: String {
    guard let encryption else { return "This document is not encrypted." }
    let owner = isOwner ? "owner password accepted" : "user password accepted"
    let profile: String
    switch encryption.profile {
    case .aes256: profile = "AES-256 (V5/R6)"
    case .aes256Revision5: profile = "AES-256 (V5/R5)"
    case .aes128: profile = "AES-128 (V4/R4)"
    case .rc4_128: profile = "RC4 128-bit"
    case .rc4_40: profile = "RC4 40-bit"
    }
    let allowed = PDFPermissionSet(permissions: encryption.permissions).allowedSummary
    let permissionText = allowed.isEmpty
      ? "no permissions granted"
      : allowed.joined(separator: ", ")
    let metadata = encryption.encryptMetadata ? "metadata encrypted" : "metadata unencrypted"
    return "\(profile); \(owner); \(permissionText); \(metadata)."
  }
}

// MARK: - Recipient encryption decision

/// SIG-08: security handlers the reader can distinguish before any password
/// is tested.
public enum PDFSecurityHandlerKind: String, Sendable, Equatable {
  case standard
  case publicKey
  case unknown

  public var displayName: String {
    switch self {
    case .standard: return "Standard password security"
    case .publicKey: return "Certificate-recipient (public-key) security"
    case .unknown: return "Unknown security handler"
    }
  }

  public init(filter: String) {
    switch filter {
    case "Standard": self = .standard
    case "Adobe.PubSec": self = .publicKey
    default: self = .unknown
    }
  }
}

/// SIG-08 decision record: certificate-recipient encryption is deliberately
/// not included in this release. The roadmap row says "if required"; the
/// declared profile keeps the password-based Standard security handler, so a
/// recipient-key handler is refused explicitly instead of being approximated.
public enum PDFRecipientEncryptionProfile {
  public static let isSupported = false

  public static let decision =
    "Certificate-recipient (public-key) encryption is not supported in this release. "
      + "sPDF writes AES-256 (V5/R6) Standard password security and reads the Standard "
      + "handler only; a public-key handler is detected and refused before any password "
      + "or recipient key is used. Password/permission presets cover the supported "
      + "security policy."

  public static let refusalReason =
    "This file uses certificate-recipient (public-key) encryption, which is outside "
      + "the supported Standard password security profile. sPDF cannot open it for "
      + "editing or validation."

  public static func handlerKind(forFilter filter: String) -> PDFSecurityHandlerKind {
    PDFSecurityHandlerKind(filter: filter)
  }
}
