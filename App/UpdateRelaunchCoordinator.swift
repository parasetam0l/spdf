import AppKit
import DocumentSession

/// Records approved file identities before the quit gate closes windows,
/// and restores view metadata once in the newly launched process.
@MainActor
enum UpdateRelaunchCoordinator {
  private(set) static var isArmed = false

  static func arm() { isArmed = true }
  static func disarm() { isArmed = false }

  static func capture(_ documents: [SPDFDocument]) throws {
    guard isArmed else { return }
    let entries = try documents.compactMap { document -> RelaunchDocument? in
      // An untitled document explicitly discarded in the native save decision
      // has no saved identity to reopen. Save As has already set fileURL here.
      guard let url = document.fileURL, let view = document.captureViewState() else { return nil }
      return try RelaunchDocument(url: url, view: view,
        wasKeyWindow: document.windowControllers.contains { $0.window?.isKeyWindow == true })
    }
    let delegate = NSApp.delegate as? ApplicationDelegate
    let state = UpdateRelaunchState(
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.parasetam0l.spdf",
      sourceBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
      documents: entries, updateSettingsFrame: delegate?.updateSettingsFrame)
    try SPDFDocument.makeUpdateRelaunchStore().stage(state)
    #if SPDF_UPDATER_ACCEPTANCE
      try ActualUpdaterProbe.didCapture()
    #endif
    isArmed = false
  }

  /// A regular launch has no pending record. Native document-controller
  /// deduplication also covers simultaneous Finder/restoration open requests.
  @discardableResult
  static func restore() async throws -> Int {
    let store = SPDFDocument.makeUpdateRelaunchStore()
    guard var state = try store.take(
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.parasetam0l.spdf")
    else { return 0 }
    var opened = 0
    var keyWindow: NSWindow?
    var failures = 0
    for index in state.documents.indices {
      do {
        let url = try state.documents[index].resolve()
        let accessing = url.startAccessingSecurityScopedResource()
        do {
          let (openedDocument, _) = try await NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true)
          guard let document = openedDocument as? SPDFDocument else {
            throw CocoaError(.fileReadCorruptFile)
          }
          document.adoptRestoredFileAccess(url, accessing: accessing)
          document.applyViewState(state.documents[index].view)
          if state.documents[index].wasKeyWindow { keyWindow = document.windowControllers.first?.window }
          opened += 1
        } catch {
          if accessing { url.stopAccessingSecurityScopedResource() }
          throw error
        }
      } catch { failures += 1 }
    }
    try store.saveBackup(state)
    if let frame = state.updateSettingsFrame {
      (NSApp.delegate as? ApplicationDelegate)?.restoreUpdateSettings(frame: frame)
    }
    keyWindow?.makeKeyAndOrderFront(nil)
    if failures > 0 {
      let alert = NSAlert()
      alert.messageText = "Some documents could not be reopened"
      alert.informativeText = "Use File → Open to locate the documents or grant access again. "
        + "Their files have not been changed."
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
    return opened
  }
}
