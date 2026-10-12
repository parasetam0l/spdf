import Foundation
import PDFCore
import PDFEditing

/// P17-012/P17-013: what one committed mutation changed, published with the
/// document revision so rendering/search services can invalidate precisely
/// and reject stale work. `pageIDs` empty means the pages are not known here;
/// callers treat that as "all pages".
public struct EditChangeSet: Sendable, Equatable {
  public let revision: UInt64
  public let pageIDs: [PDFObjectID]

  public init(revision: UInt64, pageIDs: [PDFObjectID]) {
    self.revision = revision
    self.pageIDs = pageIDs
  }
}

/// Owns the canonical edited graph for one document, bounded undo/redo
/// snapshots, and the saved-revision comparison used for dirty state and
/// save bytes. All state is lock-guarded so AppKit's nonisolated document
/// lifecycle can call it from worker threads.
///
/// Save policy for this stage: an unedited document returns its exact
/// original bytes; an edited document is serialized by the core writer, then
/// reparsed and compared against the edited graph before the bytes are
/// offered to AppKit. Undo restores snapshots, so returning to the saved
/// revision restores the original bytes exactly.
public final class DocumentEditSession: @unchecked Sendable {
  /// Undo is snapshot-based and bounded; the oldest snapshots are dropped.
  public static let undoLimit = 50

  private struct UndoEntry {
    let graph: PDFGraph
    /// Pages the edit that produced the *next* state touched, so undo can
    /// invalidate exactly those previews.
    let changedPageIDs: [PDFObjectID]
  }

  private let lock = NSLock()
  private let limits: PDFLimits
  private var source: PDFSource?
  private var original: PDFGraph?
  private var current: PDFGraph?
  private var saved: PDFGraph?
  private var parsedBase: ParsedPDF?
  private var pendingBase: ParsedPDF?
  private var savedBytes: Data?
  private var pendingBytes: Data?
  private var pages: [PDFObjectID] = []
  private var undoStack: [UndoEntry] = []
  private var redoStack: [UndoEntry] = []
  /// P17-013/P17-014: monotonic document revision, advanced by every
  /// committed mutation (load, edit, undo, redo).
  private var revision: UInt64 = 0
  private var lastChangeSet = EditChangeSet(revision: 0, pageIDs: [])
  /// P16-020: bounded per-revision change history so consumers (search
  /// index, previews) can ask "what changed since revision R" exactly.
  /// `pageIDs == nil` records an all-pages (unknown-scope) change.
  private var changeLog: [(revision: UInt64, pageIDs: [PDFObjectID]?)] = []
  private var changeFloor: UInt64 = 0
  private static let changeLogLimit = 64
  /// P28-020: the authenticated encryption state for a protected document;
  /// nil for unencrypted documents and after locking.
  private var protectedState: PDFEncryptionState?
  /// P38-022: repaired documents whose graph did not fully validate stay
  /// read-only until the repair is accepted.
  private var repairedEditSafe = true

  public init(limits: PDFLimits = PDFLimits()) {
    self.limits = limits
  }

  /// Best-effort load: documents the owned core cannot parse stay read-only
  /// but keep their original bytes available for an exact copy.
  public func load(_ source: PDFSource) {
    let parsed = try? PDFParser.parse(source.data, limits: limits)
    lock.withLock {
      self.source = source
      original = parsed?.graph
      current = parsed?.graph
      saved = parsed?.graph
      parsedBase = parsed
      pendingBase = nil
      savedBytes = nil
      pendingBytes = nil
      pages = parsed?.pageIDs ?? []
      undoStack.removeAll()
      redoStack.removeAll()
      protectedState = nil
      repairedEditSafe = true
      // P17-013: a load is a new document state; every page may differ.
      revision &+= 1
      lastChangeSet = EditChangeSet(revision: revision, pageIDs: [])
      recordChangeLocked()
    }
  }

