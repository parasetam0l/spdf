import Foundation
import PDFCore

// MARK: - Password requirement

/// SIG-08: how a preset expects its passwords. The preset never stores a
/// password; callers resolve one at export time or from the explicit
/// Keychain reference below.
public enum PDFSecurityPasswordRequirement: String, Sendable, Codable, CaseIterable, Hashable {
  /// The file prompts for an open (user) password; an owner password is
  /// optional unless the preset requires a separate one.
  case userPasswordRequired
  /// The file opens without a password but carries restricted permissions;
  /// the owner password is mandatory and must differ from the empty user
  /// password so protection cannot be removed by merely opening the file.
  case openWithoutPasswordOwnerRequired

  public var title: String {
    switch self {
    case .userPasswordRequired: return "Open password required"
    case .openWithoutPasswordOwnerRequired: return "Opens without a password; owner required"
    }
  }

  public var detail: String {
    switch self {
    case .userPasswordRequired:
      return "Readers ask for the open password; the owner password is needed to change "
        + "protection."
    case .openWithoutPasswordOwnerRequired:
      return "Readers open the file without asking, apply the restricted permissions, and "
        + "require the owner password to change them."
    }
  }
}

/// SIG-08: an explicit, non-secret pointer to a Keychain item that may hold a
/// preset's open password. The preset JSON contains only these labels; the
/// secret lives in the login Keychain and is written only when the user asks
/// to reuse the password.
public struct PDFSecurityCredentialReference: Sendable, Equatable, Hashable, Codable {
  public static let keychainService = "com.parasetam0l.spdf.security-preset"
  public static let maximumLabelLength = 128

  /// Stable identifier (the preset id or a caller-chosen account suffix).
  public let identifier: String
  /// A display label such as the preset name; never contains the password.
  public let displayName: String

  public init(identifier: String, displayName: String) {
    self.identifier = identifier
    self.displayName = displayName
  }

  public func validate() throws {
    let trimmedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty, trimmedID == identifier,
      identifier.count <= PDFSecurityCredentialReference.maximumLabelLength
    else {
      throw PDFError(.malformed, "A stored credential identifier must be non-empty and bounded")
    }
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, trimmedName == displayName,
      displayName.count <= PDFSecurityCredentialReference.maximumLabelLength
    else {
      throw PDFError(.malformed, "A stored credential label must be non-empty and bounded")
    }
  }
}

// MARK: - Reusable preset

/// SIG-08: a reusable password/permission preset. A preset carries the
/// permission bits, the password *requirement*, metadata/embedded-file
/// options and optionally a Keychain reference; it never carries a password.
public struct PDFSecurityPreset: Sendable, Equatable, Codable, Identifiable {
  public static let maximumNameLength = 80
  public static let maximumDetailLength = 300
  public static let maximumIdentifierLength = 64
  /// Revision 6 hashes at most 127 password bytes; longer input would be
  /// truncated silently, so the preset profile refuses it instead.
  public static let maximumPasswordBytes = 127

  public let id: String
  public let name: String
  public let detail: String
  public let permissions: PDFPermissionSet
  public let passwordRequirement: PDFSecurityPasswordRequirement
  /// When true the owner password is mandatory and must differ from the user
  /// password. This is required for a no-open-password preset.
  public let requiresSeparateOwnerPassword: Bool
  public let encryptMetadata: Bool
  public let unencryptedEmbeddedFiles: Bool
  /// Optional Keychain pointer for a reused open password (labels only).
  public let storedCredential: PDFSecurityCredentialReference?
  public let isBuiltIn: Bool

  public init(
    id: String, name: String, detail: String, permissions: PDFPermissionSet,
    passwordRequirement: PDFSecurityPasswordRequirement = .userPasswordRequired,
    requiresSeparateOwnerPassword: Bool = true,
    encryptMetadata: Bool = true, unencryptedEmbeddedFiles: Bool = false,
    storedCredential: PDFSecurityCredentialReference? = nil, isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.permissions = permissions
    self.passwordRequirement = passwordRequirement
    self.requiresSeparateOwnerPassword = requiresSeparateOwnerPassword
    self.encryptMetadata = encryptMetadata
    self.unencryptedEmbeddedFiles = unencryptedEmbeddedFiles
    self.storedCredential = storedCredential
    self.isBuiltIn = isBuiltIn
  }

