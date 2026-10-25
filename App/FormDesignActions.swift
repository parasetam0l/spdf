import AppKit
import PDFCore
import PDFEditing
import PDFKit

/// FRM-02: design vs fill preview for the form-design canvas.
enum FormDesignPreviewMode: String, CaseIterable, Identifiable {
  case design
  case fill

  var id: String { rawValue }

  var label: String {
    switch self {
    case .design: return "Design"
    case .fill: return "Fill preview"
    }
  }
}

/// FRM-01/FRM-02 review state for one open document.
///
/// Detection proposals and the canvas selection live here, not in the PDF:
/// detecting, accepting and rejecting never touch the edit session. Only an
/// explicit create/move/resize/tab-order action becomes one undoable
/// transaction through the document routes below.
@MainActor
final class FormDesignSession: NSObject {
  weak var document: SPDFDocument?
  weak var panelController: FormDesignPanelController?
  weak var canvas: FormDesignCanvasView?

  var pageIndex = 0
  var previewMode: FormDesignPreviewMode = .design
  var showTabOrder = true
  var showGuides = true
  /// nil means the canvas "Select" tool is active.
  var newFieldKind: FormDetectedFieldKind?
  var radioOptionCount = 3
  var minimumConfidence = 0.6

  var detectionReport: FormDetectionReport?
  var review: FormFieldDetectionReview?
  var selection = FormWidgetSelection()
  var statusMessage: String?
  var errorMessage: String?

  var canCommitAccepted: Bool { review?.canCommit == true }
}

private enum FormDesignAssociationKeys {
  /// Address used only as an associated-object key; the value is never read.
  nonisolated(unsafe) static var session: UInt8 = 0
}

// MARK: - Document routes for the form-design panel and canvas