  /// P28-020/P28-021: authenticate a protected source. The decrypted graph
  /// becomes editable according to the operation policy (owner password or
  /// the modification permission); saves re-encrypt with the same protection.
  /// The password is not retained.
  public func loadProtected(_ source: PDFSource, password: String) throws {
    let unlocked = try PDFParser.unlock(source.data, password: password, limits: limits)
    lock.withLock {
      self.source = source
      original = unlocked.parsed.graph
      current = unlocked.parsed.graph
      saved = unlocked.parsed.graph
      parsedBase = nil  // protected saves are full rewrites with re-encryption
      pendingBase = nil
      savedBytes = nil
      pendingBytes = nil
      pages = unlocked.parsed.pageIDs
      undoStack.removeAll()
      redoStack.removeAll()
      protectedState = unlocked.encryption
      repairedEditSafe = true
      revision &+= 1
      lastChangeSet = EditChangeSet(revision: revision, pageIDs: [])
      recordChangeLocked()
    }
  }

  /// P28-023: bound the unlocked session. The decrypted graph and file key
  /// are released and the document reverts to the encrypted source's
  /// read-only state.
  public func lockSession() {
    let source = lock.withLock { () -> PDFSource? in
      // P04-025: zero the retained file key before dropping the reference.
      protectedState?.reset()
      protectedState = nil
      return self.source
    }
    if let source { load(source) }
  }

  public var isProtected: Bool { lock.withLock { protectedState != nil } }
  public var protectionAllowsEditing: Bool {
    lock.withLock { protectedState?.allowsEditing ?? true }
  }
  public var protectionSummary: PDFEncryptionInfo? { lock.withLock { protectedState?.info } }
  public var isOwnerUnlocked: Bool { lock.withLock { protectedState?.isOwner ?? false } }

  public var canEdit: Bool {
    lock.withLock { current != nil && repairedEditSafe && (protectedState?.allowsEditing ?? true) }
  }
  /// P38-022: true when a repaired document's edits are gated.
  public var repairedEditGated: Bool { lock.withLock { !repairedEditSafe } }
  /// Mark the loaded document as repaired with the given safety verdict.
  public func markRepaired(editSafe: Bool) {
    lock.withLock { repairedEditSafe = editSafe }
  }
  public var isDirty: Bool { lock.withLock { graphIsDirty } }
  public var canUndo: Bool { lock.withLock { !undoStack.isEmpty } }
  public var canRedo: Bool { lock.withLock { !redoStack.isEmpty } }
  public var pageIDs: [PDFObjectID] { lock.withLock { pages } }
  public var currentGraph: PDFGraph? { lock.withLock { current } }

  /// P09-018: the save mode chosen before any output bytes are produced.
  public var savePlan: PDFSavePlan {
    lock.withLock {
      PDFWriter.plan(current: current, original: original, baseAvailable: parsedBase != nil)
    }
  }

  /// Commit a transaction against the current graph. Failures leave the
  /// session untouched; a no-op result does not create an undo entry.
  public func apply(_ transaction: PDFTransaction) throws {
    try applyWithFallbackPages(transaction, pages: [])
  }

  /// P17-013/P17-014: the monotonic revision of the current document state.
  public var documentRevision: UInt64 { lock.withLock { revision } }

  /// P16-020: what changed since `revision`. `changedPageIDs == nil` means
  /// every page (an unknown-scope change was recorded); `isUnknown` means the
  /// requested revision predates the bounded retained history, so callers
  /// must invalidate everything.
  public struct ChangeHistory: Sendable, Equatable {
    public let revision: UInt64
    public let changedPageIDs: Set<PDFObjectID>?
    public let isUnknown: Bool
  }

