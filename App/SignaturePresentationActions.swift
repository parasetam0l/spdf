import AppKit
import PDFCore
import PDFEditing
import SwiftUI

/// SIG-07: read-only presentation audit for a document: certificate signatures
/// are listed separately from visible signature marks, and each row states
/// whether the signature paints a visible appearance. No state is added to
/// SPDFDocument; the Lead wires the menu items reported in SESSION.md.
@MainActor
final class SignaturePresentationModel: ObservableObject {
  @Published private(set) var report: PDFSignaturePresentationReport?
  @Published private(set) var problem: String?
  @Published var selectedDetail: String?

  private let graphProvider: @MainActor () -> PDFGraph?

  init(graphProvider: @escaping @MainActor () -> PDFGraph?) {
    self.graphProvider = graphProvider
  }

  func reload() {
    guard let graph = graphProvider() else {
      report = nil
      problem = "No editable PDF graph is available."
      return
    }
    do {
      report = try PDFSignaturePresentationAudit.report(in: graph)
      problem = nil
    } catch {
      report = nil
      problem = error.localizedDescription
    }
  }

  var certificateSignatures: [PDFCertificateSignaturePresentation] {
    report?.certificateSignatures ?? []
  }
  var visibleCertificateSignatures: [PDFCertificateSignaturePresentation] {
    report?.visibleCertificateSignatures ?? []
  }
  var hiddenCertificateSignatures: [PDFCertificateSignaturePresentation] {
    report?.hiddenCertificateSignatures ?? []
  }
  var graphicalMarks: [PDFGraphicalSignatureMark] { report?.graphicalMarks ?? [] }
  var summaryLines: [String] { report?.summaryLines ?? [] }
  var warnings: [String] { report?.warnings ?? [] }
  var isEmpty: Bool {
    certificateSignatures.isEmpty && graphicalMarks.isEmpty
  }
}

extension SPDFDocument {
  /// Hook: call from the "Signature Presentation…" menu item.
  @MainActor
  func signaturePresentationModel() -> SignaturePresentationModel {
    SignaturePresentationModel { [weak self] in
      guard let self else { return nil }
      if let graph = self.editSession.currentGraph { return graph }
      guard let source = self.sourceStore.snapshot()?.data else { return nil }
      return (try? PDFParser.parse(
        source, limits: SPDFDocumentResourcePolicy.parsingLimits))?.graph
    }
  }

  /// Menu validation hook.
  var canShowSignaturePresentationPanel: Bool {
    viewer != nil || editSession.currentGraph != nil
  }

  /// Hook: Tools > Security > Signature Presentation…
  @MainActor
  func showSignaturePresentationPanel() {
    let model = signaturePresentationModel()
    model.reload()
    let hosting = NSHostingView(rootView: SignaturePresentationPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
    let alert = NSAlert()
    alert.messageText = "Signature Presentation"
    alert.alertStyle = .informational
    alert.informativeText =
      "Certificate signatures (cryptographic evidence) and visible signature marks "
      + "(drawn or typed ink) are different things. This report never presents one as the other."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.addButton(withTitle: "Sign Hidden Certificate…")
    if alert.runModal() == .alertSecondButtonReturn {
      presentHiddenCertificateSigning()
    }
  }

  /// SIG-07 hook: a hidden certificate signature (no painted appearance) is a
  /// separate, explicit choice from a visible certificate signature. The
  /// private key stays in the keychain; cancellation writes nothing.
  @MainActor
  func presentHiddenCertificateSigning() {
    var graph = editSession.currentGraph
    if graph == nil, let data = sourceStore.snapshot()?.data {
      graph = try? PDFParser.parse(
        data, limits: SPDFDocumentResourcePolicy.parsingLimits).graph
    }
    guard let graph else {
      presentSignaturePresentationAlert(
        "Signing Unavailable", "This document has no editable PDF graph.")
      return
    }
    let identities = PDFSigningIdentity.availableIdentities()
    guard !identities.isEmpty else {
      presentSignaturePresentationAlert(
        "No Signing Identities",
        "No code-signing or S/MIME identities were found in the keychain.")
      return
    }
    if editSession.isDirty,
      let signatures = try? PDFSignatureInventory.signatures(in: graph), !signatures.isEmpty
    {
      presentSignaturePresentationAlert(
        "Save Before Signing",
        "This document is already signed. Save your edits first; adding a signature must be "
          + "an incremental update over the saved bytes.")
      return
    }

    let identityPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    for available in identities {
      let details = PDFSignatureSignerIdentity.certificateDetails(available.certificate)
      let issuer = details?.issuerCommonName.map { " — issued by \($0)" } ?? ""
      identityPopup.addItem(withTitle: available.commonName + issuer)
    }
    let fieldName = NSTextField(string: suggestedHiddenSignatureFieldName(in: graph))
    fieldName.placeholderString = "Hidden signature field name"
    let note = NSTextField(wrappingLabelWithString:
      "This writes a hidden certificate signature: cryptographic evidence with no rectangle "
      + "drawn on the page. It is not an ink or drawn signature. The private key stays in the "
      + "keychain; cancelling leaves no partial signed file.")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 520
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Signer identity"), identityPopup],
      [NSTextField(labelWithString: "Field name"), fieldName],
    ])
    grid.rowSpacing = 6
    grid.columnSpacing = 10
    let stack = NSStackView(views: [grid, note])
    stack.orientation = NSUserInterfaceLayoutOrientation.vertical
    stack.alignment = NSLayoutConstraint.Attribute.leading
    stack.spacing = 10
    let alert = NSAlert()
    alert.messageText = "Sign Hidden Certificate"
    alert.informativeText =
      "No visible appearance is created; readers find this signature in the signature panel, not on the page."
    alert.alertStyle = .informational
    alert.accessoryView = stack
    alert.addButton(withTitle: "Sign…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard identities.indices.contains(identityPopup.indexOfSelectedItem) else { return }
    let identity = identities[identityPopup.indexOfSelectedItem]
    var name = fieldName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { name = suggestedHiddenSignatureFieldName(in: graph) }
    let existing = Set(
      (try? PDFSignatureFieldInventory.fields(in: graph))?.map(\.name) ?? [])
    guard !existing.contains(name) else {
      presentSignaturePresentationAlert(
        "Field Name In Use", "A signature field named \(name) already exists.")
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue =
      "hidden-certificate-\(fileURL?.deletingPathExtension().lastPathComponent ?? "signed").pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let options = PDFHiddenCertificateSigningOptions(
      fieldName: name, pageIndex: max(0, (viewer?.pageNumber ?? 1) - 1))
    do {
      let data = try PDFHiddenCertificateSigner.sign(
        graph, identity: identity.identity, options: options)
      try data.write(to: url, options: .atomic)
      refreshSignatures()
      refreshSignatureMultiSignerState()
      presentSignaturePresentationAlert(
        "Signed", "A hidden certificate signature was written to \(url.lastPathComponent). "
          + "No visible appearance was added; examine it in Signature Presentation or Signature Details.")
    } catch {
      presentSignaturePresentationAlert("Signing Failed", error.localizedDescription)
    }
  }

  private func suggestedHiddenSignatureFieldName(in graph: PDFGraph) -> String {
    let existing = Set(
      (try? PDFSignatureFieldInventory.fields(in: graph))?.map(\.name) ?? [])
    var index = 1
    while existing.contains("HiddenSignature\(index)") { index += 1 }
    return "HiddenSignature\(index)"
  }

  private func presentSignaturePresentationAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
