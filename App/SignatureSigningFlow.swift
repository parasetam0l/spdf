import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// SIG-06: the multi-signer UI flows. The Lead wires two menu items (see the
/// task's SESSION.md hooks): "Sign Existing Field…" and "Signature Details…";
/// both forward to the SPDFDocument extension methods at the bottom of this
/// file. No stored state is added to SPDFDocument.
@MainActor
enum SignatureSigningFlow {
  /// Field-selection + signer-identity + permission-aware incremental signing.
  static func present(for document: SPDFDocument) {
    guard let snapshot = SignatureMultiSignerSnapshot.build(for: document),
      let graph = currentGraph(of: document)
    else {
      presentAlert("Signing Unavailable", "This document has no editable PDF graph.")
      return
    }
    if document.editSession.isDirty && snapshot.hasSignatures {
      presentAlert(
        "Save Before Signing",
        "This document is already signed. Save your edits first; adding a signature to a "
          + "signed document must be an incremental update over the saved bytes.")
      return
    }
    let identities = PDFSigningIdentity.availableIdentities()
    guard !identities.isEmpty else {
      presentAlert(
        "No Signing Identities",
        "No code-signing or S/MIME identities were found in the keychain.")
      return
    }

    let identityPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    for available in identities {
      let details = PDFSignatureSignerIdentity.certificateDetails(available.certificate)
      let suffix = details?.issuerCommonName.map { " — issued by \($0)" } ?? ""
      identityPopup.addItem(withTitle: available.commonName + suffix)
    }
    let targetPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    for field in snapshot.emptyFields {
      targetPopup.addItem(withTitle: "Existing field: \(field.name)")
    }
    targetPopup.addItem(withTitle: "Create a new signature field")
    let newFieldName = NSTextField(string: suggestedFieldName(in: graph))
    newFieldName.placeholderString = "New field name"
    newFieldName.isEnabled = snapshot.emptyFields.isEmpty
    // NSControl.target is weak; keep the action object alive for the modal.
    let fieldTargetToggle = FieldTargetToggle.target(newFieldName)
    targetPopup.target = fieldTargetToggle
    targetPopup.action = #selector(FieldTargetToggle.changed(_:))
    let reasonField = NSTextField(string: "")
    reasonField.placeholderString = "Reason (optional)"

    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Signer identity"), identityPopup],
      [NSTextField(labelWithString: "Signature field"), targetPopup],
      [NSTextField(labelWithString: "New field name"), newFieldName],
      [NSTextField(labelWithString: "Reason"), reasonField],
    ])
    grid.rowSpacing = 6
    grid.columnSpacing = 10
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.widthAnchor.constraint(equalToConstant: 520).isActive = true

    let note = NSTextField(wrappingLabelWithString:
      snapshot.hasSignatures
      ? "An incremental signature covers the whole saved file and preserves earlier "
        + "signatures. Certification permissions and field locks are enforced before signing."
      : "The document will be signed into a new file; the private key stays in the keychain.")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 520
    let stack = NSStackView(views: [grid, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10

    let alert = NSAlert()
    alert.messageText = snapshot.hasSignatures ? "Add Incremental Signature" : "Sign Document"
    alert.alertStyle = .informational
    alert.accessoryView = stack
    alert.addButton(withTitle: "Sign…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    guard identities.indices.contains(identityPopup.indexOfSelectedItem) else { return }
    let identity = identities[identityPopup.indexOfSelectedItem]
    let usesExisting = targetPopup.indexOfSelectedItem < snapshot.emptyFields.count
    let target: PDFSignatureSigningTarget
    var fieldName: String
    if usesExisting {
      let field = snapshot.emptyFields[targetPopup.indexOfSelectedItem]
      fieldName = field.name
      target = .existingField(name: field.name)
    } else {
      fieldName = sanitizedFieldName(newFieldName.stringValue, in: graph)
      target = .newField(name: fieldName)
    }
    if let decision = try? PDFSignatureSigningPolicy.decision(in: graph, target: target),
      case .refused(let reason) = decision
    {
      presentAlert("Signature Not Permitted", reason)
      return
    }

    let options = PDFSigningOptions(
      fieldName: fieldName,
      pageIndex: max(0, (document.viewer?.pageNumber ?? 1) - 1),
      reason: reasonField.stringValue.isEmpty ? nil : reasonField.stringValue,
      existingFieldName: usesExisting ? fieldName : nil)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedOutputName(for: document)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try document.signDocument(to: url, identity: identity.identity, options: options)
      document.refreshSignatures()
      document.refreshSignatureMultiSignerState()
      // SIG-02/SIG-03: report the evidence actually found in the written file
      // instead of a fixed revocation/timestamp sentence.
      let evidence = document.signatureEvidenceSummary(forSignedFile: url)
      presentAlert(
        "Signed", "The signed copy was written to \(url.lastPathComponent). "
          + (evidence.map { "Evidence: " + $0 } ?? "Evidence: unavailable for the written file.")
          + " Open Signature Evidence… for timestamp and revocation details.")
    } catch {
      presentAlert("Signing Failed", error.localizedDescription)
    }
  }

  /// Signed-revision inspection: signer identity, covered bytes, and changes
  /// between consecutive signatures.
  static func presentRevisions(for document: SPDFDocument) {
    guard let snapshot = SignatureMultiSignerSnapshot.build(for: document) else {
      presentAlert("Signature Details Unavailable", "This document has no readable PDF graph.")
      return
    }
    let view = SignatureRevisionInspectorView(
      snapshot: snapshot,
      onShowEvidence: { validation in
        SignatureEvidencePresentation.present(validation)
      }
    ) { pageIndex in
      document.navigate(toSignatureAt: pageIndex)
    }
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 380)
    let alert = NSAlert()
    alert.messageText = "Signed Revisions"
    alert.alertStyle = .informational
    let latestEvidence = snapshot.report.revisions.last.map {
      SignatureEvidencePresentation.summaryLine($0.validation)
    }
    alert.informativeText =
      snapshot.report.revisions.isEmpty
      ? "No signatures."
      : "\(snapshot.report.revisions.count) signature(s). "
        + (latestEvidence ?? "No evidence available for the latest revision.")
        + " Select Evidence… on a revision for the full offline trust model."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  // MARK: - Helpers

  private static func currentGraph(of document: SPDFDocument) -> PDFGraph? {
    if let graph = document.editSession.currentGraph { return graph }
    guard let source = document.sourceStore.snapshot()?.data else { return nil }
    return (try? PDFParser.parse(
      source, limits: SPDFDocumentResourcePolicy.parsingLimits))?.graph
  }

  private static func suggestedFieldName(in graph: PDFGraph) -> String {
    let existing = (try? PDFSignatureFieldInventory.fields(in: graph))?.map(\.name) ?? []
    var index = 1
    while existing.contains("Signature\(index)") { index += 1 }
    return "Signature\(index)"
  }

  private static func sanitizedFieldName(_ raw: String, in graph: PDFGraph) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return suggestedFieldName(in: graph) }
    let existing = Set((try? PDFSignatureFieldInventory.fields(in: graph))?.map(\.name) ?? [])
    guard existing.contains(trimmed) else { return trimmed }
    var index = 2
    while existing.contains("\(trimmed)\(index)") { index += 1 }
    return "\(trimmed)\(index)"
  }

  private static func suggestedOutputName(for document: SPDFDocument) -> String {
    let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    return base + "-signed.pdf"
  }

  static func presentAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

/// Enables the new-field name control only when the popup creates a new field.
@MainActor
final class FieldTargetToggle: NSObject {
  private weak var nameField: NSTextField?
  static func target(_ field: NSTextField) -> FieldTargetToggle {
    let toggle = FieldTargetToggle()
    toggle.nameField = field
    return toggle
  }
  @objc func changed(_ sender: NSPopUpButton) {
    nameField?.isEnabled = sender.indexOfSelectedItem >= sender.numberOfItems - 1
  }
}

extension SPDFDocument {
  /// Hook: call from the "Sign Existing Field…" menu item.
  func presentSignatureSigningFlow() {
    SignatureSigningFlow.present(for: self)
  }

  /// Hook: call from the "Signature Details…" menu item.
  func presentSignatureRevisionDetails() {
    SignatureSigningFlow.presentRevisions(for: self)
  }

  /// Hook: call from refreshSignatures() to refresh the field/revision model if
  /// the workspace adopts SignatureMultiSignerModel as a stored property.
  func refreshSignatureMultiSignerState() {
    // No stored model exists on SPDFDocument yet; the flows build the snapshot
    // on demand. The Lead can add 'let signatureFieldsModel =
    // SignatureMultiSignerModel()' and call refresh(from: self) here.
  }
}