  public func changes(since revision: UInt64) -> ChangeHistory {
    lock.withLock {
      if revision >= self.revision {
        return ChangeHistory(revision: self.revision, changedPageIDs: [], isUnknown: false)
      }
      if revision < changeFloor {
        return ChangeHistory(revision: self.revision, changedPageIDs: nil, isUnknown: true)
      }
      var pages: Set<PDFObjectID> = []
      var everyPage = false
      for entry in changeLog where entry.revision > revision {
        if let ids = entry.pageIDs {
          pages.formUnion(ids)
        } else {
          everyPage = true
        }
      }
      return ChangeHistory(
        revision: self.revision, changedPageIDs: everyPage ? nil : pages, isUnknown: false)
    }
  }

  private func recordChangeLocked() {
    changeLog.append(
      (revision: revision, pageIDs: lastChangeSet.pageIDs.isEmpty ? nil : lastChangeSet.pageIDs))
    if changeLog.count > Self.changeLogLimit {
      changeLog.removeFirst(changeLog.count - Self.changeLogLimit)
      changeFloor = (changeLog.first?.revision ?? 0) &- 1
    }
  }

  /// P17-012: what the most recent committed mutation changed. Empty
  /// `pageIDs` means the pages are not known and callers invalidate all.
  public func changeSet() -> EditChangeSet { lock.withLock { lastChangeSet } }

  /// P17-012: the most recent change as page indices for the render service
  /// (`nil` = all pages), stable in document order.
  public func changedPageIndices() -> [Int]? {
    lock.withLock {
      guard !lastChangeSet.pageIDs.isEmpty else { return nil }
      let indices = lastChangeSet.pageIDs.compactMap { pages.firstIndex(of: $0) }
      return indices.count == lastChangeSet.pageIDs.count ? indices : nil
    }
  }

  /// P22-022: pages that carry at least one flattenable annotation.
  public func flattenablePageIDs() -> [PDFObjectID] {
    lock.withLock {
      guard let current else { return [] }
      return FlattenAnnotationsCommand.flattenablePageIDs(in: current, pageIDs: pages)
    }
  }

  /// P24: the canonical AcroForm field tree for the current graph.
  public func formFields() -> [FormField] {
    lock.withLock {
      guard let current else { return [] }
      return (try? FormInventory.fields(in: current, pageIDs: pages)) ?? []
    }
  }

  /// P24-017: fill a text field through the canonical transaction pipeline.
  public func fillFormText(fieldName: String, text: String) throws {
    try applyWithFallbackPages(
      PDFTransaction([SetFormTextCommand(fieldName: fieldName, text: text)]),
      pages: fieldPageIDs(fieldName))
  }

  /// P24-014: set a checkbox or radio group state.
  public func setFormButton(fieldName: String, state: PDFName?) throws {
    try applyWithFallbackPages(
      PDFTransaction([SetFormButtonStateCommand(fieldName: fieldName, state: state)]),
      pages: fieldPageIDs(fieldName))
  }

  /// P17-012: the pages a field's widgets sit on, so a fill invalidates
  /// exactly those previews (form commands carry no page scope themselves).
  private func fieldPageIDs(_ fieldName: String) -> [PDFObjectID] {
    guard let current,
      let field = (try? FormInventory.fields(in: current, pageIDs: pages))?
        .first(where: { $0.name == fieldName })
    else { return [] }
    var ids: [PDFObjectID] = []
    for widget in field.widgets {
      guard let index = widget.pageIndex, index >= 0, index < pages.count else { continue }
      let pageID = pages[index]
      if !ids.contains(pageID) { ids.append(pageID) }
    }
    return ids
  }

  /// Commit with an explicit fallback for the change set when the commands
  /// report no page scope.
  private func applyWithFallbackPages(_ transaction: PDFTransaction, pages fallback: [PDFObjectID])
    throws
  {
    try lock.withLock {
      let editing = try editableGraph()
      // P17-012/P17-022: page scope is computed against the graph the
      // commands will run on, so shared-resource edits report every page.
      var affected: [PDFObjectID] = []
      for command in transaction.commands {
        for id in command.affectedPageIDs(in: editing) where !affected.contains(id) {
          affected.append(id)
        }
      }
      if affected.isEmpty { affected = fallback }
      let updated = try PDFEditingEngine.commit(transaction, to: editing, limits: limits)
      publish(updated, changedPageIDs: affected)
      refreshPagesLocked()
    }
  }

