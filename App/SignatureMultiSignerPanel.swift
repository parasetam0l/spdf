import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

/// SIG-06: the multi-signer snapshot for the signatures sidebar and the
/// signed-revision inspector: every signature field (empty or signed), the
/// per-revision report, and the current signing-permission decision.
struct SignatureMultiSignerSnapshot {
  let fields: [PDFSignatureFieldInfo]
  let report: PDFSignedRevisionReport
  /// Field name -> refusal reason for an incremental signature there.
  let fieldDecisions: [String: String]
  let hasSignatures: Bool

  var emptyFields: [PDFSignatureFieldInfo] { fields.filter { !$0.isSigned } }
  var signedFields: [PDFSignatureFieldInfo] { fields.filter(\.isSigned) }

  /// Build from the document's current graph, preferring the on-disk source so
  /// a signature report always describes bytes that actually exist.
  @MainActor
  static func build(for document: SPDFDocument) -> SignatureMultiSignerSnapshot? {
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
    // The revision report always describes bytes that exist: the saved source
    // when available, otherwise the serialized current graph.
    let sourceBytes = savedSource ?? (try? PDFWriter.write(graph)) ?? Data()
    let fields = (try? PDFSignatureFieldInventory.fields(in: graph)) ?? []
    var decisions: [String: String] = [:]
    for field in fields where !field.isSigned {
      let decision = try? PDFSignatureSigningPolicy.decision(
        in: graph, target: .existingField(name: field.name))
      if case .refused(let reason) = decision {
        decisions[field.name] = reason
      }
    }
    let report = PDFSignedRevisionReport.build(source: sourceBytes, graph: graph)
    return SignatureMultiSignerSnapshot(
      fields: fields, report: report, fieldDecisions: decisions,
      hasSignatures: !fields.filter(\.isSigned).isEmpty || !report.revisions.isEmpty)
  }

  func decisionMessage(for target: PDFSignatureSigningTarget, in graph: PDFGraph?) -> String? {
    guard let graph else { return "The document has no editable graph" }
    guard let decision = try? PDFSignatureSigningPolicy.decision(in: graph, target: target)
    else { return "Signing permissions could not be evaluated" }
    if case .refused(let reason) = decision { return reason }
    return nil
  }
}

/// SIG-06: sidebar state for signature fields and the signed-revision report.
final class SignatureMultiSignerModel: ObservableObject {
  @Published var snapshot: SignatureMultiSignerSnapshot?
  @Published var statusNote: String?

  @MainActor
  func refresh(from document: SPDFDocument) {
    snapshot = SignatureMultiSignerSnapshot.build(for: document)
    if let snapshot {
      statusNote = snapshot.report.hasLaterChanges
        ? "Unsigned changes exist after the last signature"
        : nil
    } else {
      statusNote = "No document is open"
    }
  }
}

