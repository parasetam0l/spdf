import AppKit
import MacServices
import PDFCore
import PDFEditing
import PDFKit

/// OCR-05: document-facing services for editable scanned text.
@MainActor
struct ScannedTextHost {
  var currentPageIndex: @MainActor () -> Int
  var pageIDs: @MainActor () -> [PDFObjectID]
  var graph: @MainActor () -> PDFGraph?
  var apply: @MainActor (PDFTransaction, String) -> Bool
  var refresh: @MainActor (Int) -> Void
}

/// OCR-05: reconstruction panel model. Preview is read-only; Apply commits the
/// single atomic command (pixel erase + layer rebuild + visible text).
@MainActor
final class ScannedTextModel: ObservableObject {
  @Published var pageIndex = 0
  @Published var pageCount = 0
  @Published var words: [ScannedWord] = []
  @Published var selectedWord: ScannedWord?
  @Published var replacement = ""
  @Published var preview: ScannedTextPreview?
  @Published var message: String?
  @Published var isApplying = false

  let host: ScannedTextHost
  var requestClose: (() -> Void)?

  init(host: ScannedTextHost) {
    self.host = host
  }

  var canPreview: Bool {
    selectedWord != nil && !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var canApply: Bool { preview?.isSupported == true && !isApplying }
  var pageLabel: String { "Page \(pageIndex + 1) of \(max(1, pageCount))" }

  func reload() {
    let pageIDs = host.pageIDs()
    pageCount = pageIDs.count
    pageIndex = min(max(0, host.currentPageIndex()), max(0, pageIDs.count - 1))
    message = nil
    preview = nil
    guard pageIDs.indices.contains(pageIndex), let graph = host.graph() else {
      words = []
      selectedWord = nil
      message = "No document is open"
      return
    }
    do {
      words = try ScannedTextReconstructionService.words(
        pageIndex: pageIndex, pageID: pageIDs[pageIndex], in: graph)
    } catch let refusal as ScannedTextRefusal {
      words = []
      selectedWord = nil
      message = refusal.message
      return
    } catch {
      words = []
      selectedWord = nil
      message = error.localizedDescription
      return
    }
    if let first = words.first {
      select(first)
    } else {
      selectedWord = nil
      replacement = ""
      message = "No editable recognized words on this page"
    }
    if words.isEmpty, message == nil {
      message = "Run OCR for this page to create editable scanned text"
    }
  }

  func select(_ word: ScannedWord) {
    selectedWord = word
    replacement = word.text
    preview = nil
  }

  func updatePreview() {
    guard let word = selectedWord, let graph = host.graph(),
      let pageID = pageID()
    else { return }
    let plan = ScannedTextReconstructionService.plan(
      pageIndex: pageIndex, pageID: pageID, word: word,
      replacement: replacement, in: graph)
    preview = plan.preview
    if let refusal = plan.preview.refusal {
      message = refusal.message
    } else {
      message = "Preview ready"
    }
  }

  func apply() {
    guard let word = selectedWord, let graph = host.graph(), let pageID = pageID()
    else { return }
    let plan = ScannedTextReconstructionService.plan(
      pageIndex: pageIndex, pageID: pageID, word: word,
      replacement: replacement, in: graph)
    preview = plan.preview
    guard let transaction = plan.transaction else {
      message = plan.preview.refusal?.message ?? "Reconstruction is not available"
      return
    }
    isApplying = true
    defer { isApplying = false }
    guard host.apply(transaction, "Reconstruct Scanned Text") else {
      message = "The reconstruction transaction was refused"
      return
    }
    message = "Reconstructed \"\(word.text)\" as \"\(replacement)\""
    reload()
    host.refresh(max(0, pageIndex))
  }

  private func pageID() -> PDFObjectID? {
    let pageIDs = host.pageIDs()
    return pageIDs.indices.contains(pageIndex) ? pageIDs[pageIndex] : nil
  }
}

extension SPDFDocument {
  /// OCR-05 menu hook: Tools > OCR > Reconstruct Scanned Text...
  var scannedTextReconstructionModel: ScannedTextModel {
    if let existing = objc_getAssociatedObject(
      self, &ScanCleanupAssociationKeys.textModel) as? ScannedTextModel
    {
      return existing
    }
    let host = ScannedTextHost(
      currentPageIndex: { [weak self] in
        max(0, (self?.viewer?.pageNumber ?? 1) - 1)
      },
      pageIDs: { [weak self] in self?.editSession.pageIDs ?? [] },
      graph: { [weak self] in self?.editSession.currentGraph },
      apply: { [weak self] transaction, name in
        self?.applyScanCleanupTransaction(transaction, actionName: name) ?? false
      },
      refresh: { [weak self] page in
        self?.refreshViewerAfterScanCleanup(preservingPage: page)
      })
    let model = ScannedTextModel(host: host)
    objc_setAssociatedObject(
      self, &ScanCleanupAssociationKeys.textModel, model,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return model
  }

  var canShowScannedTextPanel: Bool {
    viewer != nil && !editSession.pageIDs.isEmpty
  }

  /// Menu hook (Tools > OCR > Reconstruct Scanned Text...).
  func showScannedTextReconstruction() {
    let model = scannedTextReconstructionModel
    model.reload()
    presentScannedTextPanel(model: model)
  }

  private func presentScannedTextPanel(model: ScannedTextModel) {
    if let controller = windowControllers.compactMap({
      $0 as? ScannedTextPanelController
    }).first {
      controller.refreshPresentation()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ScannedTextPanelController(model: model)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
