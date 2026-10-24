import AppKit
import DocumentSession
import MacServices
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SPDFDocumentResourcePolicy {
  // The NSDocument URL path already accepts this bound; keep parsing, editing
  // and save verification consistent without widening PDFCore's default.
  static let maximumPDFBytes = 256 * 1_024 * 1_024
  static let parsingLimits = PDFLimits(fileBytes: maximumPDFBytes)

  static func readPDFData(at url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, size <= maximumPDFBytes else {
      throw PDFError(.limitExceeded, "This file exceeds the current 256 MiB opening limit")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumPDFBytes else {
      throw PDFError(.limitExceeded, "This file exceeds the current 256 MiB opening limit")
    }
    return data
  }
}

@MainActor
private final class ParagraphReflowCandidateSelectionTarget: NSObject {
  private let candidates: [TextParagraphCandidate]
  private weak var replacementTextView: NSTextView?

  init(candidates: [TextParagraphCandidate], replacementTextView: NSTextView) {
    self.candidates = candidates
    self.replacementTextView = replacementTextView
  }

  @objc func candidateDidChange(_ sender: NSPopUpButton) {
    guard candidates.indices.contains(sender.indexOfSelectedItem) else { return }
    replacementTextView?.string = candidates[sender.indexOfSelectedItem].text
      .replacingOccurrences(of: "\n", with: " ")
  }
}

@objc(SPDFDocument)
final class SPDFDocument: NSDocument {
  nonisolated let sourceStore = SourceStore()
  let editSession = DocumentEditSession(limits: SPDFDocumentResourcePolicy.parsingLimits)
  let commentsModel = CommentsModel()
  let formsModel = FormsModel()
  let signaturesModel = SignaturesModel()
  let structureModel = StructureModel()
  let fontsModel = FontsModel()
  let workspaceDocumentState = WorkspaceDocumentState()
  private var warnedFonts: Set<String> = []
  /// P36-009: the table review window and its model stay alive while open.
  private var tableReviewModel: TableReviewModel?
  private var tableReviewWindows: [NSWindow] = []
  /// P23-023: the page organizer window and its model stay alive while open.
  private var pageOrganizerModel: PageOrganizerModel?
  private var pageOrganizerWindow: NSWindow?
  private var combineModel: CombineDocumentsModel?
  private var combineWindow: NSWindow?
  private var attachmentsModel: AttachmentsModel?
  private var attachmentsWindow: NSWindow?
  private var bookmarksModel: BookmarksModel?
  private var bookmarksWindow: NSWindow?
  private var signatureWindow: NSWindow?
  private var warnedXFA = false
  /// Test hook: where provisioned fonts are installed (defaults to
  /// ~/Library/Fonts, the Font Book-compatible location).
  static var fontsInstallDirectoryOverride: URL?
  /// P10-016: bounded autosave and local recovery state. The smoke test can
  /// redirect the directory before opening documents.
  static var recoveryDirectoryOverride: URL?
  #if DEBUG
    /// The native diagnostic drives the real Save As panel on disposable files.
    static var diagnosticSavePanelObserver: ((NSSavePanel) -> Void)?
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
      let prepared = super.prepareSavePanel(savePanel)
      Self.diagnosticSavePanelObserver?(savePanel)
      return prepared
    }
  #endif
  private(set) lazy var recoveryStore = SPDFDocument.makeRecoveryStore()
  private(set) lazy var viewStateStore = SPDFDocument.makeViewStateStore()
  /// P12-021: background-job progress and cancellation for this document.
  let jobCenter = JobProgressCenter()
  private var lastRecoverySnapshotAt: Date?
  private var recoveredRecoveryKey: String?
  private let untitledRecoveryKey = "untitled-" + UUID().uuidString
  private var sourceFingerprint: SourceFingerprint?
  private(set) var viewer: PDFViewingSession?
  private(set) var coreInspection: CoreInspection?
  private var inspectionTask: Task<Void, Never>?
  private var isClosed = false
  private var isRunningOCR = false
  private var restoredFileAccess: URL?
  private var pendingUnlockedViewState: ViewState?
  private var textBlockCacheRevision: UInt64?
  private var textBlockCache: [Int: [PageTextTarget]] = [:]
  private var textEditRefusalCache: [Int: [PageTextEditRefusalTarget]] = [:]
  private nonisolated let pendingPageText = PendingPageTextState()
  private nonisolated let pendingFormText = PendingFormTextState()

  // AppKit constructs concurrent-reading documents on its worker queue.
  // No views or other main-actor objects are created until makeWindowControllers().
  nonisolated override init() { super.init() }

  override class var autosavesInPlace: Bool { false }
  nonisolated override var isDocumentEdited: Bool {
    // Field editors can register native undo without changing PDF content.
    // For an opened file, the canonical graph and pending page text decide
    // whether Save is needed, including Undo back to the saved graph.
    // Untitled/recovered documents still need their initial Save As.
    (fileURL == nil && super.isDocumentEdited) || editSession.isDirty
      || pendingPageText.hasChanges || pendingFormText.hasChanges
  }
  nonisolated override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
    true
  }

  nonisolated override func read(from url: URL, ofType typeName: String) throws {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize, size <= SPDFDocumentResourcePolicy.maximumPDFBytes else {
      throw PDFError(.limitExceeded, "This file exceeds the current 256 MiB opening limit")
    }
    // P10-014: coordinate the read so cloud-backed files materialize
    // through the file provider instead of failing or stalling. This runs
    // on AppKit's worker queue (concurrent reads), never the main thread.
    var coordinatorError: NSError?
    var snapshot = Data()
    var readError: Error?
    NSFileCoordinator().coordinate(
      readingItemAt: url, options: .withoutChanges, error: &coordinatorError
    ) { coordinatedURL in
      do {
        // Read an owned snapshot; a memory mapping could reflect external changes later.
        snapshot = try Data(contentsOf: coordinatedURL, options: .uncached)
      } catch {
        readError = error
      }
    }
    if let coordinatorError { throw coordinatorError }
    if let readError { throw readError }
    guard snapshot.count <= SPDFDocumentResourcePolicy.maximumPDFBytes else {
      throw PDFError(.limitExceeded, "This file exceeds the current 256 MiB opening limit")
    }
    try sourceStore.load(snapshot)
    if let source = sourceStore.snapshot() { editSession.load(source) }
    sourceFingerprint = SourceFingerprint.capture(of: url)
  }

  nonisolated override func read(from data: Data, ofType typeName: String) throws {
    guard data.count <= SPDFDocumentResourcePolicy.maximumPDFBytes else {
      throw PDFError(.limitExceeded, "This file exceeds the current 256 MiB opening limit")
    }
    try sourceStore.load(data)
    if let source = sourceStore.snapshot() { editSession.load(source) }
  }

  // MARK: - Recovery and view state (P10-016–P10-023)

  static func makeRecoveryStore() -> RecoveryStore {
    RecoveryStore(
      policy: RecoveryPolicy(
        directory: recoveryBaseDirectory().appendingPathComponent("Recovery", isDirectory: true)))
  }

  static func makeViewStateStore() -> ViewStateStore {
    ViewStateStore(
      directory: recoveryBaseDirectory().appendingPathComponent("ViewState", isDirectory: true))
  }

  static func makeUpdateRelaunchStore() -> UpdateRelaunchStore {
    UpdateRelaunchStore(
      directory: recoveryBaseDirectory().appendingPathComponent("UpdateRelaunch", isDirectory: true)
    )
  }

  private static func recoveryBaseDirectory() -> URL {
    if let override = recoveryDirectoryOverride { return override }
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    #if SPDF_UPDATER_ACCEPTANCE
      return base.appendingPathComponent("sPDF Updater Acceptance", isDirectory: true)
    #else
      return base.appendingPathComponent("sPDF Editor", isDirectory: true)
    #endif
  }

  /// P10-022: the key follows the file's identity across moves and renames.
  var recoveryKey: String {
    recoveredRecoveryKey
      ?? (fileURL == nil ? untitledRecoveryKey : RecoveryStore.documentKey(for: fileURL))
  }

  /// P10-016: bounded autosave — snapshot a dirty session at most once per
  /// policy interval, or on demand.
  func snapshotRecoveryIfNeeded(force: Bool = false) {
    // P28-024: protected documents never write recovery snapshots, because a
    // snapshot would place decrypted content on disk outside the document's
    // protection. Their records are also purged on save and lock.
    guard !editSession.isProtected else { return }
    let now = Date()
    if !force, let last = lastRecoverySnapshotAt,
      now.timeIntervalSince(last) < recoveryStore.policy.autosaveInterval
    {
      return
    }
    guard editSession.canEdit, editSession.isDirty else { return }
    lastRecoverySnapshotAt = now
    _ = try? WorkspacePerformance.profile("recovery-snapshot") {
      try recoveryStore.snapshot(
        session: editSession, key: recoveryKey, originalURL: fileURL, now: now)
    }
  }

  func snapshotRecoveryNow() {
    snapshotRecoveryIfNeeded(force: true)
  }

  /// P10-021: discard recovery state after a verified save.
  func discardRecoveryRecords(for key: String? = nil) {
    try? recoveryStore.discard(for: key ?? recoveryKey)
    recoveredRecoveryKey = nil
    lastRecoverySnapshotAt = nil
  }

  /// P10-020: open recovered unsaved edits as a dirty untitled document.
  func loadRecovered(_ data: Data, recoveryKey: String? = nil) throws {
    let source = try PDFSource(data: data)
    try sourceStore.load(data)
    recoveredRecoveryKey = recoveryKey
    editSession.load(source)
    undoManager?.removeAllActions()
    updateChangeCount(.changeReadOtherContents)
    if windowControllers.isEmpty {
      makeWindowControllers()
    } else if let viewer {
      refreshViewer(preservingPage: 1)
    }
  }

  func captureViewState() -> ViewState? {
    guard let viewer else { return nil }
    let frame = windowControllers.first?.window?.frame ?? .zero
    let mode = viewer.sidebarMode.storedName
    // P12-019: the sidebar width is captured from the laid-out thumbnails
    // view (HSplitView divider drags report nowhere else); zero means the
    // width was never laid out and restores as automatic.
    let sidebarWidth = viewer.sidebarWidth > 0
      ? viewer.sidebarWidth : Double(viewer.thumbnails.frame.width)
    return ViewState(
      windowFrame: [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height],
      pageNumber: viewer.pageNumber, scale: viewer.scale,
      sidebarVisible: viewer.isSidebarVisible, sidebarMode: mode,
      sidebarWidth: sidebarWidth > 1 ? sidebarWidth : 0,
      continuous: viewer.view.displayMode == .singlePageContinuous)
  }

  func saveViewState(viewer: PDFViewingSession) {
    guard let state = captureViewState() else { return }
    try? viewStateStore.save(state, for: recoveryKey)
  }

  func adoptRestoredFileAccess(_ url: URL, accessing: Bool) {
    guard accessing else { return }
    if restoredFileAccess == nil {
      restoredFileAccess = url
    } else {
      url.stopAccessingSecurityScopedResource()
    }
  }

  /// P10-023: restore window and navigation state without replaying edits.
  func restoreViewState(viewer: PDFViewingSession) {
    guard let state = viewStateStore.load(for: recoveryKey) else { return }
    applyViewState(state)
  }

  func applyViewState(_ state: ViewState) {
    guard let viewer else { return }
    // A locked PDF cannot navigate to its saved page yet. Keep metadata
    // until the existing password/keychain decision unlocks its viewer.
    pendingUnlockedViewState = viewer.isLocked ? state : nil
    viewer.isSidebarVisible = state.sidebarVisible
    viewer.sidebarMode = SidebarMode(storedName: state.sidebarMode) ?? .pages
    viewer.setContinuous(state.continuous)
    if state.sidebarWidth > 1 {
      viewer.sidebarWidth = state.sidebarWidth
    }
    if !viewer.isLocked, state.pageNumber > 0 {
      viewer.go(to: min(state.pageNumber, max(1, viewer.pageCount)))
    }
    if !viewer.isLocked, state.scale > 0 {
      viewer.view.autoScales = false
      viewer.view.scaleFactor = max(
        viewer.view.minScaleFactor, min(viewer.view.maxScaleFactor, state.scale))
    }
    if state.windowFrame.count == 4, state.windowFrame.allSatisfy(\.isFinite),
      let window = windowControllers.first?.window
    {
      let frame = NSRect(
        x: state.windowFrame[0], y: state.windowFrame[1], width: state.windowFrame[2],
        height: state.windowFrame[3])
      if frame.width > 200, frame.height > 150 {
        window.setFrame(frame, display: false)
      }
    }
    viewer.synchronizeViewState()
  }

  nonisolated override func data(ofType typeName: String) throws -> Data {
    try editSession.bytesForSave()
  }

  override func save(_ sender: Any?) {
    guard finishPendingEdits() else { return }
    super.save(sender)
  }

  override func saveAs(_ sender: Any?) {
    guard finishPendingEdits() else { return }
    super.saveAs(sender)
  }

  /// Mark the saved revision only after the destination write succeeded;
  /// canceled or failed saves leave the document dirty.
  override func save(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
    completionHandler: @escaping (Error?) -> Void
  ) {
    // A verified atomic replacement changes the destination inode. Keep the
    // key used by the edits until their save has actually succeeded.
    let savedRecoveryKey = recoveryKey
    if saveOperation == .saveOperation, destinationChangedExternally(),
      !confirmExternallyModifiedSave()
    {
      completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
      return
    }
    let revision = editSession.documentRevision
    let job = jobCenter.start(title: "Saving document", total: 1)
    super.save(to: url, ofType: typeName, for: saveOperation) { [editSession] error in
      let savedCurrentRevision = error == nil && editSession.noteSaved(ifRevisionIs: revision)
      Task { @MainActor [weak self] in
        guard let self else { return }
        if error == nil {
          if savedCurrentRevision { discardRecoveryRecords(for: savedRecoveryKey) }
          // An edit made during an asynchronous write still needs saving.
          if !savedCurrentRevision { updateChangeCount(.changeDone) }
          if let url = fileURL {
            sourceFingerprint = SourceFingerprint.capture(of: url)
          }
        }
        jobCenter.finish(id: job)
        refreshWorkspaceActions()
      }
      completionHandler(error)
    }
  }

  /// P10-009/P10-010: write through a verified temporary file on the
  /// destination filesystem before atomically replacing the document.
  override func write(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
    originalContentsURL: URL?
  ) throws {
    let data = try editSession.bytesForSave()
    if editSession.isProtected {
      // P28-020: protected output cannot be reparsed without the password, so
      // the session verifies it against the decrypted graph while the
      // destination write keeps the atomic verified path.
      try VerifiedFileWriter.write(data, to: url) { [editSession] written in
        try editSession.verifyProtectedOutput(written)
      }
      return
    }
    let expected =
      try editSession.graphForSaveVerification
      ?? PDFParser.parse(data, limits: SPDFDocumentResourcePolicy.parsingLimits).graph
    try VerifiedFileWriter.write(
      data, to: url, expectedGraph: expected,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
  }

  /// P10-012: whether the destination changed on disk since it was loaded.
  func destinationChangedExternally() -> Bool {
    guard let fileURL, let sourceFingerprint else { return false }
    return !sourceFingerprint.matches(fileURL)
  }

  /// P10-013: reload/keep/duplicate conflict workflow with clear
  /// consequences. Returns true when the save should proceed.
  private func confirmExternallyModifiedSave() -> Bool {
    let alert = NSAlert()
    alert.messageText = "This document changed on disk"
    alert.informativeText =
      "Another application modified the file. Reload discards your edits, Keep overwrites "
      + "the file with your edits, and Save As… keeps both."
    alert.addButton(withTitle: "Keep My Edits")
    alert.addButton(withTitle: "Reload From Disk")
    alert.addButton(withTitle: "Save As…")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return true
    case .alertSecondButtonReturn:
      if let fileURL, let type = fileType {
        try? revert(toContentsOf: fileURL, ofType: type)
        sourceFingerprint = SourceFingerprint.capture(of: fileURL)
      }
      return false
    case .alertThirdButtonReturn:
      saveAs(nil)
      return false
    default:
      return false
    }
  }

  override func makeWindowControllers() {
    guard let source = sourceStore.snapshot() else { return }
    undoManager?.removeAllActions()
    // PDF transactions already define their undo boundary. Do not leave a
    // registration waiting for the next event-loop turn before Save As.
    undoManager?.groupsByEvent = false
    let viewer = PDFViewingSession()
    do {
      try viewer.open(source)
    } catch {
      presentError(error)
      return
    }
    self.viewer = viewer
    viewer.onInkStroke = { [weak self] pageIndex, points in
      self?.addInkStroke(pageIndex: pageIndex, points: points)
    }
    viewer.pageMenuProvider = { [weak self] pageIndex, pagePoint in
      self?.imageContextMenu(pageIndex: pageIndex, pagePoint: pagePoint)
    }
    viewer.formFieldProvider = { [weak self] pageIndex, pagePoint in
      self?.formFieldTarget(pageIndex: pageIndex, pagePoint: pagePoint)
    }
    viewer.onFormFieldCommit = { [weak self] fieldName, text in
      self?.fillFormText(fieldName: fieldName, text: text) ?? false
    }
    viewer.textRunProvider = { [weak self] pageIndex, pagePoint in
      self?.textRunTarget(pageIndex: pageIndex, pagePoint: pagePoint)
    }
    viewer.textEditRefusalProvider = { [weak self] pageIndex, pagePoint in
      self?.textEditRefusal(pageIndex: pageIndex, pagePoint: pagePoint)
    }
    viewer.textTargetsProvider = { [weak self] pageIndex in
      self?.textRunTargets(pageIndex: pageIndex) ?? []
    }
    viewer.onTextRunCommit = { [weak self] pageIndex, runIndex, text in
      self?.replaceText(pageIndex: pageIndex, runIndex: runIndex, with: text) ?? false
    }
    viewer.onAddPageText = { [weak self] pageIndex, rect, text in
      self?.addPageText(pageIndex: pageIndex, rect: rect, text: text) ?? false
    }
    viewer.onTextBlockPreview = { [weak self] target in
      guard let self, self.canEditContent, let graph = self.editSession.currentGraph,
        self.editSession.pageIDs.indices.contains(target.pageIndex)
      else { return nil }
      var preview = graph
      do {
        if let paragraph = target.paragraph {
          preview = try PageTextEditing.hidingParagraph(
            pageID: self.editSession.pageIDs[target.pageIndex], originalText: paragraph.originalText,
            standardFontAdvances: paragraph.standardFontAdvances, in: preview)
        } else {
          for run in target.runIndices {
            preview = try PageTextEditing.hidingBlock(
              pageID: self.editSession.pageIDs[target.pageIndex], runIndex: run, in: preview)
          }
        }
        return try PDFWriter.write(
          preview, droppingLinearization: true, limits: SPDFDocumentResourcePolicy.parsingLimits)
      } catch { return nil }
    }
    viewer.onTextBlockCommit = { [weak self] target, text, style, dx, dy, lines, box in
      self?.commitTextBlock(target, text: text, style: style, dx: dx, dy: dy, lines: lines, box: box) ?? false
    }
    viewer.onNewTextBlockCommit = { [weak self] pageIndex, rect, text, style, lines, box in
      guard let self, self.canEditContent, self.editSession.pageIDs.indices.contains(pageIndex) else { return false }
      do {
        try self.editSession.apply(PDFTransaction([
          AddPageTextLinesCommand(pageID: self.editSession.pageIDs[pageIndex], lines: lines, box: box)
        ]))
        self.noteUserEdit()
        self.refreshViewer(preservingPage: pageIndex + 1)
        return true
      } catch { self.presentError(error); return false }
    }
    viewer.onPendingPageTextChange = { [weak self] changed in
      guard let self else { return }
      self.pendingPageText.hasChanges = changed
      self.refreshWorkspaceActions()
      for controller in self.windowControllers {
        controller.window?.isDocumentEdited = self.isDocumentEdited
      }
    }
    viewer.setContinuous(WorkspacePreferences.continuous)
    viewer.graphicTargetProvider = { [weak self] pageIndex, pagePoint in
      self?.graphicTarget(pageIndex: pageIndex, pagePoint: pagePoint)
    }
    viewer.graphicsListProvider = { [weak self] pageIndex in
      self?.graphicsList(pageIndex: pageIndex) ?? []
    }
    viewer.graphicRefusalProvider = { [weak self] pageIndex, pagePoint in
      self?.graphicRefusal(pageIndex: pageIndex, pagePoint: pagePoint)
    }
    viewer.onMoveGraphics = { [weak self] moves in
      _ = self?.moveGraphics(moves)
    }
    viewer.onResizeGraphics = { [weak self] resizes in
      _ = self?.resizeGraphics(resizes)
    }
    viewer.graphicPreviewProvider = { [weak self] resizes in
      self?.previewGraphics(resizes)
    }
    viewer.onRotateGraphic = { [weak self] target in
      _ = self?.rotateGraphic(target)
    }
    viewer.onDeleteGraphics = { [weak self] targets in
      guard let self, let pageIndex = targets.first?.pageIndex,
        let pageID = self.pageID(at: pageIndex),
        targets.allSatisfy({ $0.imagePlacementIndex == nil }) else { return }
      _ = self.applyImageTransaction([
        DeleteAddedGraphicsCommand(pageID: pageID, streamIDs: targets.map(\.streamID))
      ])
    }
    viewer.onInsertImage = { [weak self] in self?.promptInsertImage() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(
      rootView: WorkspaceView(
        viewer: viewer, documentState: workspaceDocumentState,
        onSave: { [weak self] in self?.save(nil) },
        onUndo: { NSApp.sendAction(NSSelectorFromString("undoEdit:"), to: NSApp.delegate, from: nil) },
        onRedo: { NSApp.sendAction(NSSelectorFromString("redoEdit:"), to: NSApp.delegate, from: nil) },
        onOpenDroppedFile: { [weak self] url in self?.openDroppedFile(url) },
        comments: commentsModel, forms: formsModel,
        signatures: signaturesModel, structure: structureModel,
        onSelectComment: { [weak self] comment in self?.navigate(to: comment) },
        onDeleteComment: { [weak self] comment in self?.deleteAnnotation(comment) },
        onReplyComment: { [weak self] comment in self?.addReply(to: comment) },
        onSetStateComments: { [weak self] comments, state in
          self?.setState(state, on: comments)
        },
        onSubmitFormText: { [weak self] name, text in
          self?.fillFormText(fieldName: name, text: text)
        },
        onDraftFormText: { [weak self] name, text in
          self?.stageFormTextDraft(fieldName: name, text: text)
        },
        onToggleForm: { [weak self] name, isOn in self?.setFormButton(fieldName: name, isOn: isOn)
        },
        onSelectFormChoice: { [weak self] name, exportValue in
          self?.setFormChoice(fieldName: name, exportValue: exportValue)
        },
        onSelectFormField: { [weak self] field in self?.navigate(to: field) },
        onSelectSignature: { [weak self] pageIndex in
          self?.navigate(toSignatureAt: pageIndex)
        },
        onSelectStructurePage: { [weak self] pageIndex in
          self?.viewer?.focus(onPageIndex: pageIndex, rect: [])
        },
        onEditStructureRole: { [weak self] elementID, role in
          _ = self?.setStructureRole(elementID: elementID, role: role)
        },
        onEditStructureAltText: { [weak self] elementID in
          self?.promptStructureAltText(elementID: elementID)
        },
        onMarkStructureArtifact: { [weak self] elementID in
          _ = self?.markStructureArtifact(elementID: elementID)
        },
        fonts: fontsModel,
        jobs: jobCenter,
        onProvisionFont: { [weak self] family in
          self?.provisionFont(family: family)
        },
        onSuggestStructureTags: { [weak self] in
          self?.suggestStructureTags()
        },
        onAcceptStructureSuggestion: { [weak self] id in
          self?.structureModel.review?.accept(id)
        },
        onRejectStructureSuggestion: { [weak self] id in
          self?.structureModel.review?.reject(id)
        },
        onApplyStructureSuggestions: { [weak self] in
          self?.applyAcceptedStructureSuggestions()
        },
        onDiscardStructureSuggestions: { [weak self] in
          self?.structureModel.review = nil
        },
        onOrganizePages: { [weak self] in self?.organizePages() },
        onInsertBlankPage: { [weak self] in self?.insertBlankPageAfterCurrent() },
        onRotateRight: { [weak self] in self?.rotateCurrentPage(byDegrees: 90) },
        onImageGeometry: { [weak self] page, placement, x, y, width, height in
          _ = self?.setImageGeometry(
            pageIndex: page, placementIndex: placement, x: x, y: y,
            width: width, height: height)
        },
        onImageFlip: { [weak self] page, placement, horizontal in
          _ = self?.flipImage(
            pageIndex: page, placementIndex: placement, horizontal: horizontal)
        },
        onImageRotate: { [weak self] page, placement, degrees in
          _ = self?.rotateImage(
            pageIndex: page, placementIndex: placement, degrees: degrees)
        },
        onHighlight: { [weak self] in self?.addAnnotationFromSelection(.highlight) },
        onNote: { [weak self] in self?.addAnnotationFromSelection(.note) }))
    // A plain AppKit content view owns the workspace dimensions. Keep the
    // hosting view inside it so SwiftUI cannot reset the window constraints
    // when a sidebar changes or the root is laid out again.
    hosting.sizingOptions = []
    let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.contentView = content
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    window.contentMinSize = NSSize(width: 860, height: 540)
    window.center()
    addWindowController(NSWindowController(window: window))
    restoreViewState(viewer: viewer)
    refreshWorkspaceActions()
    refreshComments()
    refreshForms()
    refreshFonts()
    refreshSignatures()
    refreshStructure()
    refreshDocumentInfo()
    // P28-022: a stored credential is used only when the user explicitly
    // asked to remember it; the preference is per document.
    if viewer.isLocked, let fileURL,
      let stored = KeychainCredentialStore.password(forDocumentAt: fileURL),
      viewer.unlock(password: stored)
    {
      unlockCoreSession(with: stored)
    }
    inspectionTask = Task { [weak self] in
      self?.coreInspection =
        try? await PDFInspector(
          limits: SPDFDocumentResourcePolicy.parsingLimits
        ).inspect(source)
    }
  }

  override func showWindows() {
    super.showWindows()
    (NSApp.delegate as? ApplicationDelegate)?.dismissWelcome()
  }

  // MARK: - Owned-core edits

  /// Rotate the page currently shown by the viewer through the canonical
  /// edit session, then refresh the rendered snapshot.
  func rotateCurrentPage(byDegrees degrees: Int) {
    guard canEditContent, let viewer, viewer.pageCount > 0 else { return }
    do {
      try editSession.rotatePage(at: viewer.pageNumber - 1, byDegrees: degrees)
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer.pageNumber)
  }

  /// PAG-05: crop pages non-destructively by margins from each page's own
  /// MediaBox. Units are converted to points before the single transaction.
  func presentCropPages() {
    guard canEditContent, let graph = editSession.currentGraph,
      let viewer, viewer.pageCount > 0
    else { return }
    let unit = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    unit.addItems(withTitles: ["Points", "Millimeters", "Inches"])
    let boxPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    boxPopup.addItems(withTitles: DocumentAssembly.PageBox.allCases.map(\.title))
    boxPopup.selectItem(at: 0)
    let margins = ["Left", "Bottom", "Right", "Top"].map { _ in
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
      field.stringValue = "0"
      return field
    }
    let pageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
    pageField.stringValue = "\(viewer.pageNumber)"
    var rows: [[NSView]] = [
      [NSTextField(labelWithString: "Box:"), boxPopup],
      [NSTextField(labelWithString: "Units:"), unit],
    ]
    for (label, field) in zip(["Left", "Bottom", "Right", "Top"], margins) {
      rows.append([NSTextField(labelWithString: "\(label) margin:"), field])
    }
    rows.append([NSTextField(labelWithString: "Pages:"), pageField])
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let alert = NSAlert()
    alert.messageText = "Page Boxes"
    alert.informativeText =
      "Margins are measured from each page's MediaBox. Crop changes the visible page box; "
      + "Trim, Bleed and Art are production boxes. No hidden content or image pixels are removed. "
      + "Use pages such as 1, 3-5. The change is one undo step."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Set Box")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let factor: Double = [1.0, 72.0 / 25.4, 72.0][max(0, unit.indexOfSelectedItem)]
    let kind = DocumentAssembly.PageBox.allCases[max(0, boxPopup.indexOfSelectedItem)]
    let values = margins.compactMap { Double($0.stringValue) }
    guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      NSSound.beep()
      return
    }
    let indices = pageIndices(from: pageField.stringValue, count: editSession.pageIDs.count)
    guard !indices.isEmpty else {
      NSSound.beep()
      return
    }
    let inventory = PrintPreflightInventory.inventory(graph, pageIDs: editSession.pageIDs)
    var boxes: [PDFObjectID: [Double]] = [:]
    for index in indices {
      guard let boxesForPage = inventory.pages.first(where: { $0.pageIndex == index })
      else { continue }
      let media = boxesForPage.mediaBox
      let box = [
        media[0] + values[0] * factor, media[1] + values[1] * factor,
        media[2] - values[2] * factor, media[3] - values[3] * factor,
      ]
      guard box[2] > box[0], box[3] > box[1] else {
        NSSound.beep()
        return
      }
      boxes[editSession.pageIDs[index]] = box
    }
    do {
      try editSession.apply(
        PDFTransaction([DocumentAssembly.SetPageBoxCommand(boxes: boxes, kind: kind)]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer.pageNumber)
  }

  /// PAG-06: add a watermark, header, footer, page number or Bates mark to
  /// explicit pages in one undoable transaction. Returns the preview plan that
  /// was committed.
  @discardableResult
  func addPageMark(
    _ mark: RepeatedMark, pageIDs: [PDFObjectID], margin: Double = 36
  ) -> RepeatedMarkPlan? {
    guard canEditContent, !pageIDs.isEmpty, let graph = editSession.currentGraph
    else { return nil }
    let command = AddRepeatedMarkCommand(
      pageIDs: pageIDs, mark: mark, margin: margin)
    do {
      let plan = try command.plan(in: graph)
      try editSession.apply(PDFTransaction([command]))
      noteUserEdit()
      refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
      return plan
    } catch {
      presentError(error)
      return nil
    }
  }

  /// PAG-06: dialog for the repeated-mark presets. The plan is shown before
  /// the command is committed.
  func presentAddPageMark() {
    guard canEditContent, let viewer, viewer.pageCount > 0 else { return }
    let types = ["Watermark", "Header", "Footer", "Page number", "Bates number"]
    let typePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    typePopup.addItems(withTitles: types)
    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
    textField.stringValue = "CONFIDENTIAL"
    let familyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    familyPopup.addItems(withTitles: ["Helvetica", "Times", "Courier"])
    let sizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    sizeField.stringValue = "48"
    let opacityField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    opacityField.stringValue = "0.2"
    let angleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    angleField.stringValue = "45"
    let colorPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    colorPopup.addItems(withTitles: ["Gray", "Black", "Red", "Blue"])
    let boldCheckbox = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
    let pageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
    pageField.stringValue = "1-\(viewer.pageCount)"
    let marginField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    marginField.stringValue = "36"
    let startField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    startField.stringValue = "1"
    let digitsField = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
    digitsField.stringValue = "6"
    let rows: [[NSView]] = [
      [NSTextField(labelWithString: "Type:"), typePopup],
      [NSTextField(labelWithString: "Text / prefix:"), textField],
      [NSTextField(labelWithString: "Font:"), familyPopup],
      [NSTextField(labelWithString: "Size:"), sizeField],
      [NSTextField(labelWithString: "Opacity:"), opacityField],
      [NSTextField(labelWithString: "Angle:") , angleField],
      [NSTextField(labelWithString: "Color:"), colorPopup],
      [NSGridCell.emptyContentView, boldCheckbox],
      [NSTextField(labelWithString: "Pages:"), pageField],
      [NSTextField(labelWithString: "Margin:"), marginField],
      [NSTextField(labelWithString: "Bates start:"), startField],
      [NSTextField(labelWithString: "Bates digits:"), digitsField],
    ]
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 360, height: 330)
    let dialog = NSAlert()
    dialog.messageText = "Add Page Mark"
    dialog.informativeText =
      "Header, footer and page-number marks use the margin; watermarks are centered. "
      + "Page numbers support {page} and {pages}. One undo step covers every selected page."
    dialog.accessoryView = grid
    dialog.addButton(withTitle: "Preview")
    dialog.addButton(withTitle: "Cancel")
    guard dialog.runModal() == .alertFirstButtonReturn else { return }

    let size = Double(sizeField.stringValue) ?? 48
    let opacity = Double(opacityField.stringValue) ?? 0.2
    let angle = Double(angleField.stringValue) ?? 45
    let margin = Double(marginField.stringValue) ?? 36
    let start = Int(startField.stringValue) ?? 1
    let digits = Int(digitsField.stringValue) ?? 6
    let colors: [[Double]] = [
      [0.35, 0.35, 0.35], [0, 0, 0], [0.7, 0, 0], [0, 0.2, 0.7],
    ]
    let family: AddedTextStyle.Family = [
      AddedTextStyle.Family.helvetica, .times, .courier,
    ][max(0, familyPopup.indexOfSelectedItem)]
    let alignment: TextParagraphCandidate.Alignment =
      typePopup.indexOfSelectedItem <= 2
      ? .center
      : (typePopup.indexOfSelectedItem == 3 ? .center : .left)
    let style = AddedTextStyle(
      family: family, bold: boldCheckbox.state == .on, size: size,
      color: colors[max(0, colorPopup.indexOfSelectedItem)], alignment: alignment,
      opacity: min(1, max(0, opacity)))
    let rawText = textField.stringValue
    let text = rawText.isEmpty ? "CONFIDENTIAL" : rawText
    let mark: RepeatedMark
    switch typePopup.indexOfSelectedItem {
    case 1: mark = .header(text: text, style: style)
    case 2: mark = .footer(text: text, style: style)
    case 3: mark = .pageNumber(text: text.contains("{page}") ? text : "Page {page} of {pages}", style: style, offset: 0)
    case 4: mark = .bates(prefix: text, start: start, digits: digits, style: style)
    default: mark = .watermark(text: text, style: style, angle: angle)
    }
    let indices = pageIndices(from: pageField.stringValue, count: editSession.pageIDs.count)
    guard !indices.isEmpty else {
      NSSound.beep()
      return
    }
    let pageIDs = indices.map { editSession.pageIDs[$0] }
    guard let graph = editSession.currentGraph else { return }
    let command = AddRepeatedMarkCommand(
      pageIDs: pageIDs, mark: mark, margin: max(0, margin))
    let plan: RepeatedMarkPlan
    do {
      plan = try command.plan(in: graph)
    } catch {
      presentError(error)
      return
    }
    let preview = NSAlert()
    preview.messageText = "Preview: \(types[max(0, typePopup.indexOfSelectedItem)])"
    var detail = plan.summary
    for page in plan.pages.prefix(6) {
      detail += "\nPage \(page.pageIndex + 1): \(page.text)"
    }
    if plan.pages.count > 6 { detail += "\n…" }
    preview.informativeText = detail
    preview.addButton(withTitle: "Apply")
    preview.addButton(withTitle: "Cancel")
    guard preview.runModal() == .alertFirstButtonReturn else { return }
    _ = addPageMark(mark, pageIDs: pageIDs, margin: max(0, margin))
  }

  /// Parse a 1-based page list such as `1, 3-5` into zero-based indices.
  private func pageIndices(from spec: String, count: Int) -> [Int] {
    var result = Set<Int>()
    for part in spec.split(separator: ",") {
      let text = part.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      if let dash = text.firstIndex(of: "-") {
        guard let first = Int(text[..<dash]),
          let last = Int(text[text.index(after: dash)...])
        else { continue }
        for page in min(first, last)...max(first, last) where (1...count).contains(page) {
          result.insert(page - 1)
        }
      } else if let page = Int(text), (1...count).contains(page) {
        result.insert(page - 1)
      }
    }
    return result.sorted()
  }

  /// Move the current page by `offset` positions (negative moves it up).
  func moveCurrentPage(by offset: Int) {
    guard canEditContent, let viewer, viewer.pageCount > 0 else { return }
    let index = viewer.pageNumber - 1
    let target = index + offset
    guard target >= 0, target < viewer.pageCount else { return }
    do {
      try editSession.movePage(at: index, to: target)
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: target + 1)
  }

  /// Insert a blank page after the current one, matching its MediaBox size.
  func insertBlankPageAfterCurrent() {
    guard canEditContent, let viewer, viewer.pageCount > 0 else { return }
    let index = viewer.pageNumber - 1
    let box = editSession.pageMediaBox(at: index) ?? [0, 0, 612, 792]
    let width = box.count >= 4 ? max(1, box[2] - box[0]) : 612
    let height = box.count >= 4 ? max(1, box[3] - box[1]) : 792
    do {
      try editSession.insertBlankPage(at: index + 1, width: width, height: height)
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: index + 2)
  }

  /// Delete the current page after an explicit confirmation.
  func deleteCurrentPage() {
    guard canEditContent, let viewer, viewer.pageCount > 1 else { return }
    let alert = NSAlert()
    alert.messageText = "Delete this page?"
    alert.informativeText =
      "The page is removed from the document. Undo can restore it until later edits replace that history."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let index = viewer.pageNumber - 1
    do {
      try editSession.deletePage(at: index)
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    let remaining = editSession.pageIDs.count
    refreshViewer(preservingPage: min(index + 1, max(1, remaining)))
  }

  // MARK: - Native undo integration (P17-007)

  /// P17-007: every committed user edit registers one native undo action
  /// with `NSDocument.undoManager`. The action drives the session's bounded
  /// stack, so the manager and the session can never disagree about the
  /// latest edit; direct session edits (scripts, tests) keep the fallback
  /// path in `undoEdit()`/`redoEdit()`.
  private func noteUserEdit() {
    defer { refreshWorkspaceActions() }
    // NSDocument observes this manager's groups and updates its change count
    // itself. Explicitly incrementing as well counts each native edit twice.
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    // Each closure performs exactly one session step and only when the
    // session is still at the revision it was registered for: if AppKit's
    // event grouping coalesces several registrations into one action, the
    // stale closures no-op and a single undo remains a single step.
    let revision = editSession.documentRevision
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performSessionUndo(registeredRevision: revision)
    }
    undoManager.setActionName("Edit")
    undoManager.endUndoGrouping()
  }

  private func performSessionUndo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision {
      return
    }
    guard editSession.undo() else { return }
    // registerUndo during an undo becomes the redo action.
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performSessionRedo(registeredRevision: revision)
    }
    undoManager?.setActionName("Edit")
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  private func performSessionRedo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision {
      return
    }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performSessionUndo(registeredRevision: revision)
    }
    undoManager?.setActionName("Edit")
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  @discardableResult
  func undoEdit() -> Bool {
    guard canEditContent else { return false }
    if viewer?.isEditingPageText == true, viewer?.pageTextUndo?() == true { return true }
    if viewer?.isEditingPageText == true, !(viewer?.pendingEditFinisher?() ?? true) { return false }
    // The manager is the app's undo surface; each of its actions performs
    // exactly one session step. An entry that no longer matches live history
    // (for example after a reload discarded the stack) no-ops, and the
    // direct fallback below still serves session-only edits.
    if let undoManager, undoManager.canUndo {
      let before = editSession.documentRevision
      undoManager.undo()
      if editSession.documentRevision != before { return true }
    }
    guard editSession.undo() else { return false }
    updateChangeCount(.changeUndone)
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
    return true
  }

  @discardableResult
  func redoEdit() -> Bool {
    guard canEditContent else { return false }
    if viewer?.isEditingPageText == true, viewer?.pageTextRedo?() == true { return true }
    if viewer?.isEditingPageText == true, !(viewer?.pendingEditFinisher?() ?? true) { return false }
    if let undoManager, undoManager.canRedo {
      let before = editSession.documentRevision
      undoManager.redo()
      if editSession.documentRevision != before { return true }
    }
    guard editSession.redo() else { return false }
    updateChangeCount(.changeDone)
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
    return true
  }

  // MARK: - Annotations and comments

  /// P12-012 annotation slice: create markup from the viewer's current text
  /// selection. Author and subject are never collected automatically
  /// (P22-013 privacy default); only the timestamp and the selected text are
  /// recorded.
  var canAnnotateSelection: Bool {
    guard let viewer, !viewer.isLocked, canEditContent else { return false }
    return viewer.view.currentSelection != nil
  }

  func addAnnotationFromSelection(_ kind: AnnotationKind) {
    guard canEditContent, let viewer, let document = viewer.view.document,
      let selection = viewer.view.currentSelection,
      let page = selection.pages.first
    else { return }
    let index = document.index(for: page)
    guard index >= 0, index < editSession.pageIDs.count else { return }
    let bounds = selection.bounds(for: page)
    guard bounds.width > 0.5, bounds.height > 0.5 else { return }
    let pageID = editSession.pageIDs[index]
    let quads = AddHighlightCommand.quads(forClusterBounds: [
      [
        bounds.minX, bounds.minY, bounds.maxX, bounds.maxY,
      ]
    ])
    let modified = Self.pdfDateString(Date())
    let contents = selection.string
    let command: any PDFEditCommand
    switch kind {
    case .highlight:
      command = AddHighlightCommand(
        pageID: pageID, quads: quads, contents: contents, modified: modified)
    case .underline:
      command = AddTextMarkupCommand(
        pageID: pageID, style: .underline, quads: quads, contents: contents, modified: modified)
    case .strikeout:
      command = AddTextMarkupCommand(
        pageID: pageID, style: .strikeout, quads: quads, contents: contents, modified: modified)
    case .note:
      let text = (contents?.isEmpty == false) ? contents! : "Note"
      command = AddNoteCommand(
        pageID: pageID, at: [bounds.maxX + 6, bounds.maxY - 20], contents: text,
        modified: modified)
    }
    do {
      try editSession.apply(PDFTransaction([command]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer.pageNumber)
  }

  // MARK: - Protected documents (P28-020–P28-024)

  var canLockDocument: Bool { editSession.isProtected }

  /// P28-020/P28-021: after the viewer unlocks, load the owned-core session
  /// with the same password. Editing follows the document's operation policy;
  /// the password itself is not retained.
  func unlockCoreSession(with password: String) {
    guard let source = sourceStore.snapshot() else { return }
    do {
      try editSession.loadProtected(source, password: password)
    } catch {
      presentError(error)
      return
    }
    refreshComments()
    refreshForms()
    // Loading the core has not edited the file. Keep PDFKit's unlocked
    // original document and its permission policy instead of reopening
    // encrypted save bytes (which would immediately lock it again).
    _ = viewer?.unlock(password: password)
    refreshFonts()
    refreshDocumentInfo()
    if let state = pendingUnlockedViewState { applyViewState(state) }
  }

  /// P28-023: lock the document again, releasing the decrypted graph and file
  /// key. Unsaved changes are confirmed and discarded.
  func lockDocument() {
    guard editSession.isProtected else { return }
    if editSession.isDirty {
      let alert = NSAlert()
      alert.messageText = "Lock this document?"
      alert.informativeText =
        "Unsaved changes will be discarded and the document returns to its protected state."
      alert.addButton(withTitle: "Lock")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    editSession.lockSession()
    discardRecoveryRecords()
    if let source = sourceStore.snapshot() {
      try? viewer?.open(source)
    }
    refreshComments()
    refreshForms()
    refreshViewer(preservingPage: 1)
  }

  // MARK: - Comparison (P32)

  var canCompareDocuments: Bool { viewer != nil }

  /// P32-001/P32-022: compare the current document against another file and
  /// return the change list; comparison never merges or modifies either side.
  func compareWithDocument(at url: URL) throws -> PDFComparisonResult {
    guard let source = sourceStore.snapshot(), let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "The document has no editable graph")
    }
    let otherData = try SPDFDocumentResourcePolicy.readPDFData(at: url)
    let other = try PDFParser.parse(otherData, limits: SPDFDocumentResourcePolicy.parsingLimits)
    return try PDFComparison.compare(
      left: (graph, source.data), right: (other.graph, otherData),
      limits: SPDFDocumentResourcePolicy.parsingLimits)
  }

  /// P32-002: the open comparison workspace, when any.
  private(set) var comparisonSession: ComparisonSession?
  private var comparisonWindowController: NSWindowController?

  /// The comparison workspace window, when open.
  var comparisonWindow: NSWindow? { comparisonWindowController?.window }

  /// P32-002/P32-003: open the comparison workspace against another file.
  /// The workspace follows the explicit page mapping; nothing is merged.
  @discardableResult
  func openComparisonWindow(with url: URL) throws -> ComparisonSession {
    guard let source = sourceStore.snapshot(), let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "The document has no editable graph")
    }
    let otherData = try SPDFDocumentResourcePolicy.readPDFData(at: url)
    let other = try PDFParser.parse(otherData, limits: SPDFDocumentResourcePolicy.parsingLimits)
    let session = try ComparisonSession(
      left: (graph, source.data), right: (other.graph, otherData),
      limits: SPDFDocumentResourcePolicy.parsingLimits)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title =
      "Comparison — \(fileURL?.lastPathComponent ?? "document") vs \(url.lastPathComponent)"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ComparisonWindowView(
        session: session,
        onSaveReport: { [weak self] in self?.saveComparisonReport() }))
    let controller = NSWindowController(window: window)
    addWindowController(controller)
    comparisonSession = session
    comparisonWindowController = controller
    window.center()
    controller.showWindow(nil)
    return session
  }

  /// P32-022/P32-028: the local report contains changed snippets only.
  func saveComparisonReport() {
    guard let session = comparisonSession else { return }
    let panel = NSSavePanel()
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-comparison.txt"
    panel.allowedContentTypes = [.plainText]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try Data(session.reportText().utf8).write(to: url, options: .atomic)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// P32-002: pick another document and open the comparison workspace.
  func presentCompareWith() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try openComparisonWindow(with: url)
    } catch {
      presentError(error)
    }
  }

  // MARK: - Optimization (P31)

  var canOptimizeDocument: Bool {
    viewer != nil && !editSession.isProtected && !hasSignatures
  }

  /// P31-019/P31-020/P31-024: lossless optimization into a new file. The
  /// original document is never touched, and an output that would not be
  /// smaller is not written. Options keep metadata removal separate from
  /// ordinary compression (P31-021).
  @discardableResult
  func optimizeDocument(
    to url: URL, options: PDFOptimizationOptions = PDFOptimizationOptions()
  ) throws -> PDFOptimizationReport {
    let graph = try prepareDerivative(to: url)
    let sourceBytes = (try? editSession.bytesForSave().count) ?? 0
    let (_, data, report) = try PDFOptimizer.lossless(
      graph, options: options, sourceBytes: sourceBytes,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
    guard report.isImprovement else { return report }
    try VerifiedFileWriter.write(data, to: url) { written in
      let reparsed = try PDFParser.parse(
        written, limits: SPDFDocumentResourcePolicy.parsingLimits)
      guard reparsed.pageCount == editSession.pageIDs.count else {
        throw PDFError(.malformed, "Optimized output failed verification")
      }
    }
    return report
  }

  /// P31-019/P31-021: show before/after sizes and the transformations before
  /// any destination is written; metadata removal is an explicit checkbox.
  func presentOptimizeDocument() {
    guard finishPendingEdits() else { return }
    guard let graph = editSession.currentGraph else { return }
    let sourceBytes = (try? editSession.bytesForSave().count) ?? 0
    let preview: (graph: PDFGraph, data: Data, report: PDFOptimizationReport)
    do {
      preview = try PDFOptimizer.lossless(
        graph, options: PDFOptimizationOptions(), sourceBytes: sourceBytes,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
    } catch {
      presentError(error)
      return
    }
    let metadataCheckbox = NSButton(
      checkboxWithTitle: "Also remove document metadata (Info and XMP)", target: nil, action: nil)
    metadataCheckbox.state = .off
    let alert = NSAlert()
    alert.messageText = "Optimize Document"
    var text = preview.report.summary
    if preview.report.isImprovement {
      text += "\n\nThe optimized copy is written as a new file; the original stays untouched."
    } else {
      text += "\n\nThe output would not be smaller, so nothing will be written."
    }
    alert.informativeText = text
    alert.accessoryView = metadataCheckbox
    alert.addButton(withTitle: preview.report.isImprovement ? "Save Optimized Copy…" : "OK")
    if preview.report.isImprovement { alert.addButton(withTitle: "Cancel") }
    guard alert.runModal() == .alertFirstButtonReturn, preview.report.isImprovement else { return }

    let options = PDFOptimizationOptions(removeMetadata: metadataCheckbox.state == .on)
    let data: Data
    let report: PDFOptimizationReport
    do {
      let result = try PDFOptimizer.lossless(
        graph, options: options, sourceBytes: sourceBytes,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
      data = result.data
      report = result.report
    } catch {
      presentError(error)
      return
    }
    guard report.isImprovement else { return }
    let panel = NSSavePanel()
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-optimized.pdf"
    panel.allowedContentTypes = [.pdf]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try VerifiedFileWriter.write(data, to: url) { written in
          let reparsed = try PDFParser.parse(
            written, limits: SPDFDocumentResourcePolicy.parsingLimits)
          guard reparsed.pageCount == self.editSession.pageIDs.count else {
            throw PDFError(.malformed, "Optimized output failed verification")
          }
        }
      } catch {
        self.presentError(error)
      }
    }
  }

  // MARK: - Signing (P30-016–P30-020)

  var canSignDocument: Bool {
    viewer != nil && !editSession.isProtected
  }

  /// P30-019/P30-020: signs the document into a new file. Unmodified
  /// documents are signed with an incremental revision so the original bytes
  /// are preserved exactly; documents with unsaved edits are signed as a full
  /// rewrite. The private key never leaves the keychain identity.
  func signDocument(to url: URL, identity: SecIdentity, options: PDFSigningOptions) throws {
    let data: Data
    if !editSession.isDirty, let source = sourceStore.snapshot() {
      let parsed = try PDFParser.parse(
        source.data, limits: SPDFDocumentResourcePolicy.parsingLimits)
      data = try PDFSigningWriter.signIncremental(
        parsed, identity: identity, options: options,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
    } else {
      guard let graph = editSession.currentGraph else {
        throw PDFError(.malformed, "The document has no editable graph")
      }
      data = try PDFSigningWriter.sign(
        graph, identity: identity, options: options,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
    }
    try VerifiedFileWriter.write(data, to: url) { written in
      let parsed = try PDFParser.parse(
        written, limits: SPDFDocumentResourcePolicy.parsingLimits)
      let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
      guard !signatures.isEmpty else {
        throw PDFError(.malformed, "The signed copy has no signature")
      }
    }
  }

  /// P30-016: pick a keychain identity explicitly and place the signature on
  /// the current page.
  func presentSignDocument() {
    let identities = PDFSigningIdentity.availableIdentities()
    guard !identities.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Signing Identities"
      alert.informativeText =
        "No code-signing or S/MIME identities were found in the keychain."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
    for available in identities { popup.addItem(withTitle: available.commonName) }
    let fieldName = NSTextField(string: "Signature1")
    let reason = NSTextField(string: "")
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Identity:"), popup],
      [NSTextField(labelWithString: "Field name:"), fieldName],
      [NSTextField(labelWithString: "Reason:"), reason],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 460, height: 84)
    let alert = NSAlert()
    alert.messageText = "Sign Document"
    alert.informativeText =
      "The signature is created from the selected keychain identity; the private key never "
      + "leaves the system keychain. The signed copy is written as a new file."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let index = popup.indexOfSelectedItem
    guard index >= 0, index < identities.count else { return }
    let identity = identities[index].identity
    let options = PDFSigningOptions(
      fieldName: fieldName.stringValue.isEmpty ? "Signature1" : fieldName.stringValue,
      pageIndex: max(0, (viewer?.pageNumber ?? 1) - 1),
      reason: reason.stringValue.isEmpty ? nil : reason.stringValue)
    let panel = NSSavePanel()
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-signed.pdf"
    panel.allowedContentTypes = [.pdf]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try self.signDocument(to: url, identity: identity, options: options)
      } catch {
        self.presentError(error)
      }
    }
  }

  // MARK: - Redaction and sanitization (P27)

  /// P27-001/P27-002: whether the current selection can be redacted.
  var canRedactSelection: Bool {
    guard let viewer, !viewer.isLocked, canEditContent else { return false }
    return viewer.view.currentSelection != nil
  }

  /// P27-003/P27-005/P27-012/P27-013: redact the current selection. PDFKit
  /// reports selection bounds in unrotated content space (verified by test),
  /// so no rotation mapping is needed. Confirmed first because content is
  /// removed.
  func redactSelection() {
    guard canEditContent, let viewer, let document = viewer.view.document,
      let selection = viewer.view.currentSelection
    else { return }
    var commands: [any PDFEditCommand] = []
    for page in selection.pages {
      let index = document.index(for: page)
      guard index >= 0, index < editSession.pageIDs.count else { continue }
      let bounds = selection.bounds(for: page)
      guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
      commands.append(
        RedactRegionsCommand(
          pageID: editSession.pageIDs[index],
          regions: [[bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]]))
    }
    guard !commands.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Redact the selected content?"
    alert.informativeText =
      "Redaction removes the selected text, images, and marks from the document. "
      + "The edit can be undone until the document is saved. Saving writes a full rewrite, "
      + "so the removed content is not retained in an earlier revision."
    alert.addButton(withTitle: "Redact")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard applyImageTransaction(commands) else { return }
    viewer.view.setCurrentSelection(nil, animate: false)
  }

  /// Applies region redaction to explicit page-space regions. Shared by the
  /// selection flow and the smoke test.
  @discardableResult
  func applyRedaction(pageIndex: Int, regions: [[Double]]) -> Bool {
    guard pageIndex >= 0, pageIndex < editSession.pageIDs.count else { return false }
    return applyImageTransaction([
      RedactRegionsCommand(pageID: editSession.pageIDs[pageIndex], regions: regions)
    ])
  }

  /// P27-001/P27-022/P27-023: apply whole-document sanitization (prune every
  /// object unreachable from the trailer) to the session.
  @discardableResult
  func applySanitize() -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(PDFTransaction([SanitizeDocumentCommand()]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    return true
  }

  /// SAF-01: build a sanitized derivative from the current graph and write it
  /// through a verified temporary file. The session graph is not mutated. The
  /// copy is always a full rewrite with no earlier revisions, and the report
  /// states what the policy removed and what it deliberately kept.
  @discardableResult
  func writeSanitizedCopy(
    to url: URL, policy: SanitizerPolicy = .sanitizedCopy
  ) throws -> SanitizerReport {
    let graph = try prepareDerivative(to: url)
    let prepared = try SanitizedCopyBuilder.prepare(
      graph, policy: policy, limits: SPDFDocumentResourcePolicy.parsingLimits)
    let data = try PDFWriter.write(
      prepared.graph, limits: SPDFDocumentResourcePolicy.parsingLimits)
    try VerifiedFileWriter.write(
      data, to: url, expectedGraph: prepared.graph,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
    return prepared.report
  }

  func saveSanitizedCopy() {
    guard canEditContent, finishPendingEdits() else { return }
    let policy = SanitizerPolicy.sanitizedCopy
    let confirmation = NSAlert()
    confirmation.messageText = "Save Sanitized Copy"
    var disclosure = "The copy removes document metadata, document scripts, and embedded files. "
    if !policy.removeOptionalContent {
      disclosure += "Optional-content layers are kept and will be reported. "
    }
    disclosure +=
      "Earlier revisions and unreachable objects are not copied. The original document is not modified."
    confirmation.informativeText = disclosure
    confirmation.addButton(withTitle: "Choose Destination…")
    confirmation.addButton(withTitle: "Cancel")
    guard confirmation.runModal() == .alertFirstButtonReturn else { return }

    let panel = NSSavePanel()
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-sanitized.pdf"
    panel.allowedContentTypes = [.pdf]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        let report = try self.writeSanitizedCopy(to: url, policy: policy)
        self.presentSanitizedCopyReport(report, destination: url)
      } catch {
        self.presentError(error)
      }
    }
  }

  private func presentSanitizedCopyReport(_ report: SanitizerReport, destination: URL) {
    let alert = NSAlert()
    alert.messageText = "Sanitized copy saved"
    var lines = "Saved to \(destination.lastPathComponent).\n\n" + report.summary
    if !report.retained.isEmpty {
      lines += "\n\nKept by policy: \(report.retainedSummary)."
    }
    lines +=
      "\n\nThe copy contains no earlier revisions or unreachable objects. "
      + "The original document was not modified."
    alert.informativeText = lines
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  // MARK: - Encrypted export (P28-016–P28-019)

  /// Writes the current session graph as a new AES-256 (V5/R6) encrypted copy
  /// through a verified temporary file. The password is used only to derive
  /// the dictionary for this export; it is never logged or retained.
  func writeEncryptedCopy(
    to url: URL, userPassword: String, ownerPassword: String? = nil,
    permissions: Int32 = -4, encryptMetadata: Bool = true,
    unencryptedEmbeddedFiles: Bool = false
  ) throws {
    let graph = try prepareDerivative(to: url, allowProtected: true)
    let data = try PDFWriter.write(
      graph,
      encryption: PDFEncryptionOptions(
        userPassword: userPassword, ownerPassword: ownerPassword,
        permissions: permissions, encryptMetadata: encryptMetadata,
        unencryptedEmbeddedFiles: unencryptedEmbeddedFiles),
      limits: SPDFDocumentResourcePolicy.parsingLimits)
    // The exported file cannot be reparsed without the password, so the
    // verification compares the decrypted objects against the session graph
    // (stream lengths are normalized on both sides).
    func normalized(_ value: PDFValue) -> PDFValue {
      guard case .stream(var stream) = value else { return value }
      stream.dictionary[PDFName("Length")] = .integer(Int64(stream.bytes.count))
      return .stream(stream)
    }
    try VerifiedFileWriter.write(data, to: url) { written in
      let reparsed = try PDFParser.parse(
        written, password: userPassword, limits: SPDFDocumentResourcePolicy.parsingLimits)
      guard reparsed.graph.trailer[PDFName("Encrypt")] != nil,
        reparsed.graph.objects.count == graph.objects.count + 1,
        reparsed.pageIDs == editSession.pageIDs
      else {
        throw PDFError(.malformed, "Encrypted export failed structural verification")
      }
      for (id, value) in graph.objects {
        guard reparsed.graph.objects[id] == normalized(value) else {
          throw PDFError(
            .malformed, "Encrypted export failed verification against the edited graph")
        }
      }
    }
  }

  func exportEncryptedCopy() {
    guard canEditContent, finishPendingEdits() else { return }
    let userField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    userField.placeholderString = "Required"
    let ownerField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    ownerField.placeholderString = "Optional (defaults to the user password)"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Password:"), userField],
      [NSTextField(labelWithString: "Owner password:"), ownerField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 420, height: 52)
    let alert = NSAlert()
    alert.messageText = "Export Encrypted Copy"
    alert.informativeText =
      "The copy is written with AES-256 encryption. The passwords are used only for this "
      + "export and are never stored."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Export")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = userField
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let userPassword = userField.stringValue
    let ownerPassword = ownerField.stringValue
    userField.stringValue = ""
    ownerField.stringValue = ""
    guard !userPassword.isEmpty else {
      let failure = NSAlert()
      failure.messageText = "A password is required"
      failure.informativeText = "Enter a user password for the encrypted copy."
      failure.addButton(withTitle: "OK")
      failure.runModal()
      return
    }
    let panel = NSSavePanel()
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-protected.pdf"
    panel.allowedContentTypes = [.pdf]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try self.writeEncryptedCopy(
          to: url, userPassword: userPassword,
          ownerPassword: ownerPassword.isEmpty ? nil : ownerPassword)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// P22-008: commit one ink stroke collected from the native pointer tool.
  func addInkStroke(pageIndex: Int, points: [Double]) {
    guard canEditContent, pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      points.count >= 4 else { return }
    let pageID = editSession.pageIDs[pageIndex]
    do {
      try editSession.apply(
        PDFTransaction([
          AddInkCommand(pageID: pageID, strokes: [points], modified: Self.pdfDateString(Date()))
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  // MARK: - Form filling (P24)

  /// P24-017: fill a text field from the forms panel.
  @discardableResult
  func fillFormText(fieldName: String, text: String) -> Bool {
    guard canEditContent else { return false }
    do {
      try WorkspacePerformance.profile("form-edit") {
        try editSession.fillFormText(fieldName: fieldName, text: text)
      }
    } catch {
      presentError(error)
      return false
    }
    formsModel.pendingText[fieldName] = nil
    pendingFormText.setPending(false, for: fieldName)
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  /// Keep a sidebar text-field draft visible to NSDocument's save, title-bar,
  /// and close-decision state before the user presses Return.
  func stageFormTextDraft(fieldName: String, text: String) {
    guard canEditContent else { return }
    let committed = formsModel.fields.first(where: { $0.name == fieldName })?.stringValue ?? ""
    if text == committed {
      formsModel.pendingText[fieldName] = nil
      pendingFormText.setPending(false, for: fieldName)
    } else {
      formsModel.pendingText[fieldName] = text
      pendingFormText.setPending(true, for: fieldName)
    }
    refreshWorkspaceActions()
    for controller in windowControllers {
      controller.window?.isDocumentEdited = isDocumentEdited
    }
  }

  /// P24-013: resolve an editable text widget under a page point.
  private func formFieldTarget(pageIndex: Int, pagePoint: [Double]) -> FormFieldTarget? {
    guard canEditContent, pageIndex >= 0, pagePoint.count == 2 else { return nil }
    for field in editSession.formFields() where field.kind == .text && !field.isReadOnly {
      for widget in field.widgets where widget.pageIndex == pageIndex {
        guard let rect = widget.rect, rect.count == 4,
          pagePoint[0] >= rect[0], pagePoint[0] <= rect[2],
          pagePoint[1] >= rect[1], pagePoint[1] <= rect[3]
        else { continue }
        return FormFieldTarget(
          fieldName: field.name, pageIndex: pageIndex, rect: rect,
          value: field.stringValue ?? "", isReadOnly: field.isReadOnly)
      }
    }
    return nil
  }

  /// P18-021: resolve editable document text targets for keyboard traversal
  /// and pointer hit testing, sharing the revision-scoped cache.
  private func textRunTargets(pageIndex: Int) -> [PageTextTarget] {
    guard canEditContent, pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let graph = editSession.currentGraph
    else { return [] }
    if textBlockCacheRevision != editSession.documentRevision {
      textBlockCache.removeAll()
      textEditRefusalCache.removeAll()
      textBlockCacheRevision = editSession.documentRevision
    }
    if textBlockCache[pageIndex] == nil {
      guard let page = viewer?.view.document?.page(at: pageIndex) else { return [] }
      let pageID = editSession.pageIDs[pageIndex]
      let blocks = (try? PageTextEditing.blocks(pageID: pageID, in: graph)) ?? []
      textBlockCache[pageIndex] = NativeParagraphEditing.targets(from: blocks,
        pageID: pageID, graph: graph, page: page, pageIndex: pageIndex)
    }
    return textBlockCache[pageIndex] ?? []
  }

  /// P48-007: keep a cached hit map for visible text that the inline writer
  /// refuses, so pointer hit testing does not rebuild page geometry per event.
  private func textEditRefusal(pageIndex: Int, pagePoint: [Double]) -> String? {
    guard pagePoint.count >= 2, pagePoint.allSatisfy(\.isFinite),
      pageIndex >= 0, pageIndex < editSession.pageIDs.count
    else { return nil }
    guard canEditContent else { return nil }
    guard let graph = editSession.currentGraph else { return nil }
    if textBlockCacheRevision != editSession.documentRevision {
      textBlockCache.removeAll()
      textEditRefusalCache.removeAll()
      textBlockCacheRevision = editSession.documentRevision
    }
    if textEditRefusalCache[pageIndex] == nil {
      let pageID = editSession.pageIDs[pageIndex]
      textEditRefusalCache[pageIndex] =
        (try? PageTextEditing.editRefusalTargets(pageID: pageID, in: graph)) ?? []
    }
    return textEditRefusalCache[pageIndex]?.first(where: { target in
      let rect = target.rect
      return rect.count == 4 && pagePoint[0] >= rect[0] - 2
        && pagePoint[0] <= rect[2] + 2 && pagePoint[1] >= rect[1] - 2
        && pagePoint[1] <= rect[3] + 2
    })?.reason
  }

  /// P18-021: resolve an editable document text run under a page point.
  private func textRunTarget(pageIndex: Int, pagePoint: [Double]) -> PageTextTarget? {
    guard pagePoint.count >= 2 else { return nil }
    let candidates = textRunTargets(pageIndex: pageIndex).filter { target in
      let r = target.rect
      return pagePoint[0] >= r[0] - 2 && pagePoint[0] <= r[2] + 2
        && pagePoint[1] >= r[1] - 2 && pagePoint[1] <= r[3] + 2
    }
    return NativeParagraphEditing.preferredHitTarget(from: candidates, at: pagePoint)
  }

  /// P24-014: toggle a checkbox using its actual on-state name.
  func setFormButton(fieldName: String, isOn: Bool) {
    guard canEditContent else { return }
    let field = editSession.formFields().first { $0.name == fieldName }
    let onState =
      field?.widgets.flatMap(\.appearanceStates).first { $0 != PDFName("Off") }
      ?? PDFName("Yes")
    do {
      try editSession.setFormButton(fieldName: fieldName, state: isOn ? onState : nil)
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// P24-015: select a supported combo or list option.
  func setFormChoice(fieldName: String, exportValue: String) {
    guard canEditContent else { return }
    do {
      try editSession.apply(
        PDFTransaction([
          SetFormChoiceCommand(fieldName: fieldName, exportValue: exportValue)
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// P24-021: reset supported fields to their documented default values.
  func resetForm() {
    guard canEditContent else { return }
    do {
      try editSession.apply(PDFTransaction([ResetFormCommand()]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// P24-028: orphaned widgets are reported so the interface can explain why
  /// they cannot be edited.
  func orphanedFormWidgetCount() -> Int {
    guard let graph = editSession.currentGraph else { return 0 }
    return FormInventory.orphanedWidgets(in: graph, pageIDs: editSession.pageIDs).count
  }

  /// P24-022/FRM-03: export supported field values as JSON, FDF or XFDF.
  func exportFormValues() {
    guard let graph = editSession.currentGraph else { return }
    let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    formatPopup.addItems(withTitles: ["JSON (sPDF)", "XFDF (Acrobat)", "FDF (Acrobat)"])
    let dialog = NSAlert()
    dialog.messageText = "Export Form Values"
    dialog.informativeText =
      "XFDF and FDF are the portable Acrobat interchange formats; JSON keeps the sPDF schema."
    dialog.accessoryView = formatPopup
    dialog.addButton(withTitle: "Export…")
    dialog.addButton(withTitle: "Cancel")
    guard dialog.runModal() == .alertFirstButtonReturn else { return }
    let formatIndex = max(0, formatPopup.indexOfSelectedItem)
    let data: Data
    let fileExtension: String
    do {
      switch formatIndex {
      case 1:
        data = FormDataExchange.export(
          try FormValues.values(in: graph, pageIDs: editSession.pageIDs), format: .xfdf)
        fileExtension = "xfdf"
      case 2:
        data = FormDataExchange.export(
          try FormValues.values(in: graph, pageIDs: editSession.pageIDs), format: .fdf)
        fileExtension = "fdf"
      default:
        data = try FormValues.export(in: graph, pageIDs: editSession.pageIDs)
        fileExtension = "json"
      }
    } catch {
      presentError(error)
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "form-values.\(fileExtension)"
    panel.allowedContentTypes =
      [UTType(filenameExtension: fileExtension) ?? .data]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try data.write(to: url, options: .atomic)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// P34-001/P34-002: export the document text (or the viewer selection) with
  /// explicit encoding and line-ending choices.
  var canExportText: Bool { editSession.currentGraph != nil }

  func exportText() {
    guard finishPendingEdits() else { return }
    guard let graph = editSession.currentGraph else { return }
    let encodingPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    encodingPopup.addItems(withTitles: ["UTF-8", "UTF-16"])
    let endingPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    endingPopup.addItems(withTitles: ["LF (\n)", "CRLF (\r\n)"])
    let selectionCheckbox = NSButton(
      checkboxWithTitle: "Only the current selection", target: nil, action: nil)
    let hasSelection = viewer?.view.currentSelection != nil
    selectionCheckbox.state = hasSelection ? .on : .off
    selectionCheckbox.isEnabled = hasSelection
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Encoding:"), encodingPopup],
      [NSTextField(labelWithString: "Line endings:"), endingPopup],
      [NSGridCell.emptyContentView, selectionCheckbox],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 360, height: 76)
    let alert = NSAlert()
    alert.messageText = "Export Text"
    alert.informativeText = "Text follows the document's reading order."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let options = PDFTextExportOptions(
      lineEnding: endingPopup.indexOfSelectedItem == 1 ? .crlf : .lf,
      encoding: encodingPopup.indexOfSelectedItem == 1 ? .utf16 : .utf8)
    let data: Data
    do {
      if selectionCheckbox.state == .on, let selection = viewer?.view.currentSelection,
        let string = selection.string
      {
        data = PDFTextExport.encoded(string, options: options)
      } else {
        data = try PDFTextExport.plainText(
          pageIDs: editSession.pageIDs, in: graph, options: options)
      }
    } catch {
      presentError(error)
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "document.txt"
    panel.allowedContentTypes = [.plainText]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try DerivativeOutputPolicy.validateDestination(url, source: self.fileURL)
        try data.write(to: url, options: .atomic)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// Testable path behind the panel: write the export directly.
  func exportText(to url: URL, options: PDFTextExportOptions = .init()) throws {
    let graph = try prepareDerivative(
      to: url, requiresEditable: false, allowSigned: true)
    let data = try PDFTextExport.plainText(
      pageIDs: editSession.pageIDs, in: graph, options: options)
    try data.write(to: url, options: .atomic)
  }

  /// P34-003–P34-006: export page images with explicit format, resolution,
  /// color, and alpha choices through the ImageIO path.
  var canExportPageImages: Bool { editSession.currentGraph != nil }

  func exportPageImages() {
    let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    formatPopup.addItems(withTitles: ["PNG", "JPEG", "TIFF"])
    let resolutionPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    resolutionPopup.addItems(withTitles: ["72 dpi", "144 dpi", "300 dpi"])
    resolutionPopup.selectItem(at: 1)
    let colorPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    colorPopup.addItems(withTitles: ["RGB", "Grayscale"])
    let alphaCheckbox = NSButton(checkboxWithTitle: "Keep transparency", target: nil, action: nil)
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Format:"), formatPopup],
      [NSTextField(labelWithString: "Resolution:"), resolutionPopup],
      [NSTextField(labelWithString: "Color:"), colorPopup],
      [NSGridCell.emptyContentView, alphaCheckbox],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 360, height: 100)
    let alert = NSAlert()
    alert.messageText = "Export Page Images"
    alert.informativeText = "Choose a folder; pages are written as page-0001, page-0002, …"
    alert.accessoryView = grid
    alert.addButton(withTitle: "Choose Folder…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let format: PageImageExportOptions.Format =
      formatPopup.indexOfSelectedItem == 1
      ? .jpeg : (formatPopup.indexOfSelectedItem == 2 ? .tiff : .png)
    let dpi = [72.0, 144.0, 300.0][max(0, resolutionPopup.indexOfSelectedItem)]
    let options = PageImageExportOptions(
      format: format, dpi: dpi, includeAlpha: alphaCheckbox.state == .on,
      colorModel: colorPopup.indexOfSelectedItem == 1 ? .gray : .rgb)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Export"
    panel.begin { [weak self] response in
      guard response == .OK, let directory = panel.url, let self else { return }
      let baseName =
        self.fileURL?.deletingPathExtension().lastPathComponent.isEmpty == false
        ? self.fileURL!.deletingPathExtension().lastPathComponent : "page"
      Task { @MainActor [weak self] in
        do {
          _ = try await self?.exportPageImages(
            to: directory, baseName: baseName, options: options)
        } catch is CancellationError {
        } catch {
          if let self { self.presentError(error) }
        }
      }
    }
  }

  /// Testable path behind the panel: export directly to a directory.
  @discardableResult
  func exportPageImages(
    to directory: URL, baseName: String, options: PageImageExportOptions = .init(),
    job: UUID? = nil
  ) async throws -> [PageImageExport.ExportedPage] {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "There is no document to export")
    }
    // P12-028: when the background job ends (exported, cancelled, or
    // failed), keyboard focus returns to the page view instead of stranding
    // on the progress control. Captured up front on the caller's executor.
    let window = windowControllers.first?.window
    let pageView = viewer?.view
    let job =
      try job
      ?? beginDocumentJob(
        title: "Exporting page images", total: editSession.pageIDs.count)
    defer {
      jobCenter.finish(id: job)
      Task { @MainActor [weak window, weak pageView] in
        if let pageView { window?.makeFirstResponder(pageView) }
      }
    }
    // The exporter calls back off the main actor; the relay hops to it.
    // The callback is explicitly Sendable (relay and job only) so it can
    // cross into the concurrent exporter.
    let relay = JobProgressRelay(center: jobCenter)
    let progress: @Sendable (Int, Int) -> Void = { [relay, job] done, _ in
      relay.update(id: job, completed: done)
    }
    return try await PageImageExport.export(
      pages: editSession.pageIDs, in: graph, to: directory, baseName: baseName,
      options: options, progress: progress)
  }

  /// P34-009–P34-013: export HTML in semantic or appearance mode with an
  /// explicit image policy. Packaged resources are written next to the file.
  var canExportHTML: Bool { editSession.currentGraph != nil }

  func exportHTML() {
    guard finishPendingEdits() else { return }
    guard let graph = editSession.currentGraph else { return }
    let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    modePopup.addItems(withTitles: ["Semantic (text and structure)", "Appearance (page images)"])
    let policyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    policyPopup.addItems(withTitles: ["Embed images in the HTML", "Package images in a folder"])
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Mode:"), modePopup],
      [NSTextField(labelWithString: "Images:"), policyPopup],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 52)
    let alert = NSAlert()
    alert.messageText = "Export HTML"
    alert.informativeText =
      "Semantic mode writes text and structure; appearance mode renders pages. Neither mode writes scripts."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let options = PDFHTMLExportOptions(
      mode: modePopup.indexOfSelectedItem == 1 ? .appearance : .semantic,
      imagePolicy: policyPopup.indexOfSelectedItem == 1 ? .package : .embed,
      documentTitle: fileURL?.deletingPathExtension().lastPathComponent)
    let result: PDFHTMLExport.Result
    do {
      result = try PDFHTMLExport.export(pageIDs: editSession.pageIDs, in: graph, options: options)
    } catch {
      presentError(error)
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "document.html"
    panel.allowedContentTypes = [.html]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try DerivativeOutputPolicy.validateDestination(url, source: self.fileURL)
        try result.html.data(using: .utf8)?.write(to: url, options: .atomic)
        try self.writeHTMLResources(result.resources, nextTo: url)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// Testable path behind the panel.
  func exportHTML(to url: URL, options: PDFHTMLExportOptions = .init()) throws {
    let graph = try prepareDerivative(
      to: url, requiresEditable: false, allowSigned: true)
    let result = try PDFHTMLExport.export(pageIDs: editSession.pageIDs, in: graph, options: options)
    try result.html.data(using: .utf8)?.write(to: url, options: .atomic)
    try writeHTMLResources(result.resources, nextTo: url)
  }

  private func writeHTMLResources(_ resources: [String: Data], nextTo url: URL) throws {
    guard !resources.isEmpty else { return }
    let base = url.deletingLastPathComponent()
    for (relative, data) in resources {
      let destination = base.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: destination, options: .atomic)
    }
  }

  /// P34-014: export the document outline as Markdown or HTML.
  var canExportOutline: Bool {
    guard let graph = editSession.currentGraph else { return false }
    return !PDFOutlineInventory.items(in: graph, pageIDs: editSession.pageIDs).isEmpty
  }

  func exportOutline() {
    guard let graph = editSession.currentGraph else { return }
    let items = PDFOutlineInventory.items(in: graph, pageIDs: editSession.pageIDs)
    guard !items.isEmpty else { return }
    let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    formatPopup.addItems(withTitles: ["Markdown", "HTML"])
    let grid = NSGridView(views: [[NSTextField(labelWithString: "Format:"), formatPopup]])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
    let alert = NSAlert()
    alert.messageText = "Export Outline"
    alert.informativeText = "\(items.count) top-level bookmark\(items.count == 1 ? "" : "s")"
    alert.accessoryView = grid
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let format: PDFOutlineExport.Format = formatPopup.indexOfSelectedItem == 1 ? .html : .markdown
    let text = PDFOutlineExport.text(
      items: items, format: format,
      documentTitle: fileURL?.deletingPathExtension().lastPathComponent)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = format == .html ? "outline.html" : "outline.md"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// Testable path behind the panel.
  func exportOutline(to url: URL, format: PDFOutlineExport.Format = .markdown) throws {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "There is no document to export")
    }
    let items = PDFOutlineInventory.items(in: graph, pageIDs: editSession.pageIDs)
    let text = PDFOutlineExport.text(
      items: items, format: format,
      documentTitle: fileURL?.deletingPathExtension().lastPathComponent)
    try text.data(using: .utf8)?.write(to: url, options: .atomic)
  }

  // MARK: - P19 paragraph reflow

  /// P19-007: reflow the paragraph at the current page (menu-driven). The
  /// candidate comes from the analysis pass so the plan is reviewable.
  func reflowParagraph() {
    guard canEditContent else { return }
    // Reflow mutates the canonical graph and reloads the viewer. Finish the
    // selected inline text editor first so its stale source snapshot cannot
    // overwrite the new paragraph layout when the user presses Done.
    guard viewer?.pendingEditFinisher?() ?? true else { return }
    guard let graph = editSession.currentGraph,
      let pageID = currentPageID(in: graph)
    else { return }
    let candidates =
      (try? ParagraphReconstruction.candidatesForEditing(pageID: pageID, in: graph)) ?? []
    let editable = candidates.filter { $0.kind == .flowing || $0.kind == .heading }
    guard !editable.isEmpty else {
      presentError(PDFError(.malformed, "No reflowable paragraphs were found on this page"))
      return
    }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    for candidate in editable {
      let snippet = candidate.text.replacingOccurrences(of: "\n", with: " ")
      popup.addItem(withTitle: String(snippet.prefix(48)))
    }
    let replacementScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 360, height: 76))
    replacementScrollView.hasVerticalScroller = true
    replacementScrollView.autohidesScrollers = true
    replacementScrollView.borderType = .bezelBorder
    let replacementTextView = NSTextView(frame: replacementScrollView.bounds)
    replacementTextView.isRichText = false
    replacementTextView.isVerticallyResizable = true
    replacementTextView.isHorizontallyResizable = false
    replacementTextView.textContainer?.widthTracksTextView = true
    replacementTextView.textContainer?.containerSize = NSSize(
      width: replacementScrollView.contentSize.width,
      height: .greatestFiniteMagnitude)
    replacementTextView.textContainerInset = NSSize(width: 5, height: 4)
    replacementTextView.setAccessibilityLabel("New text")
    replacementTextView.setAccessibilityIdentifier("paragraph-reflow-replacement")
    replacementTextView.toolTip =
      "Enter a line break with Return to keep it in the reflowed paragraph."
    replacementTextView.string = editable[0].text.replacingOccurrences(of: "\n", with: " ")
    replacementScrollView.documentView = replacementTextView
    let candidateSelectionTarget = ParagraphReflowCandidateSelectionTarget(
      candidates: editable, replacementTextView: replacementTextView)
    popup.target = candidateSelectionTarget
    popup.action = #selector(ParagraphReflowCandidateSelectionTarget.candidateDidChange(_:))
    let overflowPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    overflowPopup.addItems(withTitles: ["Allow overflow", "Clip (refuse)", "Shrink to fit"])
    let alignmentPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    alignmentPopup.addItems(
      withTitles: ["Keep alignment", "Left", "Center", "Right", "Justified"])
    let lineSpacingField = NSTextField(string: "")
    lineSpacingField.placeholderString = "Keep current"
    lineSpacingField.toolTip =
      "Distance between line baselines, in points; limited to 1.8 times the selected font size."
    let firstLineIndentField = NSTextField(string: "")
    firstLineIndentField.placeholderString = "Keep current"
    firstLineIndentField.toolTip =
      "Positive values indent the first line; negative values create a hanging indent."
    let paragraphSpacingBeforeField = NSTextField(string: "")
    paragraphSpacingBeforeField.placeholderString = "Keep current"
    paragraphSpacingBeforeField.toolTip =
      "Moves this paragraph down to add space before it; following text shifts as needed."
    let paragraphSpacingAfterField = NSTextField(string: "")
    paragraphSpacingAfterField.placeholderString = "Keep current"
    paragraphSpacingAfterField.toolTip =
      "Adds space after this paragraph by moving following same-column text down."
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Paragraph:"), popup],
      [NSTextField(labelWithString: "New text:"), replacementScrollView],
      [NSTextField(labelWithString: "Overflow:"), overflowPopup],
      [NSTextField(labelWithString: "Alignment:"), alignmentPopup],
      [NSTextField(labelWithString: "Line spacing (pt):"), lineSpacingField],
      [NSTextField(labelWithString: "First-line indent (pt):"), firstLineIndentField],
      [NSTextField(labelWithString: "Extra space before (pt):"), paragraphSpacingBeforeField],
      [NSTextField(labelWithString: "Extra space after (pt):"), paragraphSpacingAfterField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 520, height: 256)
    guard
      runFormDialog(
        title: "Reflow Paragraph",
        message:
          "The paragraph's own lines are rewritten; other content is checked for collisions. "
          + "Justified alignment expands spaces on nonfinal lines. Leave line spacing blank "
          + "to keep the selected paragraph's current spacing. Use Return in New text to keep "
          + "an explicit line break; ordinary wrapping remains automatic. "
          + "Explicit spacing is limited to "
          + "1.8 times the selected font size so it remains available for reflow after reopening. "
          + "Leave first-line indent blank to keep it; positive values indent and negative "
          + "values create a hanging indent. Leave extra paragraph spacing blank to keep its "
          + "current placement; enter 0 to 100 points to add space before or after.",
        accessory: grid)
    else { return }
    let index = max(0, min(popup.indexOfSelectedItem, editable.count - 1))
    let candidate = editable[index]
    let spacingInput = lineSpacingField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let lineSpacing: Double?
    if spacingInput.isEmpty {
      lineSpacing = nil
    } else {
      guard overflowPopup.indexOfSelectedItem != 2 else {
        presentError(
          PDFError(
            .unsupported,
            "Custom line spacing cannot be combined with Shrink to fit; choose Allow overflow or Clip (refuse)."))
        return
      }
      let maximumLineSpacing = min(1_000, candidate.fontSize * 1.8)
      guard let value = Double(spacingInput), value.isFinite, value > 0,
        value <= maximumLineSpacing
      else {
        presentError(
          PDFError(
            .malformed,
            "Line spacing must be a positive number no greater than \(String(format: "%.1f", maximumLineSpacing)) points for this paragraph."))
        return
      }
      lineSpacing = value
    }
    let alignment: TextParagraphCandidate.Alignment?
    switch alignmentPopup.indexOfSelectedItem {
    case 1: alignment = .left
    case 2: alignment = .center
    case 3: alignment = .right
    case 4: alignment = .justified
    default: alignment = nil
    }
    let indentInput = firstLineIndentField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let firstLineIndent: Double?
    if indentInput.isEmpty {
      firstLineIndent = nil
    } else {
      let paragraphWidth = candidate.bounds[2] - candidate.bounds[0]
      let maximumIndent = min(100, max(0, paragraphWidth - 24))
      guard let value = Double(indentInput), value.isFinite,
        abs(value) <= maximumIndent
      else {
        let limit = String(format: "%.1f", maximumIndent)
        presentError(
          PDFError(
            .malformed,
            "First-line indent must be between -\(limit) and \(limit) points for this paragraph."))
        return
      }
      let effectiveAlignment = alignment ?? candidate.alignment
      guard value == 0 || effectiveAlignment == .left || effectiveAlignment == .justified else {
        presentError(
          PDFError(
            .unsupported, "First-line indentation is supported for left or justified alignment."))
        return
      }
      firstLineIndent = value
    }
    func parseAdditionalParagraphSpacing(_ field: NSTextField, label: String) -> Double? {
      let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !input.isEmpty else { return nil }
      guard let value = Double(input), value.isFinite, (0...100).contains(value) else {
        presentError(
          PDFError(.malformed, "\(label) must be between 0 and 100 points."))
        return nil
      }
      return value
    }
    let spacingBeforeInput = paragraphSpacingBeforeField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let spacingBefore = parseAdditionalParagraphSpacing(
      paragraphSpacingBeforeField, label: "Extra space before")
    guard spacingBeforeInput.isEmpty || spacingBefore != nil else { return }
    let spacingAfterInput = paragraphSpacingAfterField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let spacingAfter = parseAdditionalParagraphSpacing(
      paragraphSpacingAfterField, label: "Extra space after")
    guard spacingAfterInput.isEmpty || spacingAfter != nil else { return }
    let options = ParagraphReflowOptions(
      alignment: alignment,
      firstLineIndent: firstLineIndent,
      lineSpacing: lineSpacing,
      additionalParagraphSpacingBefore: spacingBefore,
      additionalParagraphSpacingAfter: spacingAfter,
      overflow: [
        ParagraphReflowOptions.Overflow.allow, .clip, .shrinkToFit,
      ][max(0, min(overflowPopup.indexOfSelectedItem, 2))])
    _ = reflowParagraph(
      pageID: pageID, candidate: candidate, replacement: replacementTextView.string,
      options: options)
  }

  /// Testable path behind the dialog.
  @discardableResult
  func reflowParagraph(
    pageID: PDFObjectID, candidate: TextParagraphCandidate, replacement: String,
    options: ParagraphReflowOptions = .init()
  ) -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(
        PDFTransaction([
          ReflowParagraphCommand(
            pageID: pageID, candidate: candidate, replacement: replacement, options: options)
        ]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  // MARK: - P25 form authoring (menu-driven with default placement)

  var canAuthorForm: Bool { canEditContent }

  var hasFormFields: Bool { !formFieldNames().isEmpty }

  func formFieldNames() -> [String] {
    guard let graph = editSession.currentGraph else { return [] }
    let fields = (try? FormInventory.fields(in: graph, pageIDs: editSession.pageIDs)) ?? []
    return fields.map(\.name)
  }

  /// Default placement: a 200x24 box at the current page's center, or three
  /// 18x18 radio widgets in a row.
  private func defaultRect(width: Double = 200, height: Double = 24) -> [Double]? {
    guard let graph = editSession.currentGraph,
      let pageID = currentPageID(in: graph),
      case .dictionary(let page)? = graph.objects[pageID]
    else { return nil }
    var box: [Double] = [0, 0, 612, 792]
    if case .array(let values)? = page[PDFName("MediaBox")], values.count == 4 {
      let numbers = values.compactMap { value -> Double? in
        switch value {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
      if numbers.count == 4 { box = numbers }
    }
    let centerX = (box[0] + box[2]) / 2
    let centerY = (box[1] + box[3]) / 2
    return [centerX - width / 2, centerY - height / 2, centerX + width / 2, centerY + height / 2]
  }

  private func currentPageID(in graph: PDFGraph) -> PDFObjectID? {
    let pageIndex = max(0, (viewer?.pageNumber ?? 1) - 1)
    return editSession.pageIDs.indices.contains(pageIndex) ? editSession.pageIDs[pageIndex] : nil
  }

  @discardableResult
  private func applyFormAuthoring(_ command: any PDFEditCommand) -> Bool {
    guard canEditContent, confirmXFAIfNeeded() else { return false }
    do {
      try editSession.apply(PDFTransaction([command]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshForms()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  func addTextField() {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect()
    else { return }
    let nameField = NSTextField(string: "Text1")
    let valueField = NSTextField(string: "")
    let requiredBox = NSButton(checkboxWithTitle: "Required", target: nil, action: nil)
    let multilineBox = NSButton(checkboxWithTitle: "Multiline", target: nil, action: nil)
    let readOnlyBox = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), nameField],
      [NSTextField(labelWithString: "Default:"), valueField],
      [NSGridCell.emptyContentView, requiredBox],
      [NSGridCell.emptyContentView, multilineBox],
      [NSGridCell.emptyContentView, readOnlyBox],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 360, height: 124)
    guard
      runFormDialog(
        title: "Add Text Field",
        message: "Placed at the center of the current page; move or resize it afterwards.",
        accessory: grid)
    else { return }
    _ = applyFormAuthoring(
      AddTextFieldCommand(
        pageID: pageID, rect: rect, name: nameField.stringValue,
        multiline: multilineBox.state == .on, required: requiredBox.state == .on,
        readOnly: readOnlyBox.state == .on,
        defaultValue: valueField.stringValue.isEmpty ? nil : valueField.stringValue))
  }

  func addCheckbox() {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect(width: 18, height: 18)
    else { return }
    let nameField = NSTextField(string: "Checkbox1")
    let checkedBox = NSButton(checkboxWithTitle: "Checked by default", target: nil, action: nil)
    let requiredBox = NSButton(checkboxWithTitle: "Required", target: nil, action: nil)
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), nameField],
      [NSGridCell.emptyContentView, checkedBox],
      [NSGridCell.emptyContentView, requiredBox],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 360, height: 76)
    guard
      runFormDialog(
        title: "Add Checkbox",
        message: "Placed at the center of the current page.",
        accessory: grid)
    else { return }
    _ = applyFormAuthoring(
      AddCheckboxCommand(
        pageID: pageID, rect: rect, name: nameField.stringValue,
        checkedByDefault: checkedBox.state == .on, required: requiredBox.state == .on))
  }

  func addRadioGroup() {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect(width: 120, height: 18)
    else { return }
    let nameField = NSTextField(string: "Radio1")
    let valuesField = NSTextField(string: "Choice1, Choice2, Choice3")
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), nameField],
      [NSTextField(labelWithString: "Values:"), valuesField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 52)
    guard
      runFormDialog(
        title: "Add Radio Group",
        message: "Comma-separated export values; placed at the center of the page.",
        accessory: grid)
    else { return }
    let values = valuesField.stringValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !values.isEmpty else { return }
    let y = rect[1]
    let x = rect[0]
    let rects = values.indices.map { index in
      [x + Double(index) * 30, y, x + 18 + Double(index) * 30, y + 18]
    }
    _ = applyFormAuthoring(
      AddRadioGroupCommand(
        pageID: pageID, rects: rects, name: nameField.stringValue, exportValues: values))
  }

  func addChoiceField() {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect()
    else { return }
    let nameField = NSTextField(string: "Choice1")
    let optionsField = NSTextField(string: "First, Second, Third")
    let comboBox = NSButton(
      checkboxWithTitle: "Combo box (otherwise a list)", target: nil, action: nil)
    comboBox.state = .on
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), nameField],
      [NSTextField(labelWithString: "Options:"), optionsField],
      [NSGridCell.emptyContentView, comboBox],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 76)
    guard
      runFormDialog(
        title: "Add Choice Field",
        message: "Comma-separated options; placed at the center of the page.",
        accessory: grid)
    else { return }
    let options = optionsField.stringValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { AuthoredChoiceOption(exportValue: $0) }
    guard !options.isEmpty else { return }
    _ = applyFormAuthoring(
      AddChoiceFieldCommand(
        pageID: pageID, rect: rect, name: nameField.stringValue, options: options,
        combo: comboBox.state == .on))
  }

  func addPushButton() {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect(width: 140, height: 28)
    else { return }
    let nameField = NSTextField(string: "Button1")
    let captionField = NSTextField(string: "Button")
    let urlField = NSTextField(string: "")
    urlField.placeholderString = "Optional https:// link"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), nameField],
      [NSTextField(labelWithString: "Caption:"), captionField],
      [NSTextField(labelWithString: "Link:"), urlField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 76)
    guard
      runFormDialog(
        title: "Add Push Button",
        message:
          "Only http, https, and mailto links are accepted; leave empty for an inert button.",
        accessory: grid)
    else { return }
    _ = applyFormAuthoring(
      AddPushButtonCommand(
        pageID: pageID, rect: rect, name: nameField.stringValue,
        caption: captionField.stringValue,
        uri: urlField.stringValue.isEmpty ? nil : urlField.stringValue))
  }

  func addSignatureField() {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect(width: 200, height: 36)
    else { return }
    let nameField = NSTextField(string: "Signature1")
    let grid = NSGridView(views: [[NSTextField(labelWithString: "Name:"), nameField]])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
    guard
      runFormDialog(
        title: "Add Signature Field",
        message: "An empty signature field; signing is a separate, explicit action.",
        accessory: grid)
    else { return }
    _ = applyFormAuthoring(
      AddSignatureFieldCommand(pageID: pageID, rect: rect, name: nameField.stringValue))
  }

  func renameFormField() {
    let names = formFieldNames()
    guard !names.isEmpty else { return }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    popup.addItems(withTitles: names)
    let nameField = NSTextField(string: names[0])
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Field:"), popup],
      [NSTextField(labelWithString: "New name:"), nameField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 52)
    guard
      runFormDialog(
        title: "Rename Form Field", message: "Dotted names create or move within a parent group.",
        accessory: grid)
    else { return }
    _ = applyFormAuthoring(
      RenameFormFieldCommand(
        fieldName: popup.titleOfSelectedItem ?? names[0], newName: nameField.stringValue))
  }

  func deleteFormField() {
    let names = formFieldNames()
    guard !names.isEmpty else { return }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    popup.addItems(withTitles: names)
    let grid = NSGridView(views: [[NSTextField(labelWithString: "Field:"), popup]])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
    guard
      runFormDialog(
        title: "Delete Form Field",
        message: "The field, its widgets, and its page annotations are removed.",
        accessory: grid)
    else { return }
    _ = applyFormAuthoring(
      RemoveFormFieldCommand(fieldName: popup.titleOfSelectedItem ?? names[0]))
  }

  /// P25-007: the field-properties inspector. Step one chooses a field; step
  /// two edits flags, style, validation, format, and calculation rules.
  func editFormFieldProperties() {
    guard canEditContent else { return }
    let names = formFieldNames()
    guard !names.isEmpty else { return }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    popup.addItems(withTitles: names)
    let grid = NSGridView(views: [[NSTextField(labelWithString: "Field:"), popup]])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 340, height: 28)
    guard
      runFormDialog(
        title: "Field Properties",
        message: "Choose a field to inspect and edit.", accessory: grid),
      let graph = editSession.currentGraph
    else { return }
    let name = popup.titleOfSelectedItem ?? names[0]
    guard let properties = FormFieldPropertiesReader.properties(forFieldNamed: name, in: graph)
    else { return }

    let requiredBox = NSButton(checkboxWithTitle: "Required", target: nil, action: nil)
    requiredBox.state = properties.isRequired ? .on : .off
    let readOnlyBox = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    readOnlyBox.state = properties.isReadOnly ? .on : .off
    let multilineBox = NSButton(checkboxWithTitle: "Multiline", target: nil, action: nil)
    multilineBox.state = properties.isMultiline ? .on : .off
    multilineBox.isEnabled = properties.kind == .text
    let passwordBox = NSButton(checkboxWithTitle: "Password", target: nil, action: nil)
    passwordBox.state = properties.isPassword ? .on : .off
    passwordBox.isEnabled = properties.kind == .text
    let fontSizeField = NSTextField(
      string: properties.fontSize.map { String(format: "%g", $0) } ?? "12")
    let alignmentPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
    alignmentPopup.addItems(withTitles: ["Left", "Center", "Right"])
    alignmentPopup.selectItem(at: properties.alignment ?? 0)
    let maxLengthField = NSTextField(string: properties.maxLength.map(String.init) ?? "")
    maxLengthField.placeholderString = "No limit"
    let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
    formatPopup.addItems(withTitles: ["None", "Number", "Date"])
    switch properties.format {
    case .number: formatPopup.selectItem(at: 1)
    case .date: formatPopup.selectItem(at: 2)
    default: formatPopup.selectItem(at: 0)
    }
    let decimalsField = NSTextField(string: "2")
    if case .number(let decimals, _, _)? = properties.format {
      decimalsField.stringValue = String(decimals)
    }
    let prefixField = NSTextField(string: "")
    if case .number(_, let prefix, _)? = properties.format {
      prefixField.stringValue = prefix ?? ""
    }
    let calculationField = NSTextField(
      string: properties.calculation?.fields.joined(separator: ", ") ?? "")
    calculationField.placeholderString = "Comma-separated fields to sum"
    let grid2 = NSGridView(views: [
      [NSTextField(labelWithString: "Flags:"), requiredBox],
      [NSGridCell.emptyContentView, readOnlyBox],
      [NSGridCell.emptyContentView, multilineBox],
      [NSGridCell.emptyContentView, passwordBox],
      [NSTextField(labelWithString: "Font size:"), fontSizeField],
      [NSTextField(labelWithString: "Alignment:"), alignmentPopup],
      [NSTextField(labelWithString: "Max length:"), maxLengthField],
      [NSTextField(labelWithString: "Format:"), formatPopup],
      [NSTextField(labelWithString: "Decimals:"), decimalsField],
      [NSTextField(labelWithString: "Prefix:"), prefixField],
      [NSTextField(labelWithString: "Sum of:"), calculationField],
    ])
    grid2.column(at: 0).xPlacement = .trailing
    grid2.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
    guard
      runFormDialog(
        title: "Properties — \(name)",
        message: "Formats and calculations are declarative; no document scripts run.",
        accessory: grid2),
      canEditContent
    else { return }

    let flags = SetFormFieldFlagsCommand(
      fieldName: name, required: requiredBox.state == .on, readOnly: readOnlyBox.state == .on,
      multiline: multilineBox.state == .on, password: passwordBox.state == .on)
    let style = SetFormFieldStyleCommand(
      fieldName: name, fontSize: Double(fontSizeField.stringValue),
      alignment: alignmentPopup.indexOfSelectedItem)
    var validation: SetFormFieldValidationCommand?
    if !maxLengthField.stringValue.isEmpty, let maxLength = Int(maxLengthField.stringValue) {
      validation = SetFormFieldValidationCommand(fieldName: name, maxLength: maxLength)
    }
    var format: SetFormFieldFormatCommand?
    switch formatPopup.indexOfSelectedItem {
    case 1:
      format = SetFormFieldFormatCommand(
        fieldName: name,
        format: .number(
          decimals: Int(decimalsField.stringValue) ?? 2,
          prefix: prefixField.stringValue.isEmpty ? nil : prefixField.stringValue, suffix: nil))
    case 2:
      format = SetFormFieldFormatCommand(fieldName: name, format: .date(style: .long))
    default:
      format = SetFormFieldFormatCommand(fieldName: name, format: nil)
    }
    var calculation: SetFormFieldCalculationCommand?
    let references = calculationField.stringValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    calculation = SetFormFieldCalculationCommand(
      fieldName: name, calculation: references.isEmpty ? nil : .sum(fields: references))

    var commands: [any PDFEditCommand] = [flags, style]
    if let validation { commands.append(validation) }
    if let format { commands.append(format) }
    if let calculation { commands.append(calculation) }
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshForms()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// P25-015: evaluate declarative calculation rules.
  func recalculateForm() {
    guard canEditContent else { return }
    do {
      try editSession.apply(PDFTransaction([RecalculateFormCommand()]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshForms()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// P25-024: authoring is AcroForm-only; XFA presence is surfaced once per
  /// document before the first authoring action.
  private func confirmXFAIfNeeded() -> Bool {
    guard !warnedXFA, let graph = editSession.currentGraph,
      FormXAFFlag.hasXFA(in: graph)
    else { return true }
    let alert = NSAlert()
    alert.messageText = "XFA Form Data"
    alert.informativeText = FormXAFFlag.authoringWarning
    alert.addButton(withTitle: "Continue with AcroForm")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    warnedXFA = true
    return true
  }

  /// P25-010: duplicate a field with an explicit value-sharing policy.
  func duplicateFormField() {
    let names = formFieldNames()
    guard !names.isEmpty, confirmXFAIfNeeded() else { return }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    popup.addItems(withTitles: names)
    let nameField = NSTextField(string: "")
    nameField.placeholderString = "Automatic (Name2)"
    let sharingPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    sharingPopup.addItems(withTitles: ["Shared value (another widget)", "Independent copy"])
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Field:"), popup],
      [NSTextField(labelWithString: "New name:"), nameField],
      [NSTextField(labelWithString: "Policy:"), sharingPopup],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 76)
    guard
      runFormDialog(
        title: "Duplicate Field",
        message:
          "A shared value adds a widget to the same field; an independent copy owns its value.",
        accessory: grid),
      let pageID = editSession.currentGraph.flatMap(currentPageID(in:))
    else { return }
    _ = applyFormAuthoring(
      DuplicateFormFieldCommand(
        fieldName: popup.titleOfSelectedItem ?? names[0],
        newName: nameField.stringValue.isEmpty ? nil : nameField.stringValue,
        pageID: pageID, offset: [0, -30],
        sharing: sharingPopup.indexOfSelectedItem == 1 ? .independentCopy : .sharedValue))
  }

  /// P25-019: align or distribute selected widgets.
  func alignFormFields() {
    let names = formFieldNames()
    guard names.count >= 2, confirmXFAIfNeeded() else { return }
    let namesField = NSTextField(string: names.joined(separator: ", "))
    let edgePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    edgePopup.addItems(withTitles: ["Left", "Right", "Top", "Bottom", "Center X", "Center Y"])
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Fields:"), namesField],
      [NSTextField(labelWithString: "Align:"), edgePopup],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 420, height: 52)
    guard
      runFormDialog(
        title: "Align Fields", message: "Comma-separated field names.",
        accessory: grid)
    else { return }
    let selected = namesField.stringValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let edges: [FormWidgetEdge] = [.left, .right, .top, .bottom, .centerX, .centerY]
    _ = applyFormAuthoring(
      AlignFormWidgetsCommand(
        fields: selected, edge: edges[max(0, min(edgePopup.indexOfSelectedItem, edges.count - 1))]))
  }

  func distributeFormFields() {
    let names = formFieldNames()
    guard names.count >= 3, confirmXFAIfNeeded() else { return }
    let namesField = NSTextField(string: names.joined(separator: ", "))
    let axisPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    axisPopup.addItems(withTitles: ["Horizontal", "Vertical"])
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Fields:"), namesField],
      [NSTextField(labelWithString: "Axis:"), axisPopup],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 420, height: 52)
    guard
      runFormDialog(
        title: "Distribute Fields", message: "Even spacing between the first and last widget.",
        accessory: grid)
    else { return }
    let selected = namesField.stringValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    _ = applyFormAuthoring(
      DistributeFormWidgetsCommand(
        fields: selected, axis: axisPopup.indexOfSelectedItem == 1 ? .vertical : .horizontal))
  }

  /// P25-018: edit the field and keyboard tab order.
  func editFormTabOrder() {
    let names = formFieldNames()
    guard names.count >= 2, confirmXFAIfNeeded() else { return }
    let namesField = NSTextField(string: names.joined(separator: ", "))
    let grid = NSGridView(views: [[NSTextField(labelWithString: "Order:"), namesField]])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 460, height: 28)
    guard
      runFormDialog(
        title: "Field Tab Order",
        message: "Comma-separated field names in the order readers should tab through them.",
        accessory: grid)
    else { return }
    let order = namesField.stringValue
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    _ = applyFormAuthoring(ReorderFormFieldsCommand(order: order))
  }

  private func runFormDialog(title: String, message: String, accessory: NSView) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = accessory
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Testable authoring paths behind the dialogs.
  @discardableResult
  func addAuthoredTextField(name: String, defaultValue: String? = nil, required: Bool = false)
    -> Bool
  {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)),
      let rect = defaultRect()
    else { return false }
    return applyFormAuthoring(
      AddTextFieldCommand(
        pageID: pageID, rect: rect, name: name, required: required, defaultValue: defaultValue))
  }

  func formFieldProperties(for name: String) -> FormFieldProperties? {
    guard let graph = editSession.currentGraph else { return nil }
    return FormFieldPropertiesReader.properties(forFieldNamed: name, in: graph)
  }

  @discardableResult
  func applyAuthoredFieldProperties(
    name: String, required: Bool = false, fontSize: Double? = nil, maxLength: Int? = nil,
    format: AuthoredFieldFormat? = nil, calculation: AuthoredCalculation? = nil
  ) -> Bool {
    guard canEditContent, confirmXFAIfNeeded() else { return false }
    var commands: [any PDFEditCommand] = [
      SetFormFieldFlagsCommand(fieldName: name, required: required)
    ]
    if let fontSize {
      commands.append(SetFormFieldStyleCommand(fieldName: name, fontSize: fontSize))
    }
    if let maxLength {
      commands.append(SetFormFieldValidationCommand(fieldName: name, maxLength: maxLength))
    }
    if let format {
      commands.append(SetFormFieldFormatCommand(fieldName: name, format: format))
    }
    if let calculation {
      commands.append(SetFormFieldCalculationCommand(fieldName: name, calculation: calculation))
    }
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshForms()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  @discardableResult
  func recalculateAuthoredForm() -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(PDFTransaction([RecalculateFormCommand()]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshForms()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  @discardableResult
  func duplicateAuthoredFormField(
    name: String, newName: String? = nil, sharing: DuplicateFormFieldCommand.Sharing
  ) -> Bool {
    guard let pageID = editSession.currentGraph.flatMap(currentPageID(in:)) else { return false }
    return applyFormAuthoring(
      DuplicateFormFieldCommand(
        fieldName: name, newName: newName, pageID: pageID, offset: [0, -30], sharing: sharing))
  }

  @discardableResult
  func alignAuthoredFields(_ names: [String], edge: FormWidgetEdge) -> Bool {
    applyFormAuthoring(AlignFormWidgetsCommand(fields: names, edge: edge))
  }

  @discardableResult
  func distributeAuthoredFields(_ names: [String], axis: DistributeFormWidgetsCommand.Axis)
    -> Bool
  {
    applyFormAuthoring(DistributeFormWidgetsCommand(fields: names, axis: axis))
  }

  @discardableResult
  func reorderAuthoredFields(_ order: [String]) -> Bool {
    applyFormAuthoring(ReorderFormFieldsCommand(order: order))
  }

  @discardableResult
  func renameAuthoredFormField(from: String, to: String) -> Bool {
    applyFormAuthoring(RenameFormFieldCommand(fieldName: from, newName: to))
  }

  @discardableResult
  func deleteAuthoredFormField(name: String) -> Bool {
    applyFormAuthoring(RemoveFormFieldCommand(fieldName: name))
  }

  /// PAG-09: a single attachment manager for adding, describing, removing and
  /// exporting embedded files. Every mutation is one canonical undo step.
  var canManageAttachments: Bool { editSession.currentGraph != nil }

  func manageAttachments() {
    if let window = attachmentsWindow {
      refreshAttachments()
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard canManageAttachments else { return }
    let model = AttachmentsModel()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = "Attachments"
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("spdf-attachments")
    window.contentView = NSHostingView(
      rootView: AttachmentsManagerPanel(
        model: model, canEditContent: canEditContent,
        editingRestrictionNotice: contentEditingRestrictionNotice,
        onAdd: { [weak self] in self?.addAttachmentFromManager() },
        onEditDescription: { [weak self] attachment in
          self?.editAttachmentDescription(attachment)
        },
        onRemove: { [weak self] attachment in self?.removeAttachment(attachment) },
        onExportAll: { [weak self] in self?.exportAttachments() },
        onClose: { [weak self, weak window] in
          window?.close()
          self?.attachmentsModel = nil
          self?.attachmentsWindow = nil
        }))
    attachmentsModel = model
    attachmentsWindow = window
    refreshAttachments()
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func refreshAttachments() {
    guard let model = attachmentsModel else { return }
    guard let graph = editSession.currentGraph else {
      model.attachments = []
      return
    }
    model.attachments = PDFAttachmentInventory.attachments(in: graph)
  }

  private func addAttachmentFromManager() {
    guard canEditContent else { return }
    let open = NSOpenPanel()
    open.allowsMultipleSelection = false
    open.canChooseFiles = true
    open.canChooseDirectories = false
    open.message = "Choose a file to embed in this PDF."
    guard open.runModal() == .OK, let url = open.url else { return }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    guard (size ?? 0) <= AddAttachmentCommand.maximumBytes else {
      let alert = NSAlert()
      alert.messageText = "Attachment Too Large"
      alert.informativeText = "The attachment exceeds the 64 MiB embedding limit."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      presentError(error)
      return
    }
    guard data.count <= AddAttachmentCommand.maximumBytes else {
      let alert = NSAlert()
      alert.messageText = "Attachment Too Large"
      alert.informativeText = "The attachment exceeds the 64 MiB embedding limit."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
    nameField.stringValue = url.lastPathComponent
    let descriptionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
    descriptionField.placeholderString = "Optional description"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Name:"), nameField],
      [NSTextField(labelWithString: "Description:"), descriptionField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 440, height: 54)
    let alert = NSAlert()
    alert.messageText = "Add Attachment"
    alert.informativeText = "Embeds \(url.lastPathComponent) in this PDF."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      NSSound.beep()
      return
    }
    let description = descriptionField.stringValue.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    do {
      try editSession.apply(
        PDFTransaction([
          AddAttachmentCommand(
            name: name, fileName: url.lastPathComponent, mimeType: mime,
            description: description.isEmpty ? nil : description, data: data)
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshAttachments()
  }

  private func editAttachmentDescription(_ attachment: PDFAttachment) {
    guard canEditContent else { return }
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 22))
    field.stringValue = attachment.description ?? ""
    field.placeholderString = "Leave empty to remove the description"
    let alert = NSAlert()
    alert.messageText = "Attachment Description"
    alert.informativeText = "Description for \(attachment.name)."
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try editSession.apply(
        PDFTransaction([
          SetAttachmentDescriptionCommand(
            name: attachment.name, description: field.stringValue)
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshAttachments()
  }

  private func removeAttachment(_ attachment: PDFAttachment) {
    guard canEditContent else { return }
    let alert = NSAlert()
    alert.messageText = "Remove attachment?"
    alert.informativeText =
      "\(attachment.name) will be removed from this PDF. The bytes remain in older saved "
      + "revisions until the document is saved; Undo is available in this editing session."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try editSession.apply(
        PDFTransaction([RemoveAttachmentCommand(name: attachment.name)]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshAttachments()
  }

  /// P34-018: extract attachments only to a folder the user chooses; nothing
  /// is executed or opened, and names are sanitized.
  var canExportAttachments: Bool {
    guard let graph = editSession.currentGraph else { return false }
    return !PDFAttachmentInventory.attachments(in: graph).isEmpty
  }

  func exportAttachments() {
    guard let graph = editSession.currentGraph else { return }
    let attachments = PDFAttachmentInventory.attachments(in: graph)
    guard !attachments.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Extract"
    panel.message = "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")"
    panel.begin { [weak self] response in
      guard response == .OK, let directory = panel.url, let self else { return }
      do {
        let urls = try PDFAttachmentExport.extract(attachments, from: graph, to: directory)
        let alert = NSAlert()
        alert.messageText = "Attachments Extracted"
        alert.informativeText = urls.map(\.lastPathComponent).joined(separator: "\n")
        alert.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }

  /// Testable path behind the panel.
  @discardableResult
  func exportAttachments(to directory: URL) throws -> [URL] {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "There is no document to export")
    }
    return try PDFAttachmentExport.extract(
      PDFAttachmentInventory.attachments(in: graph), from: graph, to: directory)
  }

  /// P34-021/P34-022: native print dialog over the whole document with
  /// page-range handling; geometry follows page boxes and rotation.
  var canPrint: Bool { editSession.currentGraph != nil }

  func printDocument() {
    guard let graph = editSession.currentGraph else { return }
    do {
      try PDFPrintExport.runPrintPanel(
        pageIDs: editSession.pageIDs, in: graph, in: windowControllers.first?.window)
    } catch {
      presentError(error)
    }
  }

  /// P34-023/P34-024: print-to-PDF derivative with an explicit flattening
  /// disclosure before the save panel.
  func exportPrintPDF() {
    guard finishPendingEdits() else { return }
    let alert = NSAlert()
    alert.messageText = "Export Print PDF"
    alert.informativeText =
      "This derivative is appearance-oriented: structure tags, form fields, and annotation interactivity are flattened into rendered pages."
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "print.pdf"
    panel.allowedContentTypes = [.pdf]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try self.exportPrintPDF(to: url)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// Testable path behind the panel.
  func exportPrintPDF(to url: URL) throws {
    let graph = try prepareDerivative(
      to: url, requiresEditable: false, allowSigned: true)
    try PDFPrintExport.writePDF(pageIDs: editSession.pageIDs, in: graph, to: url)
  }

  /// P34-007/P34-008: export images with explicit provenance (original bytes
  /// or rendered reconstruction).
  var canExportImages: Bool {
    guard let graph = editSession.currentGraph,
      let images = try? PDFImageInventory.images(in: graph, pageIDs: editSession.pageIDs)
    else { return false }
    return !images.isEmpty
  }

  func exportImages() {
    guard let graph = editSession.currentGraph,
      let images = try? PDFImageInventory.images(in: graph, pageIDs: editSession.pageIDs),
      !images.isEmpty
    else { return }
    let alert = NSAlert()
    alert.messageText = "Export Images"
    alert.informativeText =
      "\(images.count) image placement\(images.count == 1 ? "" : "s"). Standalone JPEG/JPEG 2000 streams and stored RGB/gray samples export as originals; masked or transformed images are reconstructed by rendering. Files are named page-by-page."
    alert.addButton(withTitle: "Choose Folder…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Export"
    panel.begin { [weak self] response in
      guard response == .OK, let directory = panel.url, let self else { return }
      let baseName =
        self.fileURL?.deletingPathExtension().lastPathComponent.isEmpty == false
        ? self.fileURL!.deletingPathExtension().lastPathComponent : "image"
      Task { @MainActor in
        do {
          let exported = try await self.exportImages(to: directory, baseName: baseName)
          guard !TerminationCoordinator.shared.isPreparing else { return }
          let alert = NSAlert()
          alert.messageText = "Images Exported"
          alert.informativeText =
            "\(exported.count) file\(exported.count == 1 ? "" : "s") written."
          alert.runModal()
        } catch is CancellationError {
        } catch {
          self.presentError(error)
        }
      }
    }
  }

  /// Testable path behind the panel.
  @discardableResult
  func exportImages(
    to directory: URL, baseName: String = "image",
    options: PDFImageExtractionOptions = .init()
  ) async throws -> [PDFExportedImage] {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "There is no document to export")
    }
    let total = try PDFImageInventory.images(in: graph, pageIDs: editSession.pageIDs).count
    let job = try beginDocumentJob(title: "Exporting images", total: total)
    defer { jobCenter.finish(id: job) }
    let relay = JobProgressRelay(center: jobCenter)
    let progress: @Sendable (Int, Int) -> Void = { [relay, job] done, _ in
      relay.update(id: job, completed: done)
    }
    return try await PDFImageExport.export(
      pageIDs: editSession.pageIDs, in: graph, to: directory, baseName: baseName,
      options: options, progress: progress)
  }

  /// P35-015–P35-019: export the document as an editable DOCX reconstruction.
  func exportDOCX() {
    guard finishPendingEdits() else { return }
    guard editSession.currentGraph != nil, !editSession.pageIDs.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Export DOCX"
    alert.informativeText =
      "The document is reconstructed as an editable Word document: paragraphs, headings, lists, tables, images, hyperlinks, headers/footers with page-number fields, and documented font substitutions where reliably detected. "
      + DOCXExport.fidelityDisclosure
    alert.addButton(withTitle: "Export…")
    alert.addButton(withTitle: "Cancel")
    let checkbox = NSButton(
      checkboxWithTitle: "Export uncertain regions as appearance images", target: nil, action: nil)
    checkbox.state = .off
    alert.accessoryView = checkbox
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let mode: DOCXExportMode = checkbox.state == .on ? .appearance : .editable
    let panel = NSSavePanel()
    if let docxType = UTType(filenameExtension: "docx") {
      panel.allowedContentTypes = [docxType]
    }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    panel.nameFieldStringValue = base.isEmpty ? "Document.docx" : "\(base).docx"
    panel.prompt = "Export"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      Task { @MainActor in
        do {
          let blocks = try await self.exportDOCX(to: url, mode: mode)
          guard !TerminationCoordinator.shared.isPreparing else { return }
          let alert = NSAlert()
          alert.messageText = "DOCX Exported"
          alert.informativeText =
            "\(blocks) reconstructed block\(blocks == 1 ? "" : "s") written."
          alert.runModal()
        } catch {
          self.presentError(error)
        }
      }
    }
  }

  /// P35-022: review the reconstruction before exporting. Ambiguous reading
  /// order (low-confidence blocks) is flagged in the preview.
  func previewDOCX() {
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    guard
      let reconstruction = try? DOCXReconstructionBuilder.reconstruct(
        pageIDs: editSession.pageIDs, in: graph)
    else { return }
    let preview = DOCXPreview.build(reconstruction: reconstruction)
    let alert = NSAlert()
    alert.messageText = "DOCX Reconstruction Preview"
    alert.informativeText =
      "\(preview.totalCount) block\(preview.totalCount == 1 ? "" : "s"), "
      + "\(preview.ambiguousCount) ambiguous. Ambiguous blocks are guesses from the visual analysis; export them as appearance images to keep their exact look."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
    scroll.hasVerticalScroller = true
    let textView = NSTextView(frame: scroll.bounds)
    textView.isEditable = false
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = preview.text()
    scroll.documentView = textView
    alert.accessoryView = scroll
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Export…")
    if alert.runModal() == .alertSecondButtonReturn {
      exportDOCX()
    }
  }

  /// Testable path behind the panel.
  @discardableResult
  func exportDOCX(to url: URL, mode: DOCXExportMode = .editable) async throws -> Int {
    let graph = try prepareDerivative(
      to: url, requiresEditable: false, allowSigned: true)
    let job = try beginDocumentJob(title: "Exporting DOCX", total: 1)
    defer { jobCenter.finish(id: job) }
    return try await DOCXDocumentExport.export(
      pageIDs: editSession.pageIDs, in: graph, to: url, mode: mode)
  }

  /// P37-001/P37-007/P37-019: a read-only compatibility report (version and
  /// extensions, archival inventory, print preflight). Nothing is written and
  /// no conformance is claimed.
  func showCompatibilityReport() {
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    let audit = PDFVersionAudit.audit(in: graph)
    let archival = ArchivalInventory.inventory(graph, pageIDs: editSession.pageIDs)
    let preflight = PrintPreflightInventory.inventory(graph, pageIDs: editSession.pageIDs)
    let accessibility = PDFAccessibilityAudit.audit(graph, pageIDs: editSession.pageIDs)
    let checks = (try? PreflightCheckReport.run(graph, pageIDs: editSession.pageIDs))
    let facts = PDFDocumentInventory.documentFacts(
      in: graph, pageCount: editSession.pageIDs.count)
    let assessment = PDFDocumentInventory.assess(
      in: graph, pageCount: editSession.pageIDs.count)
    var inventoryLines = ["Document inventory — \(assessment.summary)"]
    let metadata = facts.metadata
    if !metadata.isEmpty {
      inventoryLines.append(
        "  Metadata: title \(metadata.title ?? "—"), author \(metadata.author ?? "—"), language \(metadata.language ?? "—")"
      )
    }
    if !facts.activeContent.summary.isEmpty {
      inventoryLines.append(
        "  Active content: " + facts.activeContent.summary.joined(separator: ", "))
    }
    let graphicalSignatures = PDFDocumentInventory.graphicalSignatureCount(
      in: graph, pageIDs: editSession.pageIDs)
    if graphicalSignatures > 0 {
      inventoryLines.append(
        "  Graphical signatures: \(graphicalSignatures) placed mark\(graphicalSignatures == 1 ? "" : "s") (visual only; not digital signatures)"
      )
    }
    if !facts.optionalContent.groups.isEmpty {
      inventoryLines.append(
        "  Optional content: \(facts.optionalContent.groups.count) group\(facts.optionalContent.groups.count == 1 ? "" : "s")"
      )
    }
    let report = [
      inventoryLines.joined(separator: "\n"), "", audit.report(), "", archival.report(), "",
      preflight.report(), "", checks?.report() ?? "Print preflight checks unavailable.", "",
      accessibility.report(),
    ].joined(separator: "\n")
    let alert = NSAlert()
    alert.messageText = "Compatibility Report"
    alert.informativeText =
      "Read-only audit: no conformance is claimed, nothing is written, and the source PDF is not modified."
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
    scroll.hasVerticalScroller = true
    let textView = NSTextView(frame: scroll.bounds)
    textView.isEditable = false
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = report
    scroll.documentView = textView
    alert.accessoryView = scroll
    alert.addButton(withTitle: "Close")
    alert.runModal()
  }

  /// P37-012/P37-013/P37-014: create a staged archival copy (safe
  /// transformations only), then validate it with an independent validator
  /// when one is available. No PDF/A identifier is ever written.
  func createArchivalCopy() {
    guard finishPendingEdits() else { return }
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    let plan = ArchivalDerivative.plan(graph, pageIDs: editSession.pageIDs)
    let alert = NSAlert()
    alert.messageText = "Create Archival Copy"
    alert.informativeText =
      plan.report()
      + "\n\nOnly the safe transformations are applied automatically; transformations that remove content or affect rendering need an explicit decision. No PDF/A identifier is written."
    alert.addButton(withTitle: "Apply Safe Transformations…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let panel = NSSavePanel()
    if let type = UTType(filenameExtension: "pdf") { panel.allowedContentTypes = [type] }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    panel.nameFieldStringValue = (base.isEmpty ? "Document" : base) + "-archival.pdf"
    panel.prompt = "Create"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        let graph = try self.prepareDerivative(to: url)
        let plan = ArchivalDerivative.plan(graph, pageIDs: self.editSession.pageIDs)
        let staged = try ArchivalDerivative.stage(
          graph, plan: plan, applying: plan.safeKinds)
        let data = try PDFWriter.write(staged.graph)
        try VerifiedFileWriter.write(data, to: url) { written in
          let reparsed = try PDFParser.parse(
            written, limits: SPDFDocumentResourcePolicy.parsingLimits)
          guard reparsed.pageCount == self.editSession.pageIDs.count else {
            throw PDFError(.malformed, "Archival copy failed page verification")
          }
        }
        let validation = ArchivalDerivative.validate(data)
        let validationText =
          validation?.report()
          ?? "No independent validator is available on this system; nothing is claimed."
        let result = NSAlert()
        result.messageText = "Archival Copy Written"
        result.informativeText =
          "Applied: \(staged.applied.map(\.rawValue).joined(separator: ", ")).\n\n\(validationText)"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = validationText
        scroll.documentView = textView
        result.accessoryView = scroll
        result.addButton(withTitle: "Close")
        result.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }

  /// P37-024: explicit color conversion with before/after previews. Only
  /// supported 8-bit device images are converted; nothing else is guessed.
  func convertColors() {
    guard finishPendingEdits() else { return }
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    let choice = NSAlert()
    choice.messageText = "Convert Colors"
    choice.informativeText =
      "Only 8-bit DeviceRGB/DeviceGray images are converted; CMYK, ICC profiles, masks, and unusual filters are refused and reported. The current document is not modified until you save a copy."
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 25))
    popup.addItems(withTitles: ["To Grayscale", "To RGB"])
    choice.accessoryView = popup
    choice.addButton(withTitle: "Convert…")
    choice.addButton(withTitle: "Cancel")
    guard choice.runModal() == .alertFirstButtonReturn else { return }
    let target: ColorConversion.Target = popup.indexOfSelectedItem == 0 ? .gray : .rgb
    guard
      let converted = try? ColorConversion.convert(
        graph, pageIDs: editSession.pageIDs, to: target)
    else { return }
    guard converted.report.convertedImages > 0 else {
      let alert = NSAlert()
      alert.messageText = "Nothing to Convert"
      alert.informativeText = converted.report.report()
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    // Before/after previews of the first page that has an image.
    let images =
      (try? PDFImageInventory.images(
        in: graph, pageIDs: editSession.pageIDs)) ?? []
    let pageIndex = images.first?.pageIndex ?? 0
    let preview = NSStackView()
    preview.orientation = .horizontal
    preview.spacing = 10
    func previewView(_ graph: PDFGraph, label: String) -> NSView {
      let column = NSStackView()
      column.orientation = .vertical
      column.spacing = 4
      let title = NSTextField(labelWithString: label)
      title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      column.addArrangedSubview(title)
      if pageIndex < editSession.pageIDs.count,
        let data = try? PageImageExport.regionImageData(
          pageID: editSession.pageIDs[pageIndex], in: graph,
          region: pageBox(of: editSession.pageIDs[pageIndex], in: graph),
          options: PageImageExportOptions(format: .png, dpi: 72)),
        let image = NSImage(data: data)
      {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 285)
        column.addArrangedSubview(view)
      }
      return column
    }
    preview.addArrangedSubview(previewView(graph, label: "Before"))
    preview.addArrangedSubview(previewView(converted.graph, label: "After"))
    let alert = NSAlert()
    alert.messageText = "Color Conversion Preview"
    alert.informativeText = converted.report.report()
    alert.accessoryView = preview
    alert.addButton(withTitle: "Save Copy…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let panel = NSSavePanel()
    if let type = UTType(filenameExtension: "pdf") { panel.allowedContentTypes = [type] }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    panel.nameFieldStringValue =
      (base.isEmpty ? "Document" : base) + "-converted.pdf"
    panel.prompt = "Save"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        let graph = try self.prepareDerivative(to: url)
        let fresh = try ColorConversion.convert(
          graph, pageIDs: self.editSession.pageIDs, to: target)
        guard fresh.report.convertedImages > 0 else {
          throw PDFError(.unsupported, "Nothing remained to convert")
        }
        let data = try PDFWriter.write(fresh.graph)
        try VerifiedFileWriter.write(data, to: url) { written in
          let reparsed = try PDFParser.parse(
            written, limits: SPDFDocumentResourcePolicy.parsingLimits)
          guard reparsed.pageCount == self.editSession.pageIDs.count else {
            throw PDFError(.malformed, "Converted copy failed page verification")
          }
        }
      } catch {
        self.presentError(error)
      }
    }
  }

  /// The page's display box for previews.
  private func pageBox(of pageID: PDFObjectID, in graph: PDFGraph) -> [Double] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [0, 0, 612, 792] }
    for key in ["CropBox", "MediaBox"] {
      if case .array(let values)? = page[PDFName(key)] {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
    }
    return [0, 0, 612, 792]
  }

  /// P38-019/P38-021: repair a damaged document into a separate copy. The
  /// source file is never overwritten; the repaired copy opens with its edit
  /// gate set from the repair report.
  func repairDocument() {
    let sourceData: Data?
    if let fileURL, let data = try? Data(contentsOf: fileURL) {
      sourceData = data
    } else {
      sourceData = try? data(ofType: "com.adobe.pdf")
    }
    guard let sourceData else { return }
    let repaired = PDFRepair.repair(sourceData)
    guard let repairedData = repaired.data else {
      let alert = NSAlert()
      alert.messageText = "Repair Refused"
      alert.informativeText = repaired.report.report()
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    if !repaired.report.wasRepaired {
      let alert = NSAlert()
      alert.messageText = "No Repair Needed"
      alert.informativeText = repaired.report.report()
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let panel = NSSavePanel()
    if let type = UTType(filenameExtension: "pdf") { panel.allowedContentTypes = [type] }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    panel.nameFieldStringValue = (base.isEmpty ? "Document" : base) + "-repaired.pdf"
    panel.prompt = "Save Copy"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try DerivativeOutputPolicy.validateDestination(url, source: self.fileURL)
        try repairedData.write(to: url, options: .atomic)
        let report = repaired.report
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
          document, _, _ in
          if let repairedDocument = document as? SPDFDocument {
            repairedDocument.editSession.markRepaired(editSafe: report.editSafe)
          }
          let alert = NSAlert()
          alert.messageText = "Repaired Copy Opened"
          alert.informativeText = report.report()
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
      } catch {
        self.presentError(error)
      }
    }
  }

  /// P23-023: the page organizer window. Actions go through the session so
  /// each one is a single compound undo step.
  /// PAG-03: split the current document into page groups written as separate
  /// verified PDFs with predictable names. Every page may appear at most once
  /// across the groups.
  @discardableResult
  func splitDocument(
    to directory: URL, pageGroups: [[PDFObjectID]]
  ) throws -> [(url: URL, report: DocumentAssemblyReport)] {
    guard let graph = editSession.currentGraph, !pageGroups.isEmpty else {
      throw PDFError(.malformed, "Choose at least one page group")
    }
    let allPages = Set(editSession.pageIDs)
    var seen = Set<PDFObjectID>()
    for group in pageGroups {
      guard !group.isEmpty else {
        throw PDFError(.malformed, "A split part has no pages")
      }
      for pageID in group {
        guard allPages.contains(pageID) else {
          throw PDFError(.malformed, "A split part references a missing page")
        }
        guard seen.insert(pageID).inserted else {
          throw PDFError(.unsupported, "A page appears in more than one split part")
        }
      }
    }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    let width = max(2, String(pageGroups.count).count)
    var results: [(URL, DocumentAssemblyReport)] = []
    for (index, group) in pageGroups.enumerated() {
      let extracted = try DocumentAssembly.extract(
        graph, pageIDs: group, labels: .preserve, catalogData: .firstDocument)
      let data = try PDFWriter.write(extracted.graph)
      let name = String(format: "%@-part-%0\(width)d.pdf", base, index + 1)
      let url = directory.appendingPathComponent(name)
      try VerifiedFileWriter.write(
        data, to: url, expectedGraph: extracted.graph,
        limits: SPDFDocumentResourcePolicy.parsingLimits)
      results.append((url, extracted.report))
    }
    return results
  }

  /// PAG-03: split by measured output size. A single oversized page is kept
  /// as its own part and reported.
  func splitDocumentBySize(
    to directory: URL, maxBytes: Int
  ) throws -> (results: [(url: URL, report: DocumentAssemblyReport)], oversized: Set<PDFObjectID>) {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "There is no document to split")
    }
    let grouped = try DocumentAssembly.groupPagesBySize(
      editSession.pageIDs, in: graph, maxBytes: maxBytes,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
    let results = try splitDocument(to: directory, pageGroups: grouped.groups)
    return (results, grouped.oversized)
  }

  /// PAG-03: choose every-N-pages, explicit ranges, bookmarks, or a measured
  /// byte-size limit, then a destination folder.
  func presentSplitDocument() {
    guard canEditContent, let viewer, viewer.pageCount > 0 else { return }
    let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 24))
    modePopup.addItems(withTitles: [
      "Every N pages", "Page ranges", "Top-level bookmarks", "Maximum size",
    ])
    let nField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    nField.stringValue = "1"
    let rangesField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
    rangesField.stringValue = "1-\(viewer.pageCount)"
    let sizeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    sizeField.stringValue = "5"
    let rows: [[NSView]] = [
      [NSTextField(labelWithString: "Split:"), modePopup],
      [NSTextField(labelWithString: "Pages per file:"), nField],
      [NSTextField(labelWithString: "Ranges:"), rangesField],
      [NSTextField(labelWithString: "Max MB per file:"), sizeField],
    ]
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 340, height: 130)
    let alert = NSAlert()
    alert.messageText = "Split Document"
    alert.informativeText =
      "Every-N groups pages in order; ranges treat each comma group as one file "
      + "(for example 1-3, 4-6); bookmarks start a new part at each top-level bookmark "
      + "with a destination; maximum size measures each assembled part and keeps an "
      + "oversized single page alone. A page cannot appear in two parts."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Choose Folder…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let pageIDs = editSession.pageIDs
    let isSizeMode = modePopup.indexOfSelectedItem == 3
    let maxBytes = max(1, Int((Double(sizeField.stringValue) ?? 5) * 1_024 * 1_024))
    var groups: [[PDFObjectID]] = []
    switch modePopup.indexOfSelectedItem {
    case 0:
      let n = max(1, Int(nField.stringValue) ?? 1)
      var index = 0
      while index < pageIDs.count {
        let end = min(pageIDs.count, index + n)
        groups.append(Array(pageIDs[index..<end]))
        index = end
      }
    case 1:
      for part in rangesField.stringValue.split(separator: ",") {
        let indices = pageIndices(from: String(part), count: pageIDs.count)
        guard !indices.isEmpty else { continue }
        groups.append(indices.map { pageIDs[$0] })
      }
    case 2:
      guard let graph = editSession.currentGraph else { return }
      let items = PDFOutlineInventory.items(in: graph, pageIDs: pageIDs)
      var starts: [(page: Int, title: String)] = []
      for item in items {
        guard let page = item.pageIndex, page >= 0, page < pageIDs.count,
          !starts.contains(where: { $0.page == page })
        else { continue }
        starts.append((page, item.title))
      }
      starts.sort { $0.page < $1.page }
      guard !starts.isEmpty else {
        presentError(
          PDFError(.unsupported, "This document has no top-level bookmarks with page destinations"))
        return
      }
      if let first = starts.first, first.page > 0 {
        groups.append(Array(pageIDs[0..<first.page]))
      }
      for (index, start) in starts.enumerated() {
        let end = index + 1 < starts.count ? starts[index + 1].page : pageIDs.count
        guard start.page < end else { continue }
        groups.append(Array(pageIDs[start.page..<end]))
      }
    default:
      break
    }
    guard isSizeMode || !groups.isEmpty else {
      NSSound.beep()
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Split Here"
    panel.begin { [weak self] response in
      guard response == .OK, let directory = panel.url, let self else { return }
      do {
        let results: [(url: URL, report: DocumentAssemblyReport)]
        var oversized = Set<PDFObjectID>()
        if isSizeMode {
          let outcome = try self.splitDocumentBySize(
            to: directory, maxBytes: maxBytes)
          results = outcome.results
          oversized = outcome.oversized
        } else {
          results = try self.splitDocument(to: directory, pageGroups: groups)
        }
        var detail =
          results.map { "\($0.url.lastPathComponent): \($0.report.report())" }
          .joined(separator: "\n\n")
        if !oversized.isEmpty {
          let pages = self.editSession.pageIDs.enumerated()
            .filter { oversized.contains($0.element) }
            .map { String($0.offset + 1) }
          detail +=
            "\n\nThese single pages exceed the chosen size and were kept alone: "
            + pages.joined(separator: ", ")
        }
        let alert = NSAlert()
        alert.messageText = "Document Split"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }

  private struct PreparedCombination {
    let graph: PDFGraph
    let sourceURLs: [URL]
    let summaries: [(name: String, pages: Int)]
    let report: DocumentAssemblyReport

    var pageCount: Int {
      summaries.reduce(0) { $0 + $1.pages }
    }
  }

  /// PAG-02: assemble selected PDFs in memory so order and conflicts can be
  /// inspected before any output is written.
  private func prepareCombinedDocument(
    from urls: [URL], allowFieldRenames: Bool = true, keepBookmarks: Bool = true
  ) throws -> PreparedCombination {
    guard !urls.isEmpty else {
      throw PDFError(.malformed, "Choose at least one PDF to combine")
    }
    var sources: [(graph: PDFGraph, pageIDs: [PDFObjectID])] = []
    var summaries: [(String, Int)] = []
    for file in urls {
      let data = try Data(contentsOf: file)
      let parsed = try PDFParser.parse(
        data, limits: SPDFDocumentResourcePolicy.parsingLimits)
      sources.append((graph: parsed.graph, pageIDs: parsed.pageIDs))
      summaries.append((file.lastPathComponent, parsed.pageCount))
    }
    if !allowFieldRenames {
      let duplicates = try FormInventory.duplicateNames(across: sources.map(\.graph))
      if !duplicates.isEmpty {
        throw PDFError(
          .unsupported,
          "Duplicate field names need renaming or removal: "
            + duplicates.prefix(8).joined(separator: ", "))
      }
    }
    let merged = try DocumentAssembly.merge(
      sources, labels: .preserve,
      catalogData: keepBookmarks ? .firstDocument : .none)
    return PreparedCombination(
      graph: merged.graph, sourceURLs: urls, summaries: summaries, report: merged.report)
  }

  /// PAG-02: write an inspected combination through the verified writer.
  private func writeCombinedDocument(_ prepared: PreparedCombination, to url: URL) throws {
    for file in prepared.sourceURLs {
      try DerivativeOutputPolicy.validateDestination(url, source: file)
    }
    let data = try PDFWriter.write(
      prepared.graph, limits: SPDFDocumentResourcePolicy.parsingLimits)
    try VerifiedFileWriter.write(
      data, to: url, expectedGraph: prepared.graph,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
  }

  /// PAG-02: merge external PDFs in the chosen order into one verified file.
  /// The assembly layer refuses encrypted/signed sources and reports renamed
  /// fields or dropped destinations.
  @discardableResult
  func combineDocuments(from urls: [URL], to url: URL) throws -> DocumentAssemblyReport {
    let prepared = try prepareCombinedDocument(from: urls)
    try writeCombinedDocument(prepared, to: url)
    return prepared.report
  }

  /// PAG-02: choose source PDFs in order, inspect the result and conflicts,
  /// then write one combined file.
  func presentCombineDocuments() {
    let open = NSOpenPanel()
    open.allowedContentTypes = [.pdf]
    open.allowsMultipleSelection = true
    open.message = "Choose PDFs, then reorder them in the combine window."
    open.prompt = "Choose"
    open.begin { [weak self] response in
      guard response == .OK, !open.urls.isEmpty, let self else { return }
      var files: [CombineDocumentsModel.File] = []
      for url in open.urls {
        guard let data = try? Data(contentsOf: url),
          let parsed = try? PDFParser.parse(
            data, limits: SPDFDocumentResourcePolicy.parsingLimits)
        else { continue }
        files.append(CombineDocumentsModel.File(url: url, pageCount: parsed.pageCount))
      }
      guard !files.isEmpty else {
        self.presentError(PDFError(.malformed, "None of the selected PDFs could be read"))
        return
      }
      let model = CombineDocumentsModel(files: files)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = "Combine Documents"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: CombineDocumentsPanel(model: model))
      model.onCancel = { [weak self, weak window] in
        window?.close()
        self?.combineModel = nil
        self?.combineWindow = nil
      }
      model.onCombine = { [weak self, weak window] urls, allowFieldRenames, keepBookmarks in
        window?.close()
        self?.combineModel = nil
        self?.combineWindow = nil
        self?.reviewCombination(
          urls, allowFieldRenames: allowFieldRenames, keepBookmarks: keepBookmarks)
      }
      self.combineModel = model
      self.combineWindow = window
      window.makeKeyAndOrderFront(nil)
    }
  }

  /// PAG-02: assemble the ordered files in memory and show conflicts before
  /// asking for a destination.
  private func reviewCombination(
    _ urls: [URL], allowFieldRenames: Bool = true, keepBookmarks: Bool = true
  ) {
    let prepared: PreparedCombination
    do {
      prepared = try prepareCombinedDocument(
        from: urls, allowFieldRenames: allowFieldRenames,
        keepBookmarks: keepBookmarks)
    } catch {
      presentError(error)
      return
    }
    var detail = prepared.summaries.enumerated().map {
      "\($0.offset + 1). \($0.element.name) — \($0.element.pages) page"
        + ($0.element.pages == 1 ? "" : "s")
    }.joined(separator: "\n")
    detail += "\n\nCombined result: \(prepared.pageCount) page"
      + (prepared.pageCount == 1 ? "" : "s") + "\n"
    detail += "Duplicate fields: "
      + (allowFieldRenames ? "renamed automatically" : "refused") + "\n"
    detail += "Bookmarks: "
      + (keepBookmarks ? "kept from the first document" : "discarded") + "\n\n"
    detail += prepared.report.report()
    let review = NSAlert()
    review.messageText = "Combine Documents"
    review.informativeText = detail
    review.addButton(withTitle: "Choose Destination…")
    review.addButton(withTitle: "Cancel")
    guard review.runModal() == .alertFirstButtonReturn else { return }
    let save = NSSavePanel()
    save.allowedContentTypes = [.pdf]
    let base = editSession.pageIDs.isEmpty
      ? "Combined" : (fileURL?.deletingPathExtension().lastPathComponent ?? "Combined")
    save.nameFieldStringValue = "\(base)-combined.pdf"
    save.begin { [weak self] saveResponse in
      guard saveResponse == .OK, let url = save.url, let self else { return }
      do {
        try self.writeCombinedDocument(prepared, to: url)
        let alert = NSAlert()
        alert.messageText = "Documents Combined"
        alert.informativeText = prepared.report.report()
        alert.addButton(withTitle: "OK")
        alert.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }

  /// PAG-09: change a bookmark's title and page target.
  func presentEditBookmark() {
    guard canEditContent, let graph = editSession.currentGraph else { return }
    var flat: [(title: String, depth: Int, objectID: PDFObjectID, pageIndex: Int?)] = []
    func walk(_ items: [PDFOutlineItem], depth: Int) {
      for item in items {
        if let id = item.objectID {
          flat.append((item.title, depth, id, item.pageIndex))
        }
        walk(item.children, depth: depth + 1)
      }
    }
    walk(
      PDFOutlineInventory.items(in: graph, pageIDs: editSession.pageIDs), depth: 0)
    guard !flat.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Bookmarks"
      alert.informativeText = "This document has no bookmarks to edit."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    popup.addItems(withTitles: flat.map {
      String(repeating: "  ", count: $0.depth) + $0.title
    })
    let choose = NSAlert()
    choose.messageText = "Edit Bookmark"
    choose.informativeText = "Choose the bookmark to edit."
    choose.accessoryView = popup
    choose.addButton(withTitle: "Continue")
    choose.addButton(withTitle: "Cancel")
    guard choose.runModal() == .alertFirstButtonReturn else { return }
    let item = flat[max(0, popup.indexOfSelectedItem)]
    let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
    titleField.stringValue = item.title
    let pageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    pageField.stringValue = "\((item.pageIndex ?? max(0, (viewer?.pageNumber ?? 1) - 1)) + 1)"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Title:"), titleField],
      [NSTextField(labelWithString: "Page:"), pageField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
    let edit = NSAlert()
    edit.messageText = "Edit Bookmark"
    edit.informativeText = "The bookmark destination is updated to the chosen page."
    edit.accessoryView = grid
    edit.addButton(withTitle: "Apply")
    edit.addButton(withTitle: "Cancel")
    guard edit.runModal() == .alertFirstButtonReturn else { return }
    let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let page = Int(pageField.stringValue),
      page >= 1, page <= editSession.pageIDs.count, !title.isEmpty
    else {
      NSSound.beep()
      return
    }
    do {
      try editSession.apply(
        PDFTransaction([
          EditBookmarkCommand(
            objectID: item.objectID, title: title,
            pageID: editSession.pageIDs[page - 1])
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// PAG-09: an outline manager with explicit hierarchy operations. Every
  /// change is a canonical undo step and refreshes the window in place.
  var canManageBookmarks: Bool { editSession.currentGraph != nil }

  func manageBookmarks() {
    if let window = bookmarksWindow {
      refreshBookmarks()
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard canManageBookmarks else { return }
    let model = BookmarksModel()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = "Bookmarks"
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("spdf-bookmarks")
    window.contentView = NSHostingView(
      rootView: BookmarksManagerPanel(
        model: model, canEditContent: canEditContent,
        editingRestrictionNotice: contentEditingRestrictionNotice,
        onAdd: { [weak self] in self?.presentAddBookmark() },
        onEdit: { [weak self] entry in self?.editBookmark(entry) },
        onMove: { [weak self] entry, direction in
          self?.moveBookmark(entry, direction: direction)
        },
        onNest: { [weak self] entry in self?.nestBookmark(entry) },
        onOutdent: { [weak self] entry in self?.outdentBookmark(entry) },
        onRemove: { [weak self] entry in self?.removeBookmark(entry) },
        onSelect: { [weak self] entry in
          guard let page = entry.pageIndex else { return }
          self?.viewer?.go(to: page + 1)
        },
        onClose: { [weak self, weak window] in
          window?.close()
          self?.bookmarksModel = nil
          self?.bookmarksWindow = nil
        }))
    bookmarksModel = model
    bookmarksWindow = window
    refreshBookmarks()
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func refreshBookmarks() {
    guard let model = bookmarksModel else { return }
    guard let graph = editSession.currentGraph else {
      model.entries = []
      return
    }
    let items = PDFOutlineInventory.items(in: graph, pageIDs: editSession.pageIDs)
    var entries: [BookmarkManagerEntry] = []
    func walk(
      _ items: [PDFOutlineItem], depth: Int, parentID: PDFObjectID?
    ) {
      for (index, item) in items.enumerated() {
        guard let id = item.objectID else { continue }
        entries.append(
          BookmarkManagerEntry(
            id: id, title: item.title, pageIndex: item.pageIndex, depth: depth,
            previousID: index > 0 ? items[index - 1].objectID : nil,
            nextID: index + 1 < items.count ? items[index + 1].objectID : nil,
            parentID: parentID))
        walk(item.children, depth: depth + 1, parentID: id)
      }
    }
    walk(items, depth: 0, parentID: nil)
    model.entries = entries
  }

  private func editBookmark(_ entry: BookmarkManagerEntry) {
    guard canEditContent else { return }
    let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
    titleField.stringValue = entry.title
    let pageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
    pageField.stringValue = "\((entry.pageIndex ?? max(0, (viewer?.pageNumber ?? 1) - 1)) + 1)"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Title:"), titleField],
      [NSTextField(labelWithString: "Page:"), pageField],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
    let alert = NSAlert()
    alert.messageText = "Edit Bookmark"
    alert.informativeText = "The bookmark destination is updated to the chosen page."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let page = Int(pageField.stringValue),
      page >= 1, page <= editSession.pageIDs.count, !title.isEmpty
    else {
      NSSound.beep()
      return
    }
    do {
      try editSession.apply(
        PDFTransaction([
          EditBookmarkCommand(
            objectID: entry.id, title: title, pageID: editSession.pageIDs[page - 1])
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  private func moveBookmark(_ entry: BookmarkManagerEntry, direction: BookmarkMoveDirection) {
    applyBookmarkCommand(MoveBookmarkCommand(objectID: entry.id, direction: direction))
  }

  private func nestBookmark(_ entry: BookmarkManagerEntry) {
    applyBookmarkCommand(NestBookmarkCommand(objectID: entry.id))
  }

  private func outdentBookmark(_ entry: BookmarkManagerEntry) {
    applyBookmarkCommand(OutdentBookmarkCommand(objectID: entry.id))
  }

  private func removeBookmark(_ entry: BookmarkManagerEntry) {
    guard canEditContent else { return }
    let alert = NSAlert()
    alert.messageText = "Remove bookmark?"
    alert.informativeText =
      "\(entry.title) and any child bookmarks will be removed as one undo step."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    applyBookmarkCommand(RemoveBookmarkCommand(objectID: entry.id))
  }

  private func applyBookmarkCommand(_ command: any PDFEditCommand) {
    guard canEditContent else { return }
    do {
      try editSession.apply(PDFTransaction([command]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// PAG-09: add a top-level bookmark at the current page.
  func presentAddBookmark() {
    guard canEditContent, let viewer, viewer.pageNumber > 0,
      viewer.pageNumber <= editSession.pageIDs.count
    else { return }
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    field.stringValue = "Page \(viewer.pageNumber)"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Title:"), field]
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 380, height: 40)
    let alert = NSAlert()
    alert.messageText = "Add Bookmark"
    alert.informativeText = "Adds a top-level bookmark to the current page."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Add")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      NSSound.beep()
      return
    }
    do {
      try editSession.apply(
        PDFTransaction([
          AddBookmarkCommand(
            title: title, pageID: editSession.pageIDs[viewer.pageNumber - 1])
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer.pageNumber)
  }

  /// PAG-09: remove one existing bookmark and its descendants.
  func presentRemoveBookmark() {
    guard canEditContent, let graph = editSession.currentGraph else { return }
    var flat: [(title: String, depth: Int, objectID: PDFObjectID)] = []
    func walk(_ items: [PDFOutlineItem], depth: Int) {
      for item in items {
        if let id = item.objectID { flat.append((item.title, depth, id)) }
        walk(item.children, depth: depth + 1)
      }
    }
    walk(
      PDFOutlineInventory.items(in: graph, pageIDs: editSession.pageIDs), depth: 0)
    guard !flat.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Bookmarks"
      alert.informativeText = "This document has no bookmarks to remove."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    popup.addItems(withTitles: flat.map {
      String(repeating: "  ", count: $0.depth) + $0.title
    })
    let alert = NSAlert()
    alert.messageText = "Remove Bookmark"
    alert.informativeText =
      "Removes the selected bookmark and any child bookmarks as one undo step."
    alert.accessoryView = popup
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let item = flat[max(0, popup.indexOfSelectedItem)]
    do {
      try editSession.apply(
        PDFTransaction([RemoveBookmarkCommand(objectID: item.objectID)]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// PAG-09: edit the document information dictionary.
  func presentDocumentMetadata() {
    guard canEditContent, let graph = editSession.currentGraph else { return }
    let facts = PDFDocumentInventory.documentFacts(
      in: graph, pageCount: editSession.pageIDs.count)
    let labels = ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"]
    let values = [
      facts.metadata.title, facts.metadata.author, facts.metadata.subject,
      facts.metadata.keywords, facts.metadata.creator, facts.metadata.producer,
    ]
    let fields = zip(labels, values).map { _, value -> NSTextField in
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
      field.stringValue = value ?? ""
      return field
    }
    let grid = NSGridView(views: zip(labels, fields).map { label, field in
      [NSTextField(labelWithString: "\(label):"), field] as [NSView]
    })
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 400, height: 190)
    let alert = NSAlert()
    alert.messageText = "Document Metadata"
    alert.informativeText =
      "Updates the document information dictionary. XMP metadata, if present, is not rewritten."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    func value(_ index: Int) -> String? {
      let text = fields[index].stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
    let metadata = DocumentMetadata(
      title: value(0), author: value(1), subject: value(2), keywords: value(3),
      creator: value(4), producer: value(5))
    do {
      try editSession.apply(
        PDFTransaction([SetDocumentMetadataCommand(metadata: metadata)]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  /// PAG-06: remove one applied sPDF mark set without touching other content.
  func presentRemovePageMark() {
    guard canEditContent, let graph = editSession.currentGraph else { return }
    let groups = RepeatedMarkInventory.groups(
      in: graph, pageIDs: editSession.pageIDs)
    guard !groups.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Page Marks"
      alert.informativeText = "This document has no removable sPDF-authored page marks."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    popup.addItems(withTitles: groups.map {
      "\($0.label) — \($0.pageIDs.count) page"
        + ($0.pageIDs.count == 1 ? "" : "s")
    })
    let alert = NSAlert()
    alert.messageText = "Remove Page Mark"
    alert.informativeText =
      "The selected mark set is removed from its pages as one undo step. "
      + "Other content and other mark sets are left intact."
    alert.accessoryView = popup
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let group = groups[max(0, popup.indexOfSelectedItem)]
    do {
      try editSession.apply(
        PDFTransaction([
          RemoveRepeatedMarkCommand(groupID: group.groupID, pageIDs: group.pageIDs)
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
  }

  func organizePages() {
    guard canEditContent, editSession.currentGraph != nil else { return }
    let model = PageOrganizerModel()
    model.refresh(from: self)
    model.onApply = { [weak self] transaction in
      guard let self, self.canEditContent else { return }
      do {
        try self.editSession.apply(transaction)
        self.noteUserEdit()
        self.refreshViewer(preservingPage: self.viewer?.pageNumber ?? 1)
        model.refresh(from: self)
      } catch {
        self.presentError(error)
      }
    }
    model.onExtract = { [weak self] pageIDs in
      guard let self, let graph = self.editSession.currentGraph else { return }
      do {
        let extracted = try DocumentAssembly.extract(graph, pageIDs: pageIDs)
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "pdf") { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue =
          (self.fileURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-extract.pdf"
        panel.begin { response in
          guard response == .OK, let url = panel.url else { return }
          do {
            try PDFWriter.write(extracted.graph).write(to: url, options: .atomic)
            let alert = NSAlert()
            alert.messageText = "Pages Extracted"
            alert.informativeText = "\(pageIDs.count) page\(pageIDs.count == 1 ? "" : "s") written."
            alert.runModal()
          } catch {
            self.presentError(error)
          }
        }
      } catch {
        self.presentError(error)
      }
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Organize Pages"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: PageOrganizerPanel(model: model))
    pageOrganizerModel = model
    pageOrganizerWindow = window
    window.makeKeyAndOrderFront(nil)
  }

  /// P29-001/P29-010/P29-016: draw a graphical signature and place it as a
  /// stamp annotation on the current page (explicit save to the palette only).
  func placeGraphicalSignature() {
    guard canEditContent else { return }
    if let window = signatureWindow, window.isVisible {
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    let canvas = SignatureCanvasView(
      frame: NSRect(x: 0, y: 0, width: 460, height: 200))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Graphical Signature"
    window.isReleasedWhenClosed = false
    signatureWindow = window
    let panel = SignatureCanvasPanel(
      canvas: canvas,
      onPlace: { [weak self, weak window] asset, saveToPalette in
        guard let self, self.canEditContent else { return }
        do {
          if saveToPalette {
            let store = SignatureAssetStore(directory: SignatureAssetStore.defaultDirectory())
            try store.save(asset)
          }
          let pageID = self.editSession.pageIDs[
            min(max((self.viewer?.pageNumber ?? 1) - 1, 0), self.editSession.pageIDs.count - 1)]
          let box = self.pageBox(of: pageID, in: graph)
          let width = min(220, (box[2] - box[0]) * 0.4)
          let height = width * Double(asset.height) / Double(max(asset.width, 1))
          let rect = [
            box[0] + (box[2] - box[0] - width) / 2, box[1] + (box[3] - box[1] - height) / 2,
            box[0] + (box[2] - box[0] - width) / 2 + width,
            box[1] + (box[3] - box[1] - height) / 2 + height,
          ]
          try self.editSession.apply(
            PDFTransaction([
              PlaceSignatureStampCommand(
                pageID: pageID, rect: rect, asset: asset,
                options: SignatureStampOptions(includeDate: Self.signatureDateString()))
            ]))
          self.noteUserEdit()
          self.refreshViewer(preservingPage: self.viewer?.pageNumber ?? 1)
          window?.close()
        } catch {
          self.presentError(error)
        }
      },
      onCancel: { [weak window] in window?.close() })
    window.contentView = NSHostingView(rootView: panel)
    window.makeKeyAndOrderFront(nil)
  }

  private static func signatureDateString() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }

  /// P36-009: review detected tables in a native grid before exporting.
  func reviewTables() {
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    let tables = (try? TableExtraction.tables(pageIDs: editSession.pageIDs, in: graph)) ?? []
    guard !tables.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Tables Detected"
      alert.informativeText =
        "No supported tables were found on the current pages. Ruled tables, text grids with two or more columns, and tagged tables are supported."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let model = TableReviewModel(reviews: tables.map { TableReview(table: $0) })
    tableReviewModel = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Table Review"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 360)
    window.contentView = NSHostingView(
      rootView: TableReviewPanel(
        model: model,
        onExportCSV: { [weak self] in self?.exportTables(format: .csv) },
        onExportXLSX: { [weak self] in self?.exportTables(format: .xlsx) },
        onClose: { [weak window] in window?.close() }))
    tableReviewWindows.append(window)
    window.makeKeyAndOrderFront(nil)
  }

  /// P36-016/P36-025: CSV or XLSX export of the reviewed (or freshly
  /// extracted) tables.
  enum TableExportFormat {
    case csv
    case xlsx

    var fileExtension: String {
      switch self {
      case .csv: return "csv"
      case .xlsx: return "xlsx"
      }
    }
  }

  func exportTables(format: TableExportFormat) {
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else { return }
    let tables =
      tableReviewModel?.exportable
      ?? ((try? TableExtraction.tables(pageIDs: editSession.pageIDs, in: graph)) ?? [])
    guard !tables.isEmpty else {
      let alert = NSAlert()
      alert.messageText = "No Tables to Export"
      alert.informativeText =
        "No supported tables were detected (or every detection was rejected in review)."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let panel = NSSavePanel()
    if let type = UTType(filenameExtension: format.fileExtension) {
      panel.allowedContentTypes = [type]
    }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    panel.nameFieldStringValue =
      (base.isEmpty ? "Document" : base) + "-tables.\(format.fileExtension)"
    panel.prompt = "Export"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        let count = try self.exportTables(to: url, format: format, tables: tables)
        let alert = NSAlert()
        alert.messageText = "Tables Exported"
        alert.informativeText = "\(count) table\(count == 1 ? "" : "s") written."
        alert.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }

  /// Testable path behind the panels.
  @discardableResult
  func exportTables(
    to url: URL, format: TableExportFormat, tables: [ExtractedTable]? = nil
  ) throws -> Int {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "There is no document to export")
    }
    let extracted = try tables ?? TableExtraction.tables(pageIDs: editSession.pageIDs, in: graph)
    let data: Data
    switch format {
    case .csv:
      data = TableCSVExport.data(for: extracted)
    case .xlsx:
      data = try XLSXExport.package(tables: extracted)
    }
    try data.write(to: url, options: .atomic)
    return extracted.count
  }

  /// P24-022/FRM-03: import values from JSON, XFDF or FDF and report skipped
  /// or ambiguous fields.
  func importFormValues() {
    guard canEditContent else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      .json,
      UTType(filenameExtension: "xfdf") ?? .data,
      UTType(filenameExtension: "fdf") ?? .data,
    ]
    panel.allowsMultipleSelection = false
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self,
        self.canEditContent,
        let graph = self.editSession.currentGraph
      else { return }
      do {
        let data = try Data(contentsOf: url)
        let (commands, skipped, ambiguous): (
          [any PDFEditCommand], [String], [String]
        )
        switch url.pathExtension.lowercased() {
        case "xfdf":
          let values = try FormDataExchange.parse(data, format: .xfdf)
          (commands, skipped, ambiguous) = try FormDataExchange.commands(
            forRawValues: values, in: graph, pageIDs: self.editSession.pageIDs)
        case "fdf":
          let values = try FormDataExchange.parse(data, format: .fdf)
          (commands, skipped, ambiguous) = try FormDataExchange.commands(
            forRawValues: values, in: graph, pageIDs: self.editSession.pageIDs)
        default:
          let values = try FormValues.parse(data)
          (commands, skipped, ambiguous) = try FormValues.commands(
            for: values, in: graph, pageIDs: self.editSession.pageIDs)
        }
        guard !commands.isEmpty else {
          self.presentError(PDFError(.malformed, "No importable values matched this document"))
          return
        }
        try self.editSession.apply(PDFTransaction(commands))
        self.noteUserEdit()
        self.refreshViewer(preservingPage: self.viewer?.pageNumber ?? 1)
        if !skipped.isEmpty || !ambiguous.isEmpty {
          let alert = NSAlert()
          alert.messageText = "Some values need attention"
          var lines: [String] = []
          if !skipped.isEmpty {
            lines.append(
              "Missing, read-only, or unsupported: \(skipped.joined(separator: ", "))")
          }
          if !ambiguous.isEmpty {
            lines.append(
              "Duplicate field names (first match used): \(ambiguous.joined(separator: ", "))")
          }
          alert.informativeText = lines.joined(separator: "\n\n")
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
      } catch {
        self.presentError(error)
      }
    }
  }

  var canFlattenForm: Bool {
    canEditContent && editSession.formFields().contains { !$0.widgets.isEmpty }
  }

  /// P24-024: explicit form flattening with a confirmation.
  func flattenForm() {
    guard canEditContent else { return }
    let alert = NSAlert()
    alert.messageText = "Flatten form fields?"
    alert.informativeText =
      "Widget appearances are burned into page content and the form fields become "
      + "non-interactive. This can be undone until later edits replace that history."
    alert.addButton(withTitle: "Flatten Form")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    applyFlattenForm()
  }

  @discardableResult
  func applyFlattenForm() -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(PDFTransaction([FlattenFormCommand()]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  /// P24-013 slice: scroll to the first widget of a field.
  func navigate(to field: FormField) {
    guard let widget = field.widgets.first(where: { $0.pageIndex != nil && $0.rect != nil })
    else { return }
    viewer?.focus(onPageIndex: widget.pageIndex ?? 0, rect: widget.rect ?? [])
  }

  /// P22-017: navigate the viewer to a comment's page and geometry.
  func navigate(to comment: Comment) {
    viewer?.focus(onPageIndex: comment.pageIndex, rect: comment.bounds ?? [])
  }

  /// P22-020: delete a comment from its page through the canonical session.
  func deleteAnnotation(_ comment: Comment) {
    guard canEditContent else { return }
    do {
      try editSession.apply(
        PDFTransaction([
          DeleteAnnotationCommand(
            pageID: comment.pageID, annotationIndex: comment.annotation.index)
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  /// P12-012 text-edit slice: resolve the run under the current selection.
  func selectedTextTarget() -> (pageIndex: Int, target: TextRunTarget)? {
    guard canEditContent, let viewer, let document = viewer.view.document,
      let selection = viewer.view.currentSelection,
      let page = selection.pages.first, let graph = editSession.currentGraph
    else { return nil }
    let index = document.index(for: page)
    guard index >= 0, index < editSession.pageIDs.count else { return nil }
    let bounds = selection.bounds(for: page)
    guard
      let target = try? TextEditTargeting.run(
        atSelectionBounds: [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY],
        in: graph, pageID: editSession.pageIDs[index])
    else { return nil }
    return (index, target)
  }

  /// Use the same on-page caret for the menu and pointer editing paths.
  func editSelectedText() {
    guard canEditContent, let viewer, let selection = viewer.view.currentSelection,
      let page = selection.pages.first, let document = viewer.view.document
    else { return }
    let bounds = selection.bounds(for: page)
    guard
      let target = textRunTarget(
        pageIndex: document.index(for: page),
        pagePoint: [bounds.midX, bounds.midY]), viewer.activateTool(.textEdit)
    else { return }
    viewer.textBlockEditStarter?(target)
  }

  // MARK: - Page import (P17-021)

  /// The testable path behind File → Import Pages…: import the selected pages
  /// of another document as one transaction.
  @discardableResult
  func importPages(documentBytes: Data, pageIndices: [Int], atIndex: Int) -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(
        PDFTransaction([
          ImportPagesCommand(
            documentBytes: documentBytes, pageIndices: pageIndices, atIndex: atIndex)
        ]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  /// File → Import Pages…: choose a document, a page range, and append the
  /// pages to this document.
  func importPagesFromFile() {
    guard canEditContent else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.message = "Choose the document whose pages you want to import."
    guard panel.runModal() == .OK, let url = panel.url,
      let data = try? SPDFDocumentResourcePolicy.readPDFData(at: url)
    else { return }
    guard
      let parsed = try? PDFParser.parse(
        data, limits: SPDFDocumentResourcePolicy.parsingLimits),
      !parsed.pageIDs.isEmpty
    else {
      presentError(PDFError(.malformed, "The chosen document has no pages to import"))
      return
    }
    let field = NSTextField(string: "1")
    field.placeholderString = "for example 1-3,5"
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Pages:"), field],
      [
        NSTextField(labelWithString: "Document:"),
        NSTextField(labelWithString: url.lastPathComponent),
      ],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 420, height: 56)
    guard
      runFormDialog(
        title: "Import Pages",
        message:
          "\(parsed.pageIDs.count) page(s) available. The pages are appended and resources are remapped.",
        accessory: grid)
    else { return }
    let indices = PageRange.parse(field.stringValue, pageCount: parsed.pageIDs.count)
    guard !indices.isEmpty else {
      presentError(PDFError(.malformed, "The page range is empty; use forms such as 1-3,5"))
      return
    }
    _ = importPages(
      documentBytes: data, pageIndices: indices, atIndex: editSession.pageIDs.count)
  }

  @discardableResult
  func addPageText(pageIndex: Int, rect: [Double], text: String, style: PageTextStyle = .init())
    -> Bool
  {
    guard canEditContent, pageIndex >= 0, pageIndex < editSession.pageIDs.count else {
      return false
    }
    do {
      try editSession.apply(
        PDFTransaction([
          AddTextObjectCommand(
            pageID: editSession.pageIDs[pageIndex], rect: rect, text: text,
            style: AddedTextStyle(size: style.fontSize, color: style.color))
        ]))
      noteUserEdit()
      refreshViewer(preservingPage: pageIndex + 1)
      return true
    } catch {
      presentError(error)
      return false
    }
  }

  @discardableResult
  func commitTextBlock(
    _ target: PageTextTarget, text: String, style: PageTextStyle,
    dx: Double, dy: Double, lines: [PageTextLine]? = nil, box: PageTextBox? = nil
  ) -> Bool {
    guard canEditContent, editSession.pageIDs.indices.contains(target.pageIndex)
    else { return false }
    let page = editSession.pageIDs[target.pageIndex]
    if let paragraph = target.paragraph {
      guard let lines else { return false }
      // The inspector follows the selected characters or caret. That style
      // may differ from the first span without any actual edit to the box.
      // Canonical span/width changes are tracked by the native formatter.
      if text == target.text, dx == 0, dy == 0,
        viewer?.hasPendingPageTextChanges != true { return true }
      do {
        try editSession.apply(PDFTransaction([
          RewritePageTextCommand(
            pageID: page, originalText: paragraph.originalText, lines: lines,
            fontSize: style.fontSize, color: style.color,
            standardFontAdvances: paragraph.standardFontAdvances,
            sourceRunOutputCounts: paragraph.sourceRunOutputCounts, box: box)
        ]))
        noteUserEdit()
        refreshViewer(preservingPage: target.pageIndex + 1)
        return true
      } catch {
#if DEBUG
        if CommandLine.arguments.contains("--test-corpus-paragraphs") {
          viewer?.pageTextFormattingIssue = String(describing: error)
        } else {
          presentError(error)
        }
#else
        presentError(error)
#endif
        return false
      }
    }
    guard !text.contains("\n"), !text.contains("\r") else { return false }
    var commands: [any PDFEditCommand] = []
    if text != target.text, let first = target.runIndices.first, let last = target.runIndices.last {
      commands.append(
        ReplaceTextSpanCommand(pageID: page, runRange: first..<(last + 1), replacement: text))
    }
    if let original = target.style,
      original.fontSize != style.fontSize || original.fillColor != style.color
    {
      commands.append(
        ChangeTextStyleCommand(
          pageID: page, runIndex: target.runIndex,
          style: TextStyleChange(
            fontSize: original.fontSize == style.fontSize ? nil : style.fontSize,
            fillColor: original.fillColor == style.color ? nil : style.color)))
    }
    if dx != 0 || dy != 0 {
      commands.append(MoveTextCommand(pageID: page, runIndex: target.runIndex, dx: dx, dy: dy))
    }
    guard !commands.isEmpty else { return true }
    do {
      try editSession.apply(PDFTransaction(commands))
      noteUserEdit()
      refreshViewer(preservingPage: target.pageIndex + 1)
      return true
    } catch {
      presentError(error)
      return false
    }
  }

  @discardableResult
  func replaceText(pageIndex: Int, runIndex: Int, with replacement: String) -> Bool {
    guard canEditContent, !replacement.isEmpty else { return false }
    // P43-003: warn about missing fonts before the edit is committed.
    if let graph = editSession.currentGraph,
      pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let font = try? PDFTextFontLookup.font(
        forRunAt: runIndex, pageID: editSession.pageIDs[pageIndex], in: graph),
      !warnedFonts.contains(font.familyName),
      let warning = FontProvisioning.editingWarning(for: font)
    {
      let alert = NSAlert()
      alert.messageText = "Font Not Installed"
      alert.informativeText = warning
      alert.addButton(withTitle: "Continue Edit")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
      warnedFonts.insert(font.familyName)
    }
    do {
      try editSession.replaceText(pageAt: pageIndex, runIndex: runIndex, with: replacement)
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    // P17-016/P17-017: the edit came through this run, so re-select it on
    // the refreshed document — the selection keeps its identity with the new
    // text instead of silently vanishing. If the run is gone, the cleared
    // selection stands (the resolution reason is available for diagnostics).
    restoreTextSelection(pageIndex: pageIndex, runIndex: runIndex)
    return true
  }

  /// P17-016/P17-017: resolve a selection identity against the edited graph
  /// and re-select the run through PDFKit when it survived.
  private func restoreTextSelection(pageIndex: Int, runIndex: Int) {
    guard let viewer, let graph = editSession.currentGraph,
      pageIndex >= 0, pageIndex < editSession.pageIDs.count
    else { return }
    let identity = SelectionIdentity(
      pageID: editSession.pageIDs[pageIndex], runIndex: runIndex, text: "")
    let resolution = identity.resolve(in: graph)
    guard case .preserved(let text, let rect) = resolution, let rect,
      let page = viewer.view.document?.page(at: pageIndex)
    else { return }
    // Conservative fonts without /Widths produce zero-width run bounds;
    // widen the selection rect with the overlay's estimate so PDFKit has
    // ink to select.
    let height = max(1, rect[3] - rect[1])
    var width = rect[2] - rect[0]
    if width < 8 {
      width = max(60, Double(text.count) * height * 0.55)
    }
    let pageRect = CGRect(x: rect[0], y: rect[1], width: width, height: height)
    if let selection = page.selection(for: pageRect) {
      viewer.view.setCurrentSelection(selection, animate: false)
    }
  }

  // MARK: - Styled copy (P16-014)

  /// P16-014: put the current selection on the pasteboard as RTF built by
  /// the owned core (family, size, and color). Text the profile cannot
  /// decode leaves the pasteboard untouched so the ordinary Copy stays the
  /// fallback.
  @discardableResult
  func copySelectionAsRichText() -> Bool {
    guard let graph = editSession.currentGraph, let viewer,
      let selection = viewer.view.currentSelection,
      let page = selection.pages.first,
      let document = viewer.view.document
    else { return false }
    let index = document.index(for: page)
    guard index >= 0, index < editSession.pageIDs.count else { return false }
    let bounds = selection.bounds(for: page)
    guard
      let target = try? TextEditTargeting.run(
        atSelectionBounds: [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY],
        in: graph, pageID: editSession.pageIDs[index]),
      let rtf = try? StyledTextCopy.richText(
        pageID: editSession.pageIDs[index], runIndex: target.runIndex, in: graph)
    else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(Data(rtf.utf8), forType: .rtf)
    pasteboard.setString(rtf, forType: .string)
    return true
  }

  /// P22-014: add a threaded reply to a comment through a native prompt.
  func addReply(to comment: Comment) {
    guard canEditContent, comment.annotation.objectID != nil else { return }
    let alert = NSAlert()
    alert.messageText = "Reply"
    alert.informativeText = "Add a reply to this comment."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "Reply"
    alert.accessoryView = field
    alert.addButton(withTitle: "Reply")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    do {
      try editSession.apply(
        PDFTransaction([
          AddReplyCommand(
            pageID: comment.pageID, annotationIndex: comment.annotation.index, text: text,
            modified: Self.pdfDateString(Date()))
        ]))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  /// P22-015: set or clear a comment's review status.
  func setState(_ state: PDFName?, on comment: Comment) {
    setState(state, on: [comment])
  }

  /// REV-03: apply one review status to every selected comment atomically.
  func setState(_ state: PDFName?, on comments: [Comment]) {
    guard canEditContent, !comments.isEmpty else { return }
    var commands: [any PDFEditCommand] = []
    var seen = Set<String>()
    for comment in comments {
      let key = "\(comment.pageID.number):\(comment.pageID.generation):\(comment.annotation.index)"
      guard seen.insert(key).inserted else { continue }
      commands.append(
        SetAnnotationStateCommand(
          pageID: comment.pageID, annotationIndex: comment.annotation.index, state: state))
    }
    guard !commands.isEmpty else { return }
    do {
      try WorkspacePerformance.profile("comment-edit") {
        try editSession.apply(PDFTransaction(commands))
      }
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  var canExportReviewSummary: Bool {
    !editSession.comments().isEmpty
  }

  /// P22-022: explicit derivative flattening with a confirmation.
  var canFlattenAnnotations: Bool {
    canEditContent && !editSession.flattenablePageIDs().isEmpty
  }

  func flattenAnnotations() {
    guard canEditContent, let viewer else { return }
    let flattenable = editSession.flattenablePageIDs()
    guard !flattenable.isEmpty else { return }
    let currentIndex = max(0, viewer.pageNumber - 1)
    let alert = NSAlert()
    alert.messageText = "Flatten annotations?"
    alert.informativeText =
      "Annotation appearances are burned into page content and the annotations are removed. "
      + "This can be undone until the document is saved and later edits replace that history."
    alert.addButton(withTitle: "Flatten This Page")
    alert.addButton(withTitle: "Flatten All Pages")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      guard currentIndex < editSession.pageIDs.count else { return }
      applyFlatten(pageIDs: [editSession.pageIDs[currentIndex]])
    case .alertSecondButtonReturn:
      applyFlatten(pageIDs: flattenable)
    default:
      return
    }
  }

  private func applyFlatten(pageIDs: [PDFObjectID]) {
    guard canEditContent else { return }
    let flattenable = Set(editSession.flattenablePageIDs())
    let targets = pageIDs.filter { flattenable.contains($0) }
    guard !targets.isEmpty else { return }
    do {
      try editSession.apply(
        PDFTransaction(targets.map { FlattenAnnotationsCommand(pageID: $0) }))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 0)
  }

  // MARK: - Image edits (P12-015, P20-008–P20-012)

  private struct ImageMenuCommand {
    enum Kind {
      case rotate(Int)
      case scale(Double)
      case flip(horizontal: Bool)
      case crop
      case geometry
      case replace(shared: Bool)
    }

    let pageIndex: Int
    let placementIndex: Int
    let kind: Kind
  }

  private struct GraphicMenuCommand {
    let target: AddedGraphicTarget
  }

  /// P12-015: operation-specific menu, only offered when a directly editable
  /// image placement is under the clicked point. App-created graphics get
  /// their own section when no image placement is hit.
  private func imageContextMenu(pageIndex: Int, pagePoint: [Double]) -> NSMenu? {
    guard canEditContent, pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let graph = editSession.currentGraph
    else { return nil }
    if let placements = try? ImageInventory.placements(
      in: graph, pageID: editSession.pageIDs[pageIndex]),
      let placementIndex = try? ImageInventory.placementIndex(
        at: pagePoint, in: graph, pageID: editSession.pageIDs[pageIndex]),
      placementIndex < placements.count, placements[placementIndex].isDirectlyEditable
    {
      return imagePlacementMenu(pageIndex: pageIndex, placementIndex: placementIndex)
    }
    guard let target = graphicTarget(pageIndex: pageIndex, pagePoint: pagePoint) else {
      return nil
    }
    let menu = NSMenu()
    let rotate = NSMenuItem(
      title: "Rotate Graphic 90°", action: #selector(performGraphicMenuCommand(_:)),
      keyEquivalent: "")
    rotate.target = self
    rotate.representedObject = GraphicMenuCommand(target: target)
    menu.addItem(rotate)
    return menu
  }

  @objc private func performGraphicMenuCommand(_ sender: NSMenuItem) {
    // NSMenuItem.representedObject is Any?; the struct round-trips as-is.
    guard let command = sender.representedObject as? GraphicMenuCommand else { return }
    viewer?.selectGraphics([command.target])
    _ = rotateGraphic(command.target)
  }

  private func imagePlacementMenu(pageIndex: Int, placementIndex: Int) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ kind: ImageMenuCommand.Kind) {
      let item = NSMenuItem(
        title: title, action: #selector(performImageMenuCommand(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = ImageMenuCommand(
        pageIndex: pageIndex, placementIndex: placementIndex, kind: kind)
      menu.addItem(item)
    }
    add("Rotate Image 90°", .rotate(90))
    add("Rotate Image −90°", .rotate(-90))
    add("Flip Image Horizontally", .flip(horizontal: true))
    add("Flip Image Vertically", .flip(horizontal: false))
    add("Crop Image…", .crop)
    add("Size and Position…", .geometry)
    menu.addItem(.separator())
    add("Scale Image Up", .scale(1.1))
    add("Scale Image Down", .scale(1 / 1.1))
    menu.addItem(.separator())
    add("Replace Image…", .replace(shared: false))
    add("Replace All Shared Instances…", .replace(shared: true))
    return menu
  }

  @objc private func performImageMenuCommand(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? ImageMenuCommand else { return }
    switch command.kind {
    case .rotate(let degrees):
      _ = rotateImage(
        pageIndex: command.pageIndex, placementIndex: command.placementIndex, degrees: degrees)
    case .scale(let factor):
      _ = scaleImage(
        pageIndex: command.pageIndex, placementIndex: command.placementIndex, factor: factor)
    case .flip(let horizontal):
      _ = flipImage(
        pageIndex: command.pageIndex, placementIndex: command.placementIndex,
        horizontal: horizontal)
    case .crop:
      promptCropImage(
        pageIndex: command.pageIndex, placementIndex: command.placementIndex)
    case .geometry:
      promptImageGeometry(
        pageIndex: command.pageIndex, placementIndex: command.placementIndex)
    case .replace(let shared):
      promptReplaceImage(
        pageIndex: command.pageIndex, placementIndex: command.placementIndex, shared: shared)
    }
  }

  @discardableResult
  func rotateImage(pageIndex: Int, placementIndex: Int, degrees: Int) -> Bool {
    guard let pageID = pageID(at: pageIndex) else { return false }
    return applyImageTransaction([
      RotateImageCommand(pageID: pageID, placementIndex: placementIndex, degrees: degrees)
    ])
  }

  @discardableResult
  func flipImage(pageIndex: Int, placementIndex: Int, horizontal: Bool) -> Bool {
    guard let pageID = pageID(at: pageIndex) else { return false }
    return applyImageTransaction([
      FlipImageCommand(
        pageID: pageID, placementIndex: placementIndex, horizontal: horizontal)
    ])
  }

  @discardableResult
  func cropImage(pageIndex: Int, placementIndex: Int, unitRect: [Double]) -> Bool {
    guard let pageID = pageID(at: pageIndex) else { return false }
    return applyImageTransaction([
      ClipImageDrawCommand(
        pageID: pageID, placementIndex: placementIndex, unitRect: unitRect)
    ])
  }

  /// IMG-01: move and resize one unrotated placement from page-space numbers.
  /// Scaling keeps the top-left origin, so the move delta is applied after it.
  @discardableResult
  func setImageGeometry(
    pageIndex: Int, placementIndex: Int, x: Double, y: Double, width: Double,
    height: Double
  ) -> Bool {
    guard let pageID = pageID(at: pageIndex), let graph = editSession.currentGraph,
      width.isFinite, height.isFinite, x.isFinite, y.isFinite,
      width > 0, height > 0,
      let placements = try? ImageInventory.placements(in: graph, pageID: pageID),
      placementIndex >= 0, placementIndex < placements.count
    else { return false }
    let bounds = placements[placementIndex].bounds
    guard bounds.count == 4 else { return false }
    let currentWidth = bounds[2] - bounds[0]
    let currentHeight = bounds[3] - bounds[1]
    guard currentWidth > 0, currentHeight > 0 else { return false }
    var commands: [any PDFEditCommand] = []
    let scaleX = width / currentWidth
    let scaleY = height / currentHeight
    if abs(scaleX - 1) > 1e-9 || abs(scaleY - 1) > 1e-9 {
      commands.append(
        ScaleImageCommand(
          pageID: pageID, placementIndex: placementIndex, scaleX: scaleX, scaleY: scaleY))
    }
    let dx = x - bounds[0]
    let dy = y - bounds[1]
    if abs(dx) > 1e-9 || abs(dy) > 1e-9 {
      commands.append(
        MoveImageCommand(pageID: pageID, placementIndex: placementIndex, dx: dx, dy: dy))
    }
    guard !commands.isEmpty else { return true }
    return applyImageTransaction(commands)
  }

  @discardableResult
  func scaleImage(pageIndex: Int, placementIndex: Int, factor: Double) -> Bool {
    guard let pageID = pageID(at: pageIndex) else { return false }
    return applyImageTransaction([
      ScaleImageCommand(pageID: pageID, placementIndex: placementIndex, uniformScale: factor)
    ])
  }

  /// P20-009/P20-010/P20-011: import raster data through ImageIO and replace
  /// one instance or every shared instance. Replacing the scan invalidates a
  /// generated searchable text layer first (P26-023).
  @discardableResult
  func replaceImage(pageIndex: Int, placementIndex: Int, with data: Data, shared: Bool) -> Bool {
    guard let pageID = pageID(at: pageIndex) else { return false }
    guard let raster = ImageImport.decode(data) else {
      presentError(PDFError(.unsupported, "This image could not be imported"))
      return false
    }
    let command: any PDFEditCommand =
      shared
      ? ReplaceSharedImageCommand(
        pageID: pageID, placementIndex: placementIndex, width: raster.width,
        height: raster.height, rgb8: raster.rgb8, alpha8: raster.alpha8)
      : ReplaceImageDataCommand(
        pageID: pageID, placementIndex: placementIndex, width: raster.width,
        height: raster.height, rgb8: raster.rgb8, alpha8: raster.alpha8)
    var commands: [any PDFEditCommand] = []
    if let graph = editSession.currentGraph,
      OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID)
    {
      commands.append(RemoveOCRLayerCommand(pageID: pageID))
    }
    commands.append(command)
    return applyImageTransaction(commands)
  }

  // MARK: - Added-graphics selection (P12-017)

  private func promptInsertImage() {
    guard canEditContent, let window = windowControllers.first?.window,
      let pageIndex = viewer?.pageNumber.advanced(by: -1) else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Insert Image"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        let data = try Data(contentsOf: url)
        guard self.insertImage(data, pageIndex: pageIndex) else { return }
      } catch { self.presentError(error) }
    }
  }

  @discardableResult
  func insertImage(_ data: Data, pageIndex: Int) -> Bool {
    guard canEditContent, let pageID = pageID(at: pageIndex), let viewer,
      let page = viewer.view.document?.page(at: pageIndex) else { return false }
    guard let raster = ImageImport.decode(data) else {
      presentError(PDFError(.unsupported, "This image could not be imported")); return false
    }
    let crop = page.bounds(for: viewer.view.displayBox)
    let scale = min(crop.width * 0.5 / Double(raster.width), crop.height * 0.5 / Double(raster.height))
    let width = Double(raster.width) * scale, height = Double(raster.height) * scale
    let rect = [crop.midX - width / 2, crop.midY - height / 2, crop.midX + width / 2, crop.midY + height / 2]
    let existing = Set(graphicsList(pageIndex: pageIndex).map(\.streamID))
    guard applyImageTransaction([PlaceImageCommand(pageID: pageID, rect: rect,
      width: raster.width, height: raster.height, rgb8: raster.rgb8,
      alpha8: raster.alpha8)]) else { return false }
    _ = viewer.activateTool(.imageEdit)
    viewer.selectGraphics(graphicsList(pageIndex: pageIndex).filter { !existing.contains($0.streamID) })
    viewer.graphicSelectionFocuser?()
    return true
  }

  /// Resolve the topmost selectable app-created graphic under a page point.
  private func graphicTarget(pageIndex: Int, pagePoint: [Double]) -> AddedGraphicTarget? {
    guard pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let graph = editSession.currentGraph,
      pagePoint.count == 2
    else { return nil }
    let pageID = editSession.pageIDs[pageIndex]
    guard let selectables = try? AddedGraphics.selectable(pageID: pageID, in: graph) else {
      return nil
    }
    for graphic in selectables.reversed() {
      let bounds = graphic.bounds
      guard bounds.count == 4,
        pagePoint[0] >= bounds[0], pagePoint[0] <= bounds[2],
        pagePoint[1] >= bounds[1], pagePoint[1] <= bounds[3]
      else { continue }
      return AddedGraphicTarget(
        pageIndex: pageIndex, streamID: graphic.streamID,
        kind: graphic.kind == .imageStamp ? "Image stamp" : "Rectangle", rect: bounds)
    }
    guard let placements = try? ImageInventory.placements(in: graph, pageID: pageID) else {
      return nil
    }
    for (index, placement) in placements.enumerated().reversed() {
      guard placement.isDirectlyEditable, placement.hasSupportedClipping,
        placement.matrix.count == 6, placement.matrix[0] > 0, placement.matrix[3] > 0,
        abs(placement.matrix[1]) < 1e-9, abs(placement.matrix[2]) < 1e-9,
        placement.canvasVisibleBounds != nil, placement.contains(point: pagePoint)
      else { continue }
      return AddedGraphicTarget(
        pageIndex: pageIndex, streamID: placement.imageID, kind: "Document image",
        rect: placement.bounds, imagePlacementIndex: index,
        hitRect: placement.clippingBounds == nil ? nil : placement.canvasVisibleBounds)
    }
    return nil
  }

  private func graphicsList(pageIndex: Int) -> [AddedGraphicTarget] {
    guard pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let graph = editSession.currentGraph
    else { return [] }
    let pageID = editSession.pageIDs[pageIndex]
    guard let selectables = try? AddedGraphics.selectable(pageID: pageID, in: graph) else {
      return []
    }
    let added = selectables.map {
      AddedGraphicTarget(
        pageIndex: pageIndex, streamID: $0.streamID,
        kind: $0.kind == .imageStamp ? "Image stamp" : "Rectangle", rect: $0.bounds)
    }
    // A directly drawn app-created image is already represented by its
    // marked content stream. Do not expose the same visual twice.
    let native = nativeImageTargets(pageIndex: pageIndex).filter { image in
      !added.contains { existing in
        zip(existing.rect, image.rect).allSatisfy { abs($0 - $1) < 0.01 }
      }
    }
    return added + native
  }

  /// Existing images can use the same canvas handles as app-created stamps
  /// only when their `q … cm … Do … Q` placement is directly rewriteable.
  /// Rotated/skewed matrices remain available through the explicit context
  /// menu; the canvas currently maps an axis-aligned resize rectangle.
  private func nativeImageTargets(pageIndex: Int) -> [AddedGraphicTarget] {
    guard pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let graph = editSession.currentGraph
    else { return [] }
    let pageID = editSession.pageIDs[pageIndex]
    guard let placements = try? ImageInventory.placements(in: graph, pageID: pageID) else {
      return []
    }
    return placements.enumerated().compactMap { index, placement in
      guard placement.isDirectlyEditable, placement.matrix.count == 6,
        placement.hasSupportedClipping, let hitBounds = placement.canvasVisibleBounds,
        placement.matrix[0] > 0, placement.matrix[3] > 0,
        abs(placement.matrix[1]) < 1e-9, abs(placement.matrix[2]) < 1e-9
      else { return nil }
      return AddedGraphicTarget(
        pageIndex: pageIndex, streamID: placement.imageID, kind: "Document image",
        rect: placement.bounds, imagePlacementIndex: index,
        hitRect: placement.clippingBounds == nil ? nil : hitBounds)
    }
  }

  private func graphicRefusal(pageIndex: Int, pagePoint: [Double]) -> String? {
    guard pageIndex >= 0, pageIndex < editSession.pageIDs.count,
      let graph = editSession.currentGraph, pagePoint.count == 2
    else { return nil }
    let pageID = editSession.pageIDs[pageIndex]
    guard let placements = try? ImageInventory.placements(in: graph, pageID: pageID) else {
      return nil
    }
    let placement = placements.reversed().first { candidate in
      guard candidate.containsSourcePoint(pagePoint) else { return false }
      return !candidate.hasSupportedClipping || candidate.contains(point: pagePoint)
    }
    guard let placement else { return nil }
    if !placement.hasSupportedClipping {
      return "This image uses a clipping path the canvas cannot hit-test exactly. Canvas editing is disabled to avoid selecting hidden parts; use the image context menu for supported actions."
    }
    if placement.depth > 0 {
      return "This image is drawn inside a reusable form. Canvas movement is disabled because its shared containing transform cannot be rewritten safely."
    }
    if !placement.isDirectlyEditable {
      return "This image is not drawn in the supported q…cm…Do…Q pattern. Canvas movement is disabled; use the image context menu for supported rotate, scale or replacement actions."
    }
    return "This image has a rotated or skewed placement. Use the image context menu to rotate, scale or replace it."
  }

  /// Move a multi-selection drag as one transaction with one undo step.
  @discardableResult
  func moveGraphics(
    _ moves: [(target: AddedGraphicTarget, dx: Double, dy: Double)]
  ) -> Bool {
    let commands: [any PDFEditCommand] = moves.compactMap { move in
      guard move.dx.isFinite, move.dy.isFinite,
        hypot(move.dx, move.dy) > 0.001
      else { return nil }
      if let placementIndex = move.target.imagePlacementIndex,
        let pageID = pageID(at: move.target.pageIndex) {
        return MoveImageCommand(
          pageID: pageID, placementIndex: placementIndex, dx: move.dx, dy: move.dy)
      }
      return MoveAddedGraphicCommand(
        streamID: move.target.streamID, dx: move.dx, dy: move.dy)
    }
    guard !commands.isEmpty else { return false }
    return applyImageTransaction(commands)
  }

  /// Resize a multi-selection drag as one transaction: the origin shift
  /// first, then the scale about the new origin, matching the overlay's
  /// mapping exactly.
  @discardableResult
  func resizeGraphics(
    _ resizes: [(
      target: AddedGraphicTarget, dx: Double, dy: Double, scaleX: Double, scaleY: Double
    )]
  ) -> Bool {
    let commands = graphicTransformCommands(resizes)
    guard !commands.isEmpty else { return false }
    return applyImageTransaction(commands)
  }

  private func graphicTransformCommands(
    _ resizes: [(
      target: AddedGraphicTarget, dx: Double, dy: Double, scaleX: Double, scaleY: Double
    )]
  ) -> [any PDFEditCommand] {
    var commands: [any PDFEditCommand] = []
    for resize in resizes {
      guard resize.scaleX.isFinite, resize.scaleY.isFinite,
        resize.scaleX > 0, resize.scaleY > 0
      else { continue }
      if let placementIndex = resize.target.imagePlacementIndex,
        let pageID = pageID(at: resize.target.pageIndex) {
        if hypot(resize.dx, resize.dy) > 0.001 {
          commands.append(
            MoveImageCommand(
              pageID: pageID, placementIndex: placementIndex,
              dx: resize.dx, dy: resize.dy))
        }
        if abs(resize.scaleX - 1) > 0.0001 || abs(resize.scaleY - 1) > 0.0001 {
          commands.append(
            ScaleImageCommand(
              pageID: pageID, placementIndex: placementIndex,
              scaleX: resize.scaleX, scaleY: resize.scaleY))
        }
        continue
      }
      if hypot(resize.dx, resize.dy) > 0.001 {
        commands.append(
          MoveAddedGraphicCommand(
            streamID: resize.target.streamID, dx: resize.dx, dy: resize.dy))
      }
      if abs(resize.scaleX - 1) > 0.0001 || abs(resize.scaleY - 1) > 0.0001 {
        commands.append(
          ScaleAddedGraphicCommand(
            streamID: resize.target.streamID, scaleX: resize.scaleX, scaleY: resize.scaleY))
      }
    }
    return commands
  }

  private func previewGraphics(
    _ resizes: [(
      target: AddedGraphicTarget, dx: Double, dy: Double, scaleX: Double, scaleY: Double
    )]
  ) -> Data? {
    guard let graph = editSession.currentGraph else { return nil }
    let commands = graphicTransformCommands(resizes)
    guard !commands.isEmpty,
      let preview = try? PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    else { return nil }
    return try? PDFWriter.write(preview)
  }

  @discardableResult
  func rotateGraphic(_ target: AddedGraphicTarget) -> Bool {
    if let placementIndex = target.imagePlacementIndex,
      let pageID = pageID(at: target.pageIndex) {
      return applyImageTransaction([
        RotateImageCommand(pageID: pageID, placementIndex: placementIndex, degrees: 90)
      ])
    }
    return applyImageTransaction([
      RotateAddedGraphicCommand(streamID: target.streamID, degrees: 90)
    ])
  }

  // MARK: - OCR (P26)

  /// P26-003/P26-018: run the local OCR job for the current page.
  func runOCR() {
    presentOCR()
  }

  private var ocrLanguage: String {
    UserDefaults.standard.string(forKey: "spdf.ocr.language") ?? "en-US"
  }

  private var ocrLevel: OCRRecognitionLevel {
    OCRRecognitionLevel(
      rawValue: UserDefaults.standard.string(forKey: "spdf.ocr.level") ?? "") ?? .accurate
  }

  /// OCR-02: choose the language, quality and pages before recognition. The
  /// chooser comes from Vision's installed language set, so an unavailable
  /// language is visible before any work starts.
  func presentOCR() {
    guard canRunOCR, let viewer, viewer.pageNumber > 0 else { return }
    let languages: [String]
    do {
      languages = try VisionTextRecognizer.supportedLanguages()
    } catch {
      presentError(error)
      return
    }
    guard !languages.isEmpty else {
      presentError(
        PDFError(.unsupported, "No text-recognition languages are installed on this system"))
      return
    }
    let languagePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 24))
    languagePopup.addItems(withTitles: languages)
    if let stored = languages.firstIndex(of: ocrLanguage) ?? languages.firstIndex(of: "en-US") {
      languagePopup.selectItem(at: stored)
    }
    let qualityPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
    qualityPopup.addItems(withTitles: ["Accurate", "Fast"])
    qualityPopup.selectItem(at: ocrLevel == .accurate ? 0 : 1)
    let pagesField = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
    pagesField.stringValue = "\(viewer.pageNumber)"
    let rows: [[NSView]] = [
      [NSTextField(labelWithString: "Language:"), languagePopup],
      [NSTextField(labelWithString: "Quality:"), qualityPopup],
      [NSTextField(labelWithString: "Pages:"), pagesField],
    ]
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 300, height: 90)
    let alert = NSAlert()
    alert.messageText = "Recognize Text"
    alert.informativeText =
      "Recognition is local. Only pages without a generated text layer are offered; "
      + "use pages such as 1, 3-5. A completed page gains a searchable text layer."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Recognize")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let language = languages[max(0, languagePopup.indexOfSelectedItem)]
    let level: OCRRecognitionLevel =
      qualityPopup.indexOfSelectedItem == 1 ? .fast : .accurate
    UserDefaults.standard.set(language, forKey: "spdf.ocr.language")
    UserDefaults.standard.set(level.rawValue, forKey: "spdf.ocr.level")
    let indices = pageIndices(from: pagesField.stringValue, count: editSession.pageIDs.count)
    let candidates = editSession.ocrCandidates()
    let candidateIDs = Set(candidates.map(\.pageID))
    let pageIDs = editSession.pageIDs
    let selected = indices.filter {
      $0 >= 0 && $0 < pageIDs.count && candidateIDs.contains(pageIDs[$0])
    }
    guard !selected.isEmpty else {
      presentError(
        PDFError(.unsupported, "The selected pages already have a generated text layer"))
      return
    }
    let replacing = Set(
      selected.filter { index in
        candidates.contains { $0.pageID == pageIDs[index] && $0.replacing }
      })
    startOCR(
      pageIndexes: selected, replacing: replacing, languages: [language], level: level)
  }

  /// P26-003: run the local OCR job for every candidate page.
  func runOCRAllPages() {
    guard viewer?.view.document != nil else { return }
    let candidates = editSession.ocrCandidates()
    guard !candidates.isEmpty else { return }
    var indexes: [Int] = []
    var replacing: Set<Int> = []
    for candidate in candidates {
      guard let index = editSession.pageIDs.firstIndex(of: candidate.pageID) else { continue }
      indexes.append(index)
      if candidate.replacing { replacing.insert(index) }
    }
    startOCR(
      pageIndexes: indexes, replacing: replacing,
      languages: [ocrLanguage], level: ocrLevel)
  }

  var canRunOCR: Bool {
    guard canEditContent, !isRunningOCR, let viewer, viewer.pageNumber > 0,
      viewer.pageNumber <= editSession.pageIDs.count
    else { return false }
    let pageID = editSession.pageIDs[viewer.pageNumber - 1]
    return editSession.ocrCandidates().contains { $0.pageID == pageID }
  }

  var canRunOCRAllPages: Bool {
    canEditContent && !isRunningOCR && !editSession.ocrCandidates().isEmpty
  }

  private func startOCR(
    pageIndexes: [Int], replacing: Set<Int>,
    languages: [String] = ["en-US"], level: OCRRecognitionLevel = .accurate
  ) {
    guard !isRunningOCR else { return }
    Task { @MainActor in
      do {
        try await performOCR(
          pageIndexes: pageIndexes, replacing: replacing, languages: languages, level: level)
      } catch is CancellationError {
      } catch { presentError(error) }
    }
  }

  /// Recognition reads an immutable in-memory graph snapshot. Applying its
  /// results requires the exact revision; edits, Undo, page moves or closing
  /// the document while recognition runs cannot attach text to stale pages.
  func performOCR(
    pageIndexes: [Int], replacing: Set<Int> = [],
    languages: [String] = ["en-US"], level: OCRRecognitionLevel = .accurate,
    recognizer: TextRecognizing = VisionTextRecognizer()
  ) async throws {
    guard !isRunningOCR, canEditContent, let graph = editSession.currentGraph else {
      throw PDFError(.unsupported, "This document is not available for OCR")
    }
    let revision = editSession.documentRevision
    let pageIDs = editSession.pageIDs
    // A protected session's decrypted graph is rendered only in memory.
    // Removing the encryption marker here does not change the edit session
    // or its re-encrypted save/recovery policy.
    var snapshot = graph
    if editSession.isProtected { snapshot.trailer[PDFName("Encrypt")] = nil }
    let bytes = try PDFWriter.write(snapshot)
    let job = try beginDocumentJob(title: "Recognizing text", total: pageIndexes.count)
    isRunningOCR = true
    defer {
      isRunningOCR = false
      jobCenter.finish(id: job)
    }
    let relay = JobProgressRelay(center: jobCenter)
    let progress: @Sendable (Int, Int) -> Void = { [relay, job] done, _ in
      relay.update(id: job, completed: done)
    }
    let results = try await OCRJob.run(
      data: bytes, pageIndexes: pageIndexes, languages: languages, level: level,
      recognizer: recognizer, onProgress: progress)
    try Task.checkCancellation()
    guard !isClosed, editSession.documentRevision == revision else {
      throw PDFError(
        .unsupported, "The document changed during OCR. Run recognition again on the current pages."
      )
    }
    let commands = results.compactMap { result -> AddSearchableTextLayerCommand? in
      guard !result.lines.isEmpty, pageIDs.indices.contains(result.pageIndex) else { return nil }
      let lines = result.lines.map {
        SearchableTextLine(text: $0.text, rect: $0.rect, confidence: $0.confidence)
      }
      return AddSearchableTextLayerCommand(
        pageID: pageIDs[result.pageIndex], lines: lines,
        replacingExistingLayer: replacing.contains(result.pageIndex))
    }
    guard !commands.isEmpty else {
      throw PDFError(.unsupported, "No text was recognized on the selected pages")
    }
    try editSession.apply(PDFTransaction(commands))
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    if results.contains(where: { $0.usedFastFallback }) {
      let alert = NSAlert()
      alert.messageText = "Fast Recognition Used"
      alert.informativeText =
        "Accurate text recognition is unavailable on this system. The selected pages were "
        + "recognized with Fast quality; review the text before relying on it."
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  /// P26-010: apply a searchable text layer from caller-provided lines (used
  /// by the smoke and by future review workflows).
  @discardableResult
  func applySearchableTextLayer(
    pageIndex: Int, lines: [SearchableTextLine], replacing: Bool
  ) -> Bool {
    guard canEditContent, pageIndex >= 0, pageIndex < editSession.pageIDs.count else { return false }
    do {
      try editSession.apply(
        PDFTransaction([
          AddSearchableTextLayerCommand(
            pageID: editSession.pageIDs[pageIndex], lines: lines,
            replacingExistingLayer: replacing)
        ]))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    return true
  }

  private func promptCropImage(pageIndex: Int, placementIndex: Int) {
    guard canEditContent else { return }
    let labels = ["Left", "Bottom", "Right", "Top"]
    let fields = labels.enumerated().map { index, _ -> NSTextField in
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
      field.stringValue = index < 2 ? "0" : "100"
      return field
    }
    let rows = zip(labels, fields).map { label, field -> [NSView] in
      [NSTextField(labelWithString: "\(label) %:"), field]
    }
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
    let alert = NSAlert()
    alert.messageText = "Crop Image"
    alert.informativeText =
      "Values are percentages of the image from its left, bottom, right and top edges. "
      + "The crop is nondestructive: the image data is preserved and the change can be undone."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Crop")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let values = fields.compactMap { Double($0.stringValue) }
    guard values.count == 4,
      values.allSatisfy({ $0.isFinite && (0...100).contains($0) }),
      values[0] < values[2], values[1] < values[3]
    else {
      NSSound.beep()
      return
    }
    _ = cropImage(
      pageIndex: pageIndex, placementIndex: placementIndex,
      unitRect: [
        values[0] / 100, values[1] / 100, values[2] / 100, values[3] / 100,
      ])
  }

  private func promptImageGeometry(pageIndex: Int, placementIndex: Int) {
    guard canEditContent, let graph = editSession.currentGraph,
      let pageID = pageID(at: pageIndex),
      let placements = try? ImageInventory.placements(in: graph, pageID: pageID),
      placementIndex >= 0, placementIndex < placements.count
    else { return }
    let bounds = placements[placementIndex].bounds
    guard bounds.count == 4 else { return }
    let values = [bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1]]
    let labels = ["X:", "Y:", "Width:", "Height:"]
    let fields = values.map { value -> NSTextField in
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
      field.stringValue = String(format: "%.2f", value)
      return field
    }
    let rows: [[NSView]] = zip(labels, fields).map { label, field in
      [NSTextField(labelWithString: label), field]
    }
    let grid = NSGridView(views: rows)
    grid.column(at: 0).xPlacement = .trailing
    grid.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
    let alert = NSAlert()
    alert.messageText = "Size and Position"
    alert.informativeText =
      "Values are page-space points. Width and height scale the placement from its top-left corner; "
      + "rotated images must be rotated back to 0° or 180° first. The change is one undo step."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let entered = fields.compactMap { Double($0.stringValue) }
    guard entered.count == 4 else {
      NSSound.beep()
      return
    }
    _ = setImageGeometry(
      pageIndex: pageIndex, placementIndex: placementIndex,
      x: entered[0], y: entered[1], width: entered[2], height: entered[3])
  }

  private func promptReplaceImage(pageIndex: Int, placementIndex: Int, shared: Bool) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg]
    panel.allowsMultipleSelection = false
    panel.message =
      shared ? "Replace every placement that shares this image." : "Replace this image instance."
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      guard let data = try? Data(contentsOf: url) else { return }
      _ = self.replaceImage(
        pageIndex: pageIndex, placementIndex: placementIndex, with: data, shared: shared)
    }
  }

  private func applyImageTransaction(_ commands: [any PDFEditCommand]) -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshViewer(preservingPage: viewer?.pageNumber ?? 1)
    // SAF-02: pre-redaction recovery snapshots still contain the removed
    // content. Replace them with a secure snapshot of the current state before
    // the next autosave interval.
    if editSession.requiresSecureRewrite {
      discardRecoveryRecords()
      snapshotRecoveryNow()
    }
    return true
  }

  private func pageID(at index: Int) -> PDFObjectID? {
    guard index >= 0, index < editSession.pageIDs.count else { return nil }
    return editSession.pageIDs[index]
  }

  /// P22-021: write the local review summary. Nothing leaves the machine.
  func exportReviewSummary() {
    let comments = editSession.comments()
    guard !comments.isEmpty else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "review-summary.txt"
    panel.allowedContentTypes = [.plainText]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try Data(CommentSummary.text(comments: comments).utf8).write(to: url, options: .atomic)
      } catch {
        self.presentError(error)
      }
    }
  }

  /// REV-01: exchange review comments with another Acrobat-compatible tool.
  var canExportComments: Bool { !editSession.comments().isEmpty }
  var canImportComments: Bool { canEditContent }

  func exportComments() {
    let comments = editSession.comments()
    guard !comments.isEmpty else { return }
    let result: CommentExportResult
    do {
      result = try CommentExchange.export(comments: comments)
    } catch {
      presentError(error)
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "comments.xfdf"
    panel.allowedContentTypes = [UTType(filenameExtension: "xfdf") ?? .xml]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      do {
        try result.data.write(to: url, options: .atomic)
      } catch {
        self.presentError(error)
        return
      }
      guard !result.skipped.isEmpty else { return }
      let alert = NSAlert()
      alert.messageText = "Some Comments Were Not Exported"
      alert.informativeText = result.skipped.prefix(12).joined(separator: "\n")
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  func importComments() {
    guard canEditContent else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      UTType(filenameExtension: "xfdf") ?? .xml, .xml,
    ]
    panel.allowsMultipleSelection = false
    panel.message = "Choose an XFDF comment file to merge into this document."
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self, self.canEditContent,
        let graph = self.editSession.currentGraph
      else { return }
      do {
        let data = try Data(contentsOf: url)
        let parsed = try CommentExchange.parse(data)
        let plan = try CommentExchange.plan(
          entries: parsed.entries, issues: parsed.issues, into: graph,
          pageIDs: self.editSession.pageIDs)
        if !plan.commands.isEmpty {
          try self.editSession.apply(PDFTransaction(plan.commands))
          self.noteUserEdit()
          self.refreshViewer(preservingPage: self.viewer?.pageNumber ?? 1)
        }
        var lines = [
          "Imported \(plan.added) new comment\(plan.added == 1 ? "" : "s"), updated \(plan.updated), unchanged \(plan.unchanged)."
        ]
        if !plan.skipped.isEmpty {
          lines.append("")
          lines.append("Skipped:")
          lines.append(contentsOf: plan.skipped.prefix(12))
        }
        let alert = NSAlert()
        alert.messageText = plan.commands.isEmpty ? "No Comment Changes" : "Comments Imported"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
      } catch {
        self.presentError(error)
      }
    }
  }

  /// P30-015: re-inventory signatures and validate each one. Cryptographic
  /// validity, certificate trust, and revision changes are separate statuses;
  /// validation is offline and never claims revocation was checked.
  func refreshSignatures() {
    guard let graph = editSession.currentGraph, let source = sourceStore.snapshot() else {
      signaturesModel.entries = []
      return
    }
    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    signaturesModel.entries = signatures.enumerated().map { index, signature in
      let validation = PDFSignatureValidator.validate(
        signature, source: source.data, finalGraph: graph)
      return SignaturesModel.Entry(
        id: "\(signature.objectID?.number ?? 0)-\(index)", signature: signature,
        validation: validation)
    }
  }

  var hasSignatures: Bool { !signaturesModel.entries.isEmpty }

  /// Whole-document restrictions that prevent safe content rewrites. A
  /// digitally signed PDF stays viewable, but PDFWriter cannot preserve its
  /// signed byte ranges through the normal edit/save path.
  var canEditContent: Bool { editSession.canEdit && !hasSignatures }

  var contentEditingRestrictionNotice: String? {
    if viewer?.isLocked == true {
      return "This PDF is password-protected. Choose Tools → Security → Unlock Document to continue."
    }
    if editSession.repairedEditGated {
      return "This repaired copy did not pass validation, so editing is paused to protect its contents. Open a clean original or review the repair report and create a validated copy."
    }
    if editSession.isProtected && !editSession.protectionAllowsEditing {
      return "This password allows reading but not modification. Ask the document owner for an editable copy; Save As does not remove the PDF's permission restrictions."
    }
    if hasSignatures {
      return "This PDF contains a digital signature. Editing would invalidate the signed document, so sPDF keeps it view-only. Open an unsigned copy if you need to make changes."
    }
    if !editSession.canEdit {
      return "sPDF can display this PDF, but its document structure is outside the safe editing profile. The source remains unchanged; open a copy in an editor that supports this structure."
    }
    return nil
  }

  /// P43-002/P43-004: refresh the font inspector with current statuses.
  func refreshFonts() {
    guard let graph = editSession.currentGraph else {
      fontsModel.update(with: [])
      return
    }
    WorkspacePerformance.profile("font-inventory") {
      let fonts = PDFFontInventory.fonts(in: graph, pageIDs: editSession.pageIDs)
      fontsModel.update(with: FontProvisioning.statuses(for: fonts))
    }
  }

  var hasFonts: Bool { !fontsModel.entries.isEmpty }

  /// P43-005/P43-006/P43-008/P43-009: fetch a Google Fonts family only as an
  /// explicit user action, show the license text, and install after it is
  /// accepted. Nothing about the document is uploaded — only the family the
  /// user chose is requested.
  func provisionFont(family: String) {
    guard !fontsModel.isBusy else { return }
    fontsModel.isBusy = true
    fontsModel.message = "Searching Google Fonts…"
    Task { @MainActor in
      defer { fontsModel.isBusy = false }
      do {
        let job = try beginDocumentJob(title: "Preparing font installation", total: 1)
        defer { jobCenter.finish(id: job) }
        let families = try await GoogleFontsCatalog.families()
        try Task.checkCancellation()
        let matches = GoogleFontsCatalog.search(family, in: families)
        guard let match = matches.first else {
          fontsModel.message = nil
          let alert = NSAlert()
          alert.messageText = "No Google Fonts Match"
          alert.informativeText =
            "“\(family)” was not found in the Google Fonts catalog. Commercially licensed fonts are never downloaded by this app."
          alert.runModal()
          return
        }
        fontsModel.message = "Downloading \(match.name)…"
        let package = try await GoogleFontsInstaller.prepare(family: match.name)
        try Task.checkCancellation()
        let licenseAlert = NSAlert()
        licenseAlert.messageText = "Install \(match.name)?"
        licenseAlert.informativeText =
          "The full \(package.licenseDirectory?.uppercased() ?? "open-source") license is shown below. Installing records your acceptance and makes eligible font files available for embedded PDF writing."
        let licenseText = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        licenseText.string = package.licenseText ?? "License text unavailable."
        licenseText.isEditable = false
        licenseText.isSelectable = true
        licenseText.font = .systemFont(ofSize: 11)
        licenseText.textContainerInset = NSSize(width: 8, height: 8)
        licenseText.textContainer?.widthTracksTextView = true
        let licenseScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        licenseScroll.hasVerticalScroller = true
        licenseScroll.hasHorizontalScroller = false
        licenseScroll.documentView = licenseText
        licenseAlert.accessoryView = licenseScroll
        licenseAlert.addButton(withTitle: "Install")
        licenseAlert.addButton(withTitle: "Cancel")
        guard licenseAlert.runModal() == .alertFirstButtonReturn else {
          fontsModel.message = nil
          return
        }
        try Task.checkCancellation()
        let directory = Self.fontsInstallDirectoryOverride
        let urls = try GoogleFontsInstaller.install(
          package, to: directory, licenseAccepted: true)
        refreshFonts()
        fontsModel.message =
          "Installed \(urls.count) file\(urls.count == 1 ? "" : "s") for \(match.name)."
      } catch is CancellationError {
        fontsModel.message = nil
      } catch {
        fontsModel.message = nil
        presentError(error)
      }
    }
  }

  /// P33-022: analyze the open document for tagging suggestions and show the
  /// review sidebar. Nothing is applied until the reviewer accepts.
  func suggestStructureTags() {
    guard let graph = editSession.currentGraph else { return }
    do {
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let suggestions = try StructureTaggingAssistant.analyze(pageIDs: pageIDs, in: graph)
      structureModel.review = TaggingReview(suggestions: suggestions)
      viewer?.sidebarMode = .structure
      viewer?.isSidebarVisible = true
    } catch {
      presentError(error)
    }
  }

  /// P33-022: apply only the accepted suggestions; figures need alternate
  /// text first, so a reviewer is prompted for each one.
  func applyAcceptedStructureSuggestions() {
    guard canEditContent, var review = structureModel.review else { return }
    var commands: [ApplyTaggingSuggestionCommand] = []
    var applied: Set<UUID> = []
    var skippedFigures = 0
    for suggestion in review.accepted {
      if case .figure = suggestion.kind, TaggingReview.command(for: suggestion) == nil {
        guard let altText = promptForAltText(suggestion: suggestion) else {
          skippedFigures += 1
          continue
        }
        if let command = TaggingReview.command(for: suggestion, altText: altText) {
          commands.append(command)
          applied.insert(suggestion.id)
        }
        continue
      }
      if let command = TaggingReview.command(for: suggestion) {
        commands.append(command)
        applied.insert(suggestion.id)
      }
    }
    guard !commands.isEmpty else {
      if skippedFigures > 0 {
        let alert = NSAlert()
        alert.messageText = "Alternate Text Needed"
        alert.informativeText =
          "\(skippedFigures) figure suggestion\(skippedFigures == 1 ? "" : "s") need alternate text before they can be applied."
        alert.runModal()
      }
      return
    }
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return
    }
    noteUserEdit()
    review.remove(applied)
    structureModel.review = review.suggestions.isEmpty ? nil : review
    refreshStructure()
    if skippedFigures > 0 {
      let alert = NSAlert()
      alert.messageText = "Alternate Text Needed"
      alert.informativeText =
        "\(skippedFigures) figure suggestion\(skippedFigures == 1 ? "" : "s") still need alternate text."
      alert.runModal()
    }
  }

  private func promptForAltText(suggestion: TaggingSuggestion) -> String? {
    let field = NSTextField(string: "")
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    let alert = NSAlert()
    alert.messageText = "Alternate Text"
    alert.informativeText = "Describe the image for assistive technology before tagging it."
    alert.accessoryView = field
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Skip")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// P33-008/P33-009/P33-013: structure edits through the canonical session.
  @discardableResult
  func setStructureRole(elementID: PDFObjectID, role: String) -> Bool {
    applyStructureEdit([SetStructureRoleCommand(elementID: elementID, role: PDFName(role))])
  }

  @discardableResult
  func markStructureArtifact(elementID: PDFObjectID) -> Bool {
    applyStructureEdit([MarkStructureArtifactCommand(elementID: elementID)])
  }

  func promptStructureAltText(elementID: PDFObjectID) {
    var current = ""
    if let graph = editSession.currentGraph,
      case .dictionary(let element)? = graph.objects[elementID],
      case .string(let data)? = element[PDFName("Alt")]
    {
      current = String(decoding: data, as: UTF8.self)
    }
    let field = NSTextField(string: current)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    let alert = NSAlert()
    alert.messageText = "Alternate Text"
    alert.informativeText =
      "Describe the figure for assistive technology. Clear the field to remove the description."
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let text = field.stringValue
    _ = applyStructureEdit([
      SetStructureAltTextCommand(elementID: elementID, alt: text.isEmpty ? nil : text)
    ])
  }

  private func applyStructureEdit(_ commands: [any PDFEditCommand]) -> Bool {
    guard canEditContent else { return false }
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      presentError(error)
      return false
    }
    noteUserEdit()
    refreshStructure()
    return true
  }

  /// P33-006: re-inventory the structure tree for the inspector.
  func refreshStructure() {
    guard let graph = editSession.currentGraph else {
      structureModel.update(with: nil)
      return
    }
    structureModel.update(
      with: try? PDFStructureInspector.inspect(in: graph, pageIDs: editSession.pageIDs))
  }

  /// P30-015: navigate to the page of a signature field.
  func navigate(toSignatureAt pageIndex: Int) {
    viewer?.focus(onPageIndex: pageIndex, rect: [])
  }

  /// P10-003: open a file dropped onto the window, like a Dock drop.
  func openDroppedFile(_ url: URL) {
    Task { @MainActor [weak self] in
      do {
        _ = try await NSDocumentController.shared.openDocument(
          withContentsOf: url, display: true)
      } catch {
        self?.presentError(error)
      }
    }
  }

  func refreshComments() {
    commentsModel.comments = WorkspacePerformance.profile("comments-inventory") {
      editSession.comments()
    }
  }

  /// P12-020: install document facts for the info panel from the core
  /// inventory; cleared when no document content is available.
  func refreshDocumentInfo() {
    viewer?.allowsContentEditing = canEditContent
    viewer?.editingRestrictionNotice = contentEditingRestrictionNotice
    guard let viewer, let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else {
      viewer?.documentInfo = nil
      return
    }
    let facts = PDFDocumentInventory.documentFacts(
      in: graph, pageCount: editSession.pageIDs.count)
    let assessment = PDFDocumentInventory.assess(
      in: graph, pageCount: editSession.pageIDs.count)
    viewer.documentInfo = ViewerDocumentInfo(
      fileName: fileURL?.lastPathComponent ?? displayName,
      pageCount: editSession.pageIDs.count, title: facts.metadata.title,
      author: facts.metadata.author, subject: facts.metadata.subject,
      keywords: facts.metadata.keywords, creator: facts.metadata.creator,
      producer: facts.metadata.producer, language: facts.metadata.language,
      capabilitySummary: assessment.summary)
  }

  func refreshForms() {
    WorkspacePerformance.profile("forms-inventory") {
      formsModel.fields = editSession.formFields()
      guard let graph = editSession.currentGraph else {
        formsModel.orphanedWidgetCount = 0
        return
      }
      formsModel.orphanedWidgetCount =
        FormInventory.orphanedWidgets(
          in: graph, pageIDs: editSession.pageIDs
        ).count
    }
  }

  /// UTC PDF date string for annotation timestamps.
  private static func pdfDateString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "'D:'yyyyMMddHHmmss'Z'"
    return formatter.string(from: date)
  }

  private func refreshWorkspaceActions() {
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
  }

  private func refreshViewer(preservingPage page: Int) {
    defer { refreshWorkspaceActions() }
    guard
      let data = try? WorkspacePerformance.profile(
        "serialize-for-viewer",
        operation: {
          try editSession.bytesForSave()
        }),
      let source = try? PDFSource(data: data)
    else { return }
    let tool = viewer?.activeTool ?? .select
    let selectedGraphics = viewer?.selectedGraphics ?? []
    let scale = viewer?.view.scaleFactor ?? 1
    let autoScales = viewer?.view.autoScales ?? true
    try? WorkspacePerformance.profile("renderer-reload") { try viewer?.open(source) }
    viewer?.view.autoScales = autoScales
    if !autoScales { viewer?.view.scaleFactor = scale }
    viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
    let refreshedGraphics = selectedGraphics.compactMap { selected in
      graphicsList(pageIndex: selected.pageIndex).first { $0.identity == selected.identity }
    }
    if !refreshedGraphics.isEmpty { viewer?.selectGraphics(refreshedGraphics) }
    refreshComments()
    refreshForms()
    refreshFonts()
    refreshAttachments()
    refreshBookmarks()
    refreshDocumentInfo()
    snapshotRecoveryIfNeeded()
  }

  private func beginDocumentJob(title: String, total: Int) throws -> UUID {
    try Task.checkCancellation()
    guard !isClosed else { throw CancellationError() }
    let id = jobCenter.start(title: title, total: total)
    // This handle is retained only while its producing task is alive: defer
    // removes the canceller before the async method returns.
    withUnsafeCurrentTask { task in jobCenter.attach(id: id) { task?.cancel() } }
    return id
  }

  /// Flush all visible input before NSDocument evaluates whether to save.
  /// A failed commit leaves the editor and dirty state available for retry.
  func finishPendingEdits() -> Bool {
    if viewer?.hasPendingInkGesture?() == true || viewer?.hasPendingGraphicGesture?() == true
      || viewer?.hasPendingTextGesture?() == true
    {
      let alert = NSAlert()
      alert.messageText = "Finish the current edit first"
      alert.informativeText = "Release the drag or press Escape, then try quitting again."
      alert.addButton(withTitle: "Keep Working")
      alert.runModal()
      return false
    }
    guard viewer?.pendingEditFinisher?() ?? true else { return false }
    for (name, text) in formsModel.pendingText {
      if editSession.formFields().first(where: { $0.name == name })?.stringValue == text {
        formsModel.pendingText[name] = nil
        pendingFormText.setPending(false, for: name)
      } else if !fillFormText(fieldName: name, text: text) {
        return false
      }
    }
    for controller in windowControllers {
      if let window = controller.window, !window.makeFirstResponder(nil) { return false }
    }
    // NSDocument's canClose machinery commits registered Cocoa editors; the
    // app's native and SwiftUI editors are explicitly flushed above.
    return true
  }

  /// SAF-03: common gate for operations that write a derivative PDF. Pending
  /// input is committed first; editable operations require an editable graph;
  /// signed documents are refused unless the derivative preserves them; and
  /// the destination must not be the open source.
  @discardableResult
  private func prepareDerivative(
    to url: URL, requiresEditable: Bool = true, allowSigned: Bool = false,
    allowProtected: Bool = false
  ) throws -> PDFGraph {
    guard finishPendingEdits() else {
      throw PDFError(.unsupported, "Finish the current edit before creating a derivative")
    }
    if requiresEditable {
      guard canEditContent else {
        throw PDFError(.unsupported, "This document is read-only for editing")
      }
      if !allowProtected {
        guard !editSession.isProtected else {
          throw PDFError(
            .unsupported,
            "Save an unlocked, unencrypted copy before creating this derivative")
        }
      }
    }
    if !allowSigned, hasSignatures {
      throw PDFError(
        .unsupported,
        "This derivative would invalidate existing signatures; remove them first")
    }
    try DerivativeOutputPolicy.validateDestination(url, source: fileURL)
    guard let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "The document has no editable graph")
    }
    return graph
  }

  override func canClose(
    withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    TerminationCoordinator.shared.prepareToClose(self) { [self] allowed in
      if let selector = shouldCloseSelector, let receiver = delegate as? NSObject,
        receiver.responds(to: selector), let implementation = receiver.method(for: selector)
      {
        // AppKit's documented canClose callback has three arguments. perform
        // supports only two; invoke its exact Objective-C ABI, including the
        // caller's context, to deliver the reviewed decision exactly once.
        typealias Reply =
          @convention(c) (
            AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?
          ) -> Void
        unsafeBitCast(implementation, to: Reply.self)(
          receiver, selector, self, allowed, contextInfo)
      }
    }
  }

  /// The app-wide gate has already finished pending edits and jobs. Bypass
  /// our per-window preparation while retaining AppKit's real save decision.
  func reviewClose(
    withDelegate delegate: Any, shouldClose selector: Selector?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    super.canClose(withDelegate: delegate, shouldClose: selector, contextInfo: contextInfo)
  }

  override func close() {
    isClosed = true
    // Retire SwiftUI subscriptions while the document and viewer are still
    // alive, before publishing the renderer's empty/closed state.
    for controller in windowControllers { controller.window?.contentView = nil }
    pageOrganizerWindow?.close()
    pageOrganizerWindow = nil
    pageOrganizerModel = nil
    combineWindow?.close()
    combineWindow = nil
    combineModel = nil
    attachmentsWindow?.close()
    attachmentsWindow = nil
    attachmentsModel = nil
    bookmarksWindow?.close()
    bookmarksWindow = nil
    bookmarksModel = nil
    signatureWindow?.close()
    signatureWindow = nil
    for window in tableReviewWindows { window.close() }
    tableReviewWindows.removeAll()
    tableReviewModel = nil
    for job in jobCenter.jobs { jobCenter.requestCancel(id: job.id) }
    if let viewer { saveViewState(viewer: viewer) }
    // An explicit close means the user decided; stale recovery state is not
    // offered again (P10-021).
    discardRecoveryRecords()
    inspectionTask?.cancel()
    inspectionTask = nil
    viewer?.closeDocument()
    viewer = nil
    restoredFileAccess?.stopAccessingSecurityScopedResource()
    restoredFileAccess = nil
    super.close()
  }
}
