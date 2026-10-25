import Foundation
import PDFCore

// MARK: - RED-03 reason codes

/// RED-03: a named reason code that can be painted over redacted content. Codes
/// are plain review data: they are not written into the PDF metadata, only the
/// chosen label is painted as overlay text (and can be disabled).
public struct RedactionReasonCode: Sendable, Equatable, Hashable, Identifiable, Codable {
  public let code: String
  public let label: String

  public var id: String { code }

  public static let maximumCodeLength = 40
  public static let maximumLabelLength = 80

  public init(code: String, label: String) {
    self.code = code
    self.label = label
  }

  /// Built-in codes offered by the review panel. Users can also enter a custom
  /// label; the panel stores it under `custom` with the label as its text.
  public static let presets: [RedactionReasonCode] = [
    RedactionReasonCode(code: "privileged", label: "Privileged"),
    RedactionReasonCode(code: "confidential", label: "Confidential"),
    RedactionReasonCode(code: "personal-data", label: "Personal data"),
    RedactionReasonCode(code: "proprietary", label: "Proprietary"),
    RedactionReasonCode(code: "regulatory", label: "Regulatory"),
    RedactionReasonCode(code: "legal", label: "Legal privilege"),
    RedactionReasonCode(code: "security", label: "Security"),
    RedactionReasonCode(code: "custom", label: "Redacted"),
  ]

  public static func preset(named code: String) -> RedactionReasonCode? {
    presets.first { $0.code == code }
  }

  /// Painted line, using the user-facing label rather than the internal code.
  public var paintedText: String {
    label.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func validate() throws {
    let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCode.isEmpty else {
      throw PDFError(.malformed, "A redaction reason code needs a code")
    }
    guard !trimmedLabel.isEmpty else {
      throw PDFError(.malformed, "A redaction reason code needs label text")
    }
    guard trimmedCode.count <= Self.maximumCodeLength else {
      throw PDFError(.limitExceeded, "The redaction reason code is too long")
    }
    guard trimmedLabel.count <= Self.maximumLabelLength else {
      throw PDFError(.limitExceeded, "The redaction reason label is too long")
    }
    guard RedactionOverlayOptions.isOverlayPrintable(trimmedLabel) else {
      throw PDFError(
        .unsupported,
        "The redaction reason label uses characters the overlay font cannot paint")
    }
  }
}

// MARK: - RED-03 overlay

/// RED-03: exactly what an apply run paints over each reviewed area: fill
/// color, replacement text, a reason-code label, text color and size.
///
/// The overlay is deliberately separate from the removal operation: the marked
/// content is removed whether or not an overlay is painted, and the review plan
/// lists the exact overlay lines before apply so the output cannot differ from
/// what the reviewer saw. The overlay itself is paint only; it is not a
/// removal mechanism and does not claim secure removal.
public struct RedactionOverlayOptions: Sendable, Equatable {
  public var paintsOverlay: Bool
  public var fillColor: [Double]
  public var textColor: [Double]
  /// Replacement text painted inside each marked area. Newlines create several
  /// centered lines. Nil paints only the reason-code label (if enabled).
  public var replacementText: String?
  public var reasonCode: RedactionReasonCode?
  /// When false the reason label is not painted even if `reasonCode` is set.
  public var showsReasonCode: Bool
  public var fontSize: Double
  public var fontFamily: AddedTextStyle.Family
  public var textAlignment: TextParagraphCandidate.Alignment

  public init(
    paintsOverlay: Bool = true,
    fillColor: [Double] = [0, 0, 0],
    textColor: [Double] = [1, 1, 1],
    replacementText: String? = nil,
    reasonCode: RedactionReasonCode? = nil,
    showsReasonCode: Bool = true,
    fontSize: Double = 9,
    fontFamily: AddedTextStyle.Family = .helvetica,
    textAlignment: TextParagraphCandidate.Alignment = .center
  ) {
    self.paintsOverlay = paintsOverlay
    self.fillColor = fillColor
    self.textColor = textColor
    self.replacementText = replacementText
    self.reasonCode = reasonCode
    self.showsReasonCode = showsReasonCode
    self.fontSize = fontSize
    self.fontFamily = fontFamily
    self.textAlignment = textAlignment
  }

