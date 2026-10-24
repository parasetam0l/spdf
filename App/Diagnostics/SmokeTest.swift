#if DEBUG
  import AppKit
  import Foundation
  import ImageIO
  import MacServices
  import PDFCore
  import PDFEditing
  import PDFKit
  import Security

  /// SAF-01: seeds metadata, a JavaScript action, and unreachable objects on
  /// the session graph so the native sanitized-copy route must remove them.
  private struct SeedHiddenDataForSanitizeCheck: PDFEditCommand {
    var name: String { "Seed Hidden Data" }
    func validate(in graph: PDFGraph) throws {}
    func apply(to graph: PDFGraph) throws -> PDFGraph {
      var graph = graph
      graph.trailer[PDFName("Info")] = .dictionary([
        PDFName("Title"): .string(Data("sanitize-seed-info".utf8))
      ])
      let xmp = Data("sanitize-seed-xmp".utf8)
      graph.objects[PDFObjectID(900)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("Metadata")),
            PDFName("Length"): .integer(Int64(xmp.count)),
          ],
          bytes: xmp))
      graph.objects[PDFObjectID(901)] = .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("sanitize-seed-script".utf8)),
      ])
      let orphan = Data("sanitize-seed-orphan".utf8)
      graph.objects[PDFObjectID(902)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Length"): .integer(Int64(orphan.count)),
          ],
          bytes: orphan))
      if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(var catalog)? = graph.objects[rootID]
      {
        catalog[PDFName("OpenAction")] = .reference(PDFObjectID(901))
        graph.objects[rootID] = .dictionary(catalog)
      }
      return graph
    }
  }

  @MainActor
  enum SmokeTest {
    static func run(fixtures: URL, output: URL) async {
      let watchdog = DiagnosticWatchdog.schedule(
        after: 90, message: "sPDF Editor smoke test timed out after 90 seconds")
      defer { watchdog.cancel() }
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Stale recovery/view-state from previous runs must not leak into this
        // run (a restored tiny window frame would invalidate layout checks).
        try? FileManager.default.removeItem(at: output.appendingPathComponent("Recovery"))
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent(
          "Recovery", isDirectory: true)
        SPDFDocument.fontsInstallDirectoryOverride = output.appendingPathComponent(
          "Fonts", isDirectory: true)
        let controller = NSDocumentController.shared
        let started = ContinuousClock.now
        func checkpoint(_ name: String) {
          FileHandle.standardError.write(Data("[smoke] \(name)\n".utf8))
        }
        checkpoint("opening fixtures")
        try await ImportedParagraphSmoke.checks(fixtures: fixtures, output: output.appendingPathComponent("ImportedParagraph"))
        let firstURL = fixtures.appendingPathComponent("three-pages.pdf")
        let secondURL = fixtures.appendingPathComponent("one-page.pdf")
        let thirdURL = fixtures.appendingPathComponent("image-pages.pdf")
        let formURL = fixtures.appendingPathComponent("form-pages.pdf")
        let encryptedURL = fixtures.appendingPathComponent("Encrypted/aes-256-r6.pdf")
        let signedURL = fixtures.appendingPathComponent("Signed/signed-one-page.pdf")
        let taggedURL = fixtures.appendingPathComponent("tagged-pages.pdf")
        let attachmentURL = fixtures.appendingPathComponent("attachment-pages.pdf")
        let (opened, _) = try await controller.openDocument(withContentsOf: firstURL, display: true)
        let (second, _) = try await controller.openDocument(
          withContentsOf: secondURL, display: true)
        let (thirdOpened, _) = try await controller.openDocument(
          withContentsOf: thirdURL, display: true)
        let (formOpened, _) = try await controller.openDocument(
          withContentsOf: formURL, display: true)
        let (encryptedOpened, _) = try await controller.openDocument(
          withContentsOf: encryptedURL, display: true)
        let (signedOpened, _) = try await controller.openDocument(
          withContentsOf: signedURL, display: true)
        let (taggedOpened, _) = try await controller.openDocument(
          withContentsOf: taggedURL, display: true)
        let (attachmentOpened, _) = try await controller.openDocument(
          withContentsOf: attachmentURL, display: true)
        let openingDuration = started.duration(to: .now)
        guard let first = opened as? SPDFDocument, let other = second as? SPDFDocument,
          let third = thirdOpened as? SPDFDocument,
          let formDocument = formOpened as? SPDFDocument,
          let encryptedDocument = encryptedOpened as? SPDFDocument,
          let signedDocument = signedOpened as? SPDFDocument,
          let taggedDocument = taggedOpened as? SPDFDocument,
          let viewer = first.viewer, let secondViewer = other.viewer,
          let imageViewer = third.viewer, let formViewer = formDocument.viewer,
          let encryptedViewer = encryptedDocument.viewer,
          let signedViewer = signedDocument.viewer, let taggedViewer = taggedDocument.viewer,
          viewer.pageCount == 3, secondViewer.pageCount == 1, imageViewer.pageCount == 2,
          formViewer.pageCount == 2,
          let window = first.windowControllers.first?.window, let content = window.contentView,
          let imageWindow = third.windowControllers.first?.window,
          let formWindow = formDocument.windowControllers.first?.window
        else { throw PDFError(.malformed, "Native document opening smoke test failed") }

        checkpoint("fixtures opened; checking sidebar inventories")
        // Fresh windows must populate their sidebar models before an edit.
        guard formDocument.formsModel.fields.count == 10,
          formDocument.formsModel.fields.contains(where: { $0.name == "name" }),
          formDocument.formsModel.fields.contains(where: { $0.name == "notes" }),
          formDocument.formsModel.orphanedWidgetCount == 1,
          first.fontsModel.entries.contains(where: {
            $0.font.familyName == "Helvetica" && $0.installed
          })
        else { throw PDFError(.malformed, "Fresh document sidebar inventories are missing") }

        // P30: the signed fixture is inventoried and validated offline with
        // separate cryptographic and trust statuses; the panel is available.
        guard signedDocument.signaturesModel.entries.count == 1,
          let signatureEntry = signedDocument.signaturesModel.entries.first,
          signatureEntry.signature.fieldName == "Signature1",
          signatureEntry.validation.crypto == .valid,
          signatureEntry.validation.trust == .unknown,
          !signatureEntry.validation.unsignedChanges,
          !signatureEntry.validation.revocationChecked
        else { throw PDFError(.malformed, "Signature validation smoke checks failed") }
        signedViewer.showSignatures()
        guard signedViewer.sidebarMode == .signatures,
          let signedWindow = signedDocument.windowControllers.first?.window,
          let signedContent = signedWindow.contentView
        else { throw PDFError(.malformed, "The signatures sidebar did not open") }
        signedContent.layoutSubtreeIfNeeded()
        signedContent.displayIfNeeded()
        if let signatureBitmap = signedContent.bitmapImageRepForCachingDisplay(
          in: signedContent.bounds)
        {
          signedContent.cacheDisplay(in: signedContent.bounds, to: signatureBitmap)
          if let png = signatureBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("signatures.png"), options: .atomic)
          }
        }

        // P33: the structure inspector resolves roles (including the role
        // map), reading order, alt text, and object links; the fixture is
        // PDF/UA-valid per the independent validator.
        guard taggedDocument.structureModel.isTagged,
          taggedDocument.structureModel.entries.map(\.element.role)
            == ["H1", "P", "Figure", "Link", "Form"],
          taggedDocument.structureModel.issues.isEmpty,
          taggedDocument.structureModel.language == "en-US"
        else { throw PDFError(.malformed, "The structure inspector did not resolve the tree") }
        // P33-008/P33-013: role and artifact edits through the document path.
        guard taggedDocument.setStructureRole(elementID: PDFObjectID(22), role: "Span"),
          taggedDocument.structureModel.entries.contains(where: {
            $0.element.objectID == PDFObjectID(22) && $0.element.role == "Span"
          }),
          taggedDocument.structureModel.issues.isEmpty,
          taggedDocument.markStructureArtifact(elementID: PDFObjectID(23)),
          taggedDocument.structureModel.entries.contains(where: {
            $0.element.objectID == PDFObjectID(23) && $0.element.role == "Artifact"
              && $0.element.alt == nil
          })
        else { throw PDFError(.malformed, "Structure edits did not apply through the document") }
        taggedViewer.showStructure()
        guard taggedViewer.sidebarMode == .structure,
          let taggedWindow = taggedDocument.windowControllers.first?.window,
          let taggedContent = taggedWindow.contentView
        else { throw PDFError(.malformed, "The structure sidebar did not open") }
        taggedContent.layoutSubtreeIfNeeded()
        taggedContent.displayIfNeeded()
        if let structureBitmap = taggedContent.bitmapImageRepForCachingDisplay(
          in: taggedContent.bounds)
        {
          taggedContent.cacheDisplay(in: taggedContent.bounds, to: structureBitmap)
          if let png = structureBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("structure.png"), options: .atomic)
          }
        }

        // P43-002/P43-004: the font inspector surfaces installed, embedded,
        // and missing fonts with concrete fallbacks and paid-font warnings.
        guard
          taggedDocument.fontsModel.entries.contains(where: {
            $0.font.familyName == "F1" && !$0.font.isEmbedded && $0.needsProvisioning
          }),
          taggedDocument.fontsModel.entries.contains(where: {
            $0.warning?.contains("neither embedded nor installed") == true
          }),
          first.fontsModel.entries.contains(where: {
            $0.font.familyName == "Helvetica" && $0.installed && !$0.needsProvisioning
          })
        else { throw PDFError(.malformed, "The font inspector did not resolve statuses") }
        taggedViewer.showFonts()
        taggedViewer.isSidebarVisible = true
        guard taggedViewer.sidebarMode == .fonts else {
          throw PDFError(.malformed, "The fonts sidebar did not open")
        }
        try await Task.sleep(for: .milliseconds(250))
        taggedContent.layoutSubtreeIfNeeded()
        taggedContent.displayIfNeeded()
        if let fontsBitmap = taggedContent.bitmapImageRepForCachingDisplay(in: taggedContent.bounds)
        {
          taggedContent.cacheDisplay(in: taggedContent.bounds, to: fontsBitmap)
          if let png = fontsBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("fonts.png"), options: .atomic)
          }
        }

        // P25-001/P25-007/P25-009/P25-021: form authoring and the field
        // properties path through the document.
        guard taggedDocument.addAuthoredTextField(name: "AuthoredNote"),
          taggedDocument.formFieldNames().contains("AuthoredNote"),
          taggedDocument.applyAuthoredFieldProperties(
            name: "AuthoredNote", required: true, fontSize: 14, maxLength: 20,
            format: .number(decimals: 1, prefix: nil, suffix: nil)),
          taggedDocument.formFieldProperties(for: "AuthoredNote")?.isRequired == true,
          taggedDocument.formFieldProperties(for: "AuthoredNote")?.maxLength == 20,
          taggedDocument.formFieldProperties(for: "AuthoredNote")?.fontSize == 14,
          taggedDocument.formFieldProperties(for: "AuthoredNote")?.format
            == .number(decimals: 1, prefix: nil, suffix: nil)
        else { throw PDFError(.malformed, "Field properties did not apply through the document") }
        taggedDocument.fillFormText(fieldName: "AuthoredNote", text: "42")
        guard
          taggedDocument.formsModel.fields.first(where: { $0.name == "AuthoredNote" })?
            .stringValue == "42.0",
          taggedDocument.renameAuthoredFormField(from: "AuthoredNote", to: "Notes.Body"),
          taggedDocument.formFieldNames().contains("Notes.Body"),
          // P25-010: duplication with an independent value.
          taggedDocument.duplicateAuthoredFormField(
            name: "Notes.Body", sharing: .independentCopy),
          taggedDocument.formFieldNames().contains("Notes.Body2")
        else { throw PDFError(.malformed, "Form authoring through the document failed") }
        // P25-018/P25-019: tab order and alignment. The tab order is the
        // widget annotation order on the page; only widgets present in
        // /Annots can participate.
        let tabOrder = Array(taggedDocument.formFieldNames().reversed())
        let widgetNames: [PDFObjectID: String] = Dictionary(
          uniqueKeysWithValues: taggedDocument.formsModel.fields.flatMap { field in
            field.widgets.compactMap { widget in widget.objectID.map { ($0, field.name) } }
          })
        func annotationOrder() -> [String] {
          guard let graph = taggedDocument.editSession.currentGraph,
            case .dictionary(let page)? = graph.objects[taggedDocument.editSession.pageIDs[0]],
            case .array(let annotations)? = page[PDFName("Annots")]
          else { return [] }
          return annotations.compactMap { value in
            if case .reference(let id) = value { return widgetNames[id] }
            return nil
          }
        }
        guard taggedDocument.reorderAuthoredFields(tabOrder) else {
          throw PDFError(.malformed, "Form tab order did not apply")
        }
        let reorderedAnnotations = annotationOrder()
        let expectedAnnotations = tabOrder.filter { reorderedAnnotations.contains($0) }
        guard reorderedAnnotations == expectedAnnotations,
          taggedDocument.alignAuthoredFields(Array(tabOrder.prefix(2)), edge: .left),
          Set(
            taggedDocument.formsModel.fields.prefix(2).compactMap { $0.widgets.first?.rect?[0] }
          ).count == 1,
          taggedDocument.deleteAuthoredFormField(name: "Notes.Body"),
          taggedDocument.deleteAuthoredFormField(name: "Notes.Body2"),
          !taggedDocument.formFieldNames().contains("Notes.Body")
        else { throw PDFError(.malformed, "Form organization through the document failed") }

        // P28-005/P28-015: a protected document stays locked; the owned core
        // reads the inventory and refuses wrong or missing passwords before
        // the viewer is unlocked with the correct one.
        guard encryptedViewer.isLocked else {
          throw PDFError(.malformed, "The encrypted document was not locked")
        }
        let encryptedData = try Data(contentsOf: encryptedURL)
        guard let encryptedInfo = try PDFParser.encryptionInventory(encryptedData),
          encryptedInfo.profile == .aes256, encryptedInfo.allowsPrinting
        else { throw PDFError(.malformed, "The encryption inventory was not readable") }
        guard (try? PDFParser.parse(encryptedData)) == nil else {
          throw PDFError(.malformed, "An encrypted core parse without a password succeeded")
        }
        do {
          _ = try PDFParser.parse(encryptedData, password: "wrong")
          throw PDFError(.malformed, "An encrypted core parse with a wrong password succeeded")
        } catch let error as PDFError where error.kind == .incorrectPassword {
        }
        guard try PDFParser.parse(encryptedData, password: "abc").pageCount == 1 else {
          throw PDFError(.malformed, "The encrypted core parse did not resolve pages")
        }
        guard encryptedViewer.unlock(password: "abc"), !encryptedViewer.isLocked,
          encryptedViewer.view.document?.string?.contains("Issue 6010") == true
        else { throw PDFError(.malformed, "Viewer unlock did not produce readable text") }

        // P28-020–P28-024: unlock the owned-core session, edit, save with the
        // same protection, and lock again.
        encryptedDocument.unlockCoreSession(with: "abc")
        guard encryptedDocument.editSession.isProtected,
          encryptedDocument.editSession.canEdit,
          encryptedDocument.editSession.protectionAllowsEditing
        else { throw PDFError(.malformed, "The protected session did not unlock for editing") }
        try encryptedDocument.editSession.rotatePage(at: 0, byDegrees: 90)
        // Protected sessions never write recovery snapshots.
        encryptedDocument.snapshotRecoveryNow()
        guard try encryptedDocument.recoveryStore.latest(for: encryptedDocument.recoveryKey) == nil
        else { throw PDFError(.malformed, "A protected session wrote a recovery snapshot") }
        let protectedSave = try encryptedDocument.data(ofType: "com.adobe.pdf")
        guard protectedSave != encryptedData,
          (try? PDFParser.parse(protectedSave)) == nil
        else { throw PDFError(.malformed, "The protected save did not stay encrypted") }
        let protectedReparsed = try PDFParser.unlock(protectedSave, password: "abc")
        guard
          case .dictionary(let protectedPage)? =
            protectedReparsed.parsed.graph.objects[protectedReparsed.parsed.pageIDs[0]],
          case .integer(let protectedRotation)? = protectedPage[PDFName("Rotate")],
          protectedRotation == 90
        else { throw PDFError(.malformed, "The protected save lost the edit") }
        guard let protectedDocument = PDFDocument(data: protectedSave),
          protectedDocument.unlock(withPassword: "abc"),
          protectedDocument.page(at: 0)?.rotation == 90
        else {
          throw PDFError(.malformed, "The protected save did not open in the independent reader")
        }
        // Simulate the completed save so locking does not need the dirty
        // confirmation alert in the automated run.
        encryptedDocument.editSession.noteSaved()
        // P28-023: locking returns the document to its protected read-only
        // state with the exact encrypted source bytes.
        encryptedDocument.lockDocument()
        guard !encryptedDocument.editSession.isProtected,
          !encryptedDocument.editSession.canEdit,
          try encryptedDocument.data(ofType: "com.adobe.pdf") == encryptedData,
          encryptedViewer.isLocked
        else { throw PDFError(.malformed, "Locking did not restore the protected state") }

        viewer.lastPage()
        guard viewer.pageNumber == 3, secondViewer.pageNumber == 1 else {
          throw PDFError(.malformed, "Independent page navigation smoke test failed")
        }
        viewer.firstPage()
        viewer.actualSize()
        window.setContentSize(NSSize(width: 1_080, height: 760))
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        viewer.fitPage()
        try await Task.sleep(for: .milliseconds(500))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard viewer.scale > 0.25, viewer.pageNumber == 1 else {
          throw PDFError(
            .malformed,
            "Fit Page did not produce a readable first-page layout (scale \(viewer.scale), page \(viewer.pageNumber), bounds \(viewer.view.bounds))"
          )
        }
        // P12-016: view/page coordinate round-trips hold no drift across
        // zoom (trackpad gestures are PDFKit-owned; the app asserts the
        // shared coordinate mapping stays exact at every scale).
        func drift(at point: NSPoint, in pdfView: PDFView) -> Double {
          guard let page = pdfView.currentPage else { return .infinity }
          let pagePoint = pdfView.convert(point, to: page)
          let back = pdfView.convert(pagePoint, from: page)
          return hypot(back.x - point.x, back.y - point.y)
        }
        let probePoint = NSPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY)
        guard drift(at: probePoint, in: viewer.view) < 0.5 else {
          throw PDFError(.malformed, "View/page coordinates drift at fit scale")
        }
        viewer.zoomIn()
        content.layoutSubtreeIfNeeded()
        guard drift(at: probePoint, in: viewer.view) < 0.5 else {
          throw PDFError(.malformed, "View/page coordinates drift after zooming in")
        }
        viewer.fitPage()
        content.layoutSubtreeIfNeeded()
        guard drift(at: probePoint, in: viewer.view) < 0.5 else {
          throw PDFError(.malformed, "View/page coordinates drift after refitting")
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
          throw PDFError(.malformed, "Could not capture the app's own view")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
          try png.write(to: output.appendingPathComponent("workspace.png"), options: .atomic)
        }
        // P33-022/P33-023: assisted tagging on the untagged three-page
        // document: suggestions stay unconfirmed until reviewed, and applying
        // an accepted heading creates real structure.
        first.suggestStructureTags()
        guard let review = first.structureModel.review, review.pending.count >= 3,
          review.suggestions.allSatisfy({ $0.origin == .visualOrderGuess }),
          review.suggestions.contains(where: {
            if case .heading(let level) = $0.kind { return level == 1 } else { return false }
          }),
          !first.structureModel.isTagged,
          first.structureModel.entries.isEmpty,
          let firstViewer = first.viewer
        else { throw PDFError(.malformed, "Assisted tagging produced no reviewable suggestions") }
        firstViewer.showStructure()
        guard let firstWindow = first.windowControllers.first?.window,
          let firstContent = firstWindow.contentView
        else { throw PDFError(.malformed, "The tagging sidebar did not open") }
        try await Task.sleep(for: .milliseconds(200))
        firstContent.layoutSubtreeIfNeeded()
        firstContent.displayIfNeeded()
        if let taggingBitmap = firstContent.bitmapImageRepForCachingDisplay(in: firstContent.bounds)
        {
          firstContent.cacheDisplay(in: firstContent.bounds, to: taggingBitmap)
          if let png = taggingBitmap.representation(using: .png, properties: [:]) {
            try png.write(
              to: output.appendingPathComponent("structure-suggestions.png"), options: .atomic)
          }
        }
        guard
          let headingSuggestion = review.suggestions.first(where: {
            if case .heading = $0.kind { return true } else { return false }
          })
        else { throw PDFError(.malformed, "No heading suggestion to review") }
        first.structureModel.review?.accept(headingSuggestion.id)
        first.applyAcceptedStructureSuggestions()
        guard first.structureModel.isTagged,
          first.structureModel.entries.contains(where: {
            $0.element.role == "H1" && $0.element.pageIndex == headingSuggestion.pageIndex
          }),
          first.structureModel.issues.isEmpty,
          first.structureModel.review?.suggestions.count == review.suggestions.count - 1
        else { throw PDFError(.malformed, "Accepted tagging did not create confirmed structure") }
        // Undo returns the document to the untagged baseline so the later
        // byte-equality checks still compare against the original file.
        first.refreshStructure()
        // P17-007: the committed edit registered a native undo action with
        // the document's UndoManager; the menu's undo drives it.
        guard first.undoManager?.canUndo == true,
          first.undoManager?.undoActionName == "Edit"
        else { throw PDFError(.malformed, "Native undo action was not registered") }
        guard first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == (try Data(contentsOf: firstURL))
        else { throw PDFError(.malformed, "Undo did not restore the untagged baseline") }
        // The manager now offers the redo the session recorded.
        guard first.undoManager?.canRedo == true else {
          throw PDFError(.malformed, "Native redo action was not registered")
        }
        first.refreshStructure()
        guard !first.structureModel.isTagged, first.structureModel.entries.isEmpty else {
          throw PDFError(.malformed, "Undo did not clear the confirmed structure")
        }

        // P33-024: independent accessibility (VoiceOver) and keyboard audit.
        // The accessibility audit walks the running app's AX tree — the same
        // interface VoiceOver uses — and requires every interactive control to
        // carry a label; the keyboard audit verifies the menu shortcut map and
        // invokes real menu actions on the key window.
        // P12-023: the inspector and info sidebars join the audited chrome.
        other.viewer?.showInspector()
        taggedViewer.showInfo()
        try await Task.sleep(for: .milliseconds(300))
        let accessibility = AccessibilityAudit.run()
        let requiredLabels: Set<String> = [
          "Toggle sidebar", "Previous page", "Next page", "Page number",
          "Zoom out", "Zoom in", "Fit Page", "Suggest structure tags",
          "Accept suggestion: Heading 1", "Reject suggestion: Heading 1", "Structure",
          "Selection inspector", "Document information",
        ]
        guard accessibility.windowsAudited >= 2, accessibility.interactiveCount >= 12,
          accessibility.unlabeled.isEmpty,
          requiredLabels.isSubset(of: accessibility.labels)
        else {
          throw PDFError(
            .malformed,
            "Accessibility audit failed (windows \(accessibility.windowsAudited), interactive \(accessibility.interactiveCount), unlabeled \(accessibility.unlabeled), missing \(requiredLabels.subtracting(accessibility.labels).sorted()))"
          )
        }

        let keyboard = KeyboardAudit.verify([
          .init(title: "New PDF", modifiers: [.command]),
          .init(title: "Settings…", modifiers: [.command]),
          .init(title: "Open…", modifiers: [.command]),
          .init(title: "Save", modifiers: [.command]),
          .init(title: "Find…", modifiers: [.command]),
          .init(title: "Next Page", modifiers: [.command]),
          .init(title: "Previous Page", modifiers: [.command]),
          .init(title: "Zoom In", modifiers: [.command]),
          .init(title: "Zoom Out", modifiers: [.command]),
          .init(title: "Fit Page", modifiers: [.command]),
          .init(title: "Actual Size", modifiers: [.command]),
          .init(title: "Show Structure", modifiers: [.command, .option]),
          .init(title: "Undo Edit", modifiers: [.command]),
          .init(title: "Redo Edit", modifiers: [.command, .shift]),
          .init(title: "Rotate Right", modifiers: [.command, .shift]),
          .init(title: "Highlight Selection", modifiers: [.command, .shift]),
          .init(title: "Text Edit Tool", modifiers: [.command, .control]),
          .init(title: "Select Tool", modifiers: [.command, .control]),
          .init(title: "Go Back", modifiers: [.command, .option]),
          .init(title: "Go Forward", modifiers: [.command, .option]),
          .init(title: "Select Next Page Object", modifiers: [.command, .option]),
          .init(title: "Select Previous Page Object", modifiers: [.command, .option]),
          .init(title: "Fit Width", modifiers: [.command, .shift]),
          .init(title: "Show Inspector", modifiers: [.command, .option]),
          .init(title: "Show Document Info", modifiers: [.command, .option]),
        ])
        guard keyboard.missing.isEmpty, keyboard.shortcutCount >= 30 else {
          throw PDFError(
            .malformed,
            "Keyboard audit failed (missing \(keyboard.missing), \(keyboard.shortcutCount) shortcuts)"
          )
        }
        NSApp.activate(ignoringOtherApps: true)
        firstWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let auditPage = firstViewer.pageNumber
        // The key path uses the live, layout-localized key equivalents.
        guard KeyboardAudit.press("Next Page"),
          firstViewer.pageNumber == min(auditPage + 1, firstViewer.pageCount),
          KeyboardAudit.press("Previous Page"), firstViewer.pageNumber == auditPage,
          KeyboardAudit.press("Zoom In"), firstViewer.scale > 0,
          KeyboardAudit.press("Fit Page"), firstViewer.scale > 0.25
        else { throw PDFError(.malformed, "Keyboard key-equivalent path did not work") }
        // P12-027: shortcuts act on the key window across multiple documents.
        let imagePageBefore = imageViewer.pageNumber
        imageWindow.makeKeyAndOrderFront(nil)
        guard KeyboardAudit.press("Next Page"),
          imageViewer.pageNumber == imagePageBefore + 1,
          firstViewer.pageNumber == auditPage,
          KeyboardAudit.press("Previous Page"), imageViewer.pageNumber == imagePageBefore
        else { throw PDFError(.malformed, "Menu shortcuts did not follow the key window") }
        firstWindow.makeKeyAndOrderFront(nil)
        // P12-026: primary pointer targets keep a minimum hit size without
        // giving up the dense desktop layout. Sizes come from the AX tree —
        // what pointer and VoiceOver users actually get.
        firstWindow.makeKeyAndOrderFront(nil)
        // Measured the way pointers resolve targets: AX labels locate each
        // control, and the enclosing toolbar button frame is asserted.
        func hitButtonFrame(labeled label: String) throws -> NSRect {
          guard let element = AccessibilityAudit.keyWindowElement(labeled: label),
            let position = AccessibilityAudit.position(of: element),
            let reported = AccessibilityAudit.size(of: element),
            let screen = NSScreen.screens.first
          else { throw PDFError(.malformed, "Pointer target \(label) has no AX position") }
          // Aim at the content center: it always lies inside the button.
          let center = NSPoint(
            x: position.x + reported.width / 2, y: position.y + reported.height / 2)
          let flipped = NSPoint(x: center.x, y: screen.frame.height - center.y)
          let windowPoint = firstWindow.convertPoint(fromScreen: flipped)
          // AppKit hit-testing does not descend into SwiftUI containers,
          // so the button is resolved by geometric containment in window
          // coordinates instead.
          let prefix = "SwiftUIAppKitButton"
          var found: NSRect?
          func scan(_ root: NSView) {
            if "\(type(of: root))".hasPrefix(prefix),
              root.convert(root.bounds, to: nil).contains(windowPoint)
            {
              found = root.convert(root.bounds, to: nil)
            }
            for sub in root.subviews { scan(sub) }
          }
          scan(content)
          guard let frame = found else {
            throw PDFError(.malformed, "Pointer target \(label) has no button hit target")
          }
          return frame
        }
        for label in [
          "Toggle sidebar", "Previous page", "Next page", "Zoom out", "Zoom in",
        ] {
          let frame = try hitButtonFrame(labeled: label)
          guard frame.width >= 32, frame.height >= 32 else {
            throw PDFError(
              .malformed,
              "Pointer target \(label) is \(frame.width)x\(frame.height), below the 32 pt minimum")
          }
        }
        // P12-028: background-job completion returns keyboard focus to the
        // page view instead of stranding it on the job control.
        guard let pageField = AccessibilityAudit.keyWindowElement(labeled: "Page number"),
          AccessibilityAudit.focus(pageField)
        else { throw PDFError(.malformed, "Could not move focus for the focus test") }
        let focusExportDir = output.appendingPathComponent("focus-images")
        try await first.exportPageImages(
          to: focusExportDir, baseName: "focus",
          options: PageImageExportOptions(format: .png, dpi: 72))
        try await Task.sleep(for: .milliseconds(300))
        guard firstWindow.firstResponder === viewer.view else {
          throw PDFError(.malformed, "Focus did not return to the page view after export")
        }
        // Tool modes switch through their menu commands (P12-012). Synthetic
        // key events only traverse plain-Command equivalents, so Option
        // combinations are covered by the shortcut map above plus invocation
        // here; the end-to-end key path is proven by the plain-Command items.
        guard KeyboardAudit.invoke("Text Edit Tool"), firstViewer.activeTool == .textEdit,
          KeyboardAudit.invoke("Select Tool"), firstViewer.activeTool == .select
        else { throw PDFError(.malformed, "Tool switching through menu commands did not work") }
        checkpoint("keyboard Find/highlight/save workflow")
        // P12-029: keyboard-only completion of a find/highlight/save
        // workflow. App-local Unicode key events follow the window's real
        // first responder without needing permission to inject system-wide
        // input. Navigation, annotation, and saving use menu key equivalents.
        func postKey(_ characters: String, keyCode: UInt16, to window: NSWindow) {
          for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
              let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
            else { continue }
            window.sendEvent(event)
          }
        }
        func postUnicode(_ string: String, to window: NSWindow) {
          for character in string {
            postKey(String(character), keyCode: 0, to: window)
          }
        }
        func postReturn(to window: NSWindow) {
          postKey("\r", keyCode: 0x24, to: window)
        }
        let keyboardCopyURL = output.appendingPathComponent("keyboard-copy.pdf")
        try? FileManager.default.removeItem(at: keyboardCopyURL)
        try FileManager.default.copyItem(
          at: fixtures.appendingPathComponent("three-pages.pdf"), to: keyboardCopyURL)
        let (keyboardOpened, _) = try await controller.openDocument(
          withContentsOf: keyboardCopyURL, display: true)
        guard let keyboardDocument = keyboardOpened as? SPDFDocument,
          let keyboardViewer = keyboardDocument.viewer,
          let keyboardWindow = keyboardDocument.windowControllers.first?.window
        else { throw PDFError(.malformed, "Could not open the keyboard workflow copy") }
        keyboardWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        guard KeyboardAudit.press("Find…"), keyboardViewer.isSearchVisible else {
          throw PDFError(.malformed, "Find did not open over the keyboard")
        }
        try await Task.sleep(for: .milliseconds(300))
        guard
          keyboardWindow.firstResponder is NSTextField
            || keyboardWindow.firstResponder is NSTextView
        else {
          throw PDFError(
            .malformed, "The find field did not take focus (no keyboard entry point)")
        }
        postUnicode("page 2", to: keyboardWindow)
        try await Task.sleep(for: .milliseconds(500))
        guard keyboardViewer.searchText == "page 2" else {
          throw PDFError(
            .malformed,
            "Typed text did not reach the find field (got \(keyboardViewer.searchText))")
        }
        postReturn(to: keyboardWindow)
        try await Task.sleep(for: .milliseconds(500))
        guard keyboardViewer.searchMatchCount == 1, keyboardViewer.searchIndex == 1,
          (keyboardViewer.selectedObjectSummary ?? "").contains("Page 2")
        else {
          throw PDFError(
            .malformed,
            "Return did not run the search (matches \(keyboardViewer.searchMatchCount))")
        }
        let commentsBefore = keyboardDocument.commentsModel.comments.count
        guard KeyboardAudit.invoke("Highlight Selection"),
          keyboardDocument.commentsModel.comments.count == commentsBefore + 1
        else { throw PDFError(.malformed, "Highlight Selection did not annotate the match") }
        // Text-input or utility windows can become key during the workflow.
        // Save must be sent with the intended document owning keyboard focus.
        keyboardWindow.makeKeyAndOrderFront(nil)
        let keyboardRecoveryKey = keyboardDocument.recoveryKey
        guard NSApp.keyWindow === keyboardWindow, KeyboardAudit.press("Save") else {
          throw PDFError(.malformed, "Save did not run over the keyboard")
        }
        // NSDocument saves asynchronously. Wait for the actual disk result,
        // rather than assuming it is present after a fixed 500 ms delay.
        let saveDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var savedDocument: PDFDocument?
        repeat {
          if let savedData = try? Data(contentsOf: keyboardCopyURL),
            let candidate = PDFDocument(data: savedData),
            candidate.page(at: 1)?.annotations.filter({ $0.type == "Highlight" }).count == 1,
            !keyboardDocument.editSession.isDirty,
            !keyboardDocument.recoveryStore.pendingKeys().contains(keyboardRecoveryKey)
          {
            savedDocument = candidate
            break
          }
          try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < saveDeadline
        guard let savedDocument else {
          throw PDFError(.malformed, "The saved highlight did not reopen within three seconds")
        }
        guard
          savedDocument.page(at: 1)?.annotations.filter({
            // PDFAnnotation.type omits the subtype's leading slash.
            $0.type == "Highlight"
          }).count == 1
        else { throw PDFError(.malformed, "The saved copy lacks the keyboard-made highlight") }
        checkpoint("closing keyboard workflow document")
        keyboardDocument.close()
        // P10-008/P10-027: Duplicate copies the document without touching
        // the original's file association.
        let documentsBefore = controller.documents.count
        guard KeyboardAudit.invoke("Duplicate"),
          controller.documents.count == documentsBefore + 1,
          let duplicate =
            (controller.documents.first {
              $0 !== first && ($0 as? SPDFDocument)?.fileURL == nil
            } as? SPDFDocument),
          duplicate.viewer?.pageCount == viewer.pageCount,
          first.fileURL != nil
        else { throw PDFError(.malformed, "Duplicate did not copy the document cleanly") }
        duplicate.close()
        checkpoint("keyboard workflow closed; rulers and native gestures")
        // P12-018: rulers and guides toggle from the menu and label
        // themselves for VoiceOver.
        firstWindow.makeKeyAndOrderFront(nil)
        let rulersInvoked = KeyboardAudit.invoke("Show Rulers")
        let guidesInvoked = KeyboardAudit.invoke("Show Guides")
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        guard rulersInvoked, viewer.areRulersVisible,
          guidesInvoked, viewer.areGuidesVisible,
          AccessibilityAudit.keyWindowElement(labeled: "Horizontal ruler") != nil,
          AccessibilityAudit.keyWindowElement(labeled: "Vertical ruler") != nil,
          AccessibilityAudit.keyWindowElement(labeled: "Alignment guides") != nil
        else { throw PDFError(.malformed, "Rulers and guides did not appear") }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        if let rulersBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
          content.cacheDisplay(in: content.bounds, to: rulersBitmap)
          if let png = rulersBitmap.representation(using: .png, properties: [:]) {
            try png.write(
              to: output.appendingPathComponent("workspace-rulers.png"), options: .atomic)
          }
        }
        // Drag text selection passes through the overlay stack in the
        // select tool. Queue a complete app-local gesture before yielding:
        // PDFKit's mouse-down handler tracks drag/up events synchronously.
        guard KeyboardAudit.invoke("Select Tool"), viewer.activeTool == .select else {
          throw PDFError(.malformed, "Could not arm the select tool for the drag test")
        }
        func windowPoint(_ viewPoint: NSPoint) -> NSPoint {
          viewer.view.convert(viewPoint, to: nil)
        }
        func postMouse(_ type: NSEvent.EventType, at point: NSPoint) {
          guard
            let event = NSEvent.mouseEvent(
              with: type, location: point, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: firstWindow.windowNumber, context: nil,
              eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
          else { return }
          NSApp.postEvent(event, atStart: false)
        }
        func hasOverlayEditor(in root: NSView) -> Bool {
          if let field = root as? InlinePageTextView,
            field.identifier?.rawValue == "spdf-text-editor"
          {
            return true
          }
          return root.subviews.contains { hasOverlayEditor(in: $0) }
        }
        guard let dragDocument = viewer.view.document,
          let dragPage = dragDocument.page(at: 0),
          let dragMatch = dragDocument.findString("fixture - page 1", withOptions: []).first
        else { throw PDFError(.malformed, "No drag target text for the selection test") }
        let dragBounds = dragMatch.bounds(for: dragPage)
        let dragStart = viewer.view.convert(
          NSPoint(x: dragBounds.minX + 2, y: dragBounds.midY), from: dragPage)
        let dragEnd = viewer.view.convert(
          NSPoint(x: dragBounds.maxX - 2, y: dragBounds.midY), from: dragPage)
        let windowStart = windowPoint(dragStart)
        let windowEnd = windowPoint(dragEnd)
        postMouse(.leftMouseDown, at: windowStart)
        for step in 1...8 {
          let t = Double(step) / 8
          postMouse(
            .leftMouseDragged,
            at: NSPoint(
              x: windowStart.x + (windowEnd.x - windowStart.x) * t,
              y: windowStart.y + (windowEnd.y - windowStart.y) * t))
        }
        postMouse(.leftMouseUp, at: windowEnd)
        try await Task.sleep(for: .milliseconds(400))
        guard (viewer.view.currentSelection?.string ?? "").contains("fixture") else {
          throw PDFError(.malformed, "Drag selection did not pass through to the page view")
        }
        guard !hasOverlayEditor(in: content) else {
          throw PDFError(.malformed, "A drag opened the text editor instead of selecting")
        }
        // Clicking in the text tool opens the editor; leaving the tool
        // commits it (P12-013 across the overlay).
        guard KeyboardAudit.invoke("Text Edit Tool"), viewer.activeTool == .textEdit else {
          throw PDFError(.malformed, "Could not arm the text tool for the click test")
        }
        let clickPoint = windowPoint(
          viewer.view.convert(NSPoint(x: dragBounds.midX, y: dragBounds.midY), from: dragPage))
        postMouse(.leftMouseDown, at: clickPoint)
        postMouse(.leftMouseUp, at: clickPoint)
        try await Task.sleep(for: .milliseconds(400))
        guard hasOverlayEditor(in: content) else {
          throw PDFError(.malformed, "Clicking text in the text tool opened no editor")
        }
        guard KeyboardAudit.invoke("Select Tool") else {
          throw PDFError(.malformed, "Could not switch back to the select tool")
        }
        try await Task.sleep(for: .milliseconds(500))
        guard !hasOverlayEditor(in: content) else {
          throw PDFError(.malformed, "Leaving the text tool did not commit the editor")
        }
        let auditScale = firstViewer.scale
        guard KeyboardAudit.invoke("Zoom In"), firstViewer.scale > auditScale,
          KeyboardAudit.invoke("Show Structure"), firstViewer.sidebarMode == .structure
        else { throw PDFError(.malformed, "Keyboard menu commands did not work") }

        checkpoint("native gestures passed; export workflows")
        // P34-001/P34-003/P34-026: text and image exports through the
        // document path, reopened and verified independently.
        let textExportURL = output.appendingPathComponent("exported-text.txt")
        try first.exportText(to: textExportURL)
        let exportedText = String(decoding: try Data(contentsOf: textExportURL), as: UTF8.self)
        guard exportedText.contains("sPDF Editor fixture - page 1"),
          exportedText.contains("sPDF Editor fixture - page 3"),
          exportedText.components(separatedBy: "\u{0C}").count == 3,
          exportedText.range(of: "page 1")!.lowerBound
            < exportedText.range(of: "page 3")!.lowerBound as String.Index
        else {
          throw PDFError(.malformed, "Text export did not contain the expected reading order")
        }
        let imageDirectory = output.appendingPathComponent("exported-images")
        try? FileManager.default.removeItem(at: imageDirectory)
        let exportedImages = try await first.exportPageImages(
          to: imageDirectory, baseName: "page",
          options: PageImageExportOptions(format: .png, dpi: 72))
        guard exportedImages.count == 3,
          exportedImages.map { $0.url.lastPathComponent } == [
            "page-0001.png", "page-0002.png", "page-0003.png",
          ],
          exportedImages.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
          exportedImages[0].pixelWidth == 612, exportedImages[0].pixelHeight == 792
        else { throw PDFError(.malformed, "Page image export did not produce the expected files") }
        // P34-009/P34-012/P34-013: semantic HTML of the tagged document and
        // packaged appearance HTML of the three-page document.
        let semanticHTMLURL = output.appendingPathComponent("tagged-semantic.html")
        try taggedDocument.exportHTML(to: semanticHTMLURL)
        let semanticHTML = String(decoding: try Data(contentsOf: semanticHTMLURL), as: UTF8.self)
        guard semanticHTML.contains("<h1>Tagged heading</h1>"),
          semanticHTML.contains("https://example.invalid/tagged"),
          semanticHTML.contains("<span>Tagged paragraph text</span>"),
          !semanticHTML.lowercased().contains("<script"),
          !semanticHTML.lowercased().contains("javascript:")
        else { throw PDFError(.malformed, "Semantic HTML export did not preserve structure") }
        let appearanceHTMLURL = output.appendingPathComponent("workspace-appearance.html")
        try? FileManager.default.removeItem(at: output.appendingPathComponent("images"))
        try first.exportHTML(
          to: appearanceHTMLURL,
          options: PDFHTMLExportOptions(mode: .appearance, imagePolicy: .package, imageDPI: 72))
        let appearanceHTML = String(
          decoding: try Data(contentsOf: appearanceHTMLURL), as: UTF8.self)
        guard appearanceHTML.contains("images/page-0001.png"),
          appearanceHTML.contains("images/page-0003.png"),
          FileManager.default.fileExists(
            atPath: output.appendingPathComponent("images/page-0003.png").path)
        else { throw PDFError(.malformed, "Appearance HTML export did not package page images") }

        // P34-017/P34-018/P34-028: attachment inventory and byte-exact
        // extraction with a traversal-shaped name.
        guard let attachmentDocument = attachmentOpened as? SPDFDocument else {
          throw PDFError(.malformed, "The attachment fixture did not open")
        }
        guard let attachmentGraph = attachmentDocument.editSession.currentGraph else {
          throw PDFError(.malformed, "The attachment fixture has no graph")
        }
        let attachmentList = PDFAttachmentInventory.attachments(in: attachmentGraph)
        guard attachmentList.count == 2,
          attachmentList.contains(where: {
            $0.name == "../unsafe name.txt" && $0.mimeType == "text/plain"
          })
        else { throw PDFError(.malformed, "The attachment inventory did not resolve") }
        let attachmentDirectory = output.appendingPathComponent("attachments")
        try? FileManager.default.removeItem(at: attachmentDirectory)
        let attachmentURLs = try attachmentDocument.exportAttachments(to: attachmentDirectory)
        guard attachmentURLs.count == 2,
          attachmentURLs.contains(where: { $0.lastPathComponent == "unsafe name.txt" }),
          !attachmentURLs.contains(where: { $0.path.contains("..") }),
          try String(
            contentsOf: attachmentDirectory.appendingPathComponent("notes.txt"), encoding: .utf8)
            == "Attachment payload one.\n"
        else { throw PDFError(.malformed, "Attachment extraction did not preserve bytes safely") }

        // P34-021–P34-024: print-to-PDF derivative through the native print
        // pipeline, reopened with an independent reader.
        let printURL = output.appendingPathComponent("print-export.pdf")
        try first.exportPrintPDF(to: printURL)
        guard let printedDocument = PDFDocument(data: try Data(contentsOf: printURL)),
          printedDocument.pageCount == 3,
          printedDocument.page(at: 0)?.bounds(for: .mediaBox).size
            == CGSize(width: 792, height: 842),
          printedDocument.string?.contains("sPDF Editor fixture - page 1") == true
        else { throw PDFError(.malformed, "The print PDF derivative did not match the document") }

        // P34-007/P34-008: image extraction with original-byte provenance.
        let imageExportDirectory = output.appendingPathComponent("exported-originals")
        try? FileManager.default.removeItem(at: imageExportDirectory)
        let exportedOriginals = try await third.exportImages(
          to: imageExportDirectory, baseName: "image")
        guard exportedOriginals.count == 3,
          exportedOriginals.allSatisfy({ $0.provenance == .original }),
          exportedOriginals.map(\.url.lastPathComponent) == [
            "image-page-0001-image-0001.png", "image-page-0001-image-0002.png",
            "image-page-0002-image-0001.png",
          ],
          exportedOriginals.allSatisfy({ $0.pixelWidth == 2 && $0.pixelHeight == 2 }),
          FileManager.default.fileExists(
            atPath: imageExportDirectory.appendingPathComponent("image-page-0001-image-0001.png")
              .path)
        else { throw PDFError(.malformed, "Image extraction did not preserve stored samples") }

        // P19-007/P19-012/P19-014: reflow a paragraph through the document
        // path, then undo so the original bytes stay authoritative.
        guard let reflowGraph = first.editSession.currentGraph,
          let flowing = try ParagraphReconstruction.candidates(
            pageID: first.editSession.pageIDs[0], in: reflowGraph
          ).first(where: { $0.kind == .flowing }),
          !(try ParagraphReflow.plan(
            pageID: first.editSession.pageIDs[0], candidate: flowing,
            replacement: "Reflowed smoke paragraph text that wraps across the box.",
            in: reflowGraph,
            options: ParagraphReflowOptions(allowLowConfidence: true)
          ).plan.sourceMap.isEmpty),
          first.reflowParagraph(
            pageID: first.editSession.pageIDs[0], candidate: flowing,
            replacement: "Reflowed smoke paragraph text that wraps across the box.",
            options: ParagraphReflowOptions(allowLowConfidence: true)),
          let reflowedGraph = first.editSession.currentGraph,
          try PageTextLayout.build(pageID: first.editSession.pageIDs[0], in: reflowedGraph)
            .clusters.map(\.text).joined().contains("Reflowed smoke paragraph"),
          first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == (try Data(contentsOf: firstURL))
        else { throw PDFError(.malformed, "Paragraph reflow through the document failed") }
        first.refreshStructure()

        // P19-001–P19-006: paragraph reconstruction on the untagged document.
        guard let firstGraph = first.editSession.currentGraph else {
          throw PDFError(.malformed, "The first document has no graph")
        }
        let paragraphs = try ParagraphReconstruction.candidates(
          pageID: first.editSession.pageIDs[0], in: firstGraph)
        guard paragraphs.contains(where: { $0.kind == .heading }),
          paragraphs.contains(where: { $0.kind == .flowing && $0.lineIndices.count >= 1 }),
          paragraphs.allSatisfy({ !$0.text.isEmpty && $0.confidence > 0 })
        else { throw PDFError(.malformed, "Paragraph reconstruction found no candidates") }

        let original = try Data(contentsOf: firstURL)
        let saved = try first.data(ofType: "com.adobe.pdf")
        guard saved == original else {
          throw PDFError(.malformed, "Original bytes changed during viewing")
        }
        let copyURL = output.appendingPathComponent("original-copy.pdf")
        try first.write(
          to: copyURL, ofType: "com.adobe.pdf", for: .saveToOperation, originalContentsURL: nil)
        guard try Data(contentsOf: copyURL) == original else {
          throw PDFError(.malformed, "Native original-copy write changed the bytes")
        }

        // P35-015–P35-019: DOCX reconstruction through the document path,
        // verified by independent tools (unzip and textutil).
        let docxURL = output.appendingPathComponent("export.docx")
        let docxBlocks = try await first.exportDOCX(to: docxURL)
        // P35-022: the bounded reconstruction preview flags ambiguous blocks.
        let preview = DOCXPreview.build(
          reconstruction: try DOCXReconstructionBuilder.reconstruct(
            pageIDs: first.editSession.pageIDs, in: firstGraph))
        let previewSnippetsBounded = preview.entries.allSatisfy {
          $0.text.count <= DOCXPreview.snippetLength
        }
        guard preview.totalCount > 0, preview.entries.count > 0,
          preview.text().contains("DOCX reconstruction preview"), previewSnippetsBounded
        else { throw PDFError(.malformed, "DOCX reconstruction preview failed") }

        // P35-021: the appearance mode also produces a valid package.
        let appearanceURL = output.appendingPathComponent("export-appearance.docx")
        let appearanceBlocks = try await first.exportDOCX(to: appearanceURL, mode: .appearance)
        guard appearanceBlocks > 0,
          SmokeTest.runToolOutput("/usr/bin/unzip", ["-t", appearanceURL.path]) != nil
        else { throw PDFError(.malformed, "Appearance DOCX export failed verification") }
        guard docxBlocks > 0,
          try Data(contentsOf: docxURL).prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]),
          let documentXML = SmokeTest.runToolOutput(
            "/usr/bin/unzip", ["-p", docxURL.path, "word/document.xml"]),
          documentXML.contains("<w:document"), documentXML.contains("<w:sectPr>"),
          SmokeTest.runToolOutput("/usr/bin/unzip", ["-t", docxURL.path]) != nil,
          let converted = SmokeTest.runToolOutput(
            "/usr/bin/textutil", ["-convert", "txt", "-stdout", docxURL.path]),
          !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          try first.data(ofType: "com.adobe.pdf") == original
        else { throw PDFError(.malformed, "DOCX export failed independent verification") }

        // P36: table review model, CSV and XLSX export through the document
        // path (a synthetic table exercises the full packaging).
        let syntheticTable = ExtractedTable(
          pageIndex: 0, detection: .geometry, bounds: [0, 0, 120, 40], rowCount: 2,
          columnCount: 2,
          cells: [
            ExtractedTable.Cell(
              row: 0, column: 0, text: "Name", bounds: [0, 20, 60, 40], provenance: .text,
              confidence: 0.9),
            ExtractedTable.Cell(
              row: 0, column: 1, text: "007", bounds: [60, 20, 120, 40], provenance: .text,
              confidence: 0.9),
            ExtractedTable.Cell(
              row: 1, column: 0, text: "Ada", bounds: [0, 0, 60, 20], provenance: .text,
              confidence: 0.9),
            ExtractedTable.Cell(
              row: 1, column: 1, text: "=SUM(A1)", bounds: [60, 0, 120, 20], provenance: .text,
              confidence: 0.9),
          ], confidence: 0.8, limitations: [])
        var tableReview = TableReview(table: syntheticTable)
        try tableReview.setCellText(row: 1, column: 0, text: "Ada Lovelace")
        tableReview.accept()
        let reviewedTables = TableReview.exportable([tableReview])
        let tableXLSXURL = output.appendingPathComponent("tables.xlsx")
        let tableCSVURL = output.appendingPathComponent("tables.csv")
        let exportedTables = try first.exportTables(
          to: tableXLSXURL, format: .xlsx, tables: reviewedTables)
        _ = try first.exportTables(to: tableCSVURL, format: .csv, tables: reviewedTables)
        let detectedTables =
          (try? TableExtraction.tables(
            pageIDs: first.editSession.pageIDs, in: firstGraph))?.count ?? 0
        guard exportedTables == 1,
          SmokeTest.runToolOutput("/usr/bin/unzip", ["-t", tableXLSXURL.path]) != nil,
          let sheetXML = SmokeTest.runToolOutput(
            "/usr/bin/unzip", ["-p", tableXLSXURL.path, "xl/worksheets/sheet1.xml"]),
          let sharedStrings = SmokeTest.runToolOutput(
            "/usr/bin/unzip", ["-p", tableXLSXURL.path, "xl/sharedStrings.xml"]),
          sheetXML.contains("t=\"s\""), !sheetXML.contains("<f>"),
          sharedStrings.contains("007"), sharedStrings.contains("Ada Lovelace"),
          sharedStrings.contains("=SUM(A1)"),
          let csvText = try? String(contentsOf: tableCSVURL, encoding: .utf8),
          csvText.contains("007"), csvText.contains("'=SUM(A1)")
        else { throw PDFError(.malformed, "Table export failed verification") }

        // P37: the read-only compatibility report (version audit, archival
        // inventory, print preflight) claims no conformance and writes nothing.
        let versionAudit = PDFVersionAudit.audit(in: firstGraph)
        let archivalInventory = ArchivalInventory.inventory(
          firstGraph, pageIDs: first.editSession.pageIDs)
        let preflightInventory = PrintPreflightInventory.inventory(
          firstGraph, pageIDs: first.editSession.pageIDs)
        guard !versionAudit.declaresPDF20,
          archivalInventory.report().contains("not a conformance claim"),
          archivalInventory.findings.contains { $0.rule == "Font embedding" },
          !preflightInventory.pages.isEmpty,
          !PrintPreflightInventory.profileSelected,
          preflightInventory.report().contains("No preflight profile is selected"),
          try first.data(ofType: "com.adobe.pdf") == original
        else { throw PDFError(.malformed, "Compatibility report failed verification") }

        // P29: a synthetic graphical signature placed through the document
        // path carries the disclosure and no digital-signature claim.
        let signatureAsset = SignatureAsset(
          id: "smoke-asset", kind: .drawn, width: 4, height: 4,
          rgb8: Data(repeating: 20, count: 4 * 4 * 3),
          alpha8: Data(repeating: 255, count: 16))
        let signaturePlaced = try PDFEditingEngine.commit(
          PDFTransaction([
            PlaceSignatureStampCommand(
              pageID: first.editSession.pageIDs[0], rect: [100, 400, 260, 470],
              asset: signatureAsset,
              options: SignatureStampOptions(includeName: "Smoke Test"))
          ]), to: firstGraph)
        let signatureAnnotations = try AnnotationInventory.annotations(
          in: signaturePlaced, pageID: first.editSession.pageIDs[0])
        guard let signature = signatureAnnotations.last,
          signature.dictionary[PDFName("Name")] == .name(PDFName("SPDFGraphicalSignature")),
          signature.contents?.contains("not a digital signature") == true,
          signature.contents?.contains("Smoke Test") == true,
          try first.data(ofType: "com.adobe.pdf") == original
        else { throw PDFError(.malformed, "Graphical signature placement failed") }

        // P08: document inventory and capability assessment.
        let inventoryFacts = PDFDocumentInventory.documentFacts(
          in: firstGraph, pageCount: first.editSession.pageIDs.count)
        let inventoryAssessment = PDFDocumentInventory.assess(
          in: firstGraph, pageCount: first.editSession.pageIDs.count)
        let pageAttributes = PDFDocumentInventory.pageAttributes(
          pageIDs: first.editSession.pageIDs, in: firstGraph)
        guard inventoryAssessment.canView, inventoryAssessment.canInspect,
          pageAttributes.count == first.editSession.pageIDs.count,
          pageAttributes.allSatisfy { $0.identity.hasPrefix("page-") },
          !inventoryFacts.security.isEncrypted,
          try first.data(ofType: "com.adobe.pdf") == original
        else { throw PDFError(.malformed, "Document inventory failed") }

        // P37-023/P37-025: the preflight checks are read-only and claim no
        // PDF/X conformance.
        let preflightChecks = try PreflightCheckReport.run(
          firstGraph, pageIDs: first.editSession.pageIDs)
        guard !PreflightCheckReport.pdfxSupported,
          preflightChecks.findings.contains { $0.rule == "PDF/X" },
          preflightChecks.report().contains("no PDF/X conformance is claimed"),
          try first.data(ofType: "com.adobe.pdf") == original
        else { throw PDFError(.malformed, "Preflight checks failed verification") }

        // P37-012–P37-018: staged archival derivative, independent validation,
        // and the accessibility audit (no identifier is ever written).
        let derivativePlan = ArchivalDerivative.plan(
          firstGraph, pageIDs: first.editSession.pageIDs)
        let stagedDerivative = try ArchivalDerivative.stage(
          firstGraph, plan: derivativePlan, applying: derivativePlan.safeKinds)
        let stagedData = try PDFWriter.write(stagedDerivative.graph)
        let archivalValidation = ArchivalDerivative.validate(stagedData)
        let accessibilityAudit = PDFAccessibilityAudit.audit(
          firstGraph, pageIDs: first.editSession.pageIDs)
        let uaValidation = ArchivalDerivative.validateAccessibility(stagedData)
        guard accessibilityAudit.humanReviewRequirements.count == 7,
          accessibilityAudit.report().contains("cannot prove accessibility"),
          accessibilityAudit.findings.contains { $0.rule == "Rendering" },
          archivalValidation == nil
            || !FileManager.default.isExecutableFile(
              atPath: ArchivalDerivative.defaultValidatorPath)
            || archivalValidation?.validator == "veraPDF",
          try first.data(ofType: "com.adobe.pdf") == original
        else { throw PDFError(.malformed, "Archival staging or accessibility audit failed") }

        // PAG-05: crop pages through one transaction, verify the saved
        // CropBox, and undo back to the original bytes.
        if let graph = first.editSession.currentGraph {
          let pageID = first.editSession.pageIDs[0]
          let attributes = PDFDocumentInventory.pageAttributes(
            pageIDs: [pageID], in: graph)
          let media = attributes[0].mediaBox
          let box = [media[0] + 10, media[1] + 10, media[2] - 10, media[3] - 10]
          try first.editSession.apply(
            PDFTransaction([DocumentAssembly.SetCropBoxCommand(boxes: [pageID: box])]))
          let cropped = try first.data(ofType: "com.adobe.pdf")
          let croppedParsed = try PDFParser.parse(cropped)
          let croppedAttributes = PDFDocumentInventory.pageAttributes(
            pageIDs: [croppedParsed.pageIDs[0]], in: croppedParsed.graph)
          guard croppedAttributes[0].cropBox == box else {
            throw PDFError(.malformed, "Page crop did not round-trip")
          }
          guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == original else {
            throw PDFError(.malformed, "Page crop undo did not restore the original bytes")
          }
          // PAG-05: the same transaction sets a Trim box without changing the
          // visible crop box.
          try first.editSession.apply(
            PDFTransaction([
              DocumentAssembly.SetPageBoxCommand(
                boxes: [pageID: box], kind: .trim)
            ]))
          let trimmed = try PDFParser.parse(try first.data(ofType: "com.adobe.pdf"))
          let trimmedAttributes = PDFDocumentInventory.pageAttributes(
            pageIDs: [trimmed.pageIDs[0]], in: trimmed.graph)
          guard trimmedAttributes[0].trimBox == box,
            trimmedAttributes[0].cropBox == attributes[0].cropBox
          else { throw PDFError(.malformed, "Trim box did not round-trip") }
          guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == original else {
            throw PDFError(.malformed, "Trim box undo did not restore the original bytes")
          }
          // PAG-06: a header mark lands on exactly the selected pages and
          // undoes as one transaction.
          let headerPlan = first.addPageMark(
            .header(text: "Smoke Header", style: AddedTextStyle(size: 10)),
            pageIDs: Array(first.editSession.pageIDs.prefix(2)))
          guard headerPlan?.pages.count == 2 else {
            throw PDFError(.malformed, "Page-mark plan did not cover the selected pages")
          }
          let markedPDF = try PDFParser.parse(try first.data(ofType: "com.adobe.pdf"))
          let markedGraph = markedPDF.graph
          let firstLayout = try PageTextLayout.build(
            pageID: markedPDF.pageIDs[0], in: markedGraph)
          let thirdLayout = try PageTextLayout.build(
            pageID: markedPDF.pageIDs[2], in: markedGraph)
          guard firstLayout.lines.contains(where: {
            firstLayout.text(in: $0).contains("Smoke Header")
          }), !thirdLayout.lines.contains(where: {
            thirdLayout.text(in: $0).contains("Smoke Header")
          }) else { throw PDFError(.malformed, "Page mark landed on the wrong pages") }
          guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == original else {
            throw PDFError(.malformed, "Page mark undo did not restore the original bytes")
          }
          // PAG-03: split writes predictable verified parts and leaves the
          // source session untouched.
          let splitDirectory = output.appendingPathComponent("split", isDirectory: true)
          try FileManager.default.createDirectory(
            at: splitDirectory, withIntermediateDirectories: true)
          let pageIDs = first.editSession.pageIDs
          let parts = try first.splitDocument(
            to: splitDirectory, pageGroups: [[pageIDs[0]], [pageIDs[1], pageIDs[2]]])
          guard parts.count == 2,
            parts[0].url.lastPathComponent.hasSuffix("-part-01.pdf"),
            parts[1].url.lastPathComponent.hasSuffix("-part-02.pdf")
          else { throw PDFError(.malformed, "Split output names are not predictable") }
          let partPages = try parts.map {
            try PDFParser.parse(Data(contentsOf: $0.url)).pageCount
          }
          guard partPages == [1, 2],
            try first.data(ofType: "com.adobe.pdf") == original
          else { throw PDFError(.malformed, "Split parts or source state are wrong") }
          // PAG-03: measured size split keeps oversized single pages alone.
          let sizeDirectory = output.appendingPathComponent("split-size", isDirectory: true)
          try FileManager.default.createDirectory(
            at: sizeDirectory, withIntermediateDirectories: true)
          let sizeParts = try first.splitDocumentBySize(to: sizeDirectory, maxBytes: 1)
          guard sizeParts.results.count == 3, sizeParts.oversized.count == 3 else {
            throw PDFError(.malformed, "Measured size split did not isolate pages")
          }
          // PAG-02: combine external PDFs in order through the verified writer.
          let combineURL = output.appendingPathComponent("combined.pdf")
          let firstSource = try Data(contentsOf: firstURL)
          let secondSource = try Data(contentsOf: secondURL)
          _ = try first.combineDocuments(from: [firstURL, secondURL], to: combineURL)
          let combined = try PDFParser.parse(Data(contentsOf: combineURL))
          guard combined.pageCount == 4,
            try Data(contentsOf: firstURL) == firstSource,
            try Data(contentsOf: secondURL) == secondSource
          else { throw PDFError(.malformed, "Combined output or source bytes are wrong") }
        }

        // Owned-core edit pipeline: rotate page 1, verify the edited bytes,
        // undo back to the exact original, redo, save an edited copy through
        // the native write path, and reparse the saved file.
        first.rotateCurrentPage(byDegrees: 90)
        let edited = try first.data(ofType: "com.adobe.pdf")
        guard edited != original else {
          throw PDFError(.malformed, "Rotation edit produced no byte change")
        }
        let editedParsed = try PDFParser.parse(edited)
        guard editedParsed.pageCount == 3,
          case .dictionary(let firstPage) = editedParsed.graph.objects[editedParsed.pageIDs[0]],
          case .integer(let editedRotation)? = firstPage[PDFName("Rotate")],
          editedRotation == 90
        else { throw PDFError(.malformed, "Rotation edit did not round-trip") }
        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == original else {
          throw PDFError(.malformed, "Undo did not restore the exact original bytes")
        }
        guard first.redoEdit(), try first.data(ofType: "com.adobe.pdf") == edited else {
          throw PDFError(.malformed, "Redo did not reproduce the edited bytes")
        }
        let editedCopyURL = output.appendingPathComponent("edited-copy.pdf")
        try first.write(
          to: editedCopyURL, ofType: "com.adobe.pdf", for: .saveToOperation,
          originalContentsURL: nil)
        first.editSession.noteSaved()
        first.updateChangeCount(.changeCleared)
        let copyParsed = try PDFParser.parse(try Data(contentsOf: editedCopyURL))
        guard case .dictionary(let copyPage) = copyParsed.graph.objects[copyParsed.pageIDs[0]],
          case .integer(let copyRotation)? = copyPage[PDFName("Rotate")],
          copyRotation == 90
        else { throw PDFError(.malformed, "Saved edit is not visible after reopening") }

        // Structural page edits: reorder, insert blank, and delete — each
        // undone back to the saved revision with exact byte restoration.
        let session = first.editSession
        let baseline = try first.data(ofType: "com.adobe.pdf")
        let baselineOrder = session.pageIDs
        try session.movePage(at: 1, to: 0)
        guard session.pageIDs == [baselineOrder[1], baselineOrder[0], baselineOrder[2]],
          try PDFParser.parse(session.bytesForSave()).pageIDs == session.pageIDs,
          first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == baseline
        else { throw PDFError(.malformed, "Structural reorder/undo did not round-trip") }

        try session.insertBlankPage(at: 1, width: 200, height: 300)
        guard session.pageIDs.count == 4,
          try PDFParser.parse(session.bytesForSave()).pageCount == 4,
          first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == baseline
        else { throw PDFError(.malformed, "Blank page insert/undo did not round-trip") }

        try session.deletePage(at: 2)
        guard session.pageIDs.count == 2,
          try PDFParser.parse(session.bytesForSave()).pageCount == 2,
          first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == baseline
        else { throw PDFError(.malformed, "Page delete/undo did not round-trip") }

        // Text editing: replace a real text-show operand, verify the old text
        // is gone from the saved content, then undo/redo back to exact bytes.
        let textBaseline = try first.data(ofType: "com.adobe.pdf")
        try session.replaceText(pageAt: 0, runIndex: 0, with: "Edited by smoke")
        let textEdited = try first.data(ofType: "com.adobe.pdf")
        guard textEdited != textBaseline else {
          throw PDFError(.malformed, "Text edit produced no byte change")
        }
        let editedDocument = try PDFParser.parse(textEdited)
        let baseDocument = try PDFParser.parse(textBaseline)
        guard case .stream(let editedContent)? = editedDocument.graph.objects[PDFObjectID(5)],
          case .stream(let baseContent)? = baseDocument.graph.objects[PDFObjectID(5)]
        else { throw PDFError(.malformed, "Edited content stream missing") }
        let editedText = String(decoding: try PDFFilters.decoded(editedContent), as: UTF8.self)
        let baseText = String(decoding: try PDFFilters.decoded(baseContent), as: UTF8.self)
        guard editedText.contains("(Edited by smoke)"),
          !editedText.contains("fixture - page 1"),
          baseText.contains("fixture - page 1")
        else { throw PDFError(.malformed, "Text replacement did not rewrite the operand") }
        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == textBaseline else {
          throw PDFError(.malformed, "Text edit undo did not restore the baseline bytes")
        }
        guard first.redoEdit(), try first.data(ofType: "com.adobe.pdf") == textEdited,
          first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == textBaseline
        else { throw PDFError(.malformed, "Text edit redo/undo did not round-trip") }

        // Annotation foundation: add a highlight over the viewer's real text
        // geometry with a generated appearance, verify it in the graph and in
        // Apple's reader, capture the rendered result, then undo to baseline
        // bytes. (The owned text-geometry bridge is unit-tested; this fixture's
        // standard-14 font carries no /Widths, so the smoke uses the viewer
        // adapter's selection bounds instead of conservative zero-width
        // clusters.)
        let annotationBaseline = try first.data(ofType: "com.adobe.pdf")
        guard let viewerDocument = viewer.view.document,
          let annotationPage = viewerDocument.page(at: 0),
          let selection = viewerDocument.findString("fixture - page 1", withOptions: []).first
        else { throw PDFError(.malformed, "No text selection for the annotation highlight") }
        let selectionBounds = selection.bounds(for: annotationPage)
        let annotationPageID = session.pageIDs[0]
        let annotationQuads = AddHighlightCommand.quads(forClusterBounds: [
          [
            selectionBounds.minX, selectionBounds.minY, selectionBounds.maxX,
            selectionBounds.maxY,
          ]
        ])
        try session.apply(
          PDFTransaction([
            AddHighlightCommand(
              pageID: annotationPageID, quads: annotationQuads, contents: "Smoke review",
              author: "smoke", modified: "D:20261010120000Z"),
            AddTextMarkupCommand(
              pageID: annotationPageID, style: .underline, quads: annotationQuads,
              color: [0.8, 0.1, 0.1], contents: "Smoke underline",
              modified: "D:20261010120000Z"),
            AddNoteCommand(
              pageID: annotationPageID,
              at: [selectionBounds.maxX + 8, selectionBounds.minY],
              contents: "Smoke note", author: "smoke", modified: "D:20261010120000Z"),
            AddFreeTextCommand(
              pageID: annotationPageID,
              rect: [
                selectionBounds.minX, selectionBounds.maxY - 60,
                selectionBounds.minX + 160, selectionBounds.maxY - 20,
              ],
              text: "Smoke free text", fontSize: 10, contents: "Smoke free text",
              modified: "D:20261010120000Z"),
            AddStampCommand(
              pageID: annotationPageID,
              rect: [
                selectionBounds.minX, selectionBounds.maxY - 120,
                selectionBounds.minX + 140, selectionBounds.maxY - 70,
              ],
              stampName: .draft, contents: "Smoke stamp", modified: "D:20261010120000Z"),
            AddLinkCommand(
              pageID: annotationPageID,
              rect: [
                selectionBounds.minX, selectionBounds.minY - 40,
                selectionBounds.minX + 140, selectionBounds.minY - 10,
              ],
              target: .uri("https://example.com/spdf"), contents: "Smoke link",
              modified: "D:20261010120000Z"),
          ]))
        let annotated = try first.data(ofType: "com.adobe.pdf")
        try annotated.write(
          to: output.appendingPathComponent("annotation.pdf"), options: .atomic)
        let annotatedParsed = try PDFParser.parse(annotated)
        guard
          try AnnotationInventory.annotations(in: annotatedParsed.graph, pageID: annotationPageID)
            .count == 6,
          let annotatedDocument = PDFDocument(data: annotated),
          let annotatedPage = annotatedDocument.page(at: 0),
          Set(annotatedPage.annotations.compactMap(\.type))
            == ["Highlight", "Underline", "Text", "FreeText", "Stamp", "Link"],
          annotatedPage.annotations.first(where: { $0.type == "Link" })?.url?.absoluteString
            == "https://example.com/spdf"
        else { throw PDFError(.malformed, "Markup annotations did not round-trip") }

        // Comment review: list, filter, navigate, and capture the panel.
        let comments = session.comments()
        guard comments.count == 5,
          CommentList.filter(comments, by: CommentFilter(subtype: PDFName("Highlight"))).count == 1,
          CommentList.filter(comments, by: CommentFilter(state: PDFName("None"))).count == 5,
          CommentList.filter(comments, by: CommentFilter(pageIndex: 0)).count == 5
        else { throw PDFError(.malformed, "Comment listing or filtering failed") }
        first.commentsModel.comments = comments
        viewer.showComments()
        first.navigate(to: comments[0])
        guard viewer.pageNumber == comments[0].pageIndex + 1 else {
          throw PDFError(.malformed, "Comment navigation failed")
        }
        try await Task.sleep(for: .milliseconds(400))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        if let commentsBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
          content.cacheDisplay(in: content.bounds, to: commentsBitmap)
          if let png = commentsBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("comments.png"), options: .atomic)
          }
        }
        viewer.showPages()

        // Review summary, annotation move/delete, and undo back to baseline.
        let summary = CommentSummary.text(comments: comments)
        guard summary.contains("Comments: 5"), summary.contains("Page 1 · Highlight"),
          summary.contains("Smoke review")
        else { throw PDFError(.malformed, "Review summary formatting failed") }
        try Data(summary.utf8).write(
          to: output.appendingPathComponent("review-summary.txt"), options: .atomic)

        guard let highlightComment = comments.first(where: { $0.subtype == PDFName("Highlight") }),
          let stampComment = comments.first(where: { $0.subtype == PDFName("Stamp") }),
          let highlightRect = highlightComment.annotation.rect
        else { throw PDFError(.malformed, "Expected comments are missing") }

        // Replies and review status (P22-014/P22-015).
        try session.apply(
          PDFTransaction([
            AddReplyCommand(
              pageID: annotationPageID, annotationIndex: highlightComment.annotation.index,
              text: "Smoke reply", author: "smoke", modified: "D:20261010120000Z")
          ]))
        try session.apply(
          PDFTransaction([
            SetAnnotationStateCommand(
              pageID: annotationPageID, annotationIndex: highlightComment.annotation.index,
              state: PDFName("Accepted"))
          ]))
        let threadedComments = session.comments()
        let threads = CommentList.threads(threadedComments, by: CommentFilter())
        guard threadedComments.count == 6,
          threads.contains(where: {
            $0.root.subtype == PDFName("Highlight") && $0.replies.count == 1
          }),
          CommentList.filter(threadedComments, by: CommentFilter(state: PDFName("Accepted")))
            .count == 1,
          threadedComments.contains(where: { $0.contents == "Smoke reply" })
        else { throw PDFError(.malformed, "Reply or review status did not round-trip") }
        first.commentsModel.comments = threadedComments
        viewer.showComments()
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        if let threadsBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
          content.cacheDisplay(in: content.bounds, to: threadsBitmap)
          if let png = threadsBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("threads.png"), options: .atomic)
          }
        }
        viewer.showPages()

        try session.apply(
          PDFTransaction([
            MoveAnnotationCommand(
              pageID: annotationPageID, annotationIndex: highlightComment.annotation.index,
              dx: 12, dy: 8)
          ]))
        try session.apply(
          PDFTransaction([
            DeleteAnnotationCommand(
              pageID: annotationPageID, annotationIndex: stampComment.annotation.index)
          ]))
        let editedGraph = try PDFParser.parse(try first.data(ofType: "com.adobe.pdf")).graph
        let editedAnnotations = try AnnotationInventory.annotations(
          in: editedGraph, pageID: annotationPageID)
        guard editedAnnotations.count == 6,
          let movedHighlight = editedAnnotations.first(where: { $0.subtype == PDFName("Highlight") }
          ),
          let movedRect = movedHighlight.rect,
          abs(movedRect[0] - (highlightRect[0] + 12)) < 1e-9,
          abs(movedRect[1] - (highlightRect[1] + 8)) < 1e-9,
          !editedAnnotations.contains(where: { $0.subtype == PDFName("Stamp") })
        else { throw PDFError(.malformed, "Annotation move/delete did not round-trip") }

        // Flattening: burn appearances into content, keep the link, undo.
        try session.apply(
          PDFTransaction([FlattenAnnotationsCommand(pageID: annotationPageID)]))
        let flattenedData = try first.data(ofType: "com.adobe.pdf")
        let flattenedGraph = try PDFParser.parse(flattenedData).graph
        let remainingAnnotations = try AnnotationInventory.annotations(
          in: flattenedGraph, pageID: annotationPageID)
        guard remainingAnnotations.count == 1,
          remainingAnnotations[0].subtype == PDFName("Link"),
          case .dictionary(let flatPage)? = flattenedGraph.objects[annotationPageID],
          case .array(let flatContents)? = flatPage[PDFName("Contents")],
          flatContents.count >= 2,
          let flatDocument = PDFDocument(data: flattenedData),
          flatDocument.page(at: 0)?.annotations.count == 1
        else { throw PDFError(.malformed, "Flattening did not remove the annotations") }

        guard first.undoEdit(), first.undoEdit(), first.undoEdit(), first.undoEdit(),
          first.undoEdit(), first.undoEdit(),
          try first.data(ofType: "com.adobe.pdf") == annotationBaseline
        else {
          throw PDFError(.malformed, "Annotation editing undo did not restore the baseline bytes")
        }
        guard session.comments().isEmpty else {
          throw PDFError(.malformed, "Annotation undo did not clear the comment list")
        }

        // Ink tool: synthesize a native pointer drag over page 1.
        viewer.isInkToolActive = true
        try await Task.sleep(for: .milliseconds(300))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        if let inkPage = viewer.view.document?.page(at: 0) {
          func windowPoint(_ pageX: Double, _ pageY: Double) -> NSPoint {
            let viewPoint = viewer.view.convert(NSPoint(x: pageX, y: pageY), from: inkPage)
            return viewer.view.convert(viewPoint, to: nil)
          }
          let events: [(NSEvent.EventType, NSPoint)] = [
            (.leftMouseDown, windowPoint(150, 300)),
            (.leftMouseDragged, windowPoint(180, 320)),
            (.leftMouseDragged, windowPoint(210, 300)),
            (.leftMouseUp, windowPoint(210, 300)),
          ]
          for (type, point) in events {
            if let event = NSEvent.mouseEvent(
              with: type, location: point, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
              pressure: 1)
            {
              window.sendEvent(event)
            }
          }
        }
        viewer.isInkToolActive = false
        let inkComments = session.comments()
        guard inkComments.count == 1, inkComments[0].subtype == PDFName("Ink") else {
          throw PDFError(.malformed, "Ink pointer input did not create an annotation")
        }
        let inkGraph = try PDFParser.parse(try first.data(ofType: "com.adobe.pdf")).graph
        guard
          let inkAnnotation = try AnnotationInventory.annotations(
            in: inkGraph, pageID: annotationPageID
          ).first,
          case .array(let inkList)? = inkAnnotation.dictionary[PDFName("InkList")],
          inkList.count == 1
        else { throw PDFError(.malformed, "Ink annotation did not round-trip") }
        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == annotationBaseline else {
          throw PDFError(.malformed, "Ink undo did not restore the baseline bytes")
        }

        // P17-009/P17-011: a preview-only stroke (no mouse-up) draws but
        // commits nothing; cancelling clears the preview and never adds
        // dirt (the dirty flag is compared against its captured state
        // because a commit+undo pair may legitimately leave it set).
        let dirtyBeforePreview = first.isDocumentEdited
        viewer.isInkToolActive = true
        try await Task.sleep(for: .milliseconds(300))
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        if let inkPage = viewer.view.document?.page(at: 0) {
          func inkWindowPoint(_ pageX: Double, _ pageY: Double) -> NSPoint {
            let viewPoint = viewer.view.convert(NSPoint(x: pageX, y: pageY), from: inkPage)
            return viewer.view.convert(viewPoint, to: nil)
          }
          let previewEvents: [(NSEvent.EventType, NSPoint)] = [
            (.leftMouseDown, inkWindowPoint(150, 400)),
            (.leftMouseDragged, inkWindowPoint(180, 420)),
            (.leftMouseDragged, inkWindowPoint(210, 400)),
          ]
          for (type, point) in previewEvents {
            if let event = NSEvent.mouseEvent(
              with: type, location: point, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
              pressure: 1)
            {
              window.sendEvent(event)
            }
          }
          // The transient preview is on screen but nothing is committed.
          guard try first.data(ofType: "com.adobe.pdf") == annotationBaseline,
            !first.isDocumentEdited || dirtyBeforePreview
          else {
            throw PDFError(.malformed, "A preview-only ink stroke dirtied the document")
          }
          guard session.comments().isEmpty else {
            throw PDFError(.malformed, "A preview-only ink stroke committed an annotation")
          }
          // Escape cancels the in-progress stroke.
          if let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53)
          {
            window.sendEvent(escape)
          }
        }
        viewer.isInkToolActive = false
        guard session.comments().isEmpty,
          first.isDocumentEdited == dirtyBeforePreview,
          try first.data(ofType: "com.adobe.pdf") == annotationBaseline
        else { throw PDFError(.malformed, "Cancelled ink preview changed the document") }

        // The earlier rotation round-trip intentionally leaves page 1 at 90°.
        // Direct text editing refuses rotated pages; exercise it on the supported
        // unrotated page, then undo back to the exact earlier baseline.
        viewer.go(to: 1)
        first.rotateCurrentPage(byDegrees: -90)
        let directTextBaseline = try first.data(ofType: "com.adobe.pdf")
        // Text edit through selection mapping and the document path.
        if let textPage = viewer.view.document?.page(at: 0),
          let selection = textPage.selection(for: CGRect(x: 42, y: 705, width: 200, height: 30))
        {
          viewer.view.setCurrentSelection(selection, animate: false)
          guard let (targetPage, target) = first.selectedTextTarget(),
            targetPage == 0, target.text.contains("fixture - page 1")
          else { throw PDFError(.malformed, "Text edit targeting did not resolve the run") }
          guard
            first.replaceText(
              pageIndex: targetPage, runIndex: target.runIndex, with: "Edited"),
            let editedData = try? first.data(ofType: "com.adobe.pdf"),
            let editedGraph = try? PDFParser.parse(editedData).graph,
            case .stream(let editedStream)? = editedGraph.objects[PDFObjectID(5)]
          else { throw PDFError(.malformed, "Text edit did not commit") }
          let editedText = String(decoding: try PDFFilters.decoded(editedStream), as: UTF8.self)
          guard editedText.contains("(Edited)") || editedText.contains("<456469746564>") else {
            throw PDFError(.malformed, "Text edit did not rewrite the operand")
          }
          // P17-016: the selection survives the edit through its own run —
          // same identity, new text — instead of silently vanishing.
          guard let liveSelection = viewer.view.currentSelection,
            liveSelection.string?.contains("Edited") == true
          else { throw PDFError(.malformed, "Selection identity did not survive the edit") }
          guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == directTextBaseline
          else {
            throw PDFError(.malformed, "Text edit undo did not restore the baseline bytes")
          }
          viewer.view.setCurrentSelection(nil, animate: false)
        }

        // P18-021: in-place text editing over the run geometry. The
        // overlay claims text runs in the text tool (P12-017 keeps drag
        // selection in the select tool), and editing begins on click
        // (mouse-up over the same target).
        window.makeKeyAndOrderFront(nil)
        guard KeyboardAudit.invoke("Text Edit Tool"), viewer.activeTool == .textEdit else {
          throw PDFError(.malformed, "Could not arm the text tool for in-place editing")
        }
        if let textPage = viewer.view.document?.page(at: 0) {
          func findPageOverlay(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("PageEditOverlayView") {
              return view
            }
            for sub in view.subviews {
              if let found = findPageOverlay(in: sub) { return found }
            }
            return nil
          }
          let viewPoint = viewer.view.convert(NSPoint(x: 100, y: 718), from: textPage)
          let windowPoint = viewer.view.convert(viewPoint, to: nil)
          guard let overlay = findPageOverlay(in: content),
            overlay.hitTest(overlay.convert(windowPoint, from: nil)) === overlay
          else { throw PDFError(.malformed, "Page edit overlay did not hit-test the run") }
          if let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1),
            let up = NSEvent.mouseEvent(
              with: .leftMouseUp, location: windowPoint, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
              pressure: 1)
          {
            overlay.mouseDown(with: down)
            overlay.mouseUp(with: up)
          }
        }
        try await Task.sleep(for: .milliseconds(200))
        func findTextEditor(in view: NSView) -> InlinePageTextView? {
          if let field = view as? InlinePageTextView,
            field.identifier?.rawValue == "spdf-text-editor"
          {
            return field
          }
          for sub in view.subviews {
            if let found = findTextEditor(in: sub) { return found }
          }
          return nil
        }
        guard let inPlaceEditor = findTextEditor(in: content) else {
          throw PDFError(.malformed, "In-place text editor did not appear")
        }
        viewer.pageTextBeginTyping?()
        let originalInPlaceText = inPlaceEditor.string
        inPlaceEditor.insertText("Inline edit", replacementRange:
          NSRange(location: 0, length: (inPlaceEditor.string as NSString).length))
        guard viewer.pendingEditFinisher?() == true else {
          throw PDFError(.malformed, "Direct page text could not be committed")
        }
        let inPlaceBytes = try first.data(ofType: "com.adobe.pdf")
        try inPlaceBytes.write(to: output.appendingPathComponent("native-inline-edited.pdf"))
        guard let reader = PDFDocument(data: inPlaceBytes),
          reader.findString("Inline edit", withOptions: []).count == 1,
          reader.findString(originalInPlaceText, withOptions: []).isEmpty else {
          throw PDFError(.malformed, "In-place edit did not replace the real saved page text")
        }
        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == directTextBaseline else {
          throw PDFError(.malformed, "In-place text edit undo did not restore the baseline bytes")
        }
        // P17-010/P17-011: Escape cancels the in-place editor without
        // committing or dirtying the document, while Return commits (proven
        // above through the canvas commit). Re-open the editor over the same
        // run and send a real Escape key event.
        let editorDirtyBefore = first.isDocumentEdited
        if let textPage = viewer.view.document?.page(at: 0) {
          func localPageOverlay(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("PageEditOverlayView") {
              return view
            }
            for sub in view.subviews {
              if let found = localPageOverlay(in: sub) { return found }
            }
            return nil
          }
          let viewPoint = viewer.view.convert(NSPoint(x: 100, y: 718), from: textPage)
          let windowPoint = viewer.view.convert(viewPoint, to: nil)
          if let overlay = localPageOverlay(in: content),
            let down = NSEvent.mouseEvent(
              with: .leftMouseDown, location: windowPoint, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
              pressure: 1),
            let up = NSEvent.mouseEvent(
              with: .leftMouseUp, location: windowPoint, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
              pressure: 1)
          {
            overlay.mouseDown(with: down)
            overlay.mouseUp(with: up)
          }
        }
        try await Task.sleep(for: .milliseconds(200))
        guard let escapeEditor = findTextEditor(in: content) else {
          throw PDFError(.malformed, "In-place editor did not reopen for the cancel test")
        }
        escapeEditor.string = "Cancelled edit"
        if let escape = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
          isARepeat: false, keyCode: 53)
        {
          window.sendEvent(escape)
        }
        try await Task.sleep(for: .milliseconds(200))
        guard findTextEditor(in: content) == nil else {
          throw PDFError(.malformed, "Escape did not close the in-place editor")
        }
        guard try first.data(ofType: "com.adobe.pdf") == directTextBaseline,
          first.isDocumentEdited == editorDirtyBefore
        else { throw PDFError(.malformed, "Escape committed the in-place edit") }
        guard KeyboardAudit.invoke("Select Tool"), viewer.activeTool == .select else {
          throw PDFError(.malformed, "Could not restore the select tool after editing")
        }

        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == annotationBaseline else {
          throw PDFError(.malformed, "Direct text testing did not restore the rotated baseline")
        }

        // P17-021: compound page import — one page from the fixture file
        // lands at index 0 as one transaction with remapped resources;
        // undo restores the exact pre-import bytes.
        let importSourceBytes = try Data(contentsOf: firstURL)
        let importBaseline = try first.data(ofType: "com.adobe.pdf")
        let pagesBefore = viewer.pageCount
        guard
          first.importPages(documentBytes: importSourceBytes, pageIndices: [0], atIndex: 0),
          viewer.pageCount == pagesBefore + 1,
          let importedText = viewer.view.document?.page(at: 0)?.string,
          importedText.contains("fixture - page 1")
        else { throw PDFError(.malformed, "Page import did not insert the imported page") }
        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == importBaseline,
          viewer.pageCount == pagesBefore
        else { throw PDFError(.malformed, "Page import undo did not restore the baseline bytes") }

        // P16-014: the selection's rich-text copy comes from the owned core
        // with the run's family/size/color, while plain Copy stays native.
        if let copyPage = viewer.view.document?.page(at: 0),
          let copyMatch = viewer.view.document?.findString("fixture - page 1", withOptions: [])
            .first
        {
          let copySelection = copyPage.selection(for: copyMatch.bounds(for: copyPage))
          viewer.view.setCurrentSelection(copySelection, animate: false)
          guard first.copySelectionAsRichText() else {
            throw PDFError(.malformed, "Styled copy produced no rich text")
          }
          guard let rtf = NSPasteboard.general.string(forType: .rtf),
            rtf.hasPrefix("{\\rtf1"), rtf.contains("Helvetica"),
            rtf.contains("fixture - page 1")
          else { throw PDFError(.malformed, "Rich-text copy is malformed") }
          viewer.view.setCurrentSelection(nil, animate: false)
        }

        // Image context menu and edits (P12-015, P20-008–P20-012).
        checkpoint("image edit and preview safety")
        let imageBaseline = try third.data(ofType: "com.adobe.pdf")
        if let imagePage = imageViewer.view.document?.page(at: 0) {
          // The first placement covers [80,600]–[200,720] in page space.
          let viewPoint = imageViewer.view.convert(NSPoint(x: 140, y: 660), from: imagePage)
          let windowPoint = imageViewer.view.convert(viewPoint, to: nil)
          if let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: imageWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1),
            let menu = imageViewer.view.menu(for: event)
          {
            guard menu.items.contains(where: { $0.title == "Rotate Image 90°" }),
              menu.items.contains(where: { $0.title == "Flip Image Horizontally" }),
              menu.items.contains(where: { $0.title == "Crop Image…" }),
              menu.items.contains(where: { $0.title == "Replace All Shared Instances…" })
            else { throw PDFError(.malformed, "Image context menu is missing operations") }
          } else {
            throw PDFError(.malformed, "Image context menu did not resolve the placement")
          }
        }
        guard third.rotateImage(pageIndex: 0, placementIndex: 0, degrees: 90) else {
          throw PDFError(.malformed, "Image rotation did not commit")
        }
        let rotatedGraph = try PDFParser.parse(try third.data(ofType: "com.adobe.pdf")).graph
        let rotatedPlacements = try ImageInventory.placements(
          in: rotatedGraph, pageID: third.editSession.pageIDs[0])
        guard rotatedPlacements[0].matrix == [0, 120, -120, 0, 200, 600] else {
          throw PDFError(.malformed, "Image rotation did not round-trip")
        }
        guard third.undoEdit(), try third.data(ofType: "com.adobe.pdf") == imageBaseline else {
          throw PDFError(.malformed, "Image rotation undo did not restore the baseline bytes")
        }
        // IMG-01: flip and nondestructive crop use the same session route as
        // the image context menu and undo cleanly.
        guard third.flipImage(pageIndex: 0, placementIndex: 0, horizontal: true) else {
          throw PDFError(.malformed, "Image flip did not commit")
        }
        let flippedGraph = try PDFParser.parse(try third.data(ofType: "com.adobe.pdf")).graph
        let flippedPlacements = try ImageInventory.placements(
          in: flippedGraph, pageID: third.editSession.pageIDs[0])
        guard flippedPlacements[0].matrix == [-120, 0, 0, 120, 200, 600] else {
          throw PDFError(.malformed, "Image flip did not round-trip")
        }
        guard third.undoEdit(), try third.data(ofType: "com.adobe.pdf") == imageBaseline else {
          throw PDFError(.malformed, "Image flip undo did not restore the baseline bytes")
        }
        guard
          third.cropImage(
            pageIndex: 0, placementIndex: 0, unitRect: [0.25, 0.25, 0.75, 0.75])
        else { throw PDFError(.malformed, "Image crop did not commit") }
        let croppedBytes = try third.data(ofType: "com.adobe.pdf")
        guard String(decoding: croppedBytes, as: UTF8.self).contains(" W n") else {
          throw PDFError(.malformed, "Image crop did not write a clip path")
        }
        guard third.undoEdit(), try third.data(ofType: "com.adobe.pdf") == imageBaseline else {
          throw PDFError(.malformed, "Image crop undo did not restore the baseline bytes")
        }
        // IMG-01: numeric size and position use the same undoable route.
        guard
          third.setImageGeometry(
            pageIndex: 0, placementIndex: 0, x: 90, y: 610, width: 60, height: 60)
        else { throw PDFError(.malformed, "Image geometry did not commit") }
        let geometryGraph = try PDFParser.parse(try third.data(ofType: "com.adobe.pdf")).graph
        let geometryPlacements = try ImageInventory.placements(
          in: geometryGraph, pageID: third.editSession.pageIDs[0])
        let geometryBounds = geometryPlacements[0].bounds
        guard abs(geometryBounds[0] - 90) < 0.01, abs(geometryBounds[1] - 610) < 0.01,
          abs(geometryBounds[2] - 150) < 0.01, abs(geometryBounds[3] - 670) < 0.01
        else { throw PDFError(.malformed, "Image geometry did not round-trip") }
        guard third.undoEdit(), try third.data(ofType: "com.adobe.pdf") == imageBaseline else {
          throw PDFError(.malformed, "Image geometry undo did not restore the baseline bytes")
        }
        // Preview-first gestures (joint session): rotation keeps the
        // footprint inside the page, and overlay drags on a native image
        // never mutate the document in any tool mode.
        let rotatedBounds = rotatedPlacements[0].bounds
        if let mediaPage = imageViewer.view.document?.page(at: 0) {
          let mediaBox = mediaPage.bounds(for: .mediaBox)
          guard rotatedBounds.count == 4, rotatedBounds[0] >= mediaBox.minX,
            rotatedBounds[1] >= mediaBox.minY, rotatedBounds[2] <= mediaBox.maxX,
            rotatedBounds[3] <= mediaBox.maxY
          else { throw PDFError(.malformed, "Rotated image left the page") }
        }
        func findGraphicOverlay(in view: NSView) -> GraphicSelectionOverlayView? {
          if let overlay = view as? GraphicSelectionOverlayView { return overlay }
          for sub in view.subviews {
            if let found = findGraphicOverlay(in: sub) { return found }
          }
          return nil
        }
        do {
          guard let dragPage = imageViewer.view.document?.page(at: 0),
            let overlayRoot = imageWindow.contentView,
            let overlay = findGraphicOverlay(in: overlayRoot)
          else {
            throw PDFError(.malformed, "Native-image drag regression has no graphics overlay")
          }
          let dragFromPage = NSPoint(x: 140, y: 660)
          let dragFromView = imageViewer.view.convert(dragFromPage, from: dragPage)
          let dragFromWindow = imageViewer.view.convert(dragFromView, to: nil)
          let dragStart = overlay.convert(dragFromWindow, from: nil)
          let dragEnd = NSPoint(x: dragStart.x + 40, y: dragStart.y + 30)
          func syntheticDrag() {
            let endWindow = overlay.convert(dragEnd, to: nil)
            guard
              let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: dragFromWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: imageWindow.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1),
              let dragged = NSEvent.mouseEvent(
                with: .leftMouseDragged, location: endWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: imageWindow.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: endWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: imageWindow.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)
            else { return }
            overlay.mouseDown(with: down)
            overlay.mouseDragged(with: dragged)
            overlay.mouseUp(with: up)
          }
          // Supported native images now participate in the canvas selection.
          // Select mode may select them but must not mutate the document.
          guard overlay.hitTest(dragStart) != nil else {
            throw PDFError(.malformed, "Native image was not exposed to the graphics overlay")
          }
          let dragBaseline = try third.data(ofType: "com.adobe.pdf")
          guard imageViewer.activeTool == .select else {
            throw PDFError(.malformed, "Image window did not start in the select tool")
          }
          syntheticDrag()
          guard try third.data(ofType: "com.adobe.pdf") == dragBaseline else {
            throw PDFError(.malformed, "Select-mode drag mutated the document")
          }
          imageWindow.makeKeyAndOrderFront(nil)
          guard KeyboardAudit.invoke("Image Edit Tool"),
            imageViewer.activeTool == .imageEdit
          else { throw PDFError(.malformed, "Could not arm the image edit tool") }
          guard overlay.hitTest(dragStart) != nil else {
            throw PDFError(.malformed, "Native image disappeared from image edit mode")
          }
          syntheticDrag()
          guard try third.data(ofType: "com.adobe.pdf") != dragBaseline,
            imageViewer.selectedGraphics.count == 1,
            imageViewer.selectedGraphics[0].imagePlacementIndex != nil,
            third.undoEdit(),
            try third.data(ofType: "com.adobe.pdf") == dragBaseline
          else {
            throw PDFError(.malformed, "Image-edit drag on a native image was not one undoable move")
          }
          guard KeyboardAudit.invoke("Select Tool"), imageViewer.activeTool == .select else {
            throw PDFError(.malformed, "Could not restore the select tool after dragging")
          }
        }
        // Import a generated PNG, replace one instance, then all shared ones.
        let png = Self.tinyPNGData()
        guard third.replaceImage(pageIndex: 0, placementIndex: 0, with: png, shared: false) else {
          throw PDFError(.malformed, "Instance replacement did not commit")
        }
        var replacedGraph = try PDFParser.parse(try third.data(ofType: "com.adobe.pdf")).graph
        var placements = try ImageInventory.placements(
          in: replacedGraph, pageID: third.editSession.pageIDs[0])
        guard placements.count == 2, placements[0].imageID != placements[1].imageID else {
          throw PDFError(.malformed, "Instance replacement did not copy on write")
        }
        guard third.undoEdit(), try third.data(ofType: "com.adobe.pdf") == imageBaseline,
          third.replaceImage(pageIndex: 0, placementIndex: 0, with: png, shared: true)
        else { throw PDFError(.malformed, "Shared replacement did not commit") }
        replacedGraph = try PDFParser.parse(try third.data(ofType: "com.adobe.pdf")).graph
        placements = try ImageInventory.placements(
          in: replacedGraph, pageID: third.editSession.pageIDs[0])
        let page2Placements = try ImageInventory.placements(
          in: replacedGraph, pageID: third.editSession.pageIDs[1])
        guard placements[0].imageID == placements[1].imageID,
          placements[0].imageID == page2Placements[0].imageID,
          case .stream(let sharedImage)? = replacedGraph.objects[placements[0].imageID],
          sharedImage.dictionary[PDFName("Width")] == .integer(4),
          sharedImage.dictionary[PDFName("Height")] == .integer(2)
        else { throw PDFError(.malformed, "Shared replacement did not update every reference") }
        guard third.undoEdit(), try third.data(ofType: "com.adobe.pdf") == imageBaseline else {
          throw PDFError(.malformed, "Shared replacement undo did not restore the baseline bytes")
        }

        // OCR (P26): recognize when Vision is available, otherwise use
        // caller-supplied lines, then invalidate the layer on image replace.
        var ocrLines = [
          SearchableTextLine(
            text: "Scanned invoice 42", rect: [100, 600, 300, 620], confidence: 0.9)
        ]
        if let ocrDocument = third.viewer?.view.document {
          do {
            let results = try OCRJob.run(
              document: ocrDocument, pageIndexes: [0], languages: ["en-US"], level: .fast)
            if let first = results.first, !first.lines.isEmpty {
              ocrLines = first.lines.map {
                SearchableTextLine(text: $0.text, rect: $0.rect, confidence: $0.confidence)
              }
            }
          } catch let error as PDFError {
            // Recognition is unavailable in this environment; the layer path
            // below still exercises the real writer.
            guard error.kind == .unsupported else { throw error }
          }
        }
        guard third.applySearchableTextLayer(pageIndex: 0, lines: ocrLines, replacing: false) else {
          throw PDFError(.malformed, "Searchable text layer did not commit")
        }
        let layeredData = try third.data(ofType: "com.adobe.pdf")
        let layeredGraph = try PDFParser.parse(layeredData).graph
        guard
          OCRLayer.hasGeneratedLayer(in: layeredGraph, pageID: third.editSession.pageIDs[0]),
          let layeredDocument = PDFDocument(data: layeredData),
          layeredDocument.string?.contains(ocrLines[0].text) == true
        else { throw PDFError(.malformed, "Searchable text layer did not extract in PDFKit") }
        // P26-023: replacing the scan drops the generated layer first.
        guard third.replaceImage(pageIndex: 0, placementIndex: 0, with: png, shared: false) else {
          throw PDFError(.malformed, "Image replacement did not commit")
        }
        let replacedScanGraph = try PDFParser.parse(
          try third.data(ofType: "com.adobe.pdf")
        ).graph
        guard
          !OCRLayer.hasGeneratedLayer(
            in: replacedScanGraph, pageID: third.editSession.pageIDs[0])
        else { throw PDFError(.malformed, "Image replacement did not invalidate the OCR layer") }
        guard third.undoEdit(), third.undoEdit(),
          try third.data(ofType: "com.adobe.pdf") == imageBaseline
        else { throw PDFError(.malformed, "OCR edits did not undo to the baseline bytes") }

        checkpoint("image safety passed; form filling")
        // Form filling (P24): inventory, text/choice fill, checkbox, reset,
        // flatten, and undo.
        let formBaseline = try formDocument.data(ofType: "com.adobe.pdf")
        checkpoint("form baseline loaded")
        guard formDocument.editSession.formFields().count == 10 else {
          throw PDFError(.malformed, "Form field inventory is incomplete")
        }
        checkpoint("form inventory passed")
        formDocument.fillFormText(fieldName: "name", text: "Smoke fill")
        checkpoint("text field fill returned")
        let filledFormData = try formDocument.data(ofType: "com.adobe.pdf")
        let filledFormGraph = try PDFParser.parse(filledFormData).graph
        let filledFields = try FormInventory.fields(
          in: filledFormGraph, pageIDs: formDocument.editSession.pageIDs)
        guard
          filledFields.first(where: { $0.name == "name" })?.stringValue == "Smoke fill",
          let filledFormDocument = PDFDocument(data: filledFormData),
          filledFormDocument.page(at: 0)?.annotations
            .first(where: { $0.widgetFieldType == PDFAnnotationWidgetSubtype.text })?
            .widgetStringValue == "Smoke fill"
        else { throw PDFError(.malformed, "Filled form value did not round-trip") }
        formDocument.setFormButton(fieldName: "agree", isOn: true)
        checkpoint("checkbox fill returned")
        let toggledFormGraph = try PDFParser.parse(
          try formDocument.data(ofType: "com.adobe.pdf")
        ).graph
        let toggledFields = try FormInventory.fields(
          in: toggledFormGraph, pageIDs: formDocument.editSession.pageIDs)
        guard toggledFields.first(where: { $0.name == "agree" })?.isChecked == true else {
          throw PDFError(.malformed, "Checkbox state did not round-trip")
        }
        // FRM-03: FDF/XFDF exchange carries the filled values.
        let exchangeValues = try FormValues.values(
          in: toggledFormGraph, pageIDs: formDocument.editSession.pageIDs)
        for format in FormDataExchange.Format.allCases {
          let data = FormDataExchange.export(exchangeValues, format: format)
          let parsed = try FormDataExchange.parse(data, format: format)
          guard parsed.contains(where: { $0.name == "name" && $0.value == "Smoke fill" }),
            parsed.contains(where: { $0.name == "agree" && $0.value == "Yes" })
          else { throw PDFError(.malformed, "\(format.title) form exchange did not round-trip") }
        }
        formDocument.setFormChoice(fieldName: "department", exportValue: "Support")
        checkpoint("choice fill returned")
        let choiceGraph = try PDFParser.parse(
          try formDocument.data(ofType: "com.adobe.pdf")
        ).graph
        let choiceFields = try FormInventory.fields(
          in: choiceGraph, pageIDs: formDocument.editSession.pageIDs)
        guard choiceFields.first(where: { $0.name == "department" })?.stringValue == "Support",
          formDocument.orphanedFormWidgetCount() == 1
        else { throw PDFError(.malformed, "Choice selection or orphan reporting failed") }

        // P24-013: click the notes widget and type through the native editor.
        if let formPage = formViewer.view.document?.page(at: 0) {
          let viewPoint = formViewer.view.convert(NSPoint(x: 200, y: 560), from: formPage)
          let windowPoint = formViewer.view.convert(viewPoint, to: nil)
          for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
              with: type, location: windowPoint, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: formWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
              pressure: 1)
            {
              formWindow.sendEvent(event)
            }
          }
        }
        try await Task.sleep(for: .milliseconds(200))
        func findFormEditor(in view: NSView) -> NSTextField? {
          if let field = view as? NSTextField,
            field.identifier?.rawValue == "spdf-form-editor"
          {
            return field
          }
          for sub in view.subviews {
            if let found = findFormEditor(in: sub) { return found }
          }
          return nil
        }
        guard let formContent = formWindow.contentView,
          let editor = findFormEditor(in: formContent)
        else { throw PDFError(.malformed, "In-page form editor did not appear") }
        editor.stringValue = "Inline note"
        editor.sendAction(editor.action, to: editor.target)
        let inlineGraph = try PDFParser.parse(
          try formDocument.data(ofType: "com.adobe.pdf")
        ).graph
        let inlineFields = try FormInventory.fields(
          in: inlineGraph, pageIDs: formDocument.editSession.pageIDs)
        guard inlineFields.first(where: { $0.name == "notes" })?.stringValue == "Inline note"
        else { throw PDFError(.malformed, "In-page form edit did not commit") }
        checkpoint("inline form edit passed")

        formViewer.showForms()
        try await Task.sleep(for: .milliseconds(300))
        if let formsContent = formDocument.windowControllers.first?.window?.contentView {
          formsContent.layoutSubtreeIfNeeded()
          formsContent.displayIfNeeded()
          if let formsBitmap = formsContent.bitmapImageRepForCachingDisplay(
            in: formsContent.bounds)
          {
            formsContent.cacheDisplay(in: formsContent.bounds, to: formsBitmap)
            if let png = formsBitmap.representation(using: .png, properties: [:]) {
              try png.write(to: output.appendingPathComponent("forms.png"), options: .atomic)
            }
          }
        }
        checkpoint("forms sidebar render passed")
        formViewer.showPages()
        formDocument.resetForm()
        let resetGraph = try PDFParser.parse(
          try formDocument.data(ofType: "com.adobe.pdf")
        ).graph
        let resetFields = try FormInventory.fields(
          in: resetGraph, pageIDs: formDocument.editSession.pageIDs)
        guard resetFields.first(where: { $0.name == "name" })?.stringValue == "",
          resetFields.first(where: { $0.name == "notes" })?.stringValue == "default notes",
          resetFields.first(where: { $0.name == "department" })?.stringValue == "Sales",
          resetFields.first(where: { $0.name == "agree" })?.buttonState == PDFName("Off")
        else { throw PDFError(.malformed, "Form reset did not restore defaults") }
        checkpoint("form reset passed")
        guard formDocument.applyFlattenForm() else {
          throw PDFError(.malformed, "Form flattening did not commit")
        }
        checkpoint("form flatten returned")
        let flattenedFormData = try formDocument.data(ofType: "com.adobe.pdf")
        let flattenedFormGraph = try PDFParser.parse(flattenedFormData).graph
        guard
          try FormInventory.fields(
            in: flattenedFormGraph, pageIDs: formDocument.editSession.pageIDs
          ).isEmpty,
          !(try AnnotationInventory.annotations(
            in: flattenedFormGraph, pageID: formDocument.editSession.pageIDs[0]
          )).contains(where: { $0.subtype == PDFName("Widget") }),
          let flattenedDocument = PDFDocument(data: flattenedFormData),
          flattenedDocument.page(at: 0)?.annotations.contains(where: { $0.type == "Widget" })
            == false
        else { throw PDFError(.malformed, "Form flattening did not remove the widgets") }
        guard formDocument.undoEdit(), formDocument.undoEdit(), formDocument.undoEdit(),
          formDocument.undoEdit(), formDocument.undoEdit(), formDocument.undoEdit(),
          try formDocument.data(ofType: "com.adobe.pdf") == formBaseline
        else { throw PDFError(.malformed, "Form edits did not undo to the baseline bytes") }
        checkpoint("form undo passed")

        // Viewer search: matches, navigation, and clearing.
        viewer.showSearch()
        viewer.searchText = "fixture - page"
        viewer.runSearch()
        guard viewer.searchMatchCount == 3, viewer.searchIndex == 1 else {
          throw PDFError(.malformed, "Viewer search did not find the expected matches")
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        if let searchBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
          content.cacheDisplay(in: content.bounds, to: searchBitmap)
          if let png = searchBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("search.png"), options: .atomic)
          }
        }
        viewer.searchNext()
        guard viewer.searchIndex == 2 else {
          throw PDFError(.malformed, "Viewer search navigation failed")
        }
        viewer.hideSearch()
        guard viewer.searchMatchCount == 0 else {
          throw PDFError(.malformed, "Viewer search did not clear")
        }
        checkpoint("viewer search passed")

        // Recovery (P10): snapshot a dirty document, restore its bytes, and
        // discard after an explicit decision.
        let recoveryBaseline = try first.data(ofType: "com.adobe.pdf")
        first.rotateCurrentPage(byDegrees: 90)
        first.snapshotRecoveryNow()
        let recoveryKey = first.recoveryKey
        guard let recoveredBytes = try first.recoveryStore.latestBytes(for: recoveryKey),
          let recoveredGraph = try? PDFParser.parse(recoveredBytes).graph,
          recoveredGraph == first.editSession.currentGraph
        else { throw PDFError(.malformed, "Recovery snapshot did not round-trip") }
        guard first.undoEdit(), try first.data(ofType: "com.adobe.pdf") == recoveryBaseline else {
          throw PDFError(.malformed, "Recovery edit undo did not restore the baseline bytes")
        }
        first.discardRecoveryRecords()
        guard try first.recoveryStore.latest(for: recoveryKey) == nil else {
          throw PDFError(.malformed, "Recovery discard did not clear the record")
        }
        checkpoint("recovery passed")

        // P10-012: external modification detection before overwriting.
        if let firstURL = first.fileURL {
          try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: firstURL.path)
          guard first.destinationChangedExternally() else {
            throw PDFError(.malformed, "External modification was not detected")
          }
        }
        checkpoint("external modification check passed")

        // P27: region redaction removes targeted text and paints a fill;
        // sanitization writes a full rewrite with no earlier revisions.
        let redactionBaseline = try first.data(ofType: "com.adobe.pdf")
        guard first.applyRedaction(pageIndex: 0, regions: [[40, 700, 570, 745]]) else {
          throw PDFError(.malformed, "Redaction did not commit")
        }
        let redactedBytes = try first.data(ofType: "com.adobe.pdf")
        // SAF-02: redaction forces a secure full rewrite, so the earlier
        // revision with the removed text is not part of the saved bytes.
        guard first.editSession.requiresSecureRewrite,
          redactedBytes.range(of: Data("/Prev".utf8)) == nil
        else { throw PDFError(.malformed, "Redaction save was not a secure full rewrite") }
        // PDFKit reads the current revision, where the text is gone.
        guard let redactedDocument = PDFDocument(data: redactedBytes),
          let redactedPageText = redactedDocument.page(at: 0)?.string,
          !redactedPageText.contains("fixture - page 1"),
          redactedPageText.contains("Original Swift-generated content"),
          (try? PDFParser.parse(redactedBytes)) != nil
        else { throw PDFError(.malformed, "Redaction did not remove the targeted text") }
        // SAF-01: the menu route must sanitize a staged graph. Seed metadata,
        // a script action, and an unreachable image on the session, then write
        // the copy without applying SanitizeDocumentCommand to the session.
        try first.editSession.apply(PDFTransaction([SeedHiddenDataForSanitizeCheck()]))
        let seededGraph = first.editSession.currentGraph
        let sanitizedURL = output.appendingPathComponent("sanitized.pdf")
        let sanitizeReport = try first.writeSanitizedCopy(to: sanitizedURL)
        guard first.editSession.currentGraph == seededGraph else {
          throw PDFError(.malformed, "Sanitized copy mutated the session graph")
        }
        guard sanitizeReport.removedMetadata >= 1, sanitizeReport.removedScripts >= 1 else {
          throw PDFError(.malformed, "Sanitized copy did not report hidden-data removal")
        }
        let sanitizedData = try Data(contentsOf: sanitizedURL)
        guard let sanitizedParsed = try? PDFParser.parse(sanitizedData),
          sanitizedParsed.graph.objects[PDFObjectID(900)] == nil,
          sanitizedParsed.graph.objects[PDFObjectID(901)] == nil,
          sanitizedParsed.graph.objects[PDFObjectID(902)] == nil,
          sanitizedParsed.graph.trailer[PDFName("Info")] == nil,
          sanitizedData.range(of: Data("/Prev".utf8)) == nil,
          sanitizedData.range(of: Data("(sPDF Editor fixture - page 1)".utf8)) == nil,
          sanitizedData.range(of: Data("sanitize-seed-".utf8)) == nil
        else { throw PDFError(.malformed, "Sanitized copy is not a clean full rewrite") }
        while first.editSession.canUndo,
          try first.data(ofType: "com.adobe.pdf") != redactionBaseline
        {
          _ = first.undoEdit()
        }
        guard !first.editSession.requiresSecureRewrite,
          try first.data(ofType: "com.adobe.pdf") == redactionBaseline
        else {
          throw PDFError(.malformed, "Redaction undo did not restore the baseline bytes")
        }
        checkpoint("redaction and sanitization passed")

        // P28-016–P28-019: export an AES-256 encrypted copy and verify it
        // through the owned core and the independent reader.
        let encryptedCopyURL = output.appendingPathComponent("encrypted-copy.pdf")
        try first.writeEncryptedCopy(
          to: encryptedCopyURL, userPassword: "smoke", ownerPassword: "smokemaster")
        let encryptedCopyData = try Data(contentsOf: encryptedCopyURL)
        guard encryptedCopyData.range(of: Data("sPDF Editor fixture".utf8)) == nil,
          (try? PDFParser.parse(encryptedCopyData)) == nil
        else {
          throw PDFError(
            .malformed, "The encrypted export leaked plaintext or opened without a password")
        }
        guard let encryptedCopyDocument = PDFDocument(data: encryptedCopyData),
          encryptedCopyDocument.isLocked,
          encryptedCopyDocument.unlock(withPassword: "smoke"),
          encryptedCopyDocument.string?.contains("sPDF Editor fixture - page 1") == true
        else {
          throw PDFError(
            .malformed, "The encrypted export did not unlock in the independent reader")
        }
        let encryptedCopyGraph = try PDFParser.parse(encryptedCopyData, password: "smoke")
        guard encryptedCopyGraph.encryption?.profile == .aes256,
          encryptedCopyGraph.pageCount == 3
        else {
          throw PDFError(.malformed, "The encrypted export did not round-trip through the core")
        }
        checkpoint("encrypted export passed")

        // P30-016–P30-020/P30-026: sign the clean document through the app
        // path with a temporary keychain identity and validate the output.
        guard let signingMaterial = SmokeSigningIdentity.make() else {
          throw PDFError(.malformed, "Smoke signing material could not be created")
        }
        defer { signingMaterial.cleanUp() }
        let signedCopyURL = output.appendingPathComponent("signed-copy.pdf")
        try first.signDocument(
          to: signedCopyURL, identity: signingMaterial.identity,
          options: PDFSigningOptions(
            fieldName: "SmokeSignature", pageIndex: 0, reason: "smoke"))
        let signedCopyData = try Data(contentsOf: signedCopyURL)
        guard signedCopyData.starts(with: try Data(contentsOf: firstURL)),
          let signedPDF = PDFDocument(data: signedCopyData), signedPDF.pageCount == 3
        else { throw PDFError(.malformed, "The signed copy is malformed") }
        let signedParsed = try PDFParser.parse(signedCopyData)
        let signedSignatures = try PDFSignatureInventory.signatures(in: signedParsed.graph)
        guard signedSignatures.count == 1, signedSignatures[0].fieldName == "SmokeSignature" else {
          throw PDFError(.malformed, "The signed copy has no signature")
        }
        let signedValidation = PDFSignatureValidator.validate(
          signedSignatures[0], source: signedCopyData, finalGraph: signedParsed.graph,
          trustedAnchors: [signingMaterial.caCertificate])
        guard signedValidation.crypto == .valid, signedValidation.trust == .trusted else {
          throw PDFError(.malformed, "The signed copy failed validation")
        }
        checkpoint("digital signing passed")

        // P31: lossless optimization shrinks a copy without changing text,
        // and an already-optimized input is never rewritten.
        let optimizedURL = output.appendingPathComponent("optimized.pdf")
        let optimizationReport = try first.optimizeDocument(to: optimizedURL)
        guard optimizationReport.isImprovement, optimizationReport.recompressedStreams > 0,
          FileManager.default.fileExists(atPath: optimizedURL.path)
        else { throw PDFError(.malformed, "Optimization did not improve the document") }
        let optimizedData = try Data(contentsOf: optimizedURL)
        if optimizationReport.usedCompressedOutput,
          optimizedData.range(of: Data("/ObjStm".utf8)) == nil
        {
          throw PDFError(.malformed, "Compressed output was reported but not written")
        }
        let originalThreePages = try Data(contentsOf: firstURL)
        guard optimizedData.count < originalThreePages.count,
          let optimizedDocument = PDFDocument(data: optimizedData),
          optimizedDocument.string == PDFDocument(data: originalThreePages)?.string
        else { throw PDFError(.malformed, "The optimized copy changed the document text") }
        let optimizedParsed = try PDFParser.parse(optimizedData)
        let (_, _, secondReport) = try PDFOptimizer.lossless(
          optimizedParsed.graph, sourceBytes: optimizedData.count)
        guard !secondReport.isImprovement else {
          throw PDFError(.malformed, "Optimizing an optimized document reported an improvement")
        }
        // P31-024: the original file stays untouched until verification passes.
        guard try Data(contentsOf: firstURL) == originalThreePages else {
          throw PDFError(.malformed, "Optimization modified the original document")
        }
        checkpoint("optimization passed")

        // P32: compare the three-page document against the one-page fixture,
        // verify the change list, write the local report, and capture a
        // rendered difference image.
        let comparison = try first.compareWithDocument(at: secondURL)
        guard comparison.left.pageCount == 3, comparison.right.pageCount == 1,
          comparison.changes(kinds: [.pageDeleted]).count == 2,
          comparison.pageMapping.contains(where: { $0.status == .matched })
        else { throw PDFError(.malformed, "Document comparison produced unexpected results") }
        let comparisonReport = PDFComparisonReport.text(comparison)
        guard comparisonReport.contains("page deleted"),
          !comparisonReport.contains("Original Swift-generated content")
        else { throw PDFError(.malformed, "The comparison report leaked unchanged text") }
        try Data(comparisonReport.utf8).write(
          to: output.appendingPathComponent("comparison-report.txt"), options: .atomic)
        if let difference = PageDifferenceRenderer.difference(
          left: originalThreePages, right: try Data(contentsOf: formURL), pageIndex: 0,
          size: NSSize(width: 400, height: 520), tolerance: 2),
          difference.changedPixelRatio > 0
        {
          let differenceBitmap = NSBitmapImageRep(cgImage: difference.image)
          if let png = differenceBitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("difference.png"), options: .atomic)
          }
        } else {
          throw PDFError(.malformed, "The rendered difference image was empty")
        }
        checkpoint("document comparison passed")

        // P32-002/P32-003/P32-005/P32-008/P32-021: the comparison workspace
        // follows the mapping, navigates changes, corrects pairs manually,
        // and renders overlay/blink modes.
        let comparisonSession = try first.openComparisonWindow(with: secondURL)
        guard comparisonSession.result.pageMapping.count == 3,
          comparisonSession.leftDocument.pageCount == 3,
          comparisonSession.rightDocument.pageCount == 1
        else { throw PDFError(.malformed, "The comparison workspace did not open") }
        comparisonSession.leftPageChanged(to: 0)
        guard comparisonSession.rightPageIndex == 0 else {
          throw PDFError(.malformed, "Synchronized navigation did not follow the mapping")
        }
        comparisonSession.leftPageChanged(to: 1)
        guard comparisonSession.rightPageIndex == 0 else {
          throw PDFError(.malformed, "A deleted page moved the other pane")
        }
        comparisonSession.selectNextChange()
        guard comparisonSession.selectedChangeIndex == 0 else {
          throw PDFError(.malformed, "Change navigation did not select the first change")
        }
        comparisonSession.selectPreviousChange()
        guard comparisonSession.selectedChangeIndex == 0 else {
          throw PDFError(.malformed, "Previous change navigation failed")
        }
        try comparisonSession.correctMapping(leftIndex: 1, toRightIndex: 0)
        guard comparisonSession.mapping.first(where: { $0.leftIndex == 1 })?.rightIndex == 0,
          comparisonSession.changes.contains(where: {
            [.textChanged, .textRemoved, .textAdded].contains($0.kind)
          })
        else { throw PDFError(.malformed, "Manual page mapping correction failed") }
        try comparisonSession.resetMapping()
        guard comparisonSession.mapping.contains(where: { $0.status == .deleted }) else {
          throw PDFError(.malformed, "Reset mapping did not restore the automatic mapping")
        }
        comparisonSession.mode = .overlay
        guard comparisonSession.differenceImage() != nil else {
          throw PDFError(.malformed, "Overlay mode produced no difference image")
        }
        comparisonSession.mode = .blink
        comparisonSession.mode = .sideBySide
        if let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu,
          !viewMenu.items.contains(where: { $0.title == "Next Change" })
        {
          throw PDFError(.malformed, "Change navigation menu commands are missing")
        }
        if let comparisonWindow = first.comparisonWindow,
          let comparisonContent = comparisonWindow.contentView
        {
          comparisonContent.layoutSubtreeIfNeeded()
          comparisonContent.displayIfNeeded()
          if let bitmap = comparisonContent.bitmapImageRepForCachingDisplay(
            in: comparisonContent.bounds)
          {
            comparisonContent.cacheDisplay(in: comparisonContent.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
              try png.write(to: output.appendingPathComponent("comparison.png"), options: .atomic)
            }
          }
        } else {
          throw PDFError(.malformed, "The comparison window was not found")
        }
        checkpoint("comparison workspace passed")

        let workspaceRepairs = try await WorkspaceSmoke.checks(output: output)
        checkpoint("workspace repair smoke passed")
        let report: [String: Any] = [
          "workspaceRepairs": workspaceRepairs,
          "status": "passed", "app": "sPDF Editor", "windows": controller.documents.count,
          "pageCounts": [viewer.pageCount, secondViewer.pageCount],
          "navigation": "passed", "originalBytes": "preserved", "nativeWrite": "preserved",
          "corePages": try PDFParser.parse(saved).pageCount,
          "fitPageScale": viewer.scale,
          "twoDocumentOpeningDuration": String(describing: openingDuration),
          "editPipeline": "rotate-undo-redo passed", "editedRotation": 90,
          "editedSave": "verified",
          "structuralEdits": "reorder-insert-delete undo passed",
          "textEdit": "replace-undo-redo passed",
          "annotation": "6 created, reply/status, move/delete, flatten, undo passed",
          "comments": "5 listed, filter, navigate, undo clears",
          "reviewSummary": "written with 5 comments",
          "ink": "pointer stroke committed and undone",
          "textEditUI": "selection mapped, run replaced, undo passed",
          "imageEdits": "menu, rotate, import, shared replace, undo passed",
          "ocr": "layer applied, extracted, invalidated on replace",
          "recovery": "snapshot, restore bytes, discard passed",
          "inPlaceText": "run editor committed and undone",
          "saveVerification": "verified temp writes",
          "externalChange": "detected",
          "forms": "10 fields, inline edit, reset, flatten, undo passed",
          "search": "3 matches, next navigates, clear",
          "redaction": "region cleared text, fill painted, undo passed",
          "sanitize": "full rewrite without earlier revisions",
          "encryption": "inventory, locked view, wrong-password refusal, unlock passed",
          "protectedEditing": "unlocked edit, protected save, lock, no recovery snapshots",
          "signatures": "1 inventoried, crypto valid, trust separate, panel shown",
          "encryptedExport": "AES-256 copy, independent unlock passed",
          "signing": "incremental signed copy, original bytes preserved, validated",
          "optimization": "lossless copy smaller, text preserved, no rewrite when not smaller",
          "comparison": "mapping, 2 deleted pages, report written, difference image",
          "comparisonWorkspace":
            "sync navigation, change navigation, mapping correction, overlay, menu commands",
          "structure":
            "tagged tree resolved, PDF/UA valid, inspector shown, role/artifact edits applied; assisted tagging reviewed and an accepted heading became confirmed structure",
          "accessibility":
            "AX audit of \(accessibility.windowsAudited) windows: \(accessibility.interactiveCount) interactive controls all labeled, \(accessibility.elementCount) elements; keyboard map verified (\(keyboard.shortcutCount) shortcuts) and menu actions invoked",
          "textExport": "3 pages in reading order, Unicode intact, form-feed separators",
          "imageExport": "3 deterministic PNGs at 72 dpi, reopened at 612x792",
          "htmlExport":
            "semantic structure + link preserved and script-free; appearance mode packaged 3 page images",
          "attachments":
            "2 inventoried with types and sizes; byte-exact extraction with traversal-shaped names sanitized",
          "printExport":
            "3-page print PDF through the native pipeline; page boxes and text verified by an independent reader",
          "imageExtraction":
            "3 stored-sample PNGs with original provenance at the source resolution (2x2), deterministic names",
          "fonts":
            "installed/embedded/missing statuses resolved with fallbacks and paid-font warnings; missing font surfaced; panel shown",
          "formAuthoring":
            "authored text field with properties (flags, style, max length, declarative format), formatted fill, hierarchical rename, duplication, tab-order editing, alignment, and deletion through the document path",
          "paragraphs":
            "reconstructed heading and flowing candidates with confidences and source-linked runs; a reflow round-trip (with a source map) was applied and undone to the original bytes",
          "docxExport":
            "\(docxBlocks) blocks reconstructed into a deterministic DOCX package; unzip and textutil read the document part independently and the source bytes are unchanged",
          "docxAppearance":
            "\(appearanceBlocks) blocks in appearance mode; the package passes unzip integrity",
          "docxPreview":
            "\(preview.totalCount) blocks previewed with \(preview.ambiguousCount) ambiguous, bounded snippets, and limitations listed",
          "tables":
            "\(detectedTables) tables detected on the open document; the review model corrected a cell and accepted the table",
          "inventory":
            "\(pageAttributes.count) page attributes with inherited boxes; \(inventoryAssessment.summary); metadata \(inventoryFacts.metadata.isEmpty ? "absent" : "present")",
          "graphicalSignature":
            "placed as a stamp annotation with the disclosure text; no digital-signature claim; source bytes unchanged",
          "preflightChecks":
            "\(preflightChecks.errorCount) errors / \(preflightChecks.warningCount) warnings across \(preflightChecks.findings.count) checks; read-only and no PDF/X claim",
          "archival":
            "\(derivativePlan.transformations.count) transformations planned, \(stagedDerivative.applied.count) applied; independent validation \(archivalValidation.map { $0.isCompliant ? "compliant" : "not compliant (\($0.failedRules) failed rules)" } ?? "validator unavailable"); no PDF/A identifier written",
          "accessibilityAudit":
            "\(accessibilityAudit.errorCount) errors / \(accessibilityAudit.warningCount) warnings with 7 human-review requirements; independent UA validation \(uaValidation.map { $0.isCompliant ? "compliant" : "not compliant" } ?? "validator unavailable")",
          "compatibility":
            "version \(versionAudit.headerVersion) with \(versionAudit.extensions.count) extension dictionaries; archival inventory \(archivalInventory.errorCount) errors / \(archivalInventory.warningCount) warnings (no conformance claimed); preflight \(preflightInventory.pages.count) pages, \(preflightInventory.fontsNotEmbedded) fonts not embedded, \(preflightInventory.lowResolutionImages) low-resolution images, no profile selected",
          "tablesExport":
            "reviewed table exported to CSV and XLSX; unzip verified the package, \"007\" stayed literal, \"=SUM(A1)\" stayed a string, and no formula element was written",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("smoke-test.json"), options: .atomic)
        checkpoint("all checks passed; closing documents")
        first.close()
        other.close()
        third.close()
        formDocument.close()
        encryptedDocument.close()
        signedDocument.close()
        taggedDocument.close()
        attachmentDocument.close()
        print("sPDF Editor native document smoke test passed")
        // The temporary signing keychain is removed explicitly because the
        // direct exit below skips scope defers.
        signingMaterial.cleanUp()
        // Every document was closed explicitly above; exiting directly avoids
        // AppKit's recent-document bookkeeping, which can wait indefinitely in
        // this headless run.
        exit(0)
      } catch {
        FileHandle.standardError.write(
          Data("sPDF Editor smoke test failed: \(error.localizedDescription)\n".utf8))
        exit(1)
      }
    }
    /// Run a tool and return its standard output, or nil when unavailable or
    /// unsuccessful (used for independent DOCX package checks).
    private static func runToolOutput(_ tool: String, _ arguments: [String]) -> String? {
      guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = Pipe()
      do { try process.run() } catch { return nil }
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A 4×2 PNG (red and blue halves) for the image-import smoke step.
    private static func tinyPNGData() -> Data {
      guard
        let context = CGContext(
          data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return Data() }
      context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
      guard let image = context.makeImage() else { return Data() }
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, "public.png" as CFString, 1, nil)
      else { return Data() }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return Data() }
      return data as Data
    }
  }

  /// Debug-only helper: generates throwaway signing material with openssl and
  /// imports the identity into a temporary keychain so the smoke run never
  /// touches the user's keychain or requires committed private keys.
  enum SmokeSigningIdentity {
    struct Handle {
      let identity: SecIdentity
      let caCertificate: SecCertificate
      let keychain: SecKeychain
      let directory: URL

      func cleanUp() {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
      }
    }

    static func make() -> Handle? {
      let openssl = "/usr/bin/openssl"
      guard FileManager.default.isExecutableFile(atPath: openssl) else { return nil }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spdf-smoke-signing-\(UUID().uuidString)", isDirectory: true)
      guard
        (try? FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true)) != nil
      else { return nil }
      func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = arguments
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
      }
      let caKey = directory.appendingPathComponent("ca.key").path
      let caPEM = directory.appendingPathComponent("ca.pem").path
      let leafKey = directory.appendingPathComponent("leaf.key").path
      let leafCSR = directory.appendingPathComponent("leaf.csr").path
      let leafPEM = directory.appendingPathComponent("leaf.pem").path
      let p12Path = directory.appendingPathComponent("identity.p12").path
      guard
        run([
          "req", "-x509", "-newkey", "rsa:2048", "-keyout", caKey, "-out", caPEM, "-days", "2",
          "-nodes", "-sha256", "-subj", "/CN=sPDF Smoke CA/O=sPDF Editor",
        ]),
        run([
          "req", "-newkey", "rsa:2048", "-keyout", leafKey, "-out", leafCSR, "-nodes", "-sha256",
          "-subj", "/CN=sPDF Smoke Signer/O=sPDF Editor",
        ]),
        run([
          "x509", "-req", "-in", leafCSR, "-CA", caPEM, "-CAkey", caKey, "-CAcreateserial",
          "-out", leafPEM, "-days", "2", "-sha256",
        ]),
        run([
          "pkcs12", "-export", "-out", p12Path, "-inkey", leafKey, "-in", leafPEM, "-certfile",
          caPEM, "-passout", "pass:test", "-name", "sPDF Smoke Signer",
        ]),
        let p12 = try? Data(contentsOf: URL(fileURLWithPath: p12Path)),
        let caPEMData = try? Data(contentsOf: URL(fileURLWithPath: caPEM)),
        let caCertificate = certificate(fromPEM: caPEMData)
      else {
        try? FileManager.default.removeItem(at: directory)
        return nil
      }
      let keychainPath = NSTemporaryDirectory() + "spdf-smoke-\(UUID().uuidString).keychain"
      var keychain: SecKeychain?
      guard
        SecKeychainCreate(keychainPath, 4, "test", false, nil, &keychain) == errSecSuccess,
        let keychain
      else {
        try? FileManager.default.removeItem(at: directory)
        return nil
      }
      let options: [String: Any] = [
        kSecImportExportPassphrase as String: "test",
        kSecImportExportKeychain as String: keychain,
      ]
      var items: CFArray?
      guard SecPKCS12Import(p12 as CFData, options as CFDictionary, &items) == errSecSuccess,
        let array = items as? [[String: Any]],
        let value = array.first?[kSecImportItemIdentity as String]
      else {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
        return nil
      }
      return Handle(
        identity: value as! SecIdentity, caCertificate: caCertificate, keychain: keychain,
        directory: directory)
    }

    static func certificate(fromPEM pem: Data) -> SecCertificate? {
      let text = String(decoding: pem, as: UTF8.self)
      let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
      guard let der = Data(base64Encoded: base64) else { return nil }
      return SecCertificateCreateWithData(nil, der as CFData)
    }
  }
#endif
