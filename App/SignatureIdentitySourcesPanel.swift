import AppKit
import Foundation
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// SIG-07: explicit signing-identity sources. The model keeps only Security
/// framework references (Keychain/token identities and certificate-only
/// imports). Private keys never enter the app: PKCS#12 import hands them to the
/// user's Keychain through Security, and token-backed keys stay on the token.
@MainActor
final class SignatureIdentitySourcesModel: ObservableObject {
  @Published private(set) var catalogIdentities: [PDFSigningIdentitySource] = []
  @Published private(set) var importedCertificateSources: [PDFSigningIdentitySource] = []
  @Published var selectedFingerprint: String?
  @Published private(set) var statusNote: String?
  @Published private(set) var problem: String?

  var allSources: [PDFSigningIdentitySource] {
    catalogIdentities + importedCertificateSources
  }

  var selectedSource: PDFSigningIdentitySource? {
    guard let selectedFingerprint else { return nil }
    return allSources.first { $0.fingerprintSHA256 == selectedFingerprint }
  }

  var signableSources: [PDFSigningIdentitySource] {
    allSources.filter(\.canSign)
  }

  var unusableSources: [PDFSigningIdentitySource] {
    allSources.filter { !$0.canSign }
  }

  func refresh() {
    let previous = selectedFingerprint
    catalogIdentities = PDFSigningIdentityCatalog.available()
    importedCertificateSources = importedCertificateSources.filter { imported in
      !catalogIdentities.contains {
        $0.fingerprintSHA256 == imported.fingerprintSHA256
      }
    }
    problem = nil
    if let previous, allSources.contains(where: { $0.fingerprintSHA256 == previous }) {
      selectedFingerprint = previous
    } else {
      selectedFingerprint = signableSources.first?.fingerprintSHA256
    }
    let hardware = catalogIdentities.filter(\.kind.isHardwareBacked).count
    let imported = importedCertificateSources.count
    statusNote = "Found " + String(signableSources.count) + " signing identity(s)"
      + (hardware > 0 ? " (" + String(hardware) + " hardware-backed)" : "")
      + (imported > 0 ? ", " + String(imported) + " certificate-only import(s)" : "")
      + "."
  }

  /// Import an explicit file. PKCS#12 may require a passphrase; a
  /// certificate-only file is kept in memory for inspection and cannot sign.
  @discardableResult
  func importFile(at url: URL, passphrase: String?) -> PDFSigningIdentitySource? {
    do {
      let source = try PDFSigningIdentityCatalog.importFile(
        at: url, passphrase: passphrase)
      if source.canSign {
        refresh()
        if let refreshed = catalogIdentities.first(where: {
          $0.fingerprintSHA256 == source.fingerprintSHA256
        }) {
          selectedFingerprint = refreshed.fingerprintSHA256
        } else {
          selectedFingerprint = source.fingerprintSHA256
        }
        statusNote = "Imported " + (source.origin ?? "identity") + " into the Keychain."
      } else {
        importedCertificateSources.removeAll {
          $0.fingerprintSHA256 == source.fingerprintSHA256
        }
        importedCertificateSources.append(source)
        selectedFingerprint = source.fingerprintSHA256
        statusNote = "Imported certificate " + (source.origin ?? "")
          + " — certificate only, no private key; it cannot sign."
      }
      problem = nil
      return source
    } catch let error as PDFError {
      problem = error.errorDescription ?? error.message
      return nil
    } catch {
      problem = error.localizedDescription
      return nil
    }
  }

  func clearCertificateImports() {
    importedCertificateSources.removeAll()
    if selectedSource == nil {
      selectedFingerprint = signableSources.first?.fingerprintSHA256
    }
  }
}

/// Explicit import flow: file chooser plus, for PKCS#12, a passphrase prompt.
/// Cancelling either step writes nothing and produces no signed file.
@MainActor
enum SignatureIdentityImportFlow {
  static func chooseAndImport(into model: SignatureIdentitySourcesModel) {
    let panel = NSOpenPanel()
    var types: [UTType] = []
    for ext in ["p12", "pfx", "cer", "crt", "der", "pem"] {
      if let type = UTType(filenameExtension: ext) {
        types.append(type)
      }
    }
    panel.allowedContentTypes = types.isEmpty ? [.data] : types
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose a PKCS#12 identity (.p12/.pfx) or a certificate file."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let isPKCS12 = ["p12", "pfx"].contains(url.pathExtension.lowercased())
    let passphrase: String?
    if isPKCS12 {
      guard let input = passphrasePrompt(fileName: url.lastPathComponent) else { return }
      passphrase = input
    } else {
      passphrase = nil
    }
    _ = model.importFile(at: url, passphrase: passphrase)
  }

