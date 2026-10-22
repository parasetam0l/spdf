#if SPDF_UPDATER_ACCEPTANCE
  import AppKit
  import DocumentSession
  import Foundation
  import MacServices
  import PDFCore

  /// An opt-in private acceptance build. Its separate bundle ID, defaults
  /// and state directory leave the production installation untouched.
  @MainActor
  enum ActualUpdaterProbe {
    private static var root: URL {
      Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    static func didLaunch() async throws {
      guard Bundle.main.bundleIdentifier == "com.parasetam0l.spdf.updater-acceptance" else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      if build == "100" {
        let fixtures = root.appendingPathComponent("Fixtures")
        let files = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        for (fixture, name) in [("form-pages.pdf", "forms.pdf"), ("three-pages.pdf", "pages.pdf")] {
          try Data(contentsOf: fixtures.appendingPathComponent(fixture))
            .write(to: files.appendingPathComponent(name), options: .atomic)
        }
        let parsed = try PDFParser.parse(Data(contentsOf: fixtures.appendingPathComponent("one-page.pdf")))
        try PDFWriter.write(parsed.graph,
          encryption: PDFEncryptionOptions(userPassword: "private-update-test", ownerPassword: "private-update-test"))
          .write(to: files.appendingPathComponent("protected.pdf"), options: .atomic)
        var documents: [SPDFDocument] = []
        for name in ["forms.pdf", "pages.pdf", "protected.pdf"] {
          let (document, _) = try await NSDocumentController.shared.openDocument(
            withContentsOf: files.appendingPathComponent(name), display: true)
          guard let document = document as? SPDFDocument else { throw CocoaError(.fileReadCorruptFile) }
          documents.append(document)
        }
        documents[0].stageFormTextDraft(
          fieldName: "name", text: "Actual authenticated update")
        let pages = documents[1]
        pages.viewer?.setContinuous(false)
        pages.viewer?.go(to: 2)
        pages.viewer?.sidebarMode = .comments
        pages.viewer?.isSidebarVisible = false
        pages.viewer?.view.autoScales = false
        pages.viewer?.view.scaleFactor = 1.25
        pages.windowControllers.first?.window?.setFrame(NSRect(x: 140, y: 160, width: 850, height: 650), display: true)
        _ = documents[2].viewer?.unlock(password: "private-update-test")
        documents[2].unlockCoreSession(with: "private-update-test")
        (NSApp.delegate as? ApplicationDelegate)?.restoreUpdateSettings(frame: [120, 120, 480, 420])
        pages.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        try Data("ready\n".utf8).write(to: root.appendingPathComponent("ready.txt"), options: .atomic)
      } else if build == "101" {
        let deadline = ContinuousClock.now + .seconds(10)
        while NSDocumentController.shared.documents.count < 3 {
          if ContinuousClock.now > deadline { throw CocoaError(.fileReadCorruptFile) }
          try await Task.sleep(for: .milliseconds(50))
        }
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? SPDFDocument }
        guard let pages = documents.first(where: { $0.fileURL?.lastPathComponent == "renamed.pdf" }),
          let form = documents.first(where: { $0.fileURL?.lastPathComponent == "forms.pdf" }),
          let protected = documents.first(where: { $0.fileURL?.lastPathComponent == "protected.pdf" })
        else { throw CocoaError(.fileReadCorruptFile) }
        while pages.viewer?.pageNumber != 2 {
          if ContinuousClock.now > deadline { throw CocoaError(.fileReadCorruptFile) }
          try await Task.sleep(for: .milliseconds(50))
        }
        guard documents.count == 3,
          pages.viewer?.sidebarMode == .comments, pages.viewer?.isSidebarVisible == false,
          pages.viewer?.view.displayMode == .singlePage,
          abs((pages.viewer?.scale ?? 0) - 1.25) < 0.05,
          protected.viewer?.isLocked == true, !protected.editSession.canEdit,
          form.editSession.formFields().first(where: { $0.name == "name" })?.stringValue == "Actual authenticated update",
          (NSApp.delegate as? ApplicationDelegate)?.updateSettingsFrame != nil,
          protected.recoveryStore.pendingKeys().isEmpty
        else { throw CocoaError(.fileReadCorruptFile) }
        let backup = try Data(contentsOf: SPDFDocument.makeUpdateRelaunchStore().backupURL)
        let state = try JSONDecoder().decode(UpdateRelaunchState.self, from: backup)
        guard state.sourceBuild == "100" else { throw CocoaError(.fileReadCorruptFile) }
        let record: [String: Any] = ["passed": true, "oldBuild": "100", "newBuild": "101",
          "documents": documents.count, "date": ISO8601DateFormatter().string(from: Date()),
          "scope": "Actual Sparkle installation and relaunch on isolated Developer ID acceptance builds; local signed feed"]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
          .write(to: root.appendingPathComponent("actual-update.json"), options: .atomic)
      }
      NSApp.activate(ignoringOtherApps: true)
    }

    static func didCapture() throws {
      let files = root.appendingPathComponent("Documents")
      let original = files.appendingPathComponent("pages.pdf")
      if FileManager.default.fileExists(atPath: original.path) {
        let renamed = files.appendingPathComponent("renamed.pdf")
        if FileManager.default.fileExists(atPath: renamed.path) { try FileManager.default.removeItem(at: renamed) }
        try FileManager.default.moveItem(at: original, to: renamed)
      }
    }
  }
#endif
