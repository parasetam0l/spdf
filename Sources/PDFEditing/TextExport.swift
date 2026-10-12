import Foundation
import PDFCore

/// P34-001/P34-002/P34-025: plain-text export in page reading order with
/// explicit encoding, line-ending, and page-separator choices. The text comes
/// from the owned layout engine (font-decoded Unicode), not from a renderer.
public struct PDFTextExportOptions: Sendable, Equatable {
  public enum LineEnding: Sendable, Equatable {
    case lf
    case crlf
  }

  public enum Encoding: Sendable, Equatable {
    case utf8
    case utf16
  }

  public enum PageSeparator: Sendable, Equatable {
    case formFeed
    case blankLine
    case none
  }

  public var lineEnding: LineEnding
  public var encoding: Encoding
  public var pageSeparator: PageSeparator

  public init(
    lineEnding: LineEnding = .lf, encoding: Encoding = .utf8,
    pageSeparator: PageSeparator = .formFeed
  ) {
    self.lineEnding = lineEnding
    self.encoding = encoding
    self.pageSeparator = pageSeparator
  }

  var newline: String { lineEnding == .crlf ? "\r\n" : "\n" }
}

public enum PDFTextExport {
  /// Whole pages in document order; each page's lines follow the layout
  /// engine's reading order (baseline groups top to bottom, left to right).
  public static func plainText(
    pageIDs: [PDFObjectID], in graph: PDFGraph, options: PDFTextExportOptions = .init()
  ) throws -> Data {
    var pages: [String] = []
    for pageID in pageIDs {
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      pages.append(text(of: layout.clusters, options: options))
    }
    let separator: String
    switch options.pageSeparator {
    case .formFeed: separator = "\u{0C}"
    case .blankLine: separator = options.newline + options.newline
    case .none: separator = options.newline
    }
    return encode(pages.joined(separator: separator), options: options)
  }

  /// Selected text (for example a viewer selection) in reading order.
  public static func plainText(
    clusters: [TextCluster], options: PDFTextExportOptions = .init()
  ) -> Data {
    encode(text(of: clusters, options: options), options: options)
  }

  /// Reading order over any cluster set: baseline groups top to bottom, then
  /// left to right inside each line.
  static func text(of clusters: [TextCluster], options: PDFTextExportOptions) -> String {
    let meaningful = clusters.filter { !$0.text.isEmpty }
    guard !meaningful.isEmpty else { return "" }
    var lines: [[TextCluster]] = []
    for cluster in meaningful.sorted(by: { $0.origin[1] > $1.origin[1] }) {
      let tolerance = max(1, 0.3 * cluster.fontSize)
      if let index = lines.firstIndex(where: { line in
        guard let first = line.first else { return false }
        return abs(first.origin[1] - cluster.origin[1]) <= max(tolerance, 0.3 * first.fontSize)
      }) {
        lines[index].append(cluster)
      } else {
        lines.append([cluster])
      }
    }
    return lines.map { line in
      line.sorted { $0.bounds[0] < $1.bounds[0] }.map(\.text).joined()
    }.joined(separator: options.newline)
  }

  /// Encode arbitrary text (for example a viewer selection) with the same
  /// explicit encoding policy as whole-document exports.
  public static func encoded(_ text: String, options: PDFTextExportOptions = .init()) -> Data {
    encode(text, options: options)
  }

  static func encode(_ text: String, options: PDFTextExportOptions) -> Data {
    switch options.encoding {
    case .utf8:
      return Data(text.utf8)
    case .utf16:
      // String.data(using: .utf16) writes a little-endian byte order mark.
      return text.data(using: .utf16) ?? Data(text.utf8)
    }
  }
}
