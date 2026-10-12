import Foundation
import PDFCore

/// P19-018: cross-page reflow for *explicitly declared* regions only. A region
/// is an ordered list of page paragraphs (for example a continued article); the
/// text is filled page by page up to each box's capacity and the remainder
/// either overflows the last page (with `.allow`) or is reported so the caller
/// can extend the region.
public struct ParagraphRegionPage: Sendable, Equatable {
  public let pageID: PDFObjectID
  public let candidate: TextParagraphCandidate

  public init(pageID: PDFObjectID, candidate: TextParagraphCandidate) {
    self.pageID = pageID
    self.candidate = candidate
  }
}

public struct CrossPageReflowPlan: Sendable, Equatable {
  public struct PagePlan: Sendable, Equatable {
    public let pageID: PDFObjectID
    public let candidate: TextParagraphCandidate
    /// The text assigned to this page (words consumed here).
    public let text: String
    public let lines: [ReflowLine]
    public let overflowed: Bool
  }

  public let pages: [PagePlan]
  /// Non-empty when the region could not take all the text (`.clip`/refusal).
  public let remainingText: String
}

public enum CrossPageReflow {
  public static func plan(
    region: [ParagraphRegionPage], replacement: String, in graph: PDFGraph,
    options: ParagraphReflowOptions = .init()
  ) throws -> CrossPageReflowPlan {
    guard !region.isEmpty else {
      throw PDFError(.malformed, "The region has no pages")
    }
    guard options.overflow != .shrinkToFit else {
      throw PDFError(.unsupported, "Cross-page regions do not support shrink-to-fit yet")
    }
    // One style across the region keeps the flow predictable.
    guard let firstStyle = region[0].candidate.runStyles.first else {
      throw PDFError(.unsupported, "The region's first page has no style information")
    }
    for page in region.dropFirst() {
      guard let style = page.candidate.runStyles.first,
        style.fontResource == firstStyle.fontResource,
        abs(style.fontSize - firstStyle.fontSize) < 0.1
      else {
        throw PDFError(.unsupported, "Cross-page regions need one font and size")
      }
    }

    var remaining = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    var pagePlans: [CrossPageReflowPlan.PagePlan] = []
    for page in region {
      let context = try ParagraphReflow.context(
        pageID: page.pageID, candidate: page.candidate, in: graph)
      let box = page.candidate.bounds
      let boxWidth = max(24, box[2] - box[0])
      let boxHeight = max(page.candidate.fontSize, box[3] - box[1])
      let size = page.candidate.runStyles.first?.fontSize ?? page.candidate.fontSize
      let spacing = options.lineSpacing ?? max(page.candidate.lineSpacing, size * 1.05)
      let capacity = max(
        page.candidate.lineIndices.count,
        Int(floor((boxHeight - size * 0.2) / spacing)) + 1)
      let filled = ParagraphReflow.wrapFilling(
        remaining, width: boxWidth, context: context, capacity: capacity)
      let text = filled.lines.map { line in line.map(\.text).joined(separator: " ") }
        .joined(separator: " ")
      let pageOptions = pageOptions(from: options)
      let plan = try ParagraphReflow.plan(
        pageID: page.pageID, candidate: page.candidate, replacement: text, in: graph,
        options: pageOptions).plan
      // Words actually consumed here (punctuation may re-attach to a line).
      let consumed = plan.lines.map(\.text).joined(separator: " ")
        .split(separator: " ").count
      let words = remaining.split(separator: " ")
      remaining = words.dropFirst(min(consumed, words.count)).joined(separator: " ")
      pagePlans.append(
        CrossPageReflowPlan.PagePlan(
          pageID: page.pageID, candidate: page.candidate, text: text, lines: plan.lines,
          overflowed: false))
    }

    if !remaining.isEmpty, options.overflow == .allow, let last = region.last {
      // The remainder overflows the last page explicitly.
      let fullText = [pagePlans.last?.text ?? "", remaining]
        .filter { !$0.isEmpty }.joined(separator: " ")
      let plan = try ParagraphReflow.plan(
        pageID: last.pageID, candidate: last.candidate, replacement: fullText, in: graph,
        options: pageOptions(from: options)).plan
      pagePlans[pagePlans.count - 1] = CrossPageReflowPlan.PagePlan(
        pageID: last.pageID, candidate: last.candidate, text: fullText, lines: plan.lines,
        overflowed: true)
      remaining = ""
    }
    return CrossPageReflowPlan(pages: pagePlans, remainingText: remaining)
  }

  static func pageOptions(from options: ParagraphReflowOptions) -> ParagraphReflowOptions {
    ParagraphReflowOptions(
      alignment: options.alignment, firstLineIndent: options.firstLineIndent,
      lineSpacing: options.lineSpacing, overflow: .allow,
      allowCollisions: options.allowCollisions, allowLowConfidence: true)
  }
}

/// P19-018: apply a declared cross-page region, one page at a time.
public struct CrossPageReflowCommand: PDFEditCommand, Equatable, Sendable {
  public let region: [ParagraphRegionPage]
  public let replacement: String
  public let options: ParagraphReflowOptions

  public init(
    region: [ParagraphRegionPage], replacement: String,
    options: ParagraphReflowOptions = .init()
  ) {
    self.region = region
    self.replacement = replacement
    self.options = options
  }

  public var name: String { "Reflow Cross-Page Region" }

  public func validate(in graph: PDFGraph) throws {
    let plan = try CrossPageReflow.plan(
      region: region, replacement: replacement, in: graph, options: options)
    if !plan.remainingText.isEmpty {
      throw PDFError(
        .unsupported,
        "The region is too small for the replacement; extend it or allow overflow")
    }
    for page in plan.pages {
      try ReflowParagraphCommand(
        pageID: page.pageID, candidate: page.candidate, replacement: page.text,
        options: CrossPageReflow.pageOptions(from: options)
      ).validate(in: graph)
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let plan = try CrossPageReflow.plan(
      region: region, replacement: replacement, in: graph, options: options)
    guard plan.remainingText.isEmpty else {
      throw PDFError(
        .unsupported,
        "The region is too small for the replacement; extend it or allow overflow")
    }
    var graph = graph
    for page in plan.pages {
      graph = try ReflowParagraphCommand(
        pageID: page.pageID, candidate: page.candidate, replacement: page.text,
        options: CrossPageReflow.pageOptions(from: options)
      ).apply(to: graph)
    }
    return graph
  }
}
