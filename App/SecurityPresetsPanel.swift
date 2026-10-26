import AppKit
import Combine
import DocumentSession
import Foundation
import PDFCore
import PDFEditing
import Security
import SwiftUI
import UniformTypeIdentifiers

/// SIG-08: reusable security presets, the read-only security policy report,
/// and the password-change / protection-removal flows. The Lead wires four
/// menu items (hooks at the bottom); no stored state is added to SPDFDocument.
/// Passwords are never written to the preset file: a reused password lives in
/// the login Keychain behind an explicit, non-secret credential reference.
@MainActor
enum SecurityPresetsFlow {
  // MARK: Preset manager

  /// Browse, create, edit and apply reusable password/permission presets.
  static func presentPresets(for document: SPDFDocument) {
    let model = SecurityPresetListModel(store: SecurityPresetFileStore.load())
    while true {
      let alert = NSAlert()
      alert.messageText = "Security Presets"
      alert.alertStyle = .informational
      alert.informativeText =
        "Reusable password and permission presets. Applying one writes a new "
          + "AES-256 (V5/R6) encrypted copy; the open document is not modified."
      let hosting = NSHostingView(rootView: SecurityPresetsView(model: model))
      hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
      alert.accessoryView = hosting
      alert.addButton(withTitle: "Apply Selected...")
      alert.addButton(withTitle: "Edit Selected...")
      alert.addButton(withTitle: "Done")
      let response = alert.runModal()
      if response == .alertThirdButtonReturn { return }
      guard let selected = model.selectedPreset else {
        presentAlert("Select a Preset", "Choose a preset in the list first.")
        continue
      }
      if response == .alertFirstButtonReturn {
        if apply(selected, to: document, model: model) { return }
        continue
      }
      editSelected(selected, model: model)
    }
  }

