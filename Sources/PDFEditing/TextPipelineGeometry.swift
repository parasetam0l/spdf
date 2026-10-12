import Foundation
import PDFCore

/// P16-002: display-space normalization for text geometry.
///
/// The owned layout (`PageTextLayout`) works in unrotated page content space.
/// Real pages add three display facts: a possibly nonzero crop origin, a
/// `/UserUnit` scale, and a `/Rotate` clockwise turn. This layer maps content
/// coordinates to display points (bottom-left origin, y up, UserUnit-scaled,
/// rotation applied clockwise about the crop origin) and back, so hit testing
/// and highlights agree with what the viewer shows.
///
/// Convention (documented, not inherited from the pixel renderer, which flips
/// y for Core Graphics bitmaps): the scaled crop-relative offset
/// `(dx, dy) = ((x - x0) * u, (y - y0) * u)` on a `w*u x h*u` box maps to
/// - 0: `(dx, dy)`
/// - 90: `(dy, w*u - dx)`
/// - 180: `(w*u - dx, h*u - dy)`
/// - 270: `(h*u - dy, dx)`
/// Non-90-multiple `/Rotate` values normalize to the nearest quarter turn;
/// a nonpositive `UserUnit` falls back to 1.
public struct PageDisplayGeometry: Sendable, Equatable {
  public let rotation: Int
  public let userUnit: Double
  public let cropBox: [Double]

  public init(rotation: Int, userUnit: Double, cropBox: [Double]) {
    self.rotation = rotation
    self.userUnit = userUnit
    self.cropBox = cropBox
  }

  /// Resolve the display geometry of one page.
  public static func resolve(pageID: PDFObjectID, in graph: PDFGraph) -> PageDisplayGeometry? {
    guard let pageIDs = try? PDFPageTree.pageIDs(in: graph) else { return nil }
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: pageIDs, in: graph)
    guard let match = attributes.first(where: { $0.pageObjectID == pageID }) else { return nil }
    let unit = match.userUnit > 0 && match.userUnit.isFinite ? match.userUnit : 1
    return PageDisplayGeometry(
      rotation: ((match.rotation % 360) + 360) % 360, userUnit: unit, cropBox: match.cropBox)
  }

  /// The quarter-turn actually applied (nearest 90 for off-spec values).
  public var quarterTurns: Int {
    let normalized = ((rotation % 360) + 360) % 360
    return (Int((Double(normalized) / 90).rounded()) % 4 + 4) % 4
  }

  public var contentWidth: Double { max(0, cropBox[2] - cropBox[0]) }
  public var contentHeight: Double { max(0, cropBox[3] - cropBox[1]) }

  public var displayWidth: Double {
    quarterTurns == 1 || quarterTurns == 3
      ? contentHeight * userUnit : contentWidth * userUnit
  }

  public var displayHeight: Double {
    quarterTurns == 1 || quarterTurns == 3
      ? contentWidth * userUnit : contentHeight * userUnit
  }

  /// Content-space point to display points.
  public func toDisplay(_ point: [Double]) -> [Double]? {
    guard point.count == 2, cropBox.count == 4 else { return nil }
    let dx = (point[0] - cropBox[0]) * userUnit
    let dy = (point[1] - cropBox[1]) * userUnit
    let w = contentWidth * userUnit
    let h = contentHeight * userUnit
    switch quarterTurns {
    case 1: return [dy, w - dx]
    case 2: return [w - dx, h - dy]
    case 3: return [h - dy, dx]
    default: return [dx, dy]
    }
  }

  /// Display points back to content space.
  public func toContent(_ point: [Double]) -> [Double]? {
    guard point.count == 2, cropBox.count == 4 else { return nil }
    let w = contentWidth * userUnit
    let h = contentHeight * userUnit
    let offset: [Double]
    switch quarterTurns {
    case 1: offset = [w - point[1], point[0]]
    case 2: offset = [w - point[0], h - point[1]]
    case 3: offset = [point[1], h - point[0]]
    default: offset = [point[0], point[1]]
    }
    guard userUnit != 0 else { return nil }
    return [cropBox[0] + offset[0] / userUnit, cropBox[1] + offset[1] / userUnit]
  }

  /// Content-space axis-aligned bounds to display-space bounds (all four
  /// corners mapped, then bounded — correct for quarter turns).
  public func toDisplay(bounds: [Double]) -> [Double]? {
    guard bounds.count == 4 else { return nil }
    let corners = [
      [bounds[0], bounds[1]], [bounds[2], bounds[1]],
      [bounds[2], bounds[3]], [bounds[0], bounds[3]],
    ].compactMap { self.toDisplay($0) }
    guard corners.count == 4 else { return nil }
    let xs = corners.map { $0[0] }
    let ys = corners.map { $0[1] }
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
  }
}

