import AppKit
import MacServices
import PDFCore
import PDFEditing
import QuartzCore

/// An opt-in, local native-workspace measurement. The normal application
/// never runs this probe. Inputs are generated in the requested output folder.
@MainActor
enum WorkspacePerformance {
  private static var active = false
  private static var stages: [String: [Double]] = [:]

  static func profile<T>(_ name: String, operation: () throws -> T) rethrows -> T {
    guard active else { return try operation() }
    let start = CACurrentMediaTime()
    defer { stages[name, default: []].append((CACurrentMediaTime() - start) * 1000) }
    return try operation()
  }

  struct Distribution: Codable {
    let count: Int
    let median: Double
    let p95: Double
    let p99: Double
    let maximum: Double

    init(_ values: [Double]) {
      let sorted = values.sorted()
      func percentile(_ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
      }
      count = sorted.count
      median = percentile(0.5)
      p95 = percentile(0.95)
      p99 = percentile(0.99)
      maximum = sorted.last ?? 0
    }
  }

  struct Frames: Codable {
    let phase: String
    let screenMaximumHz: Int
    let targetPeriodMs: Distribution
    let callbackIntervalMs: Distribution
    let synchronousWorkMs: Distribution
    let deliveredCallbacksHz: Double
    let firstCallbackMs: Double
    let missedBudgets: Int
    let visibleEveryCallback: Bool
    let scrollDistancePoints: Double
    let pagesSeen: [Int]
  }

  struct Scenario: Codable {
    let name: String
    let pageCount: Int
    let fields: Int
    let comments: Int
    let openMs: Double
    let actionMs: Double?
    let actionVerified: Bool
    let actionStagesMs: [String: Distribution]
    let frames: [Frames]
  }

