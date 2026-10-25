import AppKit
import MacServices
import PDFCore
import PDFEditing
import PDFKit

/// OCR-04: document-facing services for the scan cleanup panel. The document
/// extension supplies closures so the model stays testable and independent of
/// SPDFDocument.
@MainActor
struct ScanCleanupHost {
  var graph: @MainActor () -> PDFGraph?
  var pageIDs: @MainActor () -> [PDFObjectID]
  var apply: @MainActor (PDFTransaction, String) -> Bool
  var refresh: @MainActor (Int) -> Void
}

/// OCR-04: the cleanup panel model. Previews are read-only; nothing is written
/// until Apply commits one transaction for the selected supported pages.
@MainActor
final class ScanCleanupModel: ObservableObject {
  struct PageItem: Identifiable {
    let id: Int
    let pageID: PDFObjectID
    var isSelected: Bool
    var preview: ScanCleanupPagePreview?
  }

  @Published var items: [PageItem] = []
  @Published var options = ScanCleanupOptions()
  @Published var message: String?
  @Published var isApplying = false

  let host: ScanCleanupHost
  var requestClose: (() -> Void)?

  init(host: ScanCleanupHost) {
    self.host = host
  }

  var selectedCount: Int { items.filter(\.isSelected).count }
  var supportedSelectedCount: Int {
    items.filter { $0.isSelected && ($0.preview?.isSupported ?? false) }.count
  }
  var canApply: Bool { supportedSelectedCount > 0 && !isApplying }
  var hasGraph: Bool { host.graph() != nil }

  func reload() {
    guard let graph = host.graph() else {
      items = []
      message = "No document is open"
      return
    }
    let pageIDs = host.pageIDs()
    var newItems: [PageItem] = []
    for (index, pageID) in pageIDs.enumerated() {
      let preview = ScanCleanupService.preview(
        pageIndex: index, pageID: pageID, in: graph, options: options,
        orientationDetector: ScanCleanupOrientationDetector.vision)
      newItems.append(
        PageItem(
          id: index, pageID: pageID,
          isSelected: preview.isSupported, preview: preview))
    }
    items = newItems
    let supported = items.filter { $0.preview?.isSupported ?? false }.count
    message = supported == 0
      ? "No page has a scan image this cleanup profile can process"
      : "\(supported) page(s) can be cleaned up"
  }

  func refreshPreviewsKeepingSelection() {
    let selected = Set(items.filter(\.isSelected).map(\.id))
    reload()
    for index in items.indices {
      items[index].isSelected = selected.contains(items[index].id)
        && (items[index].preview?.isSupported ?? false)
    }
  }

  func toggleSelection(pageIndex: Int, selected: Bool) {
    guard let index = items.firstIndex(where: { $0.id == pageIndex }) else { return }
    items[index].isSelected = selected
  }

  func selectAllSupported() {
    for index in items.indices {
      items[index].isSelected = items[index].preview?.isSupported ?? false
    }
  }

  func deselectAll() {
    for index in items.indices { items[index].isSelected = false }
  }

  func apply() {
    guard let graph = host.graph() else { return }
    let selected = items.filter(\.isSelected).map(\.id)
    guard !selected.isEmpty else {
      message = "Select at least one page to clean up"
      return
    }
    let plan = ScanCleanupService.plan(
      pageIndices: selected, in: graph, options: options,
      orientationDetector: ScanCleanupOrientationDetector.vision)
    guard let transaction = plan.transaction else {
      let reasons = plan.refusals.map { "p\($0.pageIndex + 1): \($0.refusal.message)" }
      message = reasons.isEmpty
        ? "No selected page can be cleaned up"
        : reasons.joined(separator: " ")
      return
    }
    isApplying = true
    defer { isApplying = false }
    let supported = plan.reports.map(\.pageIndex)
    guard host.apply(transaction, "Clean Up Scan") else {
      message = "The cleanup transaction was refused"
      return
    }
    let cleaned = supported.map { "p\($0 + 1)" }.joined(separator: ", ")
    let invalidated = plan.reports.filter(\.searchableTextInvalidated).count
    message = invalidated > 0
      ? "Cleaned \(cleaned). Searchable text changed position; run OCR again for those pages."
      : "Cleaned \(cleaned)"
    reload()
    if let first = supported.first { host.refresh(first) }
  }
}

enum ScanCleanupAssociationKeys {
  /// Associated-object address only; the value is never read.
  nonisolated(unsafe) static var model: UInt8 = 0
  nonisolated(unsafe) static var textModel: UInt8 = 0
}

extension SPDFDocument {
  /// OCR-04 menu hook: Tools > OCR > Clean Up Scan...
  var scanCleanupModel: ScanCleanupModel {
    if let existing = objc_getAssociatedObject(
      self, &ScanCleanupAssociationKeys.model) as? ScanCleanupModel
    {
      return existing
    }
    let host = ScanCleanupHost(
      graph: { [weak self] in self?.editSession.currentGraph },
      pageIDs: { [weak self] in self?.editSession.pageIDs ?? [] },
      apply: { [weak self] transaction, name in
        self?.applyScanCleanupTransaction(transaction, actionName: name) ?? false
      },
      refresh: { [weak self] page in
        self?.refreshViewerAfterScanCleanup(preservingPage: page)
      })
    let model = ScanCleanupModel(host: host)
    objc_setAssociatedObject(
      self, &ScanCleanupAssociationKeys.model, model,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return model
  }

  var canShowScanCleanupPanel: Bool {
    viewer != nil && !editSession.pageIDs.isEmpty
  }

  /// Menu hook (Tools > OCR > Clean Up Scan...).
  func showScanCleanup() {
    let model = scanCleanupModel
    model.reload()
    presentScanCleanupPanel(model: model)
  }

  private func presentScanCleanupPanel(model: ScanCleanupModel) {
    if let controller = windowControllers.compactMap({
      $0 as? ScanCleanupPanelController
    }).first {
      controller.refreshPresentation()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ScanCleanupPanelController(model: model)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  /// One transaction for every selected page, one Undo step.
  @discardableResult
  func applyScanCleanupTransaction(
    _ transaction: PDFTransaction, actionName: String
  ) -> Bool {
    guard requireContentEditing(for: actionName) else { return false }
    guard finishPendingEdits() else { return false }
    let revision = editSession.documentRevision
    do {
      try editSession.apply(transaction)
    } catch {
      presentError(error)
      return false
    }
    registerScanUndo(registeredRevision: revision, actionName: actionName)
    return true
  }

  func refreshViewerAfterScanCleanup(preservingPage page: Int) {
    defer { refreshScanCleanupDocumentState() }
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data)
    else { return }
    let tool = viewer?.activeTool ?? .select
    try? viewer?.open(source)
    _ = viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
    if let existing = objc_getAssociatedObject(
      self, &ScanCleanupAssociationKeys.model) as? ScanCleanupModel
    {
      existing.reload()
    }
  }

  func refreshScanCleanupDocumentState() {
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
  }

  func registerScanUndo(registeredRevision: UInt64?, actionName: String) {
    defer { refreshScanCleanupDocumentState() }
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performScanUndo(
        registeredRevision: registeredRevision, actionName: actionName)
    }
    undoManager.setActionName(actionName)
    undoManager.endUndoGrouping()
  }

  func performScanUndo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performScanRedo(
        registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    refreshViewerAfterScanCleanup(preservingPage: viewer?.pageNumber ?? 0)
  }

  func performScanRedo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performScanUndo(
        registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    refreshViewerAfterScanCleanup(preservingPage: viewer?.pageNumber ?? 0)
  }
}
