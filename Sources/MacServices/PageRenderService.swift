import CoreGraphics
import Foundation
import PDFCore
import PDFEditing

/// P11-002: what a render is for. Purpose drives scheduling priority (visible
/// pages before background thumbnails) and lets callers distinguish
/// interactive work from batch work.
public enum PageRenderPurpose: Int, Sendable, Equatable, Comparable, CaseIterable {
  case visible = 0
  case thumbnail = 1
  case export = 2
  case print = 3

  public static func < (left: Self, right: Self) -> Bool {
    left.rawValue < right.rawValue
  }
}

/// P11-020: how the bitmap background is prepared. `white` composites the
/// page on an opaque white background (the default viewing behavior);
/// `transparent` leaves the bitmap background transparent.
public enum PageRenderBackground: String, Sendable, Equatable, Hashable {
  case white
  case transparent
}

/// P11-013: a content-space rectangle to render instead of the whole page.
/// Tiles bound bitmap memory for large pages: only the region's pixels are
/// allocated. The region is clamped to the page's crop box.
public struct PageTile: Sendable, Equatable, Hashable {
  public let region: [Double]

  public init(region: [Double]) {
    self.region = region
  }
}

/// P11-002: an immutable render request naming the document revision, the
/// page, the scale in pixels per display point, the purpose, and a pixel
/// budget that bounds the bitmap size.
public struct PageRenderRequest: Sendable, Equatable, Hashable {
  public let documentID: UUID
  /// The snapshot revision the caller believes is current. Results for any
  /// other revision are refused as stale.
  public let revision: Int
  public let pageIndex: Int
  /// Pixels per display point (1 renders 72 dpi).
  public let scale: Double
  public let purpose: PageRenderPurpose
  /// P11-007: the rendered bitmap never exceeds this many pixels.
  public let maxPixels: Int
  public let background: PageRenderBackground
  /// P11-013: when set, only this content-space region is rendered.
  public let tile: PageTile?

  public init(
    documentID: UUID, revision: Int, pageIndex: Int, scale: Double,
    purpose: PageRenderPurpose = .visible, maxPixels: Int = 16_777_216,
    background: PageRenderBackground = .white, tile: PageTile? = nil
  ) {
    self.documentID = documentID
    self.revision = revision
    self.pageIndex = pageIndex
    self.scale = scale
    self.purpose = purpose
    self.maxPixels = maxPixels
    self.background = background
    self.tile = tile
  }
}

/// P11-005/P11-006: one page's resolved display geometry (crop box, rotation,
/// UserUnit) from the core inventory, with the display size in points and the
/// transform from PDF content space to rendered pixels.
public struct PageRenderGeometry: Sendable, Equatable {
  public let pageIndex: Int
  /// Normalized to 0/90/180/270.
  public let rotation: Int
  public let userUnit: Double
  /// The displayed page box in PDF user space (crop box or media box).
  public let cropBox: [Double]

  public init(pageIndex: Int, attributes: PDFPageAttributes) {
    self.pageIndex = pageIndex
    self.rotation = attributes.rotation
    self.userUnit = attributes.userUnit > 0 ? attributes.userUnit : 1
    self.cropBox = attributes.displayBox
  }

