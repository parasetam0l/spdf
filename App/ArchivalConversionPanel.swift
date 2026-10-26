import PDFCore
import PDFEditing
import SwiftUI

/// PRE-01/PRE-02: PDF/A conversion panel. It shows profile-specific rules and
/// disclosures, the independent verdict, and allows saving only conforming
/// output.
struct ArchivalConversionPanel: View {
  @ObservedObject var model: ArchivalConversionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      controls
      if let problem = model.problem {
        Text(problem).font(.caption).foregroundStyle(Color.orange)
      }
      statusSection
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !model.checks.isEmpty { checksSection }
          if !model.losses.isEmpty { lossesSection }
          if !model.warnings.isEmpty { warningsSection }
          disclosureSection
        }
        .padding(.trailing, 6)
      }
    }
    .padding(16)
    .frame(minWidth: 680, minHeight: 500, alignment: .topLeading)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("PDF/A conversion").font(.headline)
      Text("One declared profile at a time; rules for attachments, transparency and fonts "
        + "come from that profile, not from a generalized assumption.")
        .font(.subheadline).foregroundStyle(Color.secondary)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Picker("Profile", selection: $model.profile) {
          ForEach(ArchivalConversionProfile.allCases, id: \.self) { profile in
            Text(profile.rawValue).tag(profile)
          }
        }
        .frame(width: 220)
        TextField("Document title (XMP)", text: $model.title)
          .frame(width: 260)
      }
      HStack(spacing: 10) {
        Button("Choose Associated File…") { model.chooseAssociatedFile() }
        Text(model.associatedFileName ?? "No associated file (PDF/A-3b only)")
          .font(.caption).foregroundStyle(Color.secondary)
        Spacer()
        Button("Convert") { model.convert() }
          .disabled(!model.canConvert)
        Button("Save Conversion…") { model.saveConversion() }
          .disabled(!model.canSave)
      }
    }
  }

  private var statusSection: some View {
    HStack(spacing: 10) {
      Text(model.statusText)
        .font(.body.bold())
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(
          model.canSave ? Color.green.opacity(0.18) : Color.orange.opacity(0.16))
        .clipShape(Capsule())
      Text(model.profile.rawValue + " · " + model.validationText)
        .font(.caption).foregroundStyle(Color.secondary)
    }
  }

  private var checksSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Conversion checks").font(.headline)
      ForEach(Array(model.checks.enumerated()), id: \.offset) { _, check in
        Text("[" + check.outcome.rawValue + "] " + check.rule + ": " + check.detail)
          .font(.caption)
          .foregroundStyle(check.outcome == .refused ? Color.orange : Color.secondary)
      }
    }
  }

  private var lossesSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Explicit losses").font(.headline)
      ForEach(Array(model.losses.enumerated()), id: \.offset) { _, loss in
        Text(loss).font(.caption).foregroundStyle(Color.secondary)
      }
    }
  }

  private var warningsSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Warnings").font(.headline)
      ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
        Text(warning).font(.caption).foregroundStyle(Color.orange)
      }
    }
  }

  private var disclosureSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Divider()
      Text("Declared profile").font(.caption.bold())
      Text(model.disclosure).font(.caption).foregroundStyle(Color.secondary)
      Text("A file is labelled conforming only after the independent validator accepts the "
        + "final saved bytes; refusals and validator failures never publish conforming output.")
        .font(.caption).foregroundStyle(Color.secondary)
    }
  }
}