/// P16-002 hit testing in display space: invert the point to content space,
/// then reuse the layout's content-space probe.
public enum NormalizedHitTesting {
  public static func clusterIndex(
    atDisplayPoint point: [Double], layout: PageTextLayout,
    geometry: PageDisplayGeometry
  ) -> Int? {
    guard let content = geometry.toContent(point) else { return nil }
    return layout.clusterIndex(at: content)
  }

  public static func displayBounds(
    of range: Range<Int>, layout: PageTextLayout, geometry: PageDisplayGeometry
  ) -> [Double]? {
    guard range.lowerBound >= 0, range.upperBound <= layout.clusters.count,
      !range.isEmpty
    else { return nil }
    var union: [Double]?
    for index in range {
      guard let mapped = geometry.toDisplay(bounds: layout.clusters[index].bounds) else {
        continue
      }
      union = union.map {
        [min($0[0], mapped[0]), min($0[1], mapped[1]),
         max($0[2], mapped[2]), max($0[3], mapped[3])]
      } ?? mapped
    }
    return union
  }
}

/// P16-011: a drag selection spanning page boundaries.
///
/// The anchor and focus each name a page (document order) and a cluster in
/// that page's layout reading order. `perPageRanges` resolves the selection
/// to one cluster range per touched page: a partial range on each end page
/// and the full span for pages in between. Cluster counts come from the
/// caller's already-built layouts, so this type never parses.
public struct CrossPageSelection: Sendable, Equatable {
  public struct Endpoint: Sendable, Equatable {
    public let pageIndex: Int
    public let clusterIndex: Int

    public init(pageIndex: Int, clusterIndex: Int) {
      self.pageIndex = pageIndex
      self.clusterIndex = clusterIndex
    }
  }

  public let anchor: Endpoint
  public let focus: Endpoint

  public init(anchor: Endpoint, focus: Endpoint) {
    self.anchor = anchor
    self.focus = focus
  }

  public var isCollapsed: Bool { anchor == focus }

  /// One cluster range per selected page, keyed by document page index.
  /// Out-of-range endpoints clamp to the page's cluster span; pages with no
  /// clusters contribute no range. Collapsed selections yield one empty range
  /// at the anchor (callers treat it as a caret, not a highlight).
  public func perPageRanges(clusterCounts: [Int]) -> [Int: Range<Int>] {
    guard !clusterCounts.isEmpty else { return [:] }
    let first = min(anchor.pageIndex, focus.pageIndex)
    let last = max(anchor.pageIndex, focus.pageIndex)
    guard first < clusterCounts.count, last >= 0 else { return [:] }
    let lo = max(0, first)
    let hi = min(clusterCounts.count - 1, last)
    guard lo <= hi else { return [:] }
    func clamped(_ endpoint: Endpoint) -> Int {
      let count = clusterCounts[endpoint.pageIndex]
      return min(max(0, endpoint.clusterIndex), max(0, count))
    }
    if anchor.pageIndex == focus.pageIndex {
      let page = anchor.pageIndex
      guard page >= 0, page < clusterCounts.count else { return [:] }
      let low = min(clamped(anchor), clamped(focus))
      let high = max(clamped(anchor), clamped(focus))
      return [page: low..<high]
    }
    let startPage = anchor.pageIndex <= focus.pageIndex ? anchor : focus
    let endPage = anchor.pageIndex <= focus.pageIndex ? focus : anchor
    var result: [Int: Range<Int>] = [:]
    for page in lo...hi {
      let count = clusterCounts[page]
      if page == startPage.pageIndex {
        result[page] = clamped(startPage)..<count
      } else if page == endPage.pageIndex {
        result[page] = 0..<clamped(endPage)
      } else {
        result[page] = 0..<count
      }
    }
    return result
  }
}

