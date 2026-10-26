import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// FRM-07: collect completed forms and form-data files into one reviewable table.
// The panel only reads sources; conflicts, missing/empty values and duplicate
// submissions stay visible, and CSV/XLSX exports are separate review files.

@MainActor
final class FormResponsesPanelModel: ObservableObject {
  struct SourceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let kindLabel: String
    let detail: String
  }

  struct ColumnRow: Identifiable, Equatable {
    let id: String
    let name: String
    let kinds: String
    let missing: String
    let empty: String
    let isConflict: Bool
  }

  struct CellLine: Identifiable, Equatable {
    let id: String
    let column: String
    let text: String
    let status: FormResponseCellStatus
  }

  struct SubmissionRow: Identifiable, Equatable {
    let id: String
    let name: String
    let lines: [CellLine]
    let duplicateNote: String?
  }

  struct IssueRow: Identifiable, Equatable {
    let id: String
    let kindLabel: String
    let message: String
    let isConflict: Bool
  }

  @Published var sourceRows: [SourceRow] = []
  @Published var columnRows: [ColumnRow] = []
  @Published var submissionRows: [SubmissionRow] = []
  @Published var issueRows: [IssueRow] = []
  @Published var summary = "No forms have been added yet."
  @Published var statusText = "Add completed PDF forms, or FDF/XFDF/JSON form data files."
  @Published var errorText: String?
  @Published var isBusy = false

  private weak var document: SPDFDocument?
  private var sources: [FormResponseSource] = []
  private var table: FormResponseTable?

  init(document: SPDFDocument) {
    self.document = document
    if let current = document.formResponseCurrentSource() {
      sources = [current]
    }
    rebuild()
  }

  func rebuild() {
    table = FormResponseCollection.merge(sources)
    guard let table else { return }
    summary = table.summary
    sourceRows = table.sources.map { source in
      SourceRow(
        id: source.id, name: source.displayName,
        kindLabel: source.kind.rawValue,
        detail: source.pageCount.map { String($0) + " page(s)" }
          ?? String(source.values.count) + " value(s)")
    }
    columnRows = table.columns.map { column in
      ColumnRow(
        id: column.name, name: column.name,
        kinds: column.kinds.isEmpty ? "data" : column.kinds.joined(separator: "/"),
        missing: column.missingSourceNames.isEmpty
          ? "" : "missing in " + column.missingSourceNames.joined(separator: ", "),
        empty: column.emptySourceNames.isEmpty
          ? "" : "empty in " + column.emptySourceNames.joined(separator: ", "),
        isConflict: column.isTypeConflict)
    }
    submissionRows = table.rows.map { row in
      var lines: [CellLine] = []
      for (index, column) in table.columns.enumerated() {
        guard row.cells.indices.contains(index) else { continue }
        let cell = row.cells[index]
        let text: String
        switch cell.status {
        case .present: text = cell.value?.displayText ?? ""
        case .empty: text = "(empty)"
        case .missing: text = "(missing)"
        }
        lines.append(
          CellLine(
            id: row.id + "/" + column.name, column: column.name, text: text,
            status: cell.status))
      }
      let duplicate = row.duplicateOf.flatMap { originalID in
        table.sources.first(where: { $0.id == originalID }).map {
          "Duplicate submission of " + $0.displayName
        }
      }
      return SubmissionRow(
        id: row.id, name: row.displayName, lines: lines, duplicateNote: duplicate)
    }
    issueRows = table.issues.map { issue in
      IssueRow(
        id: issue.kind.rawValue + "/" + (issue.fieldName ?? "") + "/" + (issue.sourceName ?? "")
          + "/" + issue.message,
        kindLabel: issue.kind.rawValue, message: issue.message,
        isConflict: issue.kind == .typeMismatch || issue.kind == .fieldNameConflict)
    }
  }

  func addFiles(_ urls: [URL]) {
    errorText = nil
    var added: [FormResponseSource] = []
    var refusals: [String] = []
    for url in urls {
      do {
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        let extensionName = url.pathExtension.lowercased()
        switch extensionName {
        case "pdf":
          added.append(try FormResponseCollection.readPDFSource(data, displayName: name))
        case "xfdf":
          added.append(
            try FormResponseCollection.readFormDataSource(
              data, format: .xfdf, displayName: name))
        case "fdf":
          added.append(
            try FormResponseCollection.readFormDataSource(
              data, format: .fdf, displayName: name))
        case "json":
          added.append(try FormResponseCollection.readJSONSource(data, displayName: name))
        default:
          refusals.append(name + ": unsupported file type")
        }
      } catch {
        refusals.append(url.lastPathComponent + ": " + error.localizedDescription)
      }
    }
    sources += added
    rebuild()
    let addedText = added.isEmpty
      ? "No source was added."
      : "Added " + String(added.count) + " source(s)."
    statusText = addedText
      + (refusals.isEmpty ? "" : " Refused: " + refusals.joined(separator: "; "))
    if !refusals.isEmpty { errorText = refusals.joined(separator: "\n") }
  }

  func removeSource(_ id: String) {
    sources.removeAll { $0.id == id }
    rebuild()
    statusText = "Removed one source; the file on disk is untouched."
  }

  func removeAllSources() {
    sources.removeAll()
    rebuild()
    statusText = "Cleared the review table; no file on disk was changed."
  }

  func exportCSV(to url: URL) {
    guard let table else { return }
    do {
      try table.exportCSV().write(to: url)
      statusText = "Exported CSV to " + url.lastPathComponent + "."
    } catch {
      errorText = error.localizedDescription
    }
  }

  func exportXLSX(to url: URL) {
    guard let table else { return }
    do {
      try table.exportXLSX().write(to: url)
      statusText = "Exported XLSX to " + url.lastPathComponent + "."
    } catch {
      errorText = error.localizedDescription
    }
  }

  func reloadCurrentDocument() {
    guard let current = document?.formResponseCurrentSource() else { return }
    sources.removeAll { $0.displayName == current.displayName }
    sources.insert(current, at: 0)
    rebuild()
    statusText = "Re-read the current document as a response source."
  }
}

