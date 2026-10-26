import AppKit
import DocumentSession
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// SPC-01 App surface: browse, preview, extract, add/remove/replace portfolio
/// components and write a new portfolio derivative. Authoring is applied through
/// one undoable document transaction; component bytes are never re-encoded.
@MainActor
final class PortfolioPanelModel: ObservableObject {
  @Published private(set) var inventory: PortfolioInventory?
  @Published private(set) var staged: [PortfolioComponentEditCommand.Operation] = []
  @Published var title = ""
  @Published var componentFolderPath = ""
  @Published var selectedComponentName: String?
  @Published private(set) var previewImage: NSImage?
  @Published private(set) var previewText: String?
  @Published private(set) var statusText: String?
  @Published private(set) var errorText: String?

  private let graphProvider: @MainActor () -> PDFGraph?
  private let applyCommands: @MainActor ([any PDFEditCommand]) -> String?
  private let bytesProvider: @MainActor () -> Data?
  private let saveProvider: @MainActor (Data, String) -> Bool

  init(
    graphProvider: @escaping @MainActor () -> PDFGraph?,
    applyCommands: @escaping @MainActor ([any PDFEditCommand]) -> String?,
    bytesProvider: @escaping @MainActor () -> Data?,
    saveProvider: @escaping @MainActor (Data, String) -> Bool
  ) {
    self.graphProvider = graphProvider
    self.applyCommands = applyCommands
    self.bytesProvider = bytesProvider
    self.saveProvider = saveProvider
  }

  var components: [PortfolioComponent] {
    (inventory?.components ?? []).sorted { $0.fullName < $1.fullName }
  }

  var columns: [PortfolioColumn] { inventory?.columns ?? PortfolioReader.defaultColumns }
  var isPortfolio: Bool { inventory?.hasCollection ?? false }
  var canApply: Bool { !staged.isEmpty && graphProvider() != nil }
  var canExtract: Bool { selectedComponentName != nil }
  var canStageRemove: Bool { selectedComponentName != nil }

  func reload() {
    guard let graph = graphProvider() else {
      inventory = nil
      errorText = "No editable PDF graph is available."
      return
    }
    do {
      let read = try PortfolioReader.read(in: graph)
      inventory = read
      title = read.title ?? ""
      if selectedComponentName == nil {
        selectedComponentName = read.components.first?.name
      }
      errorText = nil
      updatePreview()
      statusText = read.hasCollection
        ? "Portfolio loaded: " + String(read.components.count) + " component(s)."
        : "This PDF is not a portfolio yet. Stage components to author one."
    } catch {
      inventory = nil
      errorText = error.localizedDescription
    }
  }

