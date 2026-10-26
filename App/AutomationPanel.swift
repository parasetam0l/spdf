import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

// AUT-05/AUT-06: the automation panel. It shows the declared profile (the same
// catalog used by the CLI, Shortcuts and AppleScript), a copyable CLI command,
// and an explicit watched-folder setup. There is no default watch location: the
// user selects folders and a recipe, and failures stay visible.

@MainActor
final class AutomationPanelModel: ObservableObject {
  struct OperationRow: Identifiable, Equatable {
    let id: String
    let name: String
    let usage: String
    let kind: String
    let restrictions: [String]
  }

  struct ResultRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let failed: Bool
  }

  @Published var operationRows: [OperationRow] = []
  @Published var restrictions: [String] = []
  @Published var cliPreview = ""
  @Published var watchedFolders: [URL] = []
  @Published var outputFolder: URL?
  @Published var recipeName = "Flatten forms"
  @Published var recipeOperation = "flatten-forms"
  @Published var recipeOptionPages = ""
  @Published var settleInterval = 30.0
  @Published var isWatching = false
  @Published var statusText = "Select folders and a recipe to start watching."
  @Published var summary = "Automation exposes the declared profile only."
  @Published var errorText: String?
  @Published var resultRows: [ResultRow] = []

  private weak var document: SPDFDocument?
  private var engine: WatchedFolderEngine?
  private var timer: Timer?

  init(document: SPDFDocument) {
    self.document = document
    reloadProfile()
  }

  func reloadProfile() {
    operationRows = AutomationProfile.operations.map { operation in
      OperationRow(
        id: operation.name, name: operation.name, usage: operation.usage,
        kind: operation.kind.rawValue, restrictions: operation.restrictions)
    }
    restrictions = AutomationProfile.restrictions
    summary = "Profile " + AutomationProfile.identifier + " — "
      + String(AutomationProfile.operations.count) + " operations, exit codes "
      + AutomationProfile.exitCodes.map { String($0.code) }.joined(separator: "/") + "."
    refreshCLIPreview()
  }

  func refreshCLIPreview() {
    let sample = outputFolder?.path ?? "<output.pdf>"
    cliPreview = "spdf-automation " + recipeOperation + " <input.pdf> --output "
      + sample + (recipeOptionPages.isEmpty ? "" : " --pages " + recipeOptionPages)
  }

  func copyCLIPreview() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(cliPreview, forType: .string)
    statusText = "Copied the CLI command."
  }

  func addWatchedFolder(_ url: URL) {
    guard !watchedFolders.contains(url) else { return }
    watchedFolders.append(url)
    statusText = "Added " + url.lastPathComponent + "; the folder is only watched after "
      + "you start."
  }

  func removeWatchedFolder(_ url: URL) {
    watchedFolders.removeAll { $0 == url }
  }

  func startWatching() {
    guard let outputFolder else {
      errorText = "Select an output folder first."
      return
    }
    do {
      var options: [String: String] = [:]
      if !recipeOptionPages.isEmpty { options["--pages"] = recipeOptionPages }
      let recipe = AutomationRecipe(
        name: recipeName,
        steps: [AutomationRecipeStep(operation: recipeOperation, options: options)])
      let configuration = try WatchedFolderConfiguration(
        name: recipeName, watchedFolders: watchedFolders, outputFolder: outputFolder,
        recipe: recipe, settleInterval: settleInterval)
      let stateURL = outputFolder.appendingPathComponent(".spdf-automation/state.json")
      let engine = WatchedFolderEngine(configuration: configuration, stateURL: stateURL)
      self.engine = engine
      isWatching = true
      errorText = nil
      statusText = "Watching " + String(watchedFolders.count) + " folder(s); each stable "
        + "input is processed once."
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.scanNow() }
      }
      scanNow()
    } catch {
      errorText = error.localizedDescription
    }
  }

  func stopWatching() {
    timer?.invalidate()
    timer = nil
    engine = nil
    isWatching = false
    statusText = "Stopped watching. The processed-input state is kept in the output folder."
  }

  func scanNow() {
    guard let engine else { return }
    do {
      let report = try engine.scanOnce()
      summary = report.summary
      errorText = nil
      for item in report.processed {
        resultRows.insert(
          ResultRow(
            id: item.path + "-ok", title: URL(fileURLWithPath: item.path).lastPathComponent,
            detail: "Processed to " + (item.output ?? "output"), failed: false), at: 0)
      }
      for failure in report.failed {
        resultRows.insert(
          ResultRow(
            id: failure.path + "-failed",
            title: URL(fileURLWithPath: failure.path).lastPathComponent,
            detail: failure.message, failed: true), at: 0)
      }
      if resultRows.count > 200 { resultRows.removeLast(resultRows.count - 200) }
    } catch {
      errorText = error.localizedDescription
    }
  }
}

