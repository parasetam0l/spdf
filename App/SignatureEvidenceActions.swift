import AppKit
import PDFCore
import PDFEditing
import SwiftUI

/// SIG-02/SIG-03 App hosting: presents the evidence panel and the explicit
/// network preferences. Both are read-only surfaces; no document bytes change
/// and no network is touched just by opening them. The Lead wires the menu
/// items/selectors reported in SESSION.md; no state is added to SPDFDocument.
@MainActor
enum SignatureEvidencePresentation {
  static func present(_ validation: PDFSignatureValidation) {
    let hosting = NSHostingView(rootView: SignatureEvidencePanel(validation: validation))
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 480)
    let alert = NSAlert()
    alert.messageText = "Signature Evidence"
    alert.alertStyle = .informational
    alert.informativeText = evidenceSummary(validation)
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  static func presentNetworkPreferences() {
    let hosting = NSHostingView(rootView: SignatureNetworkPreferencesPanel())
    hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
    let alert = NSAlert()
    alert.messageText = "Signature Network Preferences"
    alert.alertStyle = .informational
    alert.informativeText =
      "Network timestamp and revocation checks are disabled by default. "
        + "Opening this panel changes nothing; an enabled, allow-listed endpoint "
        + "is still only used by an explicit timestamp or revocation action."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  /// A one-line status used above the detailed panel and in signature rows.
  static func summaryLine(_ validation: PDFSignatureValidation) -> String {
    return "Trust: " + validation.trust.rawValue
      + " · Timestamp: " + timestampStatusText(validation)
      + " · Revocation: " + revocationStatusText(validation)
  }

  static func evidenceSummary(_ validation: PDFSignatureValidation) -> String {
    var lines: [String] = []
    lines.append(
      "Cryptographic validity: " + validation.crypto.rawValue
        + "; certificate trust: " + validation.trust.rawValue + ".")
    if let notAfter = validation.signerNotAfter {
      lines.append(
        "Signer certificate valid until " + notAfter.formatted(date: .abbreviated, time: .shortened) + ".")
    }
    lines.append("RFC 3161 timestamp: " + timestampStatusText(validation) + ".")
    lines.append("Revocation: " + revocationStatusText(validation) + ".")
    let policy = currentNetworkPolicy()
    if policy.isEnabled {
      lines.append(
        "Network checks: enabled for " + String(policy.allowedEndpoints.count)
          + " allow-listed endpoint(s); a check still requires an explicit action.")
    } else {
      lines.append("Network checks: disabled (offline default).")
    }
    return lines.joined(separator: "\n")
  }

  static func timestampStatusText(_ validation: PDFSignatureValidation) -> String {
    switch validation.timestamp.status {
    case .absent:
      return "not present (this signature has no RFC 3161 token)"
    case .verified:
      if let time = validation.timestamp.genTime {
        return "verified and trusted at " + time.formatted(date: .abbreviated, time: .standard)
      }
      return "verified and trusted"
    case .verifiedUntrusted:
      return "cryptographically verified; TSA chain not trusted offline"
    case .invalid:
      return "evidence does not verify"
    case .unavailable:
      return "requested but unavailable"
    }
  }

  static func revocationStatusText(_ validation: PDFSignatureValidation) -> String {
    let evidence = validation.revocation
    switch evidence.status {
    case .good:
      return "not revoked (fresh evidence; " + (evidence.source?.rawValue.uppercased() ?? "unknown") + ")"
    case .revoked:
      return "revoked"
    case .stale:
      return "response is stale, not current evidence"
    case .unknown:
      return "unknown / not verifiable"
    case .unavailable:
      return "check unavailable, not valid evidence"
    case .notChecked:
      return "not checked (offline default)"
    }
  }

  /// Preferences-backed policy for any explicit timestamp/revocation action the
  /// Lead wires later. Offline remains the default; only https endpoints from
  /// the preferences panel are included.
  static func currentNetworkPolicy() -> SignatureNetworkPolicy {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: "spdf.signature.network.enabled") else { return .disabled }
    var endpoints: Set<String> = []
    for key in [
      "spdf.signature.timestamp.endpoint",
      "spdf.signature.ocsp.endpoint",
      "spdf.signature.crl.endpoint",
    ] {
      guard let value = defaults.string(forKey: key)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.hasPrefix("https://"),
        URL(string: value) != nil
      else { continue }
      endpoints.insert(value)
    }
    return SignatureNetworkPolicy(isEnabled: true, allowedEndpoints: endpoints)
  }
}

extension SPDFDocument {
  /// Menu validation hook for "Signature Evidence…".
  var canShowSignatureEvidence: Bool {
    viewer != nil || editSession.currentGraph != nil
  }

  /// Hook: call from the "Signature Evidence…" menu item. Presents evidence for
  /// the only signed revision, or a chooser when several signatures exist.
  @MainActor
  func presentSignatureEvidence() {
    let snapshot = SignatureMultiSignerSnapshot.build(for: self)
    let revisions = snapshot?.report.revisions ?? []
    guard !revisions.isEmpty else {
      presentSignatureEvidenceAlert(
        "Signature Evidence Unavailable",
        "This document has no signed revision to inspect.")
      return
    }
    if revisions.count == 1, let validation = revisions.first?.validation {
      SignatureEvidencePresentation.present(validation)
      return
    }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 25))
    for revision in revisions {
      let field = revision.fieldName ?? "field"
      popup.addItem(
        withTitle: "Signature " + String(revision.index) + ": " + field
          + (revision.isCertification ? " (certification)" : ""))
    }
    let alert = NSAlert()
    alert.messageText = "Signature Evidence"
    alert.alertStyle = .informational
    alert.informativeText = "Choose the signed revision whose timestamp/revocation evidence to inspect."
    alert.accessoryView = popup
    alert.addButton(withTitle: "Show Evidence…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn,
      revisions.indices.contains(popup.indexOfSelectedItem)
    else { return }
    SignatureEvidencePresentation.present(revisions[popup.indexOfSelectedItem].validation)
  }

  /// Hook: call from the "Signature Network Preferences…" menu item.
  @MainActor
  func presentSignatureNetworkPreferences() {
    SignatureEvidencePresentation.presentNetworkPreferences()
  }

  /// Hook used by the signing flow after an output is written: validates the
  /// written bytes and returns the evidence-driven status line.
  @MainActor
  func signatureEvidenceSummary(forSignedFile url: URL) -> String? {
    do {
      let data = try Data(contentsOf: url)
      let parsed = try PDFParser.parse(
        data, limits: SPDFDocumentResourcePolicy.parsingLimits)
      guard let signature = try PDFSignatureInventory.signatures(in: parsed.graph).last else {
        return nil
      }
      let validation = PDFSignatureValidator.validate(
        signature, source: data, finalGraph: parsed.graph)
      return SignatureEvidencePresentation.summaryLine(validation)
    } catch {
      return nil
    }
  }

  private func presentSignatureEvidenceAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
