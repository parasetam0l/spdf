import PDFEditing
import SwiftUI

/// SIG-02/SIG-03 evidence panel: timestamp, revocation, trust and validity are
/// shown as separate rows with their own state, so "offline/not checked" is
/// never presented as "valid" and network failures keep an explicit state.
/// Reported as a hook for the Lead to host in the signatures window.
struct SignatureEvidencePanel: View {
  let validation: PDFSignatureValidation

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        revisionSection
        Divider()
        timestampSection
        Divider()
        revocationSection
        Divider()
        validitySection
        Divider()
        offlineModelNote
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 420, minHeight: 380)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(validation.signerIdentity?.displayName ?? validation.signerName ?? "Unknown signer")
        .font(.headline)
      Text("Cryptographic validity: \(validation.crypto.rawValue) · Certificate trust: \(validation.trust.rawValue)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var revisionSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Signed revision")
      row("Algorithm", validation.signatureAlgorithm ?? "Unknown")
      row("Digest", validation.digestAlgorithm ?? "Unknown")
      row("Covers whole file", validation.signatureCoversWholeFile ? "Yes" : "No")
      row("Later changes", validation.unsignedChanges
        ? "\(validation.changedObjectCount) changed object(s)" : "None detected")
      if validation.uncoveredTrailingBytes > 0 {
        row("Uncovered trailing bytes", "\(validation.uncoveredTrailingBytes)")
      }
    }
  }

  private var timestampSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("RFC 3161 timestamp")
      HStack {
        statusDot(timestampColor)
        Text(timestampTitle).font(.body)
      }
      if let genTime = validation.timestamp.genTime {
        row("Timestamp time", genTime.formatted(date: .abbreviated, time: .standard))
      }
      if let signer = validation.timestamp.signerName {
        row("TSA", signer)
      }
      if let trust = validation.timestamp.trust {
        row("TSA trust", trust.rawValue)
      }
      row("Imprint matches", validation.timestamp.imprintMatches ? "Yes" : "No")
      row("Timestamp signature", validation.timestamp.signatureValid ? "Valid" : "Not verified")
      if !validation.timestamp.details.isEmpty {
        disclosure("Timestamp details", validation.timestamp.details)
      }
    }
  }

  private var revocationSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Revocation")
      HStack {
        statusDot(revocationColor)
        Text(revocationTitle).font(.body)
      }
      if let source = validation.revocation.source {
        row("Source", source.rawValue.uppercased())
      }
      if let freshness = validation.revocation.freshness {
        row("Freshness", freshness.rawValue)
      }
      if let update = validation.revocation.thisUpdate {
        row("This update", update.formatted(date: .abbreviated, time: .standard))
      }
      if let next = validation.revocation.nextUpdate {
        row("Next update", next.formatted(date: .abbreviated, time: .standard))
      }
      if let time = validation.revocation.revocationTime {
        row("Revoked at", time.formatted(date: .abbreviated, time: .standard))
      }
      row("Checked", validation.revocationChecked ? "Yes" : "No")
      if !validation.revocation.details.isEmpty {
        disclosure("Revocation details", validation.revocation.details)
      }
    }
  }

  private var validitySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Certificate validity")
      row("Trust", validation.trust.rawValue)
      if let notBefore = validation.signerNotBefore {
        row("Not before", notBefore.formatted(date: .abbreviated, time: .standard))
      }
      if let notAfter = validation.signerNotAfter {
        row("Not after", notAfter.formatted(date: .abbreviated, time: .standard))
      }
      if let validationTime = validation.validationTime {
        row("Validated at", validationTime.formatted(date: .abbreviated, time: .standard))
      }
      disclosure("Validation details", validation.details)
    }
  }

  private var offlineModelNote: some View {
    Text(
      "Offline trust model: only certificates supplied as explicit anchors are trusted; "
        + "the system chain is evaluated without network access. Revocation is reported as "
        + "not checked unless an OCSP/CRL response was obtained explicitly. An unavailable "
        + "network check or an unverifiable timestamp is never shown as valid."
    )
    .font(.footnote)
    .foregroundStyle(.secondary)
  }

  private var timestampTitle: String {
    switch validation.timestamp.status {
    case .absent: return "No timestamp token"
    case .verified: return "Verified and trusted"
    case .verifiedUntrusted: return "Cryptographically verified; TSA chain not trusted offline"
    case .invalid: return "Timestamp evidence does not verify"
    case .unavailable: return "Timestamp unavailable"
    }
  }

  private var timestampColor: Color {
    switch validation.timestamp.status {
    case .verified: return .green
    case .verifiedUntrusted: return .orange
    case .invalid: return .red
    case .absent, .unavailable: return .secondary
    }
  }

  private var revocationTitle: String {
    switch validation.revocation.status {
    case .good: return "Not revoked (fresh evidence)"
    case .revoked: return "Revoked"
    case .stale: return "Response is stale"
    case .unknown: return "Unknown / not verifiable"
    case .unavailable: return "Check unavailable"
    case .notChecked: return "Not checked (offline default)"
    }
  }

  private var revocationColor: Color {
    switch validation.revocation.status {
    case .good: return .green
    case .revoked: return .red
    case .stale, .unknown: return .orange
    case .unavailable, .notChecked: return .secondary
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.subheadline).fontWeight(.semibold)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value).multilineTextAlignment(.trailing)
    }
    .font(.callout)
  }

  private func statusDot(_ color: Color) -> some View {
    Circle().fill(color).frame(width: 9, height: 9)
  }

  private func disclosure(_ title: String, _ lines: [String]) -> some View {
    DisclosureGroup(title) {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.caption)
  }
}
import SwiftUI

