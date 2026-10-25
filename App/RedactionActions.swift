import AppKit
import PDFCore
import PDFEditing
import PDFKit

/// RED-01/RED-02: pending redaction review state for one open document.
///
/// Marks live here, not in the PDF: staging, reviewing and removing them never
/// touches the edit session or the saved bytes. Only an explicit Apply turns
/// them into one undoable transaction.
@MainActor
final class RedactionMarksSession: NSObject {
  var store = RedactionMarkStore()
  var termSets = RedactionTermSetLibrary()
  var options = RedactionApplicationOptions()
  var reviewQueue: RedactionReviewQueue?
  var lastSearchRequest: RedactionSearchRequest?
  var lastAppliedMarkIDs: Set<UUID> = []
  weak var document: SPDFDocument?
  weak var panelController: RedactionMarksPanelController?

  var pendingCount: Int { store.pendingCount }
  var hasPendingMarks: Bool { store.hasUnappliedMarks }
}

private enum RedactionAssociationKeys {
  /// Address used only as an associated-object key; the value is never read.
  nonisolated(unsafe) static var session: UInt8 = 0
}

// MARK: - Document routes for the redaction marks panel

extension SPDFDocument {
  /// The per-document staged mark store and its review state.
  var redactionMarksSession: RedactionMarksSession {
    if let existing = objc_getAssociatedObject(
      self, &RedactionAssociationKeys.session) as? RedactionMarksSession
    {
      return existing
    }
    let session = RedactionMarksSession()
    session.document = self
    objc_setAssociatedObject(
      self, &RedactionAssociationKeys.session, session,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return session
  }

  // MARK: Presentation

  /// Tools → Security → Redaction Marks…: review pending marks, search for
  /// text, and apply. The panel never applies anything by itself.
  func showRedactionMarks() {
    let session = redactionMarksSession
    if let controller = windowControllers.compactMap({
      $0 as? RedactionMarksPanelController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = RedactionMarksPanelController(document: self, session: session)
    addWindowController(controller)
    session.panelController = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  /// Optional Edit route: open the panel with the selected text as the search
  /// query so Search and Redact starts from the reviewer's selection.
  func showRedactionSearch() {
    showRedactionMarks()
    guard let controller = windowControllers.compactMap({
      $0 as? RedactionMarksPanelController
    }).first else { return }
    controller.prefillSearch(viewer?.view.currentSelection?.string ?? "")
  }

  // MARK: Staging marks

  /// Stage the current text selection as pending text marks. Nothing is
  /// removed; the panel shows the marks as pending until Apply.
  @discardableResult
  func markSelectionForRedaction() -> Bool {
    guard requireContentEditing(for: "Mark for Redaction") else { return false }
    guard let viewer, let selection = viewer.view.currentSelection,
      let document = viewer.view.document
    else { return false }
    let session = redactionMarksSession
    let selectedText = selection.string ?? ""
    var added = 0
    for page in selection.pages {
      let index = document.index(for: page)
      guard index >= 0, index < editSession.pageIDs.count else { continue }
      var rects = lineSelectionRects(selection, page: page)
      if rects.isEmpty {
        let bounds = selection.bounds(for: page)
        guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
        rects = [[bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]]
      }
      do {
        _ = try session.store.add(
          kind: .text, pageID: editSession.pageIDs[index], pageIndex: index,
          rects: rects,
          matchedText: selectedText.count > 200
            ? String(selectedText.prefix(197)) + "…" : selectedText,
          sources: ["Selection"])
        added += 1
      } catch {
        presentError(error)
        break
      }
    }
    guard added > 0 else {
      NSSound.beep()
      return false
    }
    showRedactionMarks()
    redactionMarksSession.panelController?.refresh()
    redactionMarksSession.panelController?.note(
      "Staged " + String(added) + " selection mark(s) as pending — nothing has been removed yet.")
    return true
  }

  /// Stage the page currently shown as a whole-page pending mark.
  @discardableResult
  func markCurrentPageForRedaction() -> Bool {
    guard requireContentEditing(for: "Mark for Redaction") else { return false }
    guard let viewer, viewer.pageNumber >= 1,
      viewer.pageNumber <= editSession.pageIDs.count
    else { return false }
    let index = viewer.pageNumber - 1
    let pageID = editSession.pageIDs[index]
    guard let box = redactionPageBox(pageID: pageID, pageIndex: index) else {
      NSSound.beep()
      return false
    }
    let session = redactionMarksSession
    do {
      _ = try session.store.add(
        kind: .page, pageID: pageID, pageIndex: index, rects: [box],
        matchedText: nil, sources: ["Whole page " + String(index + 1)])
    } catch {
      presentError(error)
      return false
    }
    showRedactionMarks()
    session.panelController?.refresh()
    session.panelController?.note(
      "Staged a whole-page mark as pending — nothing has been removed yet.")
    return true
  }

  /// Stage one user-drawn rectangle as a pending region mark.
  @discardableResult
  func markRedactionRegion(pageIndex: Int, rect: [Double]) -> Bool {
    guard requireContentEditing(for: "Mark for Redaction") else { return false }
    guard pageIndex >= 0, pageIndex < editSession.pageIDs.count else {
      NSSound.beep()
      return false
    }
    let session = redactionMarksSession
    do {
      _ = try session.store.add(
        kind: .region, pageID: editSession.pageIDs[pageIndex], pageIndex: pageIndex,
        rects: [rect], sources: ["Rectangle region"])
    } catch {
      presentError(error)
      return false
    }
    showRedactionMarks()
    session.panelController?.refresh()
    session.panelController?.note(
      "Staged a rectangle mark as pending — nothing has been removed yet.")
    return true
  }

  // MARK: Review services used by the panel

  func redactionGraph() -> PDFGraph? { editSession.currentGraph }
  func redactionPageIDs() -> [PDFObjectID] { editSession.pageIDs }
  func redactionPageIndex(of pageID: PDFObjectID) -> Int? {
    editSession.pageIDs.firstIndex(of: pageID)
  }

  func redactionPageBox(pageID: PDFObjectID, pageIndex: Int) -> [Double]? {
    if let direct = editSession.pageMediaBox(at: pageIndex), direct.count == 4 {
      return direct.map(Double.init)
    }
    guard let graph = editSession.currentGraph,
      case .dictionary(let page)? = graph.objects[pageID]
    else { return nil }
    var current = page
    for _ in 0..<64 {
      if case .array(let values)? = current[PDFName("MediaBox")] {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let raw): return Double(raw)
          case .real(let raw): return raw
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
      guard case .reference(let parentID)? = current[PDFName("Parent")],
        case .dictionary(let parent)? = graph.objects[parentID]
      else { break }
      current = parent
    }
    return nil
  }

  func redactionPlan(options: RedactionApplicationOptions) -> RedactionMarkPlan? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? RedactionMarkPlanner.plan(
      store: redactionMarksSession.store, graph: graph,
      pageIDs: editSession.pageIDs, options: options,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
  }

  func redactionSearchPreview(
    _ request: RedactionSearchRequest
  ) throws -> RedactionSearchPreview {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.unsupported, "This document is not editable by the owned core")
    }
    return try RedactionSearch.preview(
      request, in: graph, limits: SPDFDocumentResourcePolicy.parsingLimits)
  }

  /// Bounds of the current selection on the page it belongs to, restricted to
  /// the page shown in the viewer (the supported selection scope).
  func redactionSelectionRects() -> [[Double]]? {
    guard let viewer, let selection = viewer.view.currentSelection,
      let document = viewer.view.document,
      let page = selection.pages.first,
      viewer.pageNumber >= 1
    else { return nil }
    let index = document.index(for: page)
    guard index >= 0, index == viewer.pageNumber - 1 else { return nil }
    var rects = lineSelectionRects(selection, page: page)
    if rects.isEmpty {
      let bounds = selection.bounds(for: page)
      guard bounds.width > 0.5, bounds.height > 0.5 else { return nil }
      rects = [[bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]]
    }
    return rects.isEmpty ? nil : rects
  }

  // MARK: Applying pending marks

  /// Apply every pending mark as ONE transaction: one session commit, one
  /// undoable step, and a forced full rewrite on the next save.
  @discardableResult
  func applyPendingRedactionMarks() -> Bool {
    let session = redactionMarksSession
    guard session.hasPendingMarks else {
      NSSound.beep()
      return false
    }
    guard requireContentEditing(for: "Apply Redactions") else { return false }
    guard finishPendingEdits() else { return false }
    guard let graph = editSession.currentGraph else { return false }
    let command = RedactMarksCommand(store: session.store, options: session.options)
    do {
      try command.validate(in: graph)
    } catch {
      presentError(error)
      session.panelController?.refresh()
      return false
    }
    let appliedIDs = Set(session.store.pendingMarks.map(\.id))
    do {
      try editSession.apply(PDFTransaction([command]))
    } catch {
      presentError(error)
      return false
    }
    session.store.noteApplied(appliedIDs)
    session.lastAppliedMarkIDs = appliedIDs
    registerRedactionUndo(markIDs: appliedIDs)
    // SAF-02: pre-redaction recovery snapshots still contain the removed
    // content. Replace them with a secure snapshot of the current state before
    // the next autosave interval, then refresh the display.
    discardRecoveryRecords()
    snapshotRecoveryNow()
    refreshViewerAfterRedaction(preservingPage: viewer?.pageNumber ?? 0)
    session.panelController?.refresh()
    session.panelController?.note(
      "Applied " + String(appliedIDs.count)
        + " redaction mark(s). Saving writes a verified full rewrite; Undo is available until then.")
    return true
  }

  // MARK: Validation and save-barrier hooks

  var canShowRedactionMarksPanel: Bool { true }
  var canMarkSelectionForRedaction: Bool { canRedactSelection }
  var canMarkCurrentPageForRedaction: Bool {
    canEditContent && (viewer?.pageNumber ?? 0) >= 1
  }
  var canApplyRedactionMarks: Bool {
    canEditContent && redactionMarksSession.hasPendingMarks
  }
  var pendingRedactionMarkCount: Int { redactionMarksSession.pendingCount }
  var hasUnappliedRedactionMarks: Bool {
    redactionMarksSession.hasPendingMarks
  }

  /// Save barrier for pending marks: saving while marks are staged writes the
  /// document unchanged, so the user is told explicitly instead of assuming a
  /// saved file was redacted. Returns true when the save may proceed.
  func confirmSaveWithPendingRedactionMarks() -> Bool {
    let count = redactionMarksSession.pendingCount
    guard count > 0 else { return true }
    let alert = NSAlert()
    alert.messageText = "Unapplied Redaction Marks"
    alert.informativeText =
      "This document has " + String(count)
      + " pending redaction mark(s). They have NOT been applied, so saving now writes the "
      + "document unchanged and nothing is redacted. Open Redaction Marks and apply them first "
      + "if you want the saved file to be redacted."
    alert.addButton(withTitle: "Save Without Applying")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Clears staged marks after the document is reloaded/reverted: the review
  /// geometry belongs to the previous revision and must not be applied to a
  /// different graph. The panel reports the empty state.
  func resetRedactionMarksAfterReload() {
    redactionMarksSession.store.removeAll()
    redactionMarksSession.reviewQueue = nil
    redactionMarksSession.lastSearchRequest = nil
    redactionMarksSession.panelController?.refresh()
  }

  // MARK: Undo integration

  func registerRedactionUndo(markIDs: Set<UUID>) {
    defer { refreshRedactionDocumentState() }
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    let revision = editSession.documentRevision
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performRedactionUndo(registeredRevision: revision, markIDs: markIDs)
    }
    undoManager.setActionName("Apply Redactions")
    undoManager.endUndoGrouping()
  }

  func performRedactionUndo(registeredRevision: UInt64?, markIDs: Set<UUID>) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    redactionMarksSession.store.noteUndone()
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performRedactionRedo(registeredRevision: revision, markIDs: markIDs)
    }
    undoManager?.setActionName("Apply Redactions")
    refreshViewerAfterRedaction(preservingPage: viewer?.pageNumber ?? 0)
    redactionMarksSession.panelController?.refresh()
  }

  func performRedactionRedo(registeredRevision: UInt64?, markIDs: Set<UUID>) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    redactionMarksSession.store.noteApplied(markIDs)
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performRedactionUndo(registeredRevision: revision, markIDs: markIDs)
    }
    undoManager?.setActionName("Apply Redactions")
    refreshViewerAfterRedaction(preservingPage: viewer?.pageNumber ?? 0)
    redactionMarksSession.panelController?.refresh()
  }

  func refreshViewerAfterRedaction(preservingPage page: Int) {
    defer { refreshRedactionDocumentState() }
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

  func refreshRedactionDocumentState() {
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
  }

  private func lineSelectionRects(_ selection: PDFSelection, page: PDFPage) -> [[Double]] {
    var rects: [[Double]] = []
    for line in selection.selectionsByLine() {
      guard line.pages.contains(where: { $0 === page }) else { continue }
      let bounds = line.bounds(for: page)
      guard bounds.width > 0.5, bounds.height > 0.5,
        bounds.minX.isFinite, bounds.minY.isFinite
      else { continue }
      rects.append([bounds.minX, bounds.minY, bounds.maxX, bounds.maxY])
    }
    return rects
  }
}