/// SIG-06: a compact list of signature fields for the signatures sidebar.
struct SignatureFieldList: View {
  let snapshot: SignatureMultiSignerSnapshot
  var onSelect: (PDFSignatureFieldInfo) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if snapshot.fields.isEmpty {
        Text("No signature fields")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(snapshot.fields, id: \.name) { field in
          Button {
            onSelect(field)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: field.isSigned ? "checkmark.seal.fill" : "square.dashed")
                .foregroundStyle(field.isSigned ? .green : .secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(field.name).font(.subheadline.weight(.medium))
                Text(field.isSigned
                  ? "Signed\(field.signature?.name.map { " by \($0)" } ?? "")"
                  : "Empty signature field")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if let permission = field.docMDPPermission {
                Text("Cert P\(permission)").font(.caption2).foregroundStyle(.orange)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(field.pageIndex == nil)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Signature fields")
  }
}

/// SIG-06: the signed-revision inspector: what each signature covers, who
/// signed it, and what changed between consecutive signatures.
struct SignatureRevisionInspectorView: View {
  let snapshot: SignatureMultiSignerSnapshot
  /// Optional host override; otherwise each revision presents the evidence
  /// panel through the shared presentation controller.
  var onShowEvidence: ((PDFSignatureValidation) -> Void)? = nil
  var onShowPage: @MainActor (Int) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if snapshot.report.revisions.isEmpty {
          Text("This document has no digital signatures.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(snapshot.report.revisions, id: \.index) { revision in
            revisionCard(revision)
          }
          if snapshot.report.hasLaterChanges {
            VStack(alignment: .leading, spacing: 4) {
              Text("Unsigned changes after the last signature")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
              ForEach(snapshot.report.changesSinceLastSignature, id: \.self) { change in
                Text("• \(change)").font(.caption2).foregroundStyle(.secondary)
              }
              if snapshot.report.finalUncoveredByteCount > 0 {
                Text(
                  "\(snapshot.report.finalUncoveredByteCount) byte(s) after the last signature "
                    + "are not covered")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
            }
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 420, minHeight: 240)
  }

  @ViewBuilder
  private func revisionCard(_ revision: PDFSignedRevision) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: statusSymbol(revision.validation))
          .foregroundStyle(statusColor(revision.validation))
        Text("Signature \(revision.index): \(revision.fieldName ?? "field")")
          .font(.subheadline.weight(.semibold))
        Spacer()
        if revision.isCertification {
          Text("Certification P\(revision.docMDPPermission ?? 0)")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      if let identity = revision.signerIdentity {
        Text(identity.displayName).font(.caption)
        if let email = identity.emailAddress {
          Text(email).font(.caption2).foregroundStyle(.secondary)
        }
      }
      Text(
        "Covers \(revision.signedByteCount) byte(s) through offset "
          + "\(revision.coverageEnd)\(revision.laterRevisions ? "; later revisions exist" : "")")
        .font(.caption2)
        .foregroundStyle(.secondary)
      if let algorithm = revision.validation.signatureAlgorithm {
        Text(algorithm).font(.caption2).foregroundStyle(.secondary)
      }
      Text(statusText(revision.validation))
        .font(.caption2)
        .foregroundStyle(statusColor(revision.validation))
      Text(SignatureEvidencePresentation.summaryLine(revision.validation))
        .font(.caption2)
        .foregroundStyle(.secondary)
      Button("Evidence…") {
        if let onShowEvidence {
          onShowEvidence(revision.validation)
        } else {
          SignatureEvidencePresentation.present(revision.validation)
        }
      }
      .buttonStyle(.link)
      .font(.caption2)
      .accessibilityLabel("Show signature evidence")
      if !revision.changesSincePrevious.isEmpty {
        Text("Changed since the previous signature:")
          .font(.caption2.weight(.semibold))
        ForEach(revision.changesSincePrevious, id: \.self) { change in
          Text("• \(change)").font(.caption2).foregroundStyle(.secondary)
        }
      }
      if let pageIndex = revision.signature.pageIndex {
        Button("Show Page") { onShowPage(pageIndex) }
          .buttonStyle(.link)
          .font(.caption2)
      }
    }
    .padding(8)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
  }

  private func statusSymbol(_ validation: PDFSignatureValidation) -> String {
    switch validation.crypto {
    case .valid: return "checkmark.seal.fill"
    case .invalid: return "xmark.seal.fill"
    case .indeterminate: return "questionmark.circle"
    }
  }

  private func statusColor(_ validation: PDFSignatureValidation) -> Color {
    switch validation.crypto {
    case .valid:
      switch validation.trust {
      case .trusted: return .green
      case .expired: return .orange
      default: return .yellow
      }
    case .invalid: return .red
    case .indeterminate: return .secondary
    }
  }

  private func statusText(_ validation: PDFSignatureValidation) -> String {
    switch validation.crypto {
    case .valid:
      switch validation.trust {
      case .trusted: return "Cryptographically valid; chain trusted"
      case .expired: return "Cryptographically valid; signer certificate expired"
      default: return "Cryptographically valid; chain not anchored by a trusted root"
      }
    case .invalid:
      return "Invalid: " + (validation.details.last ?? "the signature does not verify")
    case .indeterminate:
      return "Indeterminate: " + (validation.details.last ?? "unsupported evidence")
    }
  }
}