  /// P26-003: pages that are OCR candidates: no text operators at all, or
  /// only our generated layer (which a re-run would replace).
  public func ocrCandidates() -> [(pageID: PDFObjectID, replacing: Bool)] {
    lock.withLock {
      guard let current else { return [] }
      var results: [(PDFObjectID, Bool)] = []
      for pageID in pages {
        if OCRLayer.hasGeneratedLayer(in: current, pageID: pageID) {
          results.append((pageID, true))
          continue
        }
        if !OCRLayer.pageShowsText(pageID, in: current) {
          results.append((pageID, false))
        }
      }
      return results
    }
  }

  /// P22-016: comments across the document in page order, optionally filtered
  /// by page, type, and review state.
  public func comments(filter: CommentFilter = CommentFilter()) -> [Comment] {
    lock.withLock {
      guard let current else { return [] }
      return CommentList.comments(in: current, pageIDs: pages, filter: filter)
    }
  }

  /// Convenience for the document layer: rotate the page at `index`.
  public func rotatePage(at index: Int, byDegrees degrees: Int) throws {
    try lock.withLock {
      guard index >= 0, index < pages.count else {
        throw PDFError(.malformed, "Page index is outside the document")
      }
      let command = RotatePagesCommand(pageIDs: [pages[index]], byDegrees: degrees)
      let editing = try editableGraph()
      let updated = try PDFEditingEngine.commit(
        PDFTransaction([command]), to: editing, limits: limits)
      publish(updated, changedPageIDs: command.affectedPageIDs(in: editing))
    }
  }

  public func rotatePage(id: PDFObjectID, byDegrees degrees: Int) throws {
    try lock.withLock {
      let command = RotatePagesCommand(pageIDs: [id], byDegrees: degrees)
      let editing = try editableGraph()
      let updated = try PDFEditingEngine.commit(
        PDFTransaction([command]), to: editing, limits: limits)
      publish(updated, changedPageIDs: command.affectedPageIDs(in: editing))
    }
  }

  /// Move the page at `index` to `toIndex` in the flattened order.
  public func movePage(at index: Int, to toIndex: Int) throws {
    try lock.withLock {
      guard index >= 0, index < pages.count else {
        throw PDFError(.malformed, "Page index is outside the document")
      }
      let command = ReorderPagesCommand(pageID: pages[index], toIndex: toIndex)
      let editing = try editableGraph()
      let updated = try PDFEditingEngine.commit(
        PDFTransaction([command]), to: editing, limits: limits)
      publish(updated, changedPageIDs: command.affectedPageIDs(in: editing))
      refreshPagesLocked()
    }
  }

  /// Delete the page at `index`; refuses when other objects reference it.
  public func deletePage(at index: Int) throws {
    try lock.withLock {
      guard index >= 0, index < pages.count else {
        throw PDFError(.malformed, "Page index is outside the document")
      }
      let command = DeletePagesCommand(pageIDs: [pages[index]])
      let editing = try editableGraph()
      let updated = try PDFEditingEngine.commit(
        PDFTransaction([command]), to: editing, limits: limits)
      publish(updated, changedPageIDs: command.affectedPageIDs(in: editing))
      refreshPagesLocked()
    }
  }

  /// Insert a blank page at `index` with an explicit MediaBox size.
  public func insertBlankPage(at index: Int, width: Int64, height: Int64) throws {
    try lock.withLock {
      let command = InsertBlankPageCommand(atIndex: index, width: width, height: height)
      let editing = try editableGraph()
      let updated = try PDFEditingEngine.commit(
        PDFTransaction([command]), to: editing, limits: limits)
      // The inserted page's identity does not exist before the commit; the
      // change set stays conservative (the list refresh below supplies it).
      publish(updated, changedPageIDs: command.affectedPageIDs(in: editing))
      refreshPagesLocked()
    }
  }