  public var passwordSummary: String {
    var text = passwordRequirement.title
    if requiresSeparateOwnerPassword {
      text += "; separate owner password required"
    } else {
      text += "; owner password optional (defaults to the open password)"
    }
    if let storedCredential {
      text += "; reuses the Keychain credential \"\(storedCredential.displayName)\""
    }
    return text
  }

  public var canReuseStoredPassword: Bool { storedCredential != nil }

  /// The built-in presets shipped with the app. Passwords are never part of
  /// these values; they only declare what the caller must collect.
  public static let builtIns: [PDFSecurityPreset] = [
    PDFSecurityPreset(
      id: "encrypt-only", name: "Encrypt only",
      detail:
        "AES-256 encryption with no permission restrictions. An owner password is "
          + "required so readers cannot change or remove protection unnoticed.",
      permissions: .unrestricted, isBuiltIn: true),
    PDFSecurityPreset(
      id: "view-only", name: "View only",
      detail:
        "Readers may view the document and use accessibility extraction only; "
          + "printing, copying, editing and form filling are denied.",
      permissions: .viewOnly, isBuiltIn: true),
    PDFSecurityPreset(
      id: "print-standard", name: "Print (standard quality)",
      detail:
        "Printing is allowed at standard resolution; high-quality printing, copying, "
          + "editing, comments and form filling are denied.",
      permissions: PDFPermissionSet(printing: true), isBuiltIn: true),
    PDFSecurityPreset(
      id: "print-high", name: "Print (high quality)",
      detail:
        "Printing at high resolution is allowed; copying, editing, comments and form "
          + "filling are denied.",
      permissions: PDFPermissionSet(printing: true, highQualityPrinting: true),
      isBuiltIn: true),
    PDFSecurityPreset(
      id: "review", name: "Review and comment",
      detail:
        "Printing, comments, form filling and accessibility extraction are allowed; "
          + "content editing, copying and page assembly are denied.",
      permissions: PDFPermissionSet(
        printing: true, annotation: true, formFilling: true, extraction: true),
      isBuiltIn: true),
    PDFSecurityPreset(
      id: "forms", name: "Fill forms only",
      detail:
        "Printing, filling existing form fields and accessibility extraction are "
          + "allowed; editing, copying and page assembly are denied.",
      permissions: PDFPermissionSet(printing: true, formFilling: true, extraction: true),
      isBuiltIn: true),
    PDFSecurityPreset(
      id: "restricted-no-password", name: "Restrict without an open password",
      detail:
        "The file opens without a password but carries view/print restrictions; the "
          + "owner password is mandatory to change or remove protection.",
      permissions: PDFPermissionSet(printing: true, extraction: true),
      passwordRequirement: .openWithoutPasswordOwnerRequired,
      requiresSeparateOwnerPassword: true, isBuiltIn: true),
  ]

