import AppKit
import Combine
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI

/// IMG-04/IMG-05: the App-side mixed page-object selection model.
///
/// One controller per document (created lazily through
/// SPDFDocument.pageObjectSelectionController). It owns the selection,
/// resolves the declared core profile against the canonical edit-session
/// graph, and commits every arrangement action as one transaction so one Undo
/// removes the whole operation.
@MainActor
final class PageObjectSelectionController: ObservableObject {
  private weak var document: SPDFDocument?
  @Published private(set) var selection: PageObjectSelection?
  @Published private(set) var pageIndex = 0
  @Published private(set) var isArrangeMode = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var refusalMessage: String?
  private var previousTool: ViewerToolMode?
  private var sheetWindow: NSWindow?

  init(document: SPDFDocument) {
    self.document = document
  }

  var declaredProfile: String { PageObjectSelectionProfile.declaredProfile }
  var profileName: String { PageObjectSelectionProfile.name }

  var isAvailable: Bool {
    guard let document, document.canEditContent, document.viewer != nil else { return false }
    return document.editSession.currentGraph != nil
  }

  var label: String { selection?.label ?? "No objects selected" }
  var selectedCount: Int { selection?.count ?? 0 }

  /// Eligibility note for a whole-selection operation, or nil when allowed.
  func refusal(for capability: PageObjectCapability) -> String? {
    selection?.refusal(for: capability)
  }

  var canGroup: Bool { selection?.supports(.group) == true }
  var canUngroup: Bool { canGroup }
  var canDelete: Bool { selection?.supports(.delete) == true }
  var canDuplicate: Bool { selection?.supports(.duplicate) == true }
  var canReorder: Bool { selection?.supports(.reorder) == true }
  var canResize: Bool { selection?.supports(.resize) == true }
  var canAlign: Bool { (selection?.count ?? 0) >= 2 }
  var canDistribute: Bool { (selection?.count ?? 0) >= 3 }

  // MARK: - Selection

  func begin(pageIndex: Int) {
    if pageIndex != self.pageIndex {
      selection = nil
      statusMessage = nil
      refusalMessage = nil
    }
    self.pageIndex = pageIndex
  }

  func clear() {
    selection = nil
    statusMessage = nil
    refusalMessage = nil
  }

  func setArrangeMode(_ enabled: Bool) {
    guard enabled != isArrangeMode else { return }
    isArrangeMode = enabled
    statusMessage = nil
    refusalMessage = nil
    if enabled {
      previousTool = document?.viewer?.activeTool
      _ = document?.viewer?.activateTool(.select)
      statusMessage =
        "Arrange mode: click objects, Shift-click to add, drag a marquee. Esc exits."
    } else {
      selection = nil
      if let previousTool, let viewer = document?.viewer, viewer.activeTool == .select {
        _ = viewer.activateTool(previousTool)
      }
      previousTool = nil
    }
  }

  func toggleArrangeMode() {
    setArrangeMode(!isArrangeMode)
  }

  /// Selectable profile objects on a page, resolved against the current graph.
  func targets(pageIndex: Int) -> [PageObjectRef] {
    guard let document, let graph = document.editSession.currentGraph,
      document.editSession.pageIDs.indices.contains(pageIndex)
    else { return [] }
    return
      (try? PageObjectSelectionProfile.selectable(
        pageID: document.editSession.pageIDs[pageIndex], in: graph)) ?? []
  }

  func object(at pagePoint: [Double], pageIndex: Int) -> PageObjectRef? {
    guard let document, let graph = document.editSession.currentGraph,
      document.editSession.pageIDs.indices.contains(pageIndex)
    else { return nil }
    return try? PageObjectSelectionProfile.object(
      at: pagePoint, pageID: document.editSession.pageIDs[pageIndex], in: graph)
  }

  func refusal(at pagePoint: [Double], pageIndex: Int) -> String? {
    guard let document, let graph = document.editSession.currentGraph,
      document.editSession.pageIDs.indices.contains(pageIndex)
    else { return nil }
    guard
      let refusals = try? PageObjectSelectionProfile.refusals(
        pageID: document.editSession.pageIDs[pageIndex], in: graph)
    else { return nil }
    return
      refusals.first { refusal in
        let bounds = refusal.bounds
        return pagePoint.count == 2 && pagePoint[0] >= bounds[0]
          && pagePoint[0] <= bounds[2] && pagePoint[1] >= bounds[1]
          && pagePoint[1] <= bounds[3]
      }?.reason
  }

