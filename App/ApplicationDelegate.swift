import AppKit
import DocumentSession
import MacServices
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var welcome: NSWindowController?
  private let documents = NSDocumentController.shared

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenus()
    #if DEBUG
      if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"),
        CommandLine.arguments.count > index + 2
      {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 2], isDirectory: true)
        Task { await SmokeTest.run(fixtures: fixtures, output: output) }
        return
      }
    #endif
    if documents.documents.isEmpty { showWelcome() }
    offerRecoveryIfNeeded()
    NSApp.activate(ignoringOtherApps: true)
  }

  /// P10-020: offer to restore unsaved edits from a previous session.
  private func offerRecoveryIfNeeded() {
    let store = SPDFDocument.makeRecoveryStore()
    guard let key = store.pendingKeys().first else { return }
    let record = try? store.latest(for: key)
    let alert = NSAlert()
    alert.messageText = "Recover unsaved changes?"
    if let record {
      alert.informativeText =
        "sPDF Editor found unsaved edits from "
        + "\(record.savedAt.formatted(date: .abbreviated, time: .shortened))."
    } else {
      alert.informativeText = "sPDF Editor found unsaved edits from a previous session."
    }
    alert.addButton(withTitle: "Recover")
    alert.addButton(withTitle: "Discard")
    guard alert.runModal() == .alertFirstButtonReturn,
      let bytes = try? store.latestBytes(for: key)
    else {
      try? store.discard(for: key)
      return
    }
    Task { @MainActor in
      if let document = try? await documents.openUntitledDocumentAndDisplay(true)
        as? SPDFDocument
      {
        document.loadRecovered(bytes)
      }
    }
  }

  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows && documents.documents.isEmpty { showWelcome() }
    return true
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    #if DEBUG
      // AppKit also interprets positional launch arguments as file-open requests.
      // The smoke harness owns its fixture/output paths and opens documents itself.
      if CommandLine.arguments.contains("--smoke-test") {
        sender.reply(toOpenOrPrint: .success)
        return
      }
    #endif
    Task {
      var success = true
      for filename in filenames {
        do {
          _ = try await documents.openDocument(
            withContentsOf: URL(fileURLWithPath: filename), display: true)
          welcome?.close()
        } catch {
          success = false
          documents.presentError(error)
        }
      }
      sender.reply(toOpenOrPrint: success ? .success : .failure)
    }
  }

  private var currentDocument: SPDFDocument? { documents.currentDocument as? SPDFDocument }

  @objc private func previousPage(_ sender: Any?) { currentDocument?.viewer?.previousPage() }
  @objc private func nextPage(_ sender: Any?) { currentDocument?.viewer?.nextPage() }
  @objc private func firstPage(_ sender: Any?) { currentDocument?.viewer?.firstPage() }
  @objc private func lastPage(_ sender: Any?) { currentDocument?.viewer?.lastPage() }
  @objc private func goBack(_ sender: Any?) { currentDocument?.viewer?.goBack() }
  @objc private func goForward(_ sender: Any?) { currentDocument?.viewer?.goForward() }
  @objc private func fitWidth(_ sender: Any?) { currentDocument?.viewer?.fitWidth() }
  @objc private func toggleRulers(_ sender: Any?) { currentDocument?.viewer?.toggleRulers() }
  @objc private func toggleGuides(_ sender: Any?) { currentDocument?.viewer?.toggleGuides() }
  @objc private func zoomIn(_ sender: Any?) { currentDocument?.viewer?.zoomIn() }
  @objc private func zoomOut(_ sender: Any?) { currentDocument?.viewer?.zoomOut() }
  @objc private func fitPage(_ sender: Any?) { currentDocument?.viewer?.fitPage() }
  @objc private func actualSize(_ sender: Any?) { currentDocument?.viewer?.actualSize() }
  @objc private func rotateLeft(_ sender: Any?) { currentDocument?.rotateCurrentPage(byDegrees: -90) }
  @objc private func rotateRight(_ sender: Any?) { currentDocument?.rotateCurrentPage(byDegrees: 90) }
  @objc private func movePageUp(_ sender: Any?) { currentDocument?.moveCurrentPage(by: -1) }
  @objc private func movePageDown(_ sender: Any?) { currentDocument?.moveCurrentPage(by: 1) }
  @objc private func insertBlankPage(_ sender: Any?) { currentDocument?.insertBlankPageAfterCurrent() }
  @objc private func deletePage(_ sender: Any?) { currentDocument?.deleteCurrentPage() }
  @objc private func undoEdit(_ sender: Any?) { currentDocument?.undoEdit() }
  @objc private func redoEdit(_ sender: Any?) { currentDocument?.redoEdit() }
  @objc private func showFind(_ sender: Any?) { currentDocument?.viewer?.showSearch() }
  @objc private func findNext(_ sender: Any?) { currentDocument?.viewer?.searchNext() }
  @objc private func findPrevious(_ sender: Any?) { currentDocument?.viewer?.searchPrevious() }
  @objc private func showPagesSidebar(_ sender: Any?) { currentDocument?.viewer?.showPages() }
  @objc private func showCommentsSidebar(_ sender: Any?) { currentDocument?.viewer?.showComments() }
  @objc private func showFormsSidebar(_ sender: Any?) { currentDocument?.viewer?.showForms() }
  @objc private func showSignaturesSidebar(_ sender: Any?) {
    currentDocument?.viewer?.showSignatures()
  }
  @objc private func showInspectorSidebar(_ sender: Any?) { currentDocument?.viewer?.showInspector() }
  @objc private func showInfoSidebar(_ sender: Any?) { currentDocument?.viewer?.showInfo() }
  @objc private func showFontsSidebar(_ sender: Any?) {
    currentDocument?.viewer?.showFonts()
    currentDocument?.viewer?.isSidebarVisible = true
  }
  @objc private func showStructureSidebar(_ sender: Any?) {
    currentDocument?.viewer?.showStructure()
  }
  @objc private func highlightSelection(_ sender: Any?) {
    currentDocument?.addAnnotationFromSelection(.highlight)
  }
  @objc private func underlineSelection(_ sender: Any?) {
    currentDocument?.addAnnotationFromSelection(.underline)
  }
  @objc private func strikeoutSelection(_ sender: Any?) {
    currentDocument?.addAnnotationFromSelection(.strikeout)
  }
  @objc private func noteSelection(_ sender: Any?) {
    currentDocument?.addAnnotationFromSelection(.note)
  }
  @objc private func toggleInkTool(_ sender: Any?) {
    currentDocument?.viewer?.toggleInkTool()
  }
  @objc private func selectTool(_ sender: Any?) {
    _ = currentDocument?.viewer?.activateTool(.select)
  }
  @objc private func textEditTool(_ sender: Any?) {
    _ = currentDocument?.viewer?.activateTool(.textEdit)
  }
  @objc private func pageTool(_ sender: Any?) {
    _ = currentDocument?.viewer?.activateTool(.page)
  }
  @objc private func flattenAnnotations(_ sender: Any?) {
    currentDocument?.flattenAnnotations()
  }
  @objc private func flattenForm(_ sender: Any?) {
    currentDocument?.flattenForm()
  }
  @objc private func runOCR(_ sender: Any?) {
    currentDocument?.runOCR()
  }
  @objc private func runOCRAllPages(_ sender: Any?) {
    currentDocument?.runOCRAllPages()
  }
  @objc private func exportText(_ sender: Any?) {
    currentDocument?.exportText()
  }
  @objc private func exportHTML(_ sender: Any?) {
    currentDocument?.exportHTML()
  }
  @objc private func exportDOCX(_ sender: Any?) {
    currentDocument?.exportDOCX()
  }
  @objc private func previewDOCX(_ sender: Any?) {
    currentDocument?.previewDOCX()
  }
  @objc private func reviewTables(_ sender: Any?) {
    currentDocument?.reviewTables()
  }
  @objc private func exportTables(_ sender: Any?) {
    currentDocument?.exportTables(format: .xlsx)
  }
  @objc private func showCompatibilityReport(_ sender: Any?) {
    currentDocument?.showCompatibilityReport()
  }
  @objc private func createArchivalCopy(_ sender: Any?) {
    currentDocument?.createArchivalCopy()
  }
  @objc private func convertColors(_ sender: Any?) {
    currentDocument?.convertColors()
  }
  @objc private func placeGraphicalSignature(_ sender: Any?) {
    currentDocument?.placeGraphicalSignature()
  }
  @objc private func organizePages(_ sender: Any?) {
    currentDocument?.organizePages()
  }
  @objc private func repairDocument(_ sender: Any?) {
    currentDocument?.repairDocument()
  }
  @objc private func exportOutline(_ sender: Any?) {
    currentDocument?.exportOutline()
  }
  @objc private func exportAttachments(_ sender: Any?) {
    currentDocument?.exportAttachments()
  }
  @objc private func printDocument(_ sender: Any?) {
    currentDocument?.printDocument()
  }
  @objc private func exportImages(_ sender: Any?) {
    currentDocument?.exportImages()
  }
  @objc private func addTextField(_ sender: Any?) { currentDocument?.addTextField() }
  @objc private func addCheckbox(_ sender: Any?) { currentDocument?.addCheckbox() }
  @objc private func addRadioGroup(_ sender: Any?) { currentDocument?.addRadioGroup() }
  @objc private func addChoiceField(_ sender: Any?) { currentDocument?.addChoiceField() }
  @objc private func addPushButton(_ sender: Any?) { currentDocument?.addPushButton() }
  @objc private func addSignatureField(_ sender: Any?) { currentDocument?.addSignatureField() }
  @objc private func renameFormField(_ sender: Any?) { currentDocument?.renameFormField() }
  @objc private func editFormFieldProperties(_ sender: Any?) {
    currentDocument?.editFormFieldProperties()
  }
  @objc private func recalculateForm(_ sender: Any?) { currentDocument?.recalculateForm() }
  @objc private func duplicateFormField(_ sender: Any?) { currentDocument?.duplicateFormField() }
  @objc private func alignFormFields(_ sender: Any?) { currentDocument?.alignFormFields() }
  @objc private func distributeFormFields(_ sender: Any?) { currentDocument?.distributeFormFields() }
  @objc private func editFormTabOrder(_ sender: Any?) { currentDocument?.editFormTabOrder() }
  @objc private func deleteFormField(_ sender: Any?) { currentDocument?.deleteFormField() }
  @objc private func exportPrintPDF(_ sender: Any?) {
    currentDocument?.exportPrintPDF()
  }
  @objc private func exportPageImages(_ sender: Any?) {
    currentDocument?.exportPageImages()
  }
  @objc private func exportFormValues(_ sender: Any?) {
    currentDocument?.exportFormValues()
  }
  @objc private func importFormValues(_ sender: Any?) {
    currentDocument?.importFormValues()
  }
  @objc private func reflowParagraph(_ sender: Any?) { currentDocument?.reflowParagraph() }
  @objc private func editSelectedText(_ sender: Any?) {
    currentDocument?.editSelectedText()
  }
  @objc private func exportReviewSummary(_ sender: Any?) {
    currentDocument?.exportReviewSummary()
  }
  @objc private func redactSelection(_ sender: Any?) {
    currentDocument?.redactSelection()
  }
  @objc private func saveSanitizedCopy(_ sender: Any?) {
    currentDocument?.saveSanitizedCopy()
  }
  @objc private func importPages(_ sender: Any?) {
    currentDocument?.importPagesFromFile()
  }
  @objc private func copyAsRichText(_ sender: Any?) {
    currentDocument?.copySelectionAsRichText()
  }
  @objc private func exportEncryptedCopy(_ sender: Any?) {
    currentDocument?.exportEncryptedCopy()
  }
  @objc private func signDocument(_ sender: Any?) {
    currentDocument?.presentSignDocument()
  }
  @objc private func optimizeDocument(_ sender: Any?) {
    currentDocument?.presentOptimizeDocument()
  }
  @objc private func compareWithDocument(_ sender: Any?) {
    currentDocument?.presentCompareWith()
  }
  @objc private func nextChange(_ sender: Any?) {
    currentDocument?.comparisonSession?.selectNextChange()
  }
  @objc private func previousChange(_ sender: Any?) {
    currentDocument?.comparisonSession?.selectPreviousChange()
  }
  /// P28-005/P28-022: prompt for a password with a secure field and an
  /// explicit Keychain-retention checkbox (default off). The password is used
  /// only for the unlock call and, when requested, handed to the keychain.
  @objc private func unlockDocument(_ sender: Any?) {
    guard let viewer = currentDocument?.viewer, viewer.isLocked else { return }
    let alert = NSAlert()
    alert.messageText = "Unlock Document"
    alert.informativeText =
      "This document is password-protected. Enter its password to view and edit it."
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.placeholderString = "Password"
    let remember = NSButton(
      checkboxWithTitle: "Remember this password in the Keychain", target: nil, action: nil)
    remember.state = .off
    let stack = NSStackView(views: [field, remember])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
    alert.accessoryView = stack
    alert.addButton(withTitle: "Unlock")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let password = field.stringValue
    field.stringValue = ""
    guard !password.isEmpty else { return }
    guard viewer.unlock(password: password) else {
      let failure = NSAlert()
      failure.messageText = "Incorrect Password"
      failure.informativeText = "The password did not unlock this document."
      failure.addButton(withTitle: "OK")
      failure.runModal()
      return
    }
    // P28-022: retention is an explicit per-document preference; unchecking
    // removes any previously stored credential.
    if let url = currentDocument?.fileURL {
      if remember.state == .on {
        _ = KeychainCredentialStore.save(password: password, forDocumentAt: url)
      } else {
        KeychainCredentialStore.remove(forDocumentAt: url)
      }
    }
    currentDocument?.unlockCoreSession(with: password)
  }

  /// P28-023: return the document to its protected read-only state.
  @objc private func lockDocument(_ sender: Any?) {
    currentDocument?.lockDocument()
  }
  @objc private func checkForUpdates(_ sender: Any?) { AppUpdater.shared.checkForUpdates() }

  /// P41-009: native update settings window (preferences, current
  /// version, last-check state, manual check action).
  @objc private func showUpdateSettings(_ sender: Any?) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Update Settings"
    window.contentView = NSHostingView(rootView: UpdateSettingsView())
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(checkForUpdates(_:)) {
      return AppUpdater.shared.canCheckForUpdates
    }
    if menuItem.action == #selector(showUpdateSettings) {
      return true
    }
    guard let document = currentDocument else { return false }
    switch menuItem.action {
    case #selector(showFind):
      guard let viewer = document.viewer else { return false }
      return !viewer.isLocked && viewer.pageCount > 0
    case #selector(findNext), #selector(findPrevious):
      return (document.viewer?.searchMatchCount ?? 0) > 0
    case #selector(showPagesSidebar), #selector(showCommentsSidebar):
      return document.viewer != nil
    case #selector(NSText.copy(_:)):
      // P28-021: respect the copying permission of protected documents.
      guard let viewer = document.viewer, !viewer.isLocked else { return false }
      return viewer.view.document?.allowsCopying ?? true
    case #selector(showFormsSidebar):
      return document.viewer != nil && !document.editSession.formFields().isEmpty
    case #selector(showSignaturesSidebar):
      return document.viewer != nil && document.hasSignatures
    case #selector(showStructureSidebar):
      return document.viewer != nil && document.structureModel.isTagged
    case #selector(showInspectorSidebar), #selector(showInfoSidebar):
      return document.viewer != nil
    case #selector(showFontsSidebar):
      return document.viewer != nil && document.hasFonts
    case #selector(highlightSelection), #selector(underlineSelection),
      #selector(strikeoutSelection), #selector(noteSelection):
      return document.canAnnotateSelection
    case #selector(toggleInkTool):
      guard let viewer = document.viewer else { return false }
      menuItem.state = viewer.isInkToolActive ? .on : .off
      return !viewer.isLocked && viewer.pageCount > 0
    case #selector(selectTool), #selector(textEditTool), #selector(pageTool):
      guard let viewer = document.viewer else { return false }
      let tool: ViewerToolMode =
        menuItem.action == #selector(textEditTool) ? .textEdit
        : menuItem.action == #selector(pageTool) ? .page : .select
      menuItem.state = viewer.activeTool == tool ? .on : .off
      return !viewer.isLocked && viewer.pageCount > 0
    case #selector(flattenAnnotations):
      return document.canFlattenAnnotations
    case #selector(flattenForm):
      return document.canFlattenForm
    case #selector(runOCR):
      return document.canRunOCR
    case #selector(runOCRAllPages):
      return document.canRunOCRAllPages
    case #selector(exportText):
      return document.canExportText
    case #selector(exportPageImages):
      return document.canExportPageImages
    case #selector(exportHTML):
      return document.canExportHTML
    case #selector(exportOutline):
      return document.canExportOutline
    case #selector(exportAttachments):
      return document.canExportAttachments
    case #selector(printDocument), #selector(exportPrintPDF):
      return document.canPrint
    case #selector(exportImages):
      return document.canExportImages
    case #selector(addTextField), #selector(addCheckbox), #selector(addRadioGroup),
      #selector(addChoiceField), #selector(addPushButton), #selector(addSignatureField):
      return document.canAuthorForm
    case #selector(renameFormField), #selector(deleteFormField),
      #selector(editFormFieldProperties), #selector(recalculateForm),
      #selector(duplicateFormField):
      return document.canAuthorForm && document.hasFormFields
    case #selector(alignFormFields):
      return document.canAuthorForm && document.formFieldNames().count >= 2
    case #selector(distributeFormFields), #selector(editFormTabOrder):
      return document.canAuthorForm && document.formFieldNames().count >= 3
    case #selector(exportFormValues), #selector(importFormValues):
      return !document.editSession.formFields().isEmpty
    case #selector(exportReviewSummary):
      return document.canExportReviewSummary
    case #selector(editSelectedText):
      return document.selectedTextTarget() != nil
    case #selector(reflowParagraph):
      return document.canAuthorForm
    case #selector(redactSelection):
      return document.canRedactSelection
    case #selector(importPages):
      return document.editSession.canEdit
    case #selector(copyAsRichText):
      return document.viewer?.view.currentSelection != nil
    case #selector(saveSanitizedCopy):
      return document.editSession.canEdit
    case #selector(exportEncryptedCopy):
      return document.editSession.canEdit
    case #selector(signDocument):
      return document.canSignDocument
    case #selector(optimizeDocument):
      return document.canOptimizeDocument
    case #selector(compareWithDocument):
      return document.canCompareDocuments
    case #selector(nextChange), #selector(previousChange):
      return document.comparisonSession?.changes.isEmpty == false
    case #selector(unlockDocument):
      return document.viewer?.isLocked == true
    case #selector(lockDocument):
      return document.canLockDocument
    case #selector(undoEdit): return document.editSession.canUndo
    case #selector(redoEdit): return document.editSession.canRedo
    case #selector(rotateLeft), #selector(rotateRight), #selector(insertBlankPage):
      return document.editSession.canEdit && (document.viewer?.pageCount ?? 0) > 0
    case #selector(movePageUp):
      return document.editSession.canEdit && (document.viewer?.pageNumber ?? 1) > 1
    case #selector(movePageDown):
      guard let viewer = document.viewer else { return false }
      return document.editSession.canEdit && viewer.pageNumber < viewer.pageCount
    case #selector(deletePage):
      return document.editSession.canEdit && (document.viewer?.pageCount ?? 0) > 1
    case #selector(previousPage), #selector(firstPage):
      return document.viewer?.canGoBack ?? false
    case #selector(nextPage), #selector(lastPage):
      return document.viewer?.canGoForward ?? false
    case #selector(goBack):
      return document.viewer?.canGoBackInHistory ?? false
    case #selector(goForward):
      return document.viewer?.canGoForwardInHistory ?? false
    case #selector(fitWidth):
      return (document.viewer?.pageCount ?? 0) > 0
    case #selector(toggleRulers):
      guard let viewer = document.viewer else { return false }
      menuItem.state = viewer.areRulersVisible ? .on : .off
      return viewer.pageCount > 0
    case #selector(toggleGuides):
      guard let viewer = document.viewer else { return false }
      menuItem.state = viewer.areGuidesVisible ? .on : .off
      return viewer.pageCount > 0
    default:
      guard let viewer = document.viewer else { return false }
      return !viewer.isLocked && viewer.pageCount > 0
    }
  }

  private func showWelcome() {
    if welcome == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "sPDF Editor"
      window.contentView = NSHostingView(rootView: WelcomeView())
      // P12-019: the welcome window keeps its placement across launches.
      window.setFrameAutosaveName("spdf-welcome")
      window.center()
      welcome = NSWindowController(window: window)
    }
    welcome?.showWindow(nil)
    // P02-028: startup measurement probe (ships in all configurations like
    // the smoke entry point, but prints one line and exits instead of
    // logging). Methodology: launch the app binary directly with this flag;
    // the printed timestamp minus the launcher's pre-launch timestamp is the
    // launch-to-first-window time (excluding LaunchServices overhead).
    if CommandLine.arguments.contains("--measure-startup") {
      print(String(format: "%.3f", Date().timeIntervalSince1970))
      fflush(stdout)
      exit(0)
    }
  }

  private func installMenus() {
    let bar = NSMenu()
    NSApp.mainMenu = bar
    let app = submenu("sPDF Editor", in: bar)
    add("About sPDF Editor", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), to: app)
    add("Check for Updates…", #selector(checkForUpdates(_:)), target: self, to: app)
    add("Update Settings…", #selector(showUpdateSettings), key: ",", modifiers: [.command, .option], target: self, to: app)
    app.addItem(.separator())
    add("Hide sPDF Editor", #selector(NSApplication.hide(_:)), key: "h", to: app)
    add(
      "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
      modifiers: [.command, .option], to: app)
    add("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: app)
    app.addItem(.separator())
    add("Quit sPDF Editor", #selector(NSApplication.terminate(_:)), key: "q", to: app)

    let file = submenu("File", in: bar)
    add(
      "Open…", #selector(NSDocumentController.openDocument(_:)), key: "o", target: documents,
      to: file)
    add("Unlock Document…", #selector(unlockDocument), target: self, to: file)
    add("Lock Document", #selector(lockDocument), target: self, to: file)
    file.addItem(.separator())
    add("Close", #selector(NSWindow.performClose(_:)), key: "w", to: file)
    add("Save", #selector(NSDocument.save(_:)), key: "s", to: file)
    add(
      "Save As…", #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift],
      to: file)
    add(
      "Duplicate", #selector(NSDocument.duplicate(_:)), key: "d",
      modifiers: [.command, .shift], to: file)
    file.addItem(.separator())
    add(
      "Export Text…", #selector(exportText), key: "t", modifiers: [.command, .option],
      target: self, to: file)
    add("Export Page Images…", #selector(exportPageImages), target: self, to: file)
    add("Export HTML…", #selector(exportHTML), target: self, to: file)
    add("Export DOCX…", #selector(exportDOCX), target: self, to: file)
    add("Preview DOCX Reconstruction…", #selector(previewDOCX), target: self, to: file)
    add("Review Tables…", #selector(reviewTables), target: self, to: file)
    add("Export Tables…", #selector(exportTables), target: self, to: file)
    add("Compatibility Report…", #selector(showCompatibilityReport), target: self, to: file)
    add("Create Archival Copy…", #selector(createArchivalCopy), target: self, to: file)
    add("Convert Colors…", #selector(convertColors), target: self, to: file)
    add("Place Graphical Signature…", #selector(placeGraphicalSignature), target: self, to: file)
    add("Organize Pages…", #selector(organizePages), target: self, to: file)
    add("Repair Document…", #selector(repairDocument), target: self, to: file)
    add("Export Outline…", #selector(exportOutline), target: self, to: file)
    add("Export Attachments…", #selector(exportAttachments), target: self, to: file)
    add("Export Images…", #selector(exportImages), target: self, to: file)
    file.addItem(.separator())
    add("Print…", #selector(printDocument), key: "p", target: self, to: file)
    add("Export Print PDF…", #selector(exportPrintPDF), target: self, to: file)
    add(
      "Export Review Summary…", #selector(exportReviewSummary), key: "e",
      modifiers: [.command, .shift], target: self, to: file)
    add("Export Form Values…", #selector(exportFormValues), target: self, to: file)
    add("Import Form Values…", #selector(importFormValues), target: self, to: file)
    add("Import Pages…", #selector(importPages), target: self, to: file)
    file.addItem(.separator())
    add("Save Sanitized Copy…", #selector(saveSanitizedCopy), target: self, to: file)
    add("Export Encrypted Copy…", #selector(exportEncryptedCopy), target: self, to: file)
    add("Sign Document…", #selector(signDocument), target: self, to: file)
    add("Optimize Document…", #selector(optimizeDocument), target: self, to: file)
    add("Compare With…", #selector(compareWithDocument), target: self, to: file)

    let edit = submenu("Edit", in: bar)
    add("Undo Edit", #selector(undoEdit), key: "z", target: self, to: edit)
    add(
      "Redo Edit", #selector(redoEdit), key: "z", modifiers: [.command, .shift], target: self,
      to: edit)
    edit.addItem(.separator())
    add("Copy", #selector(NSText.copy(_:)), key: "c", to: edit)
    add("Copy as Rich Text", #selector(copyAsRichText), target: self, to: edit)
    add("Select All", #selector(NSText.selectAll(_:)), key: "a", to: edit)
    edit.addItem(.separator())
    add("Find…", #selector(showFind), key: "f", target: self, to: edit)
    add("Find Next", #selector(findNext), key: "g", target: self, to: edit)
    add(
      "Find Previous", #selector(findPrevious), key: "g", modifiers: [.command, .shift],
      target: self, to: edit)
    edit.addItem(.separator())
    add(
      "Edit Text…", #selector(editSelectedText), key: "t", modifiers: [.command, .shift],
      target: self, to: edit)
    add(
      "Reflow Paragraph…", #selector(reflowParagraph), key: "t",
      modifiers: [.command, .option], target: self, to: edit)
    edit.addItem(.separator())
    add(
      "Redact Selection…", #selector(redactSelection), key: "r",
      modifiers: [.command, .option], target: self, to: edit)

    let view = submenu("View", in: bar)
    add("Previous Page", #selector(previousPage), key: "[", target: self, to: view)
    add("Next Page", #selector(nextPage), key: "]", target: self, to: view)
    add("Go Back", #selector(goBack), key: "[", modifiers: [.command, .option], target: self, to: view)
    add(
      "Go Forward", #selector(goForward), key: "]", modifiers: [.command, .option], target: self,
      to: view)
    add(
      "First Page", #selector(firstPage), key: "[", modifiers: [.command, .shift], target: self,
      to: view)
    add(
      "Last Page", #selector(lastPage), key: "]", modifiers: [.command, .shift], target: self,
      to: view)
    view.addItem(.separator())
    add("Zoom In", #selector(zoomIn), key: "=", target: self, to: view)
    add("Zoom Out", #selector(zoomOut), key: "-", target: self, to: view)
    add("Fit Page", #selector(fitPage), key: "0", target: self, to: view)
    add("Fit Width", #selector(fitWidth), key: "0", modifiers: [.command, .shift], target: self, to: view)
    add("Show Rulers", #selector(toggleRulers), key: "r", target: self, to: view)
    add("Show Guides", #selector(toggleGuides), target: self, to: view)
    add("Actual Size", #selector(actualSize), key: "1", target: self, to: view)
    view.addItem(.separator())
    add(
      "Show Page Thumbnails", #selector(showPagesSidebar), key: "1",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Comments", #selector(showCommentsSidebar), key: "2",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Form Fields", #selector(showFormsSidebar), key: "3",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Signatures", #selector(showSignaturesSidebar), key: "4",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Structure", #selector(showStructureSidebar), key: "5",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Fonts", #selector(showFontsSidebar), key: "6",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Inspector", #selector(showInspectorSidebar), key: "7",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Show Document Info", #selector(showInfoSidebar), key: "8",
      modifiers: [.command, .option], target: self, to: view)
    view.addItem(.separator())
    add(
      "Previous Change", #selector(previousChange), key: "\u{F702}",
      modifiers: [.command, .option], target: self, to: view)
    add(
      "Next Change", #selector(nextChange), key: "\u{F703}",
      modifiers: [.command, .option], target: self, to: view)

    let page = submenu("Page", in: bar)
    add(
      "Rotate Left", #selector(rotateLeft), key: "l", modifiers: [.command, .shift], target: self,
      to: page)
    add(
      "Rotate Right", #selector(rotateRight), key: "r", modifiers: [.command, .shift], target: self,
      to: page)
    page.addItem(.separator())
    add("Move Page Up", #selector(movePageUp), target: self, to: page)
    add("Move Page Down", #selector(movePageDown), target: self, to: page)
    add("Insert Blank Page After", #selector(insertBlankPage), target: self, to: page)
    page.addItem(.separator())
    add("Delete Page…", #selector(deletePage), target: self, to: page)

    let form = submenu("Form", in: bar)
    add("Add Text Field…", #selector(addTextField), target: self, to: form)
    add("Add Checkbox…", #selector(addCheckbox), target: self, to: form)
    add("Add Radio Group…", #selector(addRadioGroup), target: self, to: form)
    add("Add Choice Field…", #selector(addChoiceField), target: self, to: form)
    add("Add Push Button…", #selector(addPushButton), target: self, to: form)
    add("Add Signature Field…", #selector(addSignatureField), target: self, to: form)
    form.addItem(.separator())
    add("Rename Field…", #selector(renameFormField), target: self, to: form)
    add("Delete Field…", #selector(deleteFormField), target: self, to: form)
    form.addItem(.separator())
    add("Field Properties…", #selector(editFormFieldProperties), target: self, to: form)
    add("Recalculate Form", #selector(recalculateForm), target: self, to: form)
    form.addItem(.separator())
    add("Duplicate Field…", #selector(duplicateFormField), target: self, to: form)
    add("Align Fields…", #selector(alignFormFields), target: self, to: form)
    add("Distribute Fields…", #selector(distributeFormFields), target: self, to: form)
    add("Field Tab Order…", #selector(editFormTabOrder), target: self, to: form)

    let annotate = submenu("Annotate", in: bar)
    add(
      "Highlight Selection", #selector(highlightSelection), key: "h",
      modifiers: [.command, .shift], target: self, to: annotate)
    add(
      "Underline Selection", #selector(underlineSelection), key: "u",
      modifiers: [.command, .shift], target: self, to: annotate)
    add(
      "Strikeout Selection", #selector(strikeoutSelection), key: "k",
      modifiers: [.command, .shift], target: self, to: annotate)
    annotate.addItem(.separator())
    add(
      "Add Note to Selection", #selector(noteSelection), key: "n",
      modifiers: [.command, .shift], target: self, to: annotate)
    annotate.addItem(.separator())
    add(
      "Select Tool", #selector(selectTool), key: "1", modifiers: [.command, .control],
      target: self, to: annotate)
    add(
      "Text Edit Tool", #selector(textEditTool), key: "2", modifiers: [.command, .control],
      target: self, to: annotate)
    add(
      "Page Tool", #selector(pageTool), key: "3", modifiers: [.command, .control],
      target: self, to: annotate)
    add(
      "Ink Tool", #selector(toggleInkTool), key: "i", modifiers: [.command, .shift], target: self,
      to: annotate)
    annotate.addItem(.separator())
    add("Flatten Annotations…", #selector(flattenAnnotations), target: self, to: annotate)
    add("Flatten Form…", #selector(flattenForm), target: self, to: annotate)
    annotate.addItem(.separator())
    add("Recognize Text (OCR)…", #selector(runOCR), target: self, to: annotate)
    add("Recognize Text in All Pages…", #selector(runOCRAllPages), target: self, to: annotate)

    let window = submenu("Window", in: bar)
    NSApp.windowsMenu = window
    add("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", to: window)
    add("Zoom", #selector(NSWindow.performZoom(_:)), to: window)
    window.addItem(.separator())
    add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), to: window)
    let help = submenu("Help", in: bar)
    NSApp.helpMenu = help
    let item = NSMenuItem(title: "sPDF Editor 0.1 — PDF viewing", action: nil, keyEquivalent: "")
    help.addItem(item)
  }

  private func submenu(_ title: String, in bar: NSMenu) -> NSMenu {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    item.submenu = menu
    bar.addItem(item)
    return menu
  }

  private func add(
    _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, to menu: NSMenu
  ) {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = target
    menu.addItem(item)
  }
}

private struct WelcomeView: View {
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "doc.richtext").font(.system(size: 60)).foregroundStyle(.blue)
      Text("sPDF Editor").font(.largeTitle.weight(.semibold))
      Text("Open a PDF to get started.").foregroundStyle(.secondary)
      Button("Open PDF…") { NSDocumentController.shared.openDocument(nil) }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut("o")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
