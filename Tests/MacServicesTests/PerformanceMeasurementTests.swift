import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import MacServices

/// P39-003–P39-029: consolidated performance, memory, and long-session
/// measurements on synthetic documents. Each measurement prints its number and
/// asserts a generous bound; corpus/UI-dependent measurements are recorded in
/// measured separately in an interactive session instead of being claimed here.
@Suite("Performance measurements")
struct PerformanceMeasurementTests {
  private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  private func millis(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000)
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
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

  /// A synthetic born-digital document: `pages` pages with `lines` lines each
  /// (and a heading), optionally with a shared image on every page.
  private func synthetic(
    pages: Int, lines: Int, image: Bool = false, fonts: Int = 1
  ) -> PDFGraph {
    var objects: [PDFObjectID: PDFValue] = [:]
    var kids: [PDFValue] = []
    var nextID = 1_000
    var fontResources: [PDFName: PDFValue] = [:]
    for index in 0..<fonts {
      let fontID = PDFObjectID(900 + index)
      fontResources[PDFName("F\(index + 1)")] = .reference(fontID)
      objects[fontID] = .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName(index % 2 == 0 ? "Helvetica" : "Times-Roman")),
        PDFName("Encoding"): .name(PDFName("WinAnsiEncoding")),
      ])
    }
    var resources: [PDFName: PDFValue] = [PDFName("Font"): .dictionary(fontResources)]
    if image {
      objects[PDFObjectID(950)] = .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(64), PDFName("Height"): .integer(64),
            PDFName("ColorSpace"): .name(PDFName("DeviceRGB")),
            PDFName("BitsPerComponent"): .integer(8),
          ], bytes: Data(repeating: 0x80, count: 64 * 64 * 3)))
      resources[PDFName("XObject")] = .dictionary([PDFName("Im1"): .reference(PDFObjectID(950))])
    }
    for page in 1...pages {
      let contentID = PDFObjectID(nextID)
      let pageID = PDFObjectID(nextID + 1)
      nextID += 2
      var content = "BT /F1 18 Tf 72 740 Td (Chapter \(page)) Tj ET\n"
      for line in 0..<lines {
        let font = "F\(line % fonts + 1)"
        content += "BT /\(font) 11 Tf 72 \(720 - line * 14) Td (Page \(page) line \(line) alpha beta gamma) Tj ET\n"
      }
      if image { content += "q 100 0 0 100 400 300 cm /Im1 Do Q\n" }
      objects[contentID] = .stream(PDFStream(bytes: Data(content.utf8)))
      objects[pageID] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary(resources),
        PDFName("Contents"): .reference(contentID),
      ])
      kids.append(.reference(pageID))
    }
    objects[PDFObjectID(1)] = .dictionary([
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ])
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(pages)),
      PDFName("Kids"): .array(kids),
    ])
    return PDFGraph(
      version: "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  }

  // MARK: - P39-003/P39-004

  @Test func smallAndLargeDocumentLatency() async throws {
    // Small: parse + first-page render.
    let small = try PDFParser.parse(PDFFixtures.onePage())
    let start = ContinuousClock.now
    _ = try PageImageExport.regionImageData(
      pageID: small.pageIDs[0], in: small.graph, region: [0, 0, 612, 792],
      options: PageImageExportOptions(format: .png, dpi: 144))
    let smallLatency = millis(ContinuousClock.now - start)

    // Large: a 200-page document opens without per-page work.
    let graph = synthetic(pages: 200, lines: 40)
    let writeStart = ContinuousClock.now
    let data = try PDFWriter.write(graph)
    let writeLatency = millis(ContinuousClock.now - writeStart)
    let openStart = ContinuousClock.now
    let parsed = try PDFParser.parse(data)
    let openLatency = millis(ContinuousClock.now - openStart)
    print(
      "[P39] small render \(smallLatency) ms; 200-page write \(writeLatency) ms, "
        + "open \(openLatency) ms, \(data.count / 1024) KiB")
    #expect(parsed.pageIDs.count == 200)
    #expect(smallLatency < 1_000)
    #expect(openLatency < 3_000)
  }

  /// P04-003: source-bytes profile — a large synthetic document opens
  /// from Data-backed bytes with bounded time and memory, which is the
  /// evidence behind retaining an owned source-byte snapshot.
  @Test func sourceBytesProfile() throws {
    let graph = synthetic(pages: 2000, lines: 40)
    let data = try PDFWriter.write(graph)
    let megabytes = Double(data.count) / Double(1 << 20)
    let before = memoryFootprint()
    let start = ContinuousClock.now
    let parsed = try PDFParser.parse(data)
    let latency = millis(ContinuousClock.now - start)
    let growth = memoryFootprint() > before ? memoryFootprint() - before : 0
    print(
      "[P04] source \(String(format: "%.1f", megabytes)) MiB: open \(latency) ms, footprint +\(growth / (1 << 20)) MiB")
    #expect(parsed.pageIDs.count == 2000)
    #expect(latency < 30_000)
    // Footprint is printed for observability only: allocator state varies
    // run to run, so no growth bound is asserted here (the decision
    // records the measured ratio instead).
    _ = growth
  }

  /// P06-029: lazy object-stream resolution across a many-page
  /// compressed-object document (Tests/Fixtures/xref-many.pdf: 100 pages in
  /// 5 object streams). Streams decode on demand; the benchmark pins the
  /// behavior with timing.
  @Test func objectStreamResolutionBenchmark() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/xref-many.pdf")
    let data = try Data(contentsOf: url)
    let start = ContinuousClock.now
    let parsed = try PDFParser.parse(data)
    let latency = millis(ContinuousClock.now - start)
    let attributes = PDFDocumentInventory.pageAttributes(
      pageIDs: parsed.pageIDs, in: parsed.graph)
    print(
      "[P06] 100-page object-stream file (\(data.count / 1024)) KiB: parse \(latency) ms")
    #expect(parsed.pageIDs.count == 100)
    #expect(attributes.count == 100)
    #expect(latency < 10_000)
  }

  /// P07-029: decode throughput on a large scanned-page-style Flate
  /// stream (zeros compress ~1000:1, the hostile-friendly shape).
  @Test func flateDecodeBenchmark() throws {
    let raw = Data(repeating: 0, count: 4 << 20)
    let encoded = try PDFFilters.encodeFlate(raw)
    let stream = PDFStream(
      dictionary: [PDFName("Filter"): .name(PDFName("FlateDecode"))],
      bytes: encoded)
    let start = ContinuousClock.now
    let decoded = try PDFFilters.decoded(stream)
    let latency = millis(ContinuousClock.now - start)
    print("[P07] Flate 4 MiB zeros (\(encoded.count / 1024) KiB on the wire): decode \(latency) ms")
    #expect(decoded == raw)
    #expect(latency < 10_000)
  }

  /// P09-029: large-save benchmark with bounded memory.
  @Test func largeSaveBenchmark() throws {
    let graph = synthetic(pages: 1000, lines: 40)
    let before = memoryFootprint()
    let start = ContinuousClock.now
    let data = try PDFWriter.write(graph)
    let latency = millis(ContinuousClock.now - start)
    let growth = memoryFootprint() > before ? memoryFootprint() - before : 0
    print("[P09] 1000-page save \((data.count) / (1 << 20)) MiB in \(latency) ms, footprint +\(growth / (1 << 20)) MiB")
    #expect(try PDFParser.parse(data).pageIDs.count == 1000)
    #expect(latency < 30_000)
  }

  // MARK: - P39-005/P39-007

  @Test func thumbnailThroughputAndCacheReuse() async throws {
    let graph = synthetic(pages: 8, lines: 20, image: true)
    func render(_ pages: [Int]) -> Int {
      let start = ContinuousClock.now
      for page in pages {
        _ = try? PageImageExport.regionImageData(
          pageID: graph.objects.keys.sorted().filter { id in
            if case .dictionary(let dictionary)? = graph.objects[id],
              dictionary[PDFName("Type")] == .name(PDFName("Page"))
            { return true }
            return false
          }[page], in: graph, region: [0, 0, 612, 792],
          options: PageImageExportOptions(format: .png, dpi: 72))
      }
      return millis(ContinuousClock.now - start)
    }
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let firstStart = ContinuousClock.now
    for pageID in pageIDs {
      _ = try PageImageExport.regionImageData(
        pageID: pageID, in: graph, region: [0, 0, 612, 792],
        options: PageImageExportOptions(format: .png, dpi: 72))
    }
    let firstPass = millis(ContinuousClock.now - firstStart)
    let secondStart = ContinuousClock.now
    for pageID in pageIDs {
      _ = try PageImageExport.regionImageData(
        pageID: pageID, in: graph, region: [0, 0, 612, 792],
        options: PageImageExportOptions(format: .png, dpi: 72))
    }
    let secondPass = millis(ContinuousClock.now - secondStart)
    print("[P39] 8 thumbnails at 72 dpi: pass1 \(firstPass) ms, pass2 \(secondPass) ms")
    #expect(firstPass < 5_000)
    #expect(secondPass < 5_000)
    _ = render([0])
  }

  // MARK: - P39-008/P39-009/P39-010

  @Test func denseContentSearchAndFontLatency() throws {
    let graph = synthetic(pages: 50, lines: 40, fonts: 8)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    // Content interpretation on one dense page.
    let layoutStart = ContinuousClock.now
    let layout = try PageTextLayout.build(pageID: pageIDs[0], in: graph)
    let candidates = try ParagraphReconstruction.candidates(pageID: pageIDs[0], in: graph)
    let layoutLatency = millis(ContinuousClock.now - layoutStart)
    // Search across the document, including transient index memory.
    let searchBefore = memoryFootprint()
    let searchStart = ContinuousClock.now
    var matches = 0
    for pageID in pageIDs {
      let pageLayout = try PageTextLayout.build(pageID: pageID, in: graph)
      matches += TextSearch.search(query: "alpha", in: pageLayout).count
    }
    let searchLatency = millis(ContinuousClock.now - searchStart)
    let searchGrowth = memoryFootprint() > searchBefore ? memoryFootprint() - searchBefore : 0
    // Font loading/shaping across pages.
    let fontStart = ContinuousClock.now
    let fonts = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let fontLatency = millis(ContinuousClock.now - fontStart)
    print(
      "[P39] dense layout \(layoutLatency) ms (\(layout.clusters.count) clusters, "
        + "\(candidates.count) candidates); 50-page search \(searchLatency) ms "
        + "(\(matches) matches, growth \(searchGrowth / 1_048_576) MiB); "
        + "fonts \(fontLatency) ms (\(fonts.count))")
    #expect(!candidates.isEmpty)
    #expect(matches > 0)
    #expect(layoutLatency < 2_000)
    #expect(searchLatency < 10_000)
    #expect(fontLatency < 2_000)
  }

  // MARK: - P39-010

  @Test func fontLoadingShapingAndSubsetReuse() throws {
    // Loading: inventory across the 50-page synthetic doc, two passes.
    let graph = synthetic(pages: 50, lines: 40, fonts: 8)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let loadStart = ContinuousClock.now
    let firstInventory = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let loadLatency = millis(ContinuousClock.now - loadStart)
    let reloadStart = ContinuousClock.now
    let secondInventory = PDFFontInventory.fonts(in: graph, pageIDs: pageIDs)
    let reloadLatency = millis(ContinuousClock.now - reloadStart)
    #expect(firstInventory.count == secondInventory.count)
    // Shaping: latin, ligature/combining, and RTL strings through CoreText,
    // two passes with identical results (no shaping cache in the path).
    let provider = FontProvider()
    let samples = [
      ("Hello world", "Helvetica", "en"),
      ("fi â İstanbul", "Helvetica", "tr"),
      ("שלום עולם", "Helvetica", "he"),
    ]
    func shapeAll() -> Int {
      var glyphs = 0
      for (text, font, language) in samples {
        for _ in 0..<20 {
          glyphs += provider.shape(text, fontName: font, pointSize: 12, language: language).glyphs.count
        }
      }
      return glyphs
    }
    let shapeStart = ContinuousClock.now
    let firstGlyphs = shapeAll()
    let shapeLatency = millis(ContinuousClock.now - shapeStart)
    let reshapeStart = ContinuousClock.now
    let secondGlyphs = shapeAll()
    let reshapeLatency = millis(ContinuousClock.now - reshapeStart)
    #expect(firstGlyphs > 0)
    #expect(secondGlyphs == firstGlyphs)
    // Subsetting: same program+coverage twice. There is no subset-data
    // cache, so both runs do the work; determinism (identical bytes) is
    // what makes graph-dedup reuse (P15-022) sound.
    guard let program = Data(base64Encoded: FontFixtureData.subsetProgramBase64) else {
      Issue.record("test font program is corrupt")
      return
    }
    let coverage: Set<Int> = [0x41, 0xE2]
    let subsetStart = ContinuousClock.now
    let firstSubset = try TrueTypeSubsetter.subset(program: program, unicodes: coverage)
    let subsetLatency = millis(ContinuousClock.now - subsetStart)
    let resubsetStart = ContinuousClock.now
    let secondSubset = try TrueTypeSubsetter.subset(program: program, unicodes: coverage)
    let resubsetLatency = millis(ContinuousClock.now - resubsetStart)
    #expect(!firstSubset.isEmpty)
    #expect(secondSubset == firstSubset)
    print(
      "[P39] fonts load \(loadLatency)/\(reloadLatency) ms (\(firstInventory.count)); "
        + "shape \(shapeLatency)/\(reshapeLatency) ms (\(firstGlyphs) glyphs); "
        + "subset \(subsetLatency)/\(resubsetLatency) ms (\(firstSubset.count) bytes, deterministic)")
    #expect(loadLatency < 2_000)
    #expect(reloadLatency < 2_000)
    #expect(shapeLatency < 5_000)
    #expect(reshapeLatency < 5_000)
    #expect(subsetLatency < 5_000)
    #expect(resubsetLatency < 5_000)
  }

  // MARK: - P39-016 (comment core half; sidebar rendering needs the UI session)

  @Test func commentListFilterThreadsAndSummaryAtScale() throws {
    // 1,000 text annotations across 10 pages with mixed review states and
    // every tenth as a reply; times listing, filtering, threading, and the
    // review summary over two passes (pure functions, so passes agree).
    var graph = synthetic(pages: 10, lines: 5)
    let parsedIDs = try PDFPageTree.pageIDs(in: graph)
    let states: [PDFName?] = [nil, PDFName("Accepted"), PDFName("Rejected")]
    var nextID = 5_000
    var replyParent: PDFObjectID?
    for (pageIndex, pageID) in parsedIDs.enumerated() {
      var items: [PDFValue] = []
      for index in 0..<100 {
        let annotationID = PDFObjectID(nextID)
        nextID += 1
        var dict: [PDFName: PDFValue] = [
          PDFName("Type"): .name(PDFName("Annot")),
          PDFName("Subtype"): .name(PDFName("Text")),
          PDFName("Rect"): .array([
            .integer(10), .integer(10), .integer(30), .integer(30),
          ]),
          PDFName("Contents"): .string(Data("page \(pageIndex) note \(index)".utf8)),
          PDFName("T"): .string(Data("Reviewer \(index % 7)".utf8)),
        ]
        if let state = states[index % states.count] {
          dict[PDFName("State")] = .name(state)
          dict[PDFName("StateModel")] = .name(PDFName("Review"))
        }
        if index % 10 == 9, let parent = replyParent {
          dict[PDFName("IRT")] = .reference(parent)
          dict[PDFName("RT")] = .name(PDFName("R"))
          replyParent = nil
        } else if index % 10 == 8 {
          replyParent = annotationID
        }
        graph.objects[annotationID] = .dictionary(dict)
        items.append(.reference(annotationID))
      }
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        Issue.record("synthetic page is missing")
        return
      }
      page[PDFName("Annots")] = .array(items)
      graph.objects[pageID] = .dictionary(page)
    }
    func measure() throws -> (listed: Int, threads: Int, summary: String, ms: Int) {
      let start = ContinuousClock.now
      let listed = CommentList.comments(in: graph, pageIDs: parsedIDs)
      let accepted = CommentList.filter(listed, by: CommentFilter(state: PDFName("Accepted")))
      let threaded = CommentList.threads(listed, by: CommentFilter())
      let summary = CommentSummary.text(comments: listed)
      _ = accepted.count
      return (listed.count, threaded.count, summary, millis(ContinuousClock.now - start))
    }
    let first = try measure()
    let second = try measure()
    #expect(first.listed == 1_000)
    #expect(second.listed == first.listed)
    #expect(second.threads == first.threads)
    #expect(first.threads == 900)
    #expect(second.summary == first.summary)
    #expect(first.summary.contains("Comments: 1000"))
    print(
      "[P39] 1000 comments: list/filter/threads/summary \(first.ms)/\(second.ms) ms "
        + "(\(first.threads) threads)")
    #expect(first.ms < 5_000)
    #expect(second.ms < 5_000)
  }

  // MARK: - P39-014 (recognition runs on this machine; hosted CI may differ)

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["SPDF_RUN_VISION_BENCHMARKS"] == "1",
      "Real Vision throughput is an opt-in host measurement; hosted runners can stall."))
  func ocrConcurrencyThroughputAndCancellation() async throws {
    // The host must have a working Vision recognition service. Routine CI
    // still checks language availability, tolerant recognition, rasterization
    // and deterministic job cancellation in OCRJobTests.
    // Each task opens its own PDFDocument because it is not Sendable.
    let fixture = try PDFFixtures.threePages()
    guard PDFDocument(data: fixture)?.pageCount == 3 else {
      Issue.record("three-page fixture did not open")
      return
    }
    func runPages(_ indexes: [Int]) throws -> Int {
      guard let document = PDFDocument(data: fixture) else { return -1 }
      return try OCRJob.run(
        document: document, pageIndexes: indexes, languages: ["en"], level: .fast
      ).reduce(0) { $0 + $1.lines.count }
    }
    // Sequential baseline over all pages.
    let seqStart = ContinuousClock.now
    let seqLines = try runPages([0, 1, 2])
    let seqMs = millis(ContinuousClock.now - seqStart)
    #expect(seqLines >= 0)
    // Concurrent: one job per page.
    let concStart = ContinuousClock.now
    let concLines = try await withThrowingTaskGroup(of: Int.self) { group in
      for index in 0..<3 {
        group.addTask { try runPages([index]) }
      }
      var total = 0
      for try await lines in group { total += lines }
      return total
    }
    let concMs = millis(ContinuousClock.now - concStart)
    #expect(concLines == seqLines)
    // Temperature drift: two more sequential rounds, recorded not asserted.
    var rounds = [seqMs]
    for _ in 1...2 {
      let start = ContinuousClock.now
      _ = try runPages([0, 1, 2])
      rounds.append(millis(ContinuousClock.now - start))
    }
    // Cancellation: cancel mid-run (after ~50 ms into ~20 fast pages),
    // so the acknowledgement crosses an in-flight page boundary.
    guard let cancelDoc = PDFDocument(data: fixture) else {
      Issue.record("fixture did not open for cancellation")
      return
    }
    let progressBox = ProgressCounter()
    let cancelStart = ContinuousClock.now
    let job = Task {
      try OCRJob.run(
        document: cancelDoc, pageIndexes: Array(repeating: 0, count: 20),
        languages: ["en"], level: .fast,
        onProgress: { _, _ in progressBox.increment() })
    }
    try await Task.sleep(for: .milliseconds(50))
    job.cancel()
    let ackMs: Int
    do {
      _ = try await job.value
      ackMs = millis(ContinuousClock.now - cancelStart)
    } catch is CancellationError {
      ackMs = millis(ContinuousClock.now - cancelStart)
    } catch {
      Issue.record("cancellation threw \(error) instead of CancellationError")
      return
    }
    #expect(progressBox.value > 0, "cancel landed before any page finished")
    print(
      "[P39] OCR 3 pages: sequential \(seqMs) ms (\(seqLines) lines), "
        + "concurrent \(concMs) ms (\(concLines) lines), "
        + "repeat rounds \(rounds.map(String.init).joined(separator: "/")) ms, "
        + "cancel ack \(ackMs) ms")
    #expect(seqMs < 120_000)
    #expect(concMs < 120_000)
    #expect(ackMs < 10_000)
  }

  // MARK: - P39-011

  @Test func textEditPreviewAndCommitLatency() throws {
    let graph = synthetic(pages: 1, lines: 30)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: graph)
    let candidate = try #require(candidates.first { $0.text.contains("line") })
    let planStart = ContinuousClock.now
    let plan = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate,
      replacement: "Reflowed replacement text for the measured paragraph.",
      in: graph, options: ParagraphReflowOptions(allowLowConfidence: true))
    let planLatency = millis(ContinuousClock.now - planStart)
    let commitStart = ContinuousClock.now
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReflowParagraphCommand(
          pageID: pageID, candidate: candidate,
          replacement: "Reflowed replacement text for the measured paragraph.",
          options: ParagraphReflowOptions(allowLowConfidence: true))
      ]), to: graph)
    let commitLatency = millis(ContinuousClock.now - commitStart)
    print("[P39] reflow plan \(planLatency) ms, commit \(commitLatency) ms")
    #expect(!plan.plan.lines.isEmpty)
    #expect(planLatency < 1_000)
    #expect(commitLatency < 1_000)
    #expect(edited != graph)
  }

  // MARK: - P39-012

  @Test func largeImageReplacementMemory() throws {
    let parsed = try PDFParser.parse(PDFFixtures.imagePages())
    let pageID = parsed.pageIDs[0]
    let width = 1_024
    let height = 1_024
    let pixels = Data(repeating: 0x40, count: width * height * 3)
    let before = memoryFootprint()
    let start = ContinuousClock.now
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceImageDataCommand(
          pageID: pageID, placementIndex: 0, width: width, height: height, rgb8: pixels)
      ]), to: parsed.graph)
    let latency = millis(ContinuousClock.now - start)
    let growth = memoryFootprint() > before ? memoryFootprint() - before : 0
    print("[P39] 1024² image replace: \(latency) ms, growth \(growth / 1_048_576) MiB")
    #expect(latency < 2_000)
    #expect(growth < 256 * 1_048_576)
    #expect(edited != parsed.graph)
  }

  // MARK: - P39-013

  @Test func pageMergeAndSaveThroughput() throws {
    let graph = synthetic(pages: 100, lines: 20, image: true)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    let start = ContinuousClock.now
    var edited = graph
    edited = try PDFEditingEngine.commit(
      PDFTransaction([ReorderPagesCommand(pageID: pageIDs[5], toIndex: 1)]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([InsertBlankPageCommand(atIndex: 2, width: 612, height: 792)]), to: edited)
    edited = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [pageIDs[3]])]), to: edited)
    let structural = millis(ContinuousClock.now - start)
    let before = memoryFootprint()
    let saveStart = ContinuousClock.now
    let data = try PDFWriter.write(edited)
    let saveLatency = millis(ContinuousClock.now - saveStart)
    let growth = memoryFootprint() > before ? memoryFootprint() - before : 0
    print(
      "[P39] 100-page structural edits \(structural) ms, full rewrite \(saveLatency) ms "
        + "(\(data.count / 1024) KiB), growth \(growth / 1_048_576) MiB")
    #expect(structural < 5_000)
    #expect(saveLatency < 5_000)
    #expect(growth < 512 * 1_048_576)
  }

  // MARK: - P39-015/P39-016/P39-017

  @Test func redactionFormAndExportCosts() throws {
    // Redaction across 20 pages.
    let graph = synthetic(pages: 20, lines: 30)
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    var redacted = graph
    let redactStart = ContinuousClock.now
    for pageID in pageIDs {
      // Cover one whole paragraph candidate (never a partial text run).
      let candidates = try ParagraphReconstruction.candidates(pageID: pageID, in: redacted)
      guard let candidate = candidates.first else { continue }
      let bounds = candidate.bounds
      let region = [bounds[0] - 2, bounds[1] - 2, bounds[2] + 2, bounds[3] + 2]
      redacted = try PDFEditingEngine.commit(
        PDFTransaction([RedactRegionsCommand(pageID: pageID, regions: [region])]),
        to: redacted)
    }
    let redactLatency = millis(ContinuousClock.now - redactStart)
    #expect(redacted != graph)

    // Forms and comments scale.
    let formStart = ContinuousClock.now
    var formed = graph
    for index in 0..<200 {
      formed = try PDFEditingEngine.commit(
        PDFTransaction([
          AddTextFieldCommand(
            pageID: pageIDs[0], rect: [40, Double(400 - index), 200, Double(420 - index)],
            name: "field\(index)")
        ]), to: formed)
    }
    let formLatency = millis(ContinuousClock.now - formStart)

    // Comparison and Office export on the synthetic document.
    let compareStart = ContinuousClock.now
    let comparison = try PDFComparison.compare(
      left: (graph: graph, source: try PDFWriter.write(graph)),
      right: (graph: redacted, source: try PDFWriter.write(redacted)))
    let compareLatency = millis(ContinuousClock.now - compareStart)

    var tables: [ExtractedTable] = []
    for page in 0..<10 {
      var cells: [ExtractedTable.Cell] = []
      for row in 0..<20 {
        for column in 0..<5 {
          cells.append(
            ExtractedTable.Cell(
              row: row, column: column, text: "r\(row)c\(column)", bounds: [0, 0, 50, 10],
              provenance: .text, confidence: 0.9))
        }
      }
      tables.append(
        ExtractedTable(
          pageIndex: page, detection: .geometry, bounds: [0, 0, 250, 200], rowCount: 20,
          columnCount: 5, cells: cells, confidence: 0.8, limitations: []))
    }
    let exportBefore = memoryFootprint()
    let exportStart = ContinuousClock.now
    let xlsx = try XLSXExport.package(tables: tables)
    let docx = try DOCXExport.package(
      reconstruction: DOCXReconstruction(
        blocks: (0..<500).map { index in
          DOCXBlock(kind: .paragraph, runs: [DOCXRunInput(text: "Line \(index)")])
        }, pageWidth: 612, pageHeight: 792, landscape: false, limitations: []))
    let exportLatency = millis(ContinuousClock.now - exportStart)
    let exportGrowth = memoryFootprint() > exportBefore ? memoryFootprint() - exportBefore : 0
    print(
      "[P39] 20-page redaction \(redactLatency) ms; 200 fields \(formLatency) ms; "
        + "comparison \(compareLatency) ms (\(comparison.changes.count) changes); "
        + "XLSX \(xlsx.count / 1024) KiB + DOCX \(docx.count / 1024) KiB in \(exportLatency) ms "
        + "(growth \(exportGrowth / 1_048_576) MiB)")
    #expect(redactLatency < 10_000)
    #expect(formLatency < 10_000)
    #expect(compareLatency < 10_000)
    #expect(exportLatency < 5_000)
  }

  // MARK: - P39-023/P39-027

  @Test func undoGrowthAndLongSessionCyclesStayBounded() throws {
    // Undo history is bounded across many edits.
    let graph = synthetic(pages: 1, lines: 10)
    let pageID = try PDFPageTree.pageIDs(in: graph)[0]
    var session = graph
    let before = memoryFootprint()
    for index in 0..<300 {
      session = try PDFEditingEngine.commit(
        PDFTransaction([
          RotatePagesCommand(pageIDs: [pageID], byDegrees: index % 4 == 0 ? 90 : 0)
        ]), to: session)
    }
    let growth = memoryFootprint() > before ? memoryFootprint() - before : 0
    print("[P39] 300 edits growth \(growth / 1_048_576) MiB")
    #expect(growth < 512 * 1_048_576)

    // Long open/edit/save/close cycles do not leak unboundedly.
    let data = try PDFWriter.write(graph)
    let cycleBefore = memoryFootprint()
    for _ in 0..<50 {
      let parsed = try PDFParser.parse(data)
      let edited = try PDFEditingEngine.commit(
        PDFTransaction([RotatePagesCommand(pageIDs: [parsed.pageIDs[0]], byDegrees: 90)]),
        to: parsed.graph)
      _ = try PDFWriter.write(edited)
    }
    let cycleGrowth = memoryFootprint() > cycleBefore ? memoryFootprint() - cycleBefore : 0
    print("[P39] 50 open/edit/save cycles growth \(cycleGrowth / 1_048_576) MiB")
    #expect(cycleGrowth < 256 * 1_048_576)
  }

  // MARK: - P39-029

  @Test func releaseBundleSizeIsBounded() throws {
    let app = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Work/Build/Build/Products/Debug/sPDF Editor.app")
    guard FileManager.default.fileExists(atPath: app.path) else { return }
    var total: UInt64 = 0
    if let enumerator = FileManager.default.enumerator(
      at: app, includingPropertiesForKeys: [.fileSizeKey])
    {
      for case let url as URL in enumerator {
        total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    }
    print("[P39] Debug app bundle \(total / 1_048_576) MiB")
    #expect(total < 400 * 1_048_576)
  }
}