  func chooseAddFiles() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = "Add component files. Bytes are preserved exactly; folder grouping is "
      + "declared by the path in the name tree."
    guard panel.runModal() == .OK else { return }
    let folders = componentFolderPath
      .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    var added = 0
    for url in panel.urls {
      do {
        let data = try Data(contentsOf: url)
        let component = try PortfolioAuthoring.makeComponent(
          fileName: url.lastPathComponent, folderPath: folders, data: data,
          mimeType: mimeType(for: url))
        guard !components.contains(where: { $0.name == component.name }),
          !staged.contains(where: { $0.addedName == component.name })
        else {
          errorText = "A component named " + component.name + " already exists."
          continue
        }
        staged.append(.add(component))
        added += 1
      } catch {
        errorText = error.localizedDescription
      }
    }
    if added > 0 {
      statusText = "Staged " + String(added) + " component addition(s). Apply to make them undoable."
      errorText = nil
    }
  }

  func chooseReplaceBytes() {
    guard let selected = selectedComponentName,
      let component = components.first(where: { $0.name == selected })
    else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Replace only this component's bytes. Its name and every other "
      + "component's bytes stay unchanged."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= PortfolioAuthoring.maximumComponentBytes else {
        errorText = "The replacement exceeds the supported component size limit."
        return
      }
      staged.append(.replace(name: component.name, data: data))
      statusText = "Staged byte replacement for " + component.fullName + "."
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }

  func stageRemoveSelected() {
    guard let selected = selectedComponentName,
      let component = components.first(where: { $0.name == selected })
    else { return }
    if let index = staged.firstIndex(where: { $0.removedName == component.name }) {
      staged.remove(at: index)
      statusText = "Unstaged removal of " + component.fullName + "."
      return
    }
    staged.append(.remove(name: component.name))
    statusText = "Staged removal of " + component.fullName + "."
  }

  func applyStagedChanges() {
    guard !staged.isEmpty else {
      errorText = "No staged portfolio changes to apply."
      return
    }
    let commands: [any PDFEditCommand] = staged.map {
      PortfolioComponentEditCommand(operation: $0)
    }
    if let error = applyCommands(commands) {
      errorText = error
      return
    }
    staged = []
    errorText = nil
    statusText = "Applied portfolio changes in one undoable transaction."
    reload()
  }

  func extractSelected() {
    guard let selected = selectedComponentName,
      let component = components.first(where: { $0.name == selected })
    else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = component.fileName
    panel.canCreateDirectories = true
    panel.message = "Extract the exact embedded component bytes."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try component.data.write(to: url, options: .atomic)
      statusText = "Extracted " + component.fullName + " (" + String(component.byteCount)
        + " bytes)."
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }

  func savePortfolioDerivative() {
    guard let data = bytesProvider() else {
      errorText = "The current portfolio graph could not be serialized."
      return
    }
    if saveProvider(data, title.isEmpty ? "portfolio" : title) {
      statusText = "Wrote a new portfolio derivative; the open source was not modified."
      errorText = nil
    } else {
      errorText = "The portfolio derivative was not written."
    }
  }

  func createPortfolioFromFiles() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = "Create a new PDF portfolio from component files. No open document is changed."
    guard panel.runModal() == .OK else { return }
    do {
      let folders = componentFolderPath
        .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
      var components: [PortfolioComponent] = []
      for url in panel.urls {
        let data = try Data(contentsOf: url)
        components.append(
          try PortfolioAuthoring.makeComponent(
            fileName: url.lastPathComponent, folderPath: folders, data: data,
            mimeType: mimeType(for: url)))
      }
      guard !components.isEmpty else { return }
      let data = try PortfolioAuthoring.create(
        components: components, title: title.isEmpty ? nil : title,
        columns: PortfolioReader.defaultColumns)
      if saveProvider(data, title.isEmpty ? "portfolio" : title) {
        statusText = "Created a new PDF portfolio with " + String(components.count)
          + " component(s)."
        errorText = nil
      }
    } catch {
      errorText = error.localizedDescription
    }
  }

  func updatePreview() {
    previewImage = nil
    previewText = nil
    guard let selected = selectedComponentName,
      let component = components.first(where: { $0.name == selected })
    else { return }
    if component.data.starts(with: Data("%PDF".utf8)) {
      if let document = PDFDocument(data: component.data), let page = document.page(at: 0) {
        previewImage = page.thumbnail(of: CGSize(width: 360, height: 480), for: .cropBox)
        previewText = "PDF preview · " + String(document.pageCount) + " page(s)"
      } else {
        previewText = "The component has a PDF header but could not be previewed."
      }
      return
    }
    if let image = NSImage(data: component.data) {
      previewImage = image
      previewText = "Image preview"
      return
    }
    if let text = String(data: component.data.prefix(4_000), encoding: .utf8) {
      previewText = String(text.prefix(2_000))
    } else {
      previewText = "No inline preview for this component type; extract or replace bytes."
    }
  }

  private func mimeType(for url: URL) -> String? {
    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
  }
}

/// One undoable portfolio authoring operation. Validation is re-run inside the
/// document transaction so a stale panel cannot mutate an incompatible graph.
struct PortfolioComponentEditCommand: PDFEditCommand, Sendable {
  enum Operation: Sendable, Equatable {
    case add(PortfolioComponent)
    case remove(name: String)
    case replace(name: String, data: Data)

    var addedName: String? {
      if case .add(let component) = self { return component.name }
      return nil
    }