  /// The RED-01 fill-only behavior, derived from the existing application
  /// options so older call sites keep the same painted result.
  public init(applicationOptions: RedactionApplicationOptions) {
    self.init(
      paintsOverlay: applicationOptions.paintsFill,
      fillColor: applicationOptions.fillColor)
  }

  public static let fillOnly = RedactionOverlayOptions()

  /// True when any text would be painted for a mark (fill alone is not text).
  public var paintsText: Bool {
    guard paintsOverlay else { return false }
    if let replacement = replacementText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !replacement.isEmpty
    {
      return true
    }
    if showsReasonCode, let reasonCode, !reasonCode.paintedText.isEmpty { return true }
    return false
  }

  /// The exact lines painted for a mark, in paint order.
  public func lines(for mark: RedactionMark) -> [String] {
    guard paintsOverlay else { return [] }
    var lines: [String] = []
    if let replacement = replacementText {
      for line in replacement.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(trimmed) }
      }
    }
    if showsReasonCode, let reasonCode {
      let label = reasonCode.paintedText
      if !label.isEmpty { lines.append(label) }
    }
    return lines
  }

  /// Painted lines without a mark, for review/help text.
  public var reviewLines: [String] {
    lines(for: RedactionMark(
      pageID: PDFObjectID(1), pageIndex: 0, kind: .region, rects: [[0, 0, 1, 1]]))
  }

  public var summary: String {
    guard paintsOverlay else { return "No overlay is painted; the marked content is removed only." }
    var parts = ["Overlay: fill"]
    let lines = reviewLines
    if !lines.isEmpty {
      parts.append("text \"" + lines.joined(separator: " / ") + "\"")
    }
    if !paintsText { parts.append("no text") }
    return parts.joined(separator: ", ") + "."
  }

  public func validate() throws {
    let colors = [("fill", fillColor), ("text", textColor)]
    for (label, color) in colors {
      guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
        throw PDFError(
          .malformed, "The redaction overlay \(label) color must be three finite RGB components")
      }
    }
    guard fontSize.isFinite, fontSize >= 2, fontSize <= 96 else {
      throw PDFError(.malformed, "The redaction overlay text size is outside the supported range")
    }
    if let replacement = replacementText {
      let lines = replacement.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      guard lines.count <= 8 else {
        throw PDFError(.limitExceeded, "The redaction replacement text is limited to 8 lines")
      }
      for line in lines {
        guard line.count <= 120 else {
          throw PDFError(.limitExceeded, "A redaction replacement line is too long")
        }
        guard Self.isOverlayPrintable(line) else {
          throw PDFError(
            .unsupported,
            "The redaction replacement text uses characters the overlay font cannot paint")
        }
      }
    }
    if let reasonCode {
      try reasonCode.validate()
    }
  }

  /// The overlay profile paints with the standard-14 WinAnsi fonts, so the
  /// stored text is restricted to printable Latin-1 characters.
  static func isOverlayPrintable(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      let value = scalar.value
      let printable =
        (0x20...0x7E).contains(value) || (0xA0...0xFF).contains(value)
        || value == 0x09
      if !printable { return false }
    }
    return true
  }
}

// MARK: - RED-03 overlay painter

