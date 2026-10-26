import AppKit
import Combine
import MacServices
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// EXP-07: conversion job center panel. Reusable profiles, input list,
// destination/overwrite policy, preview, progress, cancellation and a per-file
// report with fidelity losses. Rendering for appearance profiles is supplied
// by the MacServices page renderer through the core seam.

@MainActor
final class ConversionJobCenterModel: ObservableObject {
  @Published var profile = ConversionProfile()
  @Published var inputs: [URL] = []
  @Published var outputFolder: URL?
  @Published var preview: [ConversionPreviewFile] = []
  @Published var report: ConversionJobReport?
  @Published var statusText = "Choose inputs and a profile, then run the job."
  @Published var errorText: String?
  @Published var progressText = ""
  @Published var isRunning = false

  private var cancellation: ConversionCancellation?

  var canRun: Bool { !isRunning && !inputs.isEmpty }

  func addInputs() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose PDF files to convert"
    guard panel.runModal() == .OK else { return }
    let existing = Set(inputs.map(\.standardizedFileURL))
    for url in panel.urls where !existing.contains(url.standardizedFileURL) {
      inputs.append(url)
    }
    preview = []
    errorText = nil
  }

  func chooseOutputFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    outputFolder = url
    preview = []
  }

  func refreshPreview() {
    do {
      preview = try ConversionJobCenter.preview(
        inputs: inputs, profile: profile,
        destination: ConversionDestination(folderURL: outputFolder))
      statusText = "\(preview.count) file(s); "
        + String(preview.filter { $0.refusal == nil }.count) + " ready."
      errorText = nil
    } catch {
      preview = []
      errorText = error.localizedDescription
    }
  }

  func run() {
    guard !inputs.isEmpty, !isRunning else { return }
    let profile = profile
    let inputs = inputs
    let destination = ConversionDestination(folderURL: outputFolder)
    let cancellation = ConversionCancellation()
    let appearanceRenderer =
      profile.fidelity == .appearance ? Self.appearanceRenderer : nil
    self.cancellation = cancellation
    isRunning = true
    report = nil
    errorText = nil
    progressText = "Starting conversion…"
    Task {
      do {
        let result: ConversionJobReport = try await Task.detached {
          try ConversionJobCenter.run(
            inputs: inputs, profile: profile, destination: destination,
            cancellation: cancellation,
            appearanceRenderer: appearanceRenderer,
            progress: { progress in
              Task { @MainActor [weak self] in
                self?.progressText = progress.stage.rawValue + ": " + progress.fileName
              }
            })
        }.value
        report = result
        statusText = result.summary
        isRunning = false
        self.cancellation = nil
      } catch {
        errorText = error.localizedDescription
        isRunning = false
        self.cancellation = nil
      }
    }
  }

  func cancel() {
    cancellation?.requestCancel()
    progressText = "Cancelling after the current file…"
  }

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

  func saveProfile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = profile.name + ".conversionprofile.json"
    panel.message = "Save this reusable conversion profile (settings only, no code)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try profile.jsonData().write(to: url, options: [.atomic])
      statusText = "Profile saved to " + url.lastPathComponent
    } catch {
      errorText = error.localizedDescription
    }
  }

  func loadProfile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "Open a shared conversion profile"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      profile = try ConversionProfile.decode(from: Data(contentsOf: url))
      preview = []
      statusText = "Loaded profile " + profile.name
    } catch {
      errorText = error.localizedDescription
    }
  }

  func exportReport(_ markdown: Bool) {
    guard let report else { return }
    let panel = NSSavePanel()
    if markdown {
      panel.allowedContentTypes = [.plainText]
      panel.nameFieldStringValue = report.profileName + " report.md"
    } else {
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = report.profileName + " report.json"
    }
    panel.message = "Export the per-file conversion report"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      if markdown {
        try report.markdown().write(to: url, atomically: true, encoding: .utf8)
      } else {
        try report.jsonData().write(to: url, options: [.atomic])
      }
    } catch {
      errorText = error.localizedDescription
    }
  }
}

@MainActor
final class ConversionJobCenterPanelController: NSWindowController {
  let model: ConversionJobCenterModel

  init() {
    let model = ConversionJobCenterModel()
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Conversion Job Center"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: ConversionJobCenterView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the conversion job center")
  }
}

