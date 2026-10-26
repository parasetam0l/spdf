import AppKit
import Combine
import Foundation
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AUT-01/AUT-02 panels

/// AUT-01/AUT-02: the advanced search and local full-text index panels. Both
/// are additive: the Lead wires the two SPDFDocument hook methods into the
/// Search menu. No state is added to SPDFDocument.
@MainActor
enum AdvancedSearchFlow {
  static func presentAdvancedSearch(for document: SPDFDocument) {
    let model = AdvancedSearchModel()
    guard model.addCurrentDocument(document) else {
      presentAlert(
        "Advanced Search Unavailable",
        "Open or save a document before searching it.")
      return
    }
    while true {
      let hosting = NSHostingView(rootView: AdvancedSearchView(model: model))
      hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
      let alert = NSAlert()
      alert.messageText = "Advanced Search"
      alert.alertStyle = .informational
      alert.informativeText =
        "Search the current document plus any other PDF files or folders you add. "
          + "Results identify the file, page and context. Encrypted documents that are "
          + "not unlocked are reported as unsearchable, not as no match."
      alert.accessoryView = hosting
      alert.addButton(withTitle: "Search")
      alert.addButton(withTitle: "Add Files or Folders...")
      alert.addButton(withTitle: "Cancel")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        guard let report = run(model) else { continue }
        if !presentAdvancedResults(report) { return }
      } else if response == .alertSecondButtonReturn {
        addSources(to: model)
      } else {
        return
      }
    }
  }

  private static func addSources(to model: AdvancedSearchModel) {
    let panel = NSOpenPanel()
    panel.title = "Add PDF Files or Folders"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.pdf]
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        model.addFolder(url)
      } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
        model.addDocument(
          AdvancedSearchDocument(
            displayName: url.lastPathComponent, url: url, data: data))
      }
    }
  }

  private static func run(_ model: AdvancedSearchModel) -> AdvancedSearchReport? {
    do {
      guard var report = try model.run() else { return nil }
      let needsPassword = report.files.contains {
        $0.status == .passwordRequired && $0.displayName.hasPrefix("Current: ")
      }
      if needsPassword, let password = promptPassword() {
        model.currentPassword = password
        report = try model.run() ?? report
      }
      return report
    } catch {
      presentError("The search could not be completed", error)
      return nil
    }
  }

  private static func presentAdvancedResults(_ report: AdvancedSearchReport) -> Bool {
    let hosting = NSHostingView(rootView: AdvancedSearchResultsView(report: report))
    hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 480)
    let alert = NSAlert()
    alert.messageText = "Advanced Search Results"
    alert.alertStyle = .informational
    alert.informativeText = report.summary
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Search Again")
    alert.addButton(withTitle: "Done")
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: Full-text index

  static func presentSearchIndex(for document: SPDFDocument) {
    let model = SearchIndexModel(indexURL: defaultIndexURL)
    var notice: String?
    while true {
      let hosting = NSHostingView(rootView: SearchIndexView(model: model))
      hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 460)
      let alert = NSAlert()
      alert.messageText = "Local Full-Text Index"
      alert.alertStyle = .informational
      alert.informativeText = notice ?? model.summary
      alert.accessoryView = hosting
      alert.addButton(withTitle: "Search Index")
      alert.addButton(withTitle: "Refresh Index")
      alert.addButton(withTitle: "Manage Locations...")
      alert.addButton(withTitle: "Done")
      let response = alert.runModal()
      switch response {
      case .alertFirstButtonReturn:
        guard let report = model.search() else { continue }
        presentIndexResults(report)
      case .alertSecondButtonReturn:
        do {
          let report = try model.refresh()
          notice = report.summary
        } catch {
          notice = error.localizedDescription
        }
      case .alertThirdButtonReturn:
        presentLocations(model)
        notice = nil
      default:
        return
      }
    }
  }

  private static func presentLocations(_ model: SearchIndexModel) {
    while true {
      let hosting = NSHostingView(rootView: SearchIndexLocationsView(model: model))
      hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 260)
      let alert = NSAlert()
      alert.messageText = "Indexing Locations"
      alert.alertStyle = .informational
      alert.informativeText =
        "Only the folders listed here are scanned, and subfolders are indexed only "
          + "when enabled. Add a specific folder; system folders, the home directory "
          + "itself and the file system root are refused."
      alert.accessoryView = hosting
      alert.addButton(withTitle: "Add Location...")
      alert.addButton(withTitle: "Remove Selected")
      alert.addButton(withTitle: "Back")
      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        let panel = NSOpenPanel()
        panel.title = "Add Indexing Location"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { continue }
        do {
          try model.addLocation(url)
        } catch {
          presentError("The location could not be added", error)
        }
      } else if response == .alertSecondButtonReturn {
        do {
          try model.removeSelectedLocation()
        } catch {
          presentError("The location could not be removed", error)
        }
      } else {
        return
      }
    }
  }

  private static func presentIndexResults(_ report: SearchIndexSearchReport) {
    let hosting = NSHostingView(rootView: SearchIndexResultsView(report: report))
    hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 460)
    let alert = NSAlert()
    alert.messageText = "Index Search Results"
    alert.alertStyle = .informational
    alert.informativeText = report.summary
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  // MARK: Shared helpers

  static var defaultIndexURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("sPDF", isDirectory: true)
      .appendingPathComponent(LocalSearchIndex.fileName)
  }

  private static func promptPassword() -> String? {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = "Document password"
    let alert = NSAlert()
    alert.messageText = "Encrypted Document"
    alert.alertStyle = .informational
    alert.informativeText =
      "This document is encrypted. Enter its open password to search it; the "
        + "password is used for this search only and is not stored."
    alert.accessoryView = field
    alert.addButton(withTitle: "Search")
    alert.addButton(withTitle: "Skip")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue
    field.stringValue = ""
    return value.isEmpty ? nil : value
  }

  private static func presentAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private static func presentError(_ title: String, _ error: Error) {
    presentAlert(title, error.localizedDescription)
  }
}

