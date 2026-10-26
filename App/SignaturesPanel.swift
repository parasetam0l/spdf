import PDFEditing
import SwiftUI

/// P30-015/SIG-02/SIG-03: the signatures panel. Cryptographic validity,
/// certificate trust, revision-change status, RFC 3161 timestamp evidence and
/// revocation evidence are shown separately; the default offline state is
/// "revocation not checked", never "valid".
struct SignaturesPanel: View {
  let entries: [SignaturesModel.Entry]
  var onSelect: (Int) -> Void
  /// Optional host override; otherwise the row presents the evidence panel
  /// itself via the shared presentation controller.
  var onShowEvidence: ((PDFSignatureValidation) -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if entries.isEmpty {
        WorkspacePanelEmptyState(
          title: "No digital signatures", symbol: "signature",
          detail: "This PDF has not been digitally signed.")
      } else {
        List(entries) { entry in
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              statusIcon(entry.validation)
              Text(entry.signature.fieldName ?? "Document timestamp")
                .font(.subheadline.weight(.semibold))
              Spacer()
              if entry.signature.kind == .documentTimestamp {
                Text("Timestamp").font(.caption).foregroundStyle(.secondary)
              }
            }
            Text(statusText(entry.validation))
              .font(.caption)
              .foregroundStyle(statusColor(entry.validation))
            if let signer = entry.validation.signerName {
              Text(signer).font(.caption).foregroundStyle(.secondary)
            }
            if let algorithm = entry.validation.signatureAlgorithm {
              Text(algorithm).font(.caption2).foregroundStyle(.secondary)
            }
            Text(SignatureEvidencePresentation.summaryLine(entry.validation))
              .font(.caption2)
              .foregroundStyle(.secondary)
            Button("Evidence…") {
              presentEvidence(entry.validation)
            }
            .buttonStyle(.link)
            .font(.caption)
            .accessibilityLabel("Show signature evidence")
            if entry.validation.unsignedChanges {
              Text(
                "The document changed after signing (\(entry.validation.changedObjectCount) objects)"
              )
              .font(.caption2)
              .foregroundStyle(.orange)
            }
            if let permission = entry.signature.docMDPPermission {
              Text("Certification permission: \(permission)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let pageIndex = entry.signature.pageIndex {
              Button("Show Page") { onSelect(pageIndex) }
                .buttonStyle(.link)
                .font(.caption)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Signatures")
  }

  private func presentEvidence(_ validation: PDFSignatureValidation) {
    if let onShowEvidence {
      onShowEvidence(validation)
    } else {
      SignatureEvidencePresentation.present(validation)
    }
  }

  private func statusIcon(_ validation: PDFSignatureValidation) -> some View {
    Image(
      systemName: validation.crypto == .valid
        ? "checkmark.seal.fill"
        : (validation.crypto == .invalid ? "xmark.seal.fill" : "questionmark.circle")
    )
    .foregroundStyle(statusColor(validation))
  }

  private func statusColor(_ validation: PDFSignatureValidation) -> Color {
    switch validation.crypto {
    case .valid:
      switch validation.trust {
      case .trusted: return .green
      case .unknown, .untrusted, .missingAnchor: return .yellow
      case .expired: return .orange
      }
    case .invalid: return .red
    case .indeterminate: return .secondary
    }
  }

  private func statusText(_ validation: PDFSignatureValidation) -> String {
    switch validation.crypto {
    case .valid:
      switch validation.trust {
      case .trusted: return "Cryptographically valid; certificate chain trusted"
      case .unknown: return "Cryptographically valid; chain not anchored by a trusted root"
      case .untrusted: return "Cryptographically valid; certificate chain untrusted"
      case .missingAnchor:
        return "Cryptographically valid; chain not anchored by the supplied roots"
      case .expired: return "Cryptographically valid; signer certificate expired"
      }
    case .invalid:
      return "Invalid: " + (validation.details.last ?? "the signature does not verify")
    case .indeterminate:
      return "Indeterminate: " + (validation.details.last ?? "unsupported evidence")
    }
  }
}
