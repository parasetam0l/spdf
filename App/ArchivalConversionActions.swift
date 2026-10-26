import AppKit
import PDFCore
import PDFEditing
import SwiftUI

/// PRE-01/PRE-02: document-facing conversion model. The panel stays
/// independent of SPDFDocument through closures; output is saved only when the
/// independent validator accepted the final bytes.
@MainActor
final class ArchivalConversionModel: ObservableObject {
  @Published var profile: ArchivalConversionProfile = .selected
  @Published var title = ""
  @Published var associatedFileName: String?
  @Published private(set) var outcome: ArchivalConversionOutcome?
  @Published private(set) var isConverting = false
  @Published private(set) var problem: String?

  var associatedFileData: Data?

  private let graphProvider: @MainActor () -> PDFGraph?
  private let sourceProvider: @MainActor () -> Data?
  private let saveProvider: @MainActor (Data) -> Bool

  init(
    graphProvider: @escaping @MainActor () -> PDFGraph?,
    sourceProvider: @escaping @MainActor () -> Data?,
    saveProvider: @escaping @MainActor (Data) -> Bool
  ) {
    self.graphProvider = graphProvider
    self.sourceProvider = sourceProvider
    self.saveProvider = saveProvider
  }

  var checks: [ArchivalConversionCheck] { outcome?.checks ?? [] }
  var losses: [String] { outcome?.losses ?? [] }
  var warnings: [String] { outcome?.warnings ?? [] }
  var disclosure: String { outcome?.disclosure ?? profile.disclosure }
  var canConvert: Bool { !isConverting }
  var canSave: Bool { outcome?.isConforming == true }
  var statusText: String { outcome?.status.rawValue ?? "Not converted" }
  var validationText: String {
    guard let validation = outcome?.validation else { return "Independent validation: not run" }
    return "\(validation.validator) \(validation.validatorVersion ?? "?") — "
      + (validation.isCompliant ? "compliant" : "not compliant")
  }

  func chooseAssociatedFile() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a file to embed as a PDF/A-3 associated file. PDF/A-1b and "
      + "PDF/A-2b refuse attachments; the relationship is recorded as Unspecified/Source."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024 else {
        problem = "The selected file is empty or too large for an associated file."
        return
      }
      associatedFileData = data
      associatedFileName = url.lastPathComponent
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  func convert() {
    guard let graph = graphProvider() else {
      problem = "No editable PDF graph is available."
      return
    }
    isConverting = true
    defer { isConverting = false }
    var files: [ArchivalAssociatedFile] = []
    if let associatedFileData, let associatedFileName {
      files = [
        ArchivalAssociatedFile(
          name: associatedFileName, data: associatedFileData,
          mimeType: "application/octet-stream", relationship: .source)
      ]
    }
    let options = ArchivalConversionOptions(
      profile: profile, title: title.isEmpty ? nil : title, associatedFiles: files)
    let converted = PDFAConverter.convert(graph: graph, options: options)
    outcome = converted
    problem = converted.isConforming ? nil : converted.warnings.first
  }

  func saveConversion() {
    guard let data = outcome?.data, outcome?.isConforming == true else {
      problem = "Only independently validated output can be saved."
      return
    }
    guard saveProvider(data) else {
      problem = "The converted file could not be written."
      return
    }
  }

  func reload() {
    outcome = nil
    problem = nil
  }
}

extension SPDFDocument {
  /// Hook: call from the "Convert to PDF/A…" menu item.
  @MainActor
  func archivalConversionModel() -> ArchivalConversionModel {
    ArchivalConversionModel(
      graphProvider: { [weak self] in
        guard let self else { return nil }
        if let graph = self.editSession.currentGraph { return graph }
        guard let data = self.sourceStore.snapshot()?.data else { return nil }
        return (try? PDFParser.parse(
          data, limits: SPDFDocumentResourcePolicy.parsingLimits))?.graph
      },
      sourceProvider: { [weak self] in
        guard let self else { return nil }
        return (try? self.editSession.bytesForSave()) ?? self.sourceStore.snapshot()?.data
      },
      saveProvider: { [weak self] data in
        guard let self else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let base = self.fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        panel.nameFieldStringValue = base + "-archive.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
          try data.write(to: url, options: .atomic)
          return true
        } catch {
          self.presentError(error)
          return false
        }
      })
  }

  var canShowArchivalConversionPanel: Bool {
    editSession.currentGraph != nil || sourceStore.snapshot()?.data != nil
  }

  /// Hook: Tools > Export > Convert to PDF/A…
  @MainActor
  func showArchivalConversionPanel() {
    let model = archivalConversionModel()
    model.reload()
    let hosting = NSHostingView(rootView: ArchivalConversionPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
    let alert = NSAlert()
    alert.messageText = "Convert to PDF/A"
    alert.alertStyle = .informational
    alert.informativeText =
      "The declared profile is completed, written and then validated by veraPDF. Bytes are "
      + "published only when the independent validator accepts the final saved file."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }
}
