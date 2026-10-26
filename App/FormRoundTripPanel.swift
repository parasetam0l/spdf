import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - FRM-06 round-trip form data panel

@MainActor
final class FormRoundTripModel: ObservableObject {
  @Published var bundle: FormRoundTripBundle?
  @Published var summaryLines: [String] = []
  @Published var statusText: String?
  @Published var errorText: String?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    capture()
  }

  var fields: [FormRoundTripField] { bundle?.fields ?? [] }
  var unsupported: [FormUnsupportedExternalAction] { bundle?.unsupported ?? [] }

  func capture() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      return
    }
    do {
      bundle = try FormRoundTripData.capture(
        in: graph, pageIDs: document.editSession.pageIDs)
      summaryLines = bundle?.summaryLines ?? []
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }

  func exportValues() {
    guard let document, let bundle else {
      errorText = "No form values are available to export."
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-form-values.json"
    panel.begin { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      do {
        try bundle.jsonData().write(to: url, options: .atomic)
        self.statusText =
          "Exported \(bundle.fields.count) field value(s); unsupported external actions "
          + "are listed but never executed."
        self.errorText = nil
      } catch {
        self.errorText = error.localizedDescription
      }
    }
  }

  func importValues() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      return
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = "Choose a portable form-values JSON file (values only)."
    panel.prompt = "Import Values"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let imported = try FormRoundTripData.parse(data)
      let pageIDs = document.editSession.pageIDs
      let mapping = try FormRoundTripData.commands(
        for: imported, in: graph, pageIDs: pageIDs)
      guard !mapping.commands.isEmpty else {
        errorText =
          "No values map onto this document's fields. Skipped: "
          + (mapping.skipped.isEmpty ? "none" : mapping.skipped.joined(separator: ", "))
        return
      }
      let alert = NSAlert()
      alert.messageText = "Import Form Values"
      alert.informativeText =
        "Values only: no appearance streams, /NeedAppearances, /DA or /DR will be written "
        + "and no viewer cleanup is requested. \(mapping.commands.count) value(s) map onto "
        + "this document."
        + (mapping.skipped.isEmpty
          ? "" : " Skipped: " + mapping.skipped.joined(separator: ", "))
        + (mapping.ambiguous.isEmpty
          ? "" : " Ambiguous (first field used): " + mapping.ambiguous.joined(separator: ", "))
      alert.addButton(withTitle: "Import")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      guard
        document.applyPageOrganizerTransaction(
          PDFTransaction(mapping.commands), actionName: "Import Form Values (Portable)")
      else {
        errorText = "The form-value import was refused by the document session."
        return
      }
      capture()
      statusText =
        "Imported \(mapping.commands.count) value(s); "
        + "\(mapping.skipped.count) skipped, \(mapping.ambiguous.count) ambiguous. "
        + "No viewer cleanup instructions were written."
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }
}

// MARK: - Window

@MainActor
final class FormRoundTripWindowController: NSWindowController {
  let model: FormRoundTripModel

  init(document: SPDFDocument) {
    let model = FormRoundTripModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Portable Form Data (Round Trip)"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 640, height: 480)
    panel.contentView = NSHostingView(rootView: FormRoundTripView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the form round-trip panel")
  }

  func refresh() { model.capture() }
}

// MARK: - View

struct FormRoundTripView: View {
  @ObservedObject var model: FormRoundTripModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Portable Form Data").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "Exports field values and field semantics only - never appearance streams, DA/DR or "
          + "NeedAppearances - so an independent reader does not need viewer-specific cleanup. "
          + "Imports write values only. Unsupported external actions are identified and never "
          + "executed.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Refresh") { model.capture() }
        Button("Export Values…") { model.exportValues() }
          .accessibilityLabel("Export portable form values")
        Button("Import Values…") { model.importValues() }
          .accessibilityLabel("Import portable form values")
        Spacer()
        Text("\(model.fields.count) field(s)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let error = model.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let status = model.statusText {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !model.unsupported.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("Unsupported external actions (never executed)")
            .font(.caption.weight(.semibold))
          ForEach(Array(model.unsupported.enumerated()), id: \.offset) { _, action in
            Text(
              (action.field.map { $0 + ": " } ?? "")
                + action.action + " - " + action.reason)
              .font(.caption2)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(model.fields.enumerated()), id: \.offset) { _, field in
            HStack(alignment: .top, spacing: 8) {
              Text(field.name)
                .font(.caption.monospaced())
                .frame(minWidth: 120, alignment: .leading)
              Text(field.kind)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .leading)
              if let value = field.value, !value.isEmpty {
                Text(value)
                  .font(.caption)
                  .lineLimit(2)
              }
              if let state = field.buttonState {
                Text(state)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              if field.required {
                Text("required")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
              if field.readOnly {
                Text("read-only")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              if let tooltip = field.tooltip, !tooltip.isEmpty {
                Text("label: " + tooltip)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
          }
        }
        .padding(4)
      }
      Divider()
      Text(model.summaryLines.joined(separator: "\n"))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(minWidth: 640, minHeight: 480)
    .accessibilityLabel("Portable form data round trip")
  }
}

// MARK: - Document route

extension SPDFDocument {
  var canShowFormRoundTripPanel: Bool {
    editSession.currentGraph != nil
  }

  func presentFormRoundTripPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? FormRoundTripWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FormRoundTripWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
