#if DEBUG
  import AppKit
  import Foundation
  import MacServices
  import PDFCore
  import PDFEditing
  import PDFKit

  /// Opt-in local checks against a caller-provided document. Corpus files and
  /// reports stay outside source; CI uses the distributable fixture suite.
  @MainActor
  enum CorpusParagraphSmoke {
    static func run(source: URL, output: URL) async {
      do {
        try await checks(source: source, output: output)
        print("sPDF corpus paragraph check passed")
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("Corpus paragraph check failed: \(error)\n".utf8))
        exit(1)
      }
    }

    static func checks(source: URL, output: URL) async throws {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let sourceBytes = try Data(contentsOf: source)
      let priorRecovery = SPDFDocument.recoveryDirectoryOverride
      defer { SPDFDocument.recoveryDirectoryOverride = priorRecovery }
      SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
      let document = try SPDFDocument(contentsOf: source, ofType: "com.adobe.pdf")
      NSDocumentController.shared.addDocument(document)
      document.makeWindowControllers()
      defer { document.close() }
      guard let graph = document.editSession.currentGraph, let viewer = document.viewer,
        let reader = viewer.view.document else { throw PDFError(.malformed, "Missing corpus document") }
      var chosen: PageTextTarget?
      for index in 0..<min(3, document.editSession.pageIDs.count) {
        guard let page = reader.page(at: index) else { continue }
        let pageID = document.editSession.pageIDs[index]
        let blocks = try PageTextEditing.blocks(pageID: pageID, in: graph).map {
          PageTextTarget(pageIndex: index, runIndex: $0.runIndices[0], rect: $0.rect,
            text: $0.text, style: $0.style, runIndices: $0.runIndices)
        }
        chosen = NativeParagraphEditing.targets(from: blocks, pageID: pageID, graph: graph, page: page)
          .first { $0.paragraph?.wraps == true && $0.text.count >= 50 && $0.rect[1] > 100 }
        if chosen != nil { break }
      }
      guard let target = chosen else { throw PDFError(.unsupported, "No representative editable paragraph") }
      let pageIndex = target.pageIndex, pageID = document.editSession.pageIDs[pageIndex]
      func dictionary(_ value: PDFValue?) -> [PDFName: PDFValue]? {
        var value = value
        var visited = Set<PDFObjectID>()
        while case .reference(let id)? = value {
          guard visited.count < 32, visited.insert(id).inserted else { return nil }
          value = graph.objects[id]
        }
        if case .dictionary(let result)? = value { return result }; return nil
      }
      guard case .dictionary(let pageDictionary)? = graph.objects[pageID],
        let resources = dictionary(pageDictionary[PDFName("Resources")]),
        let fonts = dictionary(resources[PDFName("Font")]) else {
        throw PDFError(.malformed, "Missing corpus font resources")
      }
      let fontRoots = fonts.values.compactMap { value -> PDFObjectID? in
        if case .reference(let id) = value { return id }; return nil
      }
      let fontObjects = PDFGraphTraversal.reachable(from: fontRoots, in: graph).order
      let phrase = String(target.text.prefix(18))
      func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
      }
      func select(_ document: SPDFDocument) async throws -> InlinePageTextCanvas {
        guard let viewer = document.viewer, let window = document.windowControllers.first?.window,
          let content = window.contentView, let page = viewer.view.document?.page(at: pageIndex) else {
          throw PDFError(.malformed, "Missing corpus workspace")
        }
        window.makeKeyAndOrderFront(nil)
        viewer.view.go(to: page)
        viewer.setZoom(1)
        _ = viewer.activateTool(.textEdit)
        try await Task.sleep(for: .milliseconds(100))
        guard let match = viewer.view.document?.findString(phrase, withOptions: []).first,
          let overlay = find(PageEditOverlayView.self, in: content) else {
          throw PDFError(.malformed, "Missing corpus pointer target")
        }
        let bounds = match.bounds(for: page)
        let point = viewer.view.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page)
        let pointer = viewer.view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          guard let event = NSEvent.mouseEvent(with: type, location: pointer, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
            throw PDFError(.malformed, "Cannot construct corpus pointer event")
          }
          if type == .leftMouseDown { overlay.mouseDown(with: event) } else { overlay.mouseUp(with: event) }
        }
        guard let canvas = find(InlinePageTextCanvas.self, in: content),
          canvas.sourceTarget?.paragraph?.wraps == true else {
          throw PDFError(.malformed, "The actual workspace did not select the detected paragraph")
        }
        return canvas
      }
      func encode(_ lines: [PageTextLine]) -> [[String: Any]] {
        lines.map { line in
          ["text": line.text, "x": line.x, "baseline": line.baseline,
            "segments": line.segments.map { segment in
              ["text": segment.text, "x": segment.x, "font": segment.format.fontName,
                "size": segment.format.size, "color": segment.format.color,
                "spacing": segment.format.characterSpacing] as [String: Any]
            }] as [String: Any]
        }
      }
      func characters(_ canvas: InlinePageTextCanvas, document: SPDFDocument) -> [[String: Any]] {
        guard let viewer = document.viewer, let page = viewer.view.document?.page(at: pageIndex),
          let manager = canvas.textView.layoutManager else { return [] }
        let text = canvas.textView.string as NSString
        return (0..<text.length).compactMap { index in
          let value = text.substring(with: NSRange(location: index, length: 1))
          guard !value.allSatisfy(\.isWhitespace) else { return nil }
          let glyph = manager.glyphIndexForCharacter(at: index)
          let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
          let origin = manager.location(forGlyphAt: glyph)
          let viewPoint = canvas.textView.convert(NSPoint(x: rect.minX + origin.x, y: rect.minY + origin.y), to: viewer.view)
          let point = viewer.view.convert(viewPoint, to: page)
          return ["text": value, "x": point.x, "baseline": point.y]
        }
      }
      let original = try document.editSession.bytesForSave()
      let canvas = try await select(document)
      // The workspace omits standalone whitespace hit targets. Its visible
      // paragraph must still agree with discovery and selection must be clean.
      guard canvas.textView.string == target.text, !viewer.hasPendingPageTextChanges,
        try document.editSession.bytesForSave() == original else {
        throw PDFError(.malformed, "Paragraph discovery and actual selection disagree or mutate the source")
      }
      let beforeLines = canvas.pageLines()
      let beforeCharacters = characters(canvas, document: document)
      let selectedRuns = canvas.sourceTarget!.runIndices
      let originalBox = canvas.pageBox()
      canvas.beginTyping()
      let word = String(canvas.textView.string.split(whereSeparator: \.isWhitespace).last ?? "")
      guard !word.isEmpty else { throw PDFError(.malformed, "No source-font word for typing") }
      canvas.textView.setSelectedRange(NSRange(location: (canvas.textView.string as NSString).length, length: 0))
      canvas.textView.insertText(" " + word, replacementRange: canvas.textView.selectedRange())
      guard canvas.textView.string.hasSuffix(" " + word) else {
        throw PDFError(.malformed, "Native corpus typing did not insert the covered glyphs")
      }
      canvas.setTextWidth(originalBox.width + 6)
      let expectedText = canvas.textView.string, lines = canvas.pageLines(), box = canvas.pageBox()
      let savedCharacters = characters(canvas, document: document)
      guard canvas.commit() else { throw PDFError(.malformed, "Corpus paragraph did not commit") }
      let edited = try document.editSession.bytesForSave()
      guard let editedGraph = document.editSession.currentGraph,
        !fontObjects.isEmpty,
        fontObjects.allSatisfy({ graph.objects[$0] == editedGraph.objects[$0] }) else {
        throw PDFError(.malformed, "Corpus editing changed an existing font program or glyph mapping")
      }
      document.undoEdit()
      guard try document.editSession.bytesForSave() == original else { throw PDFError(.malformed, "Corpus Undo changed source bytes") }
      document.redoEdit()
      guard try document.editSession.bytesForSave() == edited else { throw PDFError(.malformed, "Corpus Redo changed edited bytes") }
      let saved = output.appendingPathComponent("saved.pdf")
      let error: Error? = await withCheckedContinuation { continuation in
        document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) { continuation.resume(returning: $0) }
      }
      if let error { throw error }
      document.close()
      let reopened = try SPDFDocument(contentsOf: saved, ofType: "com.adobe.pdf")
      NSDocumentController.shared.addDocument(reopened)
      reopened.makeWindowControllers()
      defer { reopened.close() }
      let again = try await select(reopened), actual = again.pageLines()
      let positionError = zip(actual, lines).map { max(abs($0.x - $1.x), abs($0.baseline - $1.baseline)) }.max() ?? 0
      guard again.textView.string == expectedText, abs(again.pageBox().width - box.width) < 0.005,
        actual.count == lines.count, positionError < 0.005,
        !reopened.viewer!.hasPendingPageTextChanges, again.commit(), !reopened.isDocumentEdited,
        try Data(contentsOf: source) == sourceBytes else {
        throw PDFError(.malformed, "Corpus Save/reopen changed text, layout, clean selection or the source file")
      }
      try original.write(to: output.appendingPathComponent("before.pdf"))
      try edited.write(to: output.appendingPathComponent("after.pdf"))
      try JSONSerialization.data(withJSONObject: ["status": "passed", "page": pageIndex,
        "sourceRect": target.rect, "originalText": target.text, "originalLines": encode(beforeLines),
        "nativeLines": encode(lines), "savedText": expectedText, "savedWidth": box.width,
        "originalCharacters": beforeCharacters, "nativeCharacters": savedCharacters,
        "sourceRuns": selectedRuns, "reopenPositionError": positionError,
        "sourceFileUnchanged": true, "fontProgramsAndMappingsUnchanged": true],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
  }
#endif