  /// Resolved geometry for every page of a core-produced snapshot.
  public static func geometries(in graph: PDFGraph) throws -> [PageRenderGeometry] {
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    return PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph).map {
      PageRenderGeometry(pageIndex: $0.pageIndex, attributes: $0)
    }
  }

  /// The displayed page size in points: rotation swaps the axes and UserUnit
  /// scales the box.
  public var displaySize: CGSize {
    let width = max(0, cropBox[2] - cropBox[0]) * userUnit
    let height = max(0, cropBox[3] - cropBox[1]) * userUnit
    if rotation == 90 || rotation == 270 {
      return CGSize(width: height, height: width)
    }
    return CGSize(width: width, height: height)
  }

  /// P11-007: pixel dimensions for a scale, clamped so width × height never
  /// exceeds the caller's pixel budget. Returns the effective scale actually
  /// used, so callers can label a downscaled preview honestly.
  public func pixelSize(scale: Double, maxPixels: Int)
    -> (width: Int, height: Int, effectiveScale: Double)
  {
    let size = displaySize
    guard size.width > 0, size.height > 0 else { return (1, 1, 1) }
    let area = Double(size.width) * Double(size.height)
    var effective = max(0.02, scale)
    let limit = Double(max(1, maxPixels))
    if area * effective * effective > limit {
      effective = (limit / area).squareRoot()
    }
    return (
      max(1, Int((Double(size.width) * effective).rounded(.down))),
      max(1, Int((Double(size.height) * effective).rounded(.down))),
      effective
    )
  }

  /// P11-013: pixel dimensions and transform for a content-space tile. The
  /// tile bitmap covers the transformed region's bounding box, so rotated
  /// pages stay correct; the budget clamp works exactly like the full page.
  public func tilePixelSize(region: [Double], scale: Double, maxPixels: Int)
    -> (width: Int, height: Int, effectiveScale: Double,
        transform: CGAffineTransform)?
  {
    guard region.count == 4 else { return nil }
    let clamped = [
      max(region[0], cropBox[0]), max(region[1], cropBox[1]),
      min(region[2], cropBox[2]), min(region[3], cropBox[3]),
    ]
    guard clamped[2] > clamped[0], clamped[3] > clamped[1] else { return nil }
    var effective = max(0.02, scale)
    let limit = Double(max(1, maxPixels))
    func box(at candidate: Double) -> (CGPoint, CGPoint) {
      let transform = contentToPixelTransform(scale: candidate)
      let corners = [
        CGPoint(x: clamped[0], y: clamped[1]), CGPoint(x: clamped[2], y: clamped[1]),
        CGPoint(x: clamped[0], y: clamped[3]), CGPoint(x: clamped[2], y: clamped[3]),
      ].map { $0.applying(transform) }
      let xs = corners.map(\.x), ys = corners.map(\.y)
      return (
        CGPoint(x: xs.min() ?? 0, y: ys.min() ?? 0),
        CGPoint(x: xs.max() ?? 0, y: ys.max() ?? 0))
    }
    var (lo, hi) = box(at: effective)
    let area = max(1, (hi.x - lo.x) * (hi.y - lo.y))
    if area * effective * effective > limit {
      effective = (limit / area).squareRoot()
      (lo, hi) = box(at: effective)
    }
    let width = max(1, Int((hi.x - lo.x).rounded(.down)))
    let height = max(1, Int((hi.y - lo.y).rounded(.down)))
    // Shift the full-page transform so the transformed region's bounding
    // box origin lands on the tile bitmap's origin.
    let full = contentToPixelTransform(scale: effective)
    let shift = CGAffineTransform(translationX: -lo.x, y: -lo.y)
    return (width, height, effective, full.concatenating(shift))
  }

  /// P11-005/P11-006: the transform from PDF content space (the crop box's
  /// coordinate system, nonzero origins included) to pixel space of a bitmap
  /// rendered at `scale`, using the bottom-left origin Core Graphics expects.
  /// Rotation follows /Rotate (clockwise for display) and UserUnit scales the
  /// content coordinates into display points.
  public func contentToPixelTransform(scale: Double) -> CGAffineTransform {
    let x0 = cropBox[0]
    let y0 = cropBox[1]
    let contentWidth = max(0, cropBox[2] - cropBox[0])
    let contentHeight = max(0, cropBox[3] - cropBox[1])
    let s = max(0, scale) * userUnit
    switch ((rotation % 360) + 360) % 360 {
    case 90:
      return CGAffineTransform(a: 0, b: -s, c: s, d: 0, tx: -s * y0, ty: s * (contentWidth + x0))
    case 180:
      return CGAffineTransform(
        a: -s, b: 0, c: 0, d: -s, tx: s * (contentWidth + x0), ty: s * (contentHeight + y0))
    case 270:
      return CGAffineTransform(
        a: 0, b: s, c: -s, d: 0, tx: s * (contentHeight + y0), ty: -s * x0)
    default:
      return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -s * x0, ty: -s * y0)
    }
  }
}

/// P11-006: mapping between a page's display points and view points at a zoom
/// factor and scroll offset (both with bottom-left origins). Lives here so
/// overlays and hit tests share one normalized transform instead of deriving
/// their own.
public struct PageViewTransform: Sendable, Equatable {
  public let displaySize: CGSize
  /// View points per display point.
  public let zoom: Double
  /// The view coordinate of the display origin.
  public let viewOffset: CGPoint

