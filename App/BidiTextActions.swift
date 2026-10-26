import AppKit
import MacServices
import PDFCore
import PDFEditing

/// FNT-05/FNT-06: document-facing services for shaped text insertion. The
/// panel model stays independent of SPDFDocument through these closures.
@MainActor
struct ShapedTextInsertionHost {
  var pageIDs: @MainActor () -> [PDFObjectID]
  var currentPageIndex: @MainActor () -> Int
  var graph: @MainActor () -> PDFGraph?
  var apply: @MainActor (PDFTransaction, String) -> Bool
  var refresh: @MainActor (Int) -> Void
}

/// FNT-05/FNT-06: the insertion panel model. It builds one command for the
/// chosen profile and applies it as one undoable transaction.
@MainActor
final class ShapedTextInsertionModel: ObservableObject {
  enum Mode: String, CaseIterable, Identifiable {
    case bidirectional = "Bidirectional"
    case horizontalCJK = "Horizontal CJK"
    case verticalCJK = "Vertical CJK"

    var id: String { rawValue }
  }

  struct FontChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let path: String
    let coreTextName: String
    let baseName: String
  }

  static let fontChoices: [FontChoice] = [
    .init(
      id: "arial-unicode",
      label: "Arial Unicode (Arabic, Hebrew, CJK)",
      path: "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
      coreTextName: "ArialUnicodeMS", baseName: "ArialUnicodeMS"),
    .init(
      id: "sf-arabic", label: "SF Arabic", path: "/System/Library/Fonts/SFArabic.ttf",
      coreTextName: ".SF Arabic", baseName: "SFArabic"),
    .init(
      id: "sf-hebrew", label: "SF Hebrew", path: "/System/Library/Fonts/SFHebrew.ttf",
      coreTextName: ".SF Hebrew", baseName: "SFHebrew"),
  ]

  @Published var mode: Mode = .bidirectional
  @Published var text = ""
  @Published var fontID = "arial-unicode"
  @Published var pointSize = 18.0
  @Published var baseDirection: BidiBaseDirection = .automatic
  @Published var language = ""
  @Published var columnHeight = 320.0
  @Published var pageIndex = 0
  @Published var message: String?
  @Published var isApplying = false

  let host: ShapedTextInsertionHost
  var requestClose: (() -> Void)?

  init(host: ShapedTextInsertionHost) {
    self.host = host
  }

  var pageCount: Int { host.pageIDs().count }
  var pageLabel: String { "Page \(pageIndex + 1) of \(max(1, pageCount))" }
  var selectedFont: FontChoice {
    Self.fontChoices.first { $0.id == fontID } ?? Self.fontChoices[0]
  }
  var canInsert: Bool {
    !isApplying && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && pageCount > 0
  }

  func reload() {
    pageIndex = min(max(0, host.currentPageIndex()), max(0, pageCount - 1))
    if message == nil { message = "Choose a profile, font and text." }
  }

  func insert() {
    guard let graph = host.graph() else {
      message = "No document is open"
      return
    }
    let pageIDs = host.pageIDs()
    guard pageIDs.indices.contains(pageIndex) else {
      message = "The current page is unavailable"
      return
    }
    let pageID = pageIDs[pageIndex]
    let font = selectedFont
    do {
      let program = try Data(contentsOf: URL(fileURLWithPath: font.path))
      let source = ShapedFontSource(
        program: program, fontName: font.coreTextName, baseName: font.baseName)
      let command: any PDFEditCommand
      switch mode {
      case .bidirectional:
        command = InsertBidirectionalTextCommand(
          pageID: pageID, origin: [72, 640], pointSize: pointSize, font: source,
          text: text, language: language.isEmpty ? nil : language,
          baseDirection: baseDirection)
      case .horizontalCJK:
        command = InsertHorizontalCJKTextCommand(
          pageID: pageID, origin: [72, 700], maxWidth: 470, pointSize: pointSize,
          font: source, text: text)
      case .verticalCJK:
        command = InsertVerticalCJKTextCommand(
          pageID: pageID, origin: [520, 700], columnHeight: columnHeight,
          pointSize: pointSize, font: source, text: text)
      }
      try command.validate(in: graph)
      let transaction = PDFTransaction([command])
      isApplying = true
      defer { isApplying = false }
      guard host.apply(transaction, command.name) else {
        message = "The document refused the shaped text insertion"
        return
      }
      message = "Inserted \(mode.rawValue.lowercased()) text"
      host.refresh(pageIndex)
    } catch {
      message = error.localizedDescription
    }
  }
}

