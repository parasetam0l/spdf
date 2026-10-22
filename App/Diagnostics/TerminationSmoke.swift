#if DEBUG
  import AppKit
  import CoreGraphics
  import DocumentSession
  import Foundation
  import ImageIO
  import MacServices
  import PDFCore
  import PDFEditing
  import PDFKit
  import Sparkle

  /// Drives real NSDocument save/close callbacks and real background workers.
  /// Every input/output belongs to the explicit diagnostic directory.
  @MainActor
  enum TerminationSmoke {
    static func prepareInteractive(fixtures: URL, output: URL) async {
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
        let controller = NSDocumentController.shared
        let document: SPDFDocument
        if CommandLine.arguments.contains("--untitled") {
          document = try controller.makeUntitledDocument(ofType: "com.adobe.pdf") as! SPDFDocument
          try document.loadRecovered(Data(contentsOf: fixtures.appendingPathComponent("one-page.pdf")))
          controller.addDocument(document)
          document.showWindows()
        } else {
          let url = output.appendingPathComponent("forms.pdf")
          if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent("form-pages.pdf"), to: url)
          }
          let (opened, _) = try await controller.openDocument(withContentsOf: url, display: true)
          document = opened as! SPDFDocument
          document.viewer?.showForms()
        }
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("[termination-ui] disposable document ready\n".utf8))
      } catch {
        FileHandle.standardError.write(Data("[termination-ui] \(error)\n".utf8))
        exit(1)
      }
    }

    static func run(fixtures: URL, output: URL) async {
      let watchdog = DiagnosticWatchdog.schedule(
        after: 120, message: "sPDF Editor termination test timed out after 120 seconds")
      defer { watchdog.cancel() }
      var accepted: [String] = []
      func record(_ name: String) {
        accepted.append(name)
        FileHandle.standardError.write(Data("[termination] \(name)\n".utf8))
      }
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
        let controller = NSDocumentController.shared
        try require(NSApp is DocumentApplication, "The custom application termination path is missing")
        let controllerReview = NativeControllerReviewProbe()

        func open(_ fixture: String, as name: String) async throws -> SPDFDocument {
          let url = output.appendingPathComponent(name)
          if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
          try FileManager.default.copyItem(at: fixtures.appendingPathComponent(fixture), to: url)
          let (document, _) = try await controller.openDocument(withContentsOf: url, display: true)
          guard let document = document as? SPDFDocument else { throw failure("Wrong document type") }
          return document
        }

        // Approving an earlier document must not close it if a later prompt
        // is canceled. Include two windows owned by that earlier document.
        let first = try await open("one-page.pdf", as: "first.pdf")
        let second = try await open("three-pages.pdf", as: "second.pdf")
        first.rotateCurrentPage(byDegrees: 90)
        second.rotateCurrentPage(byDegrees: 90)
        let extra = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        extra.title = "Second Window for First Document"
        first.addWindowController(NSWindowController(window: extra))
        extra.orderFront(nil)
        let firstGraph = first.editSession.currentGraph
        let secondGraph = second.editSession.currentGraph
        let firstOriginal = try Data(contentsOf: output.appendingPathComponent("first.pdf"))
        UpdateRelaunchCoordinator.arm()
        let canceled = await drive([.button("Don't Save"), .button("Cancel")]) {
          await controllerReview.request(reviewUnsaved: false)
        }
        FileHandle.standardError.write(Data("[termination] cancel: allowed=\(canceled), documents=\(controller.documents.map(\.displayName))\n".utf8))
        try require(!canceled && controller.documents.count == 2, "Cancel closed a reviewed document")
        try require(first.windowControllers.count == 2 && first.editSession.canUndo,
          "Cancel lost a window or Undo")
        try require(first.editSession.currentGraph == firstGraph && second.editSession.currentGraph == secondGraph,
          "Cancel changed a dirty graph")
        try require(try Data(contentsOf: output.appendingPathComponent("first.pdf")) == firstOriginal,
          "Cancel wrote the first destination")
        try require(controllerReview.receivedController && controllerReview.receivedContext,
          "Document-controller callback lost its receiver or context")
        try require(!FileManager.default.fileExists(atPath: SPDFDocument.makeUpdateRelaunchStore().pendingURL.path),
          "Canceled document-controller review staged a relaunch")
        record("document-controller close cancellation preserves both dirty graphs, windows and Undo")

        let saved = await drive([.button("Save"), .button("Save")]) {
          await controllerReview.request(reviewUnsaved: true)
        }
        try require(saved && controller.documents.isEmpty, "Saving multiple documents did not complete")
        try require(try rotation(output.appendingPathComponent("first.pdf")) == 90,
          "Independent reopen lost the first edit")
        let relaunch = try SPDFDocument.makeUpdateRelaunchStore().take(
          bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.parasetam0l.spdf")
        try require(relaunch?.documents.count == 2,
          "Document-controller review closed windows before relaunch capture")
        try require(controllerReview.receivedController && controllerReview.receivedContext
          && controllerReview.callbackCount == 2,
          "Document-controller decisions were not delivered exactly once with their context")
        record("document-controller review saves verified writes and captures two identities before closing")

        let recovered = try controller.makeUntitledDocument(ofType: "com.adobe.pdf") as! SPDFDocument
        try recovered.loadRecovered(Data(contentsOf: fixtures.appendingPathComponent("one-page.pdf")))
        controller.addDocument(recovered)
        recovered.showWindows()
        try await waitUntil { recovered.viewer?.pageNumber == 1 }
        recovered.rotateCurrentPage(byDegrees: 90)
        FileHandle.standardError.write(Data("[termination] recovered native state: type=\(recovered.fileType ?? "nil"), viewing=\(recovered.isInViewingMode), draft=\(recovered.isDraft), grouping=\(recovered.undoManager?.groupingLevel ?? -1)\n".utf8))
        try require(recovered.editSession.canUndo, "Recovered fixture edit did not start")
        let recoveredGraph = recovered.editSession.currentGraph
        let canceledSaveAs = await drive([.cancelSaveAs]) { await request() }
        FileHandle.standardError.write(Data("[termination] Save As cancel: allowed=\(canceledSaveAs), dirty=\(recovered.isDocumentEdited), undo=\(recovered.editSession.canUndo), graphEqual=\(recovered.editSession.currentGraph == recoveredGraph), revision=\(recovered.editSession.documentRevision)\n".utf8))
        try require(!canceledSaveAs && recovered.editSession.currentGraph == recoveredGraph
          && recovered.isDocumentEdited && recovered.editSession.canUndo,
          "Canceled Save As lost recovered work")
        record("canceled Save As preserves recovered document and Undo")
        let recoveredURL = output.appendingPathComponent("recovered-saved.pdf")
        // The system's remote Save button is covered by the interactive
        // diagnostic. Use NSDocument's real Save As operation for repeatable
        // automation; the canceled panel above still tests the native UI.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          recovered.save(to: recoveredURL, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
          }
        }
        let savedAs = await request()
        try require(savedAs && controller.documents.isEmpty && (try rotation(recoveredURL)) == 90,
          "Save As retry did not independently reopen")
        record("Save As retry writes and independently reopens")

        let failedOriginal = try Data(contentsOf: fixtures.appendingPathComponent("one-page.pdf"))
        let blocked = output.appendingPathComponent("Blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let blockedURL = blocked.appendingPathComponent("failed-write.pdf")
        try failedOriginal.write(to: blockedURL)
        let (failedOpened, _) = try await controller.openDocument(withContentsOf: blockedURL, display: true)
        let failed = failedOpened as! SPDFDocument
        failed.rotateCurrentPage(byDegrees: 90)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        let refused = await drive([.button("Save"), .button("OK")]) { await request() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        try require(!refused && failed.isDocumentEdited && failed.editSession.canUndo,
          "A failed write permitted termination")
        try require(try Data(contentsOf: blockedURL) == failedOriginal, "A failed write damaged the old file")
        failed.close()
        record("failed native save blocks termination and preserves old bytes and dirty work")

        let conflict = try await open("one-page.pdf", as: "external-change.pdf")
        conflict.rotateCurrentPage(byDegrees: 90)
        let conflictURL = output.appendingPathComponent("external-change.pdf")
        let external = try Data(contentsOf: fixtures.appendingPathComponent("three-pages.pdf"))
        try external.write(to: conflictURL, options: .atomic)
        let canceledConflict = await drive([.button("Save"), .button("Cancel")]) { await request() }
        try require(!canceledConflict && conflict.isDocumentEdited,
          "External-change cancellation permitted termination")
        try require(try Data(contentsOf: conflictURL) == external, "Conflict replaced external bytes")
        conflict.close()
        record("external-change cancellation preserves disk bytes and pending edits")

        let form = try await open("form-pages.pdf", as: "pending-form.pdf")
        form.stageFormTextDraft(fieldName: "name", text: "Pending termination value")
        try require(form.isDocumentEdited && form.workspaceDocumentState.hasChanges,
          "An unsubmitted form draft did not mark the document dirty")
        let formSaved = await drive([.button("Save")]) { await request() }
        let formParsed = try PDFParser.parse(Data(contentsOf: output.appendingPathComponent("pending-form.pdf")))
        let reopenedFields = try FormInventory.fields(in: formParsed.graph, pageIDs: formParsed.pageIDs)
        try require(formSaved && reopenedFields.first(where: { $0.name == "name" })?.stringValue
          == "Pending termination value", "Quit ignored an unsubmitted form draft")
        record("unsubmitted form draft participates in native save decision")

        let closing = try await open("one-page.pdf", as: "window-close.pdf")
        let closeProbe = NativeCloseProbe()
        let context = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        context.initialize(to: 41)
        defer { context.deinitialize(count: 1); context.deallocate() }
        closing.windowControllers.first?.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        closing.viewer?.hasPendingGraphicGesture = { true }
        let vetoed = await drive([.button("Keep Working")]) {
          await closeProbe.request(closing, context: context)
        }
        FileHandle.standardError.write(Data("[termination] window veto: allowed=\(vetoed), context=\(closeProbe.receivedContext), document=\(closeProbe.receivedDocument)\n".utf8))
        try require(!vetoed && closeProbe.receivedContext && closeProbe.receivedDocument,
          "Window close did not deliver its native veto/context")
        closing.viewer?.hasPendingGraphicGesture = nil
        let permitted = await closeProbe.request(closing, context: context)
        try require(permitted && closeProbe.receivedContext && closeProbe.receivedDocument,
          "Window close did not deliver its reviewed permission")
        closing.close()
        record("window close preserves veto and native callback document/context")

        let atomic = try await open("three-pages.pdf", as: "atomic-save.pdf")
        atomic.rotateCurrentPage(byDegrees: 90)
        var sawActiveSave = false
        let atomicURL = output.appendingPathComponent("atomic-save.pdf")
        let atomicAllowed = await withCheckedContinuation { continuation in
          atomic.save(to: atomicURL, ofType: "com.adobe.pdf", for: .saveOperation) { error in
            guard error == nil else { continuation.resume(returning: false); return }
            sawActiveSave = atomic.jobCenter.jobs.contains { $0.title == "Saving document" }
            TerminationCoordinator.shared.requestTermination { continuation.resume(returning: $0) }
          }
        }
        try require(atomicAllowed && sawActiveSave && atomic.jobCenter.jobs.isEmpty
          && (try rotation(atomicURL)) == 90, "Termination raced a native atomic save completion")
        record("termination at save completion waits for verified atomic output and accounting")

        let protectedURL = output.appendingPathComponent("protected-ocr.pdf")
        let scan = try PDFParser.parse(Data(contentsOf: fixtures.appendingPathComponent("image-pages.pdf")))
        try PDFWriter.write(scan.graph,
          encryption: PDFEncryptionOptions(userPassword: "abc", ownerPassword: "abc"))
          .write(to: protectedURL, options: .atomic)
        let (protectedOpened, _) = try await controller.openDocument(withContentsOf: protectedURL, display: true)
        let protected = protectedOpened as! SPDFDocument
        _ = protected.viewer?.unlock(password: "abc")
        protected.unlockCoreSession(with: "abc")
        let protectedRecognizer = HeldRecognizer()
        protectedRecognizer.release()
        try await protected.performOCR(pageIndexes: [0], recognizer: protectedRecognizer)
        try require(protected.editSession.isProtected
          && !protected.recoveryStore.pendingKeys().contains(protected.recoveryKey),
          "OCR weakened protection or wrote a plaintext recovery snapshot")
        let protectedOutput = try protected.data(ofType: "com.adobe.pdf")
        let protectedReader = PDFDocument(data: protectedOutput)
        try require(protectedReader?.isLocked == true && protectedReader?.unlock(withPassword: "abc") == true
          && protectedReader?.string?.contains("Native lifecycle OCR") == true,
          "Protected OCR did not preserve encrypted output and readable text")
        protected.close()
        record("protected OCR uses memory snapshot and preserves encrypted output/recovery policy")

        // Hold one real rasterized recognition request in a noninterruptible
        // recognizer seam, so cancellation acknowledgement can be observed.
        let ocr = try await open("image-pages.pdf", as: "ocr-wait.pdf")
        let recognizer = HeldRecognizer()
        let ocrTask = Task { try await ocr.performOCR(pageIndexes: [0], recognizer: recognizer) }
        try await waitUntil { recognizer.hasStarted }
        var observedWait = false
        let waited = await drive([.button("Wait for Work"), .button("Save")], whileWaiting: {
          observedWait = !ocr.jobCenter.jobs.isEmpty && controller.documents.contains { $0 === ocr }
          recognizer.release()
        }) { await request() }
        _ = try await ocrTask.value
        try require(waited && observedWait, "Quit did not wait for the actual OCR producer")
        let ocrReopened = PDFDocument(url: output.appendingPathComponent("ocr-wait.pdf"))
        try require(ocrReopened?.string?.contains("Native lifecycle OCR") == true, "Saved OCR text is missing")
        record("wait choice holds termination until OCR commits and verified save reopens")

        let canceledOCR = try await open("image-pages.pdf", as: "ocr-cancel.pdf")
        let canceledOriginal = try canceledOCR.data(ofType: "com.adobe.pdf")
        let held = HeldRecognizer()
        let canceledTask = Task { try await canceledOCR.performOCR(pageIndexes: [0], recognizer: held) }
        try await waitUntil { held.hasStarted }
        var heldAfterCancel = false
        let acknowledged = await drive([.button("Cancel Jobs and Wait")], whileWaiting: {
          heldAfterCancel = !canceledOCR.jobCenter.jobs.isEmpty
            && controller.documents.contains { $0 === canceledOCR }
          held.release()
        }) { await request() }
        if case .success = await canceledTask.result { throw failure("Canceled OCR committed a result") }
        try require(acknowledged && heldAfterCancel && canceledOCR.jobCenter.jobs.isEmpty,
          "Cancel was treated as completion before the producer acknowledged")
        try require(try Data(contentsOf: output.appendingPathComponent("ocr-cancel.pdf")) == canceledOriginal,
          "Canceled OCR changed source bytes")
        record("job cancellation waits for acknowledgement and leaves source unchanged")

        let kept = try await open("image-pages.pdf", as: "ocr-keep-working.pdf")
        let keepRecognizer = HeldRecognizer()
        let keepTask = Task { try await kept.performOCR(pageIndexes: [0], recognizer: keepRecognizer) }
        try await waitUntil { keepRecognizer.hasStarted }
        let keepDecision = await drive([.button("Keep Working")]) { await request() }
        try require(!keepDecision && !kept.jobCenter.jobs.isEmpty && !kept.windowControllers.isEmpty,
          "Keep Working stopped work or closed the document")
        keepRecognizer.release()
        _ = try await keepTask.value
        kept.close()
        record("Keep Working cancels termination without canceling the producer")

        let stale = try await open("image-pages.pdf", as: "ocr-stale.pdf")
        let staleRecognizer = HeldRecognizer()
        let staleTask = Task { try await stale.performOCR(pageIndexes: [0], recognizer: staleRecognizer) }
        try await waitUntil { staleRecognizer.hasStarted }
        stale.rotateCurrentPage(byDegrees: 90)
        let editedGraph = stale.editSession.currentGraph
        staleRecognizer.release()
        if case .success = await staleTask.result { throw failure("Stale OCR was applied after another edit") }
        try require(stale.editSession.currentGraph == editedGraph && stale.editSession.canUndo,
          "Rejected OCR changed current work")
        stale.close()
        record("OCR rejects stale results after a concurrent document edit")

        let exporting = try await open("three-pages.pdf", as: "export-source.pdf")
        let exportGraph = exporting.editSession.currentGraph
        let exportTask = Task {
          try await exporting.exportPageImages(to: output.appendingPathComponent("PageImages"),
            baseName: "partial", options: PageImageExportOptions(dpi: 300))
        }
        try await waitUntil { !exporting.jobCenter.jobs.isEmpty || exportTask.isCancelled }
        let exportedSafely = await drive([.button("Cancel Jobs and Wait")]) { await request() }
        _ = await exportTask.result
        try require(exportedSafely && exporting.jobCenter.jobs.isEmpty && exporting.editSession.currentGraph == exportGraph,
          "Export was not drained safely")
        let files = (try? FileManager.default.contentsOfDirectory(
          at: output.appendingPathComponent("PageImages"), includingPropertiesForKeys: nil)) ?? []
        for file in files {
          try require(CGImageSourceCreateWithURL(file as CFURL, nil).map { CGImageSourceGetCount($0) } == 1,
            "Partial export contains an invalid image")
        }
        record("page export cancellation drains actual worker and keeps valid completed files")

        let docx = try await open("three-pages.pdf", as: "docx-source.pdf")
        let docxTask = Task { try await docx.exportDOCX(to: output.appendingPathComponent("tracked.docx")) }
        try await waitUntil { !docx.jobCenter.jobs.isEmpty }
        let docxActive = !docx.jobCenter.jobs.isEmpty
        _ = try await docxTask.value
        try require(docxActive && docx.jobCenter.jobs.isEmpty, "DOCX producer was not tracked to completion")
        docx.close()
        record("DOCX reconstruction and atomic write remain tracked until completion")

        let deferred = try await open("image-pages.pdf", as: "deferred-update.pdf")
        let deferredRecognizer = HeldRecognizer()
        let deferredTask = Task { try await deferred.performOCR(pageIndexes: [0], recognizer: deferredRecognizer) }
        try await waitUntil { deferredRecognizer.hasStarted }
        let updater = AppUpdater.shared
        let sparkle = SPUStandardUpdaterController(
          startingUpdater: false, updaterDelegate: updater, userDriverDelegate: nil)
        var installations = 0
        let postponed = await drive([.button("Keep Working")]) {
          let result = updater.updater(sparkle.updater,
            shouldPostponeRelaunchForUpdate: SUAppcastItem.empty(), untilInvokingBlock: { installations += 1 })
          try? await waitUntil { !TerminationCoordinator.shared.isPreparing }
          return result
        }
        try require(postponed && updater.isInstallDeferred && installations == 0,
          "Sparkle's callback installed despite Keep Working")
        _ = await drive([.button("Wait for Work")], whileWaiting: { deferredRecognizer.release() }) {
          updater.checkForUpdates()
          try? await waitUntil { installations == 1 }
          return true
        }
        _ = try await deferredTask.value
        try require(installations == 1 && !updater.isInstallDeferred && deferred.jobCenter.jobs.isEmpty,
          "Deferred Sparkle install did not resume exactly once after the actual worker")
        deferred.close()
        record("real Sparkle delegate callback defers/retries handler until actual job completion")

        let report: [String: Any] = [
          "passed": true, "cases": accepted, "date": ISO8601DateFormatter().string(from: Date()),
          "scope": "Native document callbacks and actual jobs; no update payload or public release installed",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("termination-test.json"), options: .atomic)
        FileHandle.standardError.write(Data("[termination] PASS: \(accepted.count) native cases\n".utf8))
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("[termination] FAIL: \(error)\n".utf8))
        exit(1)
      }
    }

    private static func request() async -> Bool {
      await withCheckedContinuation { continuation in
        TerminationCoordinator.shared.requestTermination { continuation.resume(returning: $0) }
      }
    }

    private static func drive(
      _ actions: [PromptDriver.Action], whileWaiting: (() -> Void)? = nil,
      operation: () async -> Bool
    ) async -> Bool {
      let driver = PromptDriver(actions: actions, whileWaiting: whileWaiting)
      driver.start()
      defer { driver.stop() }
      return await operation()
    }

    private static func waitUntil(_ ready: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(15)
      while !ready() {
        if ContinuousClock.now > deadline { throw failure("Worker did not reach the expected state") }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    private static func rotation(_ url: URL) throws -> Int {
      let parsed = try PDFParser.parse(Data(contentsOf: url))
      guard case .dictionary(let page)? = parsed.graph.objects[parsed.pageIDs[0]],
        case .integer(let angle)? = page[PDFName("Rotate")]
      else { return 0 }
      return Int(angle)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw failure(message) }
    }
    private static func failure(_ message: String) -> Error { PDFError(.malformed, message) }
  }

  private final class HeldRecognizer: TextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    func release() { semaphore.signal() }
    func recognize(image: CGImage, languages: [String], level: OCRRecognitionLevel) throws -> [OCRObservation] {
      lock.withLock { started = true }
      semaphore.wait()
      return [OCRObservation(text: "Native lifecycle OCR", confidence: 1,
        boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.025))]
    }
  }

  @MainActor
  private final class NativeControllerReviewProbe: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var expectedContext: UnsafeMutableRawPointer?
    private(set) var receivedController = false
    private(set) var receivedContext = false
    private(set) var callbackCount = 0

    func request(reviewUnsaved: Bool) async -> Bool {
      let context = UnsafeMutablePointer<Int>.allocate(capacity: 1)
      context.initialize(to: 42)
      defer { context.deinitialize(count: 1); context.deallocate() }
      expectedContext = UnsafeMutableRawPointer(context)
      let allowed = await withCheckedContinuation { continuation in
        self.continuation = continuation
        let controller = NSDocumentController.shared
        if reviewUnsaved {
          controller.reviewUnsavedDocuments(withAlertTitle: nil, cancellable: true, delegate: self,
            didReviewAllSelector: #selector(documentController(_:didReview:contextInfo:)),
            contextInfo: expectedContext)
        } else {
          controller.closeAllDocuments(withDelegate: self,
            didCloseAllSelector: #selector(documentController(_:didReview:contextInfo:)),
            contextInfo: expectedContext)
        }
      }
      withExtendedLifetime(self) {}
      return allowed
    }

    @objc private func documentController(
      _ controller: NSDocumentController, didReview: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
      receivedController = controller === NSDocumentController.shared
      receivedContext = contextInfo == expectedContext
      callbackCount += 1
      let pending = continuation
      continuation = nil
      pending?.resume(returning: didReview)
    }
  }

  @MainActor
  private final class NativeCloseProbe: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    private weak var expectedDocument: SPDFDocument?
    private var expectedContext: UnsafeMutableRawPointer?
    private(set) var receivedDocument = false
    private(set) var receivedContext = false
    func request(_ document: SPDFDocument, context: UnsafeMutablePointer<Int>) async -> Bool {
      expectedDocument = document
      expectedContext = UnsafeMutableRawPointer(context)
      let allowed = await withCheckedContinuation { continuation in
        self.continuation = continuation
        document.canClose(withDelegate: self,
          shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: expectedContext)
      }
      withExtendedLifetime(self) {}
      return allowed
    }
    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
      receivedDocument = document === expectedDocument
      receivedContext = contextInfo == expectedContext
      let pending = continuation
      continuation = nil
      pending?.resume(returning: shouldClose)
    }
  }

  @MainActor
  private final class PromptDriver: NSObject {
    enum Action {
      case button(String)
      case saveAs(URL)
      case cancelSaveAs
    }
    private var actions: [Action]
    private var timer: Timer?
    private weak var savePanel: NSSavePanel?
    private var whileWaiting: (() -> Void)?
    private var nextActionAt = ContinuousClock.now
    private var savePanelReadyAt = ContinuousClock.now

    init(actions: [Action], whileWaiting: (() -> Void)?) {
      self.actions = actions
      self.whileWaiting = whileWaiting
      super.init()
    }

    func start() {
      SPDFDocument.diagnosticSavePanelObserver = { [weak self] panel in
        self?.savePanel = panel
        self?.savePanelReadyAt = .now + .milliseconds(800)
        FileHandle.standardError.write(Data("[termination] preparing native Save As panel\n".utf8))
        if case .saveAs(let url) = self?.actions.first {
          panel.directoryURL = url.deletingLastPathComponent()
          panel.nameFieldStringValue = url.lastPathComponent
        }
      }
      let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(tick(_:)),
        userInfo: nil, repeats: true)
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
      RunLoop.main.add(timer, forMode: .modalPanel)
    }

    func stop() { timer?.invalidate(); SPDFDocument.diagnosticSavePanelObserver = nil }

    @objc private func tick(_ timer: Timer) {
      if NSApp.windows.contains(where: { $0.isVisible && $0.title == "Finishing Work" }),
        let callback = whileWaiting
      {
        whileWaiting = nil
        callback()
      }
      guard ContinuousClock.now >= nextActionAt else { return }
      guard let action = actions.first else { return }
      let windows: [NSWindow]
      let title: String
      switch action {
      case .button(let requested):
        windows = NSApp.windows.filter(\.isVisible)
        title = requested
      case .saveAs:
        guard let savePanel, savePanel.isVisible, ContinuousClock.now >= savePanelReadyAt else { return }
        actions.removeFirst()
        nextActionAt = .now + .milliseconds(400)
        FileHandle.standardError.write(Data("[termination] native Save As OK\n".utf8))
        savePanel.ok(nil)
        return
      case .cancelSaveAs:
        guard let savePanel, savePanel.isVisible else { return }
        actions.removeFirst()
        nextActionAt = .now + .milliseconds(400)
        FileHandle.standardError.write(Data("[termination] native Save As Cancel\n".utf8))
        savePanel.cancel(nil)
        return
      }
      for window in windows {
        guard let content = window.contentView else { continue }
        let controls = buttons(in: content)
        // AppKit can add its own external-change warning before the app's
        // save override. Both variants must be handled on the owned fixtures.
        if (title == "OK" || title == "Cancel"),
          labels(in: content).contains(where: { $0.contains("another application") }),
          !controls.contains(where: { normalize($0.title) == normalize(title) }),
          let warningButton = controls.first(where: {
            normalize($0.title) == normalize(title == "OK" ? "Save" : "Don't Save")
          })
        {
          if title == "Cancel" { actions.removeFirst() }
          nextActionAt = .now + .milliseconds(400)
          warningButton.performClick(nil)
          return
        }
        if let button = controls.first(where: {
          !$0.isHidden && $0.isEnabled && normalize($0.title) == normalize(title)
        }) {
          actions.removeFirst()
          nextActionAt = .now + .milliseconds(400)
          FileHandle.standardError.write(Data("[termination] native button: \(button.title)\n".utf8))
          button.performClick(nil)
          return
        }
      }
    }

    private func normalize(_ title: String) -> String {
      title.replacingOccurrences(of: "’", with: "'").lowercased()
    }
    private func buttons(in view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    private func labels(in view: NSView) -> [String] {
      (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
    }
  }
#endif
