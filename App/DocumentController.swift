import AppKit
import PDFCore

/// AppKit can review and close documents for an Apple quit event before
/// invoking NSApplication.terminate. Use the same atomic review as menu Quit
/// so a later cancellation preserves earlier windows and updater capture
/// still sees every approved document before any window closes.
@MainActor
final class DocumentController: NSDocumentController {
  override func newDocument(_ sender: Any?) {
    do {
      guard let document = try makeUntitledDocument(ofType: "com.adobe.pdf") as? SPDFDocument
      else { throw CocoaError(.fileReadUnknown) }
      try document.read(
        from: BlankPDF.data(format: WorkspacePreferences.paper,
          landscape: WorkspacePreferences.landscape), ofType: "com.adobe.pdf")
      document.updateChangeCount(.changeDone)
      addDocument(document)
      document.makeWindowControllers()
      document.showWindows()
      document.viewer?.activateTool(.addText)
    } catch {
      presentError(error)
    }
  }

  override func reviewUnsavedDocuments(
    withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
    didReviewAllSelector selector: Selector?, contextInfo: UnsafeMutableRawPointer?
  ) {
    review(delegate: delegate, selector: selector, contextInfo: contextInfo)
  }

  override func closeAllDocuments(
    withDelegate delegate: Any?, didCloseAllSelector selector: Selector?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    review(delegate: delegate, selector: selector, contextInfo: contextInfo)
  }

  private func review(
    delegate: Any?, selector: Selector?, contextInfo: UnsafeMutableRawPointer?
  ) {
    TerminationCoordinator.shared.requestTermination { [self] allowed in
      guard let selector, let receiver = delegate as? NSObject,
        receiver.responds(to: selector), let implementation = receiver.method(for: selector)
      else { return }
      // Both documented controller callbacks include the controller, BOOL
      // decision and the caller's context. NSObject.perform cannot pass all three.
      typealias Reply = @convention(c) (
        AnyObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?
      ) -> Void
      unsafeBitCast(implementation, to: Reply.self)(receiver, selector, self, allowed, contextInfo)
    }
  }
}
