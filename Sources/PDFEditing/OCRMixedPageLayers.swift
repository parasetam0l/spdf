import Foundation
import PDFCore

// MARK: - OCR-06 mixed scanned/digital pages

/// OCR-06: what a page actually offers as text evidence. Mixed pages (a scan
/// image plus already-selectable digital text) must not be skipped when OCR
/// recognition can be bounded to the scan-only regions.
public enum OCRMixedPageKind: String, Sendable, CaseIterable {
  case digitalTextOnly
  case scannedNoText
  case scannedGeneratedLayer
  case mixedDigitalAndScan
  case mixedWithGeneratedLayer
  case blank

  public var title: String {
    switch self {
    case .digitalTextOnly: return "digital text"
    case .scannedNoText: return "scan (no text)"
    case .scannedGeneratedLayer: return "scan + generated OCR layer"
    case .mixedDigitalAndScan: return "mixed digital text + scan"
    case .mixedWithGeneratedLayer: return "mixed text + generated OCR layer"
    case .blank: return "blank"
    }
  }
}

/// OCR-06: what the mixed-page planner wants done for one page.
public enum OCRMixedPageAction: String, Sendable, Equatable {
  case addBoundedLayer
  case replaceGeneratedLayer
  case skip

  public var title: String {
    switch self {
    case .addBoundedLayer: return "bounded OCR layer"
    case .replaceGeneratedLayer: return "replace generated layer"
    case .skip: return "skip"
    }
  }
}

/// OCR-06: the image region(s) a bounded layer may cover. Recognized lines are
/// associated with scan image placements so text/image meaning survives.
public struct OCRBoundedRegion: Sendable, Equatable {
  public let rect: [Double]
  /// Index into the page's image placements, or -1 when the bound came from an
  /// existing generated layer rather than a scan image.
  public let imageIndex: Int

  public init(rect: [Double], imageIndex: Int) {
    self.rect = rect
    self.imageIndex = imageIndex
  }
}

public struct OCRMixedPageOptions: Sendable, Equatable {
  /// Minimum image coverage of the page before a text-bearing page is treated
  /// as a mixed scan page.
  public let minimumScanCoverage: Double
  /// A recognized line covering more than this fraction of a digital text line
  /// is dropped to avoid duplicate selectable text.
  public let maximumDigitalOverlapRatio: Double
  /// Re-OCR of pages that already carry a generated layer.
  public let replaceExistingGeneratedLayers: Bool
  public let allowBoundedLayersOnMixedPages: Bool

  public init(
    minimumScanCoverage: Double = 0.10, maximumDigitalOverlapRatio: Double = 0.10,
    replaceExistingGeneratedLayers: Bool = true,
    allowBoundedLayersOnMixedPages: Bool = true
  ) {
    self.minimumScanCoverage = minimumScanCoverage
    self.maximumDigitalOverlapRatio = maximumDigitalOverlapRatio
    self.replaceExistingGeneratedLayers = replaceExistingGeneratedLayers
    self.allowBoundedLayersOnMixedPages = allowBoundedLayersOnMixedPages
  }

  func validate() throws {
    guard minimumScanCoverage.isFinite, minimumScanCoverage >= 0,
      minimumScanCoverage <= 1
    else {
      throw PDFError(.malformed, "The scan-coverage threshold must be within 0...1")
    }
    guard maximumDigitalOverlapRatio.isFinite, maximumDigitalOverlapRatio >= 0,
      maximumDigitalOverlapRatio <= 1
    else {
      throw PDFError(.malformed, "The digital-overlap threshold must be within 0...1")
    }
  }
}

/// OCR-06: one page's text/image evidence plus the bounded OCR decision.
public struct OCRMixedPageProfile: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let pageIndex: Int
  public let kind: OCRMixedPageKind
  public let action: OCRMixedPageAction
  public let skipReason: String?
  public let digitalLineCount: Int
  public let generatedLineCount: Int
  public let imageCount: Int
  public let scanCoverage: Double
  public let boundedRegions: [OCRBoundedRegion]
  public let existingLayerLineCount: Int
  public let pageBox: [Double]
  public let digitalLineBounds: [[Double]]

  public var canRunOCR: Bool { action != .skip }

  public var summaryLine: String {
    var line =
      "P\(pageIndex + 1): \(kind.title); action: \(action.title)"
      + "; text lines: \(digitalLineCount) digital / \(generatedLineCount) generated"
      + "; images: \(imageCount) (\(Int((scanCoverage * 100).rounded()))% coverage)"
    if !boundedRegions.isEmpty {
      line += "; bounds: \(boundedRegions.count)"
    }
    if let skipReason { line += "; skipped: " + skipReason }
    return line
  }
}