  /// Validate the authored choices before anything is written.
  public func validate() throws {
    guard id == id.trimmingCharacters(in: .whitespacesAndNewlines),
      (1...Self.maximumIdentifierLength).contains(id.count),
      id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }),
      id.first != "-", !id.hasSuffix("-")
    else {
      throw PDFError(
        .malformed,
        "A preset id must be 1-\(Self.maximumIdentifierLength) lowercase letters, digits "
          + "or hyphens")
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, trimmedName == name,
      name.count <= Self.maximumNameLength
    else {
      throw PDFError(
        .malformed,
        "A preset name must be non-empty, trimmed and at most \(Self.maximumNameLength) "
          + "characters")
    }
    let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedDetail == detail, detail.count <= Self.maximumDetailLength else {
      throw PDFError(
        .malformed,
        "A preset description must be trimmed and at most \(Self.maximumDetailLength) "
          + "characters")
    }
    guard permissions.isValid else {
      throw PDFError(
        .malformed,
        "The preset's permissions are inconsistent: high-quality printing requires "
          + "printing to be allowed")
    }
    switch passwordRequirement {
    case .userPasswordRequired:
      if let storedCredential { try storedCredential.validate() }
    case .openWithoutPasswordOwnerRequired:
      guard requiresSeparateOwnerPassword else {
        throw PDFError(
          .malformed,
          "A preset that opens without a password must require a separate owner password")
      }
      guard storedCredential == nil else {
        throw PDFError(
          .malformed,
          "A preset that opens without a password cannot reuse an open-password "
            + "credential")
      }
    }
  }

  /// Resolve the caller-supplied credentials into the core encryption options.
  /// A stored Keychain reference is resolved by the caller (`resolvedStored`),
  /// so the secret never passes through this model.
  public func encryptionOptions(
    userPassword: String?, ownerPassword: String?,
    resolvedStoredPassword: String? = nil
  ) throws -> PDFEncryptionOptions {
    try validate()
    let resolvedUser: String
    switch passwordRequirement {
    case .userPasswordRequired:
      if let userPassword, !userPassword.isEmpty {
        resolvedUser = userPassword
      } else if let storedCredential {
        guard let resolvedStoredPassword, !resolvedStoredPassword.isEmpty else {
          throw PDFError(
            .malformed,
            "The preset \"\(name)\" reuses a stored credential, but no stored password "
              + "for \"\(storedCredential.displayName)\" was resolved")
        }
        resolvedUser = resolvedStoredPassword
      } else {
        throw PDFError(
          .malformed, "The preset \"\(name)\" requires an open (user) password")
      }
    case .openWithoutPasswordOwnerRequired:
      guard userPassword?.isEmpty ?? true else {
        throw PDFError(
          .malformed,
          "The preset \"\(name)\" opens without a password; do not provide a user "
            + "password")
      }
      resolvedUser = ""
    }
    let resolvedOwner: String?
    if requiresSeparateOwnerPassword {
      guard let ownerPassword, !ownerPassword.isEmpty else {
        throw PDFError(
          .malformed, "The preset \"\(name)\" requires a separate owner password")
      }
      guard ownerPassword != resolvedUser else {
        throw PDFError(
          .malformed,
          "The owner password must differ from the open password for the preset "
            + "\"\(name)\"")
      }
      resolvedOwner = ownerPassword
    } else {
      resolvedOwner = (ownerPassword?.isEmpty ?? true) ? nil : ownerPassword
    }
    for password in [resolvedUser, resolvedOwner ?? ""]
    where password.utf8.count > Self.maximumPasswordBytes {
      throw PDFError(
        .limitExceeded,
        "Passwords are limited to \(Self.maximumPasswordBytes) UTF-8 bytes in this "
          + "profile")
    }
    return PDFEncryptionOptions(
      userPassword: resolvedUser, ownerPassword: resolvedOwner,
      permissions: permissions.normalizedPermissions,
      encryptMetadata: encryptMetadata, unencryptedEmbeddedFiles: unencryptedEmbeddedFiles)
  }

  /// Write a protected full rewrite with this preset.
  public func apply(
    to graph: PDFGraph, userPassword: String?, ownerPassword: String?,
    resolvedStoredPassword: String? = nil, limits: PDFLimits = PDFLimits()
  ) throws -> Data {
    try PDFWriter.write(
      graph,
      encryption: try encryptionOptions(
        userPassword: userPassword, ownerPassword: ownerPassword,
        resolvedStoredPassword: resolvedStoredPassword),
      limits: limits)
  }

  /// Compare the authored preset with the encryption inventory a reader
  /// recovered from the written bytes. Empty means the profile matches.
  public func verify(against parsed: ParsedPDF) -> [String] {
    guard let info = parsed.encryption else { return ["The written document is not encrypted"] }
    var mismatches: [String] = []
    if info.profile != .aes256 {
      mismatches.append("Expected the AES-256 (V5/R6) profile, found \(info.profile.rawValue)")
    }
    if info.version != 5 || info.revision != 6 {
      mismatches.append("Expected V5/R6, found V\(info.version)/R\(info.revision)")
    }
    if info.permissions != permissions.normalizedPermissions {
      mismatches.append(
        "Expected permission bits \(permissions.normalizedPermissions), found "
          + "\(info.permissions)")
    }
    if info.encryptMetadata != encryptMetadata {
      mismatches.append(
        "Expected encryptMetadata=\(encryptMetadata), found \(info.encryptMetadata)")
    }
    let embeddedFilesAreIdentity = info.embeddedFileFilterName == "Identity"
    if embeddedFilesAreIdentity != unencryptedEmbeddedFiles {
      mismatches.append(
        "Expected unencryptedEmbeddedFiles=\(unencryptedEmbeddedFiles), found "
          + "\(embeddedFilesAreIdentity)")
    }
    return mismatches
  }
}

// MARK: - Preset store

/// SIG-08: the deterministic, validated preset collection. Only custom
/// presets are persisted; built-in presets always come from code, so a stored
/// file can never redefine them. The JSON contains no secrets (a reused
/// password is represented by `PDFSecurityCredentialReference` labels only).
public struct PDFSecurityPresetStore: Sendable, Equatable, Codable {
  public static let currentVersion = 1
  public static let maximumCustomPresets = 32

