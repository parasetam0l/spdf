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
    private struct CharacterPosition {
      let text: String
      let x: Double
      let baseline: Double

      var json: [String: Any] {
        ["text": text, "x": x, "baseline": baseline]
      }
    }

    /// Report actual document/canvas access, including view-only files and
    /// native images that the canvas cannot safely manipulate. Never turn a
    /// refusal into a successful image-edit count. Optional structure Save
    /// checks exercise the native transaction path without requiring text.
    static func access(source: URL, output: URL, testSave: Bool) async {
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: source)
        let prior = SPDFDocument.recoveryDirectoryOverride
        defer { SPDFDocument.recoveryDirectoryOverride = prior }
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
        let document = try SPDFDocument(contentsOf: source, ofType: "com.adobe.pdf")
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        defer { document.close() }
        guard let viewer = document.viewer, let reader = viewer.view.document else {
          throw PDFError(.malformed, "Native document did not open")
        }
        var result: [String: Any] = ["nativeOpen": true, "readerPages": reader.pageCount,
          "canEdit": document.editSession.canEdit, "structureSave": "not-requested"]
        if let graph = document.editSession.currentGraph {
          var image: [String: Any]?
          for index in 0..<min(3, document.editSession.pageIDs.count) {
            let id = document.editSession.pageIDs[index]
            let placements = try ImageInventory.placements(in: graph, pageID: id)
            guard !placements.isEmpty else { continue }
            let selectedIndex = placements.firstIndex {
              $0.isDirectlyEditable && $0.matrix.count == 6
                && $0.matrix[0] > 0 && $0.matrix[3] > 0
                && abs($0.matrix[1]) < 1e-9 && abs($0.matrix[2]) < 1e-9
            }
            guard let selectedIndex else {
              image = ["page": index, "placementIndex": 0,
                "placementCount": placements.count, "directPlacementCount": 0,
                "placements": placements.map {
                  ["imageID": $0.imageID.number, "matrix": $0.matrix,
                    "bounds": $0.bounds, "depth": $0.depth,
                    "directlyEditable": $0.isDirectlyEditable]
                },
                "status": "no-axis-aligned-direct-placement"]
              break
            }
            let placement = placements[selectedIndex]
            let bounds = placement.bounds
            let target = viewer.graphicTargetProvider?(index,
              [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2])
            image = ["page": index, "placementIndex": selectedIndex,
              "placementCount": placements.count,
              "directPlacementCount": placements.filter(\.isDirectlyEditable).count,
              "matrix": placement.matrix,
              "status": target?.imagePlacementIndex == selectedIndex
                ? "native-canvas-target" : "refused-by-canvas-targeting"]
            break
          }
          result["imageTask"] = image ?? ["status": "no-image-placement-resolved-in-fixed-page-sample"]
          if testSave {
            let original = try document.editSession.bytesForSave()
            let count = reader.pageCount
            viewer.view.goToFirstPage(nil)
            document.insertBlankPageAfterCurrent()
            guard document.editSession.pageIDs.count == count + 1 else {
              throw PDFError(.malformed, "Native blank-page insertion failed")
            }
            let edited = try document.editSession.bytesForSave()
            document.undoEdit()
            guard try document.editSession.bytesForSave() == original else {
              throw PDFError(.malformed, "Native structure Undo changed source bytes")
            }
            document.redoEdit()
            guard try document.editSession.bytesForSave() == edited else {
              throw PDFError(.malformed, "Native structure Redo changed edited bytes")
            }
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
            guard reopened.editSession.canEdit, reopened.editSession.pageIDs.count == count + 1,
              reopened.viewer?.view.document?.pageCount == count + 1, !reopened.isDocumentEdited else {
              throw PDFError(.malformed, "Native structure Save/reopen lost editing access or pages")
            }
            result["structureSave"] = "passed"
            result["insertedPageIndex"] = 1
          }
        } else {
          result["imageTask"] = ["status": "document-editing-unavailable"]
          if testSave { throw PDFError(.unsupported, "Document is view-only") }
        }
        guard try Data(contentsOf: source) == bytes else { throw PDFError(.malformed, "Source file changed") }
        result["sourceFileUnchanged"] = true
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("access.json"))
      } catch {
        FileHandle.standardError.write(Data("Corpus access check failed: \(error)\n".utf8))
        exit(1)
      }
      exit(0)
    }

    static func run(source: URL, output: URL, matching: String? = nil,
      wordOverride: String? = nil, replacementOverride: String? = nil) async {
      do {
        try await checks(source: source, output: output, matching: matching,
          wordOverride: wordOverride, replacementOverride: replacementOverride)
        print("sPDF corpus paragraph check passed")
        exit(0)
      } catch {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: [
          "status": "failed", "error": String(describing: error),
        ], options: [.prettyPrinted, .sortedKeys]) {
          try? data.write(to: output.appendingPathComponent("failure.json"))
        }
        FileHandle.standardError.write(Data("Corpus paragraph check failed: \(error)\n".utf8))
        exit(1)
      }
    }

    /// Exercise the same native canvas path users invoke for an existing,
    /// direct image placement: select, move, resize, exact Undo/Redo, Save As,
    /// actual close/reopen and reselection.
    static func imageEdit(source: URL, output: URL) async {
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sourceBytes = try Data(contentsOf: source)
        let previousRecovery = SPDFDocument.recoveryDirectoryOverride
        defer { SPDFDocument.recoveryDirectoryOverride = previousRecovery }
        SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
        let document = try SPDFDocument(contentsOf: source, ofType: "com.adobe.pdf")
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        defer { document.close() }
        guard let viewer = document.viewer,
          let window = document.windowControllers.first?.window,
          let content = window.contentView
        else { throw PDFError(.malformed, "Missing native image workspace") }
        window.makeKeyAndOrderFront(nil)
        viewer.setZoom(1)
        _ = viewer.activateTool(.imageEdit)
        try await Task.sleep(for: .milliseconds(100))
        guard let target = (0..<min(3, document.editSession.pageIDs.count))
          .lazy.flatMap({ viewer.graphicsListProvider?($0) ?? [] })
          .first(where: { $0.imagePlacementIndex != nil })
        else { throw PDFError(.unsupported, "No directly editable image in the fixed page sample") }
        guard let page = viewer.view.document?.page(at: target.pageIndex) else {
          throw PDFError(.malformed, "Missing native image page")
        }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
          if let found = view as? T { return found }
          return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        guard let overlay = find(GraphicSelectionOverlayView.self, in: content) else {
          throw PDFError(.malformed, "Missing native image overlay")
        }
        let initial = CGRect(
          x: target.rect[0], y: target.rect[1],
          width: target.rect[2] - target.rect[0],
          height: target.rect[3] - target.rect[1])
        let start = viewer.view.convert(
          viewer.view.convert(NSPoint(x: initial.midX, y: initial.midY), from: page), to: nil)
        let movedPointer = viewer.view.convert(
          viewer.view.convert(NSPoint(x: initial.midX + 36, y: initial.midY - 24), from: page),
          to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
          guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
          ) else { throw PDFError(.malformed, "Missing native image pointer event") }
          return event
        }
        let original = try document.editSession.bytesForSave()
        overlay.mouseDown(with: try mouse(.leftMouseDown, start))
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, movedPointer))
        overlay.mouseUp(with: try mouse(.leftMouseUp, movedPointer))
        guard viewer.selectedGraphics.count == 1,
          viewer.selectedGraphics[0].imagePlacementIndex != nil,
          let movedBounds = viewer.selectedGraphicBounds,
          abs(movedBounds.minX - initial.minX - 36) < 0.02,
          abs(movedBounds.minY - initial.minY + 24) < 0.02
        else { throw PDFError(.malformed, "Native image pointer drag did not move the actual image") }
        let movedBytes = try document.editSession.bytesForSave()
        let destination = CGRect(
          x: movedBounds.minX, y: movedBounds.minY,
          width: initial.width * 1.2, height: initial.height * 0.8)
        viewer.setGraphicBounds(destination)
        guard let moved = viewer.selectedGraphicBounds,
          abs(moved.minX - destination.minX) < 0.01,
          abs(moved.minY - destination.minY) < 0.01,
          abs(moved.width - destination.width) < 0.01,
          abs(moved.height - destination.height) < 0.01,
          document.isDocumentEdited
        else { throw PDFError(.malformed, "Native image move/resize did not reach its target bounds") }
        let edited = try document.editSession.bytesForSave()
        document.undoEdit()
        guard try document.editSession.bytesForSave() == movedBytes else {
          throw PDFError(.malformed, "Native image resize Undo did not restore its prior bytes")
        }
        document.undoEdit()
        guard try document.editSession.bytesForSave() == original else {
          throw PDFError(.malformed, "Native image pointer Undo did not restore exact source bytes")
        }
        document.redoEdit()
        guard try document.editSession.bytesForSave() == movedBytes else {
          throw PDFError(.malformed, "Native image pointer Redo did not restore its moved bytes")
        }
        document.redoEdit()
        guard try document.editSession.bytesForSave() == edited else {
          throw PDFError(.malformed, "Native image Redo did not restore exact bytes")
        }
        let saved = output.appendingPathComponent("saved.pdf")
        let saveError: Error? = await withCheckedContinuation { continuation in
          document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) {
            continuation.resume(returning: $0)
          }
        }
        if let saveError { throw saveError }
        document.close()
        let reopened = try SPDFDocument(contentsOf: saved, ofType: "com.adobe.pdf")
        NSDocumentController.shared.addDocument(reopened)
        reopened.makeWindowControllers()
        defer { reopened.close() }
        guard let again = reopened.viewer else {
          throw PDFError(.malformed, "Missing reopened native image workspace")
        }
        _ = again.activateTool(.imageEdit)
        guard let reselected = again.graphicsListProvider?(target.pageIndex).first(where: {
          abs($0.rect[0] - destination.minX) < 0.02
            && abs($0.rect[1] - destination.minY) < 0.02
            && abs($0.rect[2] - destination.maxX) < 0.02
            && abs($0.rect[3] - destination.maxY) < 0.02
            && $0.imagePlacementIndex != nil
        }) else { throw PDFError(.malformed, "Saved native image geometry did not reopen") }
        again.selectGraphics([reselected])
        guard again.selectedGraphics.count == 1, !reopened.isDocumentEdited,
          try Data(contentsOf: source) == sourceBytes
        else { throw PDFError(.malformed, "Native image reopen/reselection was not clean") }
        try original.write(to: output.appendingPathComponent("before.pdf"))
        try edited.write(to: output.appendingPathComponent("after.pdf"))
        try JSONSerialization.data(withJSONObject: [
          "status": "passed", "page": target.pageIndex,
          "imagePlacementIndex": target.imagePlacementIndex as Any,
          "initialBounds": [initial.minX, initial.minY, initial.maxX, initial.maxY],
          "pointerMovedBounds": [
            movedBounds.minX, movedBounds.minY, movedBounds.maxX, movedBounds.maxY,
          ],
          "savedBounds": [destination.minX, destination.minY, destination.maxX, destination.maxY],
          "undoRedoExact": true, "saveReopenReselect": true,
          "sourceFileUnchanged": true,
        ], options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("result.json"))
        print("sPDF native image check passed")
        exit(0)
      } catch {
        FileHandle.standardError.write(Data("Corpus native image check failed: \(error)\n".utf8))
        exit(1)
      }
    }

    static func checks(source: URL, output: URL, matching: String? = nil,
      wordOverride: String? = nil, replacementOverride: String? = nil) async throws {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let sourceBytes = try Data(contentsOf: source)
      let priorRecovery = SPDFDocument.recoveryDirectoryOverride
      defer { SPDFDocument.recoveryDirectoryOverride = priorRecovery }
      SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
      let document = try SPDFDocument(contentsOf: source, ofType: "com.adobe.pdf")
      document.makeWindowControllers()
      defer { document.close() }
      guard let graph = document.editSession.currentGraph, let viewer = document.viewer,
        let reader = viewer.view.document else { throw PDFError(.malformed, "Missing corpus document") }
      var chosen: PageTextTarget?
      var targetInventory: [[String: Any]] = []
      var pageDiagnostics: [[String: Any]] = []
      let allPages = CommandLine.arguments.contains("--corpus-all-pages")
      if allPages && matching == nil {
        throw PDFError(.unsupported, "All-pages corpus diagnostics require a target prefix")
      }
      let pageLimit = allPages
        ? document.editSession.pageIDs.count
        : min(3, document.editSession.pageIDs.count)
      let requestedPageIndex = CommandLine.arguments.firstIndex(of: "--corpus-page-index")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1)
          ? Int(CommandLine.arguments[$0 + 1]) : nil }
      let pageIndices: [Int]
      if let requestedPageIndex {
        guard document.editSession.pageIDs.indices.contains(requestedPageIndex) else {
          throw PDFError(.malformed, "Requested corpus page index is outside the document")
        }
        pageIndices = [requestedPageIndex]
      } else {
        pageIndices = Array(0..<pageLimit)
      }
      for index in pageIndices {
        guard let page = reader.page(at: index) else { continue }
        let pageID = document.editSession.pageIDs[index]
        let blocks = try PageTextEditing.blocks(pageID: pageID, in: graph)
        let sources = (try? PageTextEditing.sourceRuns(pageID: pageID, in: graph)) ?? []
        let profiles = (try? PageTextEditing.fontProfiles(pageID: pageID, in: graph)) ?? [:]
        var targetDiagnostics: [String] = []
        let targets = NativeParagraphEditing.targets(
          from: blocks, pageID: pageID, graph: graph, page: page, pageIndex: index,
          diagnostic: { message in
            if targetDiagnostics.count < 120 { targetDiagnostics.append(message) }
          })
        targetInventory += targets.map { target in
          ["page": index, "textPrefix": String(target.text.prefix(48)),
            "rect": target.rect, "runs": target.runIndices.count,
            "paragraph": target.paragraph != nil, "wraps": target.paragraph?.wraps ?? false]
        }
        pageDiagnostics.append([
          "page": index,
          "blocks": blocks.count,
          "targets": targets.count,
          "paragraphTargets": targets.filter { $0.paragraph != nil }.count,
          "targetDetails": targets.map { target in
            [
              "text": String(target.text.prefix(120)), "rect": target.rect,
              "runs": target.runIndices, "paragraph": target.paragraph != nil,
            ] as [String: Any]
          },
          "sourceRuns": sources.count,
          "reusableSourceRuns": sources.filter { $0.format.sourceFont != nil }.count,
          "targetDiagnostics": targetDiagnostics,
          "profiles": profiles.map { resource, profile in
            [
              "resource": String(decoding: resource.bytes, as: UTF8.self),
              "name": profile.source.name,
              "glyphCount": profile.glyphs.count,
              "programBytes": profile.program.count,
            ] as [String: Any]
          },
          "sourceSamples": sources.prefix(80).map { source in
            [
              "index": source.index, "text": String(source.text.prefix(80)),
              "x": source.x, "baseline": source.baseline,
              "scale": source.textScale,
              "spacing": source.format.characterSpacing,
              "font": source.format.fontName,
              "sourceFont": source.format.sourceFont?.name as Any,
              "sourceResource": source.format.sourceFont.map {
                String(decoding: $0.resource.bytes, as: UTF8.self)
              } as Any,
              "fragments": source.fragments.count,
            ] as [String: Any]
          },
          "blockSamples": blocks.prefix(80).map { block in
            [
              "text": String(block.text.prefix(80)), "rect": block.rect,
              "runs": block.runIndices.count,
              "font": block.style.fontFamily as Any,
            ] as [String: Any]
          },
        ])
        if let matching {
          chosen = targets.first { $0.paragraph != nil && $0.text.hasPrefix(matching) }
        } else {
          chosen = targets.first {
            $0.paragraph?.wraps == true && $0.text.count >= 50 && $0.rect[1] > 100
          } ?? targets.first {
            $0.paragraph != nil && $0.text.count >= 15
          }
        }
        if chosen != nil { break }
      }
      try JSONSerialization.data(withJSONObject: targetInventory,
        options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("targets.json"))
      try JSONSerialization.data(withJSONObject: pageDiagnostics,
        options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("diagnostics.json"))
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
        var overlay: PageEditOverlayView?
        for _ in 0..<50 {
          if let found = find(PageEditOverlayView.self, in: content) {
            overlay = found
            break
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard let overlay else {
          throw PDFError(.malformed, "Missing corpus pointer target")
        }
        let pagePoint = NSPoint(x: (target.rect[0] + target.rect[2]) / 2,
          y: (target.rect[1] + target.rect[3]) / 2)
        // Use the actual app's resolver before dispatching pointer events.
        // A refusal must fail the diagnostic rather than block in a modal.
        let hit = viewer.textRunProvider?(pageIndex, [pagePoint.x, pagePoint.y])
        let hitPreview = hit.flatMap { viewer.onTextBlockPreview?($0) }
        let hitSources = (try? PageTextEditing.sourceRuns(pageID: pageID, in: graph)) ?? []
        let hitBlocks = (try? PageTextEditing.blocks(pageID: pageID, in: graph)) ?? []
        func sourceDescription(_ indices: [Int]) -> [[String: Any]] {
          let set = Set(indices)
          return hitSources.filter { set.contains($0.index) }.map {
            [
              "index": $0.index, "text": $0.text, "x": $0.x,
              "baseline": $0.baseline, "scale": $0.textScale,
            ]
          }
        }
        func blockDescription(_ indices: [Int]) -> [[String: Any]] {
          let set = Set(indices)
          return hitBlocks.filter { !set.isDisjoint(with: $0.runIndices) }.map {
            ["text": $0.text, "rect": $0.rect, "runs": $0.runIndices]
          }
        }
        try JSONSerialization.data(withJSONObject: [
          "detectedRuns": target.runIndices, "hitRuns": hit?.runIndices ?? [],
          "detectedText": target.text, "detectedRect": target.rect,
          "hitText": hit?.text ?? "", "hitRect": hit?.rect ?? [],
          "detectedSources": sourceDescription(target.runIndices),
          "hitSources": sourceDescription(hit?.runIndices ?? []),
          "detectedBlocks": blockDescription(target.runIndices),
          "hitBlocks": blockDescription(hit?.runIndices ?? []),
          "hitIsParagraph": hit?.paragraph != nil,
          "hitPreviewAvailable": hitPreview != nil,
          "point": [pagePoint.x, pagePoint.y]
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("hit-target.json"))
        guard let hit, hit.paragraph != nil, hitPreview != nil else {
          throw PDFError(.unsupported, "The actual paragraph hit or its preview is unavailable")
        }
        let viewPoint = viewer.view.convert(pagePoint, from: page)
        let pointer = viewer.view.convert(viewPoint, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          guard let event = NSEvent.mouseEvent(with: type, location: pointer, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
            throw PDFError(.malformed, "Cannot construct corpus pointer event")
          }
          if type == .leftMouseDown { overlay.mouseDown(with: event) } else { overlay.mouseUp(with: event) }
        }
        guard let canvas = find(InlinePageTextCanvas.self, in: content),
          canvas.sourceTarget?.paragraph != nil else {
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
      func characters(_ canvas: InlinePageTextCanvas, document: SPDFDocument) -> [CharacterPosition] {
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
          return CharacterPosition(text: value, x: Double(point.x), baseline: Double(point.y))
        }
      }
      func compareCharacterPositions(
        _ expected: [CharacterPosition], _ actual: [CharacterPosition]
      ) -> (error: Double?, failure: String?) {
        guard expected.count == actual.count else {
          return (nil, "character count changed from \(expected.count) to \(actual.count)")
        }
        var maximum = 0.0
        for (index, pair) in zip(expected, actual).enumerated() {
          let (expected, actual) = pair
          guard expected.text == actual.text else {
            return (nil, "character text order changed at index \(index)")
          }
          maximum = max(maximum, max(abs(expected.x - actual.x),
            abs(expected.baseline - actual.baseline)))
        }
        return (maximum, nil)
      }
      let original = try document.editSession.bytesForSave()
      let canvas = try await select(document)
      // The workspace omits standalone whitespace hit targets. Its visible
      // paragraph must still agree with discovery and selection must be clean.
      guard canvas.textView.string == target.text, !viewer.hasPendingPageTextChanges,
        try document.editSession.bytesForSave() == original else {
        throw PDFError(.malformed, "Paragraph discovery and actual selection disagree or mutate the source")
      }
      if CommandLine.arguments.contains("--test-size-only") {
        guard let paragraph = target.paragraph,
          let sizeIndex = CommandLine.arguments.firstIndex(of: "--test-size-only"),
          CommandLine.arguments.indices.contains(sizeIndex + 1),
          let requestedSize = Double(CommandLine.arguments[sizeIndex + 1]) else {
          throw PDFError(.malformed, "Size-only check requires a paragraph and numeric size")
        }
        let originalSize = viewer.pageTextStyle.fontSize
        let selectedIndices = Set(paragraph.originalText.keys)
        let beforeRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: graph)
        let selectedBefore = beforeRuns.filter { selectedIndices.contains($0.index) }
        let neighborsBefore = beforeRuns.filter { !selectedIndices.contains($0.index) }
        guard !selectedBefore.isEmpty else {
          throw PDFError(.malformed, "The selected paragraph has no editable source runs")
        }

        func neighborComparison(
          _ before: [PageTextEditing.SourceRun], _ after: [PageTextEditing.SourceRun]
        ) -> (unchanged: Bool, maximumPositionDelta: Double?) {
          guard before.count == after.count else { return (false, nil) }
          var maximum = 0.0
          for (old, new) in zip(before, after) {
            guard old.index == new.index, old.text == new.text,
              old.format == new.format, abs(old.textScale - new.textScale) < 1e-8
            else { return (false, nil) }
            maximum = max(maximum, max(abs(old.x - new.x), abs(old.baseline - new.baseline)))
          }
          return (maximum < 0.02, maximum)
        }

        if let moveIndex = CommandLine.arguments.firstIndex(of: "--test-collision-dy"),
          CommandLine.arguments.indices.contains(moveIndex + 1),
          let downwardOffset = Double(CommandLine.arguments[moveIndex + 1]),
          downwardOffset.isFinite, downwardOffset > 0 {
          viewer.pageTextPositionApplier?(
            canvas.sourceRect.minX, canvas.sourceRect.minY - downwardOffset)
        } else {
          viewer.pageTextFormattingApplier?(.size(requestedSize))
        }
        let lines = canvas.pageLines()
        let style = viewer.pageTextStyle
        if CommandLine.arguments.contains("--expect-collision-refusal") {
          let committed = canvas.commit()
          let refusal = viewer.pageTextFormattingIssue ?? ""
          if committed {
            let edited = try document.editSession.bytesForSave()
            let undone = document.undoEdit()
            let restored = try document.editSession.bytesForSave() == original
            let sourceUnchanged = try Data(contentsOf: source) == sourceBytes
            let record: [String: Any] = [
              "status": "failed",
              "page": pageIndex,
              "requestedSize": requestedSize,
              "lineCount": lines.count,
              "refusal": refusal,
              "unexpectedlyCommitted": true,
              "undoRestoredOriginal": undone && restored,
              "sourceFileUnchanged": sourceUnchanged,
              "uncommittedOutputBytesChanged": edited != original,
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
              .write(to: output.appendingPathComponent("collision-check.json"))
            guard undone, restored, sourceUnchanged else {
              throw PDFError(.malformed, "Unexpected collision edit could not be undone exactly")
            }
            throw PDFError(.malformed, "The intended neighboring-text collision was accepted")
          }

          let refusalLeftGraphUnchanged = try document.editSession.bytesForSave() == original
          let isOverlapRefusal = refusal.localizedCaseInsensitiveContains("overlap another text block")
          let remainedEditable = viewer.isEditingPageText && viewer.hasPendingPageTextChanges
          let refusedGraph = document.editSession.currentGraph ?? graph
          let refusedRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: refusedGraph)
          let refusedNeighbors = refusedRuns.filter { !selectedIndices.contains($0.index) }
          let refusedNeighborCheck = neighborComparison(neighborsBefore, refusedNeighbors)
          canvas.cancel()
          let cancelLeftGraphUnchanged = try document.editSession.bytesForSave() == original
          let cleanAfterCancel = !viewer.isEditingPageText && !viewer.hasPendingPageTextChanges
            && !document.isDocumentEdited
          let sourceUnchanged = try Data(contentsOf: source) == sourceBytes
          let passed = isOverlapRefusal && refusalLeftGraphUnchanged
            && remainedEditable && refusedNeighborCheck.unchanged
            && cancelLeftGraphUnchanged && cleanAfterCancel && sourceUnchanged
          let record: [String: Any] = [
            "status": passed ? "passed" : "failed",
            "page": pageIndex,
            "targetRunIndices": paragraph.originalText.keys.sorted(),
            "originalSize": originalSize, "requestedSize": requestedSize,
            "lineCount": lines.count,
            "refusal": refusal,
            "refusedAsOverlap": isOverlapRefusal,
            "graphUnchangedOnRefusal": refusalLeftGraphUnchanged,
            "draftStayedEditableUntilCancel": remainedEditable,
            "neighborUnchanged": refusedNeighborCheck.unchanged,
            "neighborMaximumPositionDelta": refusedNeighborCheck.maximumPositionDelta as Any? ?? NSNull(),
            "cancelLeftGraphUnchanged": cancelLeftGraphUnchanged,
            "cleanAfterCancel": cleanAfterCancel,
            "sourceFileUnchanged": sourceUnchanged,
          ]
          try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("collision-check.json"))
          guard passed else {
            throw PDFError(.malformed, "Collision refusal, neighbor, or Cancel check failed")
          }
          return
        }
        guard abs(style.fontSize - requestedSize) < 0.02, lines.count == 1,
          canvas.commit(), !viewer.hasPendingPageTextChanges,
          let editedGraph = document.editSession.currentGraph else {
          throw PDFError(.unsupported,
            "In-bounds size correction did not commit: \(viewer.pageTextFormattingIssue ?? "native layout was not one line")")
        }
        let afterRuns = try PageTextEditing.sourceRuns(pageID: pageID, in: editedGraph)
        let selectedAfter = afterRuns.filter { selectedIndices.contains($0.index) }
        let neighborsAfter = afterRuns.filter { !selectedIndices.contains($0.index) }
        let liveNeighborCheck = neighborComparison(neighborsBefore, neighborsAfter)
        let selectedTextPreserved = selectedBefore.map(\.text) == selectedAfter.map(\.text)
          && selectedBefore.count == selectedAfter.count
        let selectedSizeApplied = !selectedAfter.isEmpty
          && selectedAfter.allSatisfy { abs($0.format.size - requestedSize) < 0.02 }

        let saved = output.appendingPathComponent("inbounds-correction.pdf")
        guard !FileManager.default.fileExists(atPath: saved.path) else {
          throw PDFError(.malformed, "The in-bounds correction output already exists")
        }
        let saveError: Error? = await withCheckedContinuation { continuation in
          document.save(to: saved, ofType: "com.adobe.pdf", for: .saveAsOperation) {
            continuation.resume(returning: $0)
          }
        }
        if let saveError { throw saveError }
        document.close()

        let reopened = try SPDFDocument(contentsOf: saved, ofType: "com.adobe.pdf")
        NSDocumentController.shared.addDocument(reopened)
        reopened.makeWindowControllers()
        defer { reopened.close() }
        guard reopened.editSession.pageIDs.indices.contains(pageIndex),
          let reopenedGraph = reopened.editSession.currentGraph else {
          throw PDFError(.malformed, "The corrected document did not reopen")
        }
        let reopenedPageID = reopened.editSession.pageIDs[pageIndex]
        let reopenedRuns = try PageTextEditing.sourceRuns(pageID: reopenedPageID, in: reopenedGraph)
        let reopenedSelected = reopenedRuns.filter { selectedIndices.contains($0.index) }
        let reopenedNeighbors = reopenedRuns.filter { !selectedIndices.contains($0.index) }
        let reopenedNeighborCheck = neighborComparison(neighborsBefore, reopenedNeighbors)
        let reopenedSizeApplied = reopenedSelected.count == selectedBefore.count
          && reopenedSelected.allSatisfy { abs($0.format.size - requestedSize) < 0.02 }
        let sourceUnchanged = try Data(contentsOf: source) == sourceBytes
        let passed = selectedTextPreserved && selectedSizeApplied
          && liveNeighborCheck.unchanged && reopenedSizeApplied
          && reopenedNeighborCheck.unchanged && sourceUnchanged
          && reopened.editSession.canEdit && !reopened.isDocumentEdited
        let record: [String: Any] = [
          "status": passed ? "passed" : "failed",
          "page": pageIndex,
          "targetRunIndices": paragraph.originalText.keys.sorted(),
          "originalSize": originalSize, "requestedSize": requestedSize,
          "lineCount": lines.count,
          "selectedTextPreserved": selectedTextPreserved,
          "selectedSizeApplied": selectedSizeApplied,
          "liveNeighborUnchanged": liveNeighborCheck.unchanged,
          "liveNeighborMaximumPositionDelta": liveNeighborCheck.maximumPositionDelta as Any? ?? NSNull(),
          "savedSizeApplied": reopenedSizeApplied,
          "savedNeighborUnchanged": reopenedNeighborCheck.unchanged,
          "savedNeighborMaximumPositionDelta": reopenedNeighborCheck.maximumPositionDelta as Any? ?? NSNull(),
          "saveReopenSucceeded": reopened.editSession.canEdit && !reopened.isDocumentEdited,
          "sourceFileUnchanged": sourceUnchanged,
          "output": saved.path,
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("inbounds-correction.json"))
        guard passed else {
          throw PDFError(.malformed, "In-bounds correction Save/reopen or neighbor check failed")
        }
        return
      }
      let beforeLines = canvas.pageLines()
      let beforeCharacters = characters(canvas, document: document)
      let selectedRuns = canvas.sourceTarget!.runIndices
      let originalBox = canvas.pageBox()
      if let clippingRect = target.paragraph?.clippingRect {
        try JSONSerialization.data(withJSONObject: ["detectedRect": target.rect,
          "selectedRect": [canvas.sourceRect.minX, canvas.sourceRect.minY, canvas.sourceRect.maxX, canvas.sourceRect.maxY],
          "clip": clippingRect, "lines": encode(beforeLines)], options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("selection.json"))
      }
      canvas.beginTyping()
      let words = canvas.textView.string.split(whereSeparator: \.isWhitespace).map(String.init)
      let word = wordOverride ?? words.last ?? ""
      guard words.contains(word), !word.isEmpty else { throw PDFError(.malformed, "The requested diagnostic word is absent") }
      guard !word.isEmpty else { throw PDFError(.malformed, "No source-font word for typing") }
      let clippingRect = target.paragraph?.clippingRect
      let replacement: String
      if matching != nil || clippingRect != nil {
        replacement = replacementOverride ?? String(word.reversed())
      } else {
        replacement = " " + word
      }
      guard !replacement.isEmpty, replacement != word else {
        throw PDFError(.malformed, "The requested diagnostic replacement must change the selected word")
      }
      if let clippingRect {
        // Exercise the real pending editor, including blocked movement and
        // recovery. No document transaction or partial save may escape it.
        viewer.pageTextPositionApplier?(canvas.sourceRect.minX, canvas.sourceRect.minY - (clippingRect[3] - clippingRect[1]) - 20)
        guard viewer.pageTextFormattingIssue != nil, !canvas.commit(),
          try document.editSession.bytesForSave() == original else {
          throw PDFError(.malformed, "Clipped text escaped the pending editor or changed the graph")
        }
        viewer.pageTextPositionApplier?(canvas.sourceRect.minX, canvas.sourceRect.minY)
        guard viewer.pageTextFormattingIssue == nil else {
          throw PDFError(.malformed, "Returning text inside its boundary did not clear overflow")
        }
      }
      if matching != nil || clippingRect != nil {
        let originalDraft = canvas.textView.string
        let originalDraftNSString = originalDraft as NSString
        let range = originalDraftNSString.range(of: word, options: .backwards)
        canvas.textView.setSelectedRange(range)
        let selectedBeforeInsert = canvas.textView.selectedRange()
        canvas.textView.insertText(replacement, replacementRange: range)
        let expectedText = originalDraftNSString.replacingCharacters(in: range, with: replacement)
        guard canvas.textView.string == expectedText else {
          throw PDFError(.unsupported,
            "Native corpus typing refused the requested replacement: \(viewer.pageTextFormattingIssue ?? "text mismatch"); selected=\(selectedBeforeInsert), actual=\(canvas.textView.string.debugDescription), expected=\(expectedText.debugDescription)")
        }
      } else {
        canvas.textView.setSelectedRange(NSRange(location: (canvas.textView.string as NSString).length, length: 0))
        canvas.textView.insertText(replacement, replacementRange: canvas.textView.selectedRange())
        guard canvas.textView.string.hasSuffix(replacement) else {
          throw PDFError(.malformed, "Native corpus typing did not insert the covered glyphs")
        }
      }
      if !CommandLine.arguments.contains("--corpus-keep-width") {
        canvas.setTextWidth(originalBox.width + 6)
      }
      let expectedText = canvas.textView.string, lines = canvas.pageLines(), box = canvas.pageBox()
      let savedCharacters = characters(canvas, document: document)
      guard canvas.commit() else {
        throw PDFError(.malformed,
          "Corpus paragraph did not commit: \(viewer.pageTextFormattingIssue ?? "no refusal reason was reported")")
      }
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
      let reopenedBox = again.pageBox()
      let widthError = abs(reopenedBox.width - box.width)
      // PDFs do not persist a paragraph box width. A glyph-advance change can
      // legitimately change the content-derived selection width after reopen;
      // compare saved glyph positions and clipping bounds instead.
      let reopenedCharacters = characters(again, document: reopened)
      let characterComparison = compareCharacterPositions(savedCharacters, reopenedCharacters)
      let reopenedCharacterPositionError = characterComparison.error
      let reopenedBoxFitsClip = clippingRect.map {
        reopenedBox.x >= $0[0] - 0.005
          && reopenedBox.x + reopenedBox.width <= $0[2] + 0.005
      } ?? true
      let checksBeforeCommit = [
        again.textView.string == expectedText, reopenedBoxFitsClip,
        actual.count == lines.count, positionError < 0.005,
        reopenedCharacterPositionError.map { $0 < 0.005 } == true,
        !reopened.viewer!.hasPendingPageTextChanges,
      ]
      let selectionCommitted = checksBeforeCommit.allSatisfy { $0 } && again.commit()
      let documentClean = !reopened.isDocumentEdited
      let sourceUnchanged = try Data(contentsOf: source) == sourceBytes
      try JSONSerialization.data(withJSONObject: [
        "reopenedTextMatches": checksBeforeCommit[0], "reopenedBoxFitsClip": reopenedBoxFitsClip,
        "reopenedWidthDelta": widthError,
        "reopenedBoxWidth": reopenedBox.width, "preSaveBoxWidth": box.width,
        "reopenedLineCount": actual.count, "expectedLineCount": lines.count,
        "reopenedPositionError": positionError,
        "reopenedCharacterPositionError": reopenedCharacterPositionError as Any? ?? NSNull(),
        "reopenedCharacterPositionFailure": characterComparison.failure as Any? ?? NSNull(),
        "reopenedCharacterCount": reopenedCharacters.count,
        "expectedCharacterCount": savedCharacters.count,
        "noPendingPageTextChanges": checksBeforeCommit[5],
        "selectionCommitClean": selectionCommitted, "documentClean": documentClean,
        "sourceUnchanged": sourceUnchanged,
      ], options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("reopen-validation.json"))
      guard checksBeforeCommit.allSatisfy({ $0 }), selectionCommitted,
        documentClean, sourceUnchanged else {
        throw PDFError(.malformed, "Corpus Save/reopen consistency check failed: \(checksBeforeCommit), commit=\(selectionCommitted), clean=\(documentClean), source=\(sourceUnchanged), lines=\(actual.count)/\(lines.count), widthError=\(widthError), positionError=\(positionError)")
      }
      try original.write(to: output.appendingPathComponent("before.pdf"))
      try edited.write(to: output.appendingPathComponent("after.pdf"))
      try JSONSerialization.data(withJSONObject: ["status": "passed", "page": pageIndex,
        "sourceRect": target.rect, "originalText": target.text, "originalLines": encode(beforeLines),
        "nativeLines": encode(lines), "savedText": expectedText, "savedWidth": box.width,
        "originalCharacters": beforeCharacters.map(\.json),
        "nativeCharacters": savedCharacters.map(\.json),
        "sourceRuns": selectedRuns, "reopenPositionError": positionError,
        "clippingRect": clippingRect as Any? ?? NSNull(),
        "clippedOverflowBlockedAndRepaired": clippingRect != nil,
        "matchedTarget": matching != nil,
        "editedWord": word, "replacement": replacement,
        "taskWordOverride": wordOverride != nil,
        "taskReplacementOverride": replacementOverride != nil,
        "sourceFileUnchanged": true, "fontProgramsAndMappingsUnchanged": true],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
    }
  }
#endif
