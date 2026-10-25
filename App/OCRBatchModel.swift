import AppKit
import Combine
import Foundation
import MacServices

/// OCR-07: relays background batch progress to the main-confined model without
/// capturing a non-Sendable model inside a @Sendable closure.
private final class OCRBatchProgressRelay: @unchecked Sendable {
  private let lock = NSLock()
  private weak var model: OCRBatchModel?

  init(model: OCRBatchModel) {
    self.model = model
  }

  func update(_ progress: OCRBatchProgress) {
    lock.lock()
    let model = self.model
    lock.unlock()
    guard let model else { return }
    if Thread.isMainThread {
      MainActor.assumeIsolated { model.apply(progress: progress) }
    } else {
      DispatchQueue.main.async { model.apply(progress: progress) }
    }
  }
}

/// OCR-07: the multi-file OCR queue model: file list, output naming, progress,
/// cancellation, resume and per-file failure reporting.
@MainActor
final class OCRBatchModel: ObservableObject {
  struct Item: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var status: OCRBatchItemStatus
    var detail: String?

    init(url: URL) {
      id = UUID()
      self.url = url
      status = .pending
      detail = nil
    }
  }

  @Published var items: [Item] = []
  @Published var outputDirectory: URL = FileManager.default.urls(
    for: .downloadsDirectory, in: .userDomainMask).first
    ?? FileManager.default.homeDirectoryForCurrentUser
  @Published var nameTemplate = OCRBatchSettings.defaultNameTemplate
  @Published var languages: [String] = []
  @Published var selectedLanguage = ""
  @Published var level: OCRRecognitionLevel = .accurate
  @Published var minimumConfidence = 0.6
  @Published var overwriteExisting = false
  @Published private(set) var isRunning = false
  @Published private(set) var progressText = ""
  @Published private(set) var message: String?
  @Published private(set) var failureSummary = ""
  @Published private(set) var reportPath = ""

  private var task: Task<Void, Never>?
  /// Set by the panel controller so Close can end the sheet/window.
  var requestClose: (() -> Void)?

  /// Test/smoke hook: initial output folder. Nil means the user's Downloads
  /// folder; the native/workspace smoke redirects it into an ignored Work dir.
  nonisolated(unsafe) static var outputDirectoryOverride: URL?

  init() {
    if let override = Self.outputDirectoryOverride {
      outputDirectory = override
    }
    languages = (try? VisionTextRecognizer.supportedLanguages()) ?? []
    selectedLanguage = languages.first ?? ""
  }

  var canRun: Bool { !items.isEmpty && !isRunning }
  var canCancel: Bool { isRunning }
  var successCount: Int {
    items.filter { $0.status == .completed || $0.status == .resumed }.count
  }
  var failedCount: Int { items.filter { $0.status == .failed }.count }

  func addFiles() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.pdf]
    panel.message = "Choose PDF files to recognize with the multi-file OCR queue."
    guard panel.runModal() == .OK else { return }
    let existing = Set(items.map { $0.url.standardizedFileURL })
    for url in panel.urls where !existing.contains(url.standardizedFileURL) {
      items.append(Item(url: url.standardizedFileURL))
    }
    message = nil
  }

  func remove(_ item: Item) {
    guard !isRunning else { return }
    items.removeAll { $0.id == item.id }
  }

  func chooseOutputDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Use Folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    outputDirectory = url.standardizedFileURL
  }

  func run() {
    guard canRun else { return }
    let settings = OCRBatchSettings(
      outputDirectory: outputDirectory, nameTemplate: nameTemplate,
      languages: selectedLanguage.isEmpty ? [] : [selectedLanguage],
      level: level, minimumConfidence: minimumConfidence,
      overwriteExisting: overwriteExisting)
    do {
      _ = try settings.validated(
        supportedLanguages: languages.isEmpty ? [selectedLanguage] : languages)
    } catch {
      message = error.localizedDescription
      return
    }
    let inputs = items.map(\.url)
    for index in items.indices {
      items[index].status = .pending
      items[index].detail = nil
    }
    isRunning = true
    message = "Starting OCR queue…"
    progressText = "Waiting for the first file…"
    failureSummary = ""
    reportPath = ""
    let relay = OCRBatchProgressRelay(model: self)
    task = Task { @MainActor [weak self] in
      do {
        let run = try await OCRBatchQueue.run(
          inputs: inputs, settings: settings,
          recognizer: VisionTextRecognizer(),
          onProgress: { progress in relay.update(progress) })
        guard let self else { return }
        self.finish(run: run)
      } catch {
        guard let self else { return }
        self.isRunning = false
        self.message = error.localizedDescription
        self.progressText = ""
      }
    }
  }

  func cancel() {
    task?.cancel()
    message = "Cancelling after the current page…"
  }

  func close() {
    task?.cancel()
    requestClose?()
  }

  // MARK: - Queue updates

  func apply(progress: OCRBatchProgress) {
    switch progress.stage {
    case .reading:
      progressText =
        "Reading \(progress.fileName) (\(progress.itemIndex + 1) of \(progress.itemCount))…"
      if let index = items.firstIndex(where: {
        $0.url.lastPathComponent == progress.fileName
      }), items[index].status == .pending {
        items[index].status = .cancelled  // running marker until a final status
        items[index].detail = "Reading…"
      }
    case .recognizing:
      progressText =
        "Recognizing \(progress.fileName): page \(progress.completedPages) of \(progress.totalPages)"
      if let index = items.firstIndex(where: {
        $0.url.lastPathComponent == progress.fileName
      }) {
        items[index].detail =
          "page \(progress.completedPages)/\(progress.totalPages)"
      }
    case .writing:
      progressText = "Writing \(progress.fileName)…"
    case .finished:
      progressText = "Finished \(progress.fileName)"
    }
  }

  private func finish(run: OCRBatchRun) {
    isRunning = false
    for item in run.items {
      guard let index = items.firstIndex(where: {
        $0.url.standardizedFileURL == item.inputURL.standardizedFileURL
      }) else { continue }
      items[index].status = item.status
      switch item.status {
      case .completed:
        items[index].detail =
          "\(item.pagesRecognized) page\(item.pagesRecognized == 1 ? "" : "s")"
      case .resumed:
        items[index].detail = "Already complete (resumed)"
      case .failed:
        items[index].detail = item.failure
      case .cancelled:
        items[index].detail = "Not processed"
      case .pending:
        items[index].detail = nil
      }
    }
    failureSummary = run.failureSummary
    reportPath = run.reportURL?.path ?? ""
    progressText =
      run.cancelled
      ? "Cancelled — \(run.completedCount) completed output(s) kept."
      : "Done — \(run.completedCount) completed, \(run.failedCount) failed."
    message = run.cancelled
      ? "The queue was cancelled. Completed files were kept; run again to resume the rest."
      : (run.failedCount == 0
        ? "Every file was recognized and written with a verified searchable layer."
        : "Some files failed. Completed outputs were not changed; see the failure report.")
    task = nil
  }
}