  /// Present and edit one selected preset. Built-ins are duplicated first so
  /// the shipped defaults can never be overwritten.
  private static func editSelected(
    _ preset: PDFSecurityPreset, model: SecurityPresetListModel
  ) {
    let draft = SecurityPresetDraft(preset: preset)
    let editor = SecurityPresetEditorView(draft: draft)
    let hosting = NSHostingView(rootView: editor)
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
    let alert = NSAlert()
    alert.messageText = preset.isBuiltIn ? "Duplicate and Edit Preset" : "Edit Preset"
    alert.informativeText = preset.isBuiltIn
      ? "The built-in preset stays unchanged; the edited copy is a new custom preset."
      : "Edit the custom preset. Its id does not change."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
      do {
        let updated = draft.makePreset()
        if preset.isBuiltIn {
          try model.store.add(updated)
          model.selectedID = updated.id
        } else {
          try model.store.replace(updated)
        }
        try model.persist()
      } catch {
        presentError("The preset could not be saved", error)
      }
    case .alertSecondButtonReturn:
      guard !preset.isBuiltIn else { return }
      do {
        try model.store.remove(id: preset.id)
        if model.selectedID == preset.id { model.selectedID = nil }
        try model.persist()
      } catch {
        presentError("The preset could not be deleted", error)
      }
    default:
      break
    }
  }

  // MARK: Encrypted export

  /// Resolve credentials, write an encrypted copy through the shared verified
  /// writer, and confirm the written protection from the parsed bytes.
  private static func apply(
    _ preset: PDFSecurityPreset, to document: SPDFDocument,
    model: SecurityPresetListModel
  ) -> Bool {
    guard document.canEditContent else {
      presentAlert(
        "Encrypted Export Unavailable",
        document.contentEditingRestrictionNotice
          ?? "Save an unlocked, unencrypted copy before exporting an encrypted derivative.")
      return false
    }
    guard let selection = requestCredentials(for: preset, model: model) else { return false }
    let options: PDFEncryptionOptions
    do {
      options = try preset.encryptionOptions(
        userPassword: selection.userPassword,
        ownerPassword: selection.ownerPassword,
        resolvedStoredPassword: selection.resolvedStoredPassword)
    } catch {
      presentError("The preset could not be applied", error)
      return false
    }
    guard let destination = chooseDestination(
      for: document, suffix: "-protected", title: "Export Encrypted Copy")
    else { return false }
    do {
      try document.writeEncryptedCopy(
        to: destination, userPassword: options.userPassword,
        ownerPassword: options.ownerPassword, permissions: options.permissions,
        encryptMetadata: options.encryptMetadata,
        unencryptedEmbeddedFiles: options.unencryptedEmbeddedFiles)
      let written = try Data(contentsOf: destination)
      let parsed = try PDFParser.parse(
        written, password: options.userPassword,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
      let mismatches = preset.verify(against: parsed)
      guard mismatches.isEmpty else {
        throw PDFError(
          .malformed, "The written protection did not match the preset: "
            + mismatches.joined(separator: "; "))
      }
      if selection.reusePassword, !preset.isBuiltIn {
        try storeReusedPassword(selection, preset: preset, model: model)
      }
      let policy = PDFDocumentSecurityPolicy(parsed: parsed)
      presentAlert(
        "Encrypted Copy Written",
        "Saved \(destination.lastPathComponent).\n\n\(policy.summary)\n\n"
          + "The open document and its protection were not modified.")
      return true
    } catch {
      presentError("The encrypted copy could not be written", error)
      return false
    }
  }

  private static func storeReusedPassword(
    _ selection: SecurityCredentialsSelection, preset: PDFSecurityPreset,
    model: SecurityPresetListModel
  ) throws {
    guard let password = selection.userPassword ?? selection.resolvedStoredPassword,
      !password.isEmpty
    else { return }
    _ = SecurityPresetCredentialStore.save(password: password, for: preset.id)
    if preset.storedCredential == nil {
      let reference = PDFSecurityCredentialReference(
        identifier: preset.id, displayName: preset.name)
      let updated = PDFSecurityPreset(
        id: preset.id, name: preset.name, detail: preset.detail,
        permissions: preset.permissions, passwordRequirement: preset.passwordRequirement,
        requiresSeparateOwnerPassword: preset.requiresSeparateOwnerPassword,
        encryptMetadata: preset.encryptMetadata,
        unencryptedEmbeddedFiles: preset.unencryptedEmbeddedFiles,
        storedCredential: reference, isBuiltIn: false)
      try model.store.replace(updated)
      try model.persist()
    }
  }

  // MARK: Policy report

  /// Read-only security policy for the open document: profile, permissions,
  /// what every protected operation permits, and the declared signing/
  /// recipient-encryption limits.
  static func presentPolicy(for document: SPDFDocument) {
    let policy = currentPolicy(of: document)
    guard let policy else {
      presentAlert(
        "Security Policy Unavailable",
        "Unlock the document with its password (or open an unencrypted document) "
          + "before inspecting its security policy.")
      return
    }
    let view = SecurityPolicyReportView(
      policy: policy,
      documentName: document.fileURL?.lastPathComponent ?? "Untitled document")
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 660, height: 500)
    let alert = NSAlert()
    alert.messageText = "Document Security Policy"
    alert.alertStyle = .informational
    alert.informativeText =
      "The policy is derived from the parsed encryption dictionary; it is the same "
        + "decision used by the export, decryption and signing paths."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  private static func currentPolicy(of document: SPDFDocument) -> PDFDocumentSecurityPolicy? {
    if let summary = document.editSession.protectionSummary {
      return PDFDocumentSecurityPolicy(
        encryption: summary, isOwner: document.editSession.isOwnerUnlocked)
    }
    guard let data = document.sourceStore.snapshot()?.data else { return nil }
    guard let parsed = try? PDFParser.parse(
      data, limits: SPDFDocumentResourcePolicy.parsingLimits)
    else { return nil }
    return PDFDocumentSecurityPolicy(parsed: parsed)
  }

  // MARK: Password change and protection removal

  /// Re-encrypt the saved (or clean current) graph with a new preset.
  static func presentChangeProtection(for document: SPDFDocument) {
    guard let source = document.sourceStore.snapshot()?.data else {
      presentAlert("Protection Unavailable", "This document has no saved PDF bytes.")
      return
    }
    guard !document.hasSignatures else {
      presentAlert(
        "Protection Change Unavailable",
        "A signed document is never rewritten; change protection before signing it.")
      return
    }
    if document.editSession.isDirty {
      presentAlert(
        "Save Before Changing Protection",
        "Save or discard pending edits first; protection changes rewrite the saved "
          + "bytes and must not include unsaved edits.")
      return
    }
    guard let unlocked = requestOwnerAuthentication(source) else { return }
    let model = SecurityPresetListModel(store: SecurityPresetFileStore.load())
    guard let preset = choosePreset(
      from: model, title: "New Protection",
      detail: "Choose the password/permission preset for the rewritten document.")
    else { return }
    guard let selection = requestCredentials(for: preset, model: model) else { return }
    let options: PDFEncryptionOptions
    do {
      options = try preset.encryptionOptions(
        userPassword: selection.userPassword,
        ownerPassword: selection.ownerPassword,
        resolvedStoredPassword: selection.resolvedStoredPassword)
    } catch {
      presentError("The preset could not be applied", error)
      return
    }
    guard let destination = chooseDestination(
      for: document, suffix: "-protected", title: "Save Protected Copy")
    else { return }
    do {
      let plain = try PDFWriter.removingEncryption(unlocked.parsed.graph)
      let output = try PDFWriter.write(
        plain, encryption: options, limits: SPDFDocumentResourcePolicy.parsingLimits)
      try VerifiedFileWriter.write(output, to: destination) { written in
        let parsed = try PDFParser.parse(
          written, password: options.userPassword,
          limits: SPDFDocumentResourcePolicy.parsingLimits)
        guard parsed.encryption != nil else {
          throw PDFError(.malformed, "The rewritten copy is not encrypted")
        }
        let mismatches = preset.verify(against: parsed)
        guard mismatches.isEmpty else {
          throw PDFError(
            .malformed, "The written protection did not match the preset: "
              + mismatches.joined(separator: "; "))
        }
      }
      presentAlert(
        "Protection Changed",
        "Saved \(destination.lastPathComponent) with the preset \"\(preset.name)\". "
          + "The original file is unchanged.")
    } catch {
      presentError("The protection change could not be written", error)
    }
  }

  /// Authorized removal: writes an unencrypted full rewrite of the saved graph.
  static func presentRemoveProtection(for document: SPDFDocument) {
    guard let source = document.sourceStore.snapshot()?.data else {
      presentAlert("Protection Unavailable", "This document has no saved PDF bytes.")
      return
    }
    guard !document.hasSignatures else {
      presentAlert(
        "Protection Removal Unavailable",
        "A signed document is never rewritten; remove protection before signing it.")
      return
    }
    if document.editSession.isDirty {
      presentAlert(
        "Save Before Removing Protection",
        "Save or discard pending edits first; protection removal rewrites the saved bytes.")
      return
    }
    let confirmation = NSAlert()
    confirmation.messageText = "Remove protection from a copy?"
    confirmation.alertStyle = .warning
    confirmation.informativeText =
      "The saved copy becomes an unencrypted full rewrite: it no longer enforces "
        + "passwords or permissions, and its earlier revisions are not retained. "
        + "The original file is unchanged."
    confirmation.addButton(withTitle: "Remove Protection...")
    confirmation.addButton(withTitle: "Cancel")
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }
    guard let unlocked = requestOwnerAuthentication(source) else { return }
    guard let destination = chooseDestination(
      for: document, suffix: "-unprotected", title: "Save Unprotected Copy")
    else { return }
    do {
      let plain = try PDFWriter.removingEncryption(unlocked.parsed.graph)
      let output = try PDFWriter.write(
        plain, limits: SPDFDocumentResourcePolicy.parsingLimits)
      try VerifiedFileWriter.write(output, to: destination) { written in
        let parsed = try PDFParser.parse(
          written, limits: SPDFDocumentResourcePolicy.parsingLimits)
        guard parsed.graph.trailer[PDFName("Encrypt")] == nil else {
          throw PDFError(.malformed, "The rewritten copy is still encrypted")
        }
        guard parsed.pageIDs == unlocked.parsed.pageIDs else {
          throw PDFError(.malformed, "The unprotected copy lost a page")
        }
      }
      presentAlert(
        "Protection Removed",
        "Saved \(destination.lastPathComponent) without encryption. "
          + "The original file is unchanged.")
    } catch {
      presentError("The unprotected copy could not be written", error)
    }
  }

  // MARK: Shared prompts

  private struct SecurityCredentialsSelection {
    let userPassword: String?
    let ownerPassword: String?
    let resolvedStoredPassword: String?
    let reusePassword: Bool
  }

  private static func requestCredentials(
    for preset: PDFSecurityPreset, model: SecurityPresetListModel
  ) -> SecurityCredentialsSelection? {
    let needsOpenPassword = preset.passwordRequirement == .userPasswordRequired
    let openField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    openField.placeholderString = preset.canReuseStoredPassword
      ? "Leave blank to reuse the stored password" : "Required"
    let ownerField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    ownerField.placeholderString = preset.requiresSeparateOwnerPassword
      ? "Required" : "Optional (defaults to the open password)"
    let reuseBox = NSButton(
      checkboxWithTitle: "Remember the open password in the Keychain for this preset",
      target: nil, action: nil)
    reuseBox.state = preset.canReuseStoredPassword ? .on : .off
    reuseBox.isEnabled = !preset.isBuiltIn || preset.canReuseStoredPassword
    var rows: [[NSView]] = []
    if needsOpenPassword {
      rows.append([NSTextField(labelWithString: "Open password"), openField])
    }
    rows.append([
      NSTextField(labelWithString: preset.requiresSeparateOwnerPassword
        ? "Owner password" : "Owner password (optional)"),
      ownerField,
    ])
    rows.append([reuseBox])
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 6
    grid.columnSpacing = 10
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.widthAnchor.constraint(equalToConstant: 460).isActive = true
    let note = NSTextField(wrappingLabelWithString:
      preset.passwordSummary + "\nPreset passwords are never written to the preset file.")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 460
    let stack = NSStackView(views: [grid, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    let alert = NSAlert()
    alert.messageText = "Preset \"\(preset.name)\""
    alert.alertStyle = .informational
    alert.informativeText = preset.detail
    alert.accessoryView = stack
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = needsOpenPassword ? openField : ownerField
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let userPassword = needsOpenPassword && !openField.stringValue.isEmpty
      ? openField.stringValue : nil
    let ownerPassword = ownerField.stringValue.isEmpty ? nil : ownerField.stringValue
    openField.stringValue = ""
    ownerField.stringValue = ""
    let resolvedStored = userPassword == nil && preset.canReuseStoredPassword
      ? SecurityPresetCredentialStore.password(for: preset.id) : nil
    return SecurityCredentialsSelection(
      userPassword: userPassword, ownerPassword: ownerPassword,
      resolvedStoredPassword: resolvedStored,
      reusePassword: reuseBox.state == .on)
  }

  private static func requestOwnerAuthentication(_ source: Data) -> PDFUnlockedDocument? {
    let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    passwordField.placeholderString = "Owner password"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Owner password"), passwordField]
    ])
    grid.rowSpacing = 6
    grid.columnSpacing = 10
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.widthAnchor.constraint(equalToConstant: 420).isActive = true
    let alert = NSAlert()
    alert.messageText = "Owner Password Required"
    alert.alertStyle = .informational
    alert.informativeText =
      "Changing or removing protection requires the document's owner password. "
        + "The password is used for this action only and is not stored."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = passwordField
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let password = passwordField.stringValue
    passwordField.stringValue = ""
    guard !password.isEmpty else { return nil }
    do {
      let unlocked = try PDFParser.unlock(
        source, password: password, limits: SPDFDocumentResourcePolicy.parsingLimits)
      guard unlocked.encryption.isOwner else {
        presentAlert(
          "Owner Password Required",
          "That password authenticated as the user password. Changing or removing "
            + "protection requires the owner password.")
        return nil
      }
      return unlocked
    } catch {
      presentError("The document could not be authenticated", error)
      return nil
    }
  }

  private static func choosePreset(
    from model: SecurityPresetListModel, title: String, detail: String
  ) -> PDFSecurityPreset? {
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    for preset in model.store.allPresets {
      popup.addItem(withTitle: preset.name)
    }
    if let selected = model.selectedPreset,
      let index = model.store.allPresets.firstIndex(of: selected)
    {
      popup.selectItem(at: index)
    }
    let alert = NSAlert()
    alert.messageText = title
    alert.alertStyle = .informational
    alert.informativeText = detail
    alert.accessoryView = popup
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let index = popup.indexOfSelectedItem
    guard model.store.allPresets.indices.contains(index) else { return nil }
    let preset = model.store.allPresets[index]
    model.selectedID = preset.id
    return preset
  }

  private static func chooseDestination(
    for document: SPDFDocument, suffix: String, title: String
  ) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + suffix + ".pdf"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  static func presentAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  static func presentError(_ title: String, _ error: Error) {
    presentAlert(title, error.localizedDescription)
  }
}

