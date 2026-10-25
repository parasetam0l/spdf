import AppKit
import MacServices
import PDFCore
import PDFEditing

/// OCR-03: document routes for the suspect-word review panel.
///
/// Review metadata is persisted inside each page, so the queue survives save
/// and reopen. Corrections are staged in memory and applied as one undoable
/// transaction; the scan image and original content are never rewritten.
private enum OCRReviewAssociationKeys {
  /// Associated-object address only; the value is never read.
  nonisolated(unsafe) static var model: UInt8 = 0
}

extension SPDFDocument {
  /// The per-document OCR review model.
  var ocrReviewModel: OCRReviewModel {
    if let existing = objc_getAssociatedObject(
      self, &OCRReviewAssociationKeys.model) as? OCRReviewModel
    {
      return existing
    }
    let host = OCRReviewHost(
      pageIDs: { [weak self] in self?.editSession.pageIDs ?? [] },
      graph: { [weak self] in self?.editSession.currentGraph },
      apply: { [weak self] commands in
        self?.applyOCRReviewCommands(commands) ?? false
      },
      refresh: { [weak self] page in
        self?.refreshViewerAfterOCRReview(preservingPage: page)
      },
      goToPage: { [weak self] page in self?.viewer?.go(to: page) },
      pageCount: { [weak self] in self?.editSession.pageIDs.count ?? 0 })
    let model = OCRReviewModel(host: host)
    objc_setAssociatedObject(
      self, &OCRReviewAssociationKeys.model, model,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return model
  }

  var canShowOCRReviewPanel: Bool {
    viewer != nil && !editSession.pageIDs.isEmpty
  }

  /// Menu hook (Tools > OCR > Review OCR Text...): review the persisted queue
  /// for the document's generated OCR layers.
  func showOCRReview() {
    let model = ocrReviewModel
    model.reloadFromDocument()
    presentOCRReviewPanel(model: model)
  }

  /// Recognition hook: call after the OCR layers were committed so the
  /// confidence/provenance of the fresh results becomes the review queue.
  func presentOCRReview(
    after results: [OCRPageResult], level: OCRRecognitionLevel
  ) {
    let model = ocrReviewModel
    model.begin(results: results, level: level, threshold: 0.6)
    presentOCRReviewPanel(model: model)
  }

  private func presentOCRReviewPanel(model: OCRReviewModel) {
    if let controller = windowControllers.compactMap({
      $0 as? OCRReviewPanelController
    }).first {
      controller.refreshOverlay()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = OCRReviewPanelController(model: model, viewer: viewer)
    addWindowController(controller)
    model.overlayChanged = { [weak controller] in controller?.refreshOverlay() }
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  // MARK: - Applying corrections

  /// One document transaction for every staged correction, with one Undo step.
  @discardableResult
  func applyOCRReviewCommands(_ commands: [ApplyOCRCorrectionsCommand]) -> Bool {
    guard !commands.isEmpty else { return false }
    guard requireContentEditing(for: "Correct OCR Text") else { return false }
    guard finishPendingEdits() else { return false }
    guard let graph = editSession.currentGraph else { return false }
    for command in commands {
      do {
        try command.validate(in: graph)
      } catch {
        presentError(error)
        return false
      }
    }
    let revision = editSession.documentRevision
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return false
    }
    registerOCRReviewUndo(registeredRevision: revision)
    return true
  }

  /// Refresh the display after a correction commit, keeping the reviewer page.
  func refreshViewerAfterOCRReview(preservingPage page: Int) {
    defer { refreshOCRReviewDocumentState() }
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data)
    else { return }
    let tool = viewer?.activeTool ?? .select
    try? viewer?.open(source)
    _ = viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
    ocrReviewModel.reloadFromDocument()
  }

  func refreshOCRReviewDocumentState() {
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
  }

  // MARK: - Undo integration

  func registerOCRReviewUndo(registeredRevision: UInt64?) {
    defer { refreshOCRReviewDocumentState() }
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performOCRReviewUndo(registeredRevision: registeredRevision)
    }
    undoManager.setActionName("Correct OCR Text")
    undoManager.endUndoGrouping()
  }

  func performOCRReviewUndo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performOCRReviewRedo(registeredRevision: revision)
    }
    undoManager?.setActionName("Correct OCR Text")
    refreshViewerAfterOCRReview(preservingPage: viewer?.pageNumber ?? 0)
  }

  func performOCRReviewRedo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performOCRReviewUndo(registeredRevision: revision)
    }
    undoManager?.setActionName("Correct OCR Text")
    refreshViewerAfterOCRReview(preservingPage: viewer?.pageNumber ?? 0)
  }
}
