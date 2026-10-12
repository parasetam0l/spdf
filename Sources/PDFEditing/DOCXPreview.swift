import Foundation

/// P35-022: a bounded, read-only preview of a DOCX reconstruction so an
/// ambiguous reading order can be reviewed before exporting. The preview never
/// changes the reconstruction and never touches the source document.
public struct DOCXPreview: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    /// 1-based page number derived from the deliberate breaks.
    public let pageNumber: Int
    /// A short kind label such as `heading1`, `paragraph`, or `table 2×2`.
    public let kind: String
    /// The block's text, newlines flattened and bounded to a snippet.
    public let text: String
    /// True when the block's confidence is below the ambiguity threshold.
    public let ambiguous: Bool

    public init(pageNumber: Int, kind: String, text: String, ambiguous: Bool) {
      self.pageNumber = pageNumber
      self.kind = kind
      self.text = text
      self.ambiguous = ambiguous
    }
  }

  public let entries: [Entry]
  public let limitations: [String]
  public let ambiguousCount: Int
  public let totalCount: Int
  /// True when the block list exceeded the preview bound.
  public let truncated: Bool

  /// Bounds: at most 2,000 entries with 80-character snippets.
  public static let maxEntries = 2_000
  public static let snippetLength = 80
  /// The same gate the paragraph profile uses for uncertain content.
  public static let ambiguousThreshold = 0.6

  public init(
    entries: [Entry], limitations: [String], ambiguousCount: Int, totalCount: Int,
    truncated: Bool
  ) {
    self.entries = entries
    self.limitations = limitations
    self.ambiguousCount = ambiguousCount
    self.totalCount = totalCount
    self.truncated = truncated
  }

  public static func build(reconstruction: DOCXReconstruction) -> DOCXPreview {
    var entries: [Entry] = []
    var page = 1
    var truncated = false
    for block in reconstruction.blocks {
      switch block.kind {
      case .pageBreak, .sectionBreak:
        page += 1
        continue
      default:
        break
      }
      if entries.count >= maxEntries {
        truncated = true
        break
      }
      let kind: String
      switch block.kind {
      case .heading(let level):
        kind = "heading\(min(max(level, 1), 6))"
      case .listItem(_, let ordered):
        kind = ordered ? "ordered-list" : "bullet-list"
      case .table(let rows):
        kind = "table \(rows.count)×\(rows.first?.count ?? 0)"
      case .image(let request):
        kind = request.isAppearance ? "appearance" : "image"
      case .paragraph:
        kind = "paragraph"
      case .pageBreak, .sectionBreak:
        kind = "break"
      }
      let raw: String
      switch block.kind {
      case .table(let rows):
        raw = rows.flatMap { $0 }.flatMap { $0 }.map(\.text).joined(separator: " | ")
      case .image:
        raw = block.text.isEmpty ? "(image)" : block.text
      default:
        raw = block.text
      }
      let flattened = raw.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
      entries.append(
        Entry(
          pageNumber: page, kind: kind,
          text: String(flattened.prefix(snippetLength)),
          ambiguous: block.confidence < ambiguousThreshold))
    }
    return DOCXPreview(
      entries: entries, limitations: reconstruction.limitations,
      ambiguousCount: entries.filter(\.ambiguous).count, totalCount: reconstruction.blocks.count,
      truncated: truncated)
  }

  /// A human-readable preview for a panel or a log.
  public func text() -> String {
    var lines: [String] = []
    lines.append(
      "DOCX reconstruction preview — \(totalCount) block\(totalCount == 1 ? "" : "s"), "
        + "\(ambiguousCount) ambiguous")
    var currentPage = 0
    for entry in entries {
      if entry.pageNumber != currentPage {
        currentPage = entry.pageNumber
        lines.append("")
        lines.append("Page \(currentPage)")
      }
      lines.append(
        "  [\(entry.kind)] \(entry.text)\(entry.ambiguous ? "   ⚠ ambiguous" : "")")
    }
    if truncated {
      lines.append("")
      lines.append("… preview truncated at \(Self.maxEntries) blocks")
    }
    if !limitations.isEmpty {
      lines.append("")
      lines.append("Limitations:")
      for limitation in limitations {
        lines.append("  - \(limitation)")
      }
    }
    return lines.joined(separator: "\n")
  }
}