  func select(_ refs: [PageObjectRef]) {
    selection = resolvedSelection(refs)
    refusalMessage = nil
    statusMessage = nil
  }

  func select(_ ref: PageObjectRef) {
    select([ref])
  }

  /// Shift-click composition. Returns the new selection or nil when empty.
  func toggle(_ ref: PageObjectRef) {
    begin(pageIndex: pageIndex)
    let next: PageObjectSelection?
    if let current = selection, current.pageID == ref.pageID {
      next = try? current.toggling(ref)
    } else {
      next = try? PageObjectSelection.make([ref])
    }
    selection = next.flatMap { resolvedSelection($0.members) }
    refusalMessage = nil
    statusMessage = nil
  }

  func marquee(pageIndex: Int, rect: [Double], additive: Bool) {
    guard let document, let graph = document.editSession.currentGraph,
      document.editSession.pageIDs.indices.contains(pageIndex)
    else { return }
    let pageID = document.editSession.pageIDs[pageIndex]
    var members: [PageObjectRef] = []
    if additive, let selection, selection.pageID == pageID {
      members = selection.members
    }
    if let hits = try? PageObjectSelectionProfile.marquee(
      pageID: pageID, rect: rect, in: graph)
    {
      let existing = Set(members.map(\.identity))
      members.append(contentsOf: hits.members.filter { !existing.contains($0.identity) })
    }
    if members.isEmpty {
      if !additive { selection = nil }
    } else {
      selection = try? PageObjectSelection(pageID: pageID, members: members)
    }
    refusalMessage = nil
    statusMessage = nil
  }

  func report(_ message: String) {
    refusalMessage = message
    statusMessage = nil
  }

  /// Expand persisted groups so a click on one member selects the whole group.
  private func resolvedSelection(_ members: [PageObjectRef]) -> PageObjectSelection? {
    guard !members.isEmpty else { return nil }
    var resolved: PageObjectSelection? = try? PageObjectSelection.make(members)
    if let document, let graph = document.editSession.currentGraph, let current = resolved {
      resolved = try? PageObjectSelectionProfile.expandingGroups(current, in: graph)
    }
    return resolved
  }

  // MARK: - IMG-04 transforms

  func moveSelection(dx: Double, dy: Double) {
    guard let selection, let graph = currentGraph else { return }
    perform {
      try PageObjectArrangement.moveCommands(selection, dx: dx, dy: dy, in: graph)
    }
  }

  func resizeSelection(from group: [Double], to destination: [Double]) {
    guard let selection, let graph = currentGraph else { return }
    perform {
      try PageObjectArrangement.resizeCommands(
        selection, from: group, to: destination, in: graph)
    }
  }

  func duplicateSelection() {
    guard let selection, let graph = currentGraph else {
      setStatus("Select at least one object to duplicate.")
      return
    }
    let before = Set(targets(pageIndex: pageIndex).map(\.identity))
    guard commit(try? PageObjectArrangement.duplicateCommands(selection, in: graph)) else {
      return
    }
    let after = targets(pageIndex: pageIndex)
    let newMembers = after.filter { !before.contains($0.identity) }
    self.selection = try? PageObjectSelection.make(newMembers)
    setStatus("Duplicated \(newMembers.count) object\(newMembers.count == 1 ? "" : "s").")
  }

  func deleteSelection() {
    guard let selection, let graph = currentGraph else {
      setStatus("Select at least one object to delete.")
      return
    }
    let count = selection.count
    guard commit(try? PageObjectArrangement.deleteCommands(selection, in: graph)) else {
      return
    }
    self.selection = nil
    setStatus("Deleted \(count) object\(count == 1 ? "" : "s").")
  }

  func align(_ alignment: PageObjectArrangeAlignment, reference: PageObjectArrangementReference) {
    guard let selection, let graph = currentGraph else {
      setStatus("Select at least two objects to align.")
      return
    }
    perform {
      try PageObjectArrangement.alignCommands(
        selection, alignment: alignment, reference: reference, in: graph)
    }
  }