// MARK: - Models

/// SIG-08: the preset list and its current selection.
final class SecurityPresetListModel: ObservableObject {
  @Published var store: PDFSecurityPresetStore
  @Published var selectedID: String?

  init(store: PDFSecurityPresetStore) {
    self.store = store
    self.selectedID = store.allPresets.first?.id
  }

  var selectedPreset: PDFSecurityPreset? {
    selectedID.flatMap { store.preset(id: $0) }
  }

  func persist() throws {
    try SecurityPresetFileStore.save(store)
  }
}

/// SIG-08: a mutable draft of one preset for the editor panel.
final class SecurityPresetDraft: ObservableObject {
  @Published var name: String
  @Published var detail: String
  @Published var printing: Bool
  @Published var highQualityPrinting: Bool
  @Published var modification: Bool
  @Published var copying: Bool
  @Published var annotation: Bool
  @Published var formFilling: Bool
  @Published var extraction: Bool
  @Published var assembly: Bool
  @Published var passwordRequirement: PDFSecurityPasswordRequirement
  @Published var requiresSeparateOwnerPassword: Bool
  @Published var encryptMetadata: Bool
  @Published var unencryptedEmbeddedFiles: Bool

  let id: String
  let storedCredential: PDFSecurityCredentialReference?

  init(preset: PDFSecurityPreset) {
    let duplicate = preset.isBuiltIn
    id = duplicate
      ? "custom-\(UUID().uuidString.lowercased())"
      : preset.id
    name = duplicate ? "\(preset.name) copy" : preset.name
    detail = preset.detail
    printing = preset.permissions.printing
    highQualityPrinting = preset.permissions.highQualityPrinting
    modification = preset.permissions.modification
    copying = preset.permissions.copying
    annotation = preset.permissions.annotation
    formFilling = preset.permissions.formFilling
    extraction = preset.permissions.extraction
    assembly = preset.permissions.assembly
    passwordRequirement = preset.passwordRequirement
    requiresSeparateOwnerPassword = preset.requiresSeparateOwnerPassword
    encryptMetadata = preset.encryptMetadata
    unencryptedEmbeddedFiles = preset.unencryptedEmbeddedFiles
    storedCredential = preset.storedCredential
  }