  public init(displaySize: CGSize, zoom: Double, viewOffset: CGPoint) {
    self.displaySize = displaySize
    self.zoom = zoom
    self.viewOffset = viewOffset
  }

  public func viewPoint(fromDisplay point: CGPoint) -> CGPoint {
    CGPoint(x: viewOffset.x + point.x * zoom, y: viewOffset.y + point.y * zoom)
  }

  public func displayPoint(fromView point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - viewOffset.x) / zoom, y: (point.y - viewOffset.y) / zoom)
  }

  /// The transform for a new zoom with one display point pinned to the same
  /// view point (used to keep the visible location across zoom changes).
  public func zoomed(to newZoom: Double, preserving displayPoint: CGPoint) -> PageViewTransform {
    let anchor = viewPoint(fromDisplay: displayPoint)
    return PageViewTransform(
      displaySize: displaySize, zoom: newZoom,
      viewOffset: CGPoint(
        x: anchor.x - displayPoint.x * newZoom, y: anchor.y - displayPoint.y * newZoom))
  }
}

/// A rendered page bitmap. Wraps CGImage so it can cross concurrency
/// boundaries under Swift 6 (CGImage is immutable once produced).
public struct PageBitmap: @unchecked Sendable {
  public let image: CGImage

  public init(image: CGImage) {
    self.image = image
  }
}

public struct PageRenderResult: Sendable {
  public let image: PageBitmap
  public let request: PageRenderRequest
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let effectiveScale: Double
  public let cacheHit: Bool
}

public struct PageRenderCacheStatistics: Sendable, Equatable {
  public let entries: Int
  public let bytes: Int
  public let hits: Int
  public let misses: Int
}

public enum PageRenderError: Error, Equatable {
  case noSnapshot
  case staleRevision(expected: Int, current: Int)
  case pageOutOfRange(Int)
  case renderFailed(String)
}

/// P11-024: render failures are value-level errors with readable messages.
/// They never touch the document model, so a failed preview leaves an
/// otherwise inspectable document open.
extension PageRenderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noSnapshot:
      return "The document has no render snapshot (it may be closed)."
    case .staleRevision(let expected, let current):
      return "The render request expected revision \(expected) but the document is at revision \(current)."
    case .pageOutOfRange(let index):
      return "The render request names page \(index), which the snapshot does not contain."
    case .renderFailed(let reason):
      return "Rendering failed: \(reason)"
    }
  }
}

/// The bitmap producer. The default renders the immutable snapshot bytes
/// through Core Graphics; tests inject their own to observe scheduling.
public typealias PageBitmapRenderer = @Sendable (
  _ bytes: [UInt8], _ pageIndex: Int, _ pixelWidth: Int, _ pixelHeight: Int,
  _ transform: CGAffineTransform, _ background: PageRenderBackground
) async throws -> PageBitmap

/// P11-019: what the display renderer supports, recorded separately from
/// the editing capability assessment the document inventory reports.
public struct PageRenderCapabilities: Sendable, Equatable {
  public let renderer: String
  public let colorModel: String
  /// Optional-content (layer) visibility is decided by the viewing adapter,
  /// not applied by this renderer.
  public let appliesOptionalContentFiltering: Bool
  public let appliesColorManagement: Bool
  public let supportsTransparentBackground: Bool
  public let supportsTileRendering: Bool
  public let supportsProgressiveRendering: Bool
  /// Editing support is assessed independently by the document inventory.
  public let editingSupport: String

  public static let current = PageRenderCapabilities(
    renderer: "CoreGraphics", colorModel: "8-bit DeviceRGB",
    appliesOptionalContentFiltering: false, appliesColorManagement: false,
    supportsTransparentBackground: true, supportsTileRendering: true,
    supportsProgressiveRendering: true,
    editingSupport: "assessed separately by PDFDocumentInventory")
}

/// P11-017: an annotation/edit overlay pinned to one snapshot revision.
/// Overlays resolve their geometry against the snapshot they were created
/// for, so an edit that advances the revision cannot silently misalign them:
/// resolving a superseded anchor fails with `staleRevision` and the UI must
/// re-anchor instead of drawing at a stale position.
public struct PageOverlayAnchor: Sendable, Equatable, Hashable {
  public let documentID: UUID
  public let revision: Int
  public let pageIndex: Int
  /// Rectangle in PDF content space [x0, y0, x1, y1].
  public let contentRect: [Double]