/// RED-03: paints exactly the reviewed overlay (fill and optional centered
/// text) over each mark's page-space rectangles. The painter never removes
/// content: the removal command runs first, and the same function builds the
/// preview and the committed stream so the output matches the review.
public enum RedactionOverlayPainter {
  /// Validate that the overlay text fits every rectangle of a mark. Throws
  /// before any mutation when the text cannot fit or cannot be encoded.
  public static func validate(
    mark: RedactionMark, options: RedactionOverlayOptions, pageID: PDFObjectID,
    in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws {
    let lines = options.lines(for: mark)
    guard options.paintsOverlay else { return }
    if lines.isEmpty { return }
    guard !mark.rects.isEmpty else {
      throw PDFError(.malformed, "A redaction mark has no geometry to paint an overlay on")
    }
    var probe = graph
    for rect in mark.rects {
      _ = try layout(
        lines: lines, rect: rect, options: options, pageID: pageID, in: &probe, limits: limits)
    }
  }

  /// Append one overlay content stream for the given marks of one page.
  public static func paint(
    marks: [RedactionMark], options: RedactionOverlayOptions, pageID: PDFObjectID,
    in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    guard options.paintsOverlay, !marks.isEmpty else { return graph }
    var target = marks
    var graph = graph
    var content = ""
    for mark in target where mark.pageID == pageID {
      let lines = options.lines(for: mark)
      for rect in mark.rects {
        content += fillBlock(rect: rect, color: options.fillColor)
        if !lines.isEmpty {
          let resolved = try layout(
            lines: lines, rect: rect, options: options, pageID: pageID, in: &graph,
            limits: limits)
          content += textBlock(
            lines: lines, rect: rect, style: resolved.style, font: resolved.font,
            fontName: resolved.fontName)
        }
      }
    }
    _ = target
    guard !content.isEmpty else { return graph }
    let bytes = Data(content.utf8)
    let id = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    graph.objects[id] = .stream(
      PDFStream(
        dictionary: [PDFName("Length"): .integer(Int64(bytes.count))], bytes: bytes))
    try FlattenAnnotationsCommand.appendContents([.reference(id)], pageID: pageID, in: &graph)
    return graph
  }

  struct ResolvedText {
    let style: AddedTextStyle
    let font: WritableTextFont
    let fontName: PDFName
  }

  static func layout(
    lines: [String], rect: [Double], options: RedactionOverlayOptions,
    pageID: PDFObjectID, in graph: inout PDFGraph, limits: PDFLimits
  ) throws -> ResolvedText {
    let width = rect[2] - rect[0]
    let height = rect[3] - rect[1]
    let inset: Double = 3
    let availableWidth = max(width - inset * 2, 1)
    let availableHeight = max(height - inset * 2, 1)
    var style = AddedTextStyle(
      family: options.fontFamily, size: options.fontSize, color: options.textColor,
      alignment: .center, lineSpacing: 1.15)
    var font = try AddedContent.selectFont(
      style: style, custom: nil, covering: lines.joined(separator: " "), pageID: pageID,
      in: &graph)
    func measuredWidth(_ size: Double) -> Double {
      var widest = 0.0
      for line in lines {
        guard let codes = font.encode(line) else { return .infinity }
        let measured = font.advance(of: codes, fontSize: size)
          ?? Double(line.count) * size * 0.5
        widest = max(widest, measured)
      }
      return widest
    }
    let leading = style.size * max(style.lineSpacing, 0.8)
    _ = leading
    var size = style.size
    if measuredWidth(size) > availableWidth {
      let ratio = availableWidth / measuredWidth(size)
      size *= ratio
    }
    let lineDelivery = size * max(style.lineSpacing, 0.8)
    let totalHeight = lineDelivery * Double(max(lines.count - 1, 0)) + size
    if totalHeight > availableHeight {
      size *= availableHeight / totalHeight
    }
    guard size.isFinite, size >= 2 else {
      throw PDFError(
        .unsupported,
        "The redaction overlay text does not fit inside the marked region; shorten the text or widen the region")
    }
    // Re-resolve metrics at the final size, then confirm every line encodes.
    style.size = size
    font = try AddedContent.selectFont(
      style: style, custom: nil, covering: lines.joined(separator: " "), pageID: pageID,
      in: &graph)
    for line in lines where font.encode(line) == nil {
      throw PDFError(
        .unsupported, "The redaction overlay text cannot be encoded by the overlay font")
    }
    _ = limits
    return ResolvedText(style: style, font: font, fontName: font.resourceName)
  }

  static func fillBlock(rect: [Double], color: [Double]) -> String {
    "q\n\(AnnotationSupport.number(color[0])) \(AnnotationSupport.number(color[1])) "
      + "\(AnnotationSupport.number(color[2])) rg\n"
      + "\(AnnotationSupport.number(rect[0])) \(AnnotationSupport.number(rect[1])) "
      + "\(AnnotationSupport.number(rect[2] - rect[0])) "
      + "\(AnnotationSupport.number(rect[3] - rect[1])) re f\nQ\n"
  }

  static func textBlock(
    lines: [String], rect: [Double], style: AddedTextStyle, font: WritableTextFont,
    fontName: PDFName
  ) -> String {
    let leading = style.size * max(style.lineSpacing, 0.8)
    let blockHeight = leading * Double(max(lines.count - 1, 0)) + style.size
    let centerY = (rect[1] + rect[3]) / 2
    let top = centerY + blockHeight / 2
    let firstBaseline = top - style.size * 0.8
    let origin = [rect[0] + (rect[2] - rect[0]) / 2, firstBaseline]
    var block = "q\nBT\n/"
    block += String(decoding: fontName.bytes, as: UTF8.self) + " "
    block += AnnotationSupport.number(style.size) + " Tf\n"
    block += "\(AnnotationSupport.number(style.color[0])) "
    block += "\(AnnotationSupport.number(style.color[1])) "
    block += "\(AnnotationSupport.number(style.color[2])) rg\n"
    for (index, line) in lines.enumerated() {
      guard let codes = font.encode(line) else { continue }
      let measured = font.advance(of: codes, fontSize: style.size)
        ?? Double(line.count) * style.size * 0.5
      let x = origin[0] - measured / 2
      let y = origin[1] - Double(index) * leading
      block += "1 0 0 1 \(AnnotationSupport.number(x)) \(AnnotationSupport.number(y)) Tm\n"
      block += "(\(AddedContent.escaped(codes))) Tj\n"
    }
    block += "ET\nQ\n"
    return block
  }
}

// MARK: - RED-03 repeated-page regions

extension RedactionMarkStore {
  /// Stage the same rectangle on every page of a 1-based page range such as
  /// "2-5, 8". Returns the new marks; nothing is applied here.
  @discardableResult
  public mutating func addRepeatedRegion(
    pageIDs: [PDFObjectID], pageRange: String, rects: [[Double]],
    reason: String? = nil, source: String = "Repeated region"
  ) throws -> [RedactionMark] {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "The document has no pages to mark")
    }
    // Reject out-of-document page numbers instead of silently clamping them:
    // the reviewer asked for pages that do not exist.
    for token in pageRange.components(separatedBy: CharacterSet(charactersIn: ", ")) {
      let trimmed = token.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      for part in trimmed.components(separatedBy: "-") {
        if let number = Int(part), number > pageIDs.count {
          throw PDFError(
            .malformed,
            "Page \(number) is outside the document; enter a range such as 1-\(pageIDs.count)")
        }
      }
    }
    let indices = PageRange.parse(pageRange, pageCount: pageIDs.count)
    guard !indices.isEmpty else {
      throw PDFError(
        .malformed, "Enter a page range such as 1-3 or 2, 4-6 for the repeated region")
    }
    guard !rects.isEmpty else {
      throw PDFError(.malformed, "A repeated region needs at least one rectangle")
    }
    try Self.validateRects(rects, kind: .region)
    var marks: [RedactionMark] = []
    for index in indices {
      marks.append(
        try add(
          kind: .region, pageID: pageIDs[index], pageIndex: index, rects: rects,
          reason: reason, matchedText: nil,
          sources: [source + " " + pageRange.trimmingCharacters(in: .whitespaces)]))
    }
    return marks
  }
}