extension SPDFDocument {
  /// The per-document design canvas state.
  var formDesignSession: FormDesignSession {
    if let existing = objc_getAssociatedObject(
      self, &FormDesignAssociationKeys.session) as? FormDesignSession
    {
      return existing
    }
    let session = FormDesignSession()
    session.document = self
    objc_setAssociatedObject(
      self, &FormDesignAssociationKeys.session, session,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return session
  }

  // MARK: Presentation

  /// Form -> Form Design…: open the review panel and install the page overlay.
  func showFormDesign() {
    let session = formDesignSession
    session.pageIndex = formDesignPageIndex()
    if let controller = windowControllers.compactMap({
      $0 as? FormDesignPanelController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      installFormDesignCanvas()
      return
    }
    let controller = FormDesignPanelController(document: self, session: session)
    addWindowController(controller)
    session.panelController = controller
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    installFormDesignCanvas()
  }

  /// Install the design overlay above the page view. The overlay draws only;
  /// it forwards nothing while fill preview is selected.
  func installFormDesignCanvas() {
    guard let viewer else { return }
    if let existing = viewer.view.subviews.compactMap({ $0 as? FormDesignCanvasView }).first {
      existing.session = formDesignSession
      existing.frame = viewer.view.bounds
      existing.isHidden = formDesignSession.previewMode == .fill
      existing.refreshFromDocument()
      return
    }
    let canvas = FormDesignCanvasView()
    canvas.session = formDesignSession
    canvas.document = self
    canvas.frame = viewer.view.bounds
    canvas.autoresizingMask = [.width, .height]
    canvas.isHidden = formDesignSession.previewMode == .fill
    viewer.view.addSubview(canvas)
    formDesignSession.canvas = canvas
    canvas.refreshFromDocument()
  }

  func removeFormDesignCanvas() {
    formDesignSession.canvas?.removeFromSuperview()
    formDesignSession.canvas = nil
  }

  func setFormDesignPreviewMode(_ mode: FormDesignPreviewMode) {
    formDesignSession.previewMode = mode
    let canvas = formDesignSession.canvas
    canvas?.isHidden = mode == .fill
    canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  var canShowFormDesign: Bool { viewer != nil && editSession.currentGraph != nil }
  var canDetectFormFields: Bool { viewer != nil && editSession.currentGraph != nil }
  var canAuthorOnFormCanvas: Bool { canEditContent && viewer != nil }

  func formDesignPageIndex() -> Int {
    max(0, (viewer?.pageNumber ?? 1) - 1)
  }

  /// Clear review state that belongs to a previous graph revision. Call from a
  /// document reload/revert path; staged proposals never block a save because
  /// they change no bytes.
  func resetFormDesignAfterReload() {
    formDesignSession.review = nil
    formDesignSession.detectionReport = nil
    formDesignSession.selection.removeAll()
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  // MARK: Reading canonical state

  func formDesignWidgets() -> [FormWidgetDescriptor] {
    guard let graph = editSession.currentGraph else { return [] }
    return (try? FormDesignInventory.widgets(in: graph, pageIDs: editSession.pageIDs)) ?? []
  }

  func formDesignWidgetsForCurrentPage() -> [FormWidgetDescriptor] {
    syncFormDesignPage()
    let index = formDesignSession.pageIndex
    return formDesignWidgets().filter { $0.pageIndex == index }
  }

  func formDesignWidgetsForAllPages() -> [FormWidgetDescriptor] { formDesignWidgets() }

  /// Keep the session page in step with the viewer without a panel reload.
  func syncFormDesignPage() {
    let index = formDesignPageIndex()
    if formDesignSession.pageIndex != index {
      formDesignSession.pageIndex = index
      formDesignSession.selection.removeAll()
      formDesignSession.canvas?.refreshFromDocument()
    }
  }

  func formDesignPageBounds() -> [Double] {
    guard editSession.pageIDs.indices.contains(formDesignSession.pageIndex) else {
      return [0, 0, 612, 792]
    }
    return FormFieldDetection.pageBounds(
      pageID: editSession.pageIDs[formDesignSession.pageIndex], in: editSession.currentGraph
        ?? PDFGraph(objects: [:], trailer: [:]))
  }

  func formDesignTabOrderState() -> (fields: [FormField], current: [String], suggested: [String]) {
    guard let graph = editSession.currentGraph else { return ([], [], []) }
    let fields = (try? FormInventory.fields(in: graph, pageIDs: editSession.pageIDs)) ?? []
    return (
      fields, FormTabOrder.current(fields: fields),
      FormTabOrder.suggested(pageIDs: editSession.pageIDs, fields: fields))
  }

  // MARK: Detection

  /// Run detection over the current page or the whole document. This only reads
  /// the graph; no field is created and nothing is added to the undo stack.
  @discardableResult
  func runFormFieldDetection(allPages: Bool = false) -> FormDetectionReport? {
    guard let graph = editSession.currentGraph else { return nil }
    var options = FormDetectionOptions()
    options.minimumConfidence = formDesignSession.minimumConfidence
    do {
      let report: FormDetectionReport
      if allPages {
        report = try FormFieldDetection.detectDocument(
          in: graph, pageIDs: editSession.pageIDs, options: options)
      } else {
        syncFormDesignPage()
        let index = formDesignSession.pageIndex
        guard editSession.pageIDs.indices.contains(index) else { return nil }
        let pageID = editSession.pageIDs[index]
        let outcome = try FormFieldDetection.detect(
          pageIndex: index, pageID: pageID, in: graph, options: options)
        report = FormDetectionReport(pages: [outcome.report], candidates: outcome.candidates)
      }
      formDesignSession.detectionReport = report
      formDesignSession.review = FormFieldDetectionReview(report: report)
      formDesignSession.errorMessage = nil
      formDesignSession.statusMessage = report.summary
      formDesignSession.canvas?.refreshFromDocument()
      formDesignSession.panelController?.refresh()
      return report
    } catch {
      formDesignSession.errorMessage = error.localizedDescription
      formDesignSession.panelController?.refresh()
      return nil
    }
  }

  func acceptFormCandidate(_ id: UUID) {
    formDesignSession.review?.accept(id)
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func rejectFormCandidate(_ id: UUID) {
    formDesignSession.review?.reject(id)
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func resetFormCandidate(_ id: UUID) {
    formDesignSession.review?.reset(id)
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func acceptAllFormCandidates() {
    formDesignSession.review?.acceptAllEligible()
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func rejectAllFormCandidates() {
    formDesignSession.review?.rejectAll()
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func updateFormCandidate(
    _ id: UUID, name: String? = nil, label: String? = nil, kind: FormDetectedFieldKind? = nil
  ) {
    formDesignSession.review?.update(id) { edits in
      if let name { edits.name = name }
      if let label { edits.label = label }
      if let kind { edits.kind = kind }
    }
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  /// Create every accepted proposal in ONE transaction: one Undo step.
  @discardableResult
  func createAcceptedFormFields() -> Bool {
    guard let graph = editSession.currentGraph, let review = formDesignSession.review else {
      return false
    }
    guard requireContentEditing(for: "Create Form Fields") else { return false }
    do {
      let plan = try review.makePlan(in: graph)
      guard applyFormDesignTransaction(plan.transaction, actionName: "Create Detected Fields")
      else { return false }
      let names = plan.fieldNames
      formDesignSession.detectionReport = nil
      formDesignSession.review = nil
      formDesignSession.statusMessage =
        "Created " + String(names.count) + " field" + (names.count == 1 ? "" : "s")
        + ": " + names.joined(separator: ", ") + ". One Undo removes the whole batch."
      formDesignSession.canvas?.refreshFromDocument()
      formDesignSession.panelController?.refresh()
      return true
    } catch {
      formDesignSession.errorMessage = error.localizedDescription
      formDesignSession.panelController?.refresh()
      return false
    }
  }

  // MARK: Canvas editing

  func formDesignSelection() -> FormWidgetSelection { formDesignSession.selection }

  func selectFormWidgets(_ widgets: [FormWidgetDescriptor]) {
    formDesignSession.selection = FormWidgetSelection(widgets: widgets)
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func toggleFormWidgetSelection(_ widget: FormWidgetDescriptor) {
    formDesignSession.selection.toggle(widget)
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  func clearFormWidgetSelection() {
    formDesignSession.selection.removeAll()
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  /// Commit the current canvas selection as one transaction (one Undo step).
  @discardableResult
  func moveFormWidgetSelection(by offset: [Double]) -> Bool {
    let commands = formDesignSession.selection.moveCommands(by: offset)
    guard !commands.isEmpty else { return false }
    return applyFormDesignTransaction(
      PDFTransaction(commands), actionName: "Move Form Fields")
  }

  @discardableResult
  func resizeFormWidgetSelection(handle: FormResizeHandle, by delta: [Double]) -> Bool {
    let commands = formDesignSession.selection.resizeCommands(handle: handle, by: delta)
    guard !commands.isEmpty else { return false }
    return applyFormDesignTransaction(
      PDFTransaction(commands), actionName: "Resize Form Fields")
  }

  @discardableResult
  func setFormWidgetRect(_ widget: FormWidgetDescriptor, rect: [Double]) -> Bool {
    return applyFormDesignTransaction(
      PDFTransaction([
        SetFormWidgetRectCommand(
          fieldName: widget.fieldName, widgetObjectID: widget.widgetObjectID,
          widgetIndex: widget.widgetIndex, rect: rect)
      ]), actionName: "Move Form Field")
  }

  @discardableResult
  func setSelectedFormFieldLabel(_ label: String) -> Bool {
    guard let fieldName = formDesignSession.selection.fieldNames.first else { return false }
    return applyFormFieldLabel(fieldName, label: label)
  }

  /// Set or clear one field's tooltip label as one undoable step.
  @discardableResult
  func applyFormFieldLabel(_ fieldName: String, label: String) -> Bool {
    return applyFormDesignTransaction(
      PDFTransaction([SetFormFieldTooltipCommand(fieldName: fieldName, tooltip: label)]),
      actionName: "Set Form Field Label")
  }

  /// Draw a new field directly on the page. One command (one Undo step).
  @discardableResult
  func createFormFieldOnCanvas(
    kind: FormDetectedFieldKind, rect: [Double], name: String?, label: String?
  ) -> Bool {
    guard canEditContent, let graph = editSession.currentGraph else { return false }
    syncFormDesignPage()
    let index = formDesignSession.pageIndex
    guard editSession.pageIDs.indices.contains(index) else { return false }
    let pageID = editSession.pageIDs[index]
    let bounds = FormFieldDetection.pageBounds(pageID: pageID, in: graph)
    let clamped = FormDesignGeometry.clamped(rect, to: bounds)
    let baseName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? defaultCanvasFieldName(kind: kind)
    let commands = FormCanvasAuthoring.commands(
      kind: kind, pageID: pageID, rect: clamped, baseName: baseName, label: label,
      radioOptionCount: formDesignSession.radioOptionCount)
    guard applyFormDesignTransaction(
      PDFTransaction(commands), actionName: "Draw Form Field")
    else { return false }
    formDesignSession.statusMessage =
      "Drew a " + kind.label.lowercased() + " named " + baseName + ". One Undo removes it."
    return true
  }

  private func defaultCanvasFieldName(kind: FormDetectedFieldKind) -> String {
    let existing = Set(editSession.formFields().map(\.name))
    let base: String
    switch kind {
    case .text: base = "TextField"
    case .checkbox: base = "CheckBox"
    case .radio: base = "RadioGroup"
    }
    var counter = 1
    var candidate = base + String(counter)
    while existing.contains(candidate) {
      counter += 1
      candidate = base + String(counter)
    }
    return candidate
  }

  /// Apply a tab order in ONE transaction: one Undo step.
  @discardableResult
  func applyFormTabOrder(_ order: [String]) -> Bool {
    guard let graph = editSession.currentGraph else { return false }
    let fields = (try? FormInventory.fields(in: graph, pageIDs: editSession.pageIDs)) ?? []
    if let problem = FormTabOrder.validate(order, fields: fields) {
      formDesignSession.errorMessage = problem
      formDesignSession.panelController?.refresh()
      return false
    }
    guard let transaction = FormTabOrder.transaction(order: order, fields: fields) else {
      return false
    }
    guard applyFormDesignTransaction(transaction, actionName: "Reorder Form Fields")
    else { return false }
    formDesignSession.statusMessage = "Tab order updated. One Undo restores the previous order."
    return true
  }

  // MARK: Transaction, undo and refresh

  /// One canvas gesture or panel action becomes one session transaction and one
  /// native undo group.
  @discardableResult
  func applyFormDesignTransaction(_ transaction: PDFTransaction, actionName: String) -> Bool {
    guard requireContentEditing(for: actionName) else { return false }
    guard finishPendingEdits() else { return false }
    do {
      try editSession.apply(transaction)
    } catch {
      _ = presentError(error)
      formDesignSession.errorMessage = error.localizedDescription
      formDesignSession.panelController?.refresh()
      return false
    }
    registerFormDesignUndo(actionName: actionName)
    reloadFormDesignViewer()
    return true
  }

  func registerFormDesignUndo(actionName: String) {
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    let revision = editSession.documentRevision
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performFormDesignUndo(registeredRevision: revision, actionName: actionName)
    }
    undoManager.setActionName(actionName)
    undoManager.endUndoGrouping()
  }

  func performFormDesignUndo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performFormDesignRedo(registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    reloadFormDesignViewer()
  }

  func performFormDesignRedo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performFormDesignUndo(registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    reloadFormDesignViewer()
  }

  func reloadFormDesignViewer() {
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data)
    else { return }
    let page = viewer?.pageNumber ?? 0
    let tool = viewer?.activeTool ?? .select
    try? viewer?.open(source)
    _ = viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
    refreshForms()
    refreshComments()
    refreshFonts()
    refreshDocumentInfo()
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
    formDesignSession.pageIndex = formDesignPageIndex()
    installFormDesignCanvas()
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }
}
