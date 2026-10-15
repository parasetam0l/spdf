import Foundation
import PDFCore

/// A line laid out by the platform text engine, in PDF page coordinates.
/// Persist these positions instead of running a different wrapping algorithm
/// when the user saves an on-page edit.
public struct PageTextLine: Sendable, Equatable {
  public let text: String
  public let x: Double
  public let baseline: Double

  public init(text: String, x: Double, baseline: Double) {
    self.text = text
    self.x = x
    self.baseline = baseline
  }
}

/// Replaces a homogeneous paragraph with the exact lines shown by the native
/// editor. Numeric TJ advances remove the original strings while preserving
/// the pen position seen by all following, unedited text.
public struct RewritePageTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let originalText: [Int: String]
  public let lines: [PageTextLine]
  public let fontSize: Double
  public let color: [Double]
  /// Standard-14 fonts can omit /Widths. The platform supplies unshaped
  /// advances only for those fonts; other missing metrics are refused.
  public let standardFontAdvances: [Int: Double]

  public init(
    pageID: PDFObjectID, originalText: [Int: String], lines: [PageTextLine],
    fontSize: Double, color: [Double], standardFontAdvances: [Int: Double] = [:]
  ) {
    self.pageID = pageID
    self.originalText = originalText
    self.lines = lines
    self.fontSize = fontSize
    self.color = color
    self.standardFontAdvances = standardFontAdvances
  }

  public var name: String { "Edit Paragraph" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws { _ = try resolved(in: graph) }

  private func resolved(in graph: PDFGraph) throws -> (
    content: PageContent, runs: [TextRun], font: SimpleFont, advances: [Double]
  ) {
    guard !originalText.isEmpty, originalText.count <= 500,
      fontSize.isFinite, (2...144).contains(fontSize), color.count == 3,
      color.allSatisfy({ $0.isFinite && (0...1).contains($0) }), lines.count <= 4_000,
      lines.allSatisfy({
        $0.x.isFinite && $0.baseline.isFinite
          && !$0.text.contains("\n") && !$0.text.contains("\r")
      })
    else { throw PDFError(.malformed, "The paragraph layout is invalid") }
    let content = try PageContent.load(pageID: pageID, in: graph)
    guard content.segments.allSatisfy(\.isEditable),
      Set(content.segments.map(\.objectID)).count == content.segments.count
    else {
      throw PDFError(
        .unsupported, "The paragraph page repeats streams or uses unsupported content filters")
    }
    // A wrapper can restore the initial graphics state only for balanced
    // content. Refuse malformed streams rather than changing clipping/alpha.
    var depth = 0
    var inText = false
    for instruction in content.instructions {
      switch instruction.operatorName {
      case "q": depth += 1
      case "Q":
        depth -= 1
        guard depth >= 0 else { throw PDFError(.unsupported, "Unbalanced page graphics state") }
      case "BT":
        guard !inText else { throw PDFError(.unsupported, "Nested page text objects") }
        inText = true
      case "ET":
        guard inText else { throw PDFError(.unsupported, "Unbalanced page text objects") }
        inText = false
      default: break
      }
    }
    guard depth == 0, !inText else {
      throw PDFError(.unsupported, "Unbalanced page content cannot be rewritten inline")
    }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The paragraph page is missing")
    }
    let allRuns = try TextRunIndexer.runs(in: content, graph: graph)
    var selected: [TextRun] = []
    var advances: [Double] = []
    var firstFont: SimpleFont?
    for index in originalText.keys.sorted() {
      guard allRuns.indices.contains(index) else {
        throw PDFError(.malformed, "The paragraph's text runs changed")
      }
      let run = allRuns[index]
      let instruction = content.instructions[run.instructionIndex]
      guard run.text == originalText[index], instruction.operatorName == "Tj",
        run.fontSize.isFinite, run.fontSize > 0,
        run.ctm == [1, 0, 0, 1, 0, 0],
        abs(run.matrix[0] - 1) < 1e-6, abs(run.matrix[3] - 1) < 1e-6,
        abs(run.matrix[1]) < 1e-6, abs(run.matrix[2]) < 1e-6,
        abs(run.charSpacing) < 1e-6, abs(run.wordSpacing) < 1e-6,
        abs(run.horizontalScale - 100) < 1e-6, abs(run.rise) < 1e-6,
        TextCanvasSupport.renderingMode(at: run.instructionIndex, in: content) == 0,
        safeGraphics(at: run.instructionIndex, in: content),
        let font = SimpleFont.resolve(resource: run.fontResource, page: page, in: graph),
        font.isEditable, !font.isType3,
        let segment = content.segmentIndex(for: run.stringSpan),
        content.segments[segment].isEditable,
        firstFont == nil || firstFont?.fontID == font.fontID
      else {
        throw PDFError(.unsupported, "This paragraph needs a different font, spacing or transform")
      }
      let advance: Double
      if let measured = font.advance(
        of: run.rawCodes, fontSize: run.fontSize, charSpacing: 0,
        wordSpacing: 0, horizontalScale: 100)
      {
        advance = measured
      } else {
        let family =
          TextEditTargeting.inputStyle(
            runIndex: 0, runs: [run], in: graph
          ).fontFamily ?? ""
        guard Self.standardFonts.contains(family), font.differences.isEmpty, font.toUnicode == nil,
          let measured = standardFontAdvances[index], measured.isFinite, measured >= 0
        else {
          throw PDFError(.unsupported, "The paragraph's original glyph advances are unavailable")
        }
        advance = measured
      }
      guard advance.isFinite else {
        throw PDFError(.unsupported, "The paragraph's glyph advances are invalid")
      }
      selected.append(run)
      advances.append(advance)
      firstFont = font
    }
    guard let font = firstFont, lines.allSatisfy({ font.encode($0.text) != nil }) else {
      throw PDFError(.unsupported, "The PDF font cannot encode the replacement characters")
    }
    return (content, selected, font, advances)
  }

  private func safeGraphics(at index: Int, in content: PageContent) -> Bool {
    var unsafe = false
    var stack: [Bool] = []
    for instruction in content.instructions.prefix(index + 1) {
      switch instruction.operatorName {
      case "q": stack.append(unsafe)
      case "Q": unsafe = stack.popLast() ?? true
      case "gs", "W", "W*", "cs", "sc", "scn": unsafe = true
      default: break
      }
    }
    return !unsafe
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph)
    let context = try resolved(in: graph)
    var ranges: [(range: Range<Int>, replacement: [UInt8])] = []
    for (run, advance) in zip(context.runs, context.advances) {
      let instruction = context.content.instructions[run.instructionIndex]
      let number = AnnotationSupport.number(-advance * 1_000 / run.fontSize)
      ranges.append((TextStyleSupport.fullSpan(of: instruction), Array("[\(number)] TJ".utf8)))
    }
    // Restore the page's initial CTM, clip, alpha and text state before
    // painting the replacement, including pages ending with an active cm.
    ranges.append((0..<0, Array("q\n".utf8)))
    let end = context.content.bytes.count
    ranges.append((end..<end, Array("\nQ\n".utf8)))
    var result = graph
    for index in context.content.segments.indices {
      let local = ranges.filter { context.content.segmentIndex(for: $0.range) == index }
      if !local.isEmpty {
        result = try context.content.replacing(ranges: local, in: result)
      }
    }
    let resource = String(
      decoding: try PDFWriter.serializedValue(.name(context.font.resource)), as: UTF8.self)
    var output =
      "q\nBT\n0 Tc 0 Tw 100 Tz 0 Ts 0 Tr\n\(resource) \(AnnotationSupport.number(fontSize)) Tf\n"
    output += color.map(AnnotationSupport.number).joined(separator: " ") + " rg\n"
    var bytes = Array(output.utf8)
    for line in lines where !line.text.isEmpty {
      bytes += Array(
        "1 0 0 1 \(AnnotationSupport.number(line.x)) \(AnnotationSupport.number(line.baseline)) Tm\n"
          .utf8)
      bytes += ReplaceTextCommand.literalStringBytes(context.font.encode(line.text) ?? [])
      bytes += Array(" Tj\n".utf8)
    }
    bytes += Array("ET\nQ\n".utf8)
    try AddedContent.append(
      String(decoding: bytes, as: UTF8.self), pageID: pageID, toFront: true, in: &result)
    return result
  }

  public static let standardFonts: Set<String> = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
  ]
}
