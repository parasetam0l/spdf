import PDFCore
import PDFEditing
import SwiftUI

/// SIG-04: the long-term validation panel. It reports the supported profile,
/// the embedded DSS store, per-signature completeness and archival timestamps,
/// and never claims more than the embedded evidence supports.
struct SignatureLTVPanel: View {
  @ObservedObject var model: SignatureLongTermValidationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let problem = model.problem {
        Text(problem).foregroundStyle(Color.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            profileSection
            dssSection
            signatureSection
            if !model.documentTimestamps.isEmpty { timestampSection }
            if !model.warnings.isEmpty { warningSection }
            disclosureSection
          }
          .padding(.trailing, 6)
        }
      }
    }
    .padding(16)
    .frame(minWidth: 640, minHeight: 460, alignment: .topLeading)
    .onAppear { model.reload() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Long-term validation evidence")
        .font(.headline)
      Text(
        "Offline evaluation of embedded PAdES/DSS evidence. Long-term status is claimed "
          + "only for the disclosed profile; incomplete evidence is reported as incomplete.")
        .font(.subheadline)
        .foregroundStyle(Color.secondary)
    }
  }

  private var profileSection: some View {
    HStack(spacing: 10) {
      Text(model.profile.rawValue)
        .font(.body.bold())
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
          model.isLongTermValid ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
        .clipShape(Capsule())
      Text(model.isLongTermValid
        ? "Embedded evidence covers this profile."
        : "Embedded evidence is not sufficient for this profile.")
        .font(.caption)
        .foregroundStyle(Color.secondary)
    }
  }

  private var dssSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Document security store").font(.headline)
      if !model.dss.hasDSS {
        Text("No /DSS dictionary is present.").foregroundStyle(Color.secondary)
      } else {
        Text(
          "\(model.dss.certificateCount) certificate(s) · "
            + "\(model.dss.ocspCount) OCSP response(s) · "
            + "\(model.dss.crlCount) CRL(s) · "
            + "\(model.dss.vriCount) VRI entr\(model.dss.vriCount == 1 ? "y" : "ies")")
          .font(.caption)
          .foregroundStyle(Color.secondary)
      }
    }
  }

  private var signatureSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Certificate signatures").font(.headline)
      if model.signatures.isEmpty {
        Text("No certificate signatures were found.").foregroundStyle(Color.secondary)
      } else {
        ForEach(Array(model.signatures.enumerated()), id: \.offset) { _, signature in
          signatureRow(signature)
        }
      }
    }
  }

  private func signatureRow(_ signature: PDFLongTermSignatureEvidence) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(signature.status.rawValue)
        .font(.caption.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
          signature.isLongTermComplete
            ? Color.green.opacity(0.16) : Color.orange.opacity(0.16))
        .clipShape(Capsule())
      VStack(alignment: .leading, spacing: 2) {
        Text("“\(signature.fieldName)”" + (signature.signerName.map { " — \($0)" } ?? ""))
        Text(
          "VRI: \(signature.hasVRIEntry ? "yes" : "no") · signer certificate embedded: "
            + "\(signature.signerCertificateEmbedded ? "yes" : "no") · signature timestamp: "
            + signature.signatureTimestamp.status.rawValue)
          .font(.caption)
          .foregroundStyle(Color.secondary)
        Text("Revocation: \(signature.revocation.status.rawValue)")
          .font(.caption)
          .foregroundStyle(Color.secondary)
        if !signature.cryptoValid {
          Text("Cryptographic verification did not pass.").font(.caption)
            .foregroundStyle(Color.orange)
        }
      }
    }
  }

  private var timestampSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Archival document timestamps").font(.headline)
      ForEach(Array(model.documentTimestamps.enumerated()), id: \.offset) { _, timestamp in
        Text(
          "\(timestamp.status.rawValue) · whole file: \(timestamp.coversWholeFile ? "yes" : "no")"
            + " · imprint matches: \(timestamp.imprintMatches ? "yes" : "no")")
          .font(.caption)
          .foregroundStyle(Color.secondary)
      }
    }
  }

  private var warningSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
        Text(warning).font(.caption).foregroundStyle(Color.orange)
      }
    }
  }

  private var disclosureSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Divider()
      Text("Supported profile").font(.caption.bold())
      Text(model.disclosure).font(.caption).foregroundStyle(Color.secondary)
    }
  }
}