// MARK: - AUT-01 model

/// The search scope state shown by the options panel.
final class AdvancedSearchModel: ObservableObject {
  @Published var query = ""
  @Published var searchDocumentText = true
  @Published var includeRecognizedOCRText = true
  @Published var includeComments = true
  @Published var includeFormValues = true
  @Published var includeBookmarks = true
  @Published var includeMetadata = true
  @Published var includeSubfolders = true
  @Published var currentPassword: String?
  @Published var documents: [AdvancedSearchDocument] = []
  @Published var folders: [URL] = []
  @Published var lastReport: AdvancedSearchReport?

  func addCurrentDocument(_ document: SPDFDocument) -> Bool {
    let data: Data
    if let snapshot = document.sourceStore.snapshot() {
      data = snapshot.data
    } else if let graph = document.editSession.currentGraph,
      let written = try? PDFWriter.write(graph)
    {
      data = written
    } else {
      return false
    }
    let name = document.fileURL?.lastPathComponent ?? "Untitled.pdf"
    documents.append(
      AdvancedSearchDocument(
        displayName: "Current: \(name)",
        url: document.fileURL ?? URL(fileURLWithPath: "/untitled-current.pdf"),
        data: data, password: currentPassword))
    return true
  }

  func addDocument(_ document: AdvancedSearchDocument) {
    documents.append(document)
  }

  func addFolder(_ url: URL) {
    guard !folders.contains(where: { $0.path == url.path }) else { return }
    folders.append(url)
  }

  var options: AdvancedSearchOptions {
    AdvancedSearchOptions(
      searchDocumentText: searchDocumentText,
      includeRecognizedOCRText: includeRecognizedOCRText,
      includeComments: includeComments,
      includeFormValues: includeFormValues,
      includeBookmarks: includeBookmarks,
      includeMetadata: includeMetadata,
      includeSubfolders: includeSubfolders)
  }

  var scopeSummary: String {
    var parts = documents.count == 1
      ? ["1 document"] : ["\(documents.count) documents"]
    if !folders.isEmpty {
      parts.append("\(folders.count) \(folders.count == 1 ? "folder" : "folders")")
    }
    return parts.joined(separator: ", ")
  }

  func run() throws -> AdvancedSearchReport? {
    guard !documents.isEmpty || !folders.isEmpty else { return nil }
    let options = self.options
    try options.validate()
    var files: [AdvancedSearchFileResult] = []
    var skipped = 0
    if !documents.isEmpty {
      let report = try AdvancedSearch.search(
        query: query, documents: documents, options: options)
      files.append(contentsOf: report.files)
      skipped += report.skippedDocuments
    }
    for folder in folders {
      let report = try AdvancedSearch.search(
        query: query, folder: folder, options: options)
      files.append(contentsOf: report.files)
      skipped += report.skippedDocuments
    }
    let combined = AdvancedSearchReport(
      query: query, files: files, skippedDocuments: skipped)
    lastReport = combined
    return combined
  }
}

// MARK: - AUT-02 model

/// The index page state: locations, refresh state and search results.
final class SearchIndexModel: ObservableObject {
  @Published var index: LocalSearchIndex
  @Published var query = ""
  @Published var selectedLocationPath: String?
  @Published var lastSearch: SearchIndexSearchReport?
  @Published var lastRefresh: SearchIndexRefreshReport?
  @Published var errorMessage: String?

  let indexURL: URL

  init(indexURL: URL) {
    self.indexURL = indexURL
    self.index = (try? LocalSearchIndex.load(from: indexURL)) ?? LocalSearchIndex()
    self.selectedLocationPath = index.locations.first?.path
  }

  var summary: String {
    if let refresh = lastRefresh { return refresh.summary }
    return "\(index.locations.count) \(index.locations.count == 1 ? "location" : "locations"), "
      + "\(index.indexedDocuments) indexed, \(index.protectedDocuments) protected"
  }

  func addLocation(_ url: URL) throws {
    try index.addLocation(path: url.path)
    try save()
    selectedLocationPath = index.locations.last?.path
  }

