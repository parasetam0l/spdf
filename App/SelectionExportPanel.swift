import AppKit
import Combine
import MacServices
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// EXP-06: selection/range export panel. Scope, format and fidelity are chosen
// explicitly; the panel shows the fidelity statement before writing and uses
// the owned export engine. Appearance exports use the MacServices renderer.

@MainActor
final class SelectionExportPanelModel: ObservableObject {
  enum ScopeKind: String, CaseIterable, Identifiable {
    case document
    case pageRange
    var id: String { rawValue }
    var title: String { self == .document ? "Whole document" : "Page range" }
  }

  @Published var scopeKind: ScopeKind = .document
  @Published var pageRangeStart = 1
  @Published var pageRangeEnd = 1
  @Published var format: SelectionExportFormat = .text
  @Published var fidelity: ExportFidelity = .editable
  @Published var documentTitle = ""
  @Published var acknowledgeAppearance = false
  @Published var statusText = "Choose a scope and format, then export."
  @Published var errorText: String?
  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
  }

  var pageCount: Int { document?.editSession.pageIDs.count ?? 0 }

  var scope: ExportScope {
    if scopeKind == .pageRange {
      let start = max(1, min(pageRangeStart, max(1, pageCount)))
      let end = max(start, min(pageRangeEnd, max(1, pageCount)))
      return .pageRange(start...end)
    }
    return .document
  }

  var scopeSummary: String { scope.summary }

  var fidelityStatement: String {
    fidelity.statement + " " + format.declaredProfile
  }

  func export() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "No document content is available."
      return
    }
    let pageIDs = document.editSession.pageIDs
    let format = format
    let fidelity = fidelity
    if fidelity == .appearance, !acknowledgeAppearance {
      errorText = "Acknowledge that an appearance export is a rendered image, not editable text."
      return
    }
    let scope = scope
    var options = SelectionExportOptions(documentTitle: documentTitle.isEmpty ? nil : documentTitle)
    options.acknowledgeAppearanceIsRendered = acknowledgeAppearance
    let renderer = fidelity == .appearance ? Self.appearanceRenderer : nil
    do {
      let payload = try SelectionExport.export(
        format: format, scope: scope, fidelity: fidelity, options: options,
        in: graph, pageIDs: pageIDs, appearanceRenderer: renderer)
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "export." + payload.fileExtension
      panel.message = payload.fidelityStatement
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try payload.data.write(to: url, options: [.atomic])
      statusText = "Exported " + payload.scopeDescription + " to " + url.lastPathComponent
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }
}

extension SelectionExportPanelModel {
  /// Bridges the owned core renderer seam to the MacServices page renderer.
  static var appearanceRenderer: AppearanceRenderer {
    AppearanceRenderer { request in
      guard let imageData = try? PageImageExport.regionImageData(
        pageID: request.pageID, in: request.graph,
        region: request.region ?? [0, 0, 612, 792],
        options: PageImageExportOptions(format: .png, dpi: request.dpi))
      else {
        throw PDFError(.unsupported, "The appearance renderer could not render this page")
      }
      return AppearanceImage(pngData: imageData, pixelWidth: 0, pixelHeight: 0)
    }
  }
}

@MainActor
final class SelectionExportPanelController: NSWindowController {
  let model: SelectionExportPanelModel

  init(document: SPDFDocument) {
    let model = SelectionExportPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
      styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Export Selection / Range"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: SelectionExportPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the selection export panel")
  }
}

struct SelectionExportPanelView: View {
  @ObservedObject var model: SelectionExportPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Export Scope").font(.headline)
      Picker("Scope", selection: $model.scopeKind) {
        ForEach(SelectionExportPanelModel.ScopeKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      if model.scopeKind == .pageRange {
        HStack {
          TextField("From", value: $model.pageRangeStart, format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 70)
          TextField("To", value: $model.pageRangeEnd, format: .number)
            .textFieldStyle(.roundedBorder).frame(width: 70)
          Text("of \(model.pageCount) page(s)").font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      Text("Format and Fidelity").font(.headline)
      HStack {
        Picker("Format", selection: $model.format) {
          ForEach(SelectionExportFormat.allCases, id: \.self) { format in
            Text(format.displayName).tag(format)
          }
        }
        .frame(maxWidth: 220)
        Picker("Fidelity", selection: $model.fidelity) {
          ForEach(ExportFidelity.allCases, id: \.self) { fidelity in
            Text(fidelity.displayName).tag(fidelity)
          }
        }
        .frame(maxWidth: 220)
      }
      .pickerStyle(.menu)
      if model.fidelity == .appearance {
        Toggle(
          "I understand the appearance export is a rendered image, not editable text",
          isOn: $model.acknowledgeAppearance)
          .toggleStyle(.checkbox)
          .font(.caption)
      }
      TextField("Document title", text: $model.documentTitle)
        .textFieldStyle(.roundedBorder)
      Text(model.scopeSummary)
        .font(.caption).foregroundStyle(.secondary)
      Text(model.fidelityStatement)
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let error = model.errorText {
        Label {
          Text(error).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption).foregroundStyle(.red)
      }
      Text(model.statusText).font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { NSApp.keyWindow?.close() }
        Button("Export…") { model.export() }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(16)
    .frame(minWidth: 500, minHeight: 420, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Export selection or range")
  }
}

extension SPDFDocument {
  /// EXP-06: open the selection/range export panel.
  func showSelectionExportPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? SelectionExportPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SelectionExportPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowSelectionExportPanel: Bool { editSession.currentGraph != nil }
}
