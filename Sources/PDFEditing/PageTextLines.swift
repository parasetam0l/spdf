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

/// A page-scoped snapshot for discovering many editable paragraphs. It uses
/// the command's validation rules without reparsing the page and its fonts
/// for every candidate. A fresh command still validates the current graph at
/// commit time, so this snapshot cannot authorize a later, changed document.
public struct PageTextRewriteValidator {
  private let graph: PDFGraph
  private let pageID: PDFObjectID
  private let analysis: ParagraphRewriteAnalysis

  public init(pageID: PDFObjectID, in graph: PDFGraph) throws {
    self.graph = graph; self.pageID = pageID
    analysis = try ParagraphRewriteAnalysis(pageID: pageID, graph: graph)
  }

  /// The common, page-space rectangular clip actually active at the selected
  /// instructions. Different regions cannot become one editable paragraph.
  public func clippingRect(for runIndices: [Int]) throws -> [Double]? {
    try analysis.clippingRect(for: runIndices)
  }

  public func validate(originalText: [Int: String], fontSize: Double, color: [Double],
    standardFontAdvances: [Int: Double] = [:]) throws {
    _ = try RewritePageTextCommand(pageID: pageID, originalText: originalText, lines: [],
      fontSize: fontSize, color: color, standardFontAdvances: standardFontAdvances)
      .resolved(in: graph, analysis: analysis)
  }
}