  var permissions: PDFPermissionSet {
    PDFPermissionSet(
      printing: printing, highQualityPrinting: highQualityPrinting,
      modification: modification, copying: copying,
      annotation: annotation, formFilling: formFilling,
      extraction: extraction, assembly: assembly)
  }

  func makePreset() -> PDFSecurityPreset {
    PDFSecurityPreset(
      id: id, name: name, detail: detail, permissions: permissions,
      passwordRequirement: passwordRequirement,
      requiresSeparateOwnerPassword: requiresSeparateOwnerPassword,
      encryptMetadata: encryptMetadata,
      unencryptedEmbeddedFiles: unencryptedEmbeddedFiles,
      storedCredential: storedCredential, isBuiltIn: false)
  }
}

// MARK: - Persistence

/// SIG-08: the on-disk preset file. Only custom presets are stored; the file
/// contains permission/password-policy metadata and optional Keychain labels,
/// never a password.
enum SecurityPresetFileStore {
  static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("sPDF", isDirectory: true)
  }

  static var fileURL: URL { directory.appendingPathComponent("SecurityPresets.json") }

  static func load() -> PDFSecurityPresetStore {
    guard let data = try? Data(contentsOf: fileURL),
      let store = try? PDFSecurityPresetStore(data: data)
    else { return PDFSecurityPresetStore() }
    return store
  }

  static func save(_ store: PDFSecurityPresetStore) throws {
    let data = try store.encoded()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }
}