  static func passphrasePrompt(fileName: String) -> String? {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.placeholderString = "PKCS#12 passphrase"
    let alert = NSAlert()
    alert.messageText = "Import Signing Identity"
    alert.informativeText =
      "Enter the passphrase for " + fileName
        + ". The private key stays in the Keychain after import; this app never copies it."
    alert.accessoryView = field
    alert.addButton(withTitle: "Import")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }
}

/// SIG-07 picker: grouped identity sources with explicit kinds, Keychain/token
/// state and certificate-only refusal. No signing output is produced here.
struct SignatureIdentitySourcesPanel: View {
  @ObservedObject var model: SignatureIdentitySourcesModel
  var onUse: ((PDFSigningIdentitySource) -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      HStack(spacing: 8) {
        Button("Import Certificate or PKCS#12…") {
          SignatureIdentityImportFlow.chooseAndImport(into: model)
        }
        Button("Refresh") { model.refresh() }
        if !model.importedCertificateSources.isEmpty {
          Button("Clear Certificate Imports") { model.clearCertificateImports() }
        }
        Spacer()
      }
      if let status = model.statusNote {
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
      if let problem = model.problem {
        Text(problem).font(.caption).foregroundStyle(.red)
      }
      List(selection: $model.selectedFingerprint) {
        ForEach(model.allSources, id: \.fingerprintSHA256) { source in
          sourceRow(source).tag(source.fingerprintSHA256)
        }
      }
      .frame(minHeight: 220)
      if let selected = model.selectedSource {
        detail(for: selected)
      } else {
        Text("Select an identity to see its source and signing capability.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(minWidth: 620, minHeight: 460)
    .onAppear {
      if model.allSources.isEmpty { model.refresh() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Signing identity sources")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Signing Identities").font(.headline)
      Text(
        "Private keys stay in the Keychain, Secure Enclave or hardware token. "
          + "PKCS#12 import places the key in the user's Keychain through Security; "
          + "this app never copies key material. Certificate-only files can be inspected "
          + "but cannot sign."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func sourceRow(_ source: PDFSigningIdentitySource) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: source.canSign ? "checkmark.seal" : "doc.badge.ellipsis")
        .foregroundStyle(source.canSign ? .green : .orange)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(source.displayName).font(.subheadline.weight(.semibold))
        Text(source.sourceDescription).font(.caption).foregroundStyle(.secondary)
        Text(source.validityDescription).font(.caption2).foregroundStyle(.secondary)
        if let warning = source.selectionWarning {
          Text(warning).font(.caption2).foregroundStyle(.orange)
        }
      }
      Spacer()
      Text(source.canSign ? "Can sign" : "No private key")
        .font(.caption2)
        .foregroundStyle(source.canSign ? .green : .orange)
    }
    .padding(.vertical, 2)
  }

  private func detail(for source: PDFSigningIdentitySource) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Divider()
      Text(source.sourceDescription).font(.caption.weight(.semibold))
      if let issuer = source.issuerCommonName {
        Text("Issuer: " + issuer).font(.caption2).foregroundStyle(.secondary)
      }
      Text("SHA-256 " + source.fingerprintSHA256).font(.caption2).foregroundStyle(.secondary)
      if let warning = source.selectionWarning {
        Text(warning).font(.caption2).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        if let onUse {
          Button("Use Selected Identity") { onUse(source) }
            .disabled(!source.canSign)
        }
      }
    }
  }
}

extension SPDFDocument {
  /// Menu validation hook for "Signing Identities…".
  var canShowSignatureIdentitySources: Bool { true }

  /// Hook: call from the "Signing Identities…" menu item.
  @MainActor
  func presentSignatureIdentitySources() {
    let model = SignatureIdentitySourcesModel()
    model.refresh()
    let hosting = NSHostingView(rootView: SignatureIdentitySourcesPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 660, height: 500)
    let alert = NSAlert()
    alert.messageText = "Signing Identities"
    alert.alertStyle = .informational
    alert.informativeText =
      "Identity selection is explicit: Keychain, Secure Enclave, hardware token or an "
        + "imported PKCS#12. Certificate-only files cannot sign. Cancelling import or "
        + "signing leaves no partial output."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }
}