/// OCR-06: deterministic page classification and bounded-layer plan. Pixels and
/// coordinates are never changed by planning; the plan only says which pages
/// can gain (or replace) a generated layer and within which scan bounds.
public enum OCRMixedPagePlanner {
  public static func profiles(
    in graph: PDFGraph, pageIDs: [PDFObjectID]? = nil,
    options: OCRMixedPageOptions = OCRMixedPageOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> [OCRMixedPageProfile] {
    try options.validate()
    let pages = try pageIDs ?? PDFPageTree.pageIDs(in: graph)
    var profiles: [OCRMixedPageProfile] = []
    for (index, pageID) in pages.enumerated() {
      profiles.append(
        try profile(
          pageID: pageID, pageIndex: index, in: graph, options: options, limits: limits))
    }
    return profiles
  }

  public static func plan(
    in graph: PDFGraph, pageIDs: [PDFObjectID]? = nil,
    selectedPageIndexes: [Int]? = nil,
    options: OCRMixedPageOptions = OCRMixedPageOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> OCRMixedPagePlan {
    let all = try profiles(in: graph, pageIDs: pageIDs, options: options, limits: limits)
    let selected = selectedPageIndexes.map(Set.init) ?? Set(all.map(\.pageIndex))
    let scoped = all.filter { selected.contains($0.pageIndex) }
    return OCRMixedPagePlan(profiles: scoped)
  }

  /// Filter recognized lines to the page's scan bounds and drop lines that
  /// would duplicate already-selectable digital text. Returns the accepted
  /// lines with the bounded-region association.
  public static func boundedLines(
    _ lines: [SearchableTextLine], for profile: OCRMixedPageProfile,
    options: OCRMixedPageOptions = OCRMixedPageOptions()
  ) -> [(line: SearchableTextLine, regionIndex: Int?)] {
    var accepted: [(SearchableTextLine, Int?)] = []
    for line in lines {
      guard line.rect.count == 4, line.rect.allSatisfy(\.isFinite),
        line.rect[2] > line.rect[0], line.rect[3] > line.rect[1],
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      guard contains(profile.pageBox, line.rect) else { continue }
      if profile.kind == .mixedDigitalAndScan || profile.kind == .mixedWithGeneratedLayer {
        if overlapRatio(line.rect, profile.digitalLineBounds) > options.maximumDigitalOverlapRatio {
          continue
        }
      }
      var matchedRegion: Int?
      for (regionIndex, region) in profile.boundedRegions.enumerated() {
        let ratio = overlapRatio(line.rect, [region.rect])
        if ratio >= 0.5 {
          matchedRegion = regionIndex
          break
        }
      }
      guard let matchedRegion else { continue }
      accepted.append((line, matchedRegion))
    }
    return accepted.map { (line: $0.0, regionIndex: $0.1) }
  }

  // MARK: Internals

  static func profile(
    pageID: PDFObjectID, pageIndex: Int, in graph: PDFGraph,
    options: OCRMixedPageOptions, limits: PDFLimits
  ) throws -> OCRMixedPageProfile {
    let box = pageBox(pageID: pageID, in: graph)
    let layout = try? PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    let ocrRuns = Set((try? PDFComparison.ocrRunIndices(pageID: pageID, in: graph)) ?? [])
    var digitalLineCount = 0
    var generatedLineCount = 0
    var digitalBounds: [[Double]] = []
    var generatedBounds: [[Double]] = []
    if let layout {
      for range in layout.lines {
        let clusters = range.compactMap { index -> TextCluster? in
          let cluster = layout.clusters[index]
          return cluster.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : cluster
        }
        guard !clusters.isEmpty else { continue }
        let isGenerated = clusters.allSatisfy { ocrRuns.contains($0.runIndex) }
        if isGenerated {
          generatedLineCount += 1
          generatedBounds.append(unionBounds(clusters.map(\.bounds)))
        } else {
          digitalLineCount += 1
        }
      }
      digitalBounds = digitalLineBounds(layout: layout, ocrRuns: ocrRuns)
    }
    let placements = (try? ImageInventory.placements(in: graph, pageID: pageID)) ?? []
    var regions: [OCRBoundedRegion] = []
    var imageRects: [[Double]] = []
    for (imageIndex, placement) in placements.enumerated() {
      let clipped = clip(placement.bounds, to: box)
      guard let clipped else { continue }
      imageRects.append(clipped)
      regions.append(OCRBoundedRegion(rect: clipped, imageIndex: imageIndex))
    }
    let coverage = unionArea(imageRects, in: box) / max(1, area(box))
    if regions.isEmpty, generatedLineCount > 0, !generatedBounds.isEmpty {
      // A generated layer on a vector page can still be re-recognized within
      // its existing layer bounds; the chosen layer is the only region touched.
      regions = [OCRBoundedRegion(rect: unionBounds(generatedBounds), imageIndex: -1)]
    }
    let kind: OCRMixedPageKind
    if generatedLineCount > 0 {
      kind = digitalLineCount > 0 ? .mixedWithGeneratedLayer : .scannedGeneratedLayer
    } else if digitalLineCount > 0, !imageRects.isEmpty,
      coverage >= options.minimumScanCoverage
    {
      kind = .mixedDigitalAndScan
    } else if digitalLineCount > 0 {
      kind = .digitalTextOnly
    } else if !imageRects.isEmpty {
      kind = .scannedNoText
    } else {
      kind = .blank
    }
    var action: OCRMixedPageAction
    var skipReason: String?
    switch kind {
    case .scannedGeneratedLayer, .mixedWithGeneratedLayer:
      if options.replaceExistingGeneratedLayers, !regions.isEmpty {
        action = .replaceGeneratedLayer
      } else if !options.replaceExistingGeneratedLayers {
        action = .skip
        skipReason = "a generated layer is present and replacement is disabled"
      } else {
        action = .skip
        skipReason = "no scan bounds are available for a bounded layer"
      }
    case .scannedNoText:
      if regions.isEmpty {
        action = .skip
        skipReason = "no scan image evidence"
      } else {
        action = .addBoundedLayer
      }
    case .mixedDigitalAndScan:
      if !options.allowBoundedLayersOnMixedPages {
        action = .skip
        skipReason = "mixed pages are excluded by the current policy"
      } else if regions.isEmpty {
        action = .skip
        skipReason = "no scan-only region could be bounded"
      } else {
        action = .addBoundedLayer
      }
    case .digitalTextOnly:
      action = .skip
      skipReason = "page already has selectable digital text"
    case .blank:
      action = .skip
      skipReason = "no scan image or text evidence"
    }
    return OCRMixedPageProfile(
      pageID: pageID, pageIndex: pageIndex, kind: kind, action: action,
      skipReason: skipReason, digitalLineCount: digitalLineCount,
      generatedLineCount: generatedLineCount, imageCount: imageRects.count,
      scanCoverage: coverage, boundedRegions: regions,
      existingLayerLineCount: generatedLineCount, pageBox: box,
      digitalLineBounds: digitalBounds)
  }

  /// Digital text line bounds with a conservative width estimate when a
  /// producer (for example an added-content run) reports no advance width.
  /// Without the estimate a zero-width bounds rectangle would let a recognized
  /// line duplicate selectable text.
  static func digitalLineBounds(
    layout: PageTextLayout, ocrRuns: Set<Int>
  ) -> [[Double]] {
    var bounds: [[Double]] = []
    for range in layout.lines {
      let clusters = range.compactMap { index -> TextCluster? in
        let cluster = layout.clusters[index]
        guard !cluster.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !ocrRuns.contains(cluster.runIndex)
        else { return nil }
        return cluster
      }
      guard !clusters.isEmpty else { continue }
      var lineBounds = unionBounds(clusters.map(\.bounds))
      let characterCount = clusters.reduce(0) { $0 + $1.text.count }
      let fontSize = clusters.map(\.fontSize).max() ?? 12
      let estimatedWidth = Double(max(1, characterCount)) * max(1, fontSize) * 0.5
      if lineBounds[2] - lineBounds[0] < 1 {
        lineBounds[2] = lineBounds[0] + max(1, estimatedWidth)
      }
      if lineBounds[3] - lineBounds[1] < 1 {
        lineBounds[3] = lineBounds[1] + max(1, fontSize)
      }
      bounds.append(lineBounds)
    }
    return bounds
  }

  static func pageBox(pageID: PDFObjectID, in graph: PDFGraph) -> [Double] {
    let attributes = PDFDocumentInventory.pageAttributes(pageIDs: [pageID], in: graph)
    guard let attribute = attributes.first else { return [0, 0, 612, 792] }
    let crop = attribute.cropBox
    if crop.count == 4, crop[2] > crop[0], crop[3] > crop[1] { return crop }
    return attribute.mediaBox
  }

  static func area(_ rect: [Double]) -> Double {
    guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else { return 0 }
    return (rect[2] - rect[0]) * (rect[3] - rect[1])
  }

  static func unionBounds(_ bounds: [[Double]]) -> [Double] {
    guard let first = bounds.first else { return [0, 0, 0, 0] }
    var union = first
    for rect in bounds.dropFirst() {
      guard rect.count == 4 else { continue }
      union = [
        min(union[0], rect[0]), min(union[1], rect[1]),
        max(union[2], rect[2]), max(union[3], rect[3]),
      ]
    }
    return union
  }

  static func contains(_ outer: [Double], _ inner: [Double]) -> Bool {
    guard outer.count == 4, inner.count == 4 else { return false }
    let tolerance = 0.5
    return inner[0] >= outer[0] - tolerance && inner[1] >= outer[1] - tolerance
      && inner[2] <= outer[2] + tolerance && inner[3] <= outer[3] + tolerance
  }

  static func clip(_ rect: [Double], to box: [Double]) -> [Double]? {
    guard rect.count == 4, box.count == 4 else { return nil }
    let clipped = [
      max(rect[0], box[0]), max(rect[1], box[1]),
      min(rect[2], box[2]), min(rect[3], box[3]),
    ]
    guard clipped[2] > clipped[0], clipped[3] > clipped[1] else { return nil }
    return clipped
  }

  /// Overlap area divided by the line area.
  static func overlapRatio(_ rect: [Double], _ others: [[Double]]) -> Double {
    let lineArea = area(rect)
    guard lineArea > 0 else { return 0 }
    var covered = 0.0
    for other in others {
      guard other.count == 4 else { continue }
      let intersection = [
        max(rect[0], other[0]), max(rect[1], other[1]),
        min(rect[2], other[2]), min(rect[3], other[3]),
      ]
      covered += area(intersection)
    }
    return min(1, covered / lineArea)
  }

  /// Exact union area of axis-aligned rectangles clipped to a page box.
  static func unionArea(_ rects: [[Double]], in box: [Double]) -> Double {
    let clipped = rects.compactMap { clip($0, to: box) }
    guard !clipped.isEmpty else { return 0 }
    var xs = Set<Double>()
    for rect in clipped {
      xs.insert(rect[0]); xs.insert(rect[2])
    }
    let sortedX = xs.sorted()
    var total = 0.0
    for index in 0..<(sortedX.count - 1) {
      let x0 = sortedX[index]
      let x1 = sortedX[index + 1]
      guard x1 > x0 else { continue }
      var intervals: [(Double, Double)] = []
      for rect in clipped where rect[0] < x1 && rect[2] > x0 {
        intervals.append((rect[1], rect[3]))
      }
      guard !intervals.isEmpty else { continue }
      intervals.sort { $0.0 < $1.0 }
      var covered = 0.0
      var start = intervals[0].0
      var end = intervals[0].1
      for interval in intervals.dropFirst() {
        if interval.0 <= end {
          end = max(end, interval.1)
        } else {
          covered += end - start
          start = interval.0
          end = interval.1
        }
      }
      covered += end - start
      total += (x1 - x0) * covered
    }
    return total
  }
}

/// OCR-06: the plan for a set of pages, with the recognized-page indexes and
/// the pages whose existing generated layer must be replaced.
public struct OCRMixedPagePlan: Sendable, Equatable {
  public let profiles: [OCRMixedPageProfile]

  public init(profiles: [OCRMixedPageProfile]) {
    self.profiles = profiles
  }

  public var ocrPageIndexes: [Int] {
    profiles.filter { $0.action == .addBoundedLayer }.map(\.pageIndex)
  }

  public var replacingPageIndexes: [Int] {
    profiles.filter { $0.action == .replaceGeneratedLayer }.map(\.pageIndex)
  }

  public var skipped: [OCRMixedPageProfile] {
    profiles.filter { $0.action == .skip }
  }

  public var hasWork: Bool { !ocrPageIndexes.isEmpty || !replacingPageIndexes.isEmpty }

  public var summaryLines: [String] {
    var lines: [String] = []
    lines.append(
      "Mixed-page plan: \(profiles.count) page(s); \(ocrPageIndexes.count) new bounded "
        + "layer(s); \(replacingPageIndexes.count) generated layer replacement(s); "
        + "\(skipped.count) skipped.")
    for profile in profiles { lines.append(profile.summaryLine) }
    return lines
  }
}

// MARK: - Bounded layer command

/// OCR-06: add a generated searchable text layer that is explicitly bounded to
/// scan image regions on a page that may already show selectable digital text.
/// The command never changes pixels, page geometry, image placements or
/// existing digital text: it only appends an invisible marked layer (or
/// replaces the page's existing generated layer first). Lines that overlap
/// existing selectable text or fall outside the bounds are refused.
public struct AddBoundedSearchableTextLayerCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let lines: [SearchableTextLine]
  /// Page-space rectangles that bound the layer. At least one line must fall
  /// inside one of these regions.
  public let boundedRegions: [[Double]]
  /// Replace the page's existing generated layer instead of refusing.
  public let replaceExistingLayer: Bool

  public init(
    pageID: PDFObjectID, lines: [SearchableTextLine], boundedRegions: [[Double]],
    replaceExistingLayer: Bool = false
  ) {
    self.pageID = pageID
    self.lines = lines
    self.boundedRegions = boundedRegions
    self.replaceExistingLayer = replaceExistingLayer
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Add Bounded Searchable Text" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !lines.isEmpty else {
      throw PDFError(.malformed, "A bounded searchable text layer needs at least one line")
    }
    guard !boundedRegions.isEmpty else {
      throw PDFError(.malformed, "A bounded searchable text layer needs explicit bounds")
    }
    for region in boundedRegions {
      guard region.count == 4, region.allSatisfy(\.isFinite),
        region[2] > region[0], region[3] > region[1]
      else {
        throw PDFError(.malformed, "A bounded OCR region is invalid")
      }
    }
    let box = OCRMixedPagePlanner.pageBox(pageID: pageID, in: graph)
    for line in lines {
      guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        line.rect.count == 4, line.rect.allSatisfy(\.isFinite),
        line.rect[2] > line.rect[0], line.rect[3] > line.rect[1]
      else {
        throw PDFError(.malformed, "Searchable text line geometry or text is invalid")
      }
      guard line.text.unicodeScalars.allSatisfy({ $0.value < 0x10000 }) else {
        throw PDFError(.unsupported, "Searchable text beyond the BMP is not supported yet")
      }
      guard OCRMixedPagePlanner.contains(box, line.rect) else {
        throw PDFError(.malformed, "A searchable text line is outside the page")
      }
      guard
        boundedRegions.contains(where: {
          OCRMixedPagePlanner.overlapRatio(line.rect, [$0]) >= 0.5
        })
      else {
        throw PDFError(.malformed, "A searchable text line is outside the bounded scan regions")
      }
    }
    let placements = (try? ImageInventory.placements(in: graph, pageID: pageID)) ?? []
    let hasLayer = OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID)
    let layout = try? PageTextLayout.build(pageID: pageID, in: graph)
    let ocrRuns = Set(
      (try? PDFComparison.ocrRunIndices(pageID: pageID, in: graph)) ?? [])
    let digitalBounds: [[Double]] = layout.map {
      OCRMixedPagePlanner.digitalLineBounds(layout: $0, ocrRuns: ocrRuns)
    } ?? []
    for line in lines {
      if OCRMixedPagePlanner.overlapRatio(line.rect, digitalBounds) > 0.25 {
        throw PDFError(
          .unsupported,
          "A searchable text line overlaps selectable digital text; the layer would duplicate it")
      }
    }
    if hasLayer {
      guard replaceExistingLayer else {
        throw PDFError(.unsupported, "This page already has a generated searchable text layer")
      }
    } else {
      guard replaceExistingLayer == false else {
        throw PDFError(.malformed, "There is no generated layer to replace")
      }
      guard !placements.isEmpty else {
        throw PDFError(
          .unsupported,
          "A bounded layer needs scan image evidence; the page has no image placements")
      }
    }
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 6
    guard next <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for the bounded searchable text layer")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    if replaceExistingLayer {
      try OCRLayer.removeLayer(pageID: pageID, in: &graph)
    }
    // Reuse the audited layer writer; replaceExistingLayer is false here so
    // never a second layer can be added.
    return try AddSearchableTextLayerCommand(
      pageID: pageID, lines: lines, replacingExistingLayer: false
    ).apply(to: graph)
  }
}
