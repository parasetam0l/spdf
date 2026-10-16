#if DEBUG
  import AppKit
  import Foundation
  import MacServices
  import PDFCore
  import PDFEditing
  import PDFKit

  @MainActor
  enum ImportedParagraphSmoke {
    static func survey(directory: URL, output: URL) {
      do {
        var rows: [[String: Any]] = []
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (index, file) in files.enumerated() {
          do {
            let parsed = try PDFParser.parse(Data(contentsOf: file))
            guard let reader = PDFDocument(url: file), !reader.isLocked else { continue }
            var targets: [[String: Any]] = []
            var sourceRuns = 0
            var profiles: [[String: Any]] = []
            for pageIndex in 0..<min(3, parsed.pageIDs.count) {
              guard let page = reader.page(at: pageIndex) else { continue }
              let pageID = parsed.pageIDs[pageIndex]
              profiles += try PageTextEditing.fontProfiles(pageID: pageID, in: parsed.graph).values.map {
                ["name": $0.source.name, "glyphs": $0.glyphs.count, "programBytes": $0.program.count]
              }
              sourceRuns += (try PageTextEditing.sourceRuns(pageID: pageID, in: parsed.graph)).count
              let blocks = try PageTextEditing.blocks(pageID: pageID, in: parsed.graph).map {
                PageTextTarget(pageIndex: pageIndex, runIndex: $0.runIndices[0], rect: $0.rect,
                  text: $0.text, style: $0.style, runIndices: $0.runIndices)
              }
              let paragraphs = NativeParagraphEditing.targets(from: blocks, pageID: pageID,
                graph: parsed.graph, page: page).filter { $0.paragraph != nil }
              targets += paragraphs.map { target in
                ["page": pageIndex, "rect": target.rect, "runs": target.runIndices,
                  "font": target.style?.fontFamily ?? "", "characters": target.text.count,
                  "multiline": target.paragraph?.wraps ?? false] as [String: Any]
              }
            }
            rows.append(["id": String(format: "document-%02d", index + 1),
              "file": file.lastPathComponent, "pagesSampled": min(3, parsed.pageIDs.count),
              "sourceRuns": sourceRuns, "targets": targets, "profiles": profiles])
          } catch { rows.append(["id": String(format: "document-%02d", index + 1), "error": String(describing: error)]) }
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["scope": "read-only first-three-page font/paragraph survey", "documents": rows],
          options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Imported paragraph survey recorded \(rows.count) documents privately")
        exit(0)
      } catch { FileHandle.standardError.write(Data("Imported survey failed: \(error)\n".utf8)); exit(1) }
    }

    static func run(fixtures: URL, output: URL) async {
      do {
        try await checks(fixtures: fixtures, output: output)
        print("sPDF imported paragraph smoke passed")
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("Imported paragraph smoke failed: \(error)\n".utf8))
        exit(1)
      }
    }

    static func checks(fixtures: URL, output: URL) async throws {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let priorRecovery = SPDFDocument.recoveryDirectoryOverride
      defer { SPDFDocument.recoveryDirectoryOverride = priorRecovery }
      SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
      let source = fixtures.appendingPathComponent("imported-paragraph.pdf")
      let document = try SPDFDocument(contentsOf: source, ofType: "com.adobe.pdf")
      NSDocumentController.shared.addDocument(document)
      document.makeWindowControllers()
      defer { document.close() }
      guard let viewer = document.viewer, let window = document.windowControllers.first?.window,
        let content = window.contentView else { throw PDFError(.malformed, "Missing imported workspace") }
      window.makeKeyAndOrderFront(nil)
      viewer.setZoom(1)
      _ = viewer.activateTool(.textEdit)
      try await Task.sleep(for: .milliseconds(100))
      func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
      }
      func select(_ phrase: String) throws -> InlinePageTextCanvas {
        guard let page = viewer.view.document?.page(at: 0),
          let match = viewer.view.document?.findString(phrase, withOptions: []).first,
          let overlay = find(PageEditOverlayView.self, in: content) else {
          throw PDFError(.malformed, "Missing imported text target")
        }
        let bounds = match.bounds(for: page)
        let point = viewer.view.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page)
        let pointer = viewer.view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          guard let event = NSEvent.mouseEvent(with: type, location: pointer, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
            throw PDFError(.malformed, "Could not construct paragraph pointer event")
          }
          if type == .leftMouseDown { overlay.mouseDown(with: event) }
          else { overlay.mouseUp(with: event) }
        }
        guard let canvas = find(InlinePageTextCanvas.self, in: content) else {
          throw PDFError(.malformed, "Imported paragraph did not select")
        }
        return canvas
      }
      let original = try document.editSession.bytesForSave()
      let canvas = try select("This imported paragraph")
      guard let paragraph = canvas.sourceTarget?.paragraph, paragraph.originalText.count > 3,
        !viewer.hasPendingPageTextChanges, try document.editSession.bytesForSave() == original,
        viewer.pageTextStyle.fontFamily == "DejaVuSans", !viewer.canChangePageTextTraits else {
        throw PDFError(.malformed, "Imported selection mutated, substituted or lost its paragraph")
      }
      canvas.beginTyping()
      let range = (canvas.textView.string as NSString).range(of: "saved")
      guard range.location != NSNotFound else { throw PDFError(.malformed, "Missing colored source word") }
      canvas.textView.setSelectedRange(range)
      viewer.pageTextFormattingApplier?(.color([0.7, 0.1, 0.2]))
      viewer.pageTextFormattingApplier?(.size(18))
      canvas.textView.setSelectedRange(NSRange(location: (canvas.textView.string as NSString).length, length: 0))
      canvas.textView.insertText(" This sentence is added without replacing the embedded font.",
        replacementRange: canvas.textView.selectedRange())
      guard canvas.textView.string.hasSuffix("embedded font."),
        canvas.textView.shouldChangeText(in: canvas.textView.selectedRange(), replacementString: "Ω") == false,
        viewer.pageTextFormattingIssue != nil else {
        throw PDFError(.malformed, "Embedded glyph coverage did not guard native typing")
      }
      canvas.setTextWidth(295.5)
      canvas.move(byWindowDelta: NSPoint(x: 24, y: -12), finished: true)
      let lines = canvas.pageLines()
      let expectedText = canvas.textView.string
      let expectedBox = canvas.pageBox()
      try JSONSerialization.data(withJSONObject: lines.map { line in
        ["text": line.text, "x": line.x, "baseline": line.baseline,
          "segments": line.segments.map { segment in
            ["text": segment.text, "x": segment.x, "font": segment.format.fontName,
              "size": segment.format.size, "color": segment.format.color,
              "spacing": segment.format.characterSpacing] as [String: Any]
          }] as [String: Any]
      }, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("native-lines.json"))
      guard canvas.commit(), !viewer.isEditingPageText else {
        throw PDFError(.malformed, "Imported native text did not commit")
      }
      let edited = try document.editSession.bytesForSave()
      try edited.write(to: output.appendingPathComponent("after.pdf"))
      try original.write(to: output.appendingPathComponent("before.pdf"))
      let originalGraph = try PDFParser.parse(original).graph
      let editedGraph = try PDFParser.parse(edited).graph
      for id in [4, 6, 7, 8, 9, 10] {
        guard originalGraph.objects[PDFObjectID(id)] == editedGraph.objects[PDFObjectID(id)] else {
          throw PDFError(.malformed, "Editing changed an existing font resource or program")
        }
      }
      document.undoEdit()
      guard try document.editSession.bytesForSave() == original else {
        throw PDFError(.malformed, "Imported paragraph Undo did not restore original bytes")
      }
      document.redoEdit()
      guard try document.editSession.bytesForSave() == edited else {
        throw PDFError(.malformed, "Imported paragraph Redo did not restore edited bytes")
      }
      let saved = output.appendingPathComponent("saved.pdf")
      let error: Error? = await withCheckedContinuation { continuation in
        document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) { continuation.resume(returning: $0) }
      }
      if let error { throw error }
      let again = try select("This imported paragraph")
      let actualLines = again.pageLines()
      let positionError = zip(actualLines, lines).map {
        max(abs($0.x - $1.x), abs($0.baseline - $1.baseline))
      }.max() ?? 0
      let expectedSegments = lines.flatMap(\.segments)
      let actualSegments = actualLines.flatMap(\.segments)
      let stylesMatch = expectedSegments.count == actualSegments.count
        && zip(actualSegments, expectedSegments).allSatisfy { actual, expected in
          actual.text == expected.text && abs(actual.x - expected.x) < 0.005
            && actual.format.font == expected.format.font && actual.format.sourceFont == expected.format.sourceFont
            && abs(actual.format.size - expected.format.size) < 0.00001
            && abs(actual.format.characterSpacing - expected.format.characterSpacing) < 0.00001
            && zip(actual.format.color, expected.format.color).allSatisfy { abs($0 - $1) < 0.00001 }
        }
      guard again.textView.string == expectedText, abs(again.pageBox().width - expectedBox.width) < 0.005,
        actualLines.count == lines.count, positionError < 0.005, stylesMatch,
        !viewer.hasPendingPageTextChanges else {
        throw PDFError(.malformed, "Imported reselection: text=\(again.textView.string == expectedText), width=\(again.pageBox().width), lines=\(actualLines.count)/\(lines.count), max position error=\(positionError), segments=\(actualLines.flatMap(\.segments) == lines.flatMap(\.segments)), pending=\(viewer.hasPendingPageTextChanges)")
      }
      again.beginTyping()
      again.textView.setSelectedRange((again.textView.string as NSString).range(of: "saved"))
      guard viewer.pageTextStyle.fontSize == 18, !viewer.hasPendingPageTextChanges,
        again.commit(), !document.isDocumentEdited,
        try document.editSession.bytesForSave() == edited else {
        throw PDFError(.malformed, "Selecting a different saved style created a false document edit")
      }
      try JSONSerialization.data(withJSONObject: ["status": "passed", "font": "DejaVuSans",
        "sourceRuns": paragraph.originalText.count, "savedLines": lines.count,
        "savedWidth": expectedBox.width, "nativeText": expectedText,
        "coverage": "missing glyph refused before insertion; explicit standard-font choice available",
        "checks": "selection, original glyph program, selected formatting, longer typing, resize/move, atomic Undo/Redo, Save and reselection"],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
  }
#endif