struct ConversionJobCenterView: View {
  @ObservedObject var model: ConversionJobCenterModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      HSplitView {
        profileEditor
        results
      }
    }
    .frame(minWidth: 860, minHeight: 600)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Conversion job center")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Conversion Job Center").font(.headline)
        Spacer()
        Button("Add Files…") { model.addInputs() }
        Button("Choose Output Folder…") { model.chooseOutputFolder() }
        Button("Preview") { model.refreshPreview() }
          .disabled(model.inputs.isEmpty || model.isRunning)
        Button("Run") { model.run() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canRun)
        Button("Cancel") { model.cancel() }
          .disabled(!model.isRunning)
        Button("Save Profile…") { model.saveProfile() }
        Button("Open Profile…") { model.loadProfile() }
      }
      HStack {
        Text(model.statusText).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if !model.progressText.isEmpty {
          Text(model.progressText).font(.caption2).foregroundStyle(.secondary)
        }
      }
      if let error = model.errorText {
        Label {
          Text(error).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption).foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(.bar)
  }

  private var profileEditor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Reusable Profile").font(.subheadline.weight(.semibold))
        TextField("Profile name", text: $model.profile.name)
          .textFieldStyle(.roundedBorder)
        HStack {
          Picker("Format", selection: $model.profile.format) {
            ForEach(SelectionExportFormat.allCases, id: \.self) { format in
              Text(format.displayName).tag(format)
            }
          }
          Picker("Fidelity", selection: $model.profile.fidelity) {
            ForEach(ExportFidelity.allCases, id: \.self) { fidelity in
              Text(fidelity.displayName).tag(fidelity)
            }
          }
        }
        .pickerStyle(.menu)
        if model.profile.fidelity == .appearance {
          Toggle(
            "Appearance is a rendered image, not editable text",
            isOn: $model.profile.acknowledgeAppearanceIsRendered)
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        Picker("Scope", selection: $model.profile.scope) {
          Text("Whole document").tag(ConversionScopeMode.document)
          Text("Page range").tag(ConversionScopeMode.pageRange)
        }
        .pickerStyle(.segmented)
        if model.profile.scope == .pageRange {
          HStack {
            TextField("From", value: Binding(
              get: { model.profile.pageRangeStart ?? 1 },
              set: { model.profile.pageRangeStart = $0 }), format: .number)
              .textFieldStyle(.roundedBorder).frame(width: 70)
            TextField("To", value: Binding(
              get: { model.profile.pageRangeEnd ?? 1 },
              set: { model.profile.pageRangeEnd = $0 }), format: .number)
              .textFieldStyle(.roundedBorder).frame(width: 70)
          }
        }
        TextField("Output name template", text: $model.profile.namingTemplate)
          .textFieldStyle(.roundedBorder)
        Picker("Overwrite", selection: $model.profile.overwrite) {
          ForEach(
            [ConversionOverwritePolicy.uniqueSuffix, .fail, .replaceExistingOutputs],
            id: \.self
          ) { policy in
            Text(policy.displayName).tag(policy)
          }
        }
        TextField("Document title", text: Binding(
          get: { model.profile.documentTitle ?? "" },
          set: { model.profile.documentTitle = $0.isEmpty ? nil : $0 }))
          .textFieldStyle(.roundedBorder)
        Text(
          "Fidelity: " + model.profile.fidelity.statement + " "
            + model.profile.format.declaredProfile)
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("Inputs (\(model.inputs.count))").font(.subheadline.weight(.semibold))
        ForEach(model.inputs, id: \.self) { url in
          Text(url.lastPathComponent).font(.caption2)
        }
        Text("Outputs: " + (model.outputFolder?.path ?? "beside each input"))
          .font(.caption2).foregroundStyle(.secondary)
      }
      .padding(12)
    }
    .frame(minWidth: 380)
  }

  private var results: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if !model.preview.isEmpty {
          Text("Plan Preview").font(.subheadline.weight(.semibold))
          ForEach(Array(model.preview.indices), id: \.self) { index in
            let file = model.preview[index]
            VStack(alignment: .leading, spacing: 2) {
              Text(file.fileName).font(.caption.weight(.semibold))
              Text(file.outputURL?.lastPathComponent ?? file.refusal ?? "no output")
                .font(.caption2)
                .foregroundStyle(file.refusal == nil ? Color.secondary : Color.red)
            }
          }
        }
        Text("Per-file Outcomes").font(.subheadline.weight(.semibold))
        if let report = model.report {
          Text(report.summary).font(.caption)
          ForEach(Array(report.files.indices), id: \.self) { index in
            let file = report.files[index]
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(file.inputName).font(.caption.weight(.semibold))
                Spacer()
                Text(file.status.displayName)
                  .font(.caption2)
                  .foregroundStyle(file.status == .succeeded ? Color.secondary : Color.orange)
              }
              if let output = file.outputPath {
                Text("→ " + URL(fileURLWithPath: output).lastPathComponent)
                  .font(.caption2).foregroundStyle(.secondary)
              }
              if let failure = file.failure {
                Text(failure).font(.caption2).foregroundStyle(.red)
              } else {
                ForEach(file.fidelityLosses, id: \.self) { loss in
                  Text(loss).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2)
                }
              }
            }
            .padding(.vertical, 2)
          }
          HStack {
            Button("Export Report JSON…") { model.exportReport(false) }
            Button("Export Markdown…") { model.exportReport(true) }
          }
          .font(.caption)
        } else {
          Text("No job run yet. Every succeeded conversion reports its fidelity losses; a failure keeps completed outputs.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(12)
    }
    .frame(minWidth: 420, maxWidth: 560, alignment: .leading)
  }
}

extension SPDFDocument {
  /// EXP-07: open the conversion job center. File-based, independent of the
  /// currently open document.
  func showConversionJobCenter() {
    if let controller = windowControllers.compactMap({
      $0 as? ConversionJobCenterPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ConversionJobCenterPanelController()
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowConversionJobCenter: Bool { true }
}
