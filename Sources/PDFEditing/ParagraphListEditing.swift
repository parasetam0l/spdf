import Foundation
import PDFCore

/// TXT-05: operations over a reconstructed bullet or numbered list. Every
/// operation returns commands for one PDF transaction, so marker/body changes
/// are one Undo step and follow the normal Save/reopen path.
public enum ParagraphListOperation: Sendable, Equatable {
  case switchToBullet
  case switchToNumbered
  /// Restart numbering at the selected item, leaving earlier items untouched.
  case restartNumbering(start: Int)
  /// Continue from the previous item's marker at the selected item.
  case continueNumbering
  case indent
  case outdent
  /// Insert a marker-only item after the selected item and move the rest down.
  case addItemAfter
  /// Remove the selected item and move the rest up.
  case removeItem
}

public enum ParagraphListEditing {
  public static func commands(
    pageID: PDFObjectID, list: TextListCandidate, itemIndex: Int,
    operation: ParagraphListOperation, in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    guard itemIndex >= 0, itemIndex < list.items.count else {
      throw PDFError(.malformed, "The selected list item is no longer available")
    }
    switch operation {
    case .switchToBullet:
      return renumberCommands(
        pageID: pageID, list: list, from: 0,
        style: ParagraphListStyle(kind: .bullet, bullet: "-"), in: graph)
    case .switchToNumbered:
      return renumberCommands(
        pageID: pageID, list: list, from: 0,
        style: ParagraphListStyle(
          kind: .ordered, format: .arabic, separator: ".", start: 1),
        in: graph)
    case .restartNumbering(let start):
      var style = list.style
      if style.kind == .bullet {
        style = ParagraphListStyle(
          kind: .ordered, format: .arabic, separator: ".", start: max(1, start))
      } else {
        style = ParagraphListStyle(
          kind: .ordered, format: style.format ?? .arabic,
          separator: style.separator ?? ".", start: max(1, start))
      }
      return renumberCommands(
        pageID: pageID, list: list, from: itemIndex, style: style, in: graph)
    case .continueNumbering:
      var style = list.style
      let previousValue: Int
      if itemIndex > 0 {
        let previous = list.items[itemIndex - 1]
        previousValue =
          ParagraphListReconstruction.marker(
            in: "\(previous.marker) placeholder")?.style.start
          ?? (style.start + itemIndex - 1)
      } else {
        previousValue = style.start - 1
      }
      style = ParagraphListStyle(
        kind: style.kind, bullet: style.bullet, format: style.format,
        separator: style.separator, start: max(1, previousValue + 1))
      return renumberCommands(
        pageID: pageID, list: list, from: itemIndex, style: style, in: graph)
    case .indent, .outdent:
      let delta = operation == .indent ? 18.0 : -18.0
      let candidate = list.items[itemIndex].candidate
      return candidate.runIndices.map {
        MoveTextCommand(pageID: pageID, runIndex: $0, dx: delta, dy: 0)
      }
    case .addItemAfter:
      return try addCommands(
        pageID: pageID, list: list, itemIndex: itemIndex, in: graph)
    case .removeItem:
      return try removeCommands(
        pageID: pageID, list: list, itemIndex: itemIndex, in: graph)
    }
  }

  private static func renumberCommands(
    pageID: PDFObjectID, list: TextListCandidate, from startIndex: Int,
    style: ParagraphListStyle, in graph: PDFGraph
  ) -> [any PDFEditCommand] {
    guard startIndex < list.items.count else { return [] }
    return list.items.indices.reversed().compactMap { index in
      guard index >= startIndex else { return nil }
      let item = list.items[index]
      let marker = style.marker(for: index - startIndex)
      let separator = style.kind == .ordered ? (style.separator ?? ".") : ""
      let replacement = "\(marker)\(separator) \(item.text)"
      return ReflowParagraphCommand(
        pageID: pageID, candidate: item.candidate.expandedHorizontally(by: 18),
        replacement: replacement,
        options: ParagraphReflowOptions(allowLowConfidence: true))
    }
  }

