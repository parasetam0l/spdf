#if DEBUG
  import AppKit
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
        let textOverlay = findTextOverlay(content) else {
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
      guard viewer.selectedGraphics.isEmpty,
        viewer.selectionDetails?.text == refusal,
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Images mode did not explain the nested-image refusal without mutation")
      }

      guard viewer.activateTool(.textEdit) else {
        throw PDFError(.malformed, "Could not enter Edit PDF mode over a nested image")
      }
      textOverlay.mouseDown(with: try mouse(.leftMouseDown, windowPoint))
      textOverlay.mouseUp(with: try mouse(.leftMouseUp, windowPoint))
      guard viewer.isEditingPageText, viewer.selectedGraphics.isEmpty else {
        throw PDFError(.malformed, "Edit PDF did not select visible page text over a nested image")
      }
      viewer.pageTextCancel?()
      guard !viewer.isEditingPageText,
        try document.editSession.bytesForSave() == baseline else {
        throw PDFError(.malformed, "Canceling nested-overlap text editing changed the PDF")
      }
      checkpoint("nested-image refusal and text selection passed")
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
      formatted.beginTyping()
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
      formatted.textView.typingUndo.undo()
      guard emphasizedSegments().first?.format.color == [0, 0, 0] else {
        throw PDFError(.malformed, "Native formatting Undo did not restore color independently")
      }
      formatted.textView.typingUndo.redo()
      guard emphasizedSegments().first?.format == emphasized.format else {
        throw PDFError(.malformed, "Native formatting Redo did not restore all traits")
      }
      checkpoint("character formatting typing undo and redo passed")
      formatted.textView.setSelectedRange((styledText as NSString).range(of: "\n\n"))
      viewer.pageTextFormattingApplier?(.size(26))
      checkpoint("character formatting blank paragraph styled")
      let styledLines = formatted.pageLines()
      let styledBox = formatted.pageBox()
      guard styledLines.contains(where: { $0.text.isEmpty && $0.endsParagraph }),
        styledLines.flatMap(\.segments).filter({ !$0.text.contains("these words") })
          .allSatisfy({ $0.format.font == .helvetica && $0.format.size == 16 }) else {
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
      guard let styledReader = PDFDocument(data: styledBytes), let styledPage = styledReader.page(at: 0),
        let styledTarget = NativeParagraphEditing.targets(from: [], pageID: styledParsed.pageIDs[0],
          graph: styledParsed.graph, page: styledPage).first(where: { $0.text == styledText }),
        abs(styledTarget.rect[2] - styledTarget.rect[0] - 287.125) < 0.001,
        styledTarget.paragraph?.fragments.contains(where: {
          $0.text == "these words" && $0.format == emphasized.format
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
        throw PDFError(.malformed, "Reopened native layout lost leading or styled paragraph breaks")
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
      checkpoint("workspace sizing and settings passed")
      try await checkGraphicWorkflow(output: output)
      checkpoint("image workflow passed")
      try await checkNestedImageWorkflow(output: output)
      try await checkClippedImageWorkflow(output: output)
      return [
        "graphicWorkflow": "insert, properties, preview, selection, shared resize, cancel, keyboard, delete, alignment, save/reopen",
        "nestedImageWorkflow": "Images explains reusable-form refusal; Edit PDF selects overlapping page text; cancel preserves bytes",
        "clippedImageWorkflow": "rectangular clips narrow point/rubber-band targets; unsupported clips refuse safely",
        "directTextSelection":
          "single-click selection, body move/cancel, double-click typing, marked-text Save veto",
        "paragraphWorkflow":
          "longer native text, width reflow, move, exact saved lines, atomic Undo/Redo, reselection",
        "characterFormatting":
          "selected words, family/bold/italic/size/color, native shortcuts, formatting and document Undo/Redo, saved exact width and blank paragraph",
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
      ]
    }
  }
#endif
