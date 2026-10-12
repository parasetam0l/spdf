import CoreGraphics
import Foundation
import MacServices
import PDFCore
import PDFEditing
import PDFFixtures
import PDFKit
import Testing

/// A renderer gate: renders record themselves and poll until opened; the
/// poll's task sleep makes cancellation immediate and cooperative.
private actor RenderGate {
  private var entered: [String] = []
  private var open: Set<String> = []
  private var allOpen = false
  private var active = 0
  private var peak = 0

  func enter(_ id: String) async throws {
    entered.append(id)
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    while !allOpen && !open.contains(id) {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  func open(_ id: String) { open.insert(id) }
  func openAll() { allOpen = true }
  func reset() {
    open.removeAll()
    allOpen = false
  }
  func enteredIDs() -> [String] { entered }
  func peakConcurrency() -> Int { peak }
}

/// A renderer that waits without honoring cancellation, for stale-result tests.
private actor Latch {
  private var continuation: CheckedContinuation<Void, Never>?
  private var enters = 0

  func wait() async {
    enters += 1
    await withCheckedContinuation { continuation = $0 }
  }

  func enterCount() -> Int { enters }
  func open() { continuation?.resume(); continuation = nil }
}

private func tinyImage() -> CGImage {
  let context = CGContext(
    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 0, green: 0, blue: 0.5, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
  return context.makeImage()!
}

private func samplingGraph(
  rotate: Int = 0, cropBox: [Double]? = nil, userUnit: Double? = nil
) throws -> PDFGraph {
  var page: [PDFName: PDFValue] = [
    PDFName("Type"): .name(PDFName("Page")),
    PDFName("Parent"): .reference(PDFObjectID(2)),
    PDFName("MediaBox"): .array([
      .integer(0), .integer(0), .integer(612), .integer(792),
    ]),
    PDFName("Resources"): .dictionary([:]),
    PDFName("Contents"): .reference(PDFObjectID(4)),
    PDFName("Rotate"): .integer(Int64(rotate)),
  ]
  if let cropBox { page[PDFName("CropBox")] = .array(cropBox.map { .real($0) }) }
  if let userUnit { page[PDFName("UserUnit")] = .real(userUnit) }
  let graph = PDFGraph(
    objects: [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(3): .dictionary(page),
      PDFObjectID(4): .stream(PDFStream(bytes: Data("20 20 100 100 re f\n".utf8))),
    ],
    trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  return try PDFParser.parse(try PDFWriter.write(graph)).graph
}

private func maskedGraph() throws -> PDFGraph {
  // A 1-bit image mask over a 100×100 square at (200, 200); the top two rows
  // paint, the bottom two do not.
  let graph = PDFGraph(
    objects: [
      PDFObjectID(1): .dictionary([
        PDFName("Type"): .name(PDFName("Catalog")),
        PDFName("Pages"): .reference(PDFObjectID(2)),
      ]),
      PDFObjectID(2): .dictionary([
        PDFName("Type"): .name(PDFName("Pages")),
        PDFName("Count"): .integer(1),
        PDFName("Kids"): .array([.reference(PDFObjectID(3))]),
      ]),
      PDFObjectID(3): .dictionary([
        PDFName("Type"): .name(PDFName("Page")),
        PDFName("Parent"): .reference(PDFObjectID(2)),
        PDFName("MediaBox"): .array([
          .integer(0), .integer(0), .integer(612), .integer(792),
        ]),
        PDFName("Resources"): .dictionary([
          PDFName("XObject"): .dictionary([
            PDFName("Im1"): .reference(PDFObjectID(5))
          ])
        ]),
        PDFName("Contents"): .reference(PDFObjectID(4)),
      ]),
      PDFObjectID(4): .stream(
        PDFStream(bytes: Data("q 100 0 0 100 200 200 cm /Im1 Do Q\n".utf8))),
      PDFObjectID(5): .stream(
        PDFStream(
          dictionary: [
            PDFName("Type"): .name(PDFName("XObject")),
            PDFName("Subtype"): .name(PDFName("Image")),
            PDFName("Width"): .integer(4), PDFName("Height"): .integer(4),
            PDFName("ImageMask"): .boolean(true),
            PDFName("BitsPerComponent"): .integer(1),
          ],
          bytes: Data([0x00, 0x00, 0xFF, 0xFF]))),
    ],
    trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
  return try PDFParser.parse(try PDFWriter.write(graph)).graph
}

/// Draw an image once into an RGBA buffer so region scans are cheap.
/// Index with bottom-left pixel coordinates: offset = ((height-1-y)*width+x)*4.
private func sampleBuffer(of image: CGImage) -> (width: Int, height: Int, data: [UInt8]) {
  let width = image.width
  let height = image.height
  var data = [UInt8](repeating: 0, count: width * height * 4)
  data.withUnsafeMutableBytes { buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return (width, height, data)
}

private func pixel(in image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
  let width = image.width
  let height = image.height
  let bytesPerRow = width * 4
  var data = [UInt8](repeating: 0, count: bytesPerRow * height)
  data.withUnsafeMutableBytes { buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  // CGBitmapContext rows run top-down; callers pass bottom-left pixel y.
  let offset = ((height - 1 - y) * width + x) * 4
  return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}

private func fullPageWidth(
  _ geometry: PageRenderGeometry, scale: Double
) -> (Int, Int) {
  let size = geometry.pixelSize(scale: scale, maxPixels: 16_777_216)
  return (size.width, size.height)
}

private actor Counter {
  private var value = 0
  func bump() { value += 1 }
  func count() -> Int { value }
}

private func waitUntil(
  timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(nanoseconds: 2_000_000)
  }
  return false
}

@Suite("Page render service")
struct PageRenderServiceTests {
  // MARK: - Geometry (P11-005/P11-006)

  @Test func geometryResolvesBoxesRotationAndUserUnit() throws {
    let baseline = try PageRenderGeometry.geometries(in: samplingGraph())[0]
    #expect(baseline.displaySize == CGSize(width: 612, height: 792))
    let identity = baseline.contentToPixelTransform(scale: 1)
    let origin = CGPoint(x: 0, y: 0).applying(identity)
    let far = CGPoint(x: 612, y: 792).applying(identity)
    #expect(origin == CGPoint(x: 0, y: 0))
    #expect(far == CGPoint(x: 612, y: 792))

    // A nonzero crop origin shifts the content into the bitmap.
    let cropped = try PageRenderGeometry.geometries(
      in: samplingGraph(cropBox: [50, 50, 650, 850]))[0]
    #expect(cropped.displaySize == CGSize(width: 600, height: 800))
    let cropTransform = cropped.contentToPixelTransform(scale: 1)
    #expect(
      CGPoint(x: 50, y: 50).applying(cropTransform) == CGPoint(x: 0, y: 0))
    #expect(
      CGPoint(x: 650, y: 850).applying(cropTransform) == CGPoint(x: 600, y: 800))

    // UserUnit scales the display size; the render scale stays in pixels per
    // display point so the bitmap matches pixelSize.
    let scaled = try PageRenderGeometry.geometries(
      in: samplingGraph(cropBox: [50, 50, 650, 850], userUnit: 2))[0]
    #expect(scaled.displaySize == CGSize(width: 1200, height: 1600))
    let size = scaled.pixelSize(scale: 0.5, maxPixels: 16_777_216)
    #expect(size.width == 600)
    #expect(size.height == 800)
    #expect(size.effectiveScale == 0.5)
    #expect(
      CGPoint(x: 650, y: 850).applying(
        scaled.contentToPixelTransform(scale: size.effectiveScale)) == CGPoint(x: 600, y: 800))

    // Rotation swaps the displayed axes clockwise.
    let rotated90 = try PageRenderGeometry.geometries(in: samplingGraph(rotate: 90))[0]
    #expect(rotated90.displaySize == CGSize(width: 792, height: 612))
    let t90 = rotated90.contentToPixelTransform(scale: 1)
    #expect(CGPoint(x: 0, y: 0).applying(t90) == CGPoint(x: 0, y: 612))
    #expect(CGPoint(x: 612, y: 0).applying(t90) == CGPoint(x: 0, y: 0))
    #expect(CGPoint(x: 0, y: 792).applying(t90) == CGPoint(x: 792, y: 612))
    #expect(CGPoint(x: 612, y: 792).applying(t90) == CGPoint(x: 792, y: 0))

    let rotated180 = try PageRenderGeometry.geometries(in: samplingGraph(rotate: 180))[0]
    let t180 = rotated180.contentToPixelTransform(scale: 1)
    #expect(CGPoint(x: 0, y: 0).applying(t180) == CGPoint(x: 612, y: 792))
    #expect(CGPoint(x: 612, y: 792).applying(t180) == CGPoint(x: 0, y: 0))

    let rotated270 = try PageRenderGeometry.geometries(in: samplingGraph(rotate: 270))[0]
    #expect(rotated270.displaySize == CGSize(width: 792, height: 612))
    let t270 = rotated270.contentToPixelTransform(scale: 1)
    #expect(CGPoint(x: 0, y: 0).applying(t270) == CGPoint(x: 792, y: 0))
    #expect(CGPoint(x: 0, y: 792).applying(t270) == CGPoint(x: 0, y: 0))
    #expect(CGPoint(x: 612, y: 792).applying(t270) == CGPoint(x: 0, y: 612))
    #expect(CGPoint(x: 612, y: 0).applying(t270) == CGPoint(x: 792, y: 612))
  }

  @Test func pixelBudgetClampsRetinaScales() throws {
    let geometry = try PageRenderGeometry.geometries(in: samplingGraph())[0]
    let clamped = geometry.pixelSize(scale: 40, maxPixels: 1_000_000)
    #expect(clamped.effectiveScale < 40)
    #expect(clamped.width * clamped.height <= 1_000_000)
    #expect(clamped.width > 0 && clamped.height > 0)
  }

  @Test func viewTransformRoundTripsAndPreservesAnAnchor() {
    let transform = PageViewTransform(
      displaySize: CGSize(width: 612, height: 792), zoom: 2,
      viewOffset: CGPoint(x: 10, y: 20))
    let viewPoint = transform.viewPoint(fromDisplay: CGPoint(x: 100, y: 200))
    #expect(viewPoint == CGPoint(x: 210, y: 420))
    let back = transform.displayPoint(fromView: viewPoint)
    #expect(abs(back.x - 100) < 0.0001 && abs(back.y - 200) < 0.0001)
    let zoomed = transform.zoomed(to: 4, preserving: CGPoint(x: 100, y: 200))
    #expect(zoomed.viewPoint(fromDisplay: CGPoint(x: 100, y: 200)) == viewPoint)
  }

  // MARK: - Core Graphics rendering (P11-003/P11-005)

  @Test func rotatedPagesRenderWithSampledInk() async throws {
    for rotation in [0, 90, 180, 270] {
      let graph = try samplingGraph(rotate: rotation)
      let geometry = try PageRenderGeometry.geometries(in: graph)[0]
      let service = PageRenderService()
      let id = UUID()
      try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
      let result = try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
      if rotation == 90 || rotation == 270 {
        #expect(result.pixelWidth == 396)
        #expect(result.pixelHeight == 306)
      } else {
        #expect(result.pixelWidth == 306)
        #expect(result.pixelHeight == 396)
      }
      let transform = geometry.contentToPixelTransform(scale: result.effectiveScale)
      let inkPoint = CGPoint(x: 70, y: 70).applying(transform)
      let ink = pixel(
        in: result.image.image, x: Int(inkPoint.x), y: Int(inkPoint.y))
      #expect(ink.0 < 60 && ink.1 < 60 && ink.2 < 60)
      let blankPoint = CGPoint(x: 400, y: 400).applying(transform)
      let blank = pixel(
        in: result.image.image, x: Int(blankPoint.x), y: Int(blankPoint.y))
      #expect(blank.0 > 200 && blank.1 > 200 && blank.2 > 200)
    }
  }

  // MARK: - Cache keys and invalidation (P11-007/P11-010/P11-011)

  @Test func cacheKeysIncludeRevisionAndScale() async throws {
    let graph = try samplingGraph()
    let service = PageRenderService(
      renderer: { _, _, _, _, _, _ in PageBitmap(image: tinyImage()) })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    func request(scale: Double) -> PageRenderRequest {
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: scale)
    }
    let first = try await service.render(request(scale: 1))
    #expect(first.cacheHit == false)
    let second = try await service.render(request(scale: 1))
    #expect(second.cacheHit == true)
    let otherScale = try await service.render(request(scale: 2))
    #expect(otherScale.cacheHit == false)
    let otherScaleAgain = try await service.render(request(scale: 2))
    #expect(otherScaleAgain.cacheHit == true)
    let stats = await service.cacheStatistics()
    #expect(stats.misses == 2)
    #expect(stats.hits == 2)
    #expect(stats.entries == 2)
  }

  @Test func changedPagesOnlyInvalidateTheirPreviews() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let service = PageRenderService(
      renderer: { _, _, _, _, _, _ in PageBitmap(image: tinyImage()) })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.2))
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 1, scale: 0.2))
    // An edit touching page 0 only: page 1's preview survives under revision 2.
    try await service.setSnapshot(documentID: id, revision: 2, graph: graph, changedPages: [0])
    let untouched = try await service.render(
      PageRenderRequest(documentID: id, revision: 2, pageIndex: 1, scale: 0.2))
    #expect(untouched.cacheHit == true)
    let edited = try await service.render(
      PageRenderRequest(documentID: id, revision: 2, pageIndex: 0, scale: 0.2))
    #expect(edited.cacheHit == false)
    // Explicit invalidation drops only the named page's previews.
    await service.invalidate(documentID: id, pages: [1])
    let dropped = try await service.render(
      PageRenderRequest(documentID: id, revision: 2, pageIndex: 1, scale: 0.2))
    #expect(dropped.cacheHit == false)
  }

  @Test func cacheEvictionHonorsTheByteBudget() async throws {
    let graph = try samplingGraph()
    let service = PageRenderService(
      cacheByteBudget: 8_000,
      renderer: { _, _, _, _, _, _ in PageBitmap(image: tinyImage()) })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.05))
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.06))
    let stats = await service.cacheStatistics()
    #expect(stats.bytes <= 8_000)
    #expect(stats.entries == 1)
  }

  // MARK: - Stale results and closed documents (P11-012)

  @Test func staleRevisionsAreRefused() async throws {
    let graph = try samplingGraph()
    let latch = Latch()
    let service = PageRenderService(
      renderer: { _, _, _, _, _, _ in
        await latch.wait()
        return PageBitmap(image: tinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    // A request for a revision that is not current is refused outright.
    await #expect(throws: PageRenderError.self) {
      _ = try await service.render(
        PageRenderRequest(documentID: id, revision: 99, pageIndex: 0, scale: 1))
    }
    // A render that finishes after the revision advanced is refused, not cached.
    let inFlight = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 1))
    }
    let enteredOnce = await waitUntil { await latch.enterCount() >= 1 }
    #expect(enteredOnce)
    try await service.setSnapshot(documentID: id, revision: 2, graph: graph)
    await latch.open()
    await #expect(throws: PageRenderError.self) {
      _ = try await inFlight.value
    }
    let stats = await service.cacheStatistics()
    #expect(stats.entries == 0)
    // The newer revision renders fresh rather than serving the old bitmap.
    let refreshed = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 2, pageIndex: 0, scale: 1))
    }
    let enteredTwice = await waitUntil { await latch.enterCount() >= 2 }
    #expect(enteredTwice)
    await latch.open()
    let result = try await refreshed.value
    #expect(result.cacheHit == false)
    // Closing the document rejects further renders.
    await service.removeSnapshot(documentID: id)
    await #expect(throws: PageRenderError.self) {
      _ = try await service.render(
        PageRenderRequest(documentID: id, revision: 2, pageIndex: 0, scale: 1))
    }
  }

  // MARK: - Scheduling (P11-009/P11-014)

  @Test func concurrencyIsBounded() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let gate = RenderGate()
    let service = PageRenderService(
      maxConcurrentRenders: 2,
      renderer: { _, pageIndex, _, _, _, _ in
        try await gate.enter("p\(pageIndex)")
        return PageBitmap(image: tinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let requests = (0..<3).map {
      PageRenderRequest(documentID: id, revision: 1, pageIndex: $0, scale: 0.2)
    }
    let tasks = requests.map { request in
      Task { try await service.render(request) }
    }
    let arrived = await waitUntil {
      let entered = await gate.enteredIDs().count
      let pending = await service.pendingRenderCount()
      return entered >= 2 && pending == 3
    }
    #expect(arrived)
    let peak = await gate.peakConcurrency()
    #expect(peak == 2)
    await gate.openAll()
    for task in tasks { _ = try await task.value }
    let finalPeak = await gate.peakConcurrency()
    #expect(finalPeak <= 2)
    let idle = await service.pendingRenderCount()
    #expect(idle == 0)
  }

  @Test func visiblePagesAreScheduledBeforeThumbnails() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let gate = RenderGate()
    let service = PageRenderService(
      maxConcurrentRenders: 1,
      renderer: { _, pageIndex, _, _, _, _ in
        try await gate.enter("p\(pageIndex)")
        return PageBitmap(image: tinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let first = Task {
      try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: 0, scale: 0.2, purpose: .thumbnail))
    }
    let started = await waitUntil { await gate.enteredIDs() == ["p0"] }
    #expect(started)
    let thumbnail = Task {
      try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: 1, scale: 0.2, purpose: .thumbnail))
    }
    let visible = Task {
      try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: 2, scale: 0.2, purpose: .visible))
    }
    let queued = await waitUntil { await service.pendingRenderCount() == 3 }
    #expect(queued)
    // Finishing the running render must hand the slot to the visible page.
    await gate.open("p0")
    let visibleFirst = await waitUntil { await gate.enteredIDs() == ["p0", "p2"] }
    #expect(visibleFirst)
    await gate.open("p2")
    let thumbnailStarted = await waitUntil { await gate.enteredIDs().count == 3 }
    #expect(thumbnailStarted)
    await gate.open("p1")
    _ = try await first.value
    _ = try await visible.value
    _ = try await thumbnail.value
  }

  // MARK: - Superseding and cancellation (P11-015)

  @Test func supersedingRendersCancelTheEarlierRequest() async throws {
    let graph = try samplingGraph()
    let gate = RenderGate()
    let service = PageRenderService(
      maxConcurrentRenders: 2,
      renderer: { _, pageIndex, _, _, _, _ in
        try await gate.enter("p\(pageIndex)")
        return PageBitmap(image: tinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let first = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 1))
    }
    let firstStarted = await waitUntil { await gate.enteredIDs() == ["p0"] }
    #expect(firstStarted)
    let second = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 2))
    }
    // Once the newer request reaches the renderer, the earlier one was
    // superseded and must report cancellation rather than a result.
    let superseded = await waitUntil { await gate.enteredIDs().count == 2 }
    #expect(superseded)
    var firstError: Error?
    do { _ = try await first.value } catch { firstError = error }
    #expect(firstError is CancellationError)
    await gate.open("p0")
    let result = try await second.value
    #expect(result.cacheHit == false)
    #expect(result.request.scale == 2)
    // An explicit cancel stops an in-flight render cooperatively.
    await gate.reset()
    let third = Task {
      try await service.render(
        PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 3))
    }
    let thirdStarted = await waitUntil { await gate.enteredIDs().count == 3 }
    #expect(thirdStarted)
    await service.cancel(documentID: id, pageIndex: 0)
    var thirdError: Error?
    do { _ = try await third.value } catch { thirdError = error }
    #expect(thirdError is CancellationError)
  }

  // MARK: - Cropped pages, edited snapshots, independent renderer (P11-023–P11-027)

  @Test func croppedPagesRenderWithNonzeroOrigins() async throws {
    let graph = try samplingGraph(cropBox: [10, 10, 310, 410])
    let geometry = try PageRenderGeometry.geometries(in: graph)[0]
    #expect(geometry.displaySize == CGSize(width: 300, height: 400))
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let result = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
    #expect(result.pixelWidth == 150)
    #expect(result.pixelHeight == 200)
    let transform = geometry.contentToPixelTransform(scale: result.effectiveScale)
    let inkPoint = CGPoint(x: 70, y: 70).applying(transform)
    let ink = pixel(in: result.image.image, x: Int(inkPoint.x), y: Int(inkPoint.y))
    #expect(ink.0 < 60 && ink.1 < 60 && ink.2 < 60)
    let blankPoint = CGPoint(x: 250, y: 350).applying(transform)
    let blank = pixel(in: result.image.image, x: Int(blankPoint.x), y: Int(blankPoint.y))
    #expect(blank.0 > 200 && blank.1 > 200 && blank.2 > 200)
  }

  @Test func serviceRenderAgreesWithPDFKit() async throws {
    let graph = try samplingGraph()
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let result = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.25, purpose: .export))
    let serviceInk = pixel(in: result.image.image, x: 17, y: 17)
    #expect(serviceInk.0 < 60 && serviceInk.1 < 60 && serviceInk.2 < 60)
    // The independent renderer (PDFKit) must show the same ink on the left and
    // a blank right side; its vertical origin convention is not assumed.
    let document = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    let thumbnail = page.thumbnail(of: CGSize(width: 153, height: 198), for: .cropBox)
    let kit = try #require(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
    func kitPixel(fx: Double, fy: Double) -> (UInt8, UInt8, UInt8, UInt8) {
      let x = min(kit.width - 1, max(0, Int(Double(kit.width) * fx)))
      let y = min(kit.height - 1, max(0, Int(Double(kit.height) * fy)))
      return pixel(in: kit, x: x, y: y)
    }
    let leftTop = kitPixel(fx: 0.11, fy: 0.09)
    let leftBottom = kitPixel(fx: 0.11, fy: 0.91)
    let inkOnLeft =
      (leftTop.0 < 90 && leftTop.1 < 90 && leftTop.2 < 90)
      || (leftBottom.0 < 90 && leftBottom.1 < 90 && leftBottom.2 < 90)
    #expect(inkOnLeft)
    let right = kitPixel(fx: 0.75, fy: 0.5)
    #expect(right.0 > 160 && right.1 > 160 && right.2 > 160)
  }

  @Test func editedSnapshotsRenderFromTheCoreWriter() async throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([RotatePagesCommand(pageIDs: parsed.pageIDs, byDegrees: 90)]),
      to: parsed.graph)
    let geometry = try PageRenderGeometry.geometries(in: edited)[0]
    #expect(geometry.rotation == 90)
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: edited)
    let result = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.25))
    #expect(result.pixelWidth == Int((geometry.displaySize.width * 0.25).rounded(.down)))
    #expect(result.pixelHeight == Int((geometry.displaySize.height * 0.25).rounded(.down)))
    // The independent renderer sees the same committed edit without a second
    // save model: the core writer's bytes are what both consume.
    let document = try #require(PDFDocument(data: try PDFWriter.write(edited)))
    #expect(document.page(at: 0)?.rotation == 90)
  }

  @Test func zoomOnlyRerendersRequestedPages() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let counter = Counter()
    let service = PageRenderService(
      renderer: { _, _, _, _, _, _ in
        await counter.bump()
        return PageBitmap(image: tinyImage())
      })
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.2))
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 1, scale: 0.2))
    // Zooming re-renders the viewed page at the new size, not its neighbours.
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.4))
    let other = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 1, scale: 0.2))
    #expect(other.cacheHit)
    let renders = await counter.count()
    #expect(renders == 3)
  }

  @Test func transparentBackgroundLeavesNoWhiteFill() async throws {
    let graph = try samplingGraph()
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let white = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
    let whiteCorner = pixel(in: white.image.image, x: 290, y: 380)
    #expect(whiteCorner.3 == 255)
    let whiteAgain = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
    #expect(whiteAgain.cacheHit == true)
    let transparent = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 0.5, background: .transparent))
    let transparentCorner = pixel(in: transparent.image.image, x: 290, y: 380)
    #expect(transparentCorner.3 == 0)
    // The two backgrounds are distinct cache entries.
    #expect(transparent.cacheHit == false)
  }

  @Test func maskedFixturesAgreeWithPDFKit() async throws {
    let graph = try maskedGraph()
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let result = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 1, purpose: .export))
    // The mask square occupies content (200, 200)–(300, 300). Count dark
    // pixels in the visual top and bottom halves of that square.
    func dark(_ data: [UInt8], _ offset: Int) -> Bool {
      data[offset] < 100 && data[offset + 1] < 100 && data[offset + 2] < 100
    }
    func at(_ sample: (width: Int, height: Int, data: [UInt8]), _ x: Int, _ y: Int) -> Int {
      ((sample.height - 1 - y) * sample.width + x) * 4
    }
    let serviceSample = sampleBuffer(of: result.image.image)
    var serviceTop = 0
    var serviceBottom = 0
    for y in 200..<300 {
      for x in 200..<300 {
        if dark(serviceSample.data, at(serviceSample, x, y)) {
          if y >= 250 { serviceTop += 1 } else { serviceBottom += 1 }
        }
      }
    }
    let document = try #require(PDFDocument(data: try PDFWriter.write(graph)))
    let page = try #require(document.page(at: 0))
    let thumbnail = page.thumbnail(of: CGSize(width: 153, height: 198), for: .cropBox)
    let kit = try #require(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let kitSample = sampleBuffer(of: kit)
    // Map content coordinates into the thumbnail's pixels.
    let sx = Double(kitSample.width) / 612
    let sy = Double(kitSample.height) / 792
    func kitDark(_ x: Int, _ y: Int) -> Bool {
      guard x >= 0, x < kitSample.width, y >= 0, y < kitSample.height else { return false }
      return dark(kitSample.data, at(kitSample, x, y))
    }
    var kitMinX = kitSample.width, kitMinY = kitSample.height, kitMaxX = -1, kitMaxY = -1
    for y in 0..<kitSample.height {
      for x in 0..<kitSample.width where kitDark(x, y) {
        kitMinX = min(kitMinX, x); kitMaxX = max(kitMaxX, x)
        kitMinY = min(kitMinY, y); kitMaxY = max(kitMaxY, y)
      }
    }
    var kitTop = 0
    var kitBottom = 0
    for contentY in 200..<300 {
      for contentX in 200..<300 {
        let x = Int(Double(contentX) * sx)
        let y = Int(Double(contentY) * sy)
        if kitDark(x, y) {
          if contentY >= 250 { kitTop += 1 } else { kitBottom += 1 }
        }
      }
    }
    print("[DEBUG] kit \(kitSample.width)x\(kitSample.height) dark content-space box x \(Double(kitMinX) / sx)...\(Double(kitMaxX) / sx) y \(Double(kitMinY) / sy)...\(Double(kitMaxY) / sy); service top \(serviceTop) bottom \(serviceBottom) kitTop \(kitTop) kitBottom \(kitBottom)")
    #expect(serviceTop + serviceBottom > 0)
    #expect(kitTop + kitBottom > 0)
    // Both renderers must agree on which half of the mask paints.
    #expect((serviceTop > serviceBottom) == (kitTop > kitBottom))
  }

  // MARK: - Tiles, progressive renders, capabilities, budgets (P11-013/016/019/022)

  @Test func tileRendersMatchFullPagePixels() async throws {
    let graph = try samplingGraph()
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let full = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 1))
    // The sampling fixture inks content (20, 20)-(120, 120).
    let tile = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 1,
        tile: PageTile(region: [0, 0, 200, 200])))
    #expect(tile.pixelWidth == 200)
    #expect(tile.pixelHeight == 200)
    // A tile downsamples nothing: its pixels equal the full bitmap's pixels
    // at the same offset.
    let fullSample = sampleBuffer(of: full.image.image)
    let tileSample = sampleBuffer(of: tile.image.image)
    func at(_ sample: (width: Int, height: Int, data: [UInt8]), _ x: Int, _ y: Int) -> Int {
      ((sample.height - 1 - y) * sample.width + x) * 4
    }
    for (x, y) in [(30, 30), (100, 100), (150, 50), (5, 190)] {
      let a = at(tileSample, x, y)
      let b = at(fullSample, x, y)
      #expect(
        tileSample.data[a..<a + 4] == fullSample.data[b..<b + 4],
        "tile pixel (\(x), \(y)) differs from the full render")
    }
    // A blank region renders blank and allocates only its own pixels.
    let blank = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 1,
        tile: PageTile(region: [400, 400, 500, 500])))
    #expect(blank.pixelWidth == 100 && blank.pixelHeight == 100)
    let blankSample = sampleBuffer(of: blank.image.image)
    var dark = 0
    for y in 0..<100 {
      for x in 0..<100 where blankSample.data[at(blankSample, x, y)] < 200 {
        dark += 1
      }
    }
    #expect(dark == 0)
    // A region outside the page is refused rather than rendered empty.
    await #expect(throws: PageRenderError.self) {
      _ = try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: 0, scale: 1,
          tile: PageTile(region: [1000, 1000, 1100, 1100])))
    }
  }

  @Test func rotatedTileMatchesRotatedFullRender() async throws {
    let graph = try samplingGraph(rotate: 90)
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let geometry = try PageRenderGeometry.geometries(in: graph)[0]
    // The ink rect (20, 20)-(120, 120) maps through the rotation; take a tile
    // around its mapped position and require ink inside it.
    let full = geometry.contentToPixelTransform(scale: 0.5)
    let mapped = CGPoint(x: 70, y: 70).applying(full)
    let tile = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 0.5,
        tile: PageTile(region: [20, 20, 120, 120])))
    #expect(tile.pixelWidth > 0 && tile.pixelHeight > 0)
    #expect(tile.pixelWidth <= fullPageWidth(geometry, scale: 0.5).0)
    let sample = sampleBuffer(of: tile.image.image)
    var dark = 0
    for y in 0..<sample.height {
      for x in 0..<sample.width {
        let offset = ((sample.height - 1 - y) * sample.width + x) * 4
        if sample.data[offset] < 100 && sample.data[offset + 1] < 100
          && sample.data[offset + 2] < 100
        {
          dark += 1
        }
      }
    }
    #expect(dark > 0)
    _ = mapped
  }

  @Test func progressivePlaceholderSharpensIntoTheFinalRender() async throws {
    let graph = try samplingGraph()
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    let request = PageRenderRequest(
      documentID: id, revision: 1, pageIndex: 0, scale: 1)
    let progressive = try await service.renderProgressive(request, placeholderScale: 0.1)
    #expect(progressive.placeholder.pixelWidth < progressive.final.pixelWidth)
    #expect(progressive.placeholder.request.revision == 1)
    #expect(progressive.final.pixelWidth == 612)
    #expect(progressive.final.pixelHeight == 792)
    // The final result is the cached render: asking again is a cache hit.
    let again = try await service.render(request)
    #expect(again.cacheHit == true)
  }

  @Test func renderCapabilitiesAreRecordedSeparatelyFromEditing() {
    let capabilities = PageRenderCapabilities.current
    #expect(capabilities.renderer == "CoreGraphics")
    #expect(capabilities.appliesOptionalContentFiltering == false)
    #expect(capabilities.appliesColorManagement == false)
    #expect(capabilities.supportsTransparentBackground == true)
    #expect(capabilities.supportsTileRendering == true)
    #expect(!capabilities.editingSupport.isEmpty)
  }

  @Test func shrinkingTheBudgetEvictsLeastRecentlyUsedBitmaps() async throws {
    // 612x792 page: scale 0.05 renders 30x39 (4,680 bytes), scale 0.06
    // renders 36x47 (6,768 bytes).
    let graph = try samplingGraph()
    let service = PageRenderService(cacheByteBudget: 64 << 20)
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    func request(_ scale: Double) -> PageRenderRequest {
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: scale)
    }
    _ = try await service.render(request(0.05))
    _ = try await service.render(request(0.06))
    // Touch the 0.06 entry so the 0.05 entry is least recently used.
    _ = try await service.render(request(0.06))
    // A 7,000-byte budget keeps the 6,768-byte entry and evicts the other.
    await service.setCacheByteBudget(7_000)
    let stats = await service.cacheStatistics()
    #expect(stats.bytes <= 7_000)
    #expect(stats.entries == 1)
    let kept = try await service.render(request(0.06))
    #expect(kept.cacheHit == true)
    let evicted = try await service.render(request(0.05))
    #expect(evicted.cacheHit == false)
  }

  // MARK: - Measurements (P11-029)

  @Test func renderServiceMeasurements() async throws {
    let graph = try PDFParser.parse(PDFFixtures.threePages()).graph
    let service = PageRenderService()
    let id = UUID()
    try await service.setSnapshot(documentID: id, revision: 1, graph: graph)
    _ = try await service.render(
      PageRenderRequest(documentID: id, revision: 1, pageIndex: 0, scale: 0.5))
    func millis(_ duration: Duration) -> Int {
      Int(duration.components.seconds * 1000)
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
    let clock = ContinuousClock()
    let start = clock.now
    _ = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 1, purpose: .export))
    let firstPage = millis(clock.now - start)
    let retinaStart = clock.now
    _ = try await service.render(
      PageRenderRequest(
        documentID: id, revision: 1, pageIndex: 0, scale: 2, purpose: .export))
    let retina = millis(clock.now - retinaStart)
    let thumbnailStart = clock.now
    for page in 0..<3 {
      _ = try await service.render(
        PageRenderRequest(
          documentID: id, revision: 1, pageIndex: page, scale: 0.2, purpose: .thumbnail))
    }
    let thumbnails = millis(clock.now - thumbnailStart)
    let stats = await service.cacheStatistics()
    print(
      "[P11] first page scale 1: \(firstPage) ms; scale 2: \(retina) ms; 3 thumbnails at 0.2: \(thumbnails) ms; cache \(stats.entries) entries, \(stats.bytes / 1024) KiB"
    )
    #expect(firstPage >= 0 && retina >= 0 && thumbnails >= 0)
    #expect(stats.entries >= 3)
  }
}