    var removedName: String? {
      if case .remove(let name) = self { return name }
      return nil
    }
  }

  let operation: Operation

  var name: String { "Edit PDF Portfolio" }
  func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  func validate(in graph: PDFGraph) throws {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary? = graph.objects[rootID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    switch operation {
    case .add(let component):
      _ = try PortfolioAuthoring.add(component, to: graph)
    case .remove(let name):
      _ = try PortfolioAuthoring.removeComponent(named: name, from: graph)
    case .replace(let name, let data):
      _ = try PortfolioAuthoring.replaceBytes(named: name, with: data, in: graph)
    }
  }

  func apply(to graph: PDFGraph) throws -> PDFGraph {
    switch operation {
    case .add(let component):
      return try PortfolioAuthoring.add(component, to: graph)
    case .remove(let name):
      return try PortfolioAuthoring.removeComponent(named: name, from: graph)
    case .replace(let name, let data):
      return try PortfolioAuthoring.replaceBytes(named: name, with: data, in: graph)
    }
  }
}

/// SPC-01 panel: component browsing/preview/extract/add/remove/replace and a
/// new portfolio derivative. Editing is transactional; bytes are exact.
struct PortfolioPanel: View {
  @ObservedObject var model: PortfolioPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("PDF Portfolio").font(.headline)
        Spacer()
        Button("Refresh") { model.reload() }
      }
      Text(
        "Browse, preview, extract and author portfolio components. Add/remove/replace "
          + "operations apply as one undoable transaction; component bytes are never "
          + "re-encoded. Create/Save Portfolio writes a new derivative and never overwrites "
          + "the open source."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        TextField("Portfolio title", text: $model.title).frame(width: 260)
        TextField("New component folder path (optional, / separated)", text: $model.componentFolderPath)
          .frame(width: 320)
      }
      HStack {
        Button("Add Files…") { model.chooseAddFiles() }
        Button("Extract…") { model.extractSelected() }
          .disabled(!model.canExtract)
        Button("Replace Bytes…") { model.chooseReplaceBytes() }
          .disabled(!model.canExtract)
        Button("Stage Remove") { model.stageRemoveSelected() }
          .disabled(!model.canStageRemove)
        Button("Apply Staged Changes") { model.applyStagedChanges() }
          .disabled(!model.canApply)
        Button("Save Portfolio Derivative…") { model.savePortfolioDerivative() }
        Button("Create Portfolio from Files…") { model.createPortfolioFromFiles() }
      }
      if let inventory = model.inventory {
        HStack(spacing: 12) {
          Text("Collection: " + (inventory.hasCollection ? "yes" : "no"))
          Text("Components: " + String(inventory.components.count))
          Text("Folders: " + String(inventory.folderPaths.count))
          Text("Bytes: " + String(inventory.totalByteCount))
        }
        .font(.caption)
      }
      if !model.columns.isEmpty {
        Text(
          "Columns: " + model.columns.map { $0.title + " (" + $0.subtype + ")" }
            .joined(separator: ", ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      HSplitView {
        List(selection: $model.selectedComponentName) {
          ForEach(model.components, id: \.name) { component in
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(component.fullName).font(.body)
                Spacer()
                Text(String(component.byteCount) + " B").font(.caption.monospaced())
              }
              HStack(spacing: 8) {
                if !component.folderPath.isEmpty {
                  Text("folder: " + component.folderPath.joined(separator: " / "))
                }
                if let mime = component.mimeType { Text(mime) }
                if let description = component.description { Text(description) }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            .tag(component.name)
          }
        }
        .frame(minWidth: 420)
        previewPane
          .frame(minWidth: 280)
      }
      if !model.staged.isEmpty {
        Text("Staged changes").font(.subheadline.weight(.semibold))
        ForEach(Array(model.staged.enumerated()), id: \.offset) { _, operation in
          Text(operationDescription(operation)).font(.caption.monospaced())
        }
      }
      if let status = model.statusText {
        Text(status).font(.caption).foregroundStyle(.green)
      }
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Text(PortfolioBoundary.declaredProfile)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(PortfolioBoundary.editStatement + " " + PortfolioBoundary.independentReaderStatement)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(minWidth: 760, minHeight: 560)
    .onAppear { model.reload() }
    .onChange(of: model.selectedComponentName) { _, _ in model.updatePreview() }
  }

  @ViewBuilder private var previewPane: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Preview").font(.subheadline.weight(.semibold))
      if let image = model.previewImage {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 420)
      } else if let text = model.previewText {
        ScrollView {
          Text(text).font(.caption.monospaced()).textSelection(.enabled)
        }
      } else {
        Text("Select a component to preview.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func operationDescription(_ operation: PortfolioComponentEditCommand.Operation) -> String {
    switch operation {
    case .add(let component): return "+ add " + component.fullName
    case .remove(let name): return "- remove " + name
    case .replace(let name, let data): return "~ replace bytes " + name + " (" + String(data.count) + " B)"
    }
  }
}

extension SPDFDocument {
  var canShowPortfolioPanel: Bool {
    editSession.currentGraph != nil || sourceStore.snapshot()?.data != nil
  }

