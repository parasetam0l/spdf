import AppKit
import Combine
import MacServices

/// The same gate protects Quit, system termination requests and Sparkle's
/// installer. A cancel never closes a previously reviewed document.
@MainActor
final class TerminationCoordinator: NSObject {
  static let shared = TerminationCoordinator()
  private var preparation: Task<Bool, Never>?
  private var drain: JobDrain?
  private var waitingWindow: NSWindow?

  var isPreparing: Bool { preparation != nil }
  var hasActiveWork: Bool {
    documents.contains { !$0.jobCenter.jobs.isEmpty }
  }
  private var documents: [SPDFDocument] {
    NSDocumentController.shared.documents.compactMap { $0 as? SPDFDocument }
  }

  /// Coalesces repeated termination requests instead of opening duplicate
  /// save panels. Only the final, synchronous check permits closing windows.
  func requestTermination(_ completion: @escaping (Bool) -> Void) {
    guard preparation == nil else { completion(false); return }
    preparation = Task { @MainActor in
      let allowed = await reviewDocuments()
      preparation = nil
      completion(allowed)
      return allowed
    }
  }

  /// Sparkle can postpone before sending its system termination request.
  /// Document save prompts remain in the AppKit gate, including paths where
  /// Sparkle does not invoke this optional callback.
  func postponeUpdate(_ completion: @escaping (Bool) -> Void) {
    guard preparation == nil else { completion(false); return }
    preparation = Task { @MainActor in
      let allowed = await settleWork()
      preparation = nil
      completion(allowed)
      return allowed
    }
  }

  func prepareToClose(_ document: SPDFDocument, completion: @escaping (Bool) -> Void) {
    guard preparation == nil else { completion(false); return }
    preparation = Task { @MainActor in
      var allowed = false
      while !Task.isCancelled {
        guard await settleWork([document]), document.finishPendingEdits() else { break }
        let revision = document.editSession.documentRevision
        let reviewer = DocumentCloseReview()
        guard await reviewer.review(document), document.finishPendingEdits() else { break }
        if document.jobCenter.jobs.isEmpty && document.editSession.documentRevision == revision {
          allowed = true
          break
        }
      }
      preparation = nil
      completion(allowed)
      return allowed
    }
  }

  @objc private func keepWorking(_ sender: Any?) { preparation?.cancel() }

  private func settleWork(_ scope: [SPDFDocument]? = nil) async -> Bool {
    let active = (scope ?? documents).filter { !$0.jobCenter.jobs.isEmpty }
    guard !active.isEmpty else { return !Task.isCancelled }
    let alert = NSAlert()
    alert.messageText = "Work is still in progress"
    alert.informativeText =
      "Wait for OCR, exports and saves to finish, or cancel background jobs before quitting. "
      + "Saves finish their verified atomic write. Completed export files stay in the chosen folder."
    alert.addButton(withTitle: "Wait for Work")
    alert.addButton(withTitle: "Cancel Jobs and Wait")
    alert.addButton(withTitle: "Keep Working")
    switch alert.runModal() {
    case .alertFirstButtonReturn: break
    case .alertSecondButtonReturn:
      for document in active {
        for job in document.jobCenter.jobs { document.jobCenter.requestCancel(id: job.id) }
      }
    default: return false
    }
    showWaitingWindow()
    defer { waitingWindow?.close(); waitingWindow = nil; drain = nil }
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          let waiter = JobDrain(documents: active, continuation: continuation)
          drain = waiter
          waiter.start()
        }
      } onCancel: {
        Task { @MainActor [weak self] in self?.drain?.cancel() }
      }
      return !Task.isCancelled
    } catch { return false }
  }

  private func showWaitingWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 145),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Finishing Work"
    window.isReleasedWhenClosed = false
    let label = NSTextField(wrappingLabelWithString:
      "Waiting for background jobs and verified saves to finish. You can keep working and try again later.")
    label.frame = NSRect(x: 24, y: 70, width: 392, height: 50)
    let progress = NSProgressIndicator(frame: NSRect(x: 24, y: 35, width: 24, height: 24))
    progress.style = .spinning
    progress.startAnimation(nil)
    let button = NSButton(title: "Keep Working", target: self, action: #selector(keepWorking))
    button.frame = NSRect(x: 282, y: 25, width: 134, height: 32)
    window.contentView?.addSubview(label)
    window.contentView?.addSubview(progress)
    window.contentView?.addSubview(button)
    window.center()
    window.makeKeyAndOrderFront(nil)
    waitingWindow = window
  }

  private func reviewDocuments() async -> Bool {
    var reviewed: [ObjectIdentifier: UInt64] = [:]
    while !Task.isCancelled {
      guard await settleWork() else { return false }
      let current = documents
      for document in current {
        guard document.finishPendingEdits() else { return false }
        let revision = document.editSession.documentRevision
        let id = ObjectIdentifier(document)
        if reviewed[id] == revision { continue }
        let reviewer = DocumentCloseReview()
        guard await reviewer.review(document) else { return false }
        reviewed[id] = revision
      }
      // A save sheet lets other windows receive events. Recheck the entire
      // live set, revisions and jobs before permitting termination; no await
      // or user event can occur between this check and closing the documents.
      guard !Task.isCancelled else { return false }
      let latest = documents
      for document in latest {
        guard document.finishPendingEdits() else { return false }
      }
      if latest.allSatisfy({
        $0.jobCenter.jobs.isEmpty
          && reviewed[ObjectIdentifier($0)] == $0.editSession.documentRevision
      }) {
        for document in latest { document.close() }
        return true
      }
    }
    return false
  }
}

/// Retained across AppKit's asynchronous Save/Save As/error panels.
@MainActor
private final class DocumentCloseReview: NSObject {
  private var continuation: CheckedContinuation<Bool, Never>?

  func review(_ document: SPDFDocument) async -> Bool {
    let allowed = await withCheckedContinuation { continuation in
      self.continuation = continuation
      document.reviewClose(
        withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)),
        contextInfo: nil)
    }
    withExtendedLifetime(self) {}
    return allowed
  }

  @objc private func document(
    _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    let pending = continuation
    continuation = nil
    pending?.resume(returning: shouldClose)
  }
}

/// Cancellation is only acknowledged when producers call finish. Combine
/// notifications are delivered back to MainActor before inspecting the set.
@MainActor
private final class JobDrain {
  private let documents: [SPDFDocument]
  private var continuation: CheckedContinuation<Void, Error>?
  private var observations: [AnyCancellable] = []

  init(documents: [SPDFDocument], continuation: CheckedContinuation<Void, Error>) {
    self.documents = documents
    self.continuation = continuation
  }

  func start() {
    for document in documents {
      observations.append(document.jobCenter.$jobs.dropFirst().sink { [weak self] _ in
        Task { @MainActor in self?.check() }
      })
    }
    check()
  }

  private func check() {
    guard documents.allSatisfy({ $0.jobCenter.jobs.isEmpty }) else { return }
    finish(.success(()))
  }

  func cancel() { finish(.failure(CancellationError())) }

  private func finish(_ result: Result<Void, Error>) {
    let pending = continuation
    continuation = nil
    observations.removeAll()
    pending?.resume(with: result)
  }
}
