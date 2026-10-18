import Foundation
import PDFCore

/// P12-012 text-edit slice: the supported text run a selection touches, so
/// the app can offer whole-run replacement through native text input.
public struct TextRunTarget: Sendable, Equatable {
  public let runIndex: Int
  public let text: String
  /// P18-021: the run's page-space bounds, for an in-place editor.
  public let rect: [Double]?
  /// P15-024: the run's input style for the native editor.
  public let style: TextInputStyle

  public init(runIndex: Int, text: String, rect: [Double]? = nil, style: TextInputStyle) {
    self.runIndex = runIndex
    self.text = text
    self.rect = rect
    self.style = style
  }
}

/// P15-024: the editable text input style resolved from a document run, so
/// the native editor shows the run's own family, size, and color instead of
/// anonymous system defaults.
public struct TextInputStyle: Sendable, Equatable {
  /// BaseFont family, with subset prefixes stripped; nil when the font
  /// dictionary is missing or nameless.
  public let fontFamily: String?
  /// Page-space points.
  public let fontSize: Double
  /// Fill color as RGB components in 0...1 (gray and CMYK already folded to
  /// RGB by the run indexer; default black).
  public let fillColor: [Double]
  /// Nonstroking constant alpha from the run's ExtGState.
  public let opacity: Double

  public init(fontFamily: String?, fontSize: Double, fillColor: [Double], opacity: Double = 1) {
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.fillColor = fillColor
    self.opacity = opacity
  }
}

/// P17-016/P17-017: a selection's stable identity across edits. The identity
/// names the page and run the selection came from; resolving it against the
/// current graph either preserves the selection (same run, possibly new text
/// after an edit through it) or reports it obsolete, with a reason, so the
/// UI can clear it deliberately instead of silently pointing at nothing.
public struct SelectionIdentity: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let runIndex: Int
  /// The run text the identity was captured with (diagnostics and history).
  public let text: String

  public init(pageID: PDFObjectID, runIndex: Int, text: String) {
    self.pageID = pageID
    self.runIndex = runIndex
    self.text = text
  }

  public enum Resolution: Sendable, Equatable {
    /// The same run is still present; its text may have changed.
    case preserved(text: String, rect: [Double]?)
    /// The page or run is gone.
    case obsolete(reason: String)
  }

  public func resolve(in graph: PDFGraph, limits: PDFLimits = PDFLimits()) -> Resolution {
    guard let pages = try? PDFPageTree.pageIDs(in: graph), pages.contains(pageID) else {
      return .obsolete(reason: "The page is no longer in the document")
    }
    guard let layout = try? PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    else {
      return .obsolete(reason: "The page's text could not be read")
    }
    let runClusters = layout.clusters.filter { $0.runIndex == runIndex }
    guard !runClusters.isEmpty else {
      return .obsolete(reason: "The selected run no longer exists on the page")
    }
    let text = runClusters.map(\.text).joined()
    let xs = runClusters.flatMap { [$0.bounds[0], $0.bounds[2]] }
    let ys = runClusters.flatMap { [$0.bounds[1], $0.bounds[3]] }
    return .preserved(text: text, rect: [xs.min()!, ys.min()!, xs.max()!, ys.max()!])
  }
}

public enum TextEditTargeting {
  /// First text run touched by the selection bounds, or nil when the
  /// selection covers no decodable text in the supported profile.
  public static func run(
    atSelectionBounds bounds: [Double], in graph: PDFGraph, pageID: PDFObjectID,
    limits: PDFLimits = PDFLimits()
  ) throws -> TextRunTarget? {
    guard bounds.count == 4, bounds.allSatisfy(\.isFinite) else { return nil }
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    // Probe just inside the left edge at mid height, where the first selected
    // glyph sits for horizontal text.
    let probeX = bounds[0] + 1
    let probeY = (bounds[1] + bounds[3]) / 2
    let clusterIndex: Int?
    if let exact = layout.clusterIndex(at: [probeX, probeY]) {
      clusterIndex = exact
    } else {
      // Conservative metrics (for example a standard-14 font without /Widths)
      // can produce zero-width bounds; fall back to the first cluster on the
      // nearest baseline by horizontal distance, which keeps reading order.
      let onLine = layout.clusters.indices.filter { index in
        let cluster = layout.clusters[index].bounds
        return probeY >= cluster[1] - 1 && probeY <= cluster[3] + 1
      }
      clusterIndex = onLine.min { lhs, rhs in
        let left = horizontalDistance(layout.clusters[lhs].bounds, probeX)
        let right = horizontalDistance(layout.clusters[rhs].bounds, probeX)
        return left == right ? lhs < rhs : left < right
      }
    }
    guard let clusterIndex else { return nil }
    let runIndex = layout.clusters[clusterIndex].runIndex
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    guard runIndex >= 0, runIndex < runs.count else { return nil }
    return TextRunTarget(
      runIndex: runIndex, text: runs[runIndex].text,
      style: Self.inputStyle(runIndex: runIndex, runs: runs, in: graph))
  }