@MainActor
final class AutomationPanelController: NSWindowController {
  let model: AutomationPanelModel
  init(document: SPDFDocument) {
    let model = AutomationPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Automation"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 900, height: 640)
    panel.contentView = NSHostingView(rootView: AutomationPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the automation panel")
  }
}

extension SPDFDocument {
  /// AUT-05: open the automation capabilities/CLI/watched-folder panel.
  func showAutomationPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? AutomationPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = AutomationPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowAutomationPanel: Bool { true }
}

// MARK: - SwiftUI panel

struct AutomationPanelView: View {
  @ObservedObject var model: AutomationPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        profileSection
        Divider()
        watchedSection
        Divider()
        resultsSection
        footer
      }
      .padding(16)
    }
    .frame(minWidth: 900, minHeight: 640)
    .accessibilityLabel("Automation profile and watched folders")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Automation").font(.title3).bold()
        Spacer()
        Button("Copy CLI Command") { model.copyCLIPreview() }
        Button("Reload Profile") { model.reloadProfile() }
      }
      Text(model.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
      Text(model.cliPreview).font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
      Text(model.statusText).font(.caption).foregroundStyle(.secondary)
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var profileSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Declared operations").font(.headline)
      ForEach(model.operationRows) { operation in
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(operation.name).font(.caption.weight(.semibold))
            Text(operation.kind).font(.caption2).foregroundStyle(.secondary)
            Text(operation.usage).font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          ForEach(Array(operation.restrictions.enumerated()), id: \.offset) { item in
            Text("· " + item.element).font(.caption2).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      Text("Restrictions shared by the CLI, Shortcuts and AppleScript").font(.headline)
      ForEach(Array(model.restrictions.enumerated()), id: \.offset) { item in
        Text("· " + item.element).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var watchedSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Watched folders").font(.headline)
        Spacer()
        Button("Add Folder…") { addFolder() }
        Button("Choose Output Folder…") { chooseOutput() }
        Button(model.isWatching ? "Stop" : "Start Watching") {
          if model.isWatching { model.stopWatching() } else { model.startWatching() }
        }
        .disabled(model.watchedFolders.isEmpty || model.outputFolder == nil)
      }
      ForEach(Array(model.watchedFolders.enumerated()), id: \.offset) { item in
        HStack(spacing: 8) {
          Text(item.element.path).font(.caption2)
          Spacer()
          Button("Remove") { model.removeWatchedFolder(item.element) }
            .buttonStyle(.link)
        }
      }
      Text(model.outputFolder.map { "Output: " + $0.path } ?? "No output folder selected.")
        .font(.caption2).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        TextField("Recipe name", text: $model.recipeName).frame(width: 200)
        Picker("Operation", selection: $model.recipeOperation) {
          ForEach(writeOperationNames(), id: \.self) { name in
            Text(name).tag(name)
          }
        }
        .frame(width: 220)
        TextField("--pages (optional)", text: $model.recipeOptionPages).frame(width: 160)
        TextField("Settle (s)", value: $model.settleInterval, format: .number)
          .frame(width: 80)
      }
      .font(.caption2)
      Text(
        "The output folder must not be inside a watched folder. Processing waits for a stable "
          + "size/modification sample, stores each processed identity, and keeps failures "
          + "visible below; outputs do not retrigger the job.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var resultsSection: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Recent results").font(.headline)
      if model.resultRows.isEmpty {
        Text("No watched-folder result yet.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.resultRows) { row in
        HStack(spacing: 8) {
          Text(row.title).font(.caption.weight(.semibold))
          Text(row.detail).font(.caption2)
            .foregroundStyle(row.failed ? Color.red : Color.secondary)
        }
      }
    }
  }

  private var footer: some View {
    Text(
      "Automation uses the declared profile only: no hidden diagnostic flags, no document "
        + "script execution, no network, OCR or signing, and writes never overwrite inputs. "
        + "Accessibility audit output is not a conformance claim.")
      .font(.caption2).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func writeOperationNames() -> [String] {
    AutomationProfile.operations.filter { $0.kind == .write && $0.producesFile }
      .map(\.name)
  }

  private func addFolder() {
    let panel = NSOpenPanel()
    panel.title = "Select a Watched Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { model.addWatchedFolder(url) }
  }

  private func chooseOutput() {
    let panel = NSOpenPanel()
    panel.title = "Select the Output Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.outputFolder = url
    model.refreshCLIPreview()
  }
}
