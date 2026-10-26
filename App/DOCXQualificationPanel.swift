import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// EXP-01: the DOCX reconstruction qualification panel. It runs the owned
// PDF-to-DOCX reconstruction for one document class and shows the four
// separately scored dimensions with their measurement status. Rendered layout
// is labelled as a local proxy; the panel states that the intended Office
// application was not launched and keeps that limitation attached to any
// exported report.

@MainActor
final class DOCXQualificationPanelModel: ObservableObject {
  struct DimensionRow: Identifiable, Equatable {
    let id: String
    let name: String
    let score: String
    let status: String
    let detail: String
  }

  @Published var selectedClass: DOCXDocumentClass = .baselineProse
  @Published var rows: [DimensionRow] = []
  @Published var findings: [String] = []
  @Published var limitations: [String] = []
  @Published var summary = "Run the qualification to score this document."
  @Published var errorText: String?
  @Published var overallScore: String?
  private weak var document: SPDFDocument?
  private var result: DOCXQualificationResult?

  init(document: SPDFDocument) {
    self.document = document
  }

  var canRun: Bool { document?.editSession.currentGraph != nil }

  func run() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "No document content is available."
      return
    }
    do {
      let result = try DOCXQualification.qualify(
        documentClass: selectedClass, in: graph, pageIDs: document.editSession.pageIDs)
      self.result = result
      errorText = nil
      summary =
        result.documentClass.displayName + ": " + String(result.blockCount) + " block(s), "
        + String(result.tableCount) + " table(s), " + String(result.listItemCount)
        + " list item(s); pages " + String(result.pageCount) + "."
      rows = result.dimensionScores.map { score in
        DimensionRow(
          id: score.dimension.rawValue,
          name: score.dimension.displayName,
          score: score.displayScore,
          status: score.status.displayName,
          detail: score.detail)
      }
      findings = result.findings
      limitations = result.attachedLimitations
      overallScore = result.overallMeasuredScore.map {
        "Overall measured score (excluding not-executed dimensions): " + String(format: "%.2f", $0)
      }
    } catch {
      errorText = error.localizedDescription
    }
  }

  func exportMarkdown() {
    guard let result else { return }
    export(
      content: DOCXQualification.markdownReport([result]),
      defaultName: "DOCX Qualification.md", contentType: .plainText)
  }

  func exportJSON() {
    guard let result else { return }
    export(
      content: result.json(), defaultName: "DOCX Qualification.json",
      contentType: .json)
  }

  private func export(content: String, defaultName: String, contentType: UTType) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    panel.message = "Export the qualification scorecard with its attached limitations"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [contentType]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try content.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      errorText = error.localizedDescription
    }
  }
}

@MainActor
final class DOCXQualificationPanelController: NSWindowController {
  let model: DOCXQualificationPanelModel

  init(document: SPDFDocument) {
    let model = DOCXQualificationPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "DOCX Reconstruction Qualification"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 820, height: 560)
    panel.contentView = NSHostingView(rootView: DOCXQualificationPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the DOCX qualification panel")
  }
}

struct DOCXQualificationPanelView: View {
  @ObservedObject var model: DOCXQualificationPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      HStack(alignment: .top, spacing: 0) {
        scorecard
        Divider()
        notes
      }
    }
    .frame(minWidth: 820, minHeight: 560)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("DOCX reconstruction qualification")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("DOCX Reconstruction Qualification").font(.headline)
        Spacer()
        Picker("Document class", selection: $model.selectedClass) {
          ForEach(DOCXDocumentClass.allCases, id: \.self) { documentClass in
            Text(documentClass.displayName).tag(documentClass)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
        Button("Run Qualification") { model.run() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canRun)
        Button("Export Markdown…") { model.exportMarkdown() }
          .disabled(model.rows.isEmpty)
        Button("Export JSON…") { model.exportJSON() }
          .disabled(model.rows.isEmpty)
      }
      Text(model.summary).font(.caption).foregroundStyle(.secondary)
      if let overall = model.overallScore {
        Text(overall).font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.errorText {
        Label {
          Text(error).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption).foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(.bar)
  }

  private var scorecard: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if model.rows.isEmpty {
          ContentUnavailableView(
            "No Scorecard Yet", systemImage: "tablecells",
            description: Text("Choose a document class and run the qualification."))
            .frame(minHeight: 320)
        } else {
          ForEach(model.rows) { row in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(row.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(row.score).font(.subheadline.monospaced())
              }
              Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Text(row.status.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(row.status.contains("not executed") ? .red : .secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      .padding(12)
    }
    .frame(minWidth: 440, maxWidth: 540)
  }

  private var notes: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if !model.findings.isEmpty {
          sectionTitle("Findings")
          ForEach(model.findings, id: \.self) { finding in
            Text(finding).font(.caption2).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        sectionTitle("Limitations Attached to Outputs")
        ForEach(model.limitations, id: \.self) { limitation in
          Text(limitation).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.limitations.isEmpty {
          Text("Run the qualification to see the attached limitations.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .frame(minWidth: 320, maxWidth: 420, alignment: .leading)
    }
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .semibold))
      .tracking(0.7)
      .foregroundStyle(.secondary)
  }
}

extension SPDFDocument {
  /// EXP-01: open the DOCX reconstruction qualification panel.
  func showDOCXQualificationPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? DOCXQualificationPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = DOCXQualificationPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowDOCXQualificationPanel: Bool { editSession.currentGraph != nil }

  func docxQualification(
    for documentClass: DOCXDocumentClass
  ) -> DOCXQualificationResult? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? DOCXQualification.qualify(
      documentClass: documentClass, in: graph, pageIDs: editSession.pageIDs)
  }
}
