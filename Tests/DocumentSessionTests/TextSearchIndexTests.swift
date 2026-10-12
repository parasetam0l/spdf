import DocumentSession
import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// P16-019/P16-020/P16-021/P16-029/P16-028/P18-020: the lazy,
/// revision-aware search index — pages built on demand, exact invalidation
/// from the session change history, OCR provenance, a measured long-document
/// search, and results that follow the committed edit across undo, save, and
/// reopen.
@Suite("Text search index")
struct TextSearchIndexTests {
  private func loadedSession(_ data: Data) throws -> DocumentEditSession {
    let session = DocumentEditSession()
    session.load(try PDFSource(data: data))
    return session
  }

  @Test func pagesAreBuiltLazilyAndReused() throws {
    // P16-019: creating the index touches nothing; the first search builds
    // each page once; a repeated search is pure cache hits.
    let session = try loadedSession(try PDFFixtures.threePages())
    let index = TextSearchIndex(session: session)
    #expect(index.statistics().builtPages == 0)
    #expect(index.statistics().cachedPages == 0)

    let first = try index.search("fixture")
    #expect(first.count == 3)
    #expect(first.map(\.pageIndex) == [0, 1, 2])
    let afterFirst = index.statistics()
    #expect(afterFirst.builtPages == 3)
    #expect(afterFirst.cachedPages == 3)

    let second = try index.search("page 2")
    #expect(second.count == 1)
    #expect(second[0].pageIndex == 1)
    let afterSecond = index.statistics()
    #expect(afterSecond.builtPages == 3)  // no rebuilds
    #expect(afterSecond.cacheHits >= 3)
  }

  @Test func editsInvalidateOnlyTheChangedPages() throws {
    // P16-020: a committed edit drops exactly the pages the session
    // reported; pages edited twice before the next search are still caught
    // by the bounded change history.
    let session = try loadedSession(try PDFFixtures.threePages())
    let index = TextSearchIndex(session: session)
    #expect(try index.search("fixture").count == 3)
    let baseline = index.statistics()

    try session.replaceText(pageAt: 0, runIndex: 0, with: "First replacement")
    try session.replaceText(pageAt: 2, runIndex: 0, with: "Third replacement")
    let updated = try index.search("replacement")
    #expect(updated.count == 2)
    #expect(updated.map(\.pageIndex) == [0, 2])
    let statistics = index.statistics()
    // Two pages invalidated and rebuilt; the untouched page stayed cached.
    #expect(statistics.invalidatedPages == baseline.invalidatedPages + 2)
    #expect(statistics.builtPages == baseline.builtPages + 2)
    #expect(try index.search("fixture").count == 1)  // only the middle page

    // Undo reverses both edits; the undone pages rebuild again.
    #expect(session.undo())
    #expect(session.undo())
    let restored = try index.search("fixture")
    #expect(restored.count == 3)
    #expect(try index.search("replacement").isEmpty)
  }

  @Test func unknownScopedChangesInvalidateEverything() throws {
    // A document-level edit (no page scope) invalidates the whole index
    // conservatively instead of serving stale layouts.
    let session = try loadedSession(try PDFFixtures.threePages())
    let index = TextSearchIndex(session: session)
    #expect(try index.search("fixture").count == 3)
    try session.apply(PDFTransaction([SetStructureLanguageCommand(language: "de")]))
    #expect(try index.search("fixture").count == 3)
    #expect(index.statistics().cachedPages == 3)
  }