/// SIG-08: the explicit Keychain retention used only when the user asks the
/// app to remember a preset's open password.
enum SecurityPresetCredentialStore {
  static func save(password: String, for identifier: String) -> Bool {
    guard let data = password.data(using: .utf8) else { return false }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: PDFSecurityCredentialReference.keychainService,
      kSecAttrAccount as String: identifier,
    ]
    SecItemDelete(query as CFDictionary)
    var attributes = query
    attributes[kSecValueData as String] = data
    attributes[kSecAttrLabel as String] = "sPDF Editor: security preset"
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  static func password(for identifier: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: PDFSecurityCredentialReference.keychainService,
      kSecAttrAccount as String: identifier,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  static func remove(for identifier: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: PDFSecurityCredentialReference.keychainService,
      kSecAttrAccount as String: identifier,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}

// MARK: - Views

/// SIG-08: the preset browser used by the manager modal.
struct SecurityPresetsView: View {
  @ObservedObject var model: SecurityPresetListModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Built-in presets").font(.headline)
        ForEach(model.store.builtInPresets, id: \.id) { preset in
          row(preset)
        }
        if !model.store.customPresets.isEmpty {
          Text("Custom presets").font(.headline).padding(.top, 6)
          ForEach(model.store.customPresets, id: \.id) { preset in
            row(preset)
          }
        }
        if let selected = model.selectedPreset {
          Divider()
          detail(selected)
        }
        Text(
          "Presets store permissions and password requirements only. Applying one "
            + "writes a new AES-256 (V5/R6) encrypted copy; passwords are never saved in "
            + "the preset file.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 600, minHeight: 420)
  }

  private func row(_ preset: PDFSecurityPreset) -> some View {
    Button {
      model.selectedID = preset.id
    } label: {
      HStack(spacing: 8) {
        Image(systemName: model.selectedID == preset.id
          ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(model.selectedID == preset.id ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(preset.name).font(.subheadline.weight(.medium))
          Text(preset.permissions.allowedSummary.isEmpty
            ? "No permissions granted"
            : preset.permissions.allowedSummary.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(preset.isBuiltIn ? "Built-in" : "Custom")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func detail(_ preset: PDFSecurityPreset) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(preset.name).font(.headline)
      if !preset.detail.isEmpty {
        Text(preset.detail).font(.caption).foregroundStyle(.secondary)
      }
      Text(preset.passwordSummary).font(.caption2).foregroundStyle(.secondary)
      Text("Permissions: " + (preset.permissions.allowedSummary.isEmpty
        ? "none"
        : preset.permissions.allowedSummary.joined(separator: ", ")))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

/// SIG-08: read-only policy report for the open document.
struct SecurityPolicyReportView: View {
  let policy: PDFDocumentSecurityPolicy
  let documentName: String

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        Text(documentName).font(.headline)
        Text(policy.summary).font(.caption).foregroundStyle(.secondary)
        if policy.securityChangeRequiresOwner && !policy.isOwner {
          Text("The owner password is required to change or remove this protection.")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        if !policy.signingAllowed {
          Text(
            "Signing an encrypted document is not supported: export an authorized "
              + "unencrypted copy first.")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        Divider()
        ForEach(policy.rows, id: \.operation) { row in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Image(systemName: row.decision.isAllowed
                ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(row.decision.isAllowed ? .green : .red)
              Text(row.operation.title).font(.caption.weight(.medium))
              Spacer()
              if row.ownerRequired {
                Text("Owner").font(.caption2).foregroundStyle(.orange)
              }
              Text(row.decision.isAllowed ? "Allowed" : "Denied")
                .font(.caption2)
                .foregroundStyle(row.decision.isAllowed ? .green : .red)
            }
            if let reason = row.decision.refusalReason {
              Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        Divider()
        Text(PDFRecipientEncryptionProfile.decision)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 620, minHeight: 460)
  }
}

/// SIG-08: the preset editor used by the manager modal.
struct SecurityPresetEditorView: View {
  @ObservedObject var draft: SecurityPresetDraft

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Name", text: $draft.name)
        TextField("Description", text: $draft.detail)
        Divider()
        Text("Permissions").font(.headline)
        Toggle("Print (standard quality)", isOn: $draft.printing)
        Toggle("Print at high quality", isOn: $draft.highQualityPrinting)
          .disabled(!draft.printing)
        Toggle("Modify content", isOn: $draft.modification)
        Toggle("Copy or extract content", isOn: $draft.copying)
        Toggle("Add or edit comments", isOn: $draft.annotation)
        Toggle("Fill existing forms", isOn: $draft.formFilling)
        Toggle("Accessibility extraction", isOn: $draft.extraction)
        Toggle("Assemble pages", isOn: $draft.assembly)
        Divider()
        Text("Password policy").font(.headline)
        Picker("Requirement", selection: $draft.passwordRequirement) {
          ForEach(PDFSecurityPasswordRequirement.allCases, id: \.self) { requirement in
            Text(requirement.title).tag(requirement)
          }
        }
        Toggle(
          "Require a separate owner password",
          isOn: $draft.requiresSeparateOwnerPassword)
        Toggle("Encrypt document metadata", isOn: $draft.encryptMetadata)
        Toggle(
          "Leave embedded files unencrypted",
          isOn: $draft.unencryptedEmbeddedFiles)
        Text(draft.passwordRequirement.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 520, minHeight: 440)
  }
}

// MARK: - SPDFDocument hooks (no stored state)

extension SPDFDocument {
  /// Hook: Security menu item "Security Presets...".
  func presentSecurityPresets() {
    SecurityPresetsFlow.presentPresets(for: self)
  }

  /// Hook: Security menu item "Document Security Policy...".
  func presentSecurityPolicyReport() {
    SecurityPresetsFlow.presentPolicy(for: self)
  }

  /// Hook: Security menu item "Change Password / Permissions...".
  func presentChangeDocumentProtection() {
    SecurityPresetsFlow.presentChangeProtection(for: self)
  }

  /// Hook: Security menu item "Remove Protection...".
  func presentRemoveDocumentProtection() {
    SecurityPresetsFlow.presentRemoveProtection(for: self)
  }

  /// Hook: after opening a PDF whose encryption has an empty user password,
  /// load the owned-core session so permissions (not PDFKit's auto-unlock)
  /// govern editing. Returns true when a protected session was loaded.
  @discardableResult
  func unlockCoreSessionIfEncryptionNeedsNoPassword() -> Bool {
    guard !editSession.isProtected, let source = sourceStore.snapshot(),
      let parsed = try? PDFParser.parse(
        source.data, password: "", limits: SPDFDocumentResourcePolicy.parsingLimits),
      parsed.encryption != nil
    else { return false }
    do {
      try editSession.loadProtected(source, password: "")
      _ = viewer?.unlock(password: "")
      return true
    } catch {
      return false
    }
  }
}