  static func run(output: URL) async {
    active = true
    let watchdog = DiagnosticWatchdog.schedule(
      after: 60, message: "Native workspace measurement timed out")
    defer { watchdog.cancel() }
    do {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      SPDFDocument.recoveryDirectoryOverride = output.appendingPathComponent("Recovery")
      let inputs = output.appendingPathComponent("Inputs")
      try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
      var scenarios: [Scenario] = []
      for kind in ["pages", "forms", "comments"] {
        let graph = try input(kind: kind)
        let url = inputs.appendingPathComponent("\(kind).pdf")
        try PDFWriter.write(graph).write(to: url, options: .atomic)
        scenarios.append(try await measure(kind: kind, url: url))
      }
      struct Report: Codable {
        let measuredAt: Date
        let os: String
        let methodology: String
        let scenarios: [Scenario]
      }
      let report = Report(
        measuredAt: Date(), os: ProcessInfo.processInfo.operatingSystemVersionString,
        methodology: "Visible native windows; display-linked scrolling and synchronous AppKit layout/draw. Callback timing is not a GPU-presented-frame count. Inputs are synthetic; screen cadence may be virtual.",
        scenarios: scenarios)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(report).write(
        to: output.appendingPathComponent("workspace-performance.json"), options: .atomic)
      print("Native workspace measurement completed")
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("Native workspace measurement failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func measure(kind: String, url: URL) async throws -> Scenario {
    let start = CACurrentMediaTime()
    let (opened, _) = try await NSDocumentController.shared.openDocument(
      withContentsOf: url, display: true)
    guard let document = opened as? SPDFDocument, let viewer = document.viewer,
      let window = document.windowControllers.first?.window, let content = window.contentView
    else { throw PDFError(.malformed, "The measurement document has no native window") }
    defer { document.close() }
    let openMs = (CACurrentMediaTime() - start) * 1000
    let baseline = try document.data(ofType: "com.adobe.pdf")
    window.setFrame(NSRect(x: 100, y: 100, width: 1080, height: 780), display: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Command-line launches may remain behind the active app on macOS. This
    // opt-in probe requires a genuinely exposed window, including in a VM.
    window.orderFrontRegardless()
    let sampler = DisplaySampler(window: window, viewer: viewer)
    // Activation and first-window layout occur on subsequent run-loop turns.
    // Keep this settling interval separate from the visible idle baseline.
    _ = await sampler.sample(phase: "settling", seconds: 0.5)
    var frames = [await sampler.sample(phase: "idle", seconds: 1)]
    var actionMs: Double?
    var actionVerified = true
    var actionStages: [String: Distribution] = [:]
    stages = [:]
    if kind == "pages" {
      guard let scroll = scrollViews(in: viewer.view).first,
        let pageContent = scroll.documentView,
        pageContent.frame.height > scroll.contentView.bounds.height * 2
      else { throw PDFError(.malformed, "The page measurement has no scrollable native content") }
      sampler.trackedScrollView = scroll
      let initial = scroll.contentView.bounds.origin
      for pass in ["first-scroll", "repeat-scroll"] {
        scroll.contentView.scroll(to: initial)
        scroll.reflectScrolledClipView(scroll.contentView)
        var direction: CGFloat = initial.y > pageContent.frame.height / 2 ? -1 : 1
        frames.append(await sampler.sample(phase: pass, seconds: 4) { interval, _ in
          let clip = scroll.contentView
          let limit = max(0, pageContent.frame.height - clip.bounds.height)
          let y = min(limit, max(0, clip.bounds.origin.y + direction * 1600 * interval))
          if y <= 0 { direction = 1 }
          if y >= limit { direction = -1 }
          clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
          scroll.reflectScrolledClipView(clip)
        })
      }
      try JSONEncoder().encode(frames).write(
        to: url.deletingLastPathComponent().appendingPathComponent("pages-frames.json"))
      guard frames.dropFirst().allSatisfy({ $0.scrollDistancePoints > 500 && $0.pagesSeen.count > 1 })
      else { throw PDFError(.malformed, "The scroll measurement did not traverse multiple pages") }
    } else {
      if kind == "forms" { viewer.showForms() } else { viewer.showComments() }
      frames.append(await sampler.sample(phase: "sidebar-open", seconds: 1))
      guard document.formsModel.fields.count == (kind == "forms" ? 200 : 0),
        document.commentsModel.comments.count == (kind == "comments" ? 1000 : 0),
        let sidebar = scrollViews(in: content).first(where: {
          $0.frame.width < 400 && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height
        })
      else { throw PDFError(.malformed, "The many-element sidebar did not populate or scroll") }
      sampler.trackedScrollView = sidebar
      var edited = false
      var direction: CGFloat = 1
      frames.append(await sampler.sample(phase: "sidebar-scroll-and-edit", seconds: 3) { interval, tick in
        let clip = sidebar.contentView
        let limit = max(0, (sidebar.documentView?.frame.height ?? 0) - clip.bounds.height)
        let y = min(limit, max(0, clip.bounds.origin.y + direction * 1200 * interval))
        if y <= 0 { direction = 1 }
        if y >= limit { direction = -1 }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sidebar.reflectScrolledClipView(clip)
        if tick >= 30 && !edited {
          edited = true
          // Commit from a separate event-loop turn, like a field/menu action,
          // instead of reentering NSTableView while its scroll is being laid out.
          DispatchQueue.main.async {
            let actionStart = CACurrentMediaTime()
            if kind == "forms" {
              document.fillFormText(fieldName: "field10", text: "Measured value")
            } else if document.commentsModel.comments.count > 20 {
              document.setState(PDFName("Completed"), on: document.commentsModel.comments[20])
            }
            actionMs = (CACurrentMediaTime() - actionStart) * 1000
          }
        }
      })
      actionVerified = edited && document.editSession.isDirty
      actionStages = stages.mapValues { Distribution($0) }
      if kind == "forms" {
        actionVerified = actionVerified && document.formsModel.fields.contains(where: {
          $0.name == "field10" && $0.stringValue == "Measured value"
        })
      } else {
        actionVerified = actionVerified && document.commentsModel.comments.contains(where: {
          $0.reviewState == PDFName("Completed")
        })
      }
      guard actionVerified, document.undoEdit(),
        try document.data(ofType: "com.adobe.pdf") == baseline
      else { throw PDFError(.malformed, "The measured edit or its Undo did not preserve the document") }
      document.discardRecoveryRecords()
    }
    guard frames.allSatisfy({ $0.callbackIntervalMs.count >= 30 && $0.visibleEveryCallback })
    else { throw PDFError(.malformed, "The display probe did not obtain 30 visible callback intervals") }
    return Scenario(
      name: kind, pageCount: viewer.pageCount, fields: document.formsModel.fields.count,
      comments: document.commentsModel.comments.count, openMs: openMs,
      actionMs: actionMs, actionVerified: actionVerified,
      actionStagesMs: actionStages, frames: frames)
  }

  private static func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }

  private static func input(kind: String) throws -> PDFGraph {
    let count = kind == "pages" ? 50 : 10
    var objects: [PDFObjectID: PDFValue] = [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Font")),
        PDFName("Subtype"): .name(PDFName("Type1")),
        PDFName("BaseFont"): .name(PDFName("Helvetica")),
      ]),
    ]
    let pages = (0..<count).map { PDFObjectID(10 + $0 * 2) }
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")), PDFName("Count"): .integer(Int64(count)),
      PDFName("Kids"): .array(pages.map { .reference($0) }),
    ])
    for (index, id) in pages.enumerated() {
      let content = PDFObjectID(id.number + 1)
      var text = "BT /F1 18 Tf 70 740 Td (Measurement page \(index + 1)) Tj ET\n"
      for line in 0..<(kind == "pages" ? 40 : 3) {
        text += "BT /F1 11 Tf 70 \(700 - line * 14) Td (Native scroll measurement line \(line) alpha beta gamma) Tj ET\n"
      }
      objects[content] = .stream(PDFStream(bytes: Data(text.utf8)))
      objects[id] = .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([0, 0, 612, 792].map { .integer(Int64($0)) }),
        PDFName("Resources"): .dictionary([
          PDFName("Font"): .dictionary([PDFName("F1"): .reference(PDFObjectID(3))])
        ]), PDFName("Contents"): .reference(content),
      ])
    }
    var graph = PDFGraph(objects: objects, trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    if kind == "forms" {
      for index in 0..<200 {
        graph = try PDFEditingEngine.commit(PDFTransaction([
          AddTextFieldCommand(
            pageID: pages[index / 20],
            rect: [70, Double(590 - (index % 20) * 25), 350, Double(610 - (index % 20) * 25)],
            name: "field\(index)")
        ]), to: graph)
      }
    } else if kind == "comments" {
      for (pageIndex, pageID) in pages.enumerated() {
        var refs: [PDFValue] = []
        for index in 0..<100 {
          let id = PDFObjectID(1000 + pageIndex * 100 + index)
          graph.objects[id] = .dictionary([
            PDFName("Type"): .name(PDFName("Annot")), PDFName("Subtype"): .name(PDFName("Text")),
            PDFName("Rect"): .array([20, 20, 40, 40].map { .integer(Int64($0)) }),
            PDFName("Contents"): .string(Data("Measurement comment \(pageIndex)-\(index)".utf8)),
          ])
          refs.append(.reference(id))
        }
        guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
        page[PDFName("Annots")] = .array(refs)
        graph.objects[pageID] = .dictionary(page)
      }
    }
    return graph
  }
}