  static func horizontalDistance(_ bounds: [Double], _ x: Double) -> Double {
    if x < bounds[0] { return bounds[0] - x }
    if x > bounds[2] { return x - bounds[2] }
    return 0
  }

  /// P18-021: the supported text run under a page point, with its bounds, so
  /// the app can position a native editor over the run geometry.
  public static func runTarget(
    atPoint point: [Double], in graph: PDFGraph, pageID: PDFObjectID,
    limits: PDFLimits = PDFLimits()
  ) throws -> TextRunTarget? {
    guard point.count == 2, point.allSatisfy(\.isFinite) else { return nil }
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    let exact = layout.clusterIndex(at: point)
    var clusterIndex = exact
    if clusterIndex == nil {
      // Conservative metrics (a standard-14 font without /Widths) can produce
      // zero-width bounds; fall back to the nearest cluster on the baseline.
      let onLine = layout.clusters.indices.filter { index in
        let bounds = layout.clusters[index].bounds
        return point[1] >= bounds[1] - 1 && point[1] <= bounds[3] + 1
      }
      clusterIndex = onLine.min { lhs, rhs in
        let left = horizontalDistance(layout.clusters[lhs].bounds, point[0])
        let right = horizontalDistance(layout.clusters[rhs].bounds, point[0])
        return left == right ? lhs < rhs : left < right
      }
    }
    guard let clusterIndex else { return nil }
    let runIndex = layout.clusters[clusterIndex].runIndex
    let runClusters = layout.clusters.filter { $0.runIndex == runIndex }
    guard let rect = union(runClusters.map(\.bounds)) else { return nil }
    if exact == nil {
      // Bound the fallback by an estimated run width so clicks far away on
      // the same baseline do not open an editor.
      let fontSize = layout.clusters[clusterIndex].fontSize
      let estimatedWidth = Double(runClusters.count) * fontSize * 0.55
      guard point[0] >= rect[0] - fontSize,
        point[0] <= rect[0] + estimatedWidth + fontSize
      else { return nil }
    }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    guard runIndex >= 0, runIndex < runs.count else { return nil }
    return TextRunTarget(
      runIndex: runIndex, text: runs[runIndex].text, rect: rect,
      style: Self.inputStyle(runIndex: runIndex, runs: runs, in: graph))
  }

  /// P15-024: resolve a run's input style: its page-space size, its
  /// RGB-folded fill color, and its BaseFont family (subset prefixes
  /// stripped, like the inventory's family name) when resolvable.
  static func inputStyle(runIndex: Int, runs: [TextRun], in graph: PDFGraph) -> TextInputStyle {
    let run = runs[runIndex]
    var family: String? = nil
    if case .dictionary(let fontDict)? = graph.objects[run.fontID],
      case .name(let base)? = fontDict[PDFName("BaseFont")]
    {
      let name = String(decoding: base.bytes, as: UTF8.self)
      if !name.isEmpty {
        let parts = name.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isUppercase }) {
          family = String(parts[1])
        } else {
          family = name
        }
      }
    }
    return TextInputStyle(
      fontFamily: family, fontSize: run.fontSize, fillColor: run.fillColor,
      opacity: run.fillAlpha)
  }

  static func union(_ bounds: [[Double]]) -> [Double]? {
    guard !bounds.isEmpty else { return nil }
    let xs = bounds.flatMap { [$0[0], $0[2]] }
    let ys = bounds.flatMap { [$0[1], $0[3]] }
    return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
  }
}