private enum ShapedTextAssociationKeys {
  nonisolated(unsafe) static var model: UInt8 = 0
}

extension SPDFDocument {
  /// FNT-05/FNT-06 menu hook: Tools > Text > Insert Bidirectional Text...
  var shapedTextInsertionModel: ShapedTextInsertionModel {
    if let existing = objc_getAssociatedObject(
      self, &ShapedTextAssociationKeys.model) as? ShapedTextInsertionModel
    {
      return existing
    }
    let host = ShapedTextInsertionHost(
      pageIDs: { [weak self] in self?.editSession.pageIDs ?? [] },
      currentPageIndex: { [weak self] in
        max(0, (self?.viewer?.pageNumber ?? 1) - 1)
      },
      graph: { [weak self] in self?.editSession.currentGraph },
      apply: { [weak self] transaction, name in
        self?.applyShapedTextTransaction(transaction, actionName: name) ?? false
      },
      refresh: { [weak self] page in
        self?.refreshViewerAfterShapedTextInsertion(preservingPage: page)
      })
    let model = ShapedTextInsertionModel(host: host)
    objc_setAssociatedObject(
      self, &ShapedTextAssociationKeys.model, model,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return model
  }

  var canShowBidiTextInsertionPanel: Bool {
    viewer != nil && !editSession.pageIDs.isEmpty
  }
  var canShowCJKTextInsertionPanel: Bool { canShowBidiTextInsertionPanel }

  /// Menu hook: Tools > Text > Insert Bidirectional Text...
  func showBidirectionalTextInsertion() {
    let model = shapedTextInsertionModel
    model.mode = .bidirectional
    model.reload()
    presentShapedTextPanel(model: model)
  }

  /// Menu hook: Tools > Text > Insert CJK / Vertical Text...
  func showCJKTextInsertion() {
    let model = shapedTextInsertionModel
    model.mode = .horizontalCJK
    model.reload()
    presentShapedTextPanel(model: model)
  }

  private func presentShapedTextPanel(model: ShapedTextInsertionModel) {
    if let controller = windowControllers.compactMap({
      $0 as? ShapedTextInsertionPanelController
    }).first {
      controller.refreshPresentation()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = ShapedTextInsertionPanelController(model: model)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  @discardableResult
  func applyShapedTextTransaction(
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
    registerShapedTextUndo(registeredRevision: revision, actionName: actionName)
    return true
  }

  func refreshViewerAfterShapedTextInsertion(preservingPage page: Int) {
    defer {
      workspaceDocumentState.hasChanges = isDocumentEdited
      workspaceDocumentState.canUndo = editSession.canUndo
      workspaceDocumentState.canRedo = editSession.canRedo
    }
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data)
    else { return }
    let tool = viewer?.activeTool ?? .select
    try? viewer?.open(source)
    _ = viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
  }

  func registerShapedTextUndo(registeredRevision: UInt64?, actionName: String) {
    defer {
      workspaceDocumentState.hasChanges = isDocumentEdited
      workspaceDocumentState.canUndo = editSession.canUndo
      workspaceDocumentState.canRedo = editSession.canRedo
    }
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performShapedTextUndo(
        registeredRevision: registeredRevision, actionName: actionName)
    }
    undoManager.setActionName(actionName)
    undoManager.endUndoGrouping()
  }

  func performShapedTextUndo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performShapedTextRedo(
        registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    refreshViewerAfterShapedTextInsertion(preservingPage: viewer?.pageNumber ?? 0)
  }

  func performShapedTextRedo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performShapedTextUndo(
        registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    refreshViewerAfterShapedTextInsertion(preservingPage: viewer?.pageNumber ?? 0)
  }
}