fileprivate struct ParagraphRewriteAnalysis {
  let content: PageContent
  let runs: [TextRun]
  let fonts: [PDFName: IndexedTextFont]
  let standardIndices: Set<Int>
  let safeInstructions: Set<Int>
  let instructionRuns: [Int: [Int]]
  let clips: [Int: [Double]]

  func clippingRect(for indices: [Int]) throws -> [Double]? {
    guard let first = indices.first, runs.indices.contains(first) else {
      throw PDFError(.malformed, "Missing paragraph text")
    }
    let clip = clips[runs[first].instructionIndex]
    guard indices.allSatisfy({ runs.indices.contains($0)
      && safeInstructions.contains(runs[$0].instructionIndex)
      && clips[runs[$0].instructionIndex] == clip }) else {
      throw PDFError(.unsupported, "Select text within one supported clipping region")
    }
    return clip
  }

  init(pageID: PDFObjectID, graph: PDFGraph) throws {
    content = try PageContent.load(pageID: pageID, in: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The paragraph page is missing")
    }
    func ordinaryGraphicsState(_ instruction: ContentInstruction) -> Bool {
      guard case .name(let name)? = instruction.operands.first?.value,
        case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph),
        case .dictionary(let states)? = FontValue.resolve(resources[PDFName("ExtGState")], in: graph),
        case .dictionary(let state)? = FontValue.resolve(states[name], in: graph),
        !state.isEmpty else { return false }
      return state.allSatisfy { key, value in
        switch (key, FontValue.resolve(value, in: graph)) {
        case (PDFName("Type"), .name(PDFName("ExtGState"))?),
          (PDFName("BM"), .name(PDFName("Normal"))?),
          (PDFName("ca"), .integer(1)?), (PDFName("CA"), .integer(1)?),
          (PDFName("ca"), .real(1)?), (PDFName("CA"), .real(1)?): return true
        default: return false
        }
      }
    }
    guard content.segments.allSatisfy(\.isEditable),
      Set(content.segments.map(\.objectID)).count == content.segments.count else {
      throw PDFError(.unsupported, "The paragraph page repeats streams or uses unsupported content filters")
    }
    var stack: [(unsafe: Bool, mode: Int, ctm: [Double], clip: [Double]?)] = []
    var ctm = [1.0, 0, 0, 1, 0, 0]
    var clip: [Double]?
    var clips: [Int: [Double]] = [:]
    // The current path is not part of q/Q graphics state. Apply W/W* only
    // when its following path-ending operator executes, as PDF specifies.
    var hasPath = false
    var rectangle: [Double]?
    var pendingClip = false
    var unsafe = false
    var mode = 0
    var inText = false
    var textClipping = false
    var safe = Set<Int>()
    for (index, instruction) in content.instructions.enumerated() {
      let numbers = instruction.operands.compactMap { operand -> Double? in
        switch operand.value { case .integer(let n): return Double(n); case .real(let n): return n; default: return nil }
      }
      switch instruction.operatorName {
      case "q": stack.append((unsafe, mode, ctm, clip))
      case "Q":
        guard let state = stack.popLast() else { throw PDFError(.unsupported, "Unbalanced page graphics state") }
        unsafe = state.unsafe || (inText && textClipping)
        mode = state.mode; ctm = state.ctm; clip = state.clip
      case "cm":
        if numbers.count == 6, numbers.allSatisfy(\.isFinite) {
          ctm = TextCanvasSupport.concatenate(ctm, numbers)
        } else { unsafe = true }
      case "re":
        let axisAligned = (abs(ctm[1]) < 1e-9 && abs(ctm[2]) < 1e-9)
          || (abs(ctm[0]) < 1e-9 && abs(ctm[3]) < 1e-9)
        if !hasPath, !pendingClip, axisAligned, numbers.count == 4,
          numbers.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) {
          let x = numbers[0], y = numbers[1], w = numbers[2], h = numbers[3]
          let points = [(x,y), (x+w,y), (x+w,y+h), (x,y+h)].map { x, y in
            [ctm[0] * x + ctm[2] * y + ctm[4], ctm[1] * x + ctm[3] * y + ctm[5]]
          }
          rectangle = [points.map { $0[0] }.min()!, points.map { $0[1] }.min()!,
            points.map { $0[0] }.max()!, points.map { $0[1] }.max()!]
        } else { rectangle = nil }
        hasPath = true
      case "m", "l", "c", "v", "y": hasPath = true; rectangle = nil
      case "h": break
      case "W", "W*":
        if pendingClip || inText { unsafe = true }
        pendingClip = true
      case "n", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
        if pendingClip {
          if let rect = rectangle, rect.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) {
            let next = clip.map { [max($0[0],rect[0]), max($0[1],rect[1]), min($0[2],rect[2]), min($0[3],rect[3])] } ?? rect
            if next[2] > next[0], next[3] > next[1] { clip = next } else { unsafe = true }
          } else { unsafe = true }
        }
        hasPath = false; rectangle = nil; pendingClip = false
      case "BT":
        guard !inText else { throw PDFError(.unsupported, "Nested page text objects") }
        inText = true
      case "ET":
        guard inText else { throw PDFError(.unsupported, "Unbalanced page text objects") }
        inText = false
        // Glyph clip outlines accumulate until ET, independently of a q/Q
        // inside the text object. Restoring Tr alone cannot erase that clip.
        if textClipping { unsafe = true; textClipping = false }
      case "gs": if !ordinaryGraphicsState(instruction) { unsafe = true }
      case "cs", "sc", "scn": unsafe = true
      case "Tr":
        if case .integer(let value)? = instruction.operands.first?.value {
          mode = Int(value)
          if value >= 4 { unsafe = true; textClipping = true }
        } else { unsafe = true }
      default: break
      }
      if !unsafe, !pendingClip, mode == 0 {
        safe.insert(index)
        if let clip { clips[index] = clip }
      }
    }
    guard stack.isEmpty, !inText, !pendingClip else {
      throw PDFError(.unsupported, "Unbalanced page content cannot be rewritten inline")
    }
    let allRuns = try TextRunIndexer.runs(in: content, graph: graph)
    runs = allRuns
    var resolved: [PDFName: IndexedTextFont] = [:]
    for resource in Set(runs.map(\.fontResource)) {
      resolved[resource] = IndexedTextFont.resolve(resource: resource, page: page, in: graph)
    }
    fonts = resolved
    standardIndices = Set(try StandardTextFont.editableRunIndices(pageID: pageID, in: graph))
    safeInstructions = safe
    self.clips = clips
    instructionRuns = Dictionary(grouping: allRuns.indices, by: { allRuns[$0].instructionIndex })
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

  fileprivate func resolved(in graph: PDFGraph, analysis supplied: ParagraphRewriteAnalysis? = nil) throws -> (
    content: PageContent, runs: [TextRun], font: IndexedTextFont, advances: [Double], clip: [Double]?
  ) {
    guard !originalText.isEmpty, originalText.count <= 500,
      fontSize.isFinite, (2...144).contains(fontSize), color.count == 3,
      color.allSatisfy({ $0.isFinite && (0...1).contains($0) }), lines.count <= 4_000,
      lines.allSatisfy({
        $0.x.isFinite && $0.baseline.isFinite
          && !$0.text.contains("\n") && !$0.text.contains("\r")
      })
    else { throw PDFError(.malformed, "The paragraph layout is invalid") }
    let analysis = try supplied ?? ParagraphRewriteAnalysis(pageID: pageID, graph: graph)
    let content = analysis.content
    let allRuns = analysis.runs
    var selected: [TextRun] = []
    var advances: [Double] = []
    var firstFont: IndexedTextFont?
    for index in originalText.keys.sorted() {
      guard allRuns.indices.contains(index) else {
        throw PDFError(.malformed, "The paragraph's text runs changed")
      }
      let run = allRuns[index]
      let instruction = content.instructions[run.instructionIndex]
      let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      guard run.text == originalText[index], ["Tj", "TJ"].contains(instruction.operatorName),
        run.fontSize.isFinite, run.fontSize > 0,
        transform[0] > 0, abs(transform[0] - transform[3]) < 1e-6,
        abs(transform[1]) < 1e-6, abs(transform[2]) < 1e-6,
        run.charSpacing.isFinite, abs(run.charSpacing) <= 144,
        run.wordSpacing.isFinite, abs(run.wordSpacing) <= 144,
        abs(run.horizontalScale - 100) < 1e-6, abs(run.rise) < 1e-6,
        analysis.safeInstructions.contains(run.instructionIndex),
        let font = analysis.fonts[run.fontResource],
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
        let family =
          TextEditTargeting.inputStyle(
            runIndex: 0, runs: [run], in: graph
          ).fontFamily ?? ""
        guard analysis.standardIndices.contains(index), Self.standardFonts.contains(family),
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
      guard (analysis.instructionRuns[run.instructionIndex] ?? [])
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
    let clip = try analysis.clippingRect(for: originalText.keys.sorted())
    return (content, selected, font, advances, clip)
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
      defaultSize: fontSize, defaultColor: color, clippingRect: context.clip, in: &result)
    return result
  }

  public static let standardFonts: Set<String> = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
  ]
}