  func distribute(_ axis: PageObjectDistributeAxis) {
    guard let selection, let graph = currentGraph else {
      setStatus("Select at least three objects to distribute.")
      return
    }
    perform {
      try PageObjectArrangement.distributeCommands(selection, axis: axis, in: graph)
    }
  }

  // MARK: - IMG-05 ordering and grouping

  func reorder(_ destination: PageObjectStacking) {
    guard let selection, let graph = currentGraph else {
      setStatus("Select at least one object to change paint order.")
      return
    }
    perform {
      try PageObjectArrangement.reorderCommands(selection, destination: destination, in: graph)
    }
  }

  func groupSelection() {
    guard let selection, let graph = currentGraph else { return }
    perform {
      try PageObjectArrangement.groupCommands(selection, in: graph)
    }
  }

  func ungroupSelection() {
    guard let selection, let graph = currentGraph else { return }
    perform {
      try PageObjectArrangement.ungroupCommands(selection, in: graph)
    }
  }

  // MARK: - Commit and refresh

  private var currentGraph: PDFGraph? { document?.editSession.currentGraph }

  private func perform(_ build: () throws -> [any PDFEditCommand]) {
    do {
      let commands = try build()
      guard commit(commands) else { return }
      refreshSelection()
      statusMessage = nil
      refusalMessage = nil
    } catch let error as PDFError {
      setStatus(error.message)
    } catch {
      setStatus(error.localizedDescription)
    }
  }

  @discardableResult
  private func commit(_ commands: [any PDFEditCommand]?) -> Bool {
    guard let commands, !commands.isEmpty, let document else { return false }
    guard document.applyPageObjectCommands(commands, pageIndex: pageIndex) else {
      setStatus("The document changed or refused this arrangement.")
      return false
    }
    return true
  }

  /// Re-resolve the selected identities after a commit/reload.
  private func refreshSelection() {
    guard let selection else { return }
    let identities = Set(selection.members.map(\.identity))
    let refreshed = targets(pageIndex: pageIndex).filter { identities.contains($0.identity) }
    self.selection = refreshed.isEmpty ? nil : try? PageObjectSelection.make(refreshed)
    if let document, let graph = document.editSession.currentGraph,
      let current = self.selection
    {
      self.selection = try? PageObjectSelectionProfile.expandingGroups(current, in: graph)
    }
  }

  private func setStatus(_ message: String?) {
    statusMessage = message
    if message != nil { refusalMessage = nil }
  }

  // MARK: - Arrange panel

  func presentArrangeSheet() {
    guard let document, let window = document.windowControllers.first?.window else { return }
    guard isAvailable else {
      let alert = NSAlert()
      alert.messageText = "Objects Cannot Be Arranged"
      alert.informativeText =
        document.contentEditingRestrictionNotice
        ?? "This document is view-only or still loading; nothing was changed."
      alert.runModal()
      return
    }
    if let sheetWindow, sheetWindow.isVisible {
      sheetWindow.makeKeyAndOrderFront(nil)
      return
    }
    let hosting = NSHostingController(rootView: PageObjectArrangeSheet(controller: self))
    let sheet = NSWindow(contentViewController: hosting)
    sheet.styleMask = [.titled, .closable]
    sheet.title = "Arrange Objects"
    sheet.setContentSize(NSSize(width: 380, height: 640))
    sheetWindow = sheet
    window.beginSheet(sheet) { [weak self] _ in
      self?.sheetWindow = nil
    }
  }

  func dismissArrangeSheet() {
    guard let sheetWindow, let window = document?.windowControllers.first?.window else {
      return
    }
    window.endSheet(sheetWindow)
    self.sheetWindow = nil
  }
}

// MARK: - Document integration

private enum PageObjectSelectionAssociation {
  nonisolated(unsafe) static var key: UInt8 = 0
}