  /// Replace the text of one run on the page at `index` (P18 vertical slice).
  public func replaceText(pageAt index: Int, runIndex: Int, with replacement: String) throws {
    try lock.withLock {
      guard index >= 0, index < pages.count else {
        throw PDFError(.malformed, "Page index is outside the document")
      }
      let command = ReplaceTextCommand(
        pageID: pages[index], runIndex: runIndex, replacement: replacement)
      let editing = try editableGraph()
      let updated = try PDFEditingEngine.commit(
        PDFTransaction([command]), to: editing, limits: limits)
      publish(updated, changedPageIDs: command.affectedPageIDs(in: editing))
    }
  }

  /// MediaBox of the page at `index` as `[x0, y0, x1, y1]`, when present.
  public func pageMediaBox(at index: Int) -> [Int64]? {
    lock.withLock {
      guard index >= 0, index < pages.count, let current,
        case .dictionary(let dictionary)? = current.objects[pages[index]],
        case .array(let box)? = dictionary[PDFName("MediaBox")]
      else { return nil }
      let values = box.compactMap { value -> Int64? in
        if case .integer(let raw) = value { return raw }
        return nil
      }
      return values.count == box.count ? values : nil
    }
  }

  @discardableResult
  public func undo() -> Bool {
    lock.withLock {
      guard let previous = undoStack.popLast(), let currentGraph = current else { return false }
      // The popped entry knows which pages the edit it undoes touched.
      redoStack.append(UndoEntry(graph: currentGraph, changedPageIDs: previous.changedPageIDs))
      current = previous.graph
      revision &+= 1
      lastChangeSet = EditChangeSet(revision: revision, pageIDs: previous.changedPageIDs)
      recordChangeLocked()
      refreshPagesLocked()
      return true
    }
  }

  @discardableResult
  public func redo() -> Bool {
    lock.withLock {
      guard let next = redoStack.popLast(), let currentGraph = current else { return false }
      undoStack.append(UndoEntry(graph: currentGraph, changedPageIDs: next.changedPageIDs))
      if undoStack.count > Self.undoLimit {
        undoStack.removeFirst(undoStack.count - Self.undoLimit)
      }
      current = next.graph
      revision &+= 1
      lastChangeSet = EditChangeSet(revision: revision, pageIDs: next.changedPageIDs)
      recordChangeLocked()
      refreshPagesLocked()
      return true
    }
  }

  /// Called after the destination write succeeded; the current graph becomes
  /// the saved revision for both Save and Save As, and the written bytes
  /// become the base for later incremental updates.
  public func noteSaved() {
    lock.withLock {
      if let pendingBase {
        parsedBase = pendingBase
        self.pendingBase = nil
      }
      if let pendingBytes {
        savedBytes = pendingBytes
        self.pendingBytes = nil
      }
      saved = current
    }
  }