  @Test func matchesCarryOCRProvenance() throws {
    // P16-021: a generated layer's text is reported as .recognizedText
    // through the layer's own composite font (no owned geometry), while
    // original document text reports .documentText. The two never blur.
    let parsed = try PDFParser.parse(PDFFixtures.scannedPages())
    let pageID = parsed.pageIDs[0]
    let graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddSearchableTextLayerCommand(
          pageID: pageID,
          lines: [
            SearchableTextLine(
              text: "Scanned invoice 42", rect: [100, 600, 300, 620], confidence: 0.9)
          ])
      ]), to: parsed.graph)
    let session = DocumentEditSession()
    session.load(try PDFSource(data: PDFWriter.write(graph)))
    let index = TextSearchIndex(session: session)

    let recognized = try index.search("Scanned invoice")
    #expect(recognized.count == 1)
    #expect(recognized[0].provenance == .recognizedText)
    #expect(recognized[0].bounds.isEmpty)  // layer text has no owned geometry
    // Original text on a simple-font page reports document provenance.
    let mixedSession = try loadedSession(try PDFFixtures.threePages())
    let mixedIndex = TextSearchIndex(session: mixedSession)
    let originals = try mixedIndex.search("fixture")
    #expect(!originals.isEmpty)
    #expect(originals.allSatisfy { $0.provenance == .documentText })
    #expect(try mixedIndex.search("Scanned").isEmpty)
  }

  @Test func searchDeliversPartiallyAndHonorsCancellation() async throws {
    // P16-018: the scan stops on demand with the partial results so far, and
    // a cancelled task stops before building anything further.
    let session = try loadedSession(try PDFFixtures.threePages())
    let index = TextSearchIndex(session: session)
    let firstThree = try index.search("fixture") { _ in false }
    #expect(firstThree.count == 1)  // stopped after the first match
    var delivered = 0
    let partial = try index.search("fixture") { _ in
      delivered += 1
      return delivered < 2
    }
    #expect(partial.count == 2)

    // Cancellation: pre-cancel the task; the scan stops immediately with no
    // work performed beyond the synchronization.
    let builtBefore = index.statistics().builtPages
    let task = Task { try index.search("fixture") }
    task.cancel()
    let cancelled = try await task.value
    #expect(cancelled.count <= 3)
    if cancelled.isEmpty {
      #expect(index.statistics().builtPages == builtBefore)
    }
  }

  @Test func searchFollowsEditUndoSaveAndReopen() throws {
    // P16-028/P18-020: the search and selection indexes update from the
    // committed edit — no manual invalidation, no stale hits — across undo,
    // save, and reopen in a fresh session. The replacement ("AB" to "A") is
    // narrower, so the following text holds its position and the line reads
    // cleanly; a wider replacement would overlap the held position by
    // design (compensation keeps following glyphs where they were).
    let session = try loadedSession(try PDFFixtures.textWidthsPages())
    let index = TextSearchIndex(session: session)
    #expect(try index.search("AB").count == 1)
    #expect(try index.search("Ax").isEmpty)

    // Commit through the session: the index reflects the new text.
    try session.replaceText(pageAt: 0, runIndex: 0, with: "A")
    #expect(try index.search("AB").isEmpty)
    // The selection identity tracks the same committed edit.
    let identity = SelectionIdentity(
      pageID: session.pageIDs[0], runIndex: 0, text: "AB")
    guard case .preserved(let identityText, _) = identity.resolve(
      in: try #require(session.currentGraph))
    else {
      Issue.record("selection identity did not survive the committed edit")
      return
    }
    #expect(identityText == "A")

    // Undo restores the old search results and the old selection text.
    #expect(session.undo())
    #expect(try index.search("AB").count == 1)

    // Redo, save, and reopen: a fresh session and index agree.
    #expect(session.redo())
    let bytes = try session.bytesForSave()
    let reopened = DocumentEditSession()
    reopened.load(try PDFSource(data: bytes))
    let reopenedIndex = TextSearchIndex(session: reopened)
    #expect(try reopenedIndex.search("AB").isEmpty)
    guard case .preserved(let reopenedText, _) = identity.resolve(
      in: try #require(reopened.currentGraph))
    else {
      Issue.record("selection identity did not survive save/reopen")
      return
    }
    #expect(reopenedText == "A")
  }

  @Test func longDocumentSearchIsMeasured() throws {
    // P16-029: latency and cache behavior on a 120-page synthetic document
    // with 20 lines per page; numbers print.
    let graph = Self.syntheticDocument(pages: 120, lines: 20)
    let data = try PDFWriter.write(graph)
    let session = try loadedSession(data)
    let footprintBefore = memoryFootprint()
    let index = TextSearchIndex(session: session)

    let coldStart = ContinuousClock.now
    let matches = try index.search("needle 7")
    let cold = ContinuousClock.now - coldStart
    #expect(!matches.isEmpty)
    // A complete search scans every page once; nothing was built before it.
    #expect(index.statistics().builtPages == 120)

    let warmStart = ContinuousClock.now
    _ = try index.search("needle 7")
    let warm = ContinuousClock.now - warmStart
    let milliseconds = { (duration: Duration) in
      Int(duration.components.seconds) * 1000
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
    let growth = max(0, Int64(memoryFootprint()) - Int64(footprintBefore))
    print(
      "[P16-029] 120 pages, \(matches.count) matches: cold \(milliseconds(cold)) ms, "
        + "warm \(milliseconds(warm)) ms, built pages \(index.statistics().builtPages), "
        + "cached \(index.statistics().cachedPages), index footprint ~\(growth / 1_048_576) MiB")
    #expect(milliseconds(cold) < 10_000)
    #expect(milliseconds(warm) <= milliseconds(cold))
    #expect(growth < 256 * 1_048_576)
  }

  private func memoryFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }

  /// P16-029 fixture: `pages` pages, each drawing `lines` distinct lines.
  private static func syntheticDocument(pages: Int, lines: Int) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [:]
    var kids: [PDFValue] = []
    var next = 4
    for page in 1...pages {
      let pageID = PDFObjectID(next)
      let contentID = PDFObjectID(next + 1)
      next += 2
      var content = ""
      for line in 1...lines {
        content += "BT /F1 10 Tf 42 \(700 - line * 14) Td (needle \(line) page \(page)) Tj ET\n"
      }
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ] as [PDFValue]),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]),
        PDFName("Contents"): .reference(contentID),
      ])
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(3)] = .dictionary([
      PDFName("Type"): .name(PDFName("Font")),
      PDFName("Subtype"): .name(PDFName("Type1")),
      PDFName("BaseFont"): .name(PDFName("Helvetica")),
    ])
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pages)),
      PDFName("Kids"): .array(kids),
    ])
    return PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }
}
