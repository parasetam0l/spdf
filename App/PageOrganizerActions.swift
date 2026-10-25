import AppKit
import PDFCore
import PDFEditing
import UniformTypeIdentifiers

// MARK: - PAG-01 organizer document routes

extension SPDFDocument {
  var canOrganizePages: Bool {
    editSession.currentGraph != nil && !editSession.pageIDs.isEmpty
  }

  /// Page -> Organize Pages...: the thumbnail organizer (thumbnail grid, drag/
  /// reorder, range and multi-selection, zoom, labels, batch actions).
  func presentPageOrganizer() {
    if let controller = windowControllers.compactMap({
      $0 as? PageOrganizerCanvasController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = PageOrganizerCanvasController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  /// Apply one organizer action as a single transaction/undo step.
  @discardableResult
  func applyPageOrganizerTransaction(
    _ transaction: PDFTransaction, actionName: String
  ) -> Bool {
    guard requireContentEditing(for: actionName) else { return false }
    guard editSession.currentGraph != nil else { return false }
    do {
      try editSession.apply(transaction)
    } catch {
      presentError(error)
      return false
    }
    registerPageOrganizerUndo(actionName: actionName)
    refreshViewerAfterPageOrganizerEdit(preservingPage: viewer?.pageNumber ?? 0)
    return true
  }

  /// Extract the selected pages to one verified local PDF file.
  func exportSelectedPagesAsPDF(pageIDs: [PDFObjectID], destination: URL) throws {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.unsupported, "This document is not editable by the owned core")
    }
    let extracted = try DocumentAssembly.extract(
      graph, pageIDs: pageIDs, labels: .preserve,
      catalogData: .firstDocument, limits: SPDFDocumentResourcePolicy.parsingLimits)
    let data = try PDFWriter.write(extracted.graph, limits: SPDFDocumentResourcePolicy.parsingLimits)
    try data.write(to: destination, options: .atomic)
  }

  // MARK: Undo integration for page actions

  func registerPageOrganizerUndo(actionName: String) {
    defer { refreshPageOrganizerDocumentState() }
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    let revision = editSession.documentRevision
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performPageOrganizerUndo(registeredRevision: revision, actionName: actionName)
    }
    undoManager.setActionName(actionName)
    undoManager.endUndoGrouping()
  }

  func performPageOrganizerUndo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performPageOrganizerRedo(registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    refreshViewerAfterPageOrganizerEdit(preservingPage: viewer?.pageNumber ?? 0)
    pageOrganizerController?.refresh()
  }

  func performPageOrganizerRedo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performPageOrganizerUndo(registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    refreshViewerAfterPageOrganizerEdit(preservingPage: viewer?.pageNumber ?? 0)
    pageOrganizerController?.refresh()
  }

  var pageOrganizerController: PageOrganizerCanvasController? {
    windowControllers.compactMap { $0 as? PageOrganizerCanvasController }.first
  }

  func refreshViewerAfterPageOrganizerEdit(preservingPage page: Int) {
    defer { refreshPageOrganizerDocumentState() }
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data)
    else { return }
    let tool = viewer?.activeTool ?? .select
    try? viewer?.open(source)
    _ = viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
    refreshComments()
    refreshForms()
    refreshFonts()
    refreshDocumentInfo()
    refreshStructure()
  }

  func refreshPageOrganizerDocumentState() {
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
  }

  /// Save-panel extraction used by the organizer batch action.
  func presentExtractSelectedPages(pageIDs: [PDFObjectID]) {
    guard !pageIDs.isEmpty else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue =
      (fileURL?.deletingPathExtension().lastPathComponent ?? "document")
      + "-extract.pdf"
    panel.begin { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      do {
        try self.exportSelectedPagesAsPDF(pageIDs: pageIDs, destination: url)
        let alert = NSAlert()
        alert.messageText = "Pages Extracted"
        alert.informativeText =
          "\(pageIDs.count) page\(pageIDs.count == 1 ? "" : "s") written to "
          + url.lastPathComponent + "."
        alert.addButton(withTitle: "OK")
        alert.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }
}
