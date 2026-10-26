import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// A11Y-04: accessible table/form relationships panel. Read-only presentation of
// header scopes, header associations, row/column spans, field labels and tab
// order, plus the screen-reader-shaped transcript used for qualification.

@MainActor
final class AccessibleRelationshipsPanelModel: ObservableObject {
  struct TableRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let cellLines: [String]
    let issues: [String]
  }

  struct FieldRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
  }

  @Published var tableRows: [TableRow] = []
  @Published var fieldRows: [FieldRow] = []
  @Published var issues: [String] = []
  @Published var transcript = ""
  @Published var summary = "Refresh to read table and form relationships."
  @Published var statusText = "Relationships are read-only descriptions, not a conformance claim."
  @Published var errorText: String?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  func refresh() {
    guard let document, let relationships = document.accessibleRelationships() else {
      errorText = "No document is available."
      return
    }
    summary = relationships.summary
    transcript = relationships.transcript()
    tableRows = relationships.tables.enumerated().map { (index: Int, table: AccessibleTable) in
      var cellLines: [String] = []
      for cell in table.cells {
        var text = cell.isHeader ? "Header " : "Cell "
        text += cell.positionLabel
        if let scope = cell.scope { text += ", scope " + scope }
        if !cell.spanLabel.isEmpty { text += ", spans " + cell.spanLabel }
        if !cell.isHeader {
          text += cell.resolvedHeaderIDs.isEmpty
            ? ", no header association"
            : ", " + String(cell.resolvedHeaderIDs.count) + " header association(s)"
        }
        cellLines.append(text)
      }
      return TableRow(
        id: table.id,
        title: "Table " + String(index + 1) + (table.pageIndex.map { " (page " + String($0 + 1) + ")" } ?? ""),
        detail: String(table.columnCount) + " columns, " + String(table.rowCount) + " rows"
          + (table.summary.map { ", summary: " + $0 } ?? ""),
        cellLines: cellLines,
        issues: table.issues.map(\.message))
    }
    fieldRows = relationships.form.fields.map { field in
      FieldRow(
        id: field.id,
        title: "Field " + String(field.tabOrderIndex + 1) + ": " + field.label,
        detail: field.kind
          + (field.required ? ", required" : "")
          + ", " + (field.labelSource == .tooltip ? "labelled by tooltip" : "field-name fallback")
          + ", " + field.positionLabel
          + (field.widgetCount > 1 ? ", " + String(field.widgetCount) + " widgets" : ""))
    }
    issues = relationships.tables.flatMap { table in
      table.issues.map(\.message)
    } + relationships.form.issues.map(\.message)
    statusText = String(tableRows.count) + " table(s), " + String(fieldRows.count) + " field(s)."
  }

  func copyTranscript() {
    guard !transcript.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(transcript, forType: .string)
    statusText = "Copied the relationship transcript."
  }

  func exportTranscript(to url: URL) {
    do {
      try Data(transcript.utf8).write(to: url)
      statusText = "Exported the relationship transcript."
    } catch {
      errorText = error.localizedDescription
    }
  }
}

@MainActor
final class AccessibleRelationshipsPanelController: NSWindowController {
  let model: AccessibleRelationshipsPanelModel

  init(document: SPDFDocument) {
    let model = AccessibleRelationshipsPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Accessible Tables and Forms"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 840, height: 600)
    panel.contentView = NSHostingView(
      rootView: AccessibleRelationshipsPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the accessible relationships panel")
  }
}

extension SPDFDocument {
  /// A11Y-04: expose table/form relationships and the relationship transcript.
  func showAccessibleRelationshipsPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? AccessibleRelationshipsPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = AccessibleRelationshipsPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowAccessibleRelationshipsPanel: Bool { editSession.currentGraph != nil }

  func accessibleRelationships() -> AccessibleDocumentRelationships? {
    guard let graph = editSession.currentGraph else { return nil }
    return AccessibleDocumentRelationshipsBuilder.build(
      in: graph, pageIDs: editSession.pageIDs)
  }
}

// MARK: - SwiftUI panel

struct AccessibleRelationshipsPanelView: View {
  @ObservedObject var model: AccessibleRelationshipsPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        tablesSection
        Divider()
        formsSection
        Divider()
        transcriptSection
      }
      .padding(16)
    }
    .frame(minWidth: 840, minHeight: 600)
    .accessibilityLabel("Accessible tables and forms relationships")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Accessible Tables and Forms").font(.title3).bold()
        Spacer()
        Button("Refresh") { model.refresh() }
        Button("Copy Transcript") { model.copyTranscript() }
        Button("Export Transcript…") { exportTranscript() }
      }
      Text(model.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
      Text(model.statusText).font(.caption).foregroundStyle(.secondary)
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }

  private var tablesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tables").font(.headline)
      if model.tableRows.isEmpty {
        Text("No tagged tables were found.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.tableRows) { table in
        VStack(alignment: .leading, spacing: 3) {
          Text(table.title).font(.caption.weight(.semibold))
          Text(table.detail).font(.caption2).foregroundStyle(.secondary)
          ForEach(Array(table.cellLines.enumerated()), id: \.offset) { item in
            Text(item.element).font(.caption2)
          }
          ForEach(Array(table.issues.enumerated()), id: \.offset) { item in
            Text("Issue: " + item.element).font(.caption2).foregroundStyle(.orange)
          }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      }
    }
  }

  private var formsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Form fields and tab order").font(.headline)
      if model.fieldRows.isEmpty {
        Text("No form fields were found.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.fieldRows) { field in
        VStack(alignment: .leading, spacing: 2) {
          Text(field.title).font(.caption.weight(.semibold))
          Text(field.detail).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Screen-reader transcript (structure description)").font(.headline)
      Text(model.transcript)
        .font(.caption2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      ForEach(Array(model.issues.enumerated()), id: \.offset) { item in
        Text("Issue: " + item.element).font(.caption2).foregroundStyle(.orange)
      }
      Text("This transcript describes structure relationships; it is not an accessibility-conformance claim.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func exportTranscript() {
    let panel = NSSavePanel()
    panel.title = "Export Relationship Transcript"
    panel.nameFieldStringValue = "accessibility-relationships.txt"
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportTranscript(to: url)
  }
}
