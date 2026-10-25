import Foundation
import PDFCore

/// TXT-10: one authored text box lifted out of a page for duplication or
/// cross-page paste. The lines keep their styles and their own coordinates;
/// the box keeps the paragraph geometry copied alongside them.
public struct TextBoxClipboard: Sendable, Equatable {
  public let lines: [PageTextLine]
  public let box: PageTextBox

  public init(lines: [PageTextLine], box: PageTextBox) {
    self.lines = lines
    self.box = box
  }

  /// The editable string represented by the copied lines.
  public var text: String { lines.map(\.text).joined(separator: "\n") }

  /// TXT-10: an original-PDF font (`sourceFont`) belongs to the source page's
  /// resources and program; a new box cannot re-create it safely. Standard-14
  /// and explicitly licensed custom programs can be re-embedded, so only the
  /// source-font case is refused.
  public var unsafeFormat: PageTextFormat? {
    for line in lines {
      for segment in line.segments where segment.format.sourceFont != nil {
        return segment.format
      }
    }
    return nil
  }

  public var isCopySafe: Bool { unsafeFormat == nil }
}

/// TXT-10: lift authored text boxes into the clipboard value.
public enum TextBoxCopy {
  /// Page-space bounds approximating what a box paints. Authored metadata
  /// records line positions and segment widths, so this never needs the source
  /// page's rendering.
  public static func bounds(of box: AuthoredPageTextBox) -> [Double] {
    var minX = box.box.x
    var maxX = box.box.x + 1
    var minY = box.box.firstBaseline
    var maxY = box.box.firstBaseline
    for line in box.lines {
      let size = line.segments.first?.format.size ?? 12
      var width = 0.0
      for segment in line.segments {
        width += segment.width ?? Double(segment.text.unicodeScalars.count) * segment.format.size * 0.55
      }
      minX = min(minX, line.x)
      maxX = max(maxX, line.x + max(width, 1))
      minY = min(minY, line.baseline - size * 0.25)
      maxY = max(maxY, line.baseline + size * 0.85)
    }
    return [minX, minY, maxX, maxY]
  }

  /// Lift one authored box. sPDF-embedded font programs are recovered from the
  /// page and carried as licensed custom fonts; a font program that cannot be
  /// re-created is refused before anything is copied.
  public static func clipboard(
    from box: AuthoredPageTextBox, pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> TextBoxClipboard {
    guard !box.lines.isEmpty else {
      throw PDFError(.malformed, "The text box has no editable lines to copy")
    }
    let profiles = try PageTextEditing.fontProfiles(pageID: pageID, in: graph)
    func recreated(_ format: PageTextFormat) throws -> PageTextFormat {
      var format = format
      if format.customFont != nil {
        format.sourceFont = nil
        return format
      }
      guard let source = format.sourceFont else { return format }
      guard let profile = profiles[source.resource], !profile.program.isEmpty else {
        throw PDFError(
          .unsupported,
          "The text box uses the original PDF font “" + source.name
            + "”, which cannot be re-created in a new box. Restyle the box with "
            + "Helvetica, Times, Courier or a licensed font first.")
      }
      let face = source.name.split(separator: "+", maxSplits: 1).last.map(String.init)
        ?? source.name
      format.customFont = CustomTextFont(
        program: profile.program, familyName: face, faceName: face,
        identifier: source.name, isBold: source.isBold, isItalic: source.isItalic)
      format.sourceFont = nil
      return format
    }
    let lines = try box.lines.map { line in
      let segments = try line.segments.map { segment in
        PageTextSegment(
          text: segment.text, x: segment.x, format: try recreated(segment.format),
          width: segment.width)
      }
      return PageTextLine(
        text: line.text, x: line.x, baseline: line.baseline, segments: segments,
        endsParagraph: line.endsParagraph,
        breakFormat: try line.breakFormat.map { try recreated($0) })
    }
    return TextBoxClipboard(lines: lines, box: box.box)
  }

  /// The authored box a page-space selection belongs to, or nil. The smallest
  /// intersecting box wins so nested boxes resolve predictably; without
  /// bounds, a page with exactly one authored box is unambiguous.
  public static func clipboard(
    pageID: PDFObjectID, in graph: PDFGraph, selectionBounds: [Double]? = nil
  ) throws -> TextBoxClipboard? {
    let boxes = try AuthoredPageTextBoxes.read(pageID: pageID, in: graph)
    guard !boxes.isEmpty else { return nil }
    guard let selectionBounds, selectionBounds.count == 4,
      selectionBounds.allSatisfy(\.isFinite)
    else {
      return boxes.count == 1
        ? try clipboard(from: boxes[0], pageID: pageID, in: graph) : nil
    }
    let selectionMinX = min(selectionBounds[0], selectionBounds[2])
    let selectionMaxX = max(selectionBounds[0], selectionBounds[2])
    let selectionMinY = min(selectionBounds[1], selectionBounds[3])
    let selectionMaxY = max(selectionBounds[1], selectionBounds[3])
    var best: (clipboard: TextBoxClipboard, area: Double)?
    for box in boxes {
      let bounds = bounds(of: box)
      guard bounds.maxX >= selectionMinX, bounds.minX <= selectionMaxX,
        bounds.maxY >= selectionMinY, bounds.minY <= selectionMaxY
      else { continue }
      let area = max(0, min(bounds.maxX, selectionMaxX) - max(bounds.minX, selectionMinX))
        * max(0, min(bounds.maxY, selectionMaxY) - max(bounds.minY, selectionMinY))
      guard area > 0 else { continue }
      guard let lifted = try? clipboard(from: box, pageID: pageID, in: graph) else { continue }
      if let current = best, current.area <= area { continue }
      let boxArea = max(0, bounds.maxX - bounds.minX) * max(0, bounds.maxY - bounds.minY)
      best = (lifted, boxArea)
    }
    return best?.clipboard
  }
}

extension Array where Element == Double {
  var maxX: Double { count == 4 ? Swift.max(self[0], self[2]) : 0 }
  var minX: Double { count == 4 ? Swift.min(self[0], self[2]) : 0 }
  var maxY: Double { count == 4 ? Swift.max(self[1], self[3]) : 0 }
  var minY: Double { count == 4 ? Swift.min(self[1], self[3]) : 0 }
}

/// TXT-10: place a copied box on a destination page and build the single
/// insertion command, so duplication and paste stay one Undo step.
public enum TextBoxPaste {
  public static let margin = 4.0

