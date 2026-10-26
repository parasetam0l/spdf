import AppKit
import Combine
import MacServices
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// AUT-03/AUT-04: the batch recipes panel. The model composes an ordered recipe
// from the supported safe operations, previews the resolved plan per file,
// runs it with a per-file checkpoint and stop/resume, and keeps the partial
// success report visible. OCR and DOCX export are supplied here as app-layer
// service performers because they depend on MacServices/platform frameworks;
// the panel refuses to run a recipe whose service step has no performer.

// MARK: - App-provided service performers

/// DOCX export service performer using the owned reconstruction/export code.
struct BatchDOCXServicePerformer: BatchStepPerformer {
  let kind = BatchActionKind.exportDOCX

  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    let parsed = try PDFParser.parse(request.sourceBytes)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    let data = try DOCXExport.package(reconstruction: reconstruction)
    let note =
      "DOCX reconstructed with \(reconstruction.blocks.count) block(s)"
      + (reconstruction.limitations.isEmpty
        ? "" : "; limitations: " + reconstruction.limitations.joined(separator: "; "))
    return BatchStepOutcome(data: data, note: note, warnings: reconstruction.limitations)
  }
}

/// OCR service performer using the existing local Vision-backed OCR batch
/// pipeline. The performer bridges the async pipeline because the batch runner
/// executes synchronously off the main actor.
struct BatchOCRServicePerformer: BatchStepPerformer {
  let kind = BatchActionKind.ocr

  private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var error: Error?

    func store(data: Data?, error: Error?) {
      lock.lock()
      self.data = data
      self.error = error
      lock.unlock()
    }

    func load() -> (data: Data?, error: Error?) {
      lock.lock()
      defer { lock.unlock() }
      return (data, error)
    }
  }

  func perform(_ request: BatchStepRequest) throws -> BatchStepOutcome {
    guard let settings = request.step.ocr else {
      throw PDFError(.malformed, "The OCR step has no settings")
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("spdf-batch-ocr-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let batchSettings = OCRBatchSettings(
      outputDirectory: directory, nameTemplate: "{name}-OCR.pdf",
      languages: settings.languages.isEmpty ? ["en-US"] : settings.languages,
      overwriteExisting: true,
      reportFileName: "spdf-batch-ocr-report.json")
    let semaphore = DispatchSemaphore(value: 0)
    let output = OutputBox()
    Task {
      do {
        let run = try await OCRBatchQueue.run(
          inputs: [request.inputURL], settings: batchSettings)
        var data: Data?
        if let item = run.items.first,
          item.status == .completed || item.status == .resumed
        {
          data = try? Data(contentsOf: item.outputURL)
        }
        if let data {
          output.store(data: data, error: nil)
        } else if let failure = run.items.first?.failure {
          output.store(
            data: nil, error: PDFError(.unsupported, "OCR failed: " + failure))
        } else {
          output.store(
            data: nil, error: PDFError(.unsupported, "OCR produced no output for this file"))
        }
      } catch {
        output.store(data: nil, error: error)
      }
      semaphore.signal()
    }
    semaphore.wait()
    let resolved = output.load()
    if let error = resolved.error { throw error }
    guard let data = resolved.data else {
      throw PDFError(.unsupported, "OCR produced no output for this file")
    }
    return BatchStepOutcome(
      data: data,
      note: "OCR text layer added locally with "
        + (settings.languages.isEmpty ? "en-US" : settings.languages.joined(separator: "+")))
  }
}

// MARK: - Model

@MainActor
final class BatchRecipesPanelModel: ObservableObject {
  @Published var recipe = BatchRecipe(
    name: "Archive batch",
    steps: [
      BatchRecipeStep(kind: .optimize),
      BatchRecipeStep(kind: .preflight),
    ])
  @Published var inputs: [URL] = []
  @Published var destinationFolder: URL?
  @Published var nameTemplate = "{name}-{recipe}"
  @Published var overwriteExistingOutputs = false
  @Published var failOnCollision = false
  @Published var preview: BatchPreview?
  @Published var report: BatchRunReport?
  @Published var checkpointURL: URL?
  @Published var statusText = "Compose a recipe, add files and preview the plan."
  @Published var errorText: String?
  @Published var progressText = ""
  @Published var isRunning = false
  @Published var selectedStepID: UUID?

