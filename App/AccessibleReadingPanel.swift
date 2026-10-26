import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// A11Y-07: the accessible-reading panel. It shows the structure-derived (or
// explicitly geometric) reading order, a high-contrast reading view, the
// low-contrast text findings from owned text-run color state, and a
// VoiceOver-oriented navigation script that can be copied or exported for a
// manual screen-reader check. The panel is read-only: it never edits the
// document and never claims accessibility conformance.

@MainActor
final class AccessibleReadingPanelModel: ObservableObject {
  struct Row: Identifiable, Equatable {
    let id: Int
    let role: String
    let text: String
    let pageLabel: String?
    let generatedOCR: Bool
  }

  @Published var rows: [Row] = []
  @Published var summary = "Reading order has not been analyzed."
  @Published var language: String?
  @Published var limitations: [String] = []
  @Published var structureIssues: [String] = []
  @Published var contrastFindings: [String] = []
  @Published var contrastSummary = "High-contrast analysis has not run."
  @Published var highContrastReading = true
  @Published var errorText: String?
  private weak var document: SPDFDocument?
  private var model: AccessibleReadingModel?

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  func refresh() {
    guard let document else { return }
    guard let graph = document.editSession.currentGraph else {
      errorText = "No document content is available."
      return
    }
    let pageIDs = document.editSession.pageIDs
    do {
      let model = try AccessibleReadingBuilder.build(in: graph, pageIDs: pageIDs)
      let contrast = try HighContrastAccess.audit(in: graph, pageIDs: pageIDs)
      self.model = model
      errorText = nil
      summary = model.summary
      language = model.language
      limitations = model.limitations
      structureIssues = model.structureIssueDescriptions
      rows = model.items.filter { !$0.isEmpty }.enumerated().map { index, item in
        Row(
          id: index,
          role: item.spokenDescription.split(separator: ",").first.map(String.init) ?? item.role.spokenName,
          text: item.text,
          pageLabel: item.pageIndex.map { "p" + String($0 + 1) },
          generatedOCR: item.isGeneratedOCR)
      }
      contrastFindings = contrast.findings.prefix(20).map(\.description)
      contrastSummary =
        "High contrast: " + String(contrast.failureCount) + " failure(s), "
        + String(contrast.warningCount) + " warning(s); "
        + String(contrast.checkedRunCount) + " text run(s) checked."
    } catch {
      errorText = error.localizedDescription
    }
  }

  var canExport: Bool { model != nil }

  func exportReadingText() {
    guard let model else { return }
    let text = model.reflowedText(width: 80)
    if let url = Self.savePanel(
      defaultName: "Accessible Reading.txt",
      message: "Export the reflowed accessible reading text") {
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        errorText = error.localizedDescription
      }
    }
  }

  func exportNavigationScript() {
    guard let model else { return }
    let text = model.voiceOverNavigationScript().joined(separator: "\n")
    if let url = Self.savePanel(
      defaultName: "VoiceOver Navigation Script.txt",
      message: "Export the manual VoiceOver navigation checklist") {
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        errorText = error.localizedDescription
      }
    }
  }

  func copyNavigationScript() {
    guard let model else { return }
    let text = model.voiceOverNavigationScript().joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private static func savePanel(defaultName: String, message: String) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    panel.message = message
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    return panel.runModal() == .OK ? panel.url : nil
  }
}

@MainActor
final class AccessibleReadingPanelController: NSWindowController {
  let model: AccessibleReadingPanelModel

  init(document: SPDFDocument) {
    let model = AccessibleReadingPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Accessible Reading"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 760, height: 520)
    panel.contentView = NSHostingView(rootView: AccessibleReadingPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the accessible reading panel")
  }
}

struct AccessibleReadingPanelView: View {
  @ObservedObject var model: AccessibleReadingPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      HStack(alignment: .top, spacing: 0) {
        readingList
        Divider()
        findings
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Accessible reading")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Accessible Reading").font(.headline)
        Spacer()
        if let language = model.language {
          Text(language).font(.caption).foregroundStyle(.secondary)
        }
        Button {
          model.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Re-analyze the current document")
        .accessibilityLabel("Refresh accessible reading analysis")
      }
      Text(model.summary).font(.caption).foregroundStyle(.secondary)
      if let error = model.errorText {
        Label {
          Text(error).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption).foregroundStyle(.red)
      }
      HStack(spacing: 12) {
        Button("Export Reading Text…") { model.exportReadingText() }
          .disabled(!model.canExport)
        Button("Export Navigation Script…") { model.exportNavigationScript() }
          .disabled(!model.canExport)
        Button("Copy Navigation Script") { model.copyNavigationScript() }
          .disabled(!model.canExport)
        Spacer()
        Toggle("High contrast reading", isOn: $model.highContrastReading)
          .toggleStyle(.checkbox)
          .accessibilityHint("Renders this panel with maximum text/background contrast")
      }
      .font(.caption)
    }
    .padding(12)
    .background(.bar)
  }

  private var readingList: some View {
    List {
      Section("Reading Order") {
        ForEach(model.rows) { row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.role)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .frame(width: 86, alignment: .leading)
              .accessibilityHidden(true)
            Text(row.text.isEmpty ? "(no text)" : row.text)
              .font(.body)
              .foregroundStyle(model.highContrastReading ? .primary : .secondary)
              .textSelection(.enabled)
            Spacer()
            if row.generatedOCR {
              Text("OCR")
                .font(.caption2).foregroundStyle(.orange)
                .help("Generated searchable text outside the structure tree")
            }
            if let page = row.pageLabel {
              Text(page).font(.caption2).foregroundStyle(.tertiary)
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(row.role + (row.pageLabel.map { ", " + $0 } ?? "") + ": " + row.text)
        }
      }
    }
    .listStyle(.inset)
    .frame(minWidth: 420)
  }

  private var findings: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        sectionTitle("High Contrast")
        Text(model.contrastSummary).font(.caption)
        ForEach(model.contrastFindings, id: \.self) { finding in
          Text(finding).font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.contrastFindings.isEmpty {
          Text("No low-contrast body text was found in the owned text runs.")
            .font(.caption2).foregroundStyle(.secondary)
        }
        sectionTitle("Limitations")
        ForEach(model.limitations, id: \.self) { limitation in
          Text(limitation).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.limitations.isEmpty {
          Text("None recorded.").font(.caption2).foregroundStyle(.secondary)
        }
        if !model.structureIssues.isEmpty {
          sectionTitle("Structure Issues")
          ForEach(model.structureIssues.prefix(20), id: \.self) { issue in
            Text(issue).font(.caption2).foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(12)
      .frame(minWidth: 300, maxWidth: 380, alignment: .leading)
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
  /// A11Y-07: open the read-only accessible reading panel.
  func showAccessibleReadingPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? AccessibleReadingPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = AccessibleReadingPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowAccessibleReadingPanel: Bool { editSession.currentGraph != nil }

  func accessibleReadingModel() -> AccessibleReadingModel? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? AccessibleReadingBuilder.build(in: graph, pageIDs: editSession.pageIDs)
  }

  func accessibleHighContrastReport() -> HighContrastReport? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? HighContrastAccess.audit(in: graph, pageIDs: editSession.pageIDs)
  }
}
