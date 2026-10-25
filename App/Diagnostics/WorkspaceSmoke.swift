#if DEBUG
  import AppKit
  import DocumentSession
  import Foundation
  import MacServices
  import PDFCore
  import PDFEditing
  import PDFKit
  import SwiftUI

  /// Native wheel fixtures retain explicit window-relative coordinates.
  /// CGEvent alone has no window association without WindowServer dispatch.
  private final class WorkspaceWheelEvent: NSEvent {
    let target: NSWindow
    let number: Int
    let point: NSPoint
    let delta: CGFloat
    let backing: CGEvent
    let stamp = ProcessInfo.processInfo.systemUptime
    @MainActor init(window: NSWindow, point: NSPoint, delta: Int32) {
      target = window; number = window.windowNumber; self.point = point; self.delta = CGFloat(delta)
      backing = CGEvent(scrollWheelEvent2Source: nil, units: .line,
        wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
      backing.flags = .maskCommand
      super.init()
    }
    required init?(coder: NSCoder) { return nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { .command }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var momentumPhase: NSEvent.Phase { [] }
    override var phase: NSEvent.Phase { [] }
    override var cgEvent: CGEvent? { backing }
    override var timestamp: TimeInterval { stamp }
  }

  /// Regressions for blank authoring, AppKit sizing and retained window closure.
  @MainActor
  enum WorkspaceSmoke {
    private static func checkpoint(_ name: String) {
      FileHandle.standardError.write(Data("[workspace] \(name)\n".utf8))
    }

    private static func checkCommandScroll(_ viewer: PDFViewingSession, window: NSWindow) async throws {
      let originalScale = viewer.view.scaleFactor
      let originalPage = viewer.pageNumber
      let wasTyping = viewer.isTypingPageText
      let wasPending = viewer.hasPendingPageTextChanges
      defer { viewer.setZoom(Double(originalScale)) }
      viewer.setZoom(2)
      try await Task.sleep(for: .milliseconds(50))
      let pointer = NSPoint(x: viewer.view.visibleRect.midX, y: viewer.view.visibleRect.midY)
      let windowPoint = viewer.view.convert(pointer, to: nil)
      guard let page = viewer.view.page(for: pointer, nearest: true) else {
        throw PDFError(.malformed, "Command-scroll fixture has no visible page")
      }
      let anchor = viewer.view.convert(pointer, to: page)
      viewer.view.scrollWheel(with: WorkspaceWheelEvent(window: window, point: windowPoint, delta: 3))
      try await Task.sleep(for: .milliseconds(100))
      let actualAnchor = viewer.view.convert(pointer, to: page)
      guard viewer.scale > 2, abs(actualAnchor.x - anchor.x) < 0.75,
        abs(actualAnchor.y - anchor.y) < 0.75 else {
        throw PDFError(.malformed, "Command-scroll: scale=\(viewer.scale), anchor delta=\(actualAnchor.x - anchor.x),\(actualAnchor.y - anchor.y)")
      }
      viewer.view.scrollWheel(with: WorkspaceWheelEvent(window: window, point: windowPoint, delta: -3))
      try await Task.sleep(for: .milliseconds(100))
      guard abs(viewer.scale - 2) < 0.001, viewer.pageNumber == originalPage,
        viewer.isTypingPageText == wasTyping, viewer.hasPendingPageTextChanges == wasPending else {
        throw PDFError(.malformed, "Reverse Command-scroll changed the page or pending editor")
      }
    }

    private static func checkGraphicWorkflow(output: URL) async throws {
      let controller = NSDocumentController.shared
      let old = Set(controller.documents.map(ObjectIdentifier.init))
      checkpoint("creating image workflow document")
      controller.newDocument(nil)
      checkpoint("image workflow document created")
      guard let document = controller.documents.first(where: { !old.contains(ObjectIdentifier($0)) }) as? SPDFDocument,
        let viewer = document.viewer, let window = document.windowControllers.first?.window,
        let content = window.contentView else { throw PDFError(.malformed, "Missing image workspace") }
      defer { document.close() }
      window.makeKeyAndOrderFront(nil)
      viewer.setZoom(0.8)
      let image = NSImage(size: NSSize(width: 160, height: 80), flipped: false) { rect in
        NSColor.systemBlue.setFill(); rect.fill()
        NSColor.systemOrange.setFill(); CGRect(x: 80, y: 0, width: 80, height: 80).fill()
        return true
      }
      guard let bytes = image.tiffRepresentation else {
        throw PDFError(.malformed, "Image fixture encoding failed")
      }
      let preexisting = Set((viewer.graphicsListProvider?(0) ?? []).map(\.identity))
      guard document.insertImage(bytes, pageIndex: 0) else {
        throw PDFError(.malformed, "Visible image insertion returned false")
      }
      let inserted = viewer.selectedGraphics.filter { !preexisting.contains($0.identity) }
      guard inserted.count == 1 else {
        throw PDFError(.malformed,
          "Visible image insertion selected \(inserted.count) new objects; "
            + "selected=\(viewer.selectedGraphics.map(\.identity)), preexisting=\(Array(preexisting))")
      }
      viewer.setGraphicBounds(CGRect(x: 72, y: 100, width: 160, height: 80))
      guard viewer.selectedGraphicBounds == CGRect(x: 72, y: 100, width: 160, height: 80),
        document.addPageText(
          pageIndex: 0, rect: [304, 244, 412, 298], text: "Image over text",
          style: PageTextStyle(fontSize: 18)),
        document.insertImage(bytes, pageIndex: 0)
      else { throw PDFError(.malformed, "Could not create the reverse paint-order fixture") }
      viewer.setGraphicBounds(CGRect(x: 300, y: 240, width: 120, height: 60))
      guard document.addPageText(
        pageIndex: 0, rect: [78, 110, 226, 164], text: "Text overlap",
        style: PageTextStyle(fontSize: 18)) else {
        throw PDFError(.malformed, "Could not create the cross-type overlap fixture")
      }
      let targets = viewer.graphicsListProvider?(0) ?? []
      guard targets.count == preexisting.count + 2 else {
        throw PDFError(.malformed, "Second image placement failed")
      }
      checkpoint("image placements inserted")
      func find(_ root: NSView) -> GraphicSelectionOverlayView? {
        if let overlay = root as? GraphicSelectionOverlayView { return overlay }
        return root.subviews.lazy.compactMap { find($0) }.first
      }
      func findPageEdit(_ root: NSView) -> PageEditOverlayView? {
        if let overlay = root as? PageEditOverlayView { return overlay }
        return root.subviews.lazy.compactMap { findPageEdit($0) }.first
      }
      func findInlineCanvas(_ root: NSView) -> InlinePageTextCanvas? {
        if let canvas = root as? InlinePageTextCanvas { return canvas }
        return root.subviews.lazy.compactMap { findInlineCanvas($0) }.first
      }
      try await Task.sleep(for: .milliseconds(100))
      guard let overlay = find(content) else { throw PDFError(.malformed, "Missing image overlay") }
      func point(_ x: Double, _ y: Double) throws -> NSPoint {
        guard let page = viewer.view.document?.page(at: 0) else { throw PDFError(.malformed, "Missing image page") }
        return viewer.view.convert(viewer.view.convert(NSPoint(x: x, y: y), from: page), to: nil)
      }
      func mouse(
        _ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1
      ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        else { throw PDFError(.malformed, "Missing image pointer event") }; return event
      }
      func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
        else { throw PDFError(.malformed, "Missing image key event") }; overlay.keyDown(with: event)
      }
      guard let textOverlay = findPageEdit(content),
        let overlapPage = viewer.view.document?.page(at: 0),
        let overlapText = viewer.view.document?.findString("Text overlap", withOptions: []).first
      else { throw PDFError(.malformed, "Missing overlapping text target") }
      let overlapBounds = overlapText.bounds(for: overlapPage)
      let crossTypeBaseline = try document.editSession.bytesForSave()
      window.setContentSize(NSSize(width: 1_160, height: 740))
      guard viewer.activateTool(.textEdit) else {
        throw PDFError(.malformed, "Could not activate Edit PDF before keyboard traversal")
      }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(80))
      viewer.view.clearSelection()
      viewer.clearGraphicSelection()
      let textTargetNames = (viewer.textTargetsProvider?(0) ?? []).map(\.text)
      guard viewer.canSelectAdjacentPageObject else {
        throw PDFError(.malformed,
          "Text traversal unavailable in mode \(viewer.activeTool), editing=\(viewer.isEditingPageText), targets=\(textTargetNames.count)")
      }
      guard let pageCanvasAX = AccessibilityAudit.applicationElement(labeled: "PDF pages") else {
        throw PDFError(.malformed, "PDF pages accessibility element is missing")
      }
      let pageCanvasActions = AccessibilityAudit.actionNames(of: pageCanvasAX)
      guard AccessibilityAudit.hasAction(named: "Select Next Page Object", on: pageCanvasAX),
        AccessibilityAudit.hasAction(named: "Select Previous Page Object", on: pageCanvasAX),
        !AccessibilityAudit.hasAction(named: "Edit Selected Text", on: pageCanvasAX) else {
        throw PDFError(.malformed,
          "PDF pages accessibility actions are missing (actions=\(pageCanvasActions))")
      }
      guard AccessibilityAudit.focus(pageCanvasAX) else {
        throw PDFError(.malformed, "PDF pages accessibility element could not receive AX focus")
      }
      func currentPageCanvasAX() -> AXUIElement? {
        AccessibilityAudit.applicationElement(labeledPrefix: "PDF pages")
      }
      func pageCanvasExposesSelection(_ summary: String) -> Bool {
        guard let element = currentPageCanvasAX() else { return false }
        return AccessibilityAudit.label(of: element) == "PDF pages"
          && AccessibilityAudit.value(of: element) == summary
      }
      func performPageCanvasAction(_ name: String) -> Bool {
        guard let element = currentPageCanvasAX() else { return false }
        return AccessibilityAudit.performAction(named: name, on: element)
      }
      guard performPageCanvasAction("Select Next Page Object") else {
        throw PDFError(.malformed, "VoiceOver next-object action did not dispatch for text")
      }
      try await Task.sleep(for: .milliseconds(50))
      guard let axFirstText = viewer.selectedObjectSummary,
        pageCanvasExposesSelection(axFirstText),
        window.firstResponder === viewer.view else {
        throw PDFError(.malformed,
          "VoiceOver next-object action did not expose text selection (AX label=\(currentPageCanvasAX().flatMap(AccessibilityAudit.label(of:)) ?? "nil"), value=\(currentPageCanvasAX().flatMap(AccessibilityAudit.value(of:)) ?? "nil"), attributes=\(currentPageCanvasAX().map(AccessibilityAudit.attributeNames(of:)) ?? []), selection=\(viewer.selectedObjectSummary ?? "nil"), actions=\(pageCanvasActions))")
      }
      guard performPageCanvasAction("Select Next Page Object") else {
        throw PDFError(.malformed, "VoiceOver next-object action did not advance text selection")
      }
      try await Task.sleep(for: .milliseconds(50))
      guard let axSecondText = viewer.selectedObjectSummary,
        axSecondText != axFirstText,
        pageCanvasExposesSelection(axSecondText) else {
        throw PDFError(.malformed,
          "VoiceOver next-object action did not update the accessible text selection value")
      }
      guard performPageCanvasAction("Select Previous Page Object") else {
        throw PDFError(.malformed, "VoiceOver previous-object action did not dispatch for text")
      }
      try await Task.sleep(for: .milliseconds(50))
      guard viewer.selectedObjectSummary == axFirstText,
        pageCanvasExposesSelection(axFirstText) else {
        throw PDFError(.malformed,
          "VoiceOver previous-object action did not restore the accessible text selection value")
      }
      guard let editablePageCanvasAX = currentPageCanvasAX() else {
        throw PDFError(.malformed, "PDF pages accessibility element disappeared before text edit")
      }
      let selectedTextActions = AccessibilityAudit.actionNames(of: editablePageCanvasAX)
      guard viewer.canEditSelectedPageText,
        AccessibilityAudit.hasAction(named: "Edit Selected Text", on: editablePageCanvasAX) else {
        throw PDFError(.malformed,
          "VoiceOver selected-text edit action was not available (model=\(viewer.canEditSelectedPageText), tool=\(viewer.activeTool), callback=\(viewer.textBlockEditStarter != nil), selection=\(viewer.view.currentSelection?.string ?? "nil"), actions=\(selectedTextActions))")
      }
      let axEditActionReturnedSuccess = performPageCanvasAction("Edit Selected Text")
      try await Task.sleep(for: .milliseconds(50))
      guard axEditActionReturnedSuccess,
        let accessibleCanvas = findInlineCanvas(content),
        viewer.isEditingPageText, viewer.isTypingPageText,
        window.firstResponder === accessibleCanvas.textView else {
        throw PDFError(.malformed,
          "VoiceOver selected-text action did not enter the inline editor (AX returned success=\(axEditActionReturnedSuccess), editing=\(viewer.isEditingPageText), typing=\(viewer.isTypingPageText), action names=\(selectedTextActions))")
      }
      accessibleCanvas.textView.insertText(
        "Accessible draft",
        replacementRange: NSRange(
          location: 0, length: (accessibleCanvas.textView.string as NSString).length))
      guard viewer.hasPendingPageTextChanges else {
        throw PDFError(.malformed, "VoiceOver text input did not create a pending draft")
      }
      viewer.pageTextCancel?()
      guard !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == crossTypeBaseline,
        window.firstResponder === viewer.view else {
        throw PDFError(.malformed,
          "Cancelling VoiceOver text input changed the PDF or failed to restore canvas focus")
      }
      viewer.view.clearSelection()
      viewer.clearGraphicSelection()
      guard AccessibilityAudit.applicationElement(labeled: "Select Next Page Object") != nil,
        AccessibilityAudit.applicationElement(labeled: "Select Previous Page Object") != nil,
        KeyboardAudit.press("Select Next Page Object") else {
        let item = KeyboardAudit.find("Select Next Page Object")
        throw PDFError(.malformed,
          "Next text-object shortcut did not dispatch (enabled=\(item?.isEnabled ?? false), key=\(item?.keyEquivalent.unicodeScalars.map(\.value) ?? []), keyDocument=\(NSDocumentController.shared.currentDocument === document), targets=\(textTargetNames))")
      }
      guard let firstTextSelection = viewer.selectedObjectSummary,
        window.firstResponder === viewer.view else {
        throw PDFError(.malformed,
          "Next text-object shortcut did not select a block or focus the PDF view (summary=\(viewer.selectedObjectSummary ?? "nil"), targets=\(textTargetNames))")
      }
      guard KeyboardAudit.press("Select Next Page Object"),
        let secondTextSelection = viewer.selectedObjectSummary,
        secondTextSelection != firstTextSelection,
        KeyboardAudit.press("Select Previous Page Object"),
        viewer.selectedObjectSummary == firstTextSelection else {
        throw PDFError(.malformed,
          "Keyboard next/previous did not cycle distinct text blocks (first=\(firstTextSelection), second=\(viewer.selectedObjectSummary ?? "nil"), targets=\(textTargetNames))")
      }
      _ = viewer.activateTool(.imageEdit)
      viewer.view.clearSelection()
      viewer.clearGraphicSelection()
      guard KeyboardAudit.press("Select Next Page Object"),
        let firstGraphic = viewer.selectedGraphics.first?.identity,
        targets.contains(where: { $0.identity == firstGraphic }),
        window.firstResponder === overlay,
        KeyboardAudit.press("Select Next Page Object"),
        let secondGraphic = viewer.selectedGraphics.first?.identity,
        secondGraphic != firstGraphic,
        KeyboardAudit.press("Select Previous Page Object"),
        viewer.selectedGraphics.first?.identity == firstGraphic else {
        throw PDFError(.malformed,
          "Keyboard next/previous did not select distinct graphics and restore the original selection")
      }
      guard let graphicsPageCanvasAX = AccessibilityAudit.applicationElement(labeled: "PDF pages"),
        AccessibilityAudit.focus(graphicsPageCanvasAX) else {
        throw PDFError(.malformed, "PDF pages accessibility element could not receive graphics focus")
      }
      guard AccessibilityAudit.performAction(named: "Select Next Page Object", on: graphicsPageCanvasAX) else {
        throw PDFError(.malformed, "VoiceOver next-object action did not dispatch for graphics")
      }
      try await Task.sleep(for: .milliseconds(50))
      guard let axFirstGraphic = viewer.selectedGraphics.first?.identity,
        window.firstResponder === overlay,
        let firstGraphicSummary = viewer.selectedObjectSummary,
        pageCanvasExposesSelection(firstGraphicSummary) else {
        throw PDFError(.malformed, "VoiceOver next-object action did not expose the graphic selection")
      }
      guard performPageCanvasAction("Select Next Page Object") else {
        throw PDFError(.malformed, "VoiceOver next-object action did not advance graphic selection")
      }
      try await Task.sleep(for: .milliseconds(50))
      guard viewer.selectedGraphics.first?.identity != axFirstGraphic,
        let secondGraphicSummary = viewer.selectedObjectSummary,
        pageCanvasExposesSelection(secondGraphicSummary) else {
        throw PDFError(.malformed, "VoiceOver next-object action did not update the accessible graphic value")
      }
      guard performPageCanvasAction("Select Previous Page Object") else {
        throw PDFError(.malformed, "VoiceOver previous-object action did not dispatch for graphics")
      }
      try await Task.sleep(for: .milliseconds(50))
      guard viewer.selectedGraphics.first?.identity == axFirstGraphic,
        viewer.selectedObjectSummary == firstGraphicSummary,
        pageCanvasExposesSelection(firstGraphicSummary) else {
        throw PDFError(.malformed,
          "VoiceOver page actions did not select and cycle graphics")
      }
      checkpoint("keyboard-only page-object selection passed")
      _ = viewer.activateTool(.select)
      try await Task.sleep(for: .milliseconds(150))
      guard let selectModeCanvasAX = AccessibilityAudit.applicationElement(labeledPrefix: "PDF pages") else {
        throw PDFError(.malformed, "PDF pages accessibility element disappeared in Select mode")
      }
      let selectModeActions = AccessibilityAudit.actionNames(of: selectModeCanvasAX)
      guard !AccessibilityAudit.hasAction(named: "Select Next Page Object", on: selectModeCanvasAX),
        !AccessibilityAudit.hasAction(named: "Select Previous Page Object", on: selectModeCanvasAX) else {
        throw PDFError(.malformed,
          "Page-object actions remained exposed in Select mode (tool=\(viewer.activeTool), can=\(viewer.canSelectAdjacentPageObject), label=\(AccessibilityAudit.label(of: selectModeCanvasAX) ?? "nil"), actions=\(selectModeActions))")
      }
      viewer.view.setCurrentSelection(overlapText, animate: false)
      viewer.refreshSelectionSummary()
      try await Task.sleep(for: .milliseconds(120))
      // The resize changes the overlay's window-space origin.
      let textPoint = try point(overlapBounds.midX, overlapBounds.midY)
      let imagePoint = try point(120, 140)
      guard AccessibilityAudit.applicationElement(labeled: "Text selection") != nil,
        let editTextAction = AccessibilityAudit.applicationElement(labeled: "Edit Text"),
        AccessibilityAudit.press(editTextAction),
        viewer.activeTool == .textEdit, viewer.selectedGraphics.isEmpty else {
        throw PDFError(.malformed, "Wide text inspector did not hand selection to Edit PDF")
      }
      textOverlay.mouseDown(with: try mouse(.leftMouseDown, textPoint))
      textOverlay.mouseUp(with: try mouse(.leftMouseUp, textPoint))
      guard viewer.isEditingPageText, !viewer.isTypingPageText,
        viewer.selectedGraphics.isEmpty else {
        throw PDFError(.malformed, "Edit PDF did not select the text over the image")
      }
      viewer.pageTextCancel?()
      guard !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == crossTypeBaseline else {
        throw PDFError(.malformed, "Cancelling the overlap text selection changed the document")
      }

      // A real pending paragraph draft must finish before the tool changes.
      // Verify the text is committed by the switch, then Undo restores the
      // exact pre-edit document before continuing the image selection checks.
      textOverlay.mouseDown(with: try mouse(.leftMouseDown, textPoint, clicks: 2))
      textOverlay.mouseUp(with: try mouse(.leftMouseUp, textPoint, clicks: 2))
      func findCanvas(_ root: NSView) -> InlinePageTextCanvas? {
        if let canvas = root as? InlinePageTextCanvas { return canvas }
        return root.subviews.lazy.compactMap { findCanvas($0) }.first
      }
      guard let cancelledDraft = findCanvas(content), viewer.isTypingPageText else {
        throw PDFError(.malformed, "Double-click did not start overlapping text input")
      }
      cancelledDraft.textView.insertText(
        "Cancelled draft",
        replacementRange: NSRange(location: 0, length: (cancelledDraft.textView.string as NSString).length))
      guard viewer.hasPendingPageTextChanges else {
        throw PDFError(.malformed, "Typing over the image did not create a pending text draft")
      }
      viewer.pageTextCancel?()
      guard !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == crossTypeBaseline else {
        throw PDFError(.malformed, "Cancelling a typed overlap draft changed the PDF")
      }

      textOverlay.mouseDown(with: try mouse(.leftMouseDown, textPoint, clicks: 2))
      textOverlay.mouseUp(with: try mouse(.leftMouseUp, textPoint, clicks: 2))
      guard let draft = findCanvas(content), viewer.isTypingPageText else {
        throw PDFError(.malformed, "Second double-click did not start text input")
      }
      draft.textView.insertText(
        "Draft overlap", replacementRange: NSRange(location: 0, length: (draft.textView.string as NSString).length))
      guard viewer.hasPendingPageTextChanges,
        viewer.activateTool(.imageEdit), viewer.activeTool == .imageEdit,
        try document.editSession.bytesForSave() != crossTypeBaseline,
        PDFDocument(data: try document.editSession.bytesForSave())?.string?.contains("Draft overlap") == true
      else { throw PDFError(.malformed, "Switching tools lost the pending text draft") }
      document.undoEdit()
      guard try document.editSession.bytesForSave() == crossTypeBaseline else {
        throw PDFError(.malformed, "Undo after committing the pending text draft did not restore the source")
      }
      _ = viewer.activateTool(.imageEdit)
      overlay.mouseDown(with: try mouse(.leftMouseDown, imagePoint))
      overlay.mouseUp(with: try mouse(.leftMouseUp, imagePoint))
      guard viewer.selectedGraphics.map(\.identity) == [targets[0].identity],
        window.firstResponder === overlay,
        try document.editSession.bytesForSave() == crossTypeBaseline else {
        throw PDFError(.malformed, "Images mode did not select the graphic and focus keyboard controls")
      }
      checkpoint("overlapping text/image selection passed")

      // Repeat the mode-priority check with reversed paint order: this image
      // was inserted after the text and visibly covers it. The active tool
      // must still determine which object type receives the click.
      let reversedPagePoint = [310.0, 285.0]
      guard viewer.textRunProvider?(0, reversedPagePoint) != nil else {
        throw PDFError(.malformed, "Text editing could not resolve text below a later-painted image")
      }
      checkpoint("reverse paint-order text target found")
      guard viewer.activateTool(.textEdit) else {
        throw PDFError(.malformed, "Text mode was vetoed before the reverse-order overlap check")
      }
      let reversedTextPoint = try point(reversedPagePoint[0], reversedPagePoint[1])
      textOverlay.mouseDown(with: try mouse(.leftMouseDown, reversedTextPoint))
      textOverlay.mouseUp(with: try mouse(.leftMouseUp, reversedTextPoint))
      guard viewer.isEditingPageText, viewer.selectedGraphics.isEmpty else {
        throw PDFError(.malformed, "Edit PDF did not select text below a later-painted image")
      }
      viewer.pageTextCancel?()
      guard try document.editSession.bytesForSave() == crossTypeBaseline,
        viewer.activateTool(.imageEdit) else {
        throw PDFError(.malformed, "Reverse-order text cancel changed the document or blocked Images")
      }
      let reversedImagePoint = try point(350, 270)
      overlay.mouseDown(with: try mouse(.leftMouseDown, reversedImagePoint))
      overlay.mouseUp(with: try mouse(.leftMouseUp, reversedImagePoint))
      guard viewer.selectedGraphics.map(\.identity) == [targets[1].identity],
        viewer.view.currentSelection?.string == nil,
        try document.editSession.bytesForSave() == crossTypeBaseline else {
        throw PDFError(.malformed, "Images did not select the later-painted image over text")
      }
      checkpoint("reverse paint-order selection passed")

      window.setFrame(
        NSRect(origin: window.frame.origin, size: NSSize(width: 820, height: 700)), display: true)
      try await Task.sleep(for: .milliseconds(150))
      _ = viewer.activateTool(.select)
      guard let imageProperties = AccessibilityAudit.keyWindowElement(labeled: "Image properties"),
        AccessibilityAudit.press(imageProperties) else {
        throw PDFError(.malformed, "Compact workspace could not open image properties")
      }
      try await Task.sleep(for: .milliseconds(100))
      guard let editImages = AccessibilityAudit.applicationElement(labeled: "Edit Images"),
        AccessibilityAudit.press(editImages), viewer.activeTool == .imageEdit else {
        throw PDFError(.malformed, "Compact image inspector did not enter Images mode")
      }
      guard let compactOverlapText = viewer.view.document?.findString("Text overlap", withOptions: []).first
      else { throw PDFError(.malformed, "Undo did not restore a selectable overlap text target") }
      viewer.view.setCurrentSelection(compactOverlapText, animate: false)
      viewer.refreshSelectionSummary()
      try await Task.sleep(for: .milliseconds(100))
      if AccessibilityAudit.applicationElement(labeled: "Edit Text") == nil {
        guard let textProperties = AccessibilityAudit.applicationElement(labeled: "Text selection"),
          AccessibilityAudit.press(textProperties) else {
          throw PDFError(.malformed, "Compact workspace could not open text selection properties")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard let editText = AccessibilityAudit.applicationElement(labeled: "Edit Text"),
        AccessibilityAudit.press(editText), viewer.activeTool == .textEdit,
        viewer.selectedGraphics.isEmpty,
        viewer.view.currentSelection?.string?.contains("Text overlap") == true else {
        throw PDFError(.malformed, "Compact text inspector did not enter Edit PDF mode")
      }
      checkpoint("compact contextual inspector actions passed")
      let baseline = try document.editSession.bytesForSave()
      _ = viewer.activateTool(.select)
      let first = try point(152, 140), moved = try point(172, 150)
      overlay.mouseDown(with: try mouse(.leftMouseDown, first))
      overlay.mouseDragged(with: try mouse(.leftMouseDragged, moved))
      overlay.mouseUp(with: try mouse(.leftMouseUp, moved))
      guard viewer.selectedGraphics.map(\.streamID) == [targets[0].streamID],
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Select preview moved an image")
      }
      try key(53)
      guard viewer.selectedGraphics.isEmpty, window.firstResponder === viewer.view else {
        throw PDFError(.malformed, "Escape did not clear preview selection and restore page focus")
      }
      _ = viewer.activateTool(.imageEdit)
      // A first drag selects and moves the object without a preparatory click.
      overlay.mouseDown(with: try mouse(.leftMouseDown, first))
      overlay.mouseDragged(with: try mouse(.leftMouseDragged, moved))
      overlay.mouseUp(with: try mouse(.leftMouseUp, moved))
      guard abs((viewer.selectedGraphicBounds?.minX ?? 0) - 92) < 0.005,
        document.undoEdit(), try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "First image drag or atomic Undo failed")
      }
      viewer.selectGraphics([viewer.graphicsListProvider!(0)[0]])
      let second = try point(360, 270)
      overlay.mouseDown(with: try mouse(.leftMouseDown, second, flags: .shift))
      overlay.mouseUp(with: try mouse(.leftMouseUp, second, flags: .shift))
      guard viewer.selectedGraphics.count == 2, let group = viewer.selectedGraphicBounds else {
        throw PDFError(.malformed, "Shift-click did not extend image selection")
      }
      let grip = try point(group.maxX, group.maxY), destination = try point(group.maxX + 60, group.maxY + 30)
      overlay.mouseDown(with: try mouse(.leftMouseDown, grip))
      overlay.mouseDragged(with: try mouse(.leftMouseDragged, destination))
      guard viewer.hasPendingGraphicGesture?() == true,
        viewer.isPreviewingGraphic,
        let previewData = viewer.view.document?.dataRepresentation(),
        previewData != baseline
      else { throw PDFError(.malformed, "Image resize preview missing actual transformed image") }
      overlay.mouseUp(with: try mouse(.leftMouseUp, destination))
      guard !viewer.isPreviewingGraphic, let resized = viewer.selectedGraphicBounds,
        abs(resized.width - group.width - 60) < 0.005, abs(resized.height - group.height - 30) < 0.005 else {
        throw PDFError(.malformed, "Group image resizing lost the shared bounds")
      }
      let a = viewer.selectedGraphics[0].rect, b = viewer.selectedGraphics[1].rect
      guard abs((b[0] - a[0]) - (300 - 72) * resized.width / group.width) < 0.005,
        document.undoEdit(), try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Group resize collapsed spacing or Undo")
      }
      overlay.mouseDown(with: try mouse(.leftMouseDown, grip))
      overlay.mouseDragged(with: try mouse(.leftMouseDragged, destination))
      guard viewer.isPreviewingGraphic else {
        throw PDFError(.malformed, "Image resize preview was not restored by Escape")
      }
      try key(53)
      overlay.mouseUp(with: try mouse(.leftMouseUp, destination))
      guard !viewer.isPreviewingGraphic,
        viewer.hasPendingGraphicGesture?() == false, viewer.selectedGraphics.count == 2,
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Escape failed to cancel image resize")
      }
      try key(124, flags: .shift)
      guard abs((viewer.selectedGraphicBounds?.minX ?? 0) - group.minX - 10) < 0.005 else {
        throw PDFError(.malformed, "Shift-arrow did not move images by ten points")
      }
      let nudged = try document.editSession.bytesForSave()
      try key(123, flags: .command)
      guard try document.editSession.bytesForSave() == nudged, document.undoEdit(),
        try document.editSession.bytesForSave() == baseline else { throw PDFError(.malformed, "Modified shortcut moved images") }
      try key(51)
      guard Set((viewer.graphicsListProvider?(0) ?? []).map(\.identity)) == preexisting,
        document.undoEdit(),
        try document.editSession.bytesForSave() == baseline else { throw PDFError(.malformed, "Atomic image Delete/Undo failed") }
      checkpoint("image movement and resize checks passed")
      viewer.selectGraphics([viewer.graphicsListProvider!(0)[0]])
      let unrotated = viewer.selectedGraphicBounds!
      viewer.onRotateGraphic?(viewer.selectedGraphics[0])
      guard let turned = viewer.selectedGraphicBounds,
        abs(turned.midX - unrotated.midX) < 0.005, abs(turned.midY - unrotated.midY) < 0.005,
        abs(turned.width - unrotated.height) < 0.005 else {
        throw PDFError(.malformed, "Inserted image rotation moved its center")
      }
      viewer.setGraphicBounds(CGRect(x: turned.minX, y: turned.minY,
        width: turned.width * 1.5, height: turned.height * 0.5))
      guard let scaledTurned = viewer.selectedGraphicBounds,
        abs(scaledTurned.width - turned.width * 1.5) < 0.005,
        abs(scaledTurned.height - turned.height * 0.5) < 0.005,
        document.undoEdit(), document.undoEdit(), try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Rotated image resize or Undo failed")
      }
      viewer.selectGraphics(viewer.graphicsListProvider!(0))
      viewer.alignGraphics(.center); viewer.alignGraphics(.middle)
      guard let aligned = viewer.selectedGraphicBounds, let page = viewer.view.document?.page(at: 0),
        abs(aligned.midX - page.bounds(for: .cropBox).midX) < 0.005,
        abs(aligned.midY - page.bounds(for: .cropBox).midY) < 0.005 else {
        throw PDFError(.malformed, "Image group alignment failed")
      }
      let saved = output.appendingPathComponent("image-workflow.pdf")
      let error: Error? = await withCheckedContinuation { continuation in
        document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) { continuation.resume(returning: $0) }
      }
      if let error { throw error }
      checkpoint("image workflow save returned")
      let expected = viewer.selectedGraphics
      let sourceBytes = try Data(contentsOf: saved)
      document.close()
      let reopened = try SPDFDocument(contentsOf: saved, ofType: "com.adobe.pdf")
      controller.addDocument(reopened); reopened.makeWindowControllers()
      defer { reopened.close() }
      guard reopened.viewer?.graphicsListProvider?(0) == expected,
        PDFDocument(data: sourceBytes)?.pageCount == 1 else { throw PDFError(.malformed, "Saved image geometry changed after reopening") }
      checkpoint("image workflow reopen passed")
      guard let again = reopened.viewer else { throw PDFError(.malformed, "Missing reopened image viewer") }
      _ = again.activateTool(.imageEdit)
      again.selectGraphics(again.graphicsListProvider!(0))
      // A native field-editor undo registration does not itself edit the PDF.
      reopened.updateChangeCount(.changeDone)
      guard !reopened.isDocumentEdited else { throw PDFError(.malformed, "Native property draft dirtied the saved PDF") }
      again.alignGraphics(.left)
      guard reopened.isDocumentEdited, reopened.undoEdit(), !reopened.isDocumentEdited,
        try reopened.editSession.bytesForSave() == sourceBytes,
        reopened.redoEdit(), reopened.isDocumentEdited, reopened.undoEdit(), !reopened.isDocumentEdited else {
        throw PDFError(.malformed, "Image Undo/Redo disagreed with the saved PDF state")
      }
      // Use the actual native field editor: Save must include a number still
      // being typed, before SwiftUI delivers its deferred focus update.
      let propertyURL = output.appendingPathComponent("image-property-draft.pdf")
      try sourceBytes.write(to: propertyURL)
      let propertyDocument = try SPDFDocument(contentsOf: propertyURL, ofType: "com.adobe.pdf")
      controller.addDocument(propertyDocument); propertyDocument.makeWindowControllers()
      defer { propertyDocument.close() }
      guard let properties = propertyDocument.viewer,
        let propertyWindow = propertyDocument.windowControllers.first?.window,
        let propertyContent = propertyWindow.contentView else {
        throw PDFError(.malformed, "Missing property draft workspace")
      }
      propertyWindow.makeKeyAndOrderFront(nil)
      _ = properties.activateTool(.imageEdit)
      properties.selectGraphics(properties.graphicsListProvider!(0))
      try await Task.sleep(for: .milliseconds(100))
      let number = NumberFormatter()
      number.locale = .current; number.numberStyle = .decimal
      number.usesGroupingSeparator = false; number.maximumFractionDigits = 3
      let expectedWidth = number.string(from: NSNumber(value: properties.selectedGraphicBounds!.width))!
      func widthField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
          field.accessibilityLabel() == "Object Width" || field.stringValue == expectedWidth { return field }
        return view.subviews.lazy.compactMap { widthField($0) }.first
      }
      guard let field = widthField(propertyContent) else {
        throw PDFError(.malformed, "Missing native object-width field (\(expectedWidth))")
      }
      field.selectText(nil)
      guard let editor = field.currentEditor() as? NSTextView else {
        throw PDFError(.malformed, "Object-width field did not acquire its native editor")
      }
      editor.insertText("400", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
      try await Task.sleep(for: .milliseconds(50))
      guard abs((properties.selectedGraphicBounds?.width ?? 0) - 400) > 1 else {
        throw PDFError(.malformed, "Numeric draft applied before submission")
      }
      propertyDocument.save(nil)
      for _ in 0..<200 {
        try await Task.sleep(for: .milliseconds(10))
        if propertyDocument.jobCenter.jobs.isEmpty { break }
      }
      let written = try PDFParser.parse(Data(contentsOf: propertyURL))
      let writtenBounds = try AddedGraphics.selectable(pageID: written.pageIDs[0], in: written.graph).map {
        CGRect(x: $0.bounds[0], y: $0.bounds[1], width: $0.bounds[2] - $0.bounds[0], height: $0.bounds[3] - $0.bounds[1])
      }
      guard abs((GraphicSelectionModel.union(writtenBounds)?.width ?? 0) - 400) < 0.005,
        !propertyDocument.isDocumentEdited else {
        throw PDFError(.malformed, "One Save omitted the numeric property draft or left a second unsaved edit")
      }
      checkpoint("image property save passed")
      try JSONSerialization.data(withJSONObject: ["status": "passed", "objects": expected.map {
        ["id": $0.streamID.number, "rect": $0.rect] as [String: Any]
      }, "checks": "insert, exact properties, safe Select, first-drag move, Shift-selection, shared resize, Escape, keyboard, Delete/Undo, alignment, Save and reopen"],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("image-workflow.json"))
    }

    /// P48-013: exercise alpha through the native import path, canvas
    /// resizing, Save/reopen, per-instance replacement and a second Save.
    /// A colored image beneath the logo lets independent renderers prove that
    /// transparent pixels reveal page content rather than compositing to white.
    static func runTransparentImage(output: URL) async {
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previousRecovery = SPDFDocument.recoveryDirectoryOverride
        defer { SPDFDocument.recoveryDirectoryOverride = previousRecovery }
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
        let controller = NSDocumentController.shared
        let old = Set(controller.documents.map(ObjectIdentifier.init))
        controller.newDocument(nil)
        guard
          let document = controller.documents.first(where: {
            !old.contains(ObjectIdentifier($0))
          }) as? SPDFDocument,
          let viewer = document.viewer,
          let window = document.windowControllers.first?.window,
          let page = viewer.view.document?.page(at: 0)
        else { throw PDFError(.malformed, "Missing transparent-image workspace") }
        defer { document.close() }
        window.makeKeyAndOrderFront(nil)
        viewer.setZoom(1)

        let blue = try rasterPNG(width: 20, height: 20) { context in
          context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
          context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let logo = try rasterPNG(width: 30, height: 10) { context in
          context.clear(CGRect(x: 0, y: 0, width: 10, height: 10))
          context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
          context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
          context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
          context.fill(CGRect(x: 20, y: 0, width: 10, height: 10))
        }
        let replacement = try rasterPNG(width: 30, height: 10) { context in
          context.clear(CGRect(x: 0, y: 0, width: 10, height: 10))
          context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 0.5))
          context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
          context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
          context.fill(CGRect(x: 20, y: 0, width: 10, height: 10))
        }

        guard document.editSession.canEdit, ImageImport.decode(blue) != nil else {
          throw PDFError(
            .malformed,
            "Transparent fixture is not editable (canEdit=\(document.editSession.canEdit), "
              + "decodable=\(ImageImport.decode(blue) != nil))")
        }
        guard document.insertImage(blue, pageIndex: 0), let background = viewer.selectedGraphicBounds else {
          throw PDFError(.malformed, "Colored background insertion failed")
        }
        viewer.setGraphicBounds(CGRect(x: 100, y: 100, width: 412, height: 592))
        guard document.insertImage(logo, pageIndex: 0), viewer.selectedGraphicBounds != nil else {
          throw PDFError(.malformed, "Transparent logo insertion failed")
        }
        let logoBounds = CGRect(x: 180, y: 260, width: 300, height: 100)
        viewer.setGraphicBounds(logoBounds)
        guard let resizedBounds = viewer.selectedGraphicBounds,
          abs(resizedBounds.width - logoBounds.width) < 0.01,
          abs(resizedBounds.height - logoBounds.height) < 0.01
        else { throw PDFError(.malformed, "Transparent logo resize failed") }

        let pageID = document.editSession.pageIDs[0]
        guard let editedGraph = document.editSession.currentGraph else {
          throw PDFError(.malformed, "Transparent-image graph disappeared")
        }
        let placements = try ImageInventory.placements(in: editedGraph, pageID: pageID)
        guard placements.count == 2, placements.allSatisfy({ $0.isDirectlyEditable }) else {
          throw PDFError(.malformed, "Transparent-image inventory did not resolve both placements")
        }
        guard let logoPlacement = placements.first(where: {
          let bounds = $0.bounds
          return abs(bounds[0] - resizedBounds.minX) < 0.01
            && abs(bounds[1] - resizedBounds.minY) < 0.01
            && abs(bounds[2] - resizedBounds.maxX) < 0.01
            && abs(bounds[3] - resizedBounds.maxY) < 0.01
        }), case .stream(let logoStream)? = editedGraph.objects[logoPlacement.imageID],
          case .reference(let maskID)? = logoStream.dictionary[PDFName("SMask")],
          case .stream(let mask)? = editedGraph.objects[maskID]
        else { throw PDFError(.malformed, "Inserted logo has no addressable soft mask") }
        let maskSamples = try PDFFilters.decoded(mask)
        let rowSegmentsAreExact = maskSamples.count == 300 && (0..<10).allSatisfy { row in
          let start = row * 30
          return maskSamples[start..<(start + 10)].allSatisfy { $0 == 0 }
            && maskSamples[(start + 10)..<(start + 20)].allSatisfy { (120...136).contains($0) }
            && maskSamples[(start + 20)..<(start + 30)].allSatisfy { $0 == 255 }
        }
        guard rowSegmentsAreExact
        else {
          throw PDFError(
            .malformed,
            "Inserted logo alpha plane changed during import: "
              + "count=\(maskSamples.count), first row=\(Array(maskSamples.prefix(30)))")
        }

        let insertedURL = output.appendingPathComponent("transparent-inserted.pdf")
        try await save(document, to: insertedURL)
        document.close()

        let reopened = try SPDFDocument(contentsOf: insertedURL, ofType: "com.adobe.pdf")
        controller.addDocument(reopened)
        reopened.makeWindowControllers()
        defer { reopened.close() }
        guard let again = reopened.viewer, let graph = reopened.editSession.currentGraph,
          let reopenedPageID = reopened.editSession.pageIDs.first
        else { throw PDFError(.malformed, "Transparent image did not reopen") }
        let reopenedPlacements = try ImageInventory.placements(in: graph, pageID: reopenedPageID)
        guard let index = reopenedPlacements.firstIndex(where: {
          let bounds = $0.bounds
          return abs(bounds[0] - resizedBounds.minX) < 0.01
            && abs(bounds[1] - resizedBounds.minY) < 0.01
            && abs(bounds[2] - resizedBounds.maxX) < 0.01
            && abs(bounds[3] - resizedBounds.maxY) < 0.01
        }), reopened.replaceImage(pageIndex: 0, placementIndex: index, with: replacement, shared: false)
        else { throw PDFError(.malformed, "Transparent image replacement failed") }
        _ = again.activateTool(.imageEdit)
        again.selectGraphics((again.graphicsListProvider?(0) ?? []).filter {
          abs($0.rect[0] - resizedBounds.minX) < 0.02
            && abs($0.rect[1] - resizedBounds.minY) < 0.02
            && abs($0.rect[2] - resizedBounds.maxX) < 0.02
            && abs($0.rect[3] - resizedBounds.maxY) < 0.02
        })
        let finalBounds = CGRect(x: 210, y: 280, width: 260, height: 120)
        again.setGraphicBounds(finalBounds)
        guard let actualFinal = again.selectedGraphicBounds,
          abs(actualFinal.width - finalBounds.width) < 0.01,
          abs(actualFinal.height - finalBounds.height) < 0.01
        else { throw PDFError(.malformed, "Replacement image resize failed") }
        let replacedURL = output.appendingPathComponent("transparent-replaced.pdf")
        try await save(reopened, to: replacedURL)
        reopened.close()

        try JSONSerialization.data(withJSONObject: [
          "status": "passed",
          "insertedBounds": [logoBounds.minX, logoBounds.minY, logoBounds.maxX, logoBounds.maxY],
          "replacedBounds": [
            finalBounds.minX, finalBounds.minY, finalBounds.maxX, finalBounds.maxY,
          ],
          "insertedMaskBytes": maskSamples.count,
          "backgroundBounds": [background.minX, background.minY, background.maxX, background.maxY],
          "insertedSamples": [
            "transparent": [0.0, 0.0, 1.0],
            "halfRedOverBlue": [0.5, 0.0, 0.5],
            "opaqueGreen": [0.0, 1.0, 0.0],
          ],
          "replacedSamples": [
            "transparent": [0.0, 0.0, 1.0],
            "halfYellowOverBlue": [0.5, 0.5, 0.5],
            "opaqueMagenta": [1.0, 0.0, 1.0],
          ],
          "pageBounds": [page.bounds(for: .cropBox).minX, page.bounds(for: .cropBox).minY,
            page.bounds(for: .cropBox).maxX, page.bounds(for: .cropBox).maxY],
        ], options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("transparent-image.json"))
        print("sPDF transparent image check passed")
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("Transparent image smoke failed: \(error)\n".utf8))
        exit(1)
      }
    }

    private static func rasterPNG(
      width: Int, height: Int, draw: (CGContext) -> Void
    ) throws -> Data {
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw PDFError(.malformed, "Could not create transparent image fixture") }
      context.clear(CGRect(x: 0, y: 0, width: width, height: height))
      draw(context)
      guard let image = context.makeImage(),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      else { throw PDFError(.malformed, "Could not encode transparent image fixture") }
      return data
    }

    private static func save(_ document: SPDFDocument, to url: URL) async throws {
      let error: Error? = await withCheckedContinuation { continuation in
        document.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) {
          continuation.resume(returning: $0)
        }
      }
      if let error { throw error }
    }

    private static func nestedImageOverlapPDF() throws -> Data {
      let blank = try PDFParser.parse(BlankPDF.data(format: .letter))
      let pageID = blank.pageIDs[0]
      var graph = try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceImageCommand(
            pageID: pageID, rect: [250, 340, 350, 440], width: 2, height: 2,
            rgb8: Data([40, 120, 220, 40, 120, 220, 40, 120, 220, 40, 120, 220])
          )
        ]), to: blank.graph)

      func dictionary(_ value: PDFValue?, in graph: PDFGraph) -> [PDFName: PDFValue]? {
        switch value {
        case .dictionary(let value)?: return value
        case .reference(let id)?:
          guard case .dictionary(let value)? = graph.objects[id] else { return nil }
          return value
        default: return nil
        }
      }

      guard case .dictionary(var page)? = graph.objects[pageID],
        let pageResources = dictionary(page[PDFName("Resources")], in: graph)
      else { throw PDFError(.malformed, "Nested image fixture has no page resources") }
      let contentIDs: [PDFObjectID]
      switch page[PDFName("Contents")] {
      case .reference(let id)?: contentIDs = [id]
      case .array(let values)?:
        contentIDs = values.compactMap { if case .reference(let id) = $0 { return id }; return nil }
      default: contentIDs = []
      }
      guard !contentIDs.isEmpty else {
        throw PDFError(.malformed, "Nested image fixture has no page content")
      }
      var imageContent = Data()
      for id in contentIDs {
        guard case .stream(let stream)? = graph.objects[id] else {
          throw PDFError(.malformed, "Nested image fixture content stream is missing")
        }
        imageContent.append(stream.bytes)
        imageContent.append(10)
      }

      let formID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
      let wrapperID = PDFObjectID(formID.number + 1)
      graph.objects[formID] = .stream(PDFStream(dictionary: [
        PDFName("Type"): .name(PDFName("XObject")),
        PDFName("Subtype"): .name(PDFName("Form")),
        PDFName("BBox"): .array([.integer(0), .integer(0), .integer(612), .integer(792)]),
        PDFName("Resources"): .dictionary(pageResources),
      ], bytes: imageContent))

      var pageResourcesWithForm = pageResources
      var xObjects = dictionary(pageResources[PDFName("XObject")], in: graph) ?? [:]
      xObjects[PDFName("NestedForm")] = .reference(formID)
      pageResourcesWithForm[PDFName("XObject")] = .dictionary(xObjects)
      page[PDFName("Resources")] = .dictionary(pageResourcesWithForm)
      page[PDFName("Contents")] = .reference(wrapperID)
      graph.objects[pageID] = .dictionary(page)
      graph.objects[wrapperID] = .stream(
        PDFStream(bytes: Data("q /NestedForm Do Q\n".utf8)))
      try graph.validate()

      let withText = try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextObjectCommand(
            pageID: pageID, rect: [220, 360, 430, 410], text: "Nested image overlap",
            style: AddedTextStyle(size: 18))
        ]), to: graph)
      let bytes = try PDFWriter.write(withText)
      let reopened = try PDFParser.parse(bytes)
      let placements = try ImageInventory.placements(in: reopened.graph, pageID: pageID)
      guard placements.count == 1, placements[0].depth == 1,
        !placements[0].isDirectlyEditable else {
        throw PDFError(.malformed, "Nested image fixture did not retain its reusable-form placement")
      }
      return bytes
    }

    private static func checkNestedImageWorkflow(output: URL) async throws {
      let controller = NSDocumentController.shared
      let url = output.appendingPathComponent("nested-image-overlap.pdf")
      let source = try nestedImageOverlapPDF()
      try source.write(to: url, options: .atomic)
      let document = try SPDFDocument(contentsOf: url, ofType: "com.adobe.pdf")
      controller.addDocument(document)
      document.makeWindowControllers()
      defer { document.close() }
      guard let viewer = document.viewer,
        let window = document.windowControllers.first?.window,
        let content = window.contentView,
        let page = viewer.view.document?.page(at: 0)
      else { throw PDFError(.malformed, "Missing nested image workspace") }
      window.makeKeyAndOrderFront(nil)
      viewer.setZoom(0.8)
      try await Task.sleep(for: .milliseconds(120))

      let textSelection = viewer.view.document?.findString(
        "Nested image overlap", withOptions: []).first
      guard let textSelection else {
        throw PDFError(.malformed, "PDFKit could not find text over the nested image")
      }
      let textBounds = textSelection.bounds(for: page)
      let overlap = textBounds.intersection(CGRect(x: 250, y: 340, width: 100, height: 100))
      guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else {
        throw PDFError(.malformed, "Nested image and page text do not overlap")
      }
      let probe = [Double(overlap.midX), Double(overlap.midY)]
      guard let refusal = viewer.graphicRefusalProvider?(0, probe),
        refusal.contains("reusable form"),
        viewer.graphicTargetProvider?(0, probe) == nil,
        viewer.textRunProvider?(0, probe) != nil else {
        throw PDFError(.malformed, "Nested image overlap did not expose matching text and refusal targets")
      }
      func findGraphicOverlay(_ root: NSView) -> GraphicSelectionOverlayView? {
        if let overlay = root as? GraphicSelectionOverlayView { return overlay }
        return root.subviews.lazy.compactMap { findGraphicOverlay($0) }.first
      }
      func findTextOverlay(_ root: NSView) -> PageEditOverlayView? {
        if let overlay = root as? PageEditOverlayView { return overlay }
        return root.subviews.lazy.compactMap { findTextOverlay($0) }.first
      }
      guard let graphicOverlay = findGraphicOverlay(content),
        findTextOverlay(content) != nil else {
        throw PDFError(.malformed, "Nested overlap overlays are missing")
      }
      func point(_ x: Double, _ y: Double) -> NSPoint {
        viewer.view.convert(viewer.view.convert(NSPoint(x: x, y: y), from: page), to: nil)
      }
      func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { throw PDFError(.malformed, "Missing nested overlap pointer event") }
        return event
      }

      let baseline = try document.editSession.bytesForSave()
      guard viewer.activateTool(.imageEdit) else {
        throw PDFError(.malformed, "Could not enter Images mode for a nested image")
      }
      let windowPoint = point(probe[0], probe[1])
      graphicOverlay.mouseDown(with: try mouse(.leftMouseDown, windowPoint))
      graphicOverlay.mouseUp(with: try mouse(.leftMouseUp, windowPoint))
      try await Task.sleep(for: .milliseconds(100))
      guard viewer.selectedGraphics.isEmpty,
        viewer.selectionDetails?.text == refusal,
        viewer.graphicEditRefusal == refusal,
        AccessibilityAudit.keyWindowElement(labeled: "Image editing unavailable") != nil,
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed,
          "Images mode did not show the nested-image refusal or preserve source bytes "
            + "(selected=\(viewer.selectedGraphics.count), details=\(viewer.selectionDetails?.text ?? "nil"), "
            + "refusal=\(viewer.graphicEditRefusal ?? "nil"), ax=\(AccessibilityAudit.keyWindowElement(labeled: "Image editing unavailable") != nil), "
            + "bytes=\(try document.editSession.bytesForSave() == baseline))")
      }

      guard viewer.activateTool(.textEdit) else {
        throw PDFError(.malformed, "Could not enter Edit PDF mode over a nested image")
      }
      guard let nestedTextTarget = viewer.textRunProvider?(0, probe) else {
        throw PDFError(.malformed, "Page text target disappeared after refusing the nested image")
      }
      let nestedPreviewAvailable = viewer.onTextBlockPreview?(nestedTextTarget) != nil
      guard let currentTextOverlay = findTextOverlay(content) else {
        throw PDFError(.malformed, "Edit PDF overlay disappeared after the refusal message")
      }
      let currentWindowPoint = point(probe[0], probe[1])
      currentTextOverlay.mouseDown(with: try mouse(.leftMouseDown, currentWindowPoint))
      currentTextOverlay.mouseUp(with: try mouse(.leftMouseUp, currentWindowPoint))
      guard viewer.isEditingPageText, viewer.selectedGraphics.isEmpty else {
        throw PDFError(.malformed,
          "Edit PDF did not select visible page text over a nested image "
            + "(editing=\(viewer.isEditingPageText), canEdit=\(document.canEditContent), "
            + "allows=\(viewer.allowsContentEditing), reason=\(viewer.editingRestrictionNotice ?? "nil"), "
            + "target=true, preview=\(nestedPreviewAvailable), rotation=\(page.rotation), "
            + "bounds=\(nestedTextTarget.rect), selection=\(viewer.view.currentSelection?.string ?? "nil"))")
      }
      viewer.pageTextCancel?()
      guard !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Canceling nested-overlap text editing changed the PDF")
      }
      checkpoint("nested-image refusal and text selection passed")
    }

    private static func checkReadOnlyExplanation(output: URL) async throws {
      let controller = NSDocumentController.shared
      let graph = try PDFParser.parse(BlankPDF.data(format: .letter)).graph
      let protectedBytes = try PDFWriter.write(graph, encryption: PDFEncryptionOptions(
        userPassword: "user", ownerPassword: "owner", permissions: 4 | 16))
      let url = output.appendingPathComponent("permission-read-only.pdf")
      try protectedBytes.write(to: url, options: .atomic)
      let document = try SPDFDocument(contentsOf: url, ofType: "com.adobe.pdf")
      controller.addDocument(document)
      document.makeWindowControllers()
      defer { document.close() }
      guard let viewer = document.viewer,
        let window = document.windowControllers.first?.window else {
        throw PDFError(.malformed, "Missing password-permission workspace")
      }
      window.makeKeyAndOrderFront(nil)
      guard viewer.isLocked, viewer.unlock(password: "user") else {
        throw PDFError(.malformed, "Permission fixture did not open with its user password")
      }
      document.unlockCoreSession(with: "user")
      try await Task.sleep(for: .milliseconds(100))
      let original = try document.editSession.bytesForSave()
      var refusals: [(restriction: DocumentEditingRestriction, action: String)] = []
      var lastAlertTitle = ""
      var lastAlertMessage = ""
      SPDFDocument.editingRestrictionHandler = { restriction, action, alert in
        refusals.append((restriction, action))
        lastAlertTitle = alert.messageText
        lastAlertMessage = alert.informativeText
        return true
      }
      defer { SPDFDocument.editingRestrictionHandler = nil }

      document.formsModel.pendingText["draft-field"] = "Keep this draft"
      document.editSelectedText()
      document.reflowParagraph()
      _ = document.rotateImage(pageIndex: 0, placementIndex: 0, degrees: 90)
      _ = document.fillFormText(fieldName: "draft-field", text: "Blocked fill")
      let preservedDraft = document.formsModel.pendingText["draft-field"]
      document.formsModel.pendingText["draft-field"] = nil
      _ = document.applyFlattenForm()
      _ = document.setDocumentMetadata(
        DocumentMetadata(
          title: "Blocked", author: nil, subject: nil, keywords: nil,
          creator: nil, producer: nil))
      let derivativeRefusal: String? = {
        do {
          try document.writeArchivalCopy(
            to: output.appendingPathComponent("blocked-archival.pdf"))
          return nil
        } catch {
          return error.localizedDescription
        }
      }()

      let blockedAdd = document.addPageText(
        pageIndex: 0, rect: [72, 120, 280, 150], text: "Blocked edit")
      let refusalActions = refusals.map(\.action)
      let refusalRestrictions = Set(refusals.map(\.restriction))
      let expectedActions: [String] = [
        "Edit Text", "Reflow Paragraph", "Image Editing", "Change Form Value",
        "Flatten Form", "Document Metadata", "Add Text",
      ]
      let sourceUnchanged = try document.editSession.bytesForSave() == original
      window.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(100))
      let restrictionMatches = document.contentEditingRestriction == .permissionDenied
      let noticeMatches =
        viewer.editingRestrictionNotice == DocumentEditingRestriction.permissionDenied.message
      let readOnlyFlags = !document.canEditContent && !viewer.allowsContentEditing
      let noticeContains =
        viewer.editingRestrictionNotice?.contains("password allows reading but not modification")
        == true
      let noTraversal = !viewer.canSelectAdjacentPageObject
      let inlineRefusal = viewer.textEditRefusalProvider?(0, [72, 120])
      let imageRefusal = viewer.graphicRefusalProvider?(0, [72, 120])
      let bannerVisible =
        AccessibilityAudit.keyWindowElement(labeled: "Editing unavailable") != nil
      let actionsMatch = refusalActions == expectedActions
      let restrictionsMatch = refusalRestrictions == [.permissionDenied]
      let alertTitleMatches = lastAlertTitle == "Add Text Unavailable"
      let alertMessageMatches = lastAlertMessage.contains(
        "Nothing was changed. Any open editor or draft has been left intact.")
      let derivativeMatches =
        derivativeRefusal?.contains("password allows reading but not modification") == true
      guard restrictionMatches,
        noticeMatches,
        readOnlyFlags,
        noticeContains,
        noTraversal,
        inlineRefusal == DocumentEditingRestriction.permissionDenied.message,
        imageRefusal == DocumentEditingRestriction.permissionDenied.message,
        bannerVisible,
        !blockedAdd,
        preservedDraft == "Keep this draft",
        actionsMatch,
        restrictionsMatch,
        alertTitleMatches,
        alertMessageMatches,
        derivativeMatches,
        sourceUnchanged
      else {
        throw PDFError(.malformed,
          "Password permissions were not explained at the point of use or the source changed "
            + "(restriction=\(restrictionMatches), notice=\(noticeMatches), flags=\(readOnlyFlags), "
            + "contains=\(noticeContains), traversal=\(noTraversal), banner=\(bannerVisible), "
            + "inline=\(inlineRefusal ?? "nil"), image=\(imageRefusal ?? "nil"), "
            + "add=\(blockedAdd), draft=\(preservedDraft ?? "nil"), actions=\(actionsMatch), "
            + "restrictions=\(restrictionsMatch), alertTitle=\(alertTitleMatches), "
            + "alertMessage=\(alertMessageMatches), derivative=\(derivativeMatches), "
            + "bytes=\(sourceUnchanged), actualTitle=\(lastAlertTitle), "
            + "actualActions=\(refusalActions), actualDerivative=\(derivativeRefusal ?? "nil"))")
      }

      // A real protected form must keep its sidebar draft when the fill is
      // refused. This uses the form fixture rather than a synthetic field.
      let formFixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures/form-pages.pdf")
      let formGraph = try PDFParser.parse(Data(contentsOf: formFixture)).graph
      let protectedFormBytes = try PDFWriter.write(
        formGraph,
        encryption: PDFEncryptionOptions(
          userPassword: "user", ownerPassword: "owner", permissions: 4 | 16))
      let protectedFormURL = output.appendingPathComponent("permission-form.pdf")
      try protectedFormBytes.write(to: protectedFormURL, options: .atomic)
      let formDocument = try SPDFDocument(
        contentsOf: protectedFormURL, ofType: "com.adobe.pdf")
      controller.addDocument(formDocument)
      formDocument.makeWindowControllers()
      defer { formDocument.close() }
      guard let formViewer = formDocument.viewer,
        formViewer.unlock(password: "user")
      else { throw PDFError(.malformed, "Protected form did not unlock") }
      formDocument.unlockCoreSession(with: "user")
      try await Task.sleep(for: .milliseconds(100))
      guard let field = formDocument.editSession.formFields().first(where: { $0.kind == .text }),
        let formWindow = formDocument.windowControllers.first?.window
      else { throw PDFError(.malformed, "Protected form has no editable text field") }
      formWindow.makeKeyAndOrderFront(nil)
      let formRevision = formDocument.editSession.documentRevision
      let formWasDirty = formDocument.editSession.isDirty
      formDocument.formsModel.pendingText[field.name] = "Keep form draft"
      let formFillAccepted = formDocument.fillFormText(
        fieldName: field.name, text: "Blocked fill")
      let formSourceUnchanged =
        try Data(contentsOf: protectedFormURL) == protectedFormBytes
      guard !formFillAccepted,
        formDocument.formsModel.pendingText[field.name] == "Keep form draft",
        formDocument.editSession.documentRevision == formRevision,
        formDocument.editSession.isDirty == formWasDirty,
        formSourceUnchanged
      else {
        throw PDFError(
          .malformed,
          "A refused form fill lost its draft or changed the source "
            + "(accepted=\(formFillAccepted), restriction=\(String(describing: formDocument.contentEditingRestriction)), "
            + "draft=\(formDocument.formsModel.pendingText[field.name] ?? "nil"), "
            + "revision=\(formDocument.editSession.documentRevision == formRevision), "
            + "dirty=\(formDocument.editSession.isDirty == formWasDirty), "
            + "source=\(formSourceUnchanged))")
      }
      checkpoint("password-limited read-only explanation passed")
    }

    private static func clippingTextPDF() throws -> Data {
      let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures/text-edit.pdf")
      let parsed = try PDFParser.parse(Data(contentsOf: fixtureURL))
      var graph = parsed.graph
      guard case .stream(let stream)? = graph.objects[PDFObjectID(5)] else {
        throw PDFError(.malformed, "Clipping-text fixture stream is missing")
      }
      graph.objects[PDFObjectID(5)] = .stream(
        PDFStream(dictionary: stream.dictionary, bytes: Data("4 Tr\n".utf8) + stream.bytes))
      let bytes = try PDFWriter.write(graph)
      let reopened = try PDFParser.parse(bytes)
      let pageID = reopened.pageIDs[0]
      let layout = try PageTextLayout.build(pageID: pageID, in: reopened.graph)
      let blocks = try PageTextEditing.blocks(pageID: pageID, in: reopened.graph)
      let refusals = try PageTextEditing.editRefusalTargets(pageID: pageID, in: reopened.graph)
      let refusalText = refusals.map(\.reason).joined(separator: " | ")
      let runIndex = layout.clusters.first?.runIndex ?? -1
      let assessment = TextEditabilityCheck.assess(
        pageID: pageID, runIndex: runIndex, in: reopened.graph)
      guard layout.clusters.map(\.text).joined().contains("Replace this text"),
        refusalText.contains("clipping mode") else {
        throw PDFError(.malformed,
          "Clipping-text fixture did not expose a visible refusal target "
            + "(clusters=\(layout.clusters.count), blocks=\(blocks.count), "
            + "assessment=\(assessment.reasons), refusal=\(refusalText))")
      }
      return bytes
    }

    /// TXT-07: exercise the real viewer callbacks, a document-scope preview,
    /// one atomic replace transaction and exact document Undo/Redo.
    private static func checkFindReplaceWorkflow(output: URL) async throws {
      let controller = NSDocumentController.shared
      let prior = Set(controller.documents.map(ObjectIdentifier.init))
      controller.newDocument(nil)
      guard let document = controller.documents.first(where: {
        !prior.contains(ObjectIdentifier($0))
      }) as? SPDFDocument, let viewer = document.viewer,
        let window = document.windowControllers.first?.window else {
        throw PDFError(.malformed, "Missing Find and Replace workspace")
      }
      defer { document.close() }
      window.makeKeyAndOrderFront(nil)
      guard document.addPageText(
        pageIndex: 0, rect: [72, 300, 430, 340], text: "Replace me replace me",
        style: PageTextStyle(fontSize: 14)) else {
        throw PDFError(.malformed, "Find and Replace fixture could not be added")
      }
      let baseline = try document.editSession.bytesForSave()
      viewer.searchText = "replace"
      viewer.replaceText = "swap"
      viewer.findReplaceScope = .document
      viewer.showFindReplace()
      guard viewer.isFindReplaceVisible else {
        throw PDFError(.malformed, "Find and Replace panel did not open")
      }
      viewer.previewFindReplace()
      guard let preview = viewer.findReplacePreview,
        preview.eligibleCount == 2, preview.refusedCount == 0,
        preview.matches.count == 2 else {
        throw PDFError(.malformed,
          "Find and Replace preview did not identify both matches: "
            + String(describing: viewer.findReplacePreview))
      }
      viewer.applyFindReplace()
      guard let result = viewer.findReplaceResult, result.replacedCount == 2,
        result.refusedCount == 0,
        viewer.view.document?.string?.contains("swap me swap me") == true else {
        throw PDFError(.malformed,
          "Find and Replace did not apply as one transaction: "
            + String(describing: viewer.findReplaceResult))
      }
      let edited = try document.editSession.bytesForSave()
      let findReplaceURL = output.appendingPathComponent("find-replace.pdf")
      try edited.write(to: findReplaceURL, options: .atomic)
      guard let reopened = PDFDocument(url: findReplaceURL),
        reopened.string?.contains("swap me swap me") == true,
        try Data(contentsOf: findReplaceURL).count > 0,
        document.undoEdit(), try document.editSession.bytesForSave() == baseline,
        document.redoEdit(), try document.editSession.bytesForSave() == edited else {
        throw PDFError(.malformed, "Find and Replace Undo/Redo did not restore exact bytes")
      }
    }

    private static func checkTextEditRefusal(output: URL) async throws {
      let controller = NSDocumentController.shared
      let url = output.appendingPathComponent("clipping-text-refusal.pdf")
      let source = try clippingTextPDF()
      try source.write(to: url, options: .atomic)
      let document = try SPDFDocument(contentsOf: url, ofType: "com.adobe.pdf")
      controller.addDocument(document)
      document.makeWindowControllers()
      defer { document.close() }
      guard let viewer = document.viewer,
        let window = document.windowControllers.first?.window,
        let page = viewer.view.document?.page(at: 0),
        let content = window.contentView else {
        throw PDFError(.malformed, "Missing clipping-text workspace")
      }
      window.makeKeyAndOrderFront(nil)
      viewer.setZoom(0.8)
      try await Task.sleep(for: .milliseconds(100))
      guard let selection = viewer.view.document?.findString(
        "Replace this text", withOptions: []).first else {
        throw PDFError(.malformed, "PDFKit could not find the clipping-mode text")
      }
      let bounds = selection.bounds(for: page)
      guard let graph = document.editSession.currentGraph,
        let pageID = document.editSession.pageIDs.first,
        let refusalTarget = try PageTextEditing.editRefusalTargets(pageID: pageID, in: graph).first
      else { throw PDFError(.malformed, "Clipping-mode refusal geometry is missing") }
      let pagePoint = [
        (refusalTarget.rect[0] + refusalTarget.rect[2]) / 2,
        (refusalTarget.rect[1] + refusalTarget.rect[3]) / 2,
      ]
      let reason = viewer.textEditRefusalProvider?(0, pagePoint)
      guard reason?.contains("clipping mode") == true,
        viewer.textRunProvider?(0, pagePoint) == nil,
        viewer.activateTool(.textEdit) else {
        throw PDFError(.malformed,
          "Clipping-mode text did not resolve to a specific inline refusal "
            + "(reason=\(reason ?? "nil"), target=\(refusalTarget.rect), pdfKit=\(bounds))")
      }
      func findOverlay(_ root: NSView) -> PageEditOverlayView? {
        if let overlay = root as? PageEditOverlayView { return overlay }
        return root.subviews.lazy.compactMap { findOverlay($0) }.first
      }
      guard let overlay = findOverlay(content) else {
        throw PDFError(.malformed, "Clipping-text page overlay is missing")
      }
      func mouse(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseUp ? 0 : 1)
        else { throw PDFError(.malformed, "Missing clipping-text pointer event") }
        return event
      }
      let original = try document.editSession.bytesForSave()
      let viewPoint = viewer.view.convert(NSPoint(x: pagePoint[0], y: pagePoint[1]), from: page)
      let windowPoint = viewer.view.convert(viewPoint, to: nil)
      let overlayPoint = overlay.convert(windowPoint, from: nil)
      guard overlay.hitTest(overlayPoint) === overlay else {
        throw PDFError(.malformed, "The overlay did not capture the unsupported text hit")
      }
      overlay.mouseDown(with: try mouse(.leftMouseDown, windowPoint))
      overlay.mouseUp(with: try mouse(.leftMouseUp, windowPoint))
      try await Task.sleep(for: .milliseconds(100))
      guard viewer.textEditRefusal?.contains("clipping mode") == true,
        !viewer.isEditingPageText,
        AccessibilityAudit.keyWindowElement(labeled: "Inline text editing unavailable") != nil,
        try document.editSession.bytesForSave() == original else {
        throw PDFError(.malformed,
          "The text refusal was not visible/accessible or the source changed "
            + "(reason=\(viewer.textEditRefusal ?? "nil"), editing=\(viewer.isEditingPageText), "
            + "ax=\(AccessibilityAudit.keyWindowElement(labeled: "Inline text editing unavailable") != nil), "
            + "bytes=\(try document.editSession.bytesForSave() == original))")
      }
      checkpoint("clipping-mode text refusal and unchanged source passed")
    }

    private static func clippedImagePDF(path: String) throws -> Data {
      let blank = try PDFParser.parse(BlankPDF.data(format: .letter))
      let pageID = blank.pageIDs[0]
      var graph = try PDFEditingEngine.commit(
        PDFTransaction([
          PlaceImageCommand(
            pageID: pageID, rect: [250, 300, 350, 400], width: 2, height: 2,
            rgb8: Data([40, 120, 220, 40, 120, 220, 40, 120, 220, 40, 120, 220])
          )
        ]), to: blank.graph)
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "Clipped image fixture has no page")
      }
      let contentIDs: [PDFObjectID]
      switch page[PDFName("Contents")] {
      case .reference(let id)?: contentIDs = [id]
      case .array(let values)?:
        contentIDs = values.compactMap { if case .reference(let id) = $0 { return id }; return nil }
      default: contentIDs = []
      }
      guard !contentIDs.isEmpty else {
        throw PDFError(.malformed, "Clipped image fixture has no page content")
      }
      var imageContent = Data()
      for id in contentIDs {
        guard case .stream(let stream)? = graph.objects[id] else {
          throw PDFError(.malformed, "Clipped image content stream is missing")
        }
        imageContent.append(contentsOf: try PDFFilters.decoded(stream))
        imageContent.append(10)
      }
      let wrapperID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
      page[PDFName("Contents")] = .reference(wrapperID)
      graph.objects[pageID] = .dictionary(page)
      graph.objects[wrapperID] = .stream(
        PDFStream(bytes: Data("q \(path)\n".utf8) + imageContent + Data("Q\n".utf8)))
      graph.trailer[PDFName("Size")] = .integer(Int64(wrapperID.number + 1))
      let bytes = try PDFWriter.write(graph)
      let reopened = try PDFParser.parse(bytes)
      let placements = try ImageInventory.placements(in: reopened.graph, pageID: pageID)
      guard placements.count == 1, placements[0].bounds == [250, 300, 350, 400] else {
        throw PDFError(.malformed, "Clipped image fixture lost its placement")
      }
      return bytes
    }

    private static func checkClippedImageWorkflow(output: URL) async throws {
      let controller = NSDocumentController.shared
      let url = output.appendingPathComponent("clipped-image.pdf")
      let source = try clippedImagePDF(path: "300 340 20 20 re W n")
      try source.write(to: url, options: .atomic)
      let document = try SPDFDocument(contentsOf: url, ofType: "com.adobe.pdf")
      controller.addDocument(document)
      document.makeWindowControllers()
      defer { document.close() }
      guard let viewer = document.viewer,
        let window = document.windowControllers.first?.window,
        let page = viewer.view.document?.page(at: 0)
      else { throw PDFError(.malformed, "Missing clipped image workspace") }
      window.makeKeyAndOrderFront(nil)
      viewer.setZoom(0.8)
      try await Task.sleep(for: .milliseconds(100))

      let hidden = [260.0, 310.0]
      let visible = [310.0, 350.0]
      let targets = viewer.graphicsListProvider?(0) ?? []
      guard targets.count == 1,
        targets[0].rect == [250, 300, 350, 400],
        targets[0].hitRect == [300, 340, 320, 360],
        viewer.graphicTargetProvider?(0, visible) != nil,
        viewer.graphicTargetProvider?(0, hidden) == nil,
        viewer.graphicRefusalProvider?(0, hidden) == nil else {
        throw PDFError(.malformed, "Rectangular clip did not narrow native image hit testing")
      }
      func findGraphicOverlay(_ root: NSView) -> GraphicSelectionOverlayView? {
        if let overlay = root as? GraphicSelectionOverlayView { return overlay }
        return root.subviews.lazy.compactMap { findGraphicOverlay($0) }.first
      }
      guard let content = window.contentView, let overlay = findGraphicOverlay(content) else {
        throw PDFError(.malformed, "Clipped image overlay is missing")
      }
      func point(_ values: [Double]) -> NSPoint {
        viewer.view.convert(
          viewer.view.convert(NSPoint(x: values[0], y: values[1]), from: page), to: nil)
      }
      func mouse(_ type: NSEvent.EventType, _ location: NSPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseUp ? 0 : 1)
        else { throw PDFError(.malformed, "Missing clipped-image pointer event") }
        return event
      }

      let baseline = try document.editSession.bytesForSave()
      guard viewer.activateTool(.imageEdit) else {
        throw PDFError(.malformed, "Could not enter Images mode for a clipped image")
      }
      let dragStart = point([255, 305])
      let dragEnd = point([280, 330])
      overlay.mouseDown(with: try mouse(.leftMouseDown, dragStart))
      overlay.mouseDragged(with: try mouse(.leftMouseDragged, dragEnd))
      overlay.mouseUp(with: try mouse(.leftMouseUp, dragEnd))
      guard viewer.selectedGraphics.isEmpty else {
        throw PDFError(.malformed, "Rubber-band selection included a fully clipped image area")
      }

      let visiblePoint = point(visible)
      overlay.mouseDown(with: try mouse(.leftMouseDown, visiblePoint))
      overlay.mouseUp(with: try mouse(.leftMouseUp, visiblePoint))
      guard viewer.selectedGraphics.count == 1,
        viewer.selectedGraphics[0].imagePlacementIndex == 0,
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Visible clipped-image area did not select without mutation")
      }

      let unsupportedURL = output.appendingPathComponent("nonrectangular-clipped-image.pdf")
      let unsupportedSource = try clippedImagePDF(
        path: "300 340 m 320 340 l 300 360 l h W n")
      try unsupportedSource.write(to: unsupportedURL, options: .atomic)
      let unsupported = try SPDFDocument(contentsOf: unsupportedURL, ofType: "com.adobe.pdf")
      controller.addDocument(unsupported)
      unsupported.makeWindowControllers()
      defer { unsupported.close() }
      guard let unsupportedViewer = unsupported.viewer else {
        throw PDFError(.malformed, "Missing nonrectangular clipped-image workspace")
      }
      let reason = unsupportedViewer.graphicRefusalProvider?(0, visible)
      let unsupportedBaseline = try unsupported.editSession.bytesForSave()
      guard reason?.contains("cannot hit-test exactly") == true,
        unsupportedViewer.graphicTargetProvider?(0, visible) == nil,
        try unsupported.editSession.bytesForSave() == unsupportedBaseline else {
        throw PDFError(.malformed, "Unsupported clipping did not explain the canvas refusal safely")
      }
      checkpoint("clipped-image hit regions and refusal passed")
    }

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
      checkpoint("creating blank workspace document")
      controller.newDocument(nil)
      checkpoint("blank workspace document created")
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
      checkpoint("blank authoring save and undo passed")

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
      try await checkCommandScroll(viewer, window: window)
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
      viewer.pageTextAlignmentApplier?(.center)
      guard abs(selected.pageBox().x + selected.pageBox().width / 2 - page.bounds(for: .cropBox).midX) < 0.005 else {
        throw PDFError(.malformed, "Text page alignment failed")
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
      checkpoint("selection and IME workflow passed")

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
      // SwiftUI can inset the representable inside the PDF view. Exercise the
      // hit resolver with a deliberate offset so "first point in view space"
      // regressions cannot select an adjacent block.
      let overlayFrame = overlay.frame
      overlay.frame = overlayFrame.offsetBy(dx: 29, dy: 17)
      overlay.mouseDown(with: try mouse(.leftMouseDown, point: paragraphPointer))
      overlay.mouseUp(with: try mouse(.leftMouseUp, point: paragraphPointer))
      let offsetCanvas = findCanvas(content)
      overlay.frame = overlayFrame
      guard let paragraphCanvas = offsetCanvas,
        paragraphCanvas.sourceTarget?.paragraph?.originalText.count == paragraphLines.count,
        !viewer.isTypingPageText,
        try document.editSession.bytesForSave() == paragraphBaseline
      else { throw PDFError(.malformed, "A paragraph was not selected as one non-mutating object") }
      let styleBefore = paragraphCanvas.pageLines()
      // TXT-04: deliberately wide leading (42 pt for 16 pt type) must not
      // make the reopened paragraph split apart under the 1.8× gap heuristic.
      let paragraphStyle = PageTextParagraphStyle(
        alignment: .center, leading: 42, spacingBefore: 5, spacingAfter: 7,
        leftIndent: 12, rightIndent: 10, firstLineIndent: 8)
      viewer.pageTextParagraphStyleApplier?(paragraphStyle)
      let styleAfter = paragraphCanvas.pageLines()
      guard viewer.pageTextParagraphStyle == paragraphStyle,
        styleAfter.dropFirst().first?.baseline != styleBefore.dropFirst().first?.baseline,
        styleAfter.first?.x != styleBefore.first?.x,
        viewer.hasPendingPageTextChanges
      else {
        throw PDFError(
          .malformed,
          "Paragraph alignment/leading/indent controls did not preview live "
            + "(style=\(viewer.pageTextParagraphStyle), before=\(styleBefore.first?.x ?? -1)/\(styleBefore.first?.baseline ?? -1), "
            + "after=\(styleAfter.first?.x ?? -1)/\(styleAfter.first?.baseline ?? -1), "
            + "pending=\(viewer.hasPendingPageTextChanges))")
      }
      paragraphCanvas.beginTyping()
      let replacement = "A longer paragraph is edited directly on the page. Native wrapping follows the width of the text box, and the saved document keeps exactly the line positions shown while typing. Every unrelated line stays in its original place."
      paragraphCanvas.textView.insertText(replacement,
        replacementRange: NSRange(location: 0, length: (paragraphCanvas.textView.string as NSString).length))
      try await checkCommandScroll(viewer, window: window)
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
      checkpoint("paragraph edit and undo passed")
      guard let repeatPage = viewer.view.document?.page(at: 0),
        let repeatSelection = viewer.view.document?.findString(
          expectedLines[0].text.trimmingCharacters(in: .whitespaces), withOptions: []).first
      else { throw PDFError(.malformed, "Cannot find the saved paragraph") }
      let repeatBounds = repeatSelection.bounds(for: repeatPage)
      guard viewer.textRunProvider?(
        0, [repeatBounds.midX, repeatBounds.midY])?.paragraph != nil
      else { throw PDFError(.malformed, "The saved paragraph cannot be selected for another edit") }

      let repeatPointer = viewer.view.convert(
        viewer.view.convert(NSPoint(x: repeatBounds.midX, y: repeatBounds.midY), from: repeatPage), to: nil)
      overlay.mouseDown(with: try mouse(.leftMouseDown, point: repeatPointer))
      overlay.mouseUp(with: try mouse(.leftMouseUp, point: repeatPointer))
      checkpoint("character formatting box reselected")
      guard let formatted = findCanvas(content) else {
        throw PDFError(.malformed, "Missing character-formatting canvas")
      }
      // Menu actions resolve through NSDocumentController.currentDocument, so
      // the workspace document must own the key window for this check.
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .milliseconds(200))
      formatted.beginTyping()
      guard formatted.textView.isContinuousSpellCheckingEnabled,
        !formatted.textView.isAutomaticSpellingCorrectionEnabled else {
        throw PDFError(.malformed, "Spell suggestions were unavailable or automatic correction was on")
      }
      // TXT-08: user-driven correction is reachable through the standard
      // spelling panel, and the app-level toggle stays in sync with the native
      // text view instead of drifting from it.
      let checkItem = KeyboardAudit.find("Check Spelling…")
      let guessItem = KeyboardAudit.find("Show Spelling and Grammar")
      guard let checkSpelling = checkItem,
        checkSpelling.action == #selector(NSText.checkSpelling(_:)),
        guessItem?.action == #selector(NSText.showGuessPanel(_:))
      else {
        throw PDFError(
          .malformed,
          "Spelling correction menu is not wired (check=\(String(describing: checkItem?.action)), "
            + "guess=\(String(describing: guessItem?.action)))")
      }
      let toggledOff = KeyboardAudit.invoke("Check Spelling While Typing")
      let stateAfterOff = viewer.pageTextSpellChecking
      let nativeAfterOff = formatted.textView.isContinuousSpellCheckingEnabled
      let toggledOn = KeyboardAudit.invoke("Check Spelling While Typing")
      guard toggledOff, !stateAfterOff, !nativeAfterOff, toggledOn,
        viewer.pageTextSpellChecking, formatted.textView.isContinuousSpellCheckingEnabled
      else {
        throw PDFError(
          .malformed,
          "Spell toggle did not sync (invoked=\(toggledOff)/\(toggledOn), "
            + "state=\(stateAfterOff)->\(viewer.pageTextSpellChecking), "
            + "native=\(nativeAfterOff)->\(formatted.textView.isContinuousSpellCheckingEnabled))")
      }
      viewer.pageTextSpellCheckingApplier?(false)
      guard !formatted.textView.isContinuousSpellCheckingEnabled else {
        throw PDFError(.malformed, "Spell-check toggle did not disable native checking")
      }
      viewer.pageTextSpellCheckingApplier?(true)
      checkpoint("character formatting typing started")
      let styledText = "\nKeep these words in a different style. The rest of this paragraph keeps its own font and wraps naturally.\n\nNext paragraph keeps its blank line."
      formatted.textView.insertText(styledText, replacementRange:
        NSRange(location: 0, length: (formatted.textView.string as NSString).length))
      checkpoint("character formatting text inserted")
      // This diagnostic runs inside one asynchronous launch task rather than
      // separate AppKit input events. Explicitly delimit its format actions.
      formatted.textView.breakUndoCoalescing()
      while formatted.textView.typingUndo.groupingLevel > 0 {
        formatted.textView.typingUndo.endUndoGrouping()
      }
      formatted.textView.typingUndo.groupsByEvent = false
      formatted.setTextWidth(287.125)
      formatted.textView.setSelectedRange((styledText as NSString).range(of: "these words"))
      checkpoint("character formatting selection set")
      func formatKey(_ key: String, code: UInt16) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: key,
          charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)
        else { throw PDFError(.malformed, "Missing formatting key event") }
        return event
      }
      guard formatted.textView.performKeyEquivalent(with: try formatKey("b", code: 11)),
        formatted.textView.performKeyEquivalent(with: try formatKey("i", code: 34)) else {
        throw PDFError(.malformed, "Native formatting shortcuts were not handled")
      }
      checkpoint("character formatting shortcuts passed")
      viewer.pageTextFormattingApplier?(.family(.times))
      viewer.pageTextFormattingApplier?(.size(18))
      viewer.pageTextFormattingApplier?(.color([0.8, 0.1, 0.2]))
      checkpoint("character formatting inspector styles applied")
      func emphasizedSegments() -> [PageTextSegment] {
        formatted.pageLines().flatMap(\.segments).filter { $0.text.contains("these words") }
      }
      guard let emphasized = emphasizedSegments().first,
        emphasized.format.font == .timesBoldItalic, emphasized.format.size == 18,
        emphasized.format.color == [0.8, 0.1, 0.2],
        viewer.pageTextSelectionScope == "Selected characters" else {
        throw PDFError(.malformed, "Selected-word formatting lost its traits or scope")
      }
      checkpoint("character formatting selected-word verification passed")
      guard window.makeFirstResponder(formatted), document.undoEdit(),
        viewer.isEditingPageText
      else {
        throw PDFError(.malformed, "Document Undo did not target the pending inline-format draft")
      }
      guard emphasizedSegments().first?.format.color == [0, 0, 0] else {
        throw PDFError(.malformed, "Inline-format Undo did not restore color independently")
      }
      guard document.redoEdit(), viewer.isEditingPageText,
        window.makeFirstResponder(formatted.textView)
      else {
        throw PDFError(.malformed, "Document Redo did not target the pending inline-format draft")
      }
      guard emphasizedSegments().first?.format == emphasized.format else {
        throw PDFError(.malformed, "Inline-format Redo did not restore all traits")
      }
      checkpoint("document Undo and Redo routed to the pending inline-format draft")
      formatted.textView.setSelectedRange((styledText as NSString).range(of: "different style"))
      viewer.pageTextFormattingApplier?(.underline(true))
      viewer.pageTextFormattingApplier?(.strikeout(true))
      viewer.pageTextFormattingApplier?(.characterSpacing(0.5))
      viewer.pageTextFormattingApplier?(.wordSpacing(2))
      func extendedSegments() -> [PageTextSegment] {
        formatted.pageLines().flatMap(\.segments).filter { $0.text.contains("different") }
      }
      guard let extended = extendedSegments().first,
        extended.format.underline, extended.format.strikeout,
        abs(extended.format.characterSpacing - 0.5) < 0.001,
        abs(extended.format.wordSpacing - 2) < 0.001 else {
        throw PDFError(.malformed, "Extended character formatting was not applied")
      }
      viewer.pageTextFormattingApplier?(.superscript(true))
      guard let raised = extendedSegments().first,
        raised.format.rise > 0.01, raised.format.size < 16 else {
        throw PDFError(.malformed, "Superscript formatting was not applied")
      }
      viewer.pageTextFormattingApplier?(.superscript(false))
      guard let normalScript = extendedSegments().first,
        abs(normalScript.format.rise) < 0.001,
        abs(normalScript.format.size - 16) < 0.01,
        normalScript.format.underline, normalScript.format.strikeout else {
        throw PDFError(.malformed, "Removing superscript lost other character formatting")
      }
      viewer.pageTextFormattingApplier?(.superscript(true))
      guard let persistedScript = extendedSegments().first,
        persistedScript.format.rise > 0.01, persistedScript.format.size < 16 else {
        throw PDFError(.malformed, "Superscript could not be persisted")
      }
      formatted.textView.setSelectedRange((styledText as NSString).range(of: "\n\n"))
      viewer.pageTextFormattingApplier?(.size(26))
      checkpoint("character formatting blank paragraph styled")
      let styledLines = formatted.pageLines()
      let styledBox = formatted.pageBox()
      guard styledLines.contains(where: { $0.text.isEmpty && $0.endsParagraph }),
        styledLines.flatMap(\.segments).filter({
          !$0.text.contains("these words") && !$0.text.contains("different")
        }).allSatisfy({ $0.format.font == .helvetica && $0.format.size == 16 }),
        styledLines.flatMap(\.segments).contains(where: {
          $0.format.underline && $0.format.strikeout && ($0.width ?? 0) > 0
        }) else {
        throw PDFError(.malformed, "Formatting changed neighbors or lost the blank paragraph")
      }
      try JSONSerialization.data(withJSONObject: [
        "text": styledText, "width": styledBox.width,
        "lines": styledLines.map { line in
          ["text": line.text, "x": line.x, "baseline": line.baseline,
            "hardBreak": line.endsParagraph, "segments": line.segments.map {
              ["text": $0.text, "x": $0.x, "font": $0.format.font.rawValue,
                "size": $0.format.size, "color": $0.format.color] as [String: Any]
            }] as [String: Any]
        }
      ], options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("formatting-native-lines.json"))
      checkpoint("character formatting layout verified; committing")
      guard formatted.commit() else {
        throw PDFError(.malformed, "Formatted paragraph did not commit")
      }
      checkpoint("character formatting commit returned")
      let styledBytes = try document.editSession.bytesForSave()
      try styledBytes.write(to: output.appendingPathComponent("formatting-after.pdf"))
      let styledParsed = try PDFParser.parse(styledBytes)
      guard let styledReader = PDFDocument(data: styledBytes), let styledPage = styledReader.page(at: 0)
      else { throw PDFError(.malformed, "Saved formatted PDF did not reopen") }
      let savedTargets = NativeParagraphEditing.targets(from: [], pageID: styledParsed.pageIDs[0],
        graph: styledParsed.graph, page: styledPage)
      let savedTarget = savedTargets.first(where: { $0.text == styledText })
      guard let styledTarget = savedTarget,
        abs(styledTarget.rect[2] - styledTarget.rect[0] - 287.125) < 0.001,
        styledTarget.paragraph?.fragments.contains(where: {
          $0.text == "these words" && $0.format == emphasized.format
        }) == true,
        styledTarget.paragraph?.fragments.contains(where: {
          $0.text.contains("different") && $0.format.underline && $0.format.strikeout
            && abs($0.format.wordSpacing - 2) < 0.001 && $0.format.rise > 0.01
        }) == true else {
        throw PDFError(.malformed, "Saved formatted box lost text, styles, breaks or exact width")
      }
      document.undoEdit()
      checkpoint("character formatting document undo returned")
      guard try document.editSession.bytesForSave() == paragraphEdited else {
        throw PDFError(.malformed, "Document Undo lost the complete unformatted paragraph")
      }
      document.redoEdit()
      checkpoint("character formatting document redo returned")
      guard try document.editSession.bytesForSave() == styledBytes else {
        throw PDFError(.malformed, "Document Redo changed the formatted PDF bytes")
      }
      guard let styledLivePage = viewer.view.document?.page(at: 0),
        let styledSelection = viewer.view.document?.findString("Keep", withOptions: []).first else {
        throw PDFError(.malformed, "Saved styled text is not selectable")
      }
      let styledBounds = styledSelection.bounds(for: styledLivePage)
      let styledPointer = viewer.view.convert(viewer.view.convert(
        NSPoint(x: styledBounds.midX, y: styledBounds.midY), from: styledLivePage), to: nil)
      overlay.mouseDown(with: try mouse(.leftMouseDown, point: styledPointer))
      overlay.mouseUp(with: try mouse(.leftMouseUp, point: styledPointer))
      checkpoint("character formatting saved box reselected")
      guard let savedCanvas = findCanvas(content), !viewer.hasPendingPageTextChanges,
        viewer.pageTextMixedFormatting.contains("size") else {
        throw PDFError(.malformed, "Reselecting a styled box changed it or lost mixed formatting")
      }
      let reopenedLines = savedCanvas.pageLines()
      guard reopenedLines.count == styledLines.count,
        zip(reopenedLines, styledLines).allSatisfy({ pair in
          pair.0.text == pair.1.text && pair.0.breakFormat == pair.1.breakFormat
            && abs(pair.0.baseline - pair.1.baseline) < 0.005
        }) else {
        throw PDFError(
          .malformed,
          "Reopened native layout lost leading or styled paragraph breaks "
            + "(reopened=\(reopenedLines.map { ($0.text, $0.baseline, String(describing: $0.breakFormat)) }), "
            + "expected=\(styledLines.map { ($0.text, $0.baseline, String(describing: $0.breakFormat)) }))")
      }
      let inspector = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 224, height: 460),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      inspector.isReleasedWhenClosed = false
      inspector.contentView = NSHostingView(rootView: WorkspaceTextInspector(viewer: viewer))
      inspector.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(150))
      checkpoint("character formatting inspector opened")
      guard !viewer.hasPendingPageTextChanges,
        savedCanvas.pageLines().flatMap(\.segments).contains(where: {
          $0.text == "these words" && $0.format == emphasized.format
        }), try document.editSession.bytesForSave() == styledBytes else {
        throw PDFError(.malformed, "Opening the inspector mutated mixed-size text")
      }
      inspector.close()
      window.makeKeyAndOrderFront(nil)
      guard savedCanvas.performKeyEquivalent(with: try formatKey("ı", code: 34)),
        !viewer.isTypingPageText, !viewer.pageTextMixedFormatting.contains("italic"),
        savedCanvas.performKeyEquivalent(with: try formatKey("ı", code: 34)) else {
        throw PDFError(.malformed, "Whole-box formatting shortcut or Turkish layout failed")
      }
      checkpoint("character formatting keyboard workflow passed")
      savedCanvas.cancel()
      checkpoint("character formatting passed")

      // TXT-09: a page marked with /Rotate is edited upright while the saved
      // rotation and neighboring page-space content stay unchanged.
      let rotatedSource = output.appendingPathComponent("rotated-page-source.pdf")
      try? FileManager.default.removeItem(at: rotatedSource)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .appendingPathComponent("Tests/Fixtures/text-edit.pdf"),
        to: rotatedSource)
      let (rotatedOpened, _) = try await controller.openDocument(
        withContentsOf: rotatedSource, display: true)
      guard let rotatedDocument = rotatedOpened as? SPDFDocument,
        let rotatedViewer = rotatedDocument.viewer,
        let rotatedWindow = rotatedDocument.windowControllers.first?.window,
        let rotatedContent = rotatedWindow.contentView
      else { throw PDFError(.malformed, "Could not open the rotated-page source") }
      rotatedWindow.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(200))
      rotatedDocument.rotateCurrentPage(byDegrees: 90)
      try await Task.sleep(for: .milliseconds(250))
      guard let displayedRotatedPage = rotatedViewer.view.document?.page(at: 0),
        displayedRotatedPage.rotation == 90 else {
        throw PDFError(.malformed, "Page rotation did not reach the rendered page")
      }
      let rotatedBaseline = try rotatedDocument.editSession.bytesForSave()
      _ = rotatedViewer.activateTool(.textEdit)
      try await Task.sleep(for: .milliseconds(100))
      guard let rotatedOverlay = findOverlay(rotatedContent),
        let rotatedTargets = rotatedViewer.textTargetsProvider?(0),
        let rotatedTarget = rotatedTargets.first(where: { $0.text.contains("Replace") })
          ?? rotatedTargets.first
      else { throw PDFError(.malformed, "No editable text target on the rotated page") }
      let rotatedTargetRect = CGRect(
        x: rotatedTarget.rect[0], y: rotatedTarget.rect[1],
        width: rotatedTarget.rect[2] - rotatedTarget.rect[0],
        height: rotatedTarget.rect[3] - rotatedTarget.rect[1])
      let rotatedViewPoint = rotatedViewer.view.convert(
        NSPoint(x: rotatedTargetRect.midX, y: rotatedTargetRect.midY), from: displayedRotatedPage)
      let rotatedPointer = rotatedViewer.view.convert(rotatedViewPoint, to: nil)
      rotatedOverlay.mouseDown(with: try mouse(.leftMouseDown, point: rotatedPointer, clicks: 2))
      rotatedOverlay.mouseUp(with: try mouse(.leftMouseUp, point: rotatedPointer, clicks: 2))
      guard rotatedViewer.isTypingPageText, let rotatedCanvas = findCanvas(rotatedContent) else {
        throw PDFError(.malformed, "Double-click did not start editing on the rotated page")
      }
      guard rotatedViewer.view.document?.page(at: 0)?.rotation == 0 else {
        throw PDFError(.malformed, "The rotated page was not shown upright while editing")
      }
      rotatedCanvas.textView.insertText(
        "Replace that text",
        replacementRange: NSRange(location: 0, length: (rotatedCanvas.textView.string as NSString).length))
      guard rotatedViewer.hasPendingPageTextChanges else {
        throw PDFError(.malformed, "Typing on the rotated page created no pending draft")
      }
      guard rotatedCanvas.commit() else {
        throw PDFError(
          .malformed,
          "The rotated-page text edit did not commit (issue=\(rotatedViewer.pageTextFormattingIssue ?? "nil"), "
            + "overflow=\(String(describing: rotatedViewer.pageTextOverflow)), "
            + "target=\(rotatedTarget.text), paragraph=\(rotatedTarget.paragraph != nil))")
      }
      checkpoint("rotated page edit committed")
      let rotatedBytes = try rotatedDocument.editSession.bytesForSave()
      guard let rotatedReader = PDFDocument(data: rotatedBytes),
        rotatedReader.page(at: 0)?.rotation == 90,
        rotatedReader.string?.contains("Replace that text") == true,
        rotatedViewer.view.document?.page(at: 0)?.rotation == 90
      else {
        throw PDFError(.malformed, "Saved rotated-page edit lost the text or the page rotation")
      }
      rotatedDocument.undoEdit()
      guard try rotatedDocument.editSession.bytesForSave() == rotatedBaseline,
        PDFDocument(data: try rotatedDocument.editSession.bytesForSave())?
          .string?.contains("Replace this text") == true else {
        throw PDFError(.malformed, "Undo after the rotated-page edit did not restore the source")
      }
      checkpoint("rotated page edit and undo passed")

      // A new text box on the rotated page also edits upright and saves with
      // the page rotation intact.
      _ = rotatedViewer.activateTool(.addText)
      try await Task.sleep(for: .milliseconds(100))
      guard let addTargetPage = rotatedViewer.view.document?.page(at: 0) else {
        throw PDFError(.malformed, "The rotated page disappeared before Add Text")
      }
      let addViewPoint = rotatedViewer.view.convert(NSPoint(x: 120, y: 300), from: addTargetPage)
      let addPointer = rotatedViewer.view.convert(addViewPoint, to: nil)
      rotatedOverlay.mouseDown(with: try mouse(.leftMouseDown, point: addPointer))
      rotatedOverlay.mouseUp(with: try mouse(.leftMouseUp, point: addPointer))
      guard rotatedViewer.isTypingPageText, let newTextCanvas = findCanvas(rotatedContent),
        rotatedViewer.view.document?.page(at: 0)?.rotation == 0 else {
        throw PDFError(.malformed, "Add Text on the rotated page did not start upright editing")
      }
      newTextCanvas.textView.insertText(
        "Rotated new text",
        replacementRange: NSRange(
          location: 0, length: (newTextCanvas.textView.string as NSString).length))
      guard newTextCanvas.commit() else {
        throw PDFError(.malformed, "New text on the rotated page did not commit")
      }
      let addedRotatedBytes = try rotatedDocument.editSession.bytesForSave()
      guard let addedRotatedReader = PDFDocument(data: addedRotatedBytes),
        addedRotatedReader.page(at: 0)?.rotation == 90,
        addedRotatedReader.string?.contains("Rotated new text") == true,
        rotatedViewer.view.document?.page(at: 0)?.rotation == 90 else {
        throw PDFError(.malformed, "New text on the rotated page lost the text or rotation")
      }
      rotatedDocument.undoEdit()
      guard try rotatedDocument.editSession.bytesForSave() == rotatedBaseline else {
        throw PDFError(.malformed, "Undo after adding rotated-page text did not restore the source")
      }
      checkpoint("rotated page new text and undo passed")
      rotatedDocument.close()
      window.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(200))

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
      let capabilityAudit = CapabilityContractAudit.run(menu: NSApp.mainMenu)
      guard capabilityAudit.issues.isEmpty, capabilityAudit.contracts.count >= 50 else {
        throw PDFError(
          .malformed,
          "Capability contract audit failed: \(capabilityAudit.issues.joined(separator: "; "))")
      }
      try Data(capabilityAudit.text.utf8).write(
        to: output.appendingPathComponent("capability-contracts.txt"), options: .atomic)
      settings.close()
      checkpoint("workspace sizing and settings passed")
      try await checkGraphicWorkflow(output: output)
      checkpoint("image workflow passed")
      try await checkNestedImageWorkflow(output: output)
      try await checkClippedImageWorkflow(output: output)
      try await checkTextEditRefusal(output: output)
      try await checkFindReplaceWorkflow(output: output)
      try await checkReadOnlyExplanation(output: output)
      return [
        "graphicWorkflow": "insert, properties, preview, selection, shared resize, cancel, keyboard, delete, alignment, save/reopen",
        "nestedImageWorkflow": "Images explains reusable-form refusal; Edit PDF selects overlapping page text; cancel preserves bytes",
        "clippedImageWorkflow": "rectangular clips narrow point/rubber-band targets; unsupported clips refuse safely",
        "textEditRestrictions": "visible clipping-mode text explains inline refusal before editing and preserves source bytes",
        "findReplace": "document preview, two eligible matches, one atomic replacement and exact Undo/Redo",
        "readOnlyRestrictions": "password-permission editing block is visible and accessible; source bytes remain unchanged",
        "directTextSelection":
          "single-click selection, body move/cancel, double-click typing, marked-text Save veto",
        "paragraphWorkflow":
          "longer native text, width reflow, move, exact saved lines, atomic Undo/Redo, reselection",
        "characterFormatting":
          "selected words, family/bold/italic/underline/strikeout/superscript, tracking/word spacing, native shortcuts, saved exact width, metadata round-trip and blank paragraph",
        "commandScrollZoom": "native wheel events, both directions, pointer anchor and pending typing preserved",
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
        "capabilityContracts": "\(capabilityAudit.contracts.count) document tools audited with menu selector, limits, output and evidence",
      ]
    }
  }
#endif