@MainActor
final class FormResponsesPanelController: NSWindowController {
  let model: FormResponsesPanelModel

  init(document: SPDFDocument) {
    let model = FormResponsesPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Form Responses"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 900, height: 640)
    panel.contentView = NSHostingView(rootView: FormResponsesPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the form responses panel")
  }

  func refresh() { model.rebuild() }
}

extension SPDFDocument {
  /// Form > Collect Form Responses…: review values collected from this document
  /// and other completed forms without touching the source files.
  func showFormResponsesPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? FormResponsesPanelController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FormResponsesPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowFormResponsesPanel: Bool { viewer != nil && editSession.currentGraph != nil }

  /// Read the current document as a response source. Read-only.
  func formResponseCurrentSource() -> FormResponseSource? {
    guard let graph = editSession.currentGraph else { return nil }
    let name = fileURL?.lastPathComponent ?? "Current document"
    return try? FormResponseCollection.readGraphSource(
      graph, pageIDs: editSession.pageIDs, displayName: name)
  }
}

// MARK: - SwiftUI panel

struct FormResponsesPanelView: View {
  @ObservedObject var model: FormResponsesPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        sourceSection
        Divider()
        columnsSection
        Divider()
        submissionsSection
        Divider()
        issuesSection
        footer
      }
      .padding(18)
    }
    .frame(minWidth: 900, minHeight: 640)
    .accessibilityLabel("Form responses review table")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Form Responses").font(.title3).bold()
      Text(model.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
      Text(model.statusText).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var sourceSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("Sources").font(.headline)
        Spacer()
        Button("Add Form Files…") { addFiles() }
          .accessibilityLabel("Add completed forms or form data files")
        Button("Re-read Current Document") { model.reloadCurrentDocument() }
        Button("Clear Table") { model.removeAllSources() }
          .disabled(model.sourceRows.isEmpty)
        Button("Export CSV…") { exportCSV() }
          .disabled(model.sourceRows.isEmpty)
        Button("Export XLSX…") { exportXLSX() }
          .disabled(model.sourceRows.isEmpty)
      }
      if model.sourceRows.isEmpty {
        Text("No sources yet. Add PDFs or FDF/XFDF/JSON data files exported from completed forms.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.sourceRows) { row in
        HStack(spacing: 8) {
          Text(row.name).font(.caption).bold()
          Text(row.kindLabel).font(.caption2).foregroundStyle(.secondary)
          Text(row.detail).font(.caption2).foregroundStyle(.secondary)
          Spacer()
          Button("Remove") { model.removeSource(row.id) }
            .buttonStyle(.link)
            .accessibilityLabel("Remove source " + row.name)
        }
      }
      Text("Source files are only read; collection never modifies them.")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var columnsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Fields across sources").font(.headline)
      if model.columnRows.isEmpty {
        Text("No fields to show.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.columnRows) { column in
        HStack(alignment: .top, spacing: 8) {
          Text(column.name).font(.caption).bold().frame(width: 180, alignment: .leading)
          Text(column.kinds).font(.caption2).foregroundStyle(.secondary)
          Spacer()
          if !column.missing.isEmpty {
            Text(column.missing).font(.caption2).foregroundStyle(.orange)
          }
          if !column.empty.isEmpty {
            Text(column.empty).font(.caption2).foregroundStyle(.yellow)
          }
          if column.isConflict {
            Text("name conflict").font(.caption2).foregroundStyle(.red)
          }
        }
      }
    }
  }

  private var submissionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Submissions").font(.headline)
      ForEach(model.submissionRows) { row in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(row.name).font(.caption).bold()
            if let note = row.duplicateNote {
              Text(note).font(.caption2).foregroundStyle(.purple)
            }
          }
          ForEach(row.lines) { line in
            HStack(spacing: 6) {
              Text(line.column).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
              Text(line.text)
                .font(.caption2)
                .foregroundStyle(color(for: line.status))
            }
          }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      }
    }
  }

  private var issuesSection: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Issues").font(.headline)
      if model.issueRows.isEmpty {
        Text("No conflicts, missing values or duplicates were found.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.issueRows) { issue in
        HStack(alignment: .top, spacing: 8) {
          Text(issue.kindLabel).font(.caption2)
            .foregroundStyle(issue.isConflict ? Color.red : Color.orange)
            .frame(width: 170, alignment: .leading)
          Text(issue.message).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        "Collection is read-only: values are copied into this table, conflicts/missing values/"
          + "duplicates are shown, and original form files are never modified.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func color(for status: FormResponseCellStatus) -> Color {
    switch status {
    case .present: return .primary
    case .empty: return .yellow
    case .missing: return .orange
    }
  }

  private func addFiles() {
    let panel = NSOpenPanel()
    panel.title = "Add Completed Forms or Form Data"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    var types: [UTType] = [.pdf, .json]
    for extensionName in ["xfdf", "fdf"] {
      if let type = UTType(filenameExtension: extensionName) { types.append(type) }
    }
    types.append(.data)
    panel.allowedContentTypes = types
    guard panel.runModal() == .OK else { return }
    model.addFiles(panel.urls)
  }

  private func exportCSV() {
    let panel = NSSavePanel()
    panel.title = "Export Responses as CSV"
    panel.nameFieldStringValue = "form-responses.csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportCSV(to: url)
  }

  private func exportXLSX() {
    let panel = NSSavePanel()
    panel.title = "Export Responses as XLSX"
    panel.nameFieldStringValue = "form-responses.xlsx"
    if let type = UTType(filenameExtension: "xlsx") {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportXLSX(to: url)
  }
}
