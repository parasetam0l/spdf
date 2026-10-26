import AppKit
import DocumentSession
import PDFCore
import PDFEditing
import Security
import SwiftUI
import UniformTypeIdentifiers

/// SIG-04/SIG-05: the certification authoring flow, the certification/field-lock
/// status panel and the representative signing workflow guide. The Lead wires
/// three menu items (see SESSION.md hooks); no stored state is added to
/// SPDFDocument and all bytes are produced through the shared PDFEditing core.
@MainActor
enum SignatureCertificationFlow {
  /// Certification choices, current locks and the declared permission.
  static func presentStatus(for document: SPDFDocument) {
    guard let snapshot = SignatureCertificationSnapshot.build(for: document) else {
      presentAlert("Certification Status Unavailable", "This document has no readable PDF graph.")
      return
    }
    let hosting = NSHostingView(
      rootView: SignatureCertificationStatusView(snapshot: snapshot))
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
    let alert = NSAlert()
    alert.messageText = "Certification and Field Locks"
    alert.alertStyle = .informational
    alert.informativeText =
      "DocMDP is the certification permission; FieldMDP locks named fields so later "
        + "signers cannot change them. This report is read-only and offline."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  /// Author a certification signature with an optional FieldMDP lock. This is
  /// the only route that can add a certification: it must be the first
  /// signature and the core refuses every unsupported choice before writing.
  static func presentAuthoring(for document: SPDFDocument) {
    guard let snapshot = SignatureCertificationSnapshot.build(for: document) else {
      presentAlert("Certification Unavailable", "This document has no readable PDF graph.")
      return
    }
    if snapshot.hasSignatures {
      presentAlert(
        "Already Signed",
        "A certification signature must be the document's first signature. "
          + "Inspect the existing signatures in Signature Details instead.")
      return
    }
    guard document.canSignDocument else {
      presentAlert(
        "Certification Unavailable",
        "Open the document and confirm it is not protected before certifying it.")
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
      let suffix = details?.issuerCommonName.map { " - issued by \($0)" } ?? ""
      identityPopup.addItem(withTitle: available.commonName + suffix)
    }
    let permissions = PDFDocMDPPermission.allCases
    let permissionPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 25))
    for permission in permissions {
      permissionPopup.addItem(
        withTitle: "\(permission.shortName): \(permission.summary)")
    }
    permissionPopup.selectItem(at: 1)
    let lockActions = ["No field lock", "All fields", "Include fields", "Exclude fields"]
    let lockPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    lockPopup.addItems(withTitles: lockActions)
    let lockFields = NSTextField(string: "")
    lockFields.placeholderString = "Existing field names separated by commas"
    let emptyFields = snapshot.fields.filter { !$0.isSigned }
    let targetPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    for field in emptyFields {
      targetPopup.addItem(withTitle: "Existing field: \(field.name)")
    }
    targetPopup.addItem(withTitle: "Create a new certification field")
    let newFieldName = NSTextField(string: suggestedFieldName(in: snapshot))
    newFieldName.placeholderString = "New field name"
    let reasonField = NSTextField(string: "")
    reasonField.placeholderString = "Reason (optional)"

    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Signer identity"), identityPopup],
      [NSTextField(labelWithString: "Certification"), permissionPopup],
      [NSTextField(labelWithString: "Field lock"), lockPopup],
      [NSTextField(labelWithString: "Locked fields"), lockFields],
      [NSTextField(labelWithString: "Signature field"), targetPopup],
      [NSTextField(labelWithString: "New field name"), newFieldName],
      [NSTextField(labelWithString: "Reason"), reasonField],
    ])
    grid.rowSpacing = 6
    grid.columnSpacing = 10
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.widthAnchor.constraint(equalToConstant: 560).isActive = true
    let note = NSTextField(wrappingLabelWithString:
      "The certification and any FieldMDP lock are written inside the signature revision. "
        + "The document is saved as a new certified copy; the original file is not modified.")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 560
    let stack = NSStackView(views: [grid, note])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10

    let alert = NSAlert()
    alert.messageText = "Certify Document"
    alert.alertStyle = .informational
    alert.accessoryView = stack
    alert.addButton(withTitle: "Certify...")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard identities.indices.contains(identityPopup.indexOfSelectedItem) else { return }
    let identity = identities[identityPopup.indexOfSelectedItem]

    guard permissions.indices.contains(permissionPopup.indexOfSelectedItem) else { return }
    let permission = permissions[permissionPopup.indexOfSelectedItem]
    let lockAction: PDFSignatureFieldLock.Action?
    switch lockPopup.indexOfSelectedItem {
    case 1: lockAction = .all
    case 2: lockAction = .include
    case 3: lockAction = .exclude
    default: lockAction = nil
    }
    let lock: PDFSignatureFieldLock?
    if let lockAction {
      let names = lockFields.stringValue.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      lock = PDFSignatureFieldLock(action: lockAction, fields: names)
    } else {
      lock = nil
    }
    let authoring = PDFSignatureAuthoring(
      certificationPermission: permission, fieldLock: lock)
    do {
      try authoring.validate(in: snapshot.graph)
    } catch {
      presentAlert("Certification Not Available", error.localizedDescription)
      return
    }

    let usesExisting = targetPopup.indexOfSelectedItem < emptyFields.count
    let fieldName: String
    let existingFieldName: String?
    if usesExisting {
      let field = emptyFields[targetPopup.indexOfSelectedItem]
      fieldName = field.name
      existingFieldName = field.name
    } else {
      fieldName = sanitizedFieldName(newFieldName.stringValue, in: snapshot)
      existingFieldName = nil
    }
    let options = PDFSigningOptions(
      fieldName: fieldName,
      pageIndex: max(0, (document.viewer?.pageNumber ?? 1) - 1),
      reason: reasonField.stringValue.isEmpty ? nil : reasonField.stringValue,
      existingFieldName: existingFieldName)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedOutputName(for: document)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try document.writeCertifiedCopy(
        to: url, identity: identity.identity, options: options, authoring: authoring)
      document.refreshSignatures()
      presentAlert(
        "Certified",
        "The certified copy was written to \(url.lastPathComponent). "
          + "The certification permission is \(permission.shortName) and the revision was "
          + "verified before it was offered for saving.")
    } catch {
      presentAlert("Certification Failed", error.localizedDescription)
    }
  }

  /// The declared representative review/approval/publish workflows, what each
  /// signer may change, and the remaining gaps.
  static func presentWorkflowGuide() {
    let hosting = NSHostingView(rootView: SigningWorkflowGuideView())
    hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
    let alert = NSAlert()
    alert.messageText = "Signing Workflows and Limits"
    alert.alertStyle = .informational
    alert.informativeText =
      "Representative sPDF signing workflows, the changes each signer may make, "
        + "and the declared limits that remain open in this release."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  // MARK: - Helpers

  private static func suggestedFieldName(in snapshot: SignatureCertificationSnapshot) -> String {
    let existing = Set(snapshot.fields.map(\.name))
    var index = 1
    while existing.contains("Certification\(index)") { index += 1 }
    return "Certification\(index)"
  }

  private static func sanitizedFieldName(
    _ raw: String, in snapshot: SignatureCertificationSnapshot
  ) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return suggestedFieldName(in: snapshot) }
    let existing = Set(snapshot.fields.map(\.name))
    guard existing.contains(trimmed) else { return trimmed }
    var index = 2
    while existing.contains("\(trimmed)\(index)") { index += 1 }
    return "\(trimmed)\(index)"
  }

  private static func suggestedOutputName(for document: SPDFDocument) -> String {
    let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    return base + "-certified.pdf"
  }

  static func presentAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