  /// Bytes for the destination: exact original bytes while the graph still
  /// equals the parsed original, an incremental revision while a saved base
  /// exists, otherwise a verified full rewrite. Every produced byte string
  /// is reparsed and compared against the edited graph before it is offered
  /// to AppKit, and the reparsed result becomes the next incremental base.
  public func bytesForSave() throws -> Data {
    try lock.withLock {
      guard let source else {
        throw PDFError(.malformed, "No PDF source is loaded")
      }
      // P28-020: protected documents save as full rewrites that re-encrypt
      // with the original file key and dictionary, so passwords, permissions,
      // and the profile are preserved.
      if let protectedState {
        guard let currentGraph = current else {
          throw PDFError(.unsupported, "This document is not editable by the owned core")
        }
        if !graphIsDirty, let savedBytes { return savedBytes }
        let output = try protectedState.writeReencrypted(currentGraph, limits: limits)
        try protectedState.verifyReencrypted(output, against: currentGraph, limits: limits)
        pendingBase = nil
        pendingBytes = output
        return output
      }
      let plan = PDFWriter.plan(
        current: current, original: original, baseAvailable: parsedBase != nil)
      guard plan.mode != .originalBytes, let currentGraph = current else {
        return source.data
      }
      // Re-saving without new edits reproduces the saved revision bytes
      // instead of appending an empty revision.
      if !graphIsDirty, let savedBytes { return savedBytes }
      let output: Data
      if plan.mode == .incrementalUpdate, let base = parsedBase {
        do {
          output = try PDFWriter.incrementalUpdate(from: base, to: currentGraph, limits: limits)
        } catch let error as PDFError where error.kind == .unsupported {
          // Signed/linearized/otherwise ineligible bases fall back to a
          // full rewrite, which applies the same refusals.
          output = try PDFWriter.write(currentGraph, limits: limits)
        }
      } else {
        output = try PDFWriter.write(currentGraph, limits: limits)
      }
      let reparsed = try PDFParser.parse(output, limits: limits)
      // /Size is derived per save mode: an incremental revision covers freed
      // object numbers while a full rewrite covers only live objects, so the
      // declared count may legitimately differ from the in-memory graph.
      var expected = currentGraph
      if let savedSize = reparsed.graph.trailer[PDFName("Size")] {
        expected.trailer[PDFName("Size")] = savedSize
      }
      guard reparsed.graph == expected else {
        throw PDFError(
          .malformed, "Edited output failed verification against the edited graph")
      }
      pendingBase = reparsed
      pendingBytes = output
      return output
    }
  }

  // MARK: - Lock-held helpers

  /// P28-020: verify protected output without the password (used by the
  /// verified destination writer).
  public func verifyProtectedOutput(_ data: Data) throws {
    try lock.withLock {
      guard let protectedState, let currentGraph = current else {
        throw PDFError(.unsupported, "This document is not an unlocked protected document")
      }
      try protectedState.verifyReencrypted(data, against: currentGraph, limits: limits)
    }
  }

  private var graphIsDirty: Bool {
    current != nil && current != saved
  }

  private func editableGraph() throws -> PDFGraph {
    guard let current else {
      throw PDFError(.unsupported, "This document is not editable by the owned core")
    }
    // P28-021: the operation policy gates every transaction, not just the UI.
    guard protectedState?.allowsEditing ?? true else {
      throw PDFError(.unsupported, "The document's permissions do not allow modification")
    }
    // P38-022: repaired documents whose graph did not fully validate stay
    // read-only until the repair is accepted.
    guard repairedEditSafe else {
      throw PDFError(
        .unsupported,
        "This repaired document did not fully validate; edits stay gated until the repair is accepted")
    }
    return current
  }

  private func publish(_ updated: PDFGraph, changedPageIDs: [PDFObjectID]) {
    guard let currentGraph = current, updated != currentGraph else { return }
    undoStack.append(UndoEntry(graph: currentGraph, changedPageIDs: changedPageIDs))
    if undoStack.count > Self.undoLimit {
      undoStack.removeFirst(undoStack.count - Self.undoLimit)
    }
    redoStack.removeAll()
    current = updated
    // P17-013/P17-014: every committed mutation advances the revision so
    // stale worker results are rejected and services can publish the change.
    revision &+= 1
    lastChangeSet = EditChangeSet(revision: revision, pageIDs: changedPageIDs)
    recordChangeLocked()
  }

  /// Structural edits change the page list; refresh it from the new graph.
  private func refreshPagesLocked() {
    guard let current else { return }
    if let ids = try? PDFPageTree.pageIDs(in: current) {
      pages = ids
    }
  }
}