  private static func addCommands(
    pageID: PDFObjectID, list: TextListCandidate, itemIndex: Int,
    in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    guard let selected = list.items[itemIndex].candidate.runIndices.first else {
      throw PDFError(.unsupported, "The selected list item has no text runs")
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    guard selected >= 0, selected < runs.count else {
      throw PDFError(.malformed, "The selected list item changed")
    }
    let selectedCandidate = list.items[itemIndex].candidate
    let spacing = max(
      selectedCandidate.lineSpacing,
      selectedCandidate.fontSize * 1.2)
    var commands: [any PDFEditCommand] = []
    // Shift following items first, bottom-up, so original run indices remain
    // valid for each reflow command.
    for index in list.items.indices.reversed() where index > itemIndex {
      let item = list.items[index]
      let shifted = item.candidate
        .shiftedVertically(by: -spacing)
        .expandedHorizontally(by: 18)
      let marker = list.style.marker(for: index + 1)
      let separator = list.style.kind == .ordered ? (list.style.separator ?? ".") : ""
      commands.append(
        ReflowParagraphCommand(
          pageID: pageID, candidate: shifted,
          replacement: "\(marker)\(separator) \(item.text)",
          options: ParagraphReflowOptions(
            allowCollisions: true, allowLowConfidence: true)))
    }
    let newIndex = itemIndex + 1
    let marker = list.style.marker(for: newIndex)
    let separator = list.style.kind == .ordered ? (list.style.separator ?? ".") : ""
    let text = "\(marker)\(separator) New item"
    let color = selectedCandidate.runStyles.first?.fillColor ?? [0, 0, 0]
    let format = PageTextFormat(
      font: .helvetica, size: max(4, min(144, selectedCandidate.fontSize)),
      color: color)
    let x = selectedCandidate.bounds[0]
    let width = max(24, selectedCandidate.bounds[2] - x + 18)
    let line = PageTextLine(
      text: text, x: x,
      baseline: selectedCandidate.bounds[1] + selectedCandidate.fontSize * 0.2 - spacing,
      segments: [PageTextSegment(text: text, x: x, format: format)],
      endsParagraph: true)
    commands.append(
      AddPageTextLinesCommand(
        pageID: pageID, lines: [line],
        box: PageTextBox(
          x: x,
          firstBaseline: line.baseline,
          width: width,
          lineSpacing: spacing,
          wraps: true)))
    return commands
  }

  private static func removeCommands(
    pageID: PDFObjectID, list: TextListCandidate, itemIndex: Int,
    in graph: PDFGraph
  ) throws -> [any PDFEditCommand] {
    var commands: [any PDFEditCommand] = []
    for index in list.items.indices.reversed() where index > itemIndex {
      let item = list.items[index]
      let shifted = item.candidate
        .shiftedVertically(by: max(item.candidate.lineSpacing, item.candidate.fontSize * 1.2))
        .expandedHorizontally(by: 18)
      let newIndex = index - 1
      let marker = list.style.marker(for: newIndex)
      let separator = list.style.kind == .ordered ? (list.style.separator ?? ".") : ""
      commands.append(
        ReflowParagraphCommand(
          pageID: pageID, candidate: shifted,
          replacement: "\(marker)\(separator) \(item.text)",
          options: ParagraphReflowOptions(
            allowCollisions: true, allowLowConfidence: true)))
    }
    for runIndex in list.items[itemIndex].candidate.runIndices.reversed() {
      commands.append(
        ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: ""))
    }
    return commands
  }
}

extension TextParagraphCandidate {
  /// A copy used by list insertion/removal: content instructions are cleared
  /// through the original run indices while the new box is moved vertically.
  func shiftedVertically(by delta: Double) -> TextParagraphCandidate {
    TextParagraphCandidate(
      kind: kind, lineIndices: lineIndices, runIndices: runIndices,
      lineRunIndices: lineRunIndices, runStyles: runStyles,
      clusterRange: clusterRange, text: text,
      bounds: [bounds[0], bounds[1] + delta, bounds[2], bounds[3] + delta],
      fontSize: fontSize, alignment: alignment,
      firstLineIndent: firstLineIndent, lineSpacing: lineSpacing,
      confidence: confidence, structureRole: structureRole)
  }

  /// A marker change may need a little more horizontal room than the tight
  /// source box; keep the list's body lines from wrapping solely because the
  /// new marker is wider.
  func expandedHorizontally(by delta: Double) -> TextParagraphCandidate {
    TextParagraphCandidate(
      kind: kind, lineIndices: lineIndices, runIndices: runIndices,
      lineRunIndices: lineRunIndices, runStyles: runStyles,
      clusterRange: clusterRange, text: text,
      bounds: [bounds[0], bounds[1], bounds[2] + delta, bounds[3]],
      fontSize: fontSize, alignment: alignment,
      firstLineIndent: firstLineIndent, lineSpacing: lineSpacing,
      confidence: confidence, structureRole: structureRole)
  }
}
