import AppKit
import PDFCore
import PDFEditing
import SwiftUI

// SPC-03: layer authoring panel. Supported: naming, default screen state,
// print/view usage, flat order, and content membership marking. Nested order,
// /AS automatic state and OCMD are audited and refused, never rewritten.

@MainActor
final class LayersPanelModel: ObservableObject {
  @Published private(set) var graph: PDFGraph?
  @Published private(set) var inventory: OptionalContentLayerInventory?
  @Published private(set) var audit: OptionalContentAudit?
  @Published private(set) var statusText: String?
  @Published private(set) var errorText: String?
  @Published var newLayerName = ""
  @Published var selectedLayerID: PDFObjectID?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    load()
  }

  var layers: [OptionalContentLayer] { inventory?.layers ?? [] }

  func load() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      return
    }
    self.graph = graph
    inventory = OptionalContentInventory.inspect(in: graph)
    audit = OptionalContentAuditService.audit(in: graph)
    errorText = nil
    statusText = "Inventory and audit are read-only; authoring actions are one transaction."
  }

  func select(_ id: PDFObjectID) { selectedLayerID = id }

  func rename(_ layer: OptionalContentLayer, to name: String) {
    guard let document else { return }
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([RenameLayerCommand(layerID: layer.objectID, name: name)]),
        actionName: "Rename Layer")
    else {
      errorText = "Renaming the layer was refused."
      return
    }
    load()
  }

  func setVisibility(
    _ layer: OptionalContentLayer, screen: Bool? = nil, print: Bool? = nil,
    view: Bool? = nil
  ) {
    guard let document else { return }
    let command = SetLayerVisibilityCommand(
      layerID: layer.objectID, screenVisible: screen, printVisible: print,
      viewVisible: view)
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([command]), actionName: "Set Layer Visibility")
    else {
      errorText = "Changing layer visibility was refused."
      return
    }
    load()
  }

  func addLayer() {
    guard let document else { return }
    let command = AddLayerCommand(name: newLayerName)
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([command]), actionName: "Add Layer")
    else {
      errorText = "Adding the layer was refused."
      return
    }
    newLayerName = ""
    load()
  }

  func move(_ layer: OptionalContentLayer, offset: Int) {
    guard let document else { return }
    var ids = layers.map(\.objectID)
    guard let index = ids.firstIndex(of: layer.objectID) else { return }
    let target = index + offset
    guard target >= 0, target < ids.count else { return }
    ids.swapAt(index, target)
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([ReorderLayersCommand(orderedLayerIDs: ids)]),
        actionName: "Reorder Layers")
    else {
      errorText = "Reordering the layers was refused."
      return
    }
    load()
  }

  func exportAudit() {
    guard let audit else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let base = document?.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-layer-audit.txt"
    let text = audit.report
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        self?.statusText = "Layer audit exported."
      } catch {
        self?.errorText = error.localizedDescription
      }
    }
  }
}

@MainActor
final class LayersPanelWindowController: NSWindowController {
  let model: LayersPanelModel

  init(document: SPDFDocument) {
    let model = LayersPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Layers"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: LayersPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for layers")
  }

  func refresh() { model.load() }
}

struct LayersPanelView: View {
  @ObservedObject var model: LayersPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Layers").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "Supported profile: layer names, default screen visibility, print/view usage states, "
          + "flat order and content membership marking. Nested order, /AS automatic state and "
          + "OCMD are audited and refused; the composite display path is disclosed, not changed.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        TextField("New layer name", text: $model.newLayerName)
          .textFieldStyle(.roundedBorder)
        Button("Add Layer") { model.addLayer() }
          .disabled(model.newLayerName.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Export Audit…") { model.exportAudit() }
      }
      if let error = model.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.layers) { layer in
            layerRow(layer)
          }
          if model.layers.isEmpty {
            Text("No optional-content layers were found.").foregroundStyle(.secondary)
          }
        }
      }
      if let audit = model.audit {
        GroupBox("Audit") {
          Text(audit.report)
            .font(.caption2.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
      }
    }
    .padding(14)
    .frame(minWidth: 800, minHeight: 560)
    .accessibilityLabel("Layer authoring")
  }

  private func layerRow(_ layer: OptionalContentLayer) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(layer.name ?? "Unnamed layer")
          .font(.headline)
        Text("order \(layer.orderIndex.map(String.init) ?? "—")")
          .font(.caption2).foregroundStyle(.secondary)
        Text("membership \(layer.membershipCount); annotations \(layer.annotationCount)")
          .font(.caption2).foregroundStyle(.secondary)
        Spacer()
        Button("Up") { model.move(layer, offset: -1) }
          .buttonStyle(.link)
          .accessibilityLabel("Move layer up")
        Button("Down") { model.move(layer, offset: 1) }
          .buttonStyle(.link)
          .accessibilityLabel("Move layer down")
      }
      HStack(spacing: 10) {
        Toggle(
          "Screen",
          isOn: Binding(
            get: { layer.defaultVisible },
            set: { model.setVisibility(layer, screen: $0) }))
        Toggle(
          "Print",
          isOn: Binding(
            get: { layer.printState == .on },
            set: { model.setVisibility(layer, print: $0) }))
        Toggle(
          "View",
          isOn: Binding(
            get: { layer.viewState == .on },
            set: { model.setVisibility(layer, view: $0) }))
        Spacer()
        Button("Rename…") { renamePrompt(layer) }
          .accessibilityLabel("Rename layer " + (layer.name ?? "unnamed"))
      }
      Text("Print: \(layer.printState.title); View: \(layer.viewState.title)")
        .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(8)
    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
  }

  private func renamePrompt(_ layer: OptionalContentLayer) {
    let alert = NSAlert()
    alert.messageText = "Rename Layer"
    alert.informativeText = "Choose a unique layer name."
    let field = NSTextField(string: layer.name ?? "")
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    model.rename(layer, to: field.stringValue)
  }
}

extension SPDFDocument {
  var canShowLayersPanel: Bool { editSession.currentGraph != nil }

  func presentLayersPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? LayersPanelWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = LayersPanelWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