  public init(documentID: UUID, revision: Int, pageIndex: Int, contentRect: [Double]) {
    self.documentID = documentID
    self.revision = revision
    self.pageIndex = pageIndex
    self.contentRect = contentRect
  }
}

/// P11-003/P11-004: an actor-owned render service. It holds one immutable
/// core-produced snapshot per open document (bytes plus resolved geometry),
/// renders pages through Core Graphics on worker tasks that own only copied
/// bytes, caches bitmaps under a byte budget keyed by document revision and
/// pixel size, schedules visible pages before background thumbnails, bounds
/// concurrent renders, and refuses results from superseded revisions.
public actor PageRenderService {
  public struct Snapshot: Sendable {
    public let revision: Int
    /// The exact bytes a renderer may read; written once per revision.
    public let bytes: [UInt8]
    public let geometries: [PageRenderGeometry]

    public var pageCount: Int { geometries.count }
  }

  private struct CacheKey: Hashable {
    let documentID: UUID
    let revision: Int
    let pageIndex: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let background: PageRenderBackground
    let tile: PageTile?
  }

  private struct CacheEntry {
    let image: PageBitmap
    let bytes: Int
  }

  private struct SlotKey: Hashable {
    let documentID: UUID
    let pageIndex: Int
  }

  private struct Inflight {
    let key: CacheKey
    let task: Task<PageBitmap, Error>
  }

  private struct Waiter {
    let id: Int
    let purpose: PageRenderPurpose
    let continuation: CheckedContinuation<Void, Never>
  }

  private var snapshots: [UUID: Snapshot] = [:]
  private var cache: [CacheKey: CacheEntry] = [:]
  /// Least recently used first.
  private var cacheOrder: [CacheKey] = []
  private var cacheBytes = 0
  private var cacheByteBudget: Int
  private var hits = 0
  private var misses = 0

  private var inflight: [SlotKey: Inflight] = [:]
  private var waiters: [Waiter] = []
  private var nextWaiterID = 0
  private var activeRenders = 0
  private let maxConcurrentRenders: Int
  private let renderer: PageBitmapRenderer

  public init(
    cacheByteBudget: Int = 64 << 20, maxConcurrentRenders: Int = 2,
    renderer: PageBitmapRenderer? = nil
  ) {
    self.cacheByteBudget = max(0, cacheByteBudget)
    self.maxConcurrentRenders = max(1, maxConcurrentRenders)
    self.renderer = renderer ?? PageRenderService.coreGraphicsRenderer
  }

  // MARK: - Snapshots

  /// Install (or replace) the immutable snapshot for an open document. When
  /// `changedPages` is given and the revision advances, cached previews for
  /// pages the edit did not touch are re-keyed to the new revision so only
  /// affected previews are invalidated (P11-011). In-flight renders are
  /// cancelled because the backing bytes are gone (P11-015).
  @discardableResult
  public func setSnapshot(
    documentID: UUID, revision: Int, graph: PDFGraph, changedPages: [Int]? = nil
  ) throws -> Snapshot {
    let bytes = [UInt8](try PDFWriter.write(graph))
    let geometries = try PageRenderGeometry.geometries(in: graph)
    if let previous = snapshots[documentID], revision > previous.revision,
      let changedPages, changedPages.count < geometries.count
    {
      let changed = Set(changedPages)
      let stable = cache.filter {
        $0.key.documentID == documentID && !changed.contains($0.key.pageIndex)
          && $0.key.pageIndex < geometries.count
      }
      for (key, entry) in stable {
        if let index = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: index) }
        cacheBytes -= entry.bytes
        cache.removeValue(forKey: key)
        let newKey = CacheKey(
          documentID: documentID, revision: revision, pageIndex: key.pageIndex,
          pixelWidth: key.pixelWidth, pixelHeight: key.pixelHeight,
          background: key.background, tile: key.tile)
        cache[newKey] = entry
        cacheOrder.append(newKey)
        cacheBytes += entry.bytes
      }
    }
    let staleSlots = inflight.keys.filter { $0.documentID == documentID }
    for slot in staleSlots {
      inflight[slot]?.task.cancel()
      inflight[slot] = nil
    }
    let snapshot = Snapshot(revision: revision, bytes: bytes, geometries: geometries)
    snapshots[documentID] = snapshot
    return snapshot
  }

  /// Drop a closed document's snapshot, cancelling its renders and removing
  /// its cached bitmaps (P11-012: results never outlive their document).
  public func removeSnapshot(documentID: UUID) {
    snapshots[documentID] = nil
    invalidate(documentID: documentID)
  }

  /// Invalidate cached previews for specific pages (all pages when `pages` is
  /// nil) and cancel their in-flight renders.
  public func invalidate(documentID: UUID, pages: [Int]? = nil) {
    let affected = pages.map(Set.init)
    let keysToDrop = cache.keys.filter {
      $0.documentID == documentID && (affected == nil || affected!.contains($0.pageIndex))
    }
    for key in keysToDrop {
      if let entry = cache.removeValue(forKey: key) { cacheBytes -= entry.bytes }
      cacheOrder.removeAll { $0 == key }
    }
    let slots = inflight.keys.filter {
      $0.documentID == documentID && (affected == nil || affected!.contains($0.pageIndex))
    }
    for slot in slots {
      inflight[slot]?.task.cancel()
      inflight[slot] = nil
    }
  }

  /// Cancel one page's in-flight render (cooperative: the renderer must honor
  /// task cancellation for prompt stops).
  public func cancel(documentID: UUID, pageIndex: Int) {
    let slot = SlotKey(documentID: documentID, pageIndex: pageIndex)
    inflight[slot]?.task.cancel()
    inflight[slot] = nil
  }

  public func snapshot(for documentID: UUID) -> Snapshot? {
    snapshots[documentID]
  }

  // MARK: - Rendering

  public func render(_ request: PageRenderRequest) async throws -> PageRenderResult {
    let prepared = try preparation(for: request)
    let (snapshot, _, size, transform, key) = prepared
    if let cached = cache[key] {
      hits += 1
      touch(key)
      return result(cached.image, request: request, size: size, cacheHit: true)
    }
    misses += 1
    try Task.checkCancellation()

    // P11-015: supersede an in-flight render of the same page at other pixels.
    let slot = SlotKey(documentID: request.documentID, pageIndex: request.pageIndex)
    if let existing = inflight[slot], existing.key != key {
      existing.task.cancel()
      inflight[slot] = nil
    }

    await acquireSlot(purpose: request.purpose)
    defer { releaseSlot() }
    try Task.checkCancellation()

    // Another caller may have finished the same render while we waited.
    if let cached = cache[key] {
      hits += 1
      touch(key)
      return result(cached.image, request: request, size: size, cacheHit: true)
    }

    let renderer = self.renderer
    let bytes = snapshot.bytes
    let pageIndex = request.pageIndex
    let task = Task.detached(priority: request.purpose == .visible ? .userInitiated : .utility) {
      try await renderer(bytes, pageIndex, size.width, size.height, transform, request.background)
    }
    inflight[slot] = Inflight(key: key, task: task)

    let image: PageBitmap
    do {
      image = try await task.value
    } catch {
      if inflight[slot]?.key == key { inflight[slot] = nil }
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw PageRenderError.renderFailed(String(describing: error))
    }
    if inflight[slot]?.key == key { inflight[slot] = nil }
    try Task.checkCancellation()

    // P11-012: a render that finished against an older revision is refused
    // rather than cached or handed to the newer document state.
    guard let current = snapshots[request.documentID], current.revision == request.revision else {
      throw PageRenderError.staleRevision(
        expected: request.revision, current: snapshots[request.documentID]?.revision ?? -1)
    }

    insert(image, key: key)
    return result(image, request: request, size: size, cacheHit: false)
  }

  /// P11-017: resolve an overlay anchor to display points (scale-independent)
  /// against the snapshot revision it was pinned to. Rotated pages return the
  /// mapped bounding box. A superseded anchor is refused with `staleRevision`.
  public func displayRect(for anchor: PageOverlayAnchor) throws -> CGRect {
    guard let snapshot = snapshots[anchor.documentID] else {
      throw PageRenderError.noSnapshot
    }
    guard snapshot.revision == anchor.revision else {
      throw PageRenderError.staleRevision(
        expected: anchor.revision, current: snapshot.revision)
    }
    guard anchor.pageIndex >= 0, anchor.pageIndex < snapshot.geometries.count else {
      throw PageRenderError.pageOutOfRange(anchor.pageIndex)
    }
    guard anchor.contentRect.count == 4 else {
      throw PageRenderError.pageOutOfRange(anchor.pageIndex)
    }
    let transform = snapshot.geometries[anchor.pageIndex].contentToPixelTransform(scale: 1)
    let corners = [
      CGPoint(x: anchor.contentRect[0], y: anchor.contentRect[1]),
      CGPoint(x: anchor.contentRect[2], y: anchor.contentRect[1]),
      CGPoint(x: anchor.contentRect[0], y: anchor.contentRect[3]),
      CGPoint(x: anchor.contentRect[2], y: anchor.contentRect[3]),
    ].map { $0.applying(transform) }
    let xs = corners.map(\.x), ys = corners.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(),
      let maxY = ys.max()
    else {
      throw PageRenderError.pageOutOfRange(anchor.pageIndex)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// The cached bitmap for a request, if present, without rendering.
  public func cachedImage(for request: PageRenderRequest) -> PageBitmap? {
    guard let (_, _, _, _, key) = try? preparation(for: request) else { return nil }
    guard let entry = cache[key] else { return nil }
    hits += 1
    touch(key)
    return entry.image
  }

  public func cacheStatistics() -> PageRenderCacheStatistics {
    PageRenderCacheStatistics(entries: cache.count, bytes: cacheBytes, hits: hits, misses: misses)
  }

  /// Renders that occupy a slot plus those waiting for one; used by the UI to
  /// describe background work and by tests to observe scheduling.
  public func pendingRenderCount() -> Int {
    activeRenders + waiters.count
  }

  /// P11-022: change the cache byte budget at runtime (for example when the
  /// app receives a memory warning) and immediately evict least recently used
  /// bitmaps down to it. PDFKit's own thumbnail memory is framework-owned and
  /// cannot be accounted here; this budget is the app's lever over the
  /// service's share.
  public func setCacheByteBudget(_ budget: Int) {
    cacheByteBudget = max(0, budget)
    while cacheBytes > cacheByteBudget, let oldest = cacheOrder.first {
      cacheOrder.removeFirst()
      if let entry = cache.removeValue(forKey: oldest) {
        cacheBytes -= entry.bytes
      }
    }
  }

  /// P11-016: render a low-scale placeholder and then the requested bitmap,
  /// so the UI can show a fast preview that sharpens into the final image.
  /// Both results are cached; the final result is identical to `render` of
  /// the same request.
  public func renderProgressive(
    _ request: PageRenderRequest, placeholderScale: Double
  ) async throws -> (placeholder: PageRenderResult, final: PageRenderResult) {
    var placeholderRequest = request
    placeholderRequest = PageRenderRequest(
      documentID: request.documentID, revision: request.revision,
      pageIndex: request.pageIndex, scale: min(placeholderScale, request.scale),
      purpose: .thumbnail, maxPixels: request.maxPixels,
      background: request.background, tile: request.tile)
    let placeholder = try await render(placeholderRequest)
    let final = try await render(request)
    return (placeholder, final)
  }

  // MARK: - Internals

  private func preparation(for request: PageRenderRequest) throws
    -> (Snapshot, PageRenderGeometry, (width: Int, height: Int, effectiveScale: Double),
        CGAffineTransform, CacheKey)
  {
    guard let snapshot = snapshots[request.documentID] else {
      throw PageRenderError.noSnapshot
    }
    guard snapshot.revision == request.revision else {
      throw PageRenderError.staleRevision(
        expected: request.revision, current: snapshot.revision)
    }
    guard request.pageIndex >= 0, request.pageIndex < snapshot.geometries.count else {
      throw PageRenderError.pageOutOfRange(request.pageIndex)
    }
    let geometry = snapshot.geometries[request.pageIndex]
    let key: CacheKey
    let size: (width: Int, height: Int, effectiveScale: Double)
    let transform: CGAffineTransform
    if let tile = request.tile {
      guard
        let tiled = geometry.tilePixelSize(
          region: tile.region, scale: request.scale, maxPixels: request.maxPixels)
      else { throw PageRenderError.pageOutOfRange(request.pageIndex) }
      size = (tiled.width, tiled.height, tiled.effectiveScale)
      transform = tiled.transform
    } else {
      size = geometry.pixelSize(scale: request.scale, maxPixels: request.maxPixels)
      transform = geometry.contentToPixelTransform(scale: size.effectiveScale)
    }
    key = CacheKey(
      documentID: request.documentID, revision: request.revision, pageIndex: request.pageIndex,
      pixelWidth: size.width, pixelHeight: size.height, background: request.background,
      tile: request.tile)
    return (snapshot, geometry, size, transform, key)
  }

  private func result(
    _ image: PageBitmap, request: PageRenderRequest,
    size: (width: Int, height: Int, effectiveScale: Double), cacheHit: Bool
  ) -> PageRenderResult {
    PageRenderResult(
      image: image, request: request, pixelWidth: size.width, pixelHeight: size.height,
      effectiveScale: size.effectiveScale, cacheHit: cacheHit)
  }

  /// P11-014: at most `maxConcurrentRenders` renders run at once; further
  /// callers suspend until a slot frees. P11-009: freed slots go to the
  /// highest-priority waiter first (visible before thumbnails, then arrival).
  private func acquireSlot(purpose: PageRenderPurpose) async {
    if activeRenders < maxConcurrentRenders {
      activeRenders += 1
      return
    }
    let id = nextWaiterID
    nextWaiterID += 1
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(Waiter(id: id, purpose: purpose, continuation: continuation))
    }
  }

  private func releaseSlot() {
    activeRenders = max(0, activeRenders - 1)
    guard activeRenders < maxConcurrentRenders, !waiters.isEmpty else { return }
    let next = waiters.enumerated().min { left, right in
      if left.element.purpose != right.element.purpose {
        return left.element.purpose < right.element.purpose
      }
      return left.element.id < right.element.id
    }!
    waiters.remove(at: next.offset)
    activeRenders += 1
    next.element.continuation.resume()
  }

  private func touch(_ key: CacheKey) {
    if let index = cacheOrder.firstIndex(of: key) {
      cacheOrder.remove(at: index)
    }
    cacheOrder.append(key)
  }

  private func insert(_ image: PageBitmap, key: CacheKey) {
    let bytes = key.pixelWidth * key.pixelHeight * 4
    if bytes > cacheByteBudget { return }
    if let old = cache.removeValue(forKey: key) {
      cacheBytes -= old.bytes
      cacheOrder.removeAll { $0 == key }
    }
    cache[key] = CacheEntry(image: image, bytes: bytes)
    cacheOrder.append(key)
    cacheBytes += bytes
    // P11-007/P11-022: evict least recently used bitmaps under the budget.
    while cacheBytes > cacheByteBudget, let oldest = cacheOrder.first {
      cacheOrder.removeFirst()
      if let entry = cache.removeValue(forKey: oldest) {
        cacheBytes -= entry.bytes
      }
    }
  }

  // MARK: - Core Graphics rendering

  /// P11-003: render an immutable snapshot's page with Core Graphics. The
  /// renderer reads only the copied bytes and the resolved transform, so it
  /// can run on any worker without touching service state (P11-004).
  public static func coreGraphicsRenderer(
    bytes: [UInt8], pageIndex: Int, pixelWidth: Int, pixelHeight: Int,
    transform: CGAffineTransform, background: PageRenderBackground = .white
  ) async throws -> PageBitmap {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let document = CGPDFDocument(provider),
      let page = document.page(at: pageIndex + 1)
    else {
      throw PageRenderError.renderFailed("CoreGraphics could not open the snapshot")
    }
    let alphaInfo: CGImageAlphaInfo =
      background == .transparent ? .premultipliedLast : .noneSkipLast
    guard
      let context = CGContext(
        data: nil, width: max(1, pixelWidth), height: max(1, pixelHeight), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alphaInfo.rawValue)
    else {
      throw PageRenderError.renderFailed("CoreGraphics could not create the bitmap context")
    }
    context.interpolationQuality = .high
    if background == .white {
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    }
    context.saveGState()
    context.concatenate(transform)
    context.addRect(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.clip()
    context.drawPDFPage(page)
    context.restoreGState()
    guard let image = context.makeImage() else {
      throw PageRenderError.renderFailed("CoreGraphics could not produce the bitmap")
    }
    return PageBitmap(image: image)
  }
}