/// SIG-02/SIG-03 explicit networking preferences. The default is offline:
/// enabling the checkbox and allow-listing an https endpoint are both required
/// before any timestamp/revocation client may run. Reported as a hook for the
/// Lead to place under Settings or Tools > Security.
struct SignatureNetworkPreferencesPanel: View {
  @AppStorage("spdf.signature.network.enabled") private var networkEnabled = false
  @AppStorage("spdf.signature.timestamp.endpoint") private var timestampEndpoint = ""
  @AppStorage("spdf.signature.ocsp.endpoint") private var ocspEndpoint = ""
  @AppStorage("spdf.signature.crl.endpoint") private var crlEndpoint = ""

  var body: some View {
    Form {
      Section("Offline trust model") {
        Text(
          "Signing never requires a timestamp service, and existing signatures are "
            + "verified offline with explicit anchors. Revocation stays unchecked unless "
            + "you enable and allow-list the endpoints below for a specific action."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Toggle("Enable explicit network timestamp/revocation checks", isOn: $networkEnabled)
      }
      Section("RFC 3161 timestamp authority") {
        TextField("https://tsa.example.com", text: $timestampEndpoint)
          .textFieldStyle(.roundedBorder)
        endpointState(timestampEndpoint)
      }
      Section("Revocation endpoints") {
        TextField("https://ocsp.example.com", text: $ocspEndpoint)
          .textFieldStyle(.roundedBorder)
        endpointState(ocspEndpoint)
        TextField("https://crl.example.com/issuer.crl", text: $crlEndpoint)
          .textFieldStyle(.roundedBorder)
        endpointState(crlEndpoint)
      }
      Section {
        Text(
          "Endpoint changes are preferences only. A timestamp/revocation request still "
            + "requires an explicit action, and a network failure is reported as "
            + "unavailable rather than as good or valid."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 320)
  }

  @ViewBuilder
  private func endpointState(_ endpoint: String) -> some View {
    if endpoint.isEmpty {
      Text("No endpoint configured").font(.caption).foregroundStyle(.secondary)
    } else if endpoint.hasPrefix("https://"), URL(string: endpoint) != nil {
      Text("https endpoint; still requires the checkbox and an explicit action")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text("Refused: the endpoint must be an https URL")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}