  private var control: BatchRunControl?
  private var lastCheckpointURL: URL?

  var canRun: Bool {
    !isRunning && !inputs.isEmpty && (preview?.canRun ?? true)
  }

  var canResume: Bool { !isRunning && lastCheckpointURL != nil && ((report?.hasPartialSuccess) ?? false) }

  func addInputs() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = "Choose the PDF files for this batch"
    guard panel.runModal() == .OK else { return }
    let existing = Set(inputs.map(\.standardizedFileURL))
    for url in panel.urls where !existing.contains(url.standardizedFileURL) {
      inputs.append(url)
    }
    errorText = nil
    preview = nil
    statusText = "\(inputs.count) input file(s) selected."
  }

  func clearInputs() {
    inputs = []
    preview = nil
    report = nil
    checkpointURL = nil
    lastCheckpointURL = nil
    statusText = "Compose a recipe, add files and preview the plan."
  }

  func addStep(_ kind: BatchActionKind) {
    recipe.steps.append(BatchRecipeStep(kind: kind))
    selectedStepID = recipe.steps.last?.id
    preview = nil
  }

  func removeStep(_ id: UUID) {
    recipe.steps.removeAll { $0.id == id }
    if selectedStepID == id { selectedStepID = recipe.steps.first?.id }
    preview = nil
  }

  func moveStep(_ id: UUID, offset: Int) {
    guard let index = recipe.steps.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard recipe.steps.indices.contains(target) else { return }
    recipe.steps.swapAt(index, target)
    preview = nil
  }

  func destinationPolicy() -> BatchDestinationPolicy {
    var policy: BatchDestinationPolicy
    if let destinationFolder {
      policy = BatchDestinationPolicy(
        mode: .folder, folderPath: destinationFolder.path,
        collision: failOnCollision ? .fail : .uniqueSuffix,
        overwriteExistingOutputs: overwriteExistingOutputs, nameTemplate: nameTemplate)
    } else {
      policy = BatchDestinationPolicy(
        mode: .besideInput,
        collision: failOnCollision ? .fail : .uniqueSuffix,
        overwriteExistingOutputs: overwriteExistingOutputs, nameTemplate: nameTemplate)
    }
    return policy
  }

  func chooseDestinationFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.message = "Choose the output folder for batch results"
    guard panel.runModal() == .OK else { return }
    destinationFolder = panel.url
    preview = nil
  }

  func performers() -> BatchPerformerRegistry {
    BatchStandardPerformers.registry()
      .registering([BatchOCRServicePerformer(), BatchDOCXServicePerformer()])
  }

  func refreshPreview() {
    do {
      recipe.name = recipe.name.trimmingCharacters(in: .whitespacesAndNewlines)
      preview = try BatchPlanner.preview(
        recipe: recipe, inputs: inputs, destination: destinationPolicy(),
        performers: performers())
      errorText = nil
      let preview = preview
      statusText = preview?.summary ?? "No plan."
    } catch {
      preview = nil
      errorText = error.localizedDescription
    }
  }

  func run(resume: Bool = false) {
    guard !inputs.isEmpty, !isRunning else { return }
    let recipe = recipe
    let options = BatchRunOptions(
      destination: destinationPolicy(), resume: resume,
      continueOnError: true)
    let registry = performers()
    let control = BatchRunControl()
    self.control = control
    isRunning = true
    errorText = nil
    report = nil
    progressText = "Starting batch…"
    let inputs = inputs
    Task {
      do {
        let result = try await Task.detached {
          try BatchRunner.run(
            recipe: recipe, inputs: inputs, options: options,
            performers: registry, control: control,
            progress: { progress in
              let text =
                progress.stage.rawValue + ": " + progress.fileName
                + (progress.stepCount > 0
                  ? " (" + String(progress.completedSteps) + "/"
                    + String(progress.stepCount) + " steps)" : "")
              Task { @MainActor [weak self] in
                self?.progressText = text
              }
            })
        }.value
        report = result.report
        checkpointURL = result.checkpointURL
        lastCheckpointURL = result.checkpointURL
        statusText = result.report.summary
        isRunning = false
        self.control = nil
      } catch {
        errorText = error.localizedDescription
        isRunning = false
        self.control = nil
      }
    }
  }

  func stop() {
    control?.requestStop()
    progressText = "Stopping after the current file…"
  }

  func saveRecipe() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = recipe.name + ".spdfrecipe.json"
    panel.message = "Save this reusable batch recipe (settings only, no code)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try recipe.jsonData().write(to: url, options: [.atomic])
      statusText = "Recipe saved to " + url.lastPathComponent
    } catch {
      errorText = error.localizedDescription
    }
  }

  func loadRecipe() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = "Open a shared batch recipe"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      recipe = try BatchRecipe.decode(from: Data(contentsOf: url))
      preview = nil
      statusText = "Loaded recipe " + recipe.name
    } catch {
      errorText = error.localizedDescription
    }
  }

  func exportReport(_ markdown: Bool) {
    guard let report else { return }
    let panel = NSSavePanel()
    if markdown {
      panel.allowedContentTypes = [.plainText]
      panel.nameFieldStringValue = report.recipeName + " report.md"
    } else {
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = report.recipeName + " report.json"
    }
    panel.message = "Export the batch outcome report"
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

// MARK: - Panel controller and view

@MainActor
final class BatchRecipesPanelController: NSWindowController {
  let model: BatchRecipesPanelModel

  init() {
    let model = BatchRecipesPanelModel()
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Batch Recipes"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 860, height: 560)
    panel.contentView = NSHostingView(rootView: BatchRecipesPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the batch recipes panel")
  }
}

struct BatchRecipesPanelView: View {
  @ObservedObject var model: BatchRecipesPanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      HSplitView {
        stepEditor
        rightColumn
      }
    }
    .frame(minWidth: 860, minHeight: 560)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Batch recipes")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Batch Recipes").font(.headline)
        TextField("Recipe name", text: $model.recipe.name)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 260)
        Spacer()
        Button("Add Files…") { model.addInputs() }
        Button("Clear") { model.clearInputs() }
          .disabled(model.inputs.isEmpty)
        Button("Save Recipe…") { model.saveRecipe() }
        Button("Open Recipe…") { model.loadRecipe() }
      }
      HStack(spacing: 12) {
        Button("Preview Plan") { model.refreshPreview() }
          .disabled(model.inputs.isEmpty || model.isRunning)
        Button("Run") { model.run() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canRun)
        Button("Stop") { model.stop() }
          .disabled(!model.isRunning)
        Button("Resume") { model.run(resume: true) }
          .disabled(!model.canResume)
        Spacer()
        Button("Export Report…") { model.exportReport(false) }
          .disabled(model.report == nil)
        Button("Export Markdown…") { model.exportReport(true) }
          .disabled(model.report == nil)
      }
      .font(.caption)
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
      destinationControls
    }
    .padding(12)
    .background(.bar)
  }

  private var destinationControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text("Destination").font(.caption).foregroundStyle(.secondary)
          .frame(width: 74, alignment: .leading)
        Picker(
          "Destination",
          selection: Binding(
            get: { model.destinationFolder == nil ? 0 : 1 },
            set: { newValue in
              if newValue == 0 {
                model.destinationFolder = nil
              } else {
                model.chooseDestinationFolder()
              }
            })
        ) {
          Text("Beside inputs").tag(0)
          Text("Folder…").tag(1)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 200)
        if let folder = model.destinationFolder {
          Text(folder.lastPathComponent).font(.caption2).lineLimit(1)
        }
        TextField("Name template", text: $model.nameTemplate)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 240)
          .help("Output file name template, for example {name}-{recipe}.")
        Spacer()
      }
      HStack(spacing: 14) {
        Toggle("Replace existing outputs", isOn: $model.overwriteExistingOutputs)
          .toggleStyle(.checkbox)
          .help("Allow writing over outputs that already exist. Inputs are never overwritten.")
        Toggle("Fail on collision", isOn: $model.failOnCollision)
          .toggleStyle(.checkbox)
          .help("Fail instead of adding a unique suffix when an output name already exists.")
        Spacer()
      }
    }
    .font(.caption)
  }

  private var stepEditor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Ordered Steps").font(.subheadline.weight(.semibold))
          Spacer()
          Menu("Add Step") {
            ForEach(BatchActionKind.allCases, id: \.self) { kind in
              Button(kind.displayName) { model.addStep(kind) }
            }
          }
          .frame(maxWidth: 140)
        }
        ForEach(Array(model.recipe.steps.enumerated()), id: \.offset) { index, step in
          stepRow(step, index: index)
        }
        Text(
          "The recipe is settings only: it composes the supported safe operations and never carries code. "
            + "OCR and DOCX export need the app service performers above.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
    }
    .frame(minWidth: 460)
  }

  private func stepRow(_ step: BatchRecipeStep, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Toggle(
          "", isOn: Binding(
            get: { step.enabled },
            set: { newValue in
              if let index = model.recipe.steps.firstIndex(where: { $0.id == step.id }) {
                model.recipe.steps[index].enabled = newValue
              }
            }))
          .labelsHidden()
          .toggleStyle(.checkbox)
        Text(String(index + 1) + ". " + step.kind.displayName)
          .font(.body.weight(.medium))
        Spacer()
        Button {
          model.moveStep(step.id, offset: -1)
        } label: {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .accessibilityLabel("Move step up")
        Button {
          model.moveStep(step.id, offset: 1)
        } label: {
          Image(systemName: "arrow.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == model.recipe.steps.count - 1)
        .accessibilityLabel("Move step down")
        Button {
          model.removeStep(step.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove step")
      }
      Text(step.settingsSummary).font(.caption2).foregroundStyle(.secondary)
      stepSettings(step)
    }
    .padding(8)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func stepSettings(_ step: BatchRecipeStep) -> some View {
    switch step.kind {
    case .batesNumbering:
      batesSettings(step.id)
    case .ocr:
      ocrSettings(step.id)
    case .optimize:
      optimizeSettings(step.id)
    case .preflight:
      preflightSettings(step.id)
    case .exportText, .exportDOCX:
      Text(step.kind.declaredProfile)
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func binding(for id: UUID) -> Binding<BatchRecipeStep>? {
    guard model.recipe.steps.contains(where: { $0.id == id }) else { return nil }
    return Binding(
      get: { model.recipe.steps.first(where: { $0.id == id }) ?? BatchRecipeStep(kind: .optimize) },
      set: { newValue in
        if let index = model.recipe.steps.firstIndex(where: { $0.id == id }) {
          model.recipe.steps[index] = newValue
        }
      })
  }

  @ViewBuilder
  private func batesSettings(_ id: UUID) -> some View {
    if let binding = binding(for: id) {
      HStack(spacing: 8) {
        TextField(
          "Prefix", text: Binding(
            get: { binding.wrappedValue.bates?.prefix ?? "" },
            set: { value in
              var step = binding.wrappedValue
              step.bates?.prefix = value
              binding.wrappedValue = step
            }))
          .textFieldStyle(.roundedBorder)
          .frame(width: 110)
        TextField(
          "Start", value: Binding(
            get: { binding.wrappedValue.bates?.startNumber ?? 1 },
            set: { value in
              var step = binding.wrappedValue
              step.bates?.startNumber = value
              binding.wrappedValue = step
            }), format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 70)
        TextField(
          "Digits", value: Binding(
            get: { binding.wrappedValue.bates?.digits ?? 6 },
            set: { value in
              var step = binding.wrappedValue
              step.bates?.digits = value
              binding.wrappedValue = step
            }), format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 60)
        Toggle(
          "Continuous", isOn: Binding(
            get: { binding.wrappedValue.bates?.continuesAcrossFiles ?? true },
            set: { value in
              var step = binding.wrappedValue
              step.bates?.continuesAcrossFiles = value
              binding.wrappedValue = step
            }))
          .toggleStyle(.checkbox)
      }
      .font(.caption)
    }
  }

  @ViewBuilder
  private func ocrSettings(_ id: UUID) -> some View {
    if let binding = binding(for: id) {
      HStack(spacing: 8) {
        TextField(
          "Languages (comma separated)", text: Binding(
            get: { (binding.wrappedValue.ocr?.languages ?? ["en-US"]).joined(separator: ",") },
            set: { value in
              var step = binding.wrappedValue
              step.ocr?.languages =
                value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
              binding.wrappedValue = step
            }))
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 220)
        Toggle(
          "Replace generated layer", isOn: Binding(
            get: { binding.wrappedValue.ocr?.replacesExistingLayer ?? false },
            set: { value in
              var step = binding.wrappedValue
              step.ocr?.replacesExistingLayer = value
              binding.wrappedValue = step
            }))
          .toggleStyle(.checkbox)
        Text("Local Vision OCR; requires the app service performer.")
          .font(.caption2).foregroundStyle(.secondary)
      }
      .font(.caption)
    }
  }

  @ViewBuilder
  private func optimizeSettings(_ id: UUID) -> some View {
    if let binding = binding(for: id) {
      Toggle(
        "Remove metadata", isOn: Binding(
          get: { binding.wrappedValue.optimize?.removeMetadata ?? false },
          set: { value in
            var step = binding.wrappedValue
            step.optimize?.removeMetadata = value
            binding.wrappedValue = step
          }))
        .toggleStyle(.checkbox)
        .font(.caption)
    }
  }

  @ViewBuilder
  private func preflightSettings(_ id: UUID) -> some View {
    if let binding = binding(for: id) {
      Toggle(
        "Fail the file when preflight reports errors", isOn: Binding(
          get: { binding.wrappedValue.preflight?.failOnErrors ?? false },
          set: { value in
            var step = binding.wrappedValue
            step.preflight?.failOnErrors = value
            binding.wrappedValue = step
          }))
        .toggleStyle(.checkbox)
        .font(.caption)
    }
  }

  private var rightColumn: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        inputsSection
        previewSection
        reportSection
      }
      .padding(12)
    }
    .frame(minWidth: 360, maxWidth: 480, alignment: .leading)
  }

  private var inputsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Inputs (\(model.inputs.count))")
      if model.inputs.isEmpty {
        Text("Add PDF files to preview the plan.").font(.caption2).foregroundStyle(.secondary)
      }
      ForEach(model.inputs, id: \.self) { url in
        Text(url.lastPathComponent).font(.caption2).lineLimit(1)
      }
      if !model.recipe.steps.isEmpty {
        Text("Output: " + model.destinationPolicy().summary)
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var previewSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Plan Preview")
      if let preview = model.preview {
        Text(preview.summary).font(.caption)
        ForEach(Array(preview.files.indices), id: \.self) { index in
          let file = preview.files[index]
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(file.fileName).font(.caption.weight(.semibold))
              Spacer()
              Text(file.status == .ready ? "ready" : "refused")
                .font(.caption2)
                .foregroundStyle(file.status == .ready ? Color.secondary : Color.red)
            }
            if let pageCount = file.pageCount {
              Text("\(pageCount) page(s); → " + (file.outputURL?.lastPathComponent ?? "?"))
                .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(file.refusals, id: \.self) { refusal in
              Text(refusal).font(.caption2).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(file.stepSummaries, id: \.self) { summary in
              Text(summary).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
          }
          .padding(.vertical, 2)
        }
      } else {
        Text("Preview to see the ordered plan and resolved output names.")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var reportSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionTitle("Outcomes")
      if let report = model.report {
        Text(report.summary).font(.caption)
        ForEach(Array(report.files.indices), id: \.self) { index in
          let file = report.files[index]
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Text(file.fileName).font(.caption.weight(.semibold))
              Spacer()
              Text(file.status.displayName)
                .font(.caption2)
                .foregroundStyle(file.status.isSuccess ? Color.secondary : Color.orange)
            }
            if let output = file.outputPath {
              Text("→ " + URL(fileURLWithPath: output).lastPathComponent)
                .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(file.completedSteps, id: \.self) { step in
              Text(step).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            if let failure = file.failure {
              Text(failure).font(.caption2).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.vertical, 2)
        }
        if let checkpoint = model.checkpointURL {
          Text("Checkpoint: " + checkpoint.lastPathComponent)
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        Text("No run yet. A successful file means every step completed and its output was written atomically.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .semibold))
      .tracking(0.7)
      .foregroundStyle(.secondary)
  }
}

extension SPDFDocument {
  /// AUT-03/AUT-04: open the batch recipe panel. The panel is file-based, so it
  /// works independently of the open document.
  func showBatchRecipesPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? BatchRecipesPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = BatchRecipesPanelController()
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowBatchRecipesPanel: Bool { true }
}
