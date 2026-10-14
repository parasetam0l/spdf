#if DEBUG
  import AppKit
  import DocumentSession
  import Foundation
  import MacServices
  import PDFCore
  import Sparkle

  @MainActor
  enum RelaunchSmoke {
    static func run(phase: String, fixtures: URL, output: URL) async {
      let watchdog = DiagnosticWatchdog.schedule(after: 60,
        message: "sPDF Editor relaunch diagnostic timed out")
      defer { watchdog.cancel() }
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("State")
        if phase == "capture" { try await capture(fixtures: fixtures, output: output) }
        else if phase == "restore" { try await restore(output: output) }
        else { throw error("Unknown diagnostic phase") }
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("[relaunch] FAIL: \(error)\n".utf8))
        exit(1)
      }
    }

    private static func capture(fixtures: URL, output: URL) async throws {
      let controller = NSDocumentController.shared
      func open(_ name: String) async throws -> SPDFDocument {
        let (document, _) = try await controller.openDocument(
          withContentsOf: output.appendingPathComponent(name), display: true)
        return try requireDocument(document)
      }
      for (fixture, name) in [("one-page.pdf", "first.pdf"), ("three-pages.pdf", "second.pdf")] {
        try Data(contentsOf: fixtures.appendingPathComponent(fixture))
          .write(to: output.appendingPathComponent(name), options: .atomic)
      }
      let parsed = try PDFParser.parse(Data(contentsOf: fixtures.appendingPathComponent("three-pages.pdf")))
      try PDFWriter.write(parsed.graph,
        encryption: PDFEncryptionOptions(userPassword: "relaunch-test-password", ownerPassword: "relaunch-test-password"))
        .write(to: output.appendingPathComponent("protected.pdf"), options: .atomic)
      let first = try await open("first.pdf")
      let second = try await open("second.pdf")
      let protected = try await open("protected.pdf")
      _ = protected.viewer?.unlock(password: "relaunch-test-password")
      protected.unlockCoreSession(with: "relaunch-test-password")
      protected.viewer?.go(to: 3)
      protected.viewer?.view.autoScales = false
      protected.viewer?.view.scaleFactor = 0.75
      try require(protected.editSession.isProtected, "Protected fixture was not protected")
      second.viewer?.setContinuous(false)
      second.viewer?.go(to: 2)
      second.viewer?.sidebarMode = .comments
      second.viewer?.isSidebarVisible = false
      second.viewer?.view.autoScales = false
      second.viewer?.view.scaleFactor = 1.25
      second.windowControllers.first?.window?.setFrame(NSRect(x: 140, y: 160, width: 850, height: 650), display: true)
      (NSApp.delegate as? ApplicationDelegate)?.restoreUpdateSettings(frame: [120, 120, 480, 420])
      second.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
      try await waitUntil { second.viewer?.pageNumber == 2 }
      try await Task.sleep(for: .milliseconds(100))
      let store = SPDFDocument.makeUpdateRelaunchStore()
      try UpdateRelaunchCoordinator.capture([first, second, protected])
      try require(!FileManager.default.fileExists(atPath: store.pendingURL.path),
        "Ordinary quitting staged an update request")
      let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
      AppUpdater.shared.updaterWillRelaunchApplication(updater.updater)
      let allowed = await withCheckedContinuation { continuation in
        TerminationCoordinator.shared.requestTermination { continuation.resume(returning: $0) }
      }
      try require(allowed && controller.documents.isEmpty, "Approved update shutdown did not close documents")
      let data = try Data(contentsOf: store.pendingURL)
      let state = try JSONDecoder().decode(UpdateRelaunchState.self, from: data)
      try require(state.documents.count == 3 && state.updateSettingsFrame != nil,
        "Update shutdown lost view identities or Settings")
      try require(!String(decoding: data, as: UTF8.self).contains("relaunch-test-password"),
        "A password entered relaunch metadata")
      try require(protected.recoveryStore.pendingKeys().isEmpty,
        "Protected fixture wrote recovery bytes")
      FileHandle.standardError.write(Data("[relaunch] capture PASS: 3 documents and Settings\n".utf8))
    }

    private static func restore(output: URL) async throws {
      let controller = NSDocumentController.shared
      try require(controller.documents.isEmpty, "Restore process already had documents")
      let count = try await UpdateRelaunchCoordinator.restore()
      try require(count == 3 && controller.documents.count == 3, "Relaunch lost or duplicated documents")
      let documents = controller.documents.compactMap { $0 as? SPDFDocument }
      let second = try requireDocument(documents.first { $0.fileURL?.lastPathComponent == "renamed.pdf" })
      let protected = try requireDocument(documents.first { $0.fileURL?.lastPathComponent == "protected.pdf" })
      try await waitUntil { second.viewer?.pageNumber == 2 }
      try require(second.viewer?.sidebarMode == .comments && second.viewer?.isSidebarVisible == false,
        "Sidebar state did not survive relaunch")
      try require(second.viewer?.view.displayMode == .singlePage,
        "Page layout did not survive relaunch")
      try require(abs((second.viewer?.scale ?? 0) - 1.25) < 0.05,
        "Zoom did not survive relaunch")
      try require(protected.viewer?.isLocked == true && !protected.editSession.canEdit,
        "Protected document reopened without its access decision")
      _ = protected.viewer?.unlock(password: "relaunch-test-password")
      protected.unlockCoreSession(with: "relaunch-test-password")
      try await waitUntil { protected.viewer?.pageNumber == 3 }
      try require(abs((protected.viewer?.scale ?? 0) - 0.75) < 0.05,
        "Protected navigation/zoom did not resume after explicit unlock")
      let store = SPDFDocument.makeUpdateRelaunchStore()
      let state = try JSONDecoder().decode(UpdateRelaunchState.self, from: Data(contentsOf: store.backupURL))
      let frame = (NSApp.delegate as? ApplicationDelegate)?.updateSettingsFrame
      try require(frame == state.updateSettingsFrame, "Settings window frame did not survive relaunch")
      let secondEntry = try requireEntry(state.documents.first { entry in
        var entry = entry
        return (try? entry.resolve().lastPathComponent) == "renamed.pdf"
      })
      try require(second.captureViewState()?.windowFrame == secondEntry.view.windowFrame,
        "Document frame did not survive relaunch")
      try require(try await UpdateRelaunchCoordinator.restore() == 0 && controller.documents.count == 3,
        "Consumed state replayed twice")
      try require(protected.recoveryStore.pendingKeys().isEmpty, "Relaunch wrote protected recovery")
      let report: [String: Any] = [
        "passed": true, "documents": count, "date": ISO8601DateFormatter().string(from: Date()),
        "scope": "Separate-process native relaunch restoration; no update payload installed",
        "cases": ["file bookmark follows rename", "page/zoom/sidebar/layout/frame", "Settings frame",
          "protected document reopens locked and resumes its view after unlock", "no protected recovery or password metadata",
          "one-use restoration and compatible backup"],
      ]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("relaunch-test.json"), options: .atomic)
      for document in documents { document.close() }
      FileHandle.standardError.write(Data("[relaunch] restore PASS: 6 cases in a new process\n".utf8))
    }

    private static func waitUntil(_ ready: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while !ready() {
        if ContinuousClock.now > deadline { throw error("View state did not settle") }
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    private static func require(_ value: Bool, _ message: String) throws {
      if !value { throw error(message) }
    }
    private static func requireDocument(_ document: NSDocument?) throws -> SPDFDocument {
      guard let document = document as? SPDFDocument else { throw error("Expected document is missing") }
      return document
    }
    private static func requireEntry(_ entry: RelaunchDocument?) throws -> RelaunchDocument {
      guard let entry else { throw error("Expected bookmark is missing") }
      return entry
    }
    private static func error(_ message: String) -> NSError {
      NSError(domain: "SPDFRelaunchTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
#endif