  func removeSelectedLocation() throws {
    guard let path = selectedLocationPath else {
      throw PDFError(.malformed, "Select an indexing location first")
    }
    try index.removeLocation(path: path)
    try save()
    selectedLocationPath = index.locations.first?.path
  }

  func refresh() throws -> SearchIndexRefreshReport {
    let report = try index.refresh()
    try save()
    lastRefresh = report
    lastSearch = nil
    return report
  }

  func search() -> SearchIndexSearchReport? {
    do {
      let report = try index.search(query)
      lastSearch = report
      errorMessage = nil
      return report
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func save() throws {
    try index.save(to: indexURL)
  }
}

// MARK: - Views

struct AdvancedSearchView: View {
  @ObservedObject var model: AdvancedSearchModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Search text", text: $model.query)
        Text("Scope: " + model.scopeSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Sources").font(.headline)
        Toggle("Document text", isOn: $model.searchDocumentText)
        Toggle("Recognized OCR text", isOn: $model.includeRecognizedOCRText)
        Toggle("Comments", isOn: $model.includeComments)
        Toggle("Form values", isOn: $model.includeFormValues)
        Toggle("Bookmarks", isOn: $model.includeBookmarks)
        Toggle("Metadata", isOn: $model.includeMetadata)
        Toggle("Include subfolders in added folders", isOn: $model.includeSubfolders)
        if !model.folders.isEmpty {
          Text("Folders: " + model.folders.map(\.lastPathComponent).joined(separator: ", "))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(
          "Encrypted documents are searched only when their open password is "
            + "available; otherwise they are reported as unsearchable. A readable document "
            + "with no extractable content is distinct from a document with no match.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 580, minHeight: 420)
  }
}

struct AdvancedSearchResultsView: View {
  let report: AdvancedSearchReport

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(report.summary).font(.caption).foregroundStyle(.secondary)
        ForEach(report.files) { file in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text(file.displayName).font(.subheadline.weight(.medium))
              Spacer()
              Text(file.summary)
                .font(.caption2)
                .foregroundStyle(file.hasMatches ? Color.green : Color.secondary)
            }
            if let detail = file.statusDetail {
              Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(file.hits) { hit in
              HStack(alignment: .top, spacing: 6) {
                Text(hit.pageLabel ?? "Document")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                  Text(hit.source.title).font(.caption2).foregroundStyle(.secondary)
                  Text(hit.context ?? "(matched text withheld by document permissions)")
                    .font(.caption)
                }
              }
            }
          }
          Divider()
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 640, minHeight: 420)
  }
}

struct SearchIndexView: View {
  @ObservedObject var model: SearchIndexModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(model.summary).font(.caption).foregroundStyle(.secondary)
        TextField("Search the index", text: $model.query)
        Text(
          "The index is built only from the folders listed under Manage Locations. "
            + "It stores page text for unprotected documents; protected documents are "
            + "recorded by path, size, hash and status and their plaintext is never stored.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        if let error = model.errorMessage {
          Text(error).font(.caption2).foregroundStyle(.red)
        }
        if let search = model.lastSearch {
          Text(search.summary).font(.caption2).foregroundStyle(.secondary)
        }
        if !model.index.locations.isEmpty {
          Text("Locations").font(.headline)
          ForEach(model.index.locations, id: \.path) { location in
            Text(location.path + (location.includeSubfolders ? " (with subfolders)" : ""))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 600, minHeight: 420)
  }
}

struct SearchIndexLocationsView: View {
  @ObservedObject var model: SearchIndexModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(model.index.locations, id: \.path) { location in
          Button {
            model.selectedLocationPath = location.path
          } label: {
            HStack(spacing: 6) {
              Image(systemName: model.selectedLocationPath == location.path
                ? "largecircle.fill.circle" : "circle")
              VStack(alignment: .leading, spacing: 1) {
                Text(location.path).font(.caption)
                Text("\(model.index.indexedDocuments) indexed")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if model.index.locations.isEmpty {
          Text("No indexing locations yet. Add a folder to start indexing.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(LocalSearchIndex.disclosure)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 520, minHeight: 240)
  }
}

struct SearchIndexResultsView: View {
  let report: SearchIndexSearchReport

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        Text(report.summary).font(.caption).foregroundStyle(.secondary)
        ForEach(report.hits) { hit in
          HStack(alignment: .top, spacing: 6) {
            Text(hit.pageLabel ?? "Document")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
              Text(hit.fileName).font(.caption.weight(.medium))
              Text(hit.source.title).font(.caption2).foregroundStyle(.secondary)
              Text(hit.context).font(.caption)
            }
          }
        }
        if report.hits.isEmpty {
          Text("No index matches. Protected or missing documents are counted above "
            + "instead of being reported as no match.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 640, minHeight: 420)
  }
}

// MARK: - SPDFDocument hooks (no stored state)

extension SPDFDocument {
  /// Hook: Search menu item "Advanced Search...".
  func presentAdvancedSearch() {
    AdvancedSearchFlow.presentAdvancedSearch(for: self)
  }

  /// Hook: Search menu item "Search Index...".
  func presentLocalSearchIndex() {
    AdvancedSearchFlow.presentSearchIndex(for: self)
  }
}
