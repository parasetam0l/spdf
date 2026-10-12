import Foundation
import PDFCore

/// P16-014: formatting-preserving copy for supported text. The rich-text
/// form carries exactly the styling the profile tracks — the run's font
/// family, size, and fill color — inside a minimal RTF document; anything
/// the profile does not model (links, images, tables, kerning pairs) is
/// deliberately not claimed. Text that the layout cannot decode yields nil
/// so callers fall back to plain text instead of guessing.
public enum StyledTextCopy {
  public struct StyledRun: Sendable, Equatable {
    public let text: String
    public let fontFamily: String
    public let fontSize: Double
    public let color: [Double]

    public init(text: String, fontFamily: String, fontSize: Double, color: [Double]) {
      self.text = text
      self.fontFamily = fontFamily
      self.fontSize = fontSize
      self.color = color
    }
  }

  /// Styled runs for a cluster range, grouping consecutive clusters that
  /// share family, size, and color.
  public static func styledRuns(
    pageID: PDFObjectID, range: Range<Int>, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> [StyledRun]? {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    guard range.lowerBound >= 0, range.upperBound <= layout.clusters.count,
      !range.isEmpty
    else { return nil }
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let textRuns = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    var runs: [StyledRun] = []
    for index in range {
      let cluster = layout.clusters[index]
      guard cluster.runIndex >= 0, cluster.runIndex < textRuns.count else { return nil }
      let textRun = textRuns[cluster.runIndex]
      let family: String
      if let font = SimpleFont.resolve(
        resource: textRun.fontResource, page: page, in: graph)
      {
        family = Self.family(font.baseFont)
      } else {
        family = "Helvetica"
      }
      let color = textRun.fillColor
      let size = cluster.fontSize
      if let last = runs.last, last.fontFamily == family, abs(last.fontSize - size) < 0.001,
        zip(last.color, color).allSatisfy({ abs($0 - $1) < 0.001 }), last.color.count == color.count
      {
        runs[runs.count - 1] = StyledRun(
          text: last.text + cluster.text, fontFamily: family, fontSize: size, color: color)
      } else {
        runs.append(StyledRun(text: cluster.text, fontFamily: family, fontSize: size, color: color))
      }
    }
    return runs.isEmpty ? nil : runs
  }

  /// The rich-text form of one run (all its clusters), for selection-driven
  /// copy paths that resolve a run rather than a cluster range.
  public static func richText(
    pageID: PDFObjectID, runIndex: Int, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> String? {
    let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
    let indices = layout.clusters.indices.filter { layout.clusters[$0].runIndex == runIndex }
    guard let first = indices.first, let last = indices.last else { return nil }
    return try richText(pageID: pageID, range: first..<(last + 1), in: graph, limits: limits)
  }

  /// A minimal RTF document for the styled runs, or nil when the range is
  /// empty or undecodable.
  public static func richText(
    pageID: PDFObjectID, range: Range<Int>, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> String? {
    guard let runs = try styledRuns(pageID: pageID, range: range, in: graph, limits: limits),
      !runs.isEmpty
    else { return nil }
    var fontIndex: [String: Int] = [:]
    var fonts: [String] = []
    var colorIndex: [String: Int] = [:]
    var colors: [[Double]] = []
    for run in runs {
      if fontIndex[run.fontFamily] == nil {
        fontIndex[run.fontFamily] = fonts.count
        fonts.append(run.fontFamily)
      }
      let key = colorKey(run.color)
      if colorIndex[key] == nil {
        colorIndex[key] = colors.count + 1  // RTF color 0 is the default
        colors.append(run.color)
      }
    }
    var output = "{\\rtf1\\ansi\\deff0\n{\\fonttbl"
    for (index, family) in fonts.enumerated() {
      output += "{\\f\(index) \(escape(family));}"
    }
    output += "}\n{\\colortbl;"
    for color in colors {
      let rgb = color.count == 3 ? color : [0, 0, 0]
      output += "\\red\(Int((rgb[0] * 255).rounded()))\\green\(Int((rgb[1] * 255).rounded()))\\blue\(Int((rgb[2] * 255).rounded()));"
    }
    output += "}\n"
    for run in runs {
      let font = fontIndex[run.fontFamily] ?? 0
      let color = colorIndex[colorKey(run.color)] ?? 1
      output += "\\f\(font)\\fs\(Int((run.fontSize * 2).rounded()))\\cf\(color) "
      output += escape(run.text)
    }
    output += "}\n"
    return output
  }

  // MARK: - Internals

  static func family(_ baseFont: String) -> String {
    let parts = baseFont.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isUppercase }) {
      return String(parts[1])
    }
    return baseFont.isEmpty ? "Helvetica" : baseFont
  }

  private static func colorKey(_ color: [Double]) -> String {
    let components = color.count == 3 ? color : [0, 0, 0]
    return components.map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
  }

  /// RTF-escape braces and backslashes; non-ASCII scalars as \uN?.
  static func escape(_ text: String) -> String {
    var output = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\\":
        output += "\\\\"
      case "{":
        output += "\\{"
      case "}":
        output += "\\}"
      case "\n":
        output += "\\line "
      default:
        if scalar.value > 127 {
          output += "\\u\(Int(scalar.value))?"
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    return output
  }
}
