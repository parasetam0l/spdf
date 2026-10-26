import PDFCore
import PDFEditing
import SwiftUI

/// SIG-07: the presentation panel separates cryptographic signatures from
/// visible marks. Certificate rows state visible/hidden; mark rows repeat that
/// they are not digital signatures. The panel is read-only.
struct SignaturePresentationPanel: View {
  @ObservedObject var model: SignaturePresentationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let problem = model.problem {
        Text(problem)
          .foregroundStyle(Color.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            certificateSection
            markSection
            if !model.warnings.isEmpty { warningSection }
            disclosureFooter
          }
          .padding(.trailing, 6)
        }
      }
    }
    .padding(16)
    .frame(minWidth: 600, minHeight: 420, alignment: .topLeading)
    .onAppear { model.reload() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Certificate signatures and visible marks are different")
        .font(.headline)
      Text(
        "Certificate signatures carry cryptographic evidence. Visible signature marks are "
          + "drawn or typed ink and never authenticate the document.")
        .font(.subheadline)
        .foregroundStyle(Color.secondary)
    }
  }

  private var certificateSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Certificate signatures").font(.headline)
        Text(
          "\(model.certificateSignatures.count) total · "
            + "\(model.visibleCertificateSignatures.count) visible · "
            + "\(model.hiddenCertificateSignatures.count) hidden")
          .font(.caption)
          .foregroundStyle(Color.secondary)
      }
      if model.certificateSignatures.isEmpty {
        Text("No certificate signatures (cryptographic evidence) were found.")
          .foregroundStyle(Color.secondary)
      } else {
        ForEach(Array(model.certificateSignatures.enumerated()), id: \.offset) { _, entry in
          certificateRow(entry)
        }
      }
    }
  }

  private func certificateRow(_ entry: PDFCertificateSignaturePresentation) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(entry.visibility.rawValue)
        .font(.caption.bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
          entry.visibility == .visible ? Color.green.opacity(0.18) : Color.orange.opacity(0.20))
        .clipShape(Capsule())
      VStack(alignment: .leading, spacing: 2) {
        Text("“\(entry.fieldName)”" + (entry.signerName.map { " — \($0)" } ?? ""))
          .font(.body)
        Text(entry.disclosure)
          .font(.caption)
          .foregroundStyle(Color.secondary)
        if let reason = entry.reason {
          Text("Classified hidden: \(reason).")
            .font(.caption)
            .foregroundStyle(Color.secondary)
        }
        if entry.isCertification {
          Text("Certification signature (DocMDP permission).")
            .font(.caption)
            .foregroundStyle(Color.secondary)
        }
      }
    }
  }

  private var markSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Visible signature marks").font(.headline)
        Text("\(model.graphicalMarks.count) mark(s) · not digital signatures")
          .font(.caption)
          .foregroundStyle(Color.secondary)
      }
      if model.graphicalMarks.isEmpty {
        Text("No visible signature marks were found.")
          .foregroundStyle(Color.secondary)
      } else {
        ForEach(Array(model.graphicalMarks.enumerated()), id: \.offset) { _, mark in
          HStack(alignment: .top, spacing: 8) {
            Text("Mark")
              .font(.caption.bold())
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.15))
              .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
              Text("Page \(mark.pageIndex + 1)" + (mark.subject.map { " — \($0)" } ?? ""))
              Text(PDFGraphicalSignatureMark.disclosure)
                .font(.caption)
                .foregroundStyle(Color.secondary)
              if let contents = mark.contents {
                Text(contents).font(.caption).foregroundStyle(Color.secondary)
              }
            }
          }
        }
      }
    }
  }

  private var warningSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
        Text(warning)
          .font(.caption)
          .foregroundStyle(Color.orange)
      }
    }
  }

  private var disclosureFooter: some View {
    VStack(alignment: .leading, spacing: 3) {
      Divider()
      Text(PDFSignaturePresentationMode.visibleAppearance.disclosure)
      Text(PDFSignaturePresentationMode.hiddenCertificate.disclosure)
      Text(PDFGraphicalSignatureMark.disclosure)
      Text("Hiding or drawing a mark never changes cryptographic evidence, and a mark never "
        + "counts as a certificate signature in this report, the signature details or the "
        + "document status.")
        .foregroundStyle(Color.secondary)
    }
    .font(.caption)
    .foregroundStyle(Color.secondary)
  }
}
