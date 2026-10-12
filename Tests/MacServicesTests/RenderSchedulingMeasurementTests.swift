import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import Testing

/// A renderer that blocks inside the render until released, recording entry
/// order so scheduling priority is observable.
private actor SchedulingGate {
  private var entered: [String] = []
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func enter(_ id: String) async {
    entered.append(id)
    if !released {
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func entryCount() -> Int { entered.count }
  func order() -> [String] { entered }
}

private func schedulingTinyImage() -> CGImage {
  let context = CGContext(
    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 0, green: 0, blue: 0.5, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
  return context.makeImage()!
}

private func schedulingWait(
  timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(nanoseconds: 2_000_000)
  }
  return false
}

@Suite("Render scheduling measurements")
struct RenderSchedulingMeasurementTests {
  private func widths(in graph: PDFGraph) throws -> [PageRenderGeometry] {
    try PageRenderGeometry.geometries(in: graph)
  }

  private func tag(_ geometries: [PageRenderGeometry], page: Int, scale: Double) -> String {
    let size = geometries[page].pixelSize(scale: scale, maxPixels: 16_777_216)
    return "p\(page)-w\(size.width)"
  }
  // MARK: - P39-005 thumbnail scheduling and visible-page prioritization

  @Test func visiblePageWinsOverQueuedThumbnails() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let gate = SchedulingGate()
    let service = PageRenderService(
      maxConcurrentRenders: 1,
      renderer: { _, pageIndex, pixelWidth, _, _, _ in
        await gate.enter("p\(pageIndex)-w\(pixelWidth)")
        return PageBitmap(image: schedulingTinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    // Occupy the single slot with a gated render.
    let occupant = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.2))
    }
    _ = await schedulingWait { await gate.entryCount() == 1 }
    // Queue background thumbnails, then an interactive visible request.
    let start = ContinuousClock.now
    let thumbnails = Task {
      await withTaskGroup(of: Void.self) { group in
        for page in [1, 2] {
          group.addTask {
            _ = try? await service.render(
              PageRenderRequest(
                documentID: id, revision: 1, pageIndex: page, scale: 0.2,
                purpose: .thumbnail))
          }
        }
      }
    }
    // Let both thumbnails reach the queue before the visible request.
    _ = await schedulingWait { await service.pendingRenderCount() >= 3 }
    let visibleStart = ContinuousClock.now
    let visible = Task {
      try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: 1, scale: 0.5,
          purpose: .visible))
    }
    _ = await schedulingWait { await service.pendingRenderCount() >= 4 }
    await gate.release()
    let visibleResult = try await visible.value
    await thumbnails.value
    _ = try await occupant.value
    let end = ContinuousClock.now
    let visibleLatency = (visibleStart.duration(to: end) as Duration).formatted
    let totalLatency = (start.duration(to: end) as Duration).formatted
    let order = await gate.order()
    print(
      "[P39] prioritized schedule: visible \(visibleLatency) after release, "
        + "full drain \(totalLatency); entry order \(order)")
    // The visible request entered the renderer before every queued
    // thumbnail even though it arrived last (widths disambiguate the
    // visible page-1 render at scale 0.5 from its thumbnail at 0.2).
    let geometries = try widths(in: graph)
    #expect(order.count == 4)
    #expect(order[0] == tag(geometries, page: 0, scale: 0.2))
    #expect(order[1] == tag(geometries, page: 1, scale: 0.5))
    #expect(order[2] == tag(geometries, page: 1, scale: 0.2))
    #expect(order[3] == tag(geometries, page: 2, scale: 0.2))
    #expect(visibleResult.request.purpose == .visible)
  }

  // MARK: - P39-007 rapid zoom with bounded cache growth

  @Test func rapidZoomKeepsCacheWithinBudget() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let budget = 8 << 20
    let service = PageRenderService(cacheByteBudget: budget)
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let scales = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 0.5, 1.0, 2.0, 4.0, 1.25, 2.5]
    let start = ContinuousClock.now
    try await withThrowingTaskGroup(of: PageRenderResult.self) { group in
      for scale in scales {
        group.addTask {
          try await service.render(
            PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: scale))
        }
      }
      var served = 0
      for try await result in group {
        #expect(result.request.revision == 1)
        served += 1
      }
      #expect(served == scales.count)
    }
    let elapsed = (start.duration(to: ContinuousClock.now) as Duration).formatted
    let stats = await service.cacheStatistics()
    print(
      "[P39] rapid zoom: \(scales.count) renders in \(elapsed), "
        + "cache \(stats.bytes / 1024) KiB in \(stats.entries) entries")
    #expect(stats.bytes <= budget)
  }

  // MARK: - P39-022 fairness: background jobs do not starve interactive work

  @Test func backgroundExportsYieldToInteractiveRenders() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let gate = SchedulingGate()
    let service = PageRenderService(
      maxConcurrentRenders: 1,
      renderer: { _, pageIndex, pixelWidth, _, _, _ in
        await gate.enter("p\(pageIndex)-w\(pixelWidth)")
        return PageBitmap(image: schedulingTinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let occupant = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.2))
    }
    _ = await schedulingWait { await gate.entryCount() == 1 }
    // Background batch work queues first; the interactive request arrives
    // last and must still run first. Everything drains afterwards.
    let batch = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try? await service.render(
            PageRenderRequest(
              documentID: id, revision: 1, pageIndex: 1, scale: 0.5,
              purpose: .export))
        }
        group.addTask {
          _ = try? await service.render(
            PageRenderRequest(
              documentID: id, revision: 1, pageIndex: 2, scale: 0.5,
              purpose: .print))
        }
      }
    }
    _ = await schedulingWait { await service.pendingRenderCount() >= 3 }
    let interactive = Task {
      try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: 2, scale: 1.0,
          purpose: .visible))
    }
    _ = await schedulingWait { await service.pendingRenderCount() >= 4 }
    await gate.release()
    _ = try await interactive.value
    await batch.value
    _ = try await occupant.value
    let order = await gate.order()
    print("[P39] fairness entry order \(order)")
    // Occupant first, then the interactive render, then the background
    // batch in arrival order: interactive work never waits behind batch.
    let geometries = try widths(in: graph)
    #expect(
      order == [
        tag(geometries, page: 0, scale: 0.2), tag(geometries, page: 2, scale: 1.0),
        tag(geometries, page: 1, scale: 0.5), tag(geometries, page: 2, scale: 0.5),
      ])
  }

  // MARK: - P39-020 workers do not retain closed document sessions

  @Test func closingADocumentDropsItsWorkersAndBitmaps() async throws {
    let latch = SchedulingGate()
    let service = PageRenderService(
      renderer: { _, _, _, _, _, _ in
        await latch.enter("render")
        return PageBitmap(image: schedulingTinyImage())
      })
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let inFlight = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
    }
    _ = await schedulingWait { await latch.entryCount() == 1 }
    // Closing cancels the worker and drops every cached bitmap.
    await service.removeSnapshot(documentID: id)
    await latch.release()
    do {
      _ = try await inFlight.value
      #expect(Bool(false), "a closed document's render must not complete")
    } catch is CancellationError {
    } catch let error as PageRenderError {
      #expect(error == .staleRevision(expected: 1, current: -1))
    }
    let stats = await service.cacheStatistics()
    #expect(stats.entries == 0 && stats.bytes == 0)
    #expect(await service.pendingRenderCount() == 0)
    do {
      _ = try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
      #expect(Bool(false), "a closed document must not render")
    } catch let error as PageRenderError {
      #expect(error == .noSnapshot)
    }

    // Job bookkeeping drains the same way: cancel runs, finish drops.
    let center = JobProgressCenter()
    let job = center.start(title: "Export", total: 8)
    var cancelled = false
    center.attach(id: job) { cancelled = true }
    #expect(center.requestCancel(id: job) == true)
    #expect(cancelled)
    center.finish(id: job)
    #expect(center.jobs.isEmpty)
  }
}

extension Duration {
  fileprivate var formatted: String {
    let seconds = Double(components.seconds)
      + Double(components.attoseconds) / 1e18
    if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
    return String(format: "%.2f s", seconds)
  }
}