extension SPDFDocument {
  /// One mixed-selection controller per document. Stored as an associated
  /// object because SPDFDocument is owned by the Lead in this batch and the
  /// controller needs per-document state without adding stored properties.
  @MainActor
  var pageObjectSelectionController: PageObjectSelectionController {
    if let existing = objc_getAssociatedObject(
      self, &PageObjectSelectionAssociation.key) as? PageObjectSelectionController
    {
      return existing
    }
    let controller = PageObjectSelectionController(document: self)
    objc_setAssociatedObject(
      self, &PageObjectSelectionAssociation.key, controller,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return controller
  }

  /// Apply one arrangement transaction with one native Undo step and a viewer
  /// reload. This mirrors the App's existing private image-transaction helper
  /// through public/internal session APIs because that helper is file-private.
  @MainActor
  func applyPageObjectCommands(_ commands: [any PDFEditCommand], pageIndex: Int) -> Bool {
    guard !commands.isEmpty, requireContentEditing(for: "Arrange Objects") else {
      return false
    }
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return false
    }
    registerPageObjectUndo()
    reloadViewerAfterPageObjectEdit(preservingPage: max(1, pageIndex + 1))
    return true
  }

  @MainActor
  private func registerPageObjectUndo() {
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    let revision = editSession.documentRevision
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performPageObjectUndo(registeredRevision: revision)
    }
    undoManager.setActionName("Arrange Objects")
    undoManager.endUndoGrouping()
  }

  @MainActor
  private func performPageObjectUndo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performPageObjectRedo(registeredRevision: revision)
    }
    undoManager?.setActionName("Arrange Objects")
    reloadViewerAfterPageObjectEdit(preservingPage: viewer?.pageNumber ?? 0)
  }

  @MainActor
  private func performPageObjectRedo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performPageObjectUndo(registeredRevision: revision)
    }
    undoManager?.setActionName("Arrange Objects")
    reloadViewerAfterPageObjectEdit(preservingPage: viewer?.pageNumber ?? 0)
  }

  /// Reopen the canonical session bytes in the PDFKit renderer, keeping the
  /// tool, zoom and visible page. Comments/forms/fonts do not change in a
  /// page-content arrangement, so only the renderer needs refreshing.
  @MainActor
  private func reloadViewerAfterPageObjectEdit(preservingPage page: Int) {
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data), let viewer
    else { return }
    let tool = viewer.activeTool
    let scale = viewer.view.scaleFactor
    let autoScales = viewer.view.autoScales
    try? viewer.open(source)
    viewer.view.autoScales = autoScales
    if !autoScales { viewer.view.scaleFactor = scale }
    _ = viewer.activateTool(tool)
    if page > 0 { viewer.go(to: page) }
  }

  // MARK: - Menu-facing entry points (hooked by ApplicationDelegate)

  var canUsePageObjectArrangement: Bool {
    pageObjectSelectionController.isAvailable
  }

  var canAlignSelectedPageObjects: Bool {
    pageObjectSelectionController.canAlign
  }

  var canDistributeSelectedPageObjects: Bool {
    pageObjectSelectionController.canDistribute
  }

  var canReorderSelectedPageObjects: Bool {
    pageObjectSelectionController.canReorder
  }

  var canGroupSelectedPageObjects: Bool {
    pageObjectSelectionController.canGroup
  }

  var canDeleteSelectedPageObjects: Bool {
    pageObjectSelectionController.canDelete
  }

  var canDuplicateSelectedPageObjects: Bool {
    pageObjectSelectionController.canDuplicate
  }

  @MainActor
  func alignSelectedPageObjects(_ alignment: PageObjectArrangeAlignment) {
    pageObjectSelectionController.align(alignment, reference: .selection)
  }

  @MainActor
  func distributeSelectedPageObjects(_ axis: PageObjectDistributeAxis) {
    pageObjectSelectionController.distribute(axis)
  }

  @MainActor
  func reorderSelectedPageObjects(_ destination: PageObjectStacking) {
    pageObjectSelectionController.reorder(destination)
  }

  @MainActor
  func groupSelectedPageObjects() {
    pageObjectSelectionController.groupSelection()
  }

  @MainActor
  func ungroupSelectedPageObjects() {
    pageObjectSelectionController.ungroupSelection()
  }

  @MainActor
  func duplicateSelectedPageObjects() {
    pageObjectSelectionController.duplicateSelection()
  }

  @MainActor
  func deleteSelectedPageObjects() {
    pageObjectSelectionController.deleteSelection()
  }
}