/// P16-012: selection rendering as glyph quadrilaterals.
///
/// Axis-aligned boxes overstate rotated text; quads follow the run matrix.
/// Each quad is eight numbers `[x0,y0, x1,y1, x2,y2, x3,y3]` in content space
/// for the text-space corners `(x0,y0),(x1,y0),(x1,y1),(x0,y1)`.
public enum SelectionQuads {
  /// The four mapped corners of one glyph cell.
  public static func quad(
    matrix: [Double], position: Double, advance: Double, em: Double, descent: Double,
    xOffset: Double = 0, rise: Double = 0
  ) -> [Double]? {
    guard matrix.count == 6 else { return nil }
    let x0 = position + xOffset
    let x1 = x0 + advance
    let y0 = rise + descent
    let y1 = rise + em
    var output: [Double] = []
    for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] {
      output.append(matrix[4] + x * matrix[0] + y * matrix[2])
      output.append(matrix[5] + x * matrix[1] + y * matrix[3])
    }
    return output
  }

  /// One quad per cluster in `range`, in layout order. Runs are re-walked to
  /// recover each glyph's text-space position (the same advance math the
  /// layout build uses); clusters with unrecoverable metrics fall back to
  /// their axis-aligned bounds corners.
  static func quads(
    range: Range<Int>, layout: PageTextLayout, runs: [TextRun], in graph: PDFGraph
  ) -> [[Double]] {
    guard range.lowerBound >= 0, range.upperBound <= layout.clusters.count else { return [] }
    var result: [[Double]] = []
    for index in range {
      let cluster = layout.clusters[index]
      if let quad = quadForCluster(cluster, runs: runs, in: graph) {
        result.append(quad)
      } else {
        let bounds = cluster.bounds
        result.append(
          [bounds[0], bounds[1], bounds[2], bounds[1], bounds[2], bounds[3],
           bounds[0], bounds[3]])
      }
    }
    return result
  }

  static func quadForCluster(
    _ cluster: TextCluster, runs: [TextRun], in graph: PDFGraph
  ) -> [Double]? {
    guard cluster.runIndex >= 0, cluster.runIndex < runs.count else { return nil }
    let run = runs[cluster.runIndex]
    guard run.matrix.count == 6 else { return nil }
    guard case .dictionary(let page)? = graph.objects[run.pageID],
      let font = SimpleFont.resolve(resource: run.fontResource, page: page, in: graph)
    else { return nil }
    // Replay the run's codes up to the target glyph to recover its offset.
    var position = 0.0
    var cursor = 0
    for code in run.rawCodes {
      let advance = font.advance(
        of: [code], fontSize: run.fontSize, charSpacing: run.charSpacing,
        wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale)
      if cursor == cluster.glyphIndex {
        let base = run.hasKnownOffset ? run.textSpaceOffset : 0
        let glyphPosition = base + position
        guard let advance else { return nil }
        return quad(
          matrix: run.matrix, position: glyphPosition, advance: advance,
          em: run.fontSize, descent: 0, rise: run.rise)
      }
      guard let advance else { return nil }
      position += advance
      cursor += 1
    }
    return nil
  }
}
