import AppKit

@main
enum SPDFApplication {
  @MainActor
  static func main() {
    let application = DocumentApplication.shared
    // Register the controller before the delegate asks for its shared instance.
    let documents = DocumentController()
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    withExtendedLifetime((documents, delegate)) { application.run() }
  }
}

/// NSApplication normally asks NSDocumentController to close documents before
/// calling applicationShouldTerminate. Run our gate first so pending input,
/// jobs and canceled later save panels cannot lose earlier document windows.
@objc(SPDFApplicationHost)
@MainActor
final class DocumentApplication: NSApplication {
  override func terminate(_ sender: Any?) {
    let gate = TerminationCoordinator.shared
    guard !gate.isPreparing else { return }
    gate.requestTermination { [weak self] allowed in
      guard allowed, let self else { return }
      finishTermination(sender)
    }
  }

  private func finishTermination(_ sender: Any?) { super.terminate(sender) }
}