  public private(set) var version: Int
  public private(set) var customPresets: [PDFSecurityPreset]

  public init() {
    version = Self.currentVersion
    customPresets = []
  }

  public init(version: Int, customPresets: [PDFSecurityPreset]) throws {
    self.version = version
    self.customPresets = customPresets
    try validateContents()
  }

  public var builtInPresets: [PDFSecurityPreset] { PDFSecurityPreset.builtIns }

  /// Built-ins first, then custom presets in insertion order.
  public var allPresets: [PDFSecurityPreset] { builtInPresets + customPresets }

  public func preset(id: String) -> PDFSecurityPreset? {
    allPresets.first { $0.id == id }
  }

  public mutating func add(_ preset: PDFSecurityPreset) throws {
    try validateCustom(preset)
    guard !isBuiltInIdentifier(preset.id) else {
      throw PDFError(.malformed, "\"\(preset.id)\" is a built-in preset id")
    }
    guard customPresets.count < Self.maximumCustomPresets else {
      throw PDFError(
        .limitExceeded,
        "At most \(Self.maximumCustomPresets) custom presets are supported")
    }
    guard !allPresets.contains(where: { $0.id == preset.id }) else {
      throw PDFError(.malformed, "A preset with the id \"\(preset.id)\" already exists")
    }
    let duplicateName = allPresets.contains {
      $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
    }
    guard !duplicateName else {
      throw PDFError(.malformed, "A preset with the name \"\(preset.name)\" already exists")
    }
    customPresets.append(preset)
  }

  public mutating func replace(_ preset: PDFSecurityPreset) throws {
    try validateCustom(preset)
    guard !isBuiltInIdentifier(preset.id) else {
      throw PDFError(.malformed, "Built-in presets cannot be replaced; duplicate one first")
    }
    guard let index = customPresets.firstIndex(where: { $0.id == preset.id }) else {
      throw PDFError(.malformed, "No custom preset with the id \"\(preset.id)\" exists")
    }
    guard !allPresets.contains(where: {
      $0.id != preset.id && $0.name.caseInsensitiveCompare(preset.name) == .orderedSame
    }) else {
      throw PDFError(.malformed, "A preset with the name \"\(preset.name)\" already exists")
    }
    customPresets[index] = preset
  }

  public mutating func remove(id: String) throws {
    guard !isBuiltInIdentifier(id) else {
      throw PDFError(.malformed, "Built-in presets cannot be removed")
    }
    guard customPresets.contains(where: { $0.id == id }) else {
      throw PDFError(.malformed, "No custom preset with the id \"\(id)\" exists")
    }
    customPresets.removeAll { $0.id == id }
  }

  public mutating func resetCustomPresets() { customPresets = [] }

  /// Deterministic JSON suitable for a user-preset file.
  public func encoded() throws -> Data {
    try validateContents()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public init(data: Data) throws {
    let decoded = try JSONDecoder().decode(PDFSecurityPresetStore.self, from: data)
    version = decoded.version
    customPresets = decoded.customPresets
    try validateContents()
  }

  private func isBuiltInIdentifier(_ id: String) -> Bool {
    PDFSecurityPreset.builtIns.contains { $0.id == id }
  }

  private func validateCustom(_ preset: PDFSecurityPreset) throws {
    guard !preset.isBuiltIn else {
      throw PDFError(.malformed, "A custom preset must not claim to be built in")
    }
    try preset.validate()
  }

  private func validateContents() throws {
    guard version == Self.currentVersion else {
      throw PDFError(
        .unsupported,
        "Security preset data is version \(version); this release supports version "
          + "\(Self.currentVersion)")
    }
    guard customPresets.count <= Self.maximumCustomPresets else {
      throw PDFError(
        .limitExceeded,
        "At most \(Self.maximumCustomPresets) custom presets are supported")
    }
    var ids = Set(PDFSecurityPreset.builtIns.map(\.id))
    var names = Set(PDFSecurityPreset.builtIns.map { $0.name.lowercased() })
    for preset in customPresets {
      guard !preset.isBuiltIn else {
        throw PDFError(.malformed, "Stored custom presets must not be marked built in")
      }
      try preset.validate()
      guard ids.insert(preset.id).inserted else {
        throw PDFError(.malformed, "Duplicate preset id \"\(preset.id)\" in stored data")
      }
      guard names.insert(preset.name.lowercased()).inserted else {
        throw PDFError(.malformed, "Duplicate preset name \"\(preset.name)\" in stored data")
      }
    }
  }
}