@MainActor
private final class DisplaySampler: NSObject {
  let window: NSWindow
  let viewer: PDFViewingSession
  var trackedScrollView: NSScrollView?
  private var link: CADisplayLink?
  private var continuation: CheckedContinuation<WorkspacePerformance.Frames, Never>?
  private var work: ((CGFloat, Int) -> Void)?
  private var phase = ""
  private var start = 0.0
  private var seconds = 0.0
  private var firstTime = 0.0
  private var lastTime = 0.0
  private var intervals: [Double] = []
  private var periods: [Double] = []
  private var workTimes: [Double] = []
  private var missed = 0
  private var visible = true
  private var pages: Set<Int> = []
  private var distance = 0.0
  private var previousOrigin: CGPoint?

  init(window: NSWindow, viewer: PDFViewingSession) {
    self.window = window
    self.viewer = viewer
  }

  func sample(phase: String, seconds: Double, work: ((CGFloat, Int) -> Void)? = nil)
    async -> WorkspacePerformance.Frames
  {
    self.phase = phase
    self.seconds = seconds
    self.work = work
    intervals = []; periods = []; workTimes = []; pages = []
    firstTime = 0; lastTime = 0; missed = 0; visible = true; distance = 0; previousOrigin = nil
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      start = CACurrentMediaTime()
      let link = window.displayLink(target: self, selector: #selector(tick(_:)))
      let rate = Float(window.screen?.maximumFramesPerSecond ?? 60)
      link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
      self.link = link
      link.add(to: .main, forMode: .common)
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    let period = max(0.001, link.targetTimestamp - link.timestamp)
    periods.append(period * 1000)
    if firstTime == 0 { firstTime = now }
    let interval = lastTime == 0 ? period : now - lastTime
    if lastTime != 0 {
      intervals.append(interval * 1000)
      if interval > period * 1.5 { missed += 1 }
    }
    lastTime = now
    visible = visible && window.occlusionState.contains(.visible)
    // Programmatic clip scrolling does not update PDFKit's navigation history.
    // Measure the page actually visible in the viewport, not that history.
    let center = CGPoint(x: viewer.view.bounds.midX, y: viewer.view.bounds.midY)
    if let page = viewer.view.page(for: center, nearest: true), let document = viewer.view.document {
      pages.insert(document.index(for: page) + 1)
    }
    let workStart = CACurrentMediaTime()
    work?(CGFloat(min(interval, 0.1)), workTimes.count)
    window.contentView?.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()
    workTimes.append((CACurrentMediaTime() - workStart) * 1000)
    if let scroll = trackedScrollView {
      let origin = scroll.contentView.bounds.origin
      if let previousOrigin { distance += abs(origin.y - previousOrigin.y) }
      previousOrigin = origin
    }
    guard now - start >= seconds else { return }
    link.invalidate()
    self.link = nil
    let result = WorkspacePerformance.Frames(
      phase: phase, screenMaximumHz: window.screen?.maximumFramesPerSecond ?? 0,
      targetPeriodMs: .init(periods), callbackIntervalMs: .init(intervals),
      synchronousWorkMs: .init(workTimes),
      deliveredCallbacksHz: Double(intervals.count) / max(0.001, lastTime - firstTime),
      firstCallbackMs: (firstTime - start) * 1000, missedBudgets: missed,
      visibleEveryCallback: visible, scrollDistancePoints: distance, pagesSeen: pages.sorted())
    let completion = continuation
    continuation = nil
    work = nil
    completion?.resume(returning: result)
  }
}
