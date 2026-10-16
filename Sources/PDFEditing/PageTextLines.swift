import Foundation
import PDFCore

/// A line laid out by the platform text engine, in PDF page coordinates.
/// Persist these positions instead of running a different wrapping algorithm
/// when the user saves an on-page edit.
public struct PageTextLine: Sendable, Equatable {
  public let text: String
  public let x: Double
  public let baseline: Double
  public let segments: [PageTextSegment]
  public let endsParagraph: Bool
  public let breakFormat: PageTextFormat?

  public init(text: String, x: Double, baseline: Double,
    segments: [PageTextSegment] = [], endsParagraph: Bool = false, breakFormat: PageTextFormat? = nil) {
    self.text = text
    self.x = x
    self.baseline = baseline
    self.segments = segments
    self.endsParagraph = endsParagraph
    self.breakFormat = breakFormat
  }
}

/// Replaces supported paragraph text with the exact lines shown by the native
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
  public let box: PageTextBox?

  public init(
    pageID: PDFObjectID, originalText: [Int: String], lines: [PageTextLine],
    fontSize: Double, color: [Double], standardFontAdvances: [Int: Double] = [:], box: PageTextBox? = nil
  ) {
    self.pageID = pageID
    self.originalText = originalText
    self.lines = lines
    self.fontSize = fontSize
    self.color = color
    self.standardFontAdvances = standardFontAdvances
    self.box = box
  }

  public var name: String { "Edit Paragraph" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws { _ = try resolved(in: graph) }

  private func resolved(in graph: PDFGraph) throws -> (
    content: PageContent, runs: [TextRun], font: IndexedTextFont, advances: [Double]
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
    var firstFont: IndexedTextFont?
    var fonts: [PDFName: IndexedTextFont] = [:]
    var standardIndices: Set<Int>?
    for index in originalText.keys.sorted() {
      guard allRuns.indices.contains(index) else {
        throw PDFError(.malformed, "The paragraph's text runs changed")
      }
      let run = allRuns[index]
      let instruction = content.instructions[run.instructionIndex]
      let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      if fonts[run.fontResource] == nil {
        fonts[run.fontResource] = IndexedTextFont.resolve(resource: run.fontResource, page: page, in: graph)
      }
      guard run.text == originalText[index], ["Tj", "TJ"].contains(instruction.operatorName),
        run.fontSize.isFinite, run.fontSize > 0,
        transform[0] > 0, abs(transform[0] - transform[3]) < 1e-6,
        abs(transform[1]) < 1e-6, abs(transform[2]) < 1e-6,
        run.charSpacing.isFinite, abs(run.charSpacing) <= 144,
        run.wordSpacing.isFinite, abs(run.wordSpacing) <= 144,
        abs(run.horizontalScale - 100) < 1e-6, abs(run.rise) < 1e-6,
        TextCanvasSupport.renderingMode(at: run.instructionIndex, in: content) == 0,
        safeGraphics(at: run.instructionIndex, in: content),
        let font = fonts[run.fontResource],
        font.isInlineEditable,
        let segment = content.segmentIndex(for: run.stringSpan),
        content.segments[segment].isEditable
      else {
        throw PDFError(.unsupported, "This paragraph needs a different font, spacing or transform")
      }
      let advance: Double
      if let measured = font.advance(
        of: run.rawCodes, fontSize: run.fontSize, charSpacing: run.charSpacing,
        wordSpacing: run.wordSpacing, horizontalScale: 100)
      {
        advance = measured
      } else {
        if standardIndices == nil {
          standardIndices = Set(try StandardTextFont.editableRunIndices(pageID: pageID, in: graph))
        }
        let family =
          TextEditTargeting.inputStyle(
            runIndex: 0, runs: [run], in: graph
          ).fontFamily ?? ""
        guard standardIndices?.contains(index) == true, Self.standardFonts.contains(family),
          font.simple?.differences.isEmpty == true,
          font.simple?.toUnicode == nil,
          let measured = standardFontAdvances[index], measured.isFinite, measured >= 0
        else {
          throw PDFError(.unsupported, "The paragraph's original glyph advances are unavailable")
        }
        advance = measured + Double(run.rawCodes.count) * run.charSpacing
          + Double(run.rawCodes.filter { $0 == 32 }.count) * run.wordSpacing
      }
      guard advance.isFinite else {
        throw PDFError(.unsupported, "The paragraph's glyph advances are invalid")
      }
      selected.append(run)
      advances.append(advance)
      if firstFont == nil { firstFont = font }
    }
    for run in selected {
      guard allRuns.indices.filter({ allRuns[$0].instructionIndex == run.instructionIndex })
        .allSatisfy({ originalText[$0] != nil }) else {
        throw PDFError(.unsupported, "Select the complete text-show instruction before editing")
      }
    }
    try PageTextLineWriter.validate(lines, box: box)
    try PageTextLineWriter.validateFonts(lines, pageID: pageID, in: graph)
    guard let font = firstFont,
      lines.allSatisfy({ !$0.segments.isEmpty || font.encode($0.text) != nil }) else {
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
    let groups = Dictionary(grouping: context.runs.indices, by: { context.runs[$0].instructionIndex })
    for instructionIndex in groups.keys.sorted() {
      let indices = groups[instructionIndex]!
      let run = context.runs[indices[0]]
      let instruction = context.content.instructions[instructionIndex]
      var advance = indices.reduce(0.0) { $0 + context.advances[$1] }
      if case .array(let entries)? = instruction.operands.first?.value {
        for entry in entries {
          switch entry {
          case .integer(let n): advance -= Double(n) * run.fontSize / 1_000
          case .real(let n): advance -= n * run.fontSize / 1_000
          case .string: break
          default: throw PDFError(.malformed, "Invalid text adjustment")
          }
        }
      }
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
    try PageTextLineWriter.append(lines, box: box, pageID: pageID, defaultFont: context.font,
      defaultSize: fontSize, defaultColor: color, in: &result)
    return result
  }

  public static let standardFonts: Set<String> = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
  ]
}