  /// Hook: File/Tools > PDF Portfolio…. The panel never mutates page content.
  @MainActor
  func portfolioPanelModel() -> PortfolioPanelModel {
    PortfolioPanelModel(
      graphProvider: { [weak self] in
        guard let self else { return nil }
        if let graph = self.editSession.currentGraph { return graph }
        guard let data = self.sourceStore.snapshot()?.data else { return nil }
        return (try? PDFParser.parse(
          data, limits: SPDFDocumentResourcePolicy.parsingLimits))?.graph
      },
      applyCommands: { [weak self] commands in
        guard let self else { return "The document is closed." }
        return self.applyPortfolioCommands(commands)
      },
      bytesProvider: { [weak self] in
        guard let self else { return nil }
        if let data = try? self.editSession.bytesForSave() { return data }
        return self.sourceStore.snapshot()?.data
      },
      saveProvider: { [weak self] data, suggestedName in
        guard let self else { return false }
        return self.savePortfolioDerivative(data, suggestedName: suggestedName)
      })
  }

  /// Hook: call from the PDF Portfolio menu item.
  @MainActor
  func presentPortfolioPanel() {
    let model = portfolioPanelModel()
    model.reload()
    let hosting = NSHostingView(rootView: PortfolioPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 620)
    let alert = NSAlert()
    alert.messageText = "PDF Portfolio"
    alert.alertStyle = .informational
    alert.informativeText =
      "Components remain ordinary embedded files with exact bytes. Authoring is one "
      + "undoable transaction; the portfolio derivative is written to a new file."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }

  @MainActor
  private func applyPortfolioCommands(_ commands: [any PDFEditCommand]) -> String? {
    guard canEditContent else {
      return contentEditingRestriction?.message ?? "Portfolio editing is unavailable."
    }
    guard let undoManager else { return "Undo is unavailable for this document." }
    let revision = editSession.documentRevision
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      return error.localizedDescription
    }
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performPortfolioUndo(registeredRevision: revision)
    }
    undoManager.setActionName("Edit PDF Portfolio")
    undoManager.endUndoGrouping()
    return nil
  }

  private func performPortfolioUndo(registeredRevision: UInt64?) {
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performPortfolioRedo(registeredRevision: revision)
    }
    undoManager?.setActionName("Edit PDF Portfolio")
  }

  private func performPortfolioRedo(registeredRevision: UInt64?) {
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performPortfolioUndo(registeredRevision: revision)
    }
    undoManager?.setActionName("Edit PDF Portfolio")
  }

  @MainActor
  private func savePortfolioDerivative(_ data: Data, suggestedName: String) -> Bool {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    let base = fileURL?.deletingPathExtension().lastPathComponent
      ?? (suggestedName.isEmpty ? "Portfolio" : suggestedName)
    panel.nameFieldStringValue = base + "-portfolio.pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    do {
      try DerivativeOutputPolicy.validateDestination(url, source: fileURL)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      presentError(error)
      return false
    }
  }
}
