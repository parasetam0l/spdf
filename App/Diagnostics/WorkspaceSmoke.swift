#if DEBUG
  import AppKit
  import Foundation
  import MacServices
  import PDFCore
  import PDFEditing
  import PDFKit

  /// Regressions for blank authoring, AppKit sizing and retained window closure.
  @MainActor
  enum WorkspaceSmoke {
    static func run(output: URL) async {
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
        let report = try await checks(output: output)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("workspace-smoke.json"), options: .atomic)
        print("sPDF workspace smoke passed")
        NSApp.terminate(nil)
      } catch {
        FileHandle.standardError.write(Data("Workspace smoke failed: \(error)\n".utf8))
        exit(1)
      }
    }

    static func checks(output: URL) async throws -> [String: Any] {
      let controller = NSDocumentController.shared
      let previous = Set(controller.documents.map(ObjectIdentifier.init))
      controller.newDocument(nil)
      guard
        let document = controller.documents.first(where: {
          !previous.contains(ObjectIdentifier($0))
        }) as? SPDFDocument, let viewer = document.viewer,
        let window = document.windowControllers.first?.window,
        document.fileURL == nil, document.isDocumentEdited,
        viewer.pageCount == 1, viewer.activeTool == .addText
      else { throw PDFError(.malformed, "New PDF did not create a dirty editable untitled window") }
      defer { document.close() }
      let original = try document.editSession.bytesForSave()
      let firstUntitledKey = document.recoveryKey
      let top = Double(viewer.view.document?.page(at: 0)?.bounds(for: .mediaBox).maxY ?? 792) - 48
      guard
        viewer.onAddPageText?(0, [48, top - 30, 400, top], "Workspace authoring regression")
          == true,
        viewer.activeTool == .addText
      else { throw PDFError(.malformed, "Add Text failed or reset its active mode") }
      let saved = output.appendingPathComponent("new-authored.pdf")
      let saveError: Error? = await withCheckedContinuation { continuation in
        document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
          continuation.resume(returning: error)
        }
      }
      if let saveError { throw saveError }
      guard PDFDocument(url: saved)?.string?.contains("Workspace authoring regression") == true,
        PDFDocument(url: saved)?.page(at: 0)?.annotations.isEmpty == true
      else { throw PDFError(.malformed, "Saved New PDF lacks real page text") }
      document.undoEdit()
      guard try document.editSession.bytesForSave() == original else {
        throw PDFError(.malformed, "Undo did not restore the exact blank source")
      }
      document.redoEdit()
      guard viewer.view.document?.string?.contains("Workspace authoring regression") == true else {
        throw PDFError(.malformed, "Redo did not restore visible text")
      }

      // Clicking selects a block without putting a caret into it. A selected
      // block can move, cancel and enter native marked-text input independently.
      guard let page = viewer.view.document?.page(at: 0),
        let match = viewer.view.document?.findString(
          "Workspace authoring regression", withOptions: []
        ).first,
        let content = window.contentView
      else { throw PDFError(.malformed, "Missing native text fixture") }
      window.makeKeyAndOrderFront(nil)
      _ = viewer.activateTool(.textEdit)
      try await Task.sleep(for: .milliseconds(100))
      func findOverlay(_ view: NSView) -> PageEditOverlayView? {
        if let overlay = view as? PageEditOverlayView { return overlay }
        return view.subviews.lazy.compactMap { findOverlay($0) }.first
      }
      func findCanvas(_ view: NSView) -> InlinePageTextCanvas? {
        if let canvas = view as? InlinePageTextCanvas { return canvas }
        return view.subviews.lazy.compactMap { findCanvas($0) }.first
      }
      guard let overlay = findOverlay(content) else {
        throw PDFError(.malformed, "Missing page overlay")
      }
      let bounds = match.bounds(for: page)
      let point = viewer.view.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page)
      let pointer = viewer.view.convert(point, to: nil)
      func mouse(_ type: NSEvent.EventType, point: NSPoint, clicks: Int = 1) throws -> NSEvent {
        guard
          let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
          )
        else { throw PDFError(.malformed, "Could not construct native pointer event") }
        return event
      }
      let selectionBaseline = try document.editSession.bytesForSave()
      overlay.mouseDown(with: try mouse(.leftMouseDown, point: pointer))
      overlay.mouseUp(with: try mouse(.leftMouseUp, point: pointer))
      guard let selected = findCanvas(content), viewer.isEditingPageText,
        !viewer.isTypingPageText, !selected.textView.isEditable,
        window.firstResponder === selected,
        try document.editSession.bytesForSave() == selectionBaseline
      else {
        throw PDFError(.malformed, "Single-click did not create a non-mutating block selection")
      }
      let position = viewer.pageTextPosition
      selected.mouseDown(with: try mouse(.leftMouseDown, point: pointer))
      let movedPointer = NSPoint(x: pointer.x + 60, y: pointer.y - 30)
      selected.mouseDragged(with: try mouse(.leftMouseDragged, point: movedPointer))
      selected.mouseUp(with: try mouse(.leftMouseUp, point: movedPointer))
      guard viewer.pageTextPosition != position, document.isDocumentEdited else {
        throw PDFError(.malformed, "Selected-block drag did not move or mark pending text")
      }
      viewer.pageTextCancel?()
      guard !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == selectionBaseline
      else {
        throw PDFError(.malformed, "Cancel did not restore selected-block movement")
      }
      overlay.mouseDown(with: try mouse(.leftMouseDown, point: pointer))
      overlay.mouseUp(with: try mouse(.leftMouseUp, point: pointer))
      guard let input = findCanvas(content) else {
        throw PDFError(.malformed, "Text did not reselect")
      }
      input.mouseDown(with: try mouse(.leftMouseDown, point: pointer, clicks: 2))
      guard viewer.isTypingPageText, input.textView.isEditable,
        window.firstResponder === input.textView
      else {
        throw PDFError(.malformed, "Double-click did not enter native page typing")
      }
      input.textView.setMarkedText(
        "composition", selectedRange: NSRange(location: 11, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
      guard input.textView.hasMarkedText(), viewer.pendingEditFinisher?() == false,
        viewer.isEditingPageText,
        try document.editSession.bytesForSave() == selectionBaseline
      else {
        throw PDFError(.malformed, "Incomplete IME composition was committed")
      }
      input.textView.unmarkText()
      viewer.pageTextCancel?()
      guard !viewer.isTypingPageText, !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == selectionBaseline
      else {
        throw PDFError(.malformed, "Native composition cancellation changed the document")
      }

      let paragraphText = "A natural paragraph can be edited directly on the page with automatic wrapping and predictable saved line positions."
      guard let paragraphFont = NSFont(name: "Helvetica", size: 16) else {
        throw PDFError(.malformed, "Missing paragraph test font")
      }
      let paragraphLines = NativeParagraphEditing.wrappedLines(
        paragraphText, font: paragraphFont, width: 265)
      guard document.addPageText(
        pageIndex: 0, rect: [48, 350, 500, 590], text: paragraphLines.joined(separator: "\n"),
        style: PageTextStyle(fontSize: 16)),
        let paragraphPage = viewer.view.document?.page(at: 0),
        let paragraphMatch = viewer.view.document?.findString(paragraphLines[0], withOptions: []).first
      else { throw PDFError(.malformed, "Missing paragraph workflow fixture") }
      let paragraphBaseline = try document.editSession.bytesForSave()
      try paragraphBaseline.write(to: output.appendingPathComponent("paragraph-before.pdf"))
      let paragraphBounds = paragraphMatch.bounds(for: paragraphPage)
      let paragraphPointer = viewer.view.convert(
        viewer.view.convert(NSPoint(x: paragraphBounds.midX, y: paragraphBounds.midY), from: paragraphPage), to: nil)
      overlay.mouseDown(with: try mouse(.leftMouseDown, point: paragraphPointer))
      overlay.mouseUp(with: try mouse(.leftMouseUp, point: paragraphPointer))
      guard let paragraphCanvas = findCanvas(content),
        paragraphCanvas.sourceTarget?.paragraph?.originalText.count == paragraphLines.count,
        !viewer.isTypingPageText,
        try document.editSession.bytesForSave() == paragraphBaseline
      else { throw PDFError(.malformed, "A paragraph was not selected as one non-mutating object") }
      paragraphCanvas.beginTyping()
      let replacement = "A longer paragraph is edited directly on the page. Native wrapping follows the width of the text box, and the saved document keeps exactly the line positions shown while typing. Every unrelated line stays in its original place."
      paragraphCanvas.textView.insertText(replacement,
        replacementRange: NSRange(location: 0, length: (paragraphCanvas.textView.string as NSString).length))
      let wideLines = paragraphCanvas.pageLines().count
      paragraphCanvas.setTextWidth(195)
      guard paragraphCanvas.pageLines().count > wideLines, document.isDocumentEdited else {
        throw PDFError(.malformed, "Changing paragraph width did not rewrap the actual editor")
      }
      paragraphCanvas.move(byWindowDelta: NSPoint(x: 24, y: -14), finished: true)
      let expectedLines = paragraphCanvas.pageLines()
      try JSONSerialization.data(withJSONObject: expectedLines.map {
        ["text": $0.text, "x": $0.x, "baseline": $0.baseline] as [String: Any]
      }, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("paragraph-native-lines.json"))
      guard paragraphCanvas.commit(), !viewer.isEditingPageText else {
        throw PDFError(.malformed, "Native paragraph commit did not finish")
      }
      let paragraphEdited = try document.editSession.bytesForSave()
      let paragraphOutput = output.appendingPathComponent("paragraph-after.pdf")
      try paragraphEdited.write(to: paragraphOutput)
      guard let reopened = PDFDocument(url: paragraphOutput), let reopenedPage = reopened.page(at: 0),
        reopened.string?.contains("A natural paragraph") == false,
        reopened.string?.contains("Workspace authoring regression") == true
      else { throw PDFError(.malformed, "Reopened paragraph retained old text or lost its neighbor") }
      for line in expectedLines where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
        let value = line.text.trimmingCharacters(in: .whitespaces)
        guard let selection = reopened.findString(value, withOptions: []).first else {
          throw PDFError(.malformed, "Saved paragraph is missing a native line")
        }
        let bounds = selection.bounds(for: reopenedPage)
        guard abs(bounds.minX - line.x) < 0.1 else {
          throw PDFError(.malformed, "Saved paragraph diverged from the native line position")
        }
      }
      document.undoEdit()
      guard try document.editSession.bytesForSave() == paragraphBaseline else {
        throw PDFError(.malformed, "Paragraph Undo did not restore the complete source in one step")
      }
      document.redoEdit()
      guard try document.editSession.bytesForSave() == paragraphEdited else {
        throw PDFError(.malformed, "Paragraph Redo did not restore the exact edited layout")
      }
      guard let repeatPage = viewer.view.document?.page(at: 0),
        let repeatSelection = viewer.view.document?.findString(
          expectedLines[0].text.trimmingCharacters(in: .whitespaces), withOptions: []).first
      else { throw PDFError(.malformed, "Cannot find the saved paragraph") }
      let repeatBounds = repeatSelection.bounds(for: repeatPage)
      guard viewer.textRunProvider?(
        0, [repeatBounds.midX, repeatBounds.midY])?.paragraph != nil
      else { throw PDFError(.malformed, "The saved paragraph cannot be selected for another edit") }

      window.setContentSize(NSSize(width: 960, height: 650))
      try await Task.sleep(for: .milliseconds(150))
      let originalFrame = window.frame
      let minimum = window.contentMinSize
      let maximum = window.contentMaxSize
      guard minimum == NSSize(width: 860, height: 540) else {
        throw PDFError(.malformed, "Workspace minimum size was reset: \(minimum)")
      }
      for mode in SidebarMode.allCases {
        viewer.sidebarMode = mode
        try await Task.sleep(for: .milliseconds(70))
        window.contentView?.layoutSubtreeIfNeeded()
        guard window.frame == originalFrame, window.contentMinSize == minimum,
          window.contentMaxSize == maximum, window.styleMask.contains(.resizable)
        else { throw PDFError(.malformed, "Sidebar \(mode) changed window sizing constraints") }
      }
      viewer.isSidebarVisible = false
      try await Task.sleep(for: .milliseconds(70))
      guard window.frame == originalFrame else {
        throw PDFError(.malformed, "Hiding the sidebar changed the window frame")
      }
      viewer.isSidebarVisible = true
      viewer.sidebarMode = .comments
      // AppKit constrains windows to the available display. Exercise two
      // distinct legal sizes even on the smaller hosted-runner display.
      let available = window.contentRect(
        forFrameRect: window.screen?.visibleFrame ?? originalFrame
      ).size
      let resized = NSSize(
        width: min(minimum.width + 100, floor(available.width)),
        height: min(minimum.height + 80, floor(available.height)))
      guard resized.width > minimum.width, resized.height > minimum.height else {
        throw PDFError(.malformed, "Display cannot accommodate two workspace sizes: \(available)")
      }
      window.setContentSize(minimum)
      try await Task.sleep(for: .milliseconds(70))
      guard window.contentView?.bounds.size == minimum else {
        throw PDFError(
          .malformed,
          "Comments minimum resize: expected \(minimum), got \(String(describing: window.contentView?.bounds.size))"
        )
      }
      window.setContentSize(resized)
      try await Task.sleep(for: .milliseconds(70))
      guard window.contentView?.bounds.size == resized,
        window.contentMinSize == minimum, window.contentMaxSize == maximum
      else {
        throw PDFError(
          .malformed,
          "Comments expanded resize: expected \(resized), got \(String(describing: window.contentView?.bounds.size))"
        )
      }
      let beforeSecond = Set(controller.documents.map(ObjectIdentifier.init))
      controller.newDocument(nil)
      guard
        let second = controller.documents.first(where: {
          !beforeSecond.contains(ObjectIdentifier($0))
        }) as? SPDFDocument, second.recoveryKey != firstUntitledKey,
        second.viewer?.sidebarMode == .pages
      else { throw PDFError(.malformed, "New PDFs share recovery/view state") }
      second.close()

      for _ in 0..<3 {
        document.organizePages()
        guard
          let auxiliary = NSApp.windows.first(where: {
            $0.title == "Organize Pages" && $0.isVisible
          }),
          !auxiliary.isReleasedWhenClosed
        else { throw PDFError(.malformed, "Page organizer has unsafe window ownership") }
        auxiliary.close()
        try await Task.sleep(for: .milliseconds(30))
        guard auxiliary.title == "Organize Pages" else {
          throw PDFError(.malformed, "Closed page organizer was invalidated")
        }
      }
      document.placeGraphicalSignature()
      guard
        let signature = NSApp.windows.first(where: {
          $0.title == "Graphical Signature" && $0.isVisible
        }),
        !signature.isReleasedWhenClosed
      else { throw PDFError(.malformed, "Signature window has unsafe ownership") }
      signature.close()
      try await Task.sleep(for: .milliseconds(30))
      guard signature.title == "Graphical Signature" else {
        throw PDFError(.malformed, "Closed signature window was invalidated")
      }
      guard let delegate = NSApp.delegate as? ApplicationDelegate else {
        throw PDFError(.malformed, "Missing application delegate")
      }
      delegate.showUpdateSettings(nil)
      guard let settings = NSApp.windows.first(where: { $0.title == "Settings" && $0.isVisible })
      else {
        throw PDFError(.malformed, "Unified Settings did not open")
      }
      settings.close()
      delegate.showUpdateSettings(nil)
      guard settings.isVisible,
        NSApp.windows.filter({ $0.title == "Settings" }).count == 1,
        KeyboardAudit.verify([
          .init(title: "New PDF", modifiers: [.command]),
          .init(title: "Settings…", modifiers: [.command]),
          .init(title: "Cut", modifiers: [.command]),
          .init(title: "Paste", modifiers: [.command]),
        ]).missing.isEmpty,
        let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
        file.items.filter({ !$0.isSeparatorItem }).count <= 10,
        KeyboardAudit.find("Check for Updates…") != nil
      else { throw PDFError(.malformed, "Settings/menu structure regression") }
      settings.close()
      return [
        "directTextSelection":
          "single-click selection, body move/cancel, double-click typing, marked-text Save veto",
        "paragraphWorkflow":
          "longer native text, width reflow, move, exact saved lines, atomic Undo/Redo, reselection",
        "status": "passed", "blankAuthoring": "created, real text, saved, undo/redo",
        "sidebarModes": SidebarMode.allCases.map(\.rawValue),
        "windowSizing":
          "frame/min/max preserved; Comments resized between two display-fitting sizes",
        "minimumContentSize": [minimum.width, minimum.height],
        "resizedContentSize": [resized.width, resized.height],
        "availableContentSize": [available.width, available.height],
        "auxiliaryClosure": "3 organizers and signature closed with retained objects valid",
        "settings": "one reusable Settings window; Command-comma",
        "fileMenu": "New PDF/Command-N; at most 10 root commands; grouped exports",
      ]
    }
  }
#endif