  /// Layout for the clipboard on `pageID`, shifted by the offset and clamped
  /// inside the destination page's media box.
  public static func placed(
    _ clipboard: TextBoxClipboard, on pageID: PDFObjectID, in graph: PDFGraph,
    offsetX: Double = 0, offsetY: Double = 0
  ) throws -> TextBoxClipboard {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The paste destination page is missing")
    }
    guard offsetX.isFinite, offsetY.isFinite else {
      throw PDFError(.malformed, "The paste offset is not a finite position")
    }
    let media = DocumentInventoryBox.mediaBox(of: page, in: graph)
    guard media.count == 4, media.allSatisfy(\.isFinite) else {
      throw PDFError(.malformed, "The paste destination page has no usable media box")
    }
    let left = media.minX + margin
    let right = media.maxX - margin
    let bottom = media.minY + margin
    let top = media.maxY - margin
    var box = clipboard.box
    guard box.width <= right - left + 0.01 else {
      throw PDFError(
        .unsupported,
        "The text box is wider than the destination page; resize it before copying.")
    }
    let desiredX = box.x + offsetX
    let clampedX = min(max(desiredX, left), right - box.width)
    let dx = clampedX - box.x
    var dy = offsetY
    let movedBaselines = clipboard.lines.map { $0.baseline + dy }
    if let lowest = movedBaselines.min(), lowest < bottom + 2 {
      dy += bottom + 2 - lowest
    }
    let recheckedBaselines = clipboard.lines.map { $0.baseline + dy }
    if let highest = recheckedBaselines.max(), highest > top - 2 {
      dy -= highest - (top - 2)
    }
    guard abs(dx).isFinite, dy.isFinite else {
      throw PDFError(.malformed, "The text box cannot be placed on the destination page")
    }
    let lines = clipboard.lines.map { line in
      PageTextLine(
        text: line.text, x: line.x + dx, baseline: line.baseline + dy,
        segments: line.segments.map { segment in
          PageTextSegment(
            text: segment.text, x: segment.x + dx, format: segment.format,
            width: segment.width)
        },
        endsParagraph: line.endsParagraph, breakFormat: line.breakFormat)
    }
    box = PageTextBox(
      x: box.x + dx, firstBaseline: box.firstBaseline + dy, width: box.width,
      lineSpacing: box.lineSpacing, wraps: box.wraps)
    let placed = TextBoxClipboard(lines: lines, box: box)
    guard !placed.lines.isEmpty else {
      throw PDFError(.malformed, "The text box has no editable lines to paste")
    }
    return placed
  }

  /// The whole paste insertion: one `AddPageTextLinesCommand` so a single
  /// Undo removes the entire copied box.
  public static func command(
    _ clipboard: TextBoxClipboard, on pageID: PDFObjectID, in graph: PDFGraph,
    offsetX: Double = 0, offsetY: Double = 0
  ) throws -> AddPageTextLinesCommand {
    let placed = try placed(
      clipboard, on: pageID, in: graph, offsetX: offsetX, offsetY: offsetY)
    let command = AddPageTextLinesCommand(
      pageID: pageID, lines: placed.lines, box: placed.box)
    try command.validate(in: graph)
    return command
  }
}
