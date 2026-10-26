import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// FRM-08: visible save-time form validation and lifecycle qualification. The
// panel is read-only; findings are graded, tied to fields and copyable as JSON
// so a save path can surface the same warnings.

@MainActor
final class FormValidationPanelModel: ObservableObject {
  struct FindingRow: Identifiable, Equatable {
    let id: String
    let severity: FormValidationSeverity
    let code: String
    let field: String
    let message: String
    let disclosure: String
  }

  struct StageRow: Identifiable, Equatable {
    let id: String
    let name: String
    let passed: Bool
    let notes: String
  }

  @Published var summary = "Run save validation to check required values, declared rules and actions."
  @Published var saveDisclosure = ""
  @Published var findingRows: [FindingRow] = []
  @Published var stageRows: [StageRow] = []
  @Published var lifecycleSummary = ""
  @Published var signatureNotes = ""
  @Published var statusText = "Validation is read-only."
  @Published var errorText: String?
  @Published var hasBlockingErrors = false
  @Published var reportJSON = ""

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
  }

  func runValidation() {
    errorText = nil
    guard let report = document?.formSaveValidationReport() else {
      errorText = "No form document is available to validate."
      return
    }
    summary = report.summary
    saveDisclosure = report.saveDisclosure
    hasBlockingErrors = report.hasBlockingErrors
    findingRows = report.findings.map { finding in
      FindingRow(
        id: finding.id, severity: finding.severity, code: finding.code.rawValue,
        field: finding.fieldName ?? "—", message: finding.message,
        disclosure: finding.disclosure)
    }
    reportJSON = FormSaveValidation.json(report).flatMap { String(data: $0, encoding: .utf8) }
      ?? ""
    statusText = report.findings.isEmpty
      ? "No save-time issues were found."
      : String(report.findings.count) + " finding(s) listed."
  }

  func runLifecycleQualification() {
    errorText = nil
    guard let report = document?.runFormLifecycleQualification() else {
      errorText = "Lifecycle qualification could not run (it needs a document with fields)."
      return
    }
    lifecycleSummary = report.summary
    signatureNotes = report.signatureNotes.joined(separator: " ")
    stageRows = report.stages.map { stage in
      StageRow(
        id: stage.name, name: stage.name, passed: stage.passed,
        notes: stage.notes.joined(separator: " · "))
    }
    statusText = report.passed
      ? "Lifecycle qualification passed every stage."
      : "Lifecycle qualification failed: "
        + report.failedStages.map(\.name).joined(separator: ", ") + "."
  }

  func copyJSON() {
    guard !reportJSON.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(reportJSON, forType: .string)
    statusText = "Copied the validation report JSON."
  }

  func exportReport(to url: URL) {
    guard let data = reportJSON.data(using: .utf8) else { return }
    do {
      try data.write(to: url)
      statusText = "Exported the validation report."
    } catch {
      errorText = error.localizedDescription
    }
  }
}

@MainActor
final class FormValidationPanelController: NSWindowController {
  let model: FormValidationPanelModel

  init(document: SPDFDocument) {
    let model = FormValidationPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Form Validation"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 760, height: 560)
    panel.contentView = NSHostingView(rootView: FormValidationPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the form validation panel")
  }
}

extension SPDFDocument {
  /// Form > Validate Form for Save…: show the graded save-time findings.
  func showFormValidationPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? FormValidationPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FormValidationPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowFormValidationPanel: Bool { editSession.currentGraph != nil }

  /// The save-time report the Lead-owned save path can surface verbatim.
  func formSaveValidationReport() -> FormSaveValidationReport? {
    guard let graph = editSession.currentGraph else { return nil }
    return FormSaveValidation.validate(in: graph, pageIDs: editSession.pageIDs)
  }

  /// Read-only lifecycle qualification of the current document.
  func runFormLifecycleQualification() -> FormLifecycleQualificationReport? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? FormLifecycleQualification.run(in: graph, pageIDs: editSession.pageIDs)
  }
}

// MARK: - SwiftUI panel

struct FormValidationPanelView: View {
  @ObservedObject var model: FormValidationPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        findingsSection
        Divider()
        lifecycleSection
        footer
      }
      .padding(18)
    }
    .frame(minWidth: 760, minHeight: 560)
    .accessibilityLabel("Form validation report")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Form Validation").font(.title3).bold()
        Spacer()
        Button("Run Save Validation") { model.runValidation() }
        Button("Copy Report JSON") { model.copyJSON() }
          .disabled(model.reportJSON.isEmpty)
      }
      Text(model.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
      if !model.saveDisclosure.isEmpty {
        Text(model.saveDisclosure).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(model.statusText).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var findingsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Save-time findings").font(.headline)
        if model.hasBlockingErrors {
          Text("blocking errors").font(.caption2).foregroundStyle(.red)
        }
      }
      if model.findingRows.isEmpty {
        Text("Run save validation to list required fields, declared rules, imported actions, "
          + "appearance and signature findings.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.findingRows) { row in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(row.severity.label).font(.caption2).bold()
              .foregroundStyle(color(for: row.severity))
              .frame(width: 64, alignment: .leading)
            Text(row.field).font(.caption2).foregroundStyle(.secondary)
              .frame(width: 160, alignment: .leading)
            Text(row.message).font(.caption2)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text(row.disclosure).font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
      }
    }
  }

  private var lifecycleSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Lifecycle qualification").font(.headline)
        Spacer()
        Button("Run Lifecycle Qualification") { model.runLifecycleQualification() }
      }
      if model.lifecycleSummary.isEmpty {
        Text(
          "Fill → page operations → save/reopen → flatten → export preserves canonical values, "
            + "appearances and field order; run the qualification to check this document.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(model.lifecycleSummary).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        if !model.signatureNotes.isEmpty {
          Text(model.signatureNotes).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.stageRows) { stage in
          HStack(alignment: .top, spacing: 8) {
            Text(stage.passed ? "Pass" : "Fail").font(.caption2).bold()
              .foregroundStyle(stage.passed ? Color.green : Color.red)
              .frame(width: 46, alignment: .leading)
            Text(stage.name).font(.caption).bold()
              .frame(width: 170, alignment: .leading)
            Text(stage.notes).font(.caption2).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "Validation and qualification are read-only and never execute an imported action. "
          + "The Lead-owned save path can present the same graded report before writing.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func color(for severity: FormValidationSeverity) -> Color {
    switch severity {
    case .error: return .red
    case .warning: return .orange
    case .note: return .blue
    }
  }
}
