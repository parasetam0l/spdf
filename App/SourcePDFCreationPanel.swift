import PDFCore
import PDFEditing
import SwiftUI

/// EXP-04/EXP-05: creation-route panel. It states the decision per source kind,
/// the handoff steps, exactly what is and is not claimed to be preserved, and
/// the post-handoff verification report.
struct SourcePDFCreationPanel: View {
  @ObservedObject var model: SourcePDFCreationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      controls
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(Color.orange)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          decisionSection
          stepsSection
          preservationSection
          verificationSection
          disclosureSection
        }
        .padding(.trailing, 6)
      }
    }
    .padding(16)
    .frame(minWidth: 680, minHeight: 520, alignment: .topLeading)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Create a PDF from a source document").font(.headline)
      Text("The decision names the approved route and what still requires another "
        + "application; layout fidelity is always a human check.")
        .font(.subheadline).foregroundStyle(Color.secondary)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Source kind", selection: $model.kind) {
        ForEach(SourceDocumentKind.allCases, id: \.self) { kind in
          Text(kind.displayName).tag(kind)
        }
      }
      .frame(width: 320)
      HStack(spacing: 10) {
        Button("Choose Source File…") { model.chooseSource() }
        Button("Open Source Locally") { model.openSourceLocally() }
          .disabled(model.decision.route == .boundedSwiftImport)
        if model.decision.isBoundedConversion {
          Button("Create Text PDF") { model.createBoundedPlainText() }
          Button("Save Created PDF…") { model.saveCreatedPDF() }
        }
        Spacer()
        Button("Verify Produced PDF…") { model.verifyProducedPDF() }
      }
      if let url = model.sourceURL {
        Text(url.lastPathComponent).font(.caption).foregroundStyle(Color.secondary)
      }
    }
  }

  private var decisionSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Decision").font(.headline)
      Text("Route: " + model.decision.route.rawValue)
      if !model.decision.requiredApplications.isEmpty {
        Text("Requires: " + model.decision.requiredApplications.joined(separator: ", "))
          .font(.caption).foregroundStyle(Color.secondary)
      }
      Text("No upload · no embedded web view · no unapproved converter")
        .font(.caption).foregroundStyle(Color.secondary)
    }
  }

  private var stepsSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Handoff steps").font(.headline)
      ForEach(Array(model.decision.handoffSteps.enumerated()), id: \.offset) { index, step in
        Text("\(index + 1). " + step).font(.caption)
      }
      if !model.decision.manualChecks.isEmpty {
        Text("Manual checks").font(.headline).padding(.top, 4)
        ForEach(Array(model.decision.manualChecks.enumerated()), id: \.offset) { _, check in
          Text("• " + check).font(.caption).foregroundStyle(Color.secondary)
        }
      }
    }
  }

  private var preservationSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Preserved by the declared route").font(.headline)
      ForEach(Array(model.decision.preserved.enumerated()), id: \.offset) { _, item in
        Text("✓ " + item).font(.caption).foregroundStyle(Color.secondary)
      }
      Text("Not preserved / not claimed").font(.headline).padding(.top, 4)
      ForEach(Array(model.decision.notPreserved.enumerated()), id: \.offset) { _, item in
        Text("— " + item).font(.caption).foregroundStyle(Color.secondary)
      }
      if !model.decision.requiresAnotherApplication.isEmpty {
        Text("Requires another application").font(.headline).padding(.top, 4)
        ForEach(Array(model.decision.requiresAnotherApplication.enumerated()),
          id: \.offset) { _, item in
          Text("→ " + item).font(.caption).foregroundStyle(Color.secondary)
        }
      }
    }
  }

  private var verificationSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Verification").font(.headline)
      if let report = model.verification {
        Text(report.plainText).font(.caption).foregroundStyle(Color.secondary)
      } else {
        Text(model.reportText).font(.caption).foregroundStyle(Color.secondary)
      }
    }
  }

  private var disclosureSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      Divider()
      Text("Declared boundary").font(.caption.bold())
      Text(model.disclosure).font(.caption).foregroundStyle(Color.secondary)
      Text(model.decision.disclosure).font(.caption).foregroundStyle(Color.secondary)
    }
  }
}