/// SIG-04: the report source for the status panel and the authoring preflight.
struct SignatureCertificationSnapshot {
  let report: PDFCertificationReport
  let fields: [PDFSignatureFieldInfo]
  let graph: PDFGraph

  var hasSignatures: Bool { fields.contains { $0.isSigned } }

  @MainActor
  static func build(for document: SPDFDocument) -> SignatureCertificationSnapshot? {
    let savedSource = document.sourceStore.snapshot()?.data
    let graph: PDFGraph?
    if let current = document.editSession.currentGraph {
      graph = current
    } else if let savedSource {
      graph = (try? PDFParser.parse(
        savedSource, limits: SPDFDocumentResourcePolicy.parsingLimits))?.graph
    } else {
      graph = nil
    }
    guard let graph else { return nil }
    let sourceBytes = savedSource ?? (try? PDFWriter.write(graph)) ?? Data()
    let fields = (try? PDFSignatureFieldInventory.fields(in: graph)) ?? []
    return SignatureCertificationSnapshot(
      report: PDFCertificationReport.read(source: sourceBytes, graph: graph),
      fields: fields, graph: graph)
  }
}

/// SIG-04: read-only certification status: the declared permission, exactly
/// which changes it allows and denies, the FieldMDP locks, and later changes.
struct SignatureCertificationStatusView: View {
  let snapshot: SignatureCertificationSnapshot

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        header
        if snapshot.report.isCertified {
          allowedChanges
          fieldLocks
          laterChanges
        }
        Text(
          "This report is offline evidence only: it does not add timestamps, "
            + "revocation data or long-term validation.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 480, minHeight: 300)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: snapshot.report.isCertified ? "checkmark.seal.fill" : "seal")
          .foregroundStyle(snapshot.report.isCertified ? .orange : .secondary)
        Text(stateTitle).font(.headline)
      }
      if let permission = snapshot.report.permission {
        Text(permission.summary).font(.caption).foregroundStyle(.secondary)
      }
      if let fieldName = snapshot.report.certificationFieldName {
        Text("Certification field: \(fieldName)").font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let validation = snapshot.report.validation {
        Text("Signature: \(cryptoText(validation)) - \(trustText(validation))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var allowedChanges: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Allowed after certification").font(.caption.weight(.semibold))
      if snapshot.report.allowedChanges.isEmpty {
        Text("No change is allowed; the certified file is final.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else {
        ForEach(snapshot.report.allowedChanges, id: \.rawValue) { change in
          Text("+ \(change.displayName)").font(.caption2)
        }
      }
      ForEach(snapshot.report.deniedChanges, id: \.rawValue) { change in
        Text("- \(change.displayName)").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var fieldLocks: some View {
    if !snapshot.report.fieldLocks.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("FieldMDP locks").font(.caption.weight(.semibold))
        ForEach(snapshot.report.fieldLocks.indices, id: \.self) { index in
          let lock = snapshot.report.fieldLocks[index]
          Text("\(lock.signingFieldName ?? "Signature"): \(lock.displayName)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var laterChanges: some View {
    if snapshot.report.laterChanges.isEmpty {
      Text("No later changes were found after the signed revision.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text("Changes after the signed revision").font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        ForEach(snapshot.report.laterChanges, id: \.self) { change in
          Text("! \(change)").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var stateTitle: String {
    switch snapshot.report.state {
    case .notCertified: return "Not certified"
    case .certified: return "Certified document"
    case .multipleCertifications: return "Multiple certifications (ambiguous)"
    case .unsupportedPermission(let value): return "Unsupported permission P\(value)"
    }
  }

  private func cryptoText(_ validation: PDFSignatureValidation) -> String {
    switch validation.crypto {
    case .valid: return "cryptographically valid"
    case .invalid: return "invalid"
    case .indeterminate: return "indeterminate"
    }
  }

  private func trustText(_ validation: PDFSignatureValidation) -> String {
    switch validation.trust {
    case .trusted: return "chain trusted"
    case .expired: return "signer certificate expired"
    case .missingAnchor, .untrusted, .unknown: return "trust not established offline"
    }
  }
}

/// SIG-05: the representative workflows, per-signer changes and declared gaps.
struct SigningWorkflowGuideView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(PDFSigningWorkflowGuide.workflows, id: \.id) { workflow in
          workflowCard(workflow)
        }
        boundariesCard
        gapsCard
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 560, minHeight: 380)
  }

  private func workflowCard(_ workflow: PDFSigningWorkflow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "person.2").foregroundStyle(.secondary)
        Text(workflow.title).font(.subheadline.weight(.semibold))
        Spacer()
        if let permission = workflow.certificationPermission {
          Text(permission.shortName).font(.caption2).foregroundStyle(.orange)
        }
      }
      Text(workflow.summary).font(.caption).foregroundStyle(.secondary)
      Text("Steps").font(.caption2.weight(.semibold))
      ForEach(workflow.steps, id: \.self) { step in
        Text("• \(step)").font(.caption2).foregroundStyle(.secondary)
      }
      Text("What each signer can change").font(.caption2.weight(.semibold))
      ForEach(workflow.signerChanges, id: \.self) { change in
        Text("* \(change)").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
  }

  private var boundariesCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Declared limits").font(.caption.weight(.semibold))
      ForEach(PDFSigningWorkflowGuide.declaredBoundaries, id: \.self) { boundary in
        Text("- \(boundary)").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var gapsCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Remaining gaps").font(.caption.weight(.semibold)).foregroundStyle(.orange)
      ForEach(PDFSigningWorkflowGuide.remainingGaps, id: \.self) { gap in
        Text("! \(gap)").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - SPDFDocument hooks (no stored state)

extension SPDFDocument {
  /// Hook: call from a Security menu item titled "Certify Document...".
  func presentSignatureCertification() {
    SignatureCertificationFlow.presentAuthoring(for: self)
  }

  /// Hook: call from a Security menu item titled "Certification & Field Locks...".
  func presentSignatureCertificationStatus() {
    SignatureCertificationFlow.presentStatus(for: self)
  }

  /// Hook: call from a Help or Security menu item titled "Signing Workflows...".
  func presentSigningWorkflowGuide() {
    SignatureCertificationFlow.presentWorkflowGuide()
  }

  /// Write a certified copy through the shared authoring writer and verify the
  /// produced bytes contain the authored certification before offering them.
  func writeCertifiedCopy(
    to url: URL, identity: SecIdentity, options: PDFSigningOptions,
    authoring: PDFSignatureAuthoring
  ) throws {
    let data: Data
    if !editSession.isDirty, let source = sourceStore.snapshot() {
      let parsed = try PDFParser.parse(
        source.data, limits: SPDFDocumentResourcePolicy.parsingLimits)
      data = try PDFSignatureAuthoringWriter.signIncremental(
        parsed, identity: identity, options: options, authoring: authoring,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
    } else {
      guard let graph = editSession.currentGraph else {
        throw PDFError(.malformed, "The document has no editable graph")
      }
      data = try PDFSignatureAuthoringWriter.sign(
        graph, identity: identity, options: options, authoring: authoring,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
    }
    try VerifiedFileWriter.write(data, to: url) { written in
      let parsed = try PDFParser.parse(
        written, limits: SPDFDocumentResourcePolicy.parsingLimits)
      let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
      guard signatures.contains(where: { $0.docMDPPermission != nil }) else {
        throw PDFError(.malformed, "The certified copy has no certification signature")
      }
    }
  }
}
