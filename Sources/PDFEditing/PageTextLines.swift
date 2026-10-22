import Foundation
import CoreText
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

  /// Whether a contiguous selection can be rewritten without moving text
  /// between its original marked-content items or changing tagged reading order.
  public func canPreserveMarkedContentOrder(runIndices: [Int]) -> Bool {
    let selected = runIndices.sorted()
    guard !selected.isEmpty, Set(selected).count == selected.count,
      let lower = selected.first, let upper = selected.last,
      upper - lower + 1 == selected.count,
      selected.allSatisfy(analysis.runs.indices.contains) else { return false }
    guard case .dictionary(let page)? = graph.objects[pageID],
      page[PDFName("StructParents")] != nil else { return true }
    let instructions = Set(selected.map { analysis.runs[$0].instructionIndex })
    let ranges = StructureTaggingAssistant.markedRanges(in: analysis.content)
    for instruction in instructions {
      let mcids = ranges.filter { $0.instructions.contains(instruction) }.compactMap(\.mcid)
      guard mcids.count == 1 else { return false }
    }
    let selectedSet = Set(selected)
    guard let structureRunOrder = analysis.taggedStructureRunOrder else { return false }
    let selectedStructureOrder = structureRunOrder.filter(selectedSet.contains)
    return selectedStructureOrder == selected
  }

  public func validate(originalText: [Int: String], fontSize: Double, color: [Double],
    standardFontAdvances: [Int: Double] = [:]) throws {
    _ = try RewritePageTextCommand(pageID: pageID, originalText: originalText, lines: [],
      fontSize: fontSize, color: color, standardFontAdvances: standardFontAdvances)
      .resolved(in: graph, analysis: analysis)
  }

  /// Explain the first graphics-state restriction that blocks this run set.
  public func issue(for runIndices: [Int]) -> String? {
    analysis.issue(for: runIndices)
  }
}

fileprivate struct ParagraphRewriteAnalysis {
  let content: PageContent
  let runs: [TextRun]
  let fonts: [PDFName: IndexedTextFont]
  let standardIndices: Set<Int>
  let safeInstructions: Set<Int>
  let overprintInstructions: Set<Int>
  let instructionIssues: [Int: String]
  let instructionRuns: [Int: [Int]]
  let clips: [Int: [Double]]
  let taggedStructureRunOrder: [Int]?

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

  func issue(for indices: [Int]) -> String? {
    guard let first = indices.first, runs.indices.contains(first) else {
      return "Missing paragraph text"
    }
    let instruction = runs[first].instructionIndex
    guard !safeInstructions.contains(instruction) else { return nil }
    return instructionIssues[instruction]
      ?? "The surrounding graphics state is not available for safe rewriting"
  }

  init(pageID: PDFObjectID, graph: PDFGraph) throws {
    content = try PageContent.load(pageID: pageID, in: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The paragraph page is missing")
    }
    func ordinaryGraphicsState(
      _ instruction: ContentInstruction
    ) -> (safe: Bool, overprint: Bool, alpha: Double)? {
      guard instruction.operands.count == 1,
        case .name(let name)? = instruction.operands.first?.value,
        case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph),
        case .dictionary(let states)? = FontValue.resolve(resources[PDFName("ExtGState")], in: graph),
        case .dictionary(let state)? = FontValue.resolve(states[name], in: graph),
        !state.isEmpty else { return nil }
      var overprint = false
      var fillAlpha = 1.0
      let safe = state.allSatisfy { key, value in
        switch (key, FontValue.resolve(value, in: graph)) {
        case (PDFName("Type"), .name(PDFName("ExtGState"))?),
          (PDFName("BM"), .name(PDFName("Normal"))?),
          (PDFName("AIS"), .boolean(_)?),
          (PDFName("SMask"), .name(PDFName("None"))?),
          (PDFName("OPM"), .integer(0)?), (PDFName("OPM"), .integer(1)?),
          (PDFName("SA"), .boolean(_)?): return true
        case (PDFName("CA"), .integer(let n)?): return (0...1).contains(n)
        case (PDFName("CA"), .real(let n)?): return n.isFinite && (0...1).contains(n)
        case (PDFName("ca"), .integer(let n)?):
          guard (0...1).contains(n) else { return false }
          fillAlpha = Double(n)
          return true
        case (PDFName("ca"), .real(let n)?):
          guard n.isFinite, (0...1).contains(n) else { return false }
          fillAlpha = n
          return true
        case (PDFName("OP"), .boolean(_)?): return true
        case (PDFName("op"), .boolean(let enabled)?):
          overprint = overprint || enabled
          return true
        case (PDFName("SM"), .integer(let n)?): return (0...1).contains(n)
        case (PDFName("SM"), .real(let n)?): return n.isFinite && (0...1).contains(n)
        default: return false
        }
      }
      return safe ? (true, overprint, fillAlpha) : nil
    }
    guard content.segments.allSatisfy(\.isEditable),
      Set(content.segments.map(\.objectID)).count == content.segments.count else {
      throw PDFError(.unsupported, "The paragraph page repeats streams or uses unsupported content filters")
    }
    // Stroke adjustment and gradient smoothness do not affect mode-0 glyph
    // fills. Overprint mode is inert here because enabled overprint refuses.
    // Color uncertainty is different from alpha/clipping uncertainty: an
    // explicit device-gray/RGB operator replaces the current fill color.
    func deviceColorIsKnown(_ instruction: ContentInstruction?, components: Int, defaultName: String) -> Bool {
      guard case .dictionary(let resources)? = FontValue.resolve(page[PDFName("Resources")], in: graph) else { return false }
      if let value = resources[PDFName("ColorSpace")] {
        guard case .dictionary(let spaces)? = FontValue.resolve(value, in: graph) else {
          return false
        }
        guard let override = spaces[PDFName(defaultName)] else {
          // No override. Continue to operand validation below.
          return instruction.map { value in
            guard value.operands.count == components else { return false }
            return value.operands.allSatisfy {
              switch $0.value {
              case .integer(let n): return (0...1).contains(n)
              case .real(let n): return n.isFinite && (0...1).contains(n)
              default: return false
              }
            }
          } ?? true
        }
        let resolved = FontValue.resolve(override, in: graph)
        let expectedDeviceName: PDFName
        switch defaultName {
        case "DefaultGray": expectedDeviceName = PDFName("DeviceGray")
        case "DefaultRGB": expectedDeviceName = PDFName("DeviceRGB")
        default: expectedDeviceName = PDFName("DeviceCMYK")
        }
        var supported = false
        switch resolved {
        case .name(let name)?:
          supported = name == expectedDeviceName
        case .array(let values)?:
          if case .name(let family)? = values.first,
            ["ICCBased", "CalGray", "CalRGB"].contains(String(decoding: family.bytes, as: UTF8.self)),
            values.count >= 2 {
            if family == PDFName("ICCBased"),
              case .reference(let profileID) = values[1],
              case .stream(let profile)? = graph.objects[profileID],
              case .integer(let profileComponents)? = profile.dictionary[PDFName("N")] {
              supported = Int(profileComponents) == components
            } else {
              supported = (family == PDFName("CalGray") && components == 1)
                || (family == PDFName("CalRGB") && components == 3)
            }
          }
        default:
          break
        }
        guard supported else { return false }
      }
      guard let instruction else { return true }
      guard instruction.operands.count == components else { return false }
      return instruction.operands.allSatisfy {
        switch $0.value {
        case .integer(let n): return (0...1).contains(n)
        case .real(let n): return n.isFinite && (0...1).contains(n)
        default: return false
        }
      }
    }
    var stack: [(
      unsafe: Bool, unsafeReason: String?, unknownFill: Bool, unknownFillReason: String?,
      overprint: Bool, fillAlpha: Double, mode: Int, ctm: [Double], clip: [Double]?
    )] = []
    var ctm = [1.0, 0, 0, 1, 0, 0]
    var clip: [Double]?
    var clips: [Int: [Double]] = [:]
    // The current path is not part of q/Q graphics state. Apply W/W* only
    // when its following path-ending operator executes, as PDF specifies.
    var hasPath = false
    var rectangle: [Double]?
    var pendingClip = false
    var unsafe = false
    var unsafeReason: String?
    var unknownFill = !deviceColorIsKnown(nil, components: 1, defaultName: "DefaultGray")
    var unknownFillReason: String? =
      unknownFill ? "Unknown initial fill color" : nil
    var mode = 0
    var overprint = false
    var fillAlpha = 1.0
    var inText = false
    var textClipping = false
    var safe = Set<Int>()
    var overprinted = Set<Int>()
    var issues: [Int: String] = [:]
    for (index, instruction) in content.instructions.enumerated() {
      let numbers = instruction.operands.compactMap { operand -> Double? in
        switch operand.value { case .integer(let n): return Double(n); case .real(let n): return n; default: return nil }
      }
      switch instruction.operatorName {
      case "q":
        stack.append((
          unsafe, unsafeReason, unknownFill, unknownFillReason, overprint, fillAlpha,
          mode, ctm, clip
        ))
      case "Q":
        guard let state = stack.popLast() else { throw PDFError(.unsupported, "Unbalanced page graphics state") }
        unsafe = state.unsafe || (inText && textClipping)
        unsafeReason = inText && textClipping
          ? "Text clipping mode inside a text object" : state.unsafeReason
        unknownFill = state.unknownFill
        unknownFillReason = state.unknownFillReason
        overprint = state.overprint
        fillAlpha = state.fillAlpha
        mode = state.mode; ctm = state.ctm; clip = state.clip
      case "cm":
        if numbers.count == 6, numbers.allSatisfy(\.isFinite) {
          ctm = TextCanvasSupport.concatenate(ctm, numbers)
        } else {
          unsafe = true
          unsafeReason = "Malformed or non-finite coordinate transform"
        }
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
        if pendingClip || inText {
          unsafe = true
          unsafeReason = "Nested or in-text clipping path"
        }
        pendingClip = true
      case "n", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
        if pendingClip {
          if let rect = rectangle, rect.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) {
            let next = clip.map { [max($0[0],rect[0]), max($0[1],rect[1]), min($0[2],rect[2]), min($0[3],rect[3])] } ?? rect
            if next[2] > next[0], next[3] > next[1] {
              clip = next
            } else {
              unsafe = true
              unsafeReason = "Empty rectangular clip intersection"
            }
          } else {
            unsafe = true
            unsafeReason = "Non-rectangular clipping path"
          }
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
        if textClipping {
          unsafe = true
          unsafeReason = "Text clipping render mode"
          textClipping = false
        }
      case "gs":
        if let state = ordinaryGraphicsState(instruction) {
          overprint = state.overprint
          fillAlpha = state.alpha
        } else {
          unsafe = true
          unsafeReason = "Unsupported or unknown ExtGState"
        }
      case "cs", "sc", "scn":
        unknownFill = true
        unknownFillReason = "Unsupported or unresolved fill color space"
      case "g":
        unknownFill = !deviceColorIsKnown(
          instruction, components: 1, defaultName: "DefaultGray")
        unknownFillReason = unknownFill ? "Unsupported DeviceGray fill color" : nil
      case "rg":
        unknownFill = !deviceColorIsKnown(
          instruction, components: 3, defaultName: "DefaultRGB")
        unknownFillReason = unknownFill ? "Unsupported DeviceRGB fill color" : nil
      case "k":
        // Retain the existing CMYK profile; it cannot establish a new known
        // RGB preview after an unsupported color-space operation.
        unknownFill = unknownFill || !deviceColorIsKnown(
          instruction, components: 4, defaultName: "DefaultCMYK")
        if unknownFill { unknownFillReason = "Unsupported DeviceCMYK fill color" }
      case "Tr":
        if case .integer(let value)? = instruction.operands.first?.value {
          mode = Int(value)
          if value >= 4 {
            unsafe = true
            unsafeReason = "Text clipping render mode"
            textClipping = true
          }
        } else {
          unsafe = true
          unsafeReason = "Malformed text render mode"
        }
      default: break
      }
      if !unsafe, !unknownFill, !pendingClip, mode == 0 {
        safe.insert(index)
        if overprint { overprinted.insert(index) }
        if let clip { clips[index] = clip }
      } else {
        issues[index] = unsafeReason
          ?? unknownFillReason
          ?? (pendingClip ? "Unfinished clipping path" : "Unsupported text render mode")
      }
    }
    guard stack.isEmpty, !inText, !pendingClip else {
      throw PDFError(.unsupported, "Unbalanced page content cannot be rewritten inline")
    }
    let allRuns = try TextRunIndexer.runs(in: content, graph: graph)
    runs = allRuns
    let tagged: Bool
    if case .dictionary(let page)? = graph.objects[pageID] {
      tagged = page[PDFName("StructParents")] != nil
    } else {
      tagged = false
    }
    if tagged, let layout = try? PageTextLayout.build(in: content, graph: graph),
      let clusterOrder = TextReadingOrder.structureClusterOrder(
        pageID: pageID, layout: layout, in: graph, limits: PDFLimits())
    {
      var order: [Int] = []
      var seen = Set<Int>()
      var valid = true
      for clusterIndex in clusterOrder {
        guard layout.clusters.indices.contains(clusterIndex) else {
          valid = false
          break
        }
        let runIndex = layout.clusters[clusterIndex].runIndex
        if seen.insert(runIndex).inserted {
          order.append(runIndex)
        } else if order.last != runIndex {
          valid = false
          break
        }
      }
      taggedStructureRunOrder = valid ? order : nil
    } else {
      taggedStructureRunOrder = nil
    }
    var resolved: [PDFName: IndexedTextFont] = [:]
    for resource in Set(runs.map(\.fontResource)) {
      resolved[resource] = IndexedTextFont.resolve(resource: resource, page: page, in: graph)
    }
    fonts = resolved
    standardIndices = Set(try StandardTextFont.editableRunIndices(pageID: pageID, in: graph))
    safeInstructions = safe
    overprintInstructions = overprinted
    instructionIssues = issues
    self.clips = clips
    instructionRuns = Dictionary(grouping: allRuns.indices, by: { allRuns[$0].instructionIndex })
  }
}

/// Replaces supported paragraph text with the exact lines shown by the native
/// editor. Numeric TJ advances remove the original strings while preserving
/// the pen position seen by all following, unedited text.
public struct RewritePageTextCommand: PDFEditCommand, Equatable, Sendable {
  private static let taggedRewriteRefusal =
    "This tagged paragraph needs a supported same-style line layout with preserved marked-content boundaries and reading order."

  public let pageID: PDFObjectID
  public let originalText: [Int: String]
  public let lines: [PageTextLine]
  public let fontSize: Double
  public let color: [Double]
  /// Standard-14 fonts can omit /Widths. The platform supplies unshaped
  /// advances only for those fonts; other missing metrics are refused.
  public let standardFontAdvances: [Int: Double]
  /// Output scalar counts can exceed a source run's text when paragraph
  /// discovery inserted a visual word separator at that run boundary.
  public let sourceRunOutputCounts: [Int: Int]
  public let box: PageTextBox?

  public init(
    pageID: PDFObjectID, originalText: [Int: String], lines: [PageTextLine],
    fontSize: Double, color: [Double], standardFontAdvances: [Int: Double] = [:],
    sourceRunOutputCounts: [Int: Int] = [:], box: PageTextBox? = nil
  ) {
    self.pageID = pageID
    self.originalText = originalText
    self.lines = lines
    self.fontSize = fontSize
    self.color = color
    self.standardFontAdvances = standardFontAdvances
    self.sourceRunOutputCounts = sourceRunOutputCounts
    self.box = box
  }

  public var name: String { "Edit Paragraph" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws {
    let context = try resolved(in: graph)
    if Self.hasTaggedReadingOrder(pageID: pageID, in: graph),
      try inPlaceRewriteRanges(
        content: context.content, runs: context.runs, advances: context.advances,
        font: context.font, graph: graph) == nil
    {
      throw PDFError(.unsupported, Self.taggedRewriteRefusal)
    }
  }

  /// Validates the source selection without requiring a particular output
  /// layout. The native editor uses this for its rendering-only hidden-text
  /// preview; the eventual commit still goes through `validate(in:)` and must
  /// satisfy tagged reading-order constraints.
  func validateSource(in graph: PDFGraph) throws {
    _ = try resolved(in: graph)
  }

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
    if !sourceRunOutputCounts.isEmpty {
      guard Set(sourceRunOutputCounts.keys) == Set(originalText.keys),
        originalText.allSatisfy({ index, text in
          let sourceCount = text.unicodeScalars.count
          guard let outputCount = sourceRunOutputCounts[index] else { return false }
          return outputCount >= sourceCount && outputCount <= sourceCount + 1
        })
      else {
        throw PDFError(.malformed, "The paragraph's source run mapping is invalid")
      }
    }
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
      guard analysis.safeInstructions.contains(run.instructionIndex) else {
        throw PDFError(.unsupported, "This text uses an unsupported graphics or clipping state")
      }
      if analysis.overprintInstructions.contains(run.instructionIndex),
        zip(color, run.fillColor).contains(where: { abs($0.0 - $0.1) > 1e-6 }) {
        throw PDFError(
          .unsupported,
          "Changing the color of overprint-enabled text is not supported; the original color can still be edited")
      }
      guard run.text == originalText[index], ["Tj", "TJ"].contains(instruction.operatorName),
        run.fontSize.isFinite, run.fontSize > 0,
        TextCanvasSupport.inlineObliqueness(for: transform) != nil,
        run.charSpacing.isFinite, abs(run.charSpacing) <= 144,
        run.wordSpacing.isFinite, abs(run.wordSpacing) <= 144,
        abs(run.horizontalScale - 100) < 1e-6, abs(run.rise) < 1e-6,
        let font = analysis.fonts[run.fontResource],
        font.isInlineEditable,
        let segment = content.segmentIndex(for: TextStyleSupport.fullSpan(of: instruction)),
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
    try Self.validateNoTextCollisions(
      lines, selectedRunIndices: Set(originalText.keys), pageID: pageID,
      graph: graph, analysis: analysis, defaultFont: font, defaultFontSize: fontSize)
    return (content, selected, font, advances, clip)
  }

  /// Refuse a replacement when its measured text box would cover text outside
  /// the selected runs. Reconstructed paragraph blocks can contain both
  /// selected and unselected runs, so collision checks operate at glyph level.
  private static func validateNoTextCollisions(
    _ lines: [PageTextLine], selectedRunIndices: Set<Int>, pageID: PDFObjectID,
    graph: PDFGraph, analysis: ParagraphRewriteAnalysis, defaultFont: IndexedTextFont,
    defaultFontSize: Double
  ) throws {
    guard !lines.isEmpty else { return }
    let layout: PageTextLayout
    do {
      layout = try PageTextLayout.build(in: analysis.content, graph: graph)
    } catch {
      throw PDFError(.unsupported, "Cannot check the edited paragraph against nearby text")
    }
    let independentGlyphs = layout.clusters.filter {
      !selectedRunIndices.contains($0.runIndex)
    }
    guard !independentGlyphs.isEmpty else { return }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Missing text page")
    }

    var standardFontsByName: [String: CTFont] = [:]
    func standardFont(named name: String) -> CTFont {
      if let font = standardFontsByName[name] { return font }
      let font = CTFontCreateWithName(name as CFString, 1_000, nil)
      standardFontsByName[name] = font
      return font
    }

    func standardWidths(of text: String, family: String) -> [Double]? {
      guard Self.standardFonts.contains(family), StandardTextFont(rawValue: family) != nil,
        StandardTextFont.canEncode(text)
      else { return nil }
      let characters = Array(text.utf16)
      guard characters.count == text.unicodeScalars.count else { return nil }
      let font = standardFont(named: family)
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count),
        glyphs.allSatisfy({ $0 != 0 }) else { return nil }
      var advances = [CGSize](repeating: .zero, count: glyphs.count)
      _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
      guard advances.allSatisfy({ $0.width.isFinite && $0.width >= 0 }) else { return nil }
      return advances.map { $0.width.rounded() }
    }

    var outputOutlineMetrics: [PDFObjectID: TrueTypeOutlineMetrics] = [:]
    var fontsWithoutOutputOutlines: Set<PDFObjectID> = []
    var customFontOutlineMetrics: [String: TrueTypeOutlineMetrics] = [:]
    var customFontsWithoutOutlines: Set<String> = []
    func outlineMetrics(for font: IndexedTextFont) -> TrueTypeOutlineMetrics? {
      if let cached = outputOutlineMetrics[font.fontID] { return cached }
      guard !fontsWithoutOutputOutlines.contains(font.fontID) else { return nil }
      guard let metrics = font.outlineMetrics else {
        fontsWithoutOutputOutlines.insert(font.fontID)
        return nil
      }
      outputOutlineMetrics[font.fontID] = metrics
      return metrics
    }
    func outlineMetrics(forCustomFont font: CustomTextFont) -> TrueTypeOutlineMetrics? {
      if let cached = customFontOutlineMetrics[font.identifier] { return cached }
      guard !customFontsWithoutOutlines.contains(font.identifier) else { return nil }
      guard let metrics = try? TrueTypeOutlineMetrics(program: font.program) else {
        customFontsWithoutOutlines.insert(font.identifier)
        return nil
      }
      customFontOutlineMetrics[font.identifier] = metrics
      return metrics
    }

    /// Measure output glyphs individually when the font exposes its outlines.
    /// A single line rectangle can extend through a neighboring line's ink
    /// box even when the glyphs themselves remain separated.
    func inkBounds(of text: String, font: IndexedTextFont?, standardFamily: String? = nil,
      customFont: CustomTextFont? = nil, size: Double, spacing: Double,
      x: Double, baseline: Double, obliqueness: Double = 0) -> [[Double]]?
    {
      guard size.isFinite, size > 0, spacing.isFinite,
        x.isFinite, baseline.isFinite, obliqueness.isFinite,
        abs(obliqueness) <= 0.35 else { return nil }
      if text.isEmpty { return [] }

      func pageBounds(_ rect: [Double], pen: Double, scale: Double) -> [Double]? {
        guard rect.count == 4, rect.allSatisfy(\.isFinite), scale.isFinite else { return nil }
        let lowerShift = obliqueness * rect[1] * scale
        let upperShift = obliqueness * rect[3] * scale
        let bounds = [
          x + pen + rect[0] * scale + min(lowerShift, upperShift),
          baseline + rect[1] * scale,
          x + pen + rect[2] * scale + max(lowerShift, upperShift),
          baseline + rect[3] * scale,
        ]
        return bounds.allSatisfy(\.isFinite) ? bounds : nil
      }

      if let font {
        guard let metrics = outlineMetrics(for: font),
          metrics.inspector.unitsPerEm > 0,
          let codes = font.encode(text), let glyphs = font.glyphs(codes), !glyphs.isEmpty
        else { return nil }
        let unitScale = size / Double(metrics.inspector.unitsPerEm)
        var pen = 0.0
        var result: [[Double]] = []
        for glyph in glyphs {
          guard let width = glyph.width,
            width.isFinite, width >= 0 else { return nil }
          guard let glyphID = font.outlineGlyphID(for: glyph, inspector: metrics.inspector) else {
            return nil
          }
          if let box = metrics.bounds(glyphID: glyphID) {
            guard let bounds = pageBounds(box.map(Double.init), pen: pen, scale: unitScale) else { return nil }
            result.append(bounds)
          }
          pen += width * size / 1_000 + spacing
        }
        return result
      }

      if let customFont {
        guard let metrics = outlineMetrics(forCustomFont: customFont),
          metrics.inspector.unitsPerEm > 0 else { return nil }
        let unitScale = size / Double(metrics.inspector.unitsPerEm)
        var pen = 0.0
        var result: [[Double]] = []
        for scalar in text.unicodeScalars {
          guard let glyphID = metrics.inspector.unicodeToGlyph[Int(scalar.value)],
            glyphID > 0, glyphID < metrics.inspector.glyphCount,
            let advance = metrics.inspector.advances[glyphID], advance >= 0 else { return nil }
          if let box = metrics.bounds(glyphID: glyphID) {
            guard let bounds = pageBounds(box.map(Double.init), pen: pen, scale: unitScale) else { return nil }
            result.append(bounds)
          }
          pen += Double(advance) * unitScale + spacing
        }
        return result
      }

      guard let standardFamily, Self.standardFonts.contains(standardFamily),
        StandardTextFont(rawValue: standardFamily) != nil,
        let widths = standardWidths(of: text, family: standardFamily),
        widths.count == text.unicodeScalars.count else { return nil }
      let characters = Array(text.utf16)
      guard characters.count == text.unicodeScalars.count else { return nil }
      let coreTextFont = standardFont(named: standardFamily)
      var glyphs = [CGGlyph](repeating: 0, count: characters.count)
      guard CTFontGetGlyphsForCharacters(coreTextFont, characters, &glyphs, glyphs.count),
        glyphs.allSatisfy({ $0 != 0 }) else { return nil }
      var rects = [CGRect](repeating: .zero, count: glyphs.count)
      _ = CTFontGetBoundingRectsForGlyphs(coreTextFont, .horizontal, glyphs, &rects, glyphs.count)
      var pen = 0.0
      var result: [[Double]] = []
      for (index, rect) in rects.enumerated() {
        if !rect.isNull, rect.width > 0, rect.height > 0 {
          let scale = size / 1_000
          guard let bounds = pageBounds(
            [Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY)],
            pen: pen, scale: scale) else { return nil }
          result.append(bounds)
        }
        pen += widths[index] * size / 1_000 + spacing
      }
      return result
    }

    func bounds(of text: String, font: IndexedTextFont?, standardFamily: String? = nil,
      customFont: CustomTextFont? = nil,
      size: Double, spacing: Double)
      -> (min: Double, max: Double)?
    {
      guard size.isFinite, size > 0, spacing.isFinite else { return nil }
      if text.isEmpty { return (0, 0) }
      let widths: [Double]
      if let font {
        guard let codes = font.encode(text), let glyphs = font.glyphs(codes), !glyphs.isEmpty else {
          return nil
        }
        if glyphs.contains(where: { $0.width == nil }) {
          let family = font.baseFont.split(separator: "+", maxSplits: 1).last.map(String.init)
          let isCanonicalStandard = analysis.runs.indices.contains { index in
            analysis.standardIndices.contains(index) && analysis.runs[index].fontResource == font.resource
          }
          guard isCanonicalStandard, let family, Self.standardFonts.contains(family) else {
            return nil
          }
          let glyphText = glyphs.map(\.text).joined()
          guard let measured = standardWidths(of: glyphText, family: family),
            measured.count == glyphs.count else { return nil }
          widths = measured
        } else {
          widths = glyphs.compactMap(\.width)
        }
      } else if let customFont {
        guard let inspector = outlineMetrics(forCustomFont: customFont)?.inspector,
          inspector.permitsEditableSubsetEmbedding else { return nil }
        let advances = text.unicodeScalars.compactMap { scalar -> Double? in
          guard let glyph = inspector.unicodeToGlyph[Int(scalar.value)],
            glyph > 0, glyph < inspector.glyphCount,
            let advance = inspector.advances[glyph] else { return nil }
          return Double(advance) * 1_000 / Double(inspector.unitsPerEm)
        }
        guard advances.count == text.unicodeScalars.count else { return nil }
        widths = advances
      } else if let standardFamily, let measured = standardWidths(of: text, family: standardFamily) {
        widths = measured
      } else {
        return nil
      }
      guard !widths.isEmpty else { return nil }
      var pen = 0.0
      var minimum = 0.0
      var maximum = 0.0
      for width in widths {
        guard width.isFinite, width >= 0 else { return nil }
        let glyphEnd = pen + width * size / 1_000
        minimum = min(minimum, min(pen, glyphEnd))
        maximum = max(maximum, max(pen, glyphEnd))
        pen = glyphEnd + spacing
        minimum = min(minimum, pen)
        maximum = max(maximum, pen)
      }
      return (minimum, maximum)
    }

    func font(for format: PageTextFormat) -> IndexedTextFont? {
      guard let source = format.sourceFont else { return nil }
      return IndexedTextFont.resolve(resource: source.resource, page: page, in: graph)
    }

    func embeddedInkBounds(for glyph: TextCluster) -> [Double]? {
      guard analysis.runs.indices.contains(glyph.runIndex) else { return nil }
      let run = analysis.runs[glyph.runIndex]
      guard let font = analysis.fonts[run.fontResource],
        let metrics = outlineMetrics(for: font), metrics.inspector.unitsPerEm > 0,
        let sourceGlyphs = font.glyphs(run.rawCodes), sourceGlyphs.indices.contains(glyph.glyphIndex),
        let glyphID = font.outlineGlyphID(
          for: sourceGlyphs[glyph.glyphIndex], inspector: metrics.inspector),
        let box = metrics.bounds(glyphID: glyphID)
      else { return nil }
      let matrix = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      guard matrix.count == 6, matrix.allSatisfy(\.isFinite),
        run.fontSize.isFinite, run.fontSize > 0, run.rise.isFinite,
        run.horizontalScale.isFinite else { return nil }
      let textX = glyph.origin[0] - matrix[4] - run.rise * matrix[2]
      let textY = glyph.origin[1] - matrix[5] - run.rise * matrix[3]
      let position: Double
      if abs(matrix[0]) > 1e-9 {
        position = textX / matrix[0]
      } else if abs(matrix[1]) > 1e-9 {
        position = textY / matrix[1]
      } else {
        return nil
      }
      guard position.isFinite else { return nil }
      let pointScale = run.fontSize / Double(metrics.inspector.unitsPerEm)
      let horizontal = pointScale * max(0.01, min(1000, run.horizontalScale)) / 100
      let bounds = PageTextLayout.composedBounds(
        matrix: matrix, position: position,
        advance: Double(box[2] - box[0]) * horizontal,
        em: Double(box[3] - box[1]) * pointScale,
        descent: Double(box[1]) * pointScale,
        xOffset: Double(box[0]) * horizontal, rise: run.rise)
      return bounds.allSatisfy(\.isFinite) ? bounds : nil
    }

    func measuredBounds(for glyph: TextCluster) -> (bounds: [Double], hasAdvance: Bool)? {
      guard glyph.bounds.count == 4, glyph.bounds.allSatisfy(\.isFinite) else { return nil }
      if let ink = embeddedInkBounds(for: glyph) { return (ink, true) }
      if glyph.advance != nil { return (glyph.bounds, true) }
      guard analysis.runs.indices.contains(glyph.runIndex),
        analysis.standardIndices.contains(glyph.runIndex)
      else { return (glyph.bounds, false) }
      let run = analysis.runs[glyph.runIndex]
      guard let font = analysis.fonts[run.fontResource],
        let family = font.baseFont.split(separator: "+", maxSplits: 1).last.map(String.init),
        Self.standardFonts.contains(family)
      else { return (glyph.bounds, false) }
      let characters = Array(glyph.text.utf16)
      guard characters.count == 1, run.fontSize.isFinite, run.fontSize > 0,
        run.charSpacing.isFinite, run.wordSpacing.isFinite,
        run.horizontalScale.isFinite
      else { return (glyph.bounds, false) }
      let coreTextFont = standardFont(named: family)
      var standardGlyphs = [CGGlyph](repeating: 0, count: characters.count)
      guard CTFontGetGlyphsForCharacters(
        coreTextFont, characters, &standardGlyphs, characters.count) else {
        return (glyph.bounds, false)
      }
      var advances = [CGSize](repeating: .zero, count: standardGlyphs.count)
      let totalAdvance = CTFontGetAdvancesForGlyphs(
        coreTextFont, .horizontal, standardGlyphs, &advances, standardGlyphs.count)
      guard totalAdvance.isFinite, let width = advances.first?.width,
        width.isFinite, width >= 0 else { return (glyph.bounds, false) }
      let spacing = run.charSpacing + (glyph.code == 32 ? run.wordSpacing : 0)
      let advance = (width * run.fontSize / 1_000 + spacing) * run.horizontalScale / 100
      guard advance.isFinite else { return (glyph.bounds, false) }
      let matrix = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      guard matrix.count == 6, matrix.allSatisfy(\.isFinite) else {
        return (glyph.bounds, false)
      }
      let textX = glyph.origin[0] - matrix[4] - run.rise * matrix[2]
      let textY = glyph.origin[1] - matrix[5] - run.rise * matrix[3]
      let position: Double
      if abs(matrix[0]) > 1e-9 {
        position = textX / matrix[0]
      } else if abs(matrix[1]) > 1e-9 {
        position = textY / matrix[1]
      } else {
        return (glyph.bounds, false)
      }
      guard position.isFinite else { return (glyph.bounds, false) }
      let measured = PageTextLayout.composedBounds(
        matrix: matrix, position: position, advance: advance,
        em: run.fontSize, descent: 0, rise: run.rise)
      guard measured.allSatisfy(\.isFinite) else { return (glyph.bounds, false) }
      return ([
        min(glyph.bounds[0], measured[0]), min(glyph.bounds[1], measured[1]),
        max(glyph.bounds[2], measured[2]), max(glyph.bounds[3], measured[3]),
      ], true)
    }

    let independentGlyphBounds = independentGlyphs.compactMap { measuredBounds(for: $0) }
    for line in lines {
      var editedGlyphBounds: [[Double]] = []
      if line.segments.isEmpty {
        if !line.text.isEmpty {
          guard let measured = bounds(
            of: line.text, font: defaultFont, size: defaultFontSize, spacing: 0)
          else {
            throw PDFError(.unsupported,
              "Cannot safely check this edit against nearby text because output glyph widths are unavailable")
          }
          if let ink = inkBounds(of: line.text, font: defaultFont,
            size: defaultFontSize, spacing: 0, x: line.x, baseline: line.baseline) {
            editedGlyphBounds += ink
          } else {
            editedGlyphBounds.append([
              line.x + measured.min, line.baseline - defaultFontSize * 0.2,
              line.x + measured.max, line.baseline + defaultFontSize * 0.85,
            ])
          }
        }
      } else {
        for segment in line.segments where !segment.text.isEmpty {
          let segmentFont = font(for: segment.format)
          let standardFamily = segment.format.sourceFont == nil && segment.format.customFont == nil
            ? segment.format.font.rawValue : nil
          guard let measured = bounds(of: segment.text, font: segmentFont,
              standardFamily: standardFamily, customFont: segment.format.customFont,
              size: segment.format.size, spacing: segment.format.characterSpacing)
          else {
            throw PDFError(.unsupported,
              "Cannot safely check this edit against nearby text because output glyph widths are unavailable")
          }
          if let ink = inkBounds(of: segment.text, font: segmentFont,
            standardFamily: standardFamily, customFont: segment.format.customFont,
            size: segment.format.size, spacing: segment.format.characterSpacing,
            x: segment.x, baseline: line.baseline,
            obliqueness: segment.format.obliqueness) {
            let expansion = segment.format.syntheticBoldStrokeWidth / 2
            editedGlyphBounds += ink.map { bounds in
              [bounds[0] - expansion, bounds[1] - expansion,
                bounds[2] + expansion, bounds[3] + expansion]
            }
          } else {
            let expansion = segment.format.syntheticBoldStrokeWidth / 2
            let lower = -segment.format.size * 0.2
            let upper = segment.format.size * 0.85
            let lowerShift = segment.format.obliqueness * lower
            let upperShift = segment.format.obliqueness * upper
            editedGlyphBounds.append([
              segment.x + measured.min + min(lowerShift, upperShift) - expansion,
              line.baseline + lower - expansion,
              segment.x + measured.max + max(lowerShift, upperShift) + expansion,
              line.baseline + upper + expansion,
            ])
          }
        }
      }
      guard !editedGlyphBounds.isEmpty else { continue }

      // Preserve the conservative refusal for nearby text whose width cannot
      // be measured. For known glyphs, first limit pairwise outline checks to
      // candidates that can intersect this line's ink box; long output lines
      // then avoid comparing every output glyph with every page glyph.
      if independentGlyphBounds.contains(where: { other in
        guard !other.hasAdvance else { return false }
        return editedGlyphBounds.contains { edited in
          min(edited[3], other.bounds[3]) - max(edited[1], other.bounds[1]) > 0.5
        }
      }) {
        throw PDFError(.unsupported,
          "Cannot safely check this edit against nearby text because glyph widths are unavailable")
      }
      let lineBounds = [
        editedGlyphBounds.map { $0[0] }.min()!, editedGlyphBounds.map { $0[1] }.min()!,
        editedGlyphBounds.map { $0[2] }.max()!, editedGlyphBounds.map { $0[3] }.max()!,
      ]
      let nearbyGlyphBounds = independentGlyphBounds.filter { other in
        guard other.hasAdvance else { return false }
        return min(lineBounds[2], other.bounds[2]) - max(lineBounds[0], other.bounds[0]) > 0.5
          && min(lineBounds[3], other.bounds[3]) - max(lineBounds[1], other.bounds[1]) > 0.5
      }
      for editedBounds in editedGlyphBounds {
        for measured in nearbyGlyphBounds {
          let other = measured.bounds
          let overlapX = min(editedBounds[2], other[2]) - max(editedBounds[0], other[0])
          let overlapY = min(editedBounds[3], other[3]) - max(editedBounds[1], other[1])
          guard overlapX > 0.5, overlapY > 0.5 else { continue }
          throw PDFError(.unsupported,
            "This edit would overlap another text block. Shorten the text or choose a wider area.")
        }
      }
    }
  }

  private static func hasTaggedReadingOrder(pageID: PDFObjectID, in graph: PDFGraph) -> Bool {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return false }
    return page[PDFName("StructParents")] != nil
  }

  /// A same-style, fixed-geometry edit can replace its source text-show
  /// instructions directly. Keeping the glyphs under their original marked
  /// content preserves the structure-tree reading order in tagged PDFs.
  private func inPlaceRewriteRanges(
    content: PageContent, runs: [TextRun], advances: [Double], font: IndexedTextFont,
    graph: PDFGraph
  ) throws -> [(range: Range<Int>, replacement: [UInt8])]? {
    if Self.hasTaggedReadingOrder(pageID: pageID, in: graph),
      let preserved = try taggedRunPreservingRewriteRanges(
        content: content, runs: runs, advances: advances, graph: graph)
    {
      return preserved
    }
    guard lines.count == 1, runs.count == originalText.count,
      runs.count == advances.count, let first = runs.first,
      let line = lines.first, runs.allSatisfy(\.hasKnownOffset),
      runs.allSatisfy({ abs($0.wordSpacing) < 1e-8 })
    else { return nil }

    if let box {
      guard !box.wraps, abs(box.x - line.x) <= 0.02,
        abs(box.firstBaseline - line.baseline) <= 0.02 else { return nil }
    }

    let globalIndices = originalText.keys.sorted()
    guard globalIndices.count == runs.count,
      let allRuns = try? TextRunIndexer.runs(in: content, graph: graph),
      globalIndices.allSatisfy({ allRuns.indices.contains($0) }),
      Self.coversWholeTextInstructions(globalIndices, in: allRuns)
    else { return nil }

    let firstTransform = TextCanvasSupport.concatenate(first.ctm, first.matrix)
    guard firstTransform.count == 6, firstTransform.allSatisfy(\.isFinite),
      firstTransform[0] > 0, abs(firstTransform[1]) <= 1e-8
    else { return nil }
    let baseline = firstTransform[5]
    let firstX = firstTransform[4] + first.textSpaceOffset * firstTransform[0]
    guard abs(line.baseline - baseline) <= 0.02, abs(line.x - firstX) <= 0.02 else {
      return nil
    }
    for run in runs {
      let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      guard transform.count == 6, transform.allSatisfy(\.isFinite),
        abs(transform[5] - baseline) <= 0.02
      else { return nil }
    }
    // Keep the replacement within one continuous text run sequence and one
    // marked-content scope. Tagged structure trees can order MCIDs separately
    // from the content stream, so merging across MCIDs would change semantics.
    let selectedIndices = Set(globalIndices)
    guard let lower = globalIndices.first, let upper = globalIndices.last else { return nil }
    guard upper - lower + 1 == selectedIndices.count else { return nil }
    let selectedInstructionIndices = Set(runs.map(\.instructionIndex))
    var markedContentStack: [Int] = []
    var markedContentScopes: [Int: [Int]] = [:]
    for (index, instruction) in content.instructions.enumerated() {
      if selectedInstructionIndices.contains(index) {
        markedContentScopes[index] = markedContentStack
      }
      switch instruction.operatorName {
      case "BMC", "BDC": markedContentStack.append(index)
      case "EMC":
        guard !markedContentStack.isEmpty else { return nil }
        markedContentStack.removeLast()
      default: break
      }
    }
    guard markedContentStack.isEmpty,
      instructionScopeIsConsistent(selectedInstructionIndices, scopes: markedContentScopes) else {
      return nil
    }
    let firstStyle = TextEditTargeting.inputStyle(
      runIndex: globalIndices[0], runs: allRuns, in: graph)
    guard var expectedFormat = PageTextEditing.format(
      for: first, family: firstStyle.fontFamily ?? "", pageID: pageID, in: graph),
      expectedFormat.customFont == nil,
      runs.allSatisfy({ run in
        run.fontID == first.fontID && run.fontResource == first.fontResource
          && abs(run.fontSize - first.fontSize) < 1e-8
          && abs(run.charSpacing - first.charSpacing) < 1e-8
          && abs(run.fillAlpha - first.fillAlpha) < 1e-8
          && run.fillColor == first.fillColor
          && TextCanvasSupport.concatenate(run.ctm, run.matrix)[0]
            == firstTransform[0]
      })
    else { return nil }
    expectedFormat.size *= firstTransform[0]
    expectedFormat.characterSpacing *= firstTransform[0]

    var replacementParts: [([UInt8], Double)] = []
    var newAdvance = 0.0
    if line.segments.isEmpty {
      guard font.fontID == first.fontID, abs(fontSize - expectedFormat.size) <= 0.02,
        color == expectedFormat.color
      else { return nil }
      guard let codes = font.encode(line.text),
        PageTextSourceFont.canWriteInline(line.text) else { return nil }
      let measured: Double
      if let advance = font.advance(
          of: codes, fontSize: first.fontSize, charSpacing: first.charSpacing,
          wordSpacing: first.wordSpacing, horizontalScale: first.horizontalScale),
        advance.isFinite {
        measured = advance
      } else {
        guard let family = firstStyle.fontFamily,
          let standardFont = StandardTextFont(rawValue: family),
          let standardIndices = try? StandardTextFont.editableRunIndices(pageID: pageID, in: graph),
          globalIndices.allSatisfy(standardIndices.contains),
          font.simple?.differences.isEmpty == true, font.simple?.toUnicode == nil,
          let advance = Self.standardAdvance(
            line.text, font: standardFont, size: first.fontSize,
            charSpacing: first.charSpacing, wordSpacing: first.wordSpacing,
            horizontalScale: first.horizontalScale), advance.isFinite
        else { return nil }
        measured = advance
      }
      newAdvance = measured
      replacementParts = [(ReplaceTextCommand.literalStringBytes(codes), 0)]
    } else {
      guard let firstSegment = line.segments.first,
        line.segments.map(\.text).joined() == line.text,
        abs(firstSegment.x - line.x) <= 0.02 else { return nil }
      let segmentStandardFont = firstStyle.fontFamily.flatMap(StandardTextFont.init(rawValue:))
      let segmentStandardIndices = try? StandardTextFont.editableRunIndices(pageID: pageID, in: graph)
      let mayUseStandardMetrics = segmentStandardFont != nil
        && segmentStandardIndices.map { globalIndices.allSatisfy($0.contains) } == true
        && font.simple?.differences.isEmpty == true && font.simple?.toUnicode == nil
      var pagePen = line.x
      for segment in line.segments {
        var normalizedFormat = segment.format
        normalizedFormat.characterSpacing = expectedFormat.characterSpacing
        guard !segment.text.isEmpty, segment.format.isValid, segment.x.isFinite,
          abs(segment.x - pagePen) <= 0.02,
          normalizedFormat == expectedFormat,
          PageTextSourceFont.canWriteInline(segment.text),
          let codes = font.encode(segment.text), let glyphs = font.glyphs(codes),
          glyphs.map(\.text).joined() == segment.text
        else { return nil }
        for glyph in glyphs {
          let glyphWidth: Double
          if let width = glyph.width, width.isFinite, width >= 0 {
            glyphWidth = width
          } else {
            guard mayUseStandardMetrics, glyph.text.unicodeScalars.count == 1,
              let segmentStandardFont,
              let width = Self.standardAdvance(
                glyph.text, font: segmentStandardFont, size: 1_000,
                charSpacing: 0, wordSpacing: 0, horizontalScale: 100),
              width.isFinite, width >= 0 else { return nil }
            glyphWidth = width
          }
          let desiredPageAdvance = glyphWidth * segment.format.size / 1_000
            + segment.format.characterSpacing
          guard desiredPageAdvance.isFinite, desiredPageAdvance >= 0 else { return nil }
          let sourceTextAdvance: Double
          if let measured = font.advance(
              of: glyph.codes, fontSize: first.fontSize, charSpacing: first.charSpacing,
              wordSpacing: first.wordSpacing, horizontalScale: first.horizontalScale),
            measured.isFinite {
            sourceTextAdvance = measured
          } else {
            guard glyph.text.unicodeScalars.count == 1,
              let family = firstStyle.fontFamily,
              let standardFont = StandardTextFont(rawValue: family),
              let standardIndices = try? StandardTextFont.editableRunIndices(
                pageID: pageID, in: graph),
              globalIndices.allSatisfy(standardIndices.contains),
              font.simple?.differences.isEmpty == true, font.simple?.toUnicode == nil,
              let measured = Self.standardAdvance(
                glyph.text, font: standardFont, size: first.fontSize,
                charSpacing: first.charSpacing, wordSpacing: first.wordSpacing,
                horizontalScale: first.horizontalScale), measured.isFinite
            else { return nil }
            sourceTextAdvance = measured
          }
          let sourcePageAdvance = sourceTextAdvance * firstTransform[0]
          let horizontalScale = first.horizontalScale / 100
          guard sourcePageAdvance.isFinite, horizontalScale > 0 else { return nil }
          let adjustment = (sourcePageAdvance - desiredPageAdvance) * 1_000
            / (first.fontSize * horizontalScale * firstTransform[0])
          guard adjustment.isFinite, abs(adjustment) <= 1_000_000 else { return nil }
          replacementParts.append((
            ReplaceTextCommand.literalStringBytes(glyph.codes), adjustment))
          pagePen += desiredPageAdvance
          newAdvance += desiredPageAdvance / firstTransform[0]
        }
      }
      let trailingWhitespaceIndices = Array(globalIndices.reversed().prefix { index in
        allRuns[index].text.allSatisfy(\.isWhitespace)
      }.reversed())
      if line.text.last?.isWhitespace != true,
        let firstTrailingIndex = trailingWhitespaceIndices.first
      {
        let firstTrailingRun = allRuns[firstTrailingIndex]
        let firstTrailingTransform = TextCanvasSupport.concatenate(
          firstTrailingRun.ctm, firstTrailingRun.matrix)
        let firstTrailingX = firstTrailingTransform[4]
          + firstTrailingRun.textSpaceOffset * firstTrailingTransform[0]
        guard firstTrailingTransform.count == 6,
          firstTrailingTransform.allSatisfy(\.isFinite),
          abs(pagePen - firstTrailingX) <= 0.02 else { return nil }
        for index in trailingWhitespaceIndices {
          guard let runOffset = globalIndices.firstIndex(of: index) else { return nil }
          let sourceRun = allRuns[index]
          let sourcePageAdvance = advances[runOffset] * firstTransform[0]
          guard !sourceRun.rawCodes.isEmpty, sourceRun.text.allSatisfy(\.isWhitespace),
            font.decode(sourceRun.rawCodes) == sourceRun.text,
            PageTextSourceFont.canWriteInline(sourceRun.text),
            sourcePageAdvance.isFinite, sourcePageAdvance >= 0 else { return nil }
          replacementParts.append((
            ReplaceTextCommand.literalStringBytes(sourceRun.rawCodes), 0))
          newAdvance += advances[runOffset]
          pagePen += sourcePageAdvance
        }
      }
    }

    let indicesByInstruction = Dictionary(grouping: runs.indices, by: { runs[$0].instructionIndex })
    let instructionIndices = indicesByInstruction.keys.sorted()
    guard let firstInstruction = instructionIndices.first else { return nil }
    var replacements: [(range: Range<Int>, replacement: [UInt8])] = []
    for instructionIndex in instructionIndices {
      guard let indices = indicesByInstruction[instructionIndex], let runIndex = indices.first,
        content.instructions.indices.contains(instructionIndex)
      else { return nil }
      let instruction = content.instructions[instructionIndex]
      guard ["Tj", "TJ"].contains(instruction.operatorName) else { return nil }
      var oldAdvance = indices.reduce(0.0) { $0 + advances[$1] }
      if case .array(let entries)? = instruction.operands.first?.value {
        for entry in entries {
          switch entry {
          case .integer(let value):
            oldAdvance -= Double(value) * runs[runIndex].fontSize / 1_000
              * runs[runIndex].horizontalScale / 100
          case .real(let value):
            oldAdvance -= value * runs[runIndex].fontSize / 1_000
              * runs[runIndex].horizontalScale / 100
          case .string: break
          default: return nil
          }
        }
      }
      guard oldAdvance.isFinite,
        abs(oldAdvance) <= 1_000_000,
        runs[runIndex].fontSize > 0
      else { return nil }

      let replacement: [UInt8]
      if instructionIndex == firstInstruction {
        let horizontalScale = runs[runIndex].horizontalScale / 100
        guard horizontalScale > 0 else { return nil }
        let adjustment = (newAdvance - oldAdvance) * 1_000
          / (runs[runIndex].fontSize * horizontalScale)
        guard adjustment.isFinite, abs(adjustment) <= 1_000_000 else { return nil }
        var array = Array("[".utf8)
        for (codes, glyphAdjustment) in replacementParts {
          array += codes
          if abs(glyphAdjustment) > 1e-9 {
            array += Array(" \(AnnotationSupport.number(glyphAdjustment))".utf8)
          }
        }
        if abs(adjustment) > 1e-9 {
          array += Array(" \(AnnotationSupport.number(adjustment))".utf8)
        }
        replacement = array + Array("] TJ".utf8)
      } else {
        let horizontalScale = runs[runIndex].horizontalScale / 100
        guard horizontalScale > 0 else { return nil }
        let adjustment = -oldAdvance * 1_000
          / (runs[runIndex].fontSize * horizontalScale)
        guard adjustment.isFinite, abs(adjustment) <= 1_000_000 else { return nil }
        replacement = Array("[\(AnnotationSupport.number(adjustment))] TJ".utf8)
      }
      replacements.append((TextStyleSupport.fullSpan(of: instruction), replacement))
    }
    return replacements
  }

  /// Rewrites changed tagged lines inside their existing text-show instructions.
  /// Output keeps each line's source scalar count, uses each instruction's own
  /// font mapping, never moves glyphs between marked-content items, and restores
  /// every source instruction's ending text-matrix position.
  private func taggedRunPreservingRewriteRanges(
    content: PageContent, runs: [TextRun], advances: [Double], graph: PDFGraph
  ) throws -> [(range: Range<Int>, replacement: [UInt8])]? {
    guard runs.count == originalText.count, runs.count == advances.count,
      !runs.isEmpty, lines.count > 0, runs.allSatisfy(\.hasKnownOffset)
    else { return nil }

    let globalIndices = originalText.keys.sorted()
    guard globalIndices.count == runs.count,
      let lower = globalIndices.first, let upper = globalIndices.last,
      upper - lower + 1 == globalIndices.count,
      let allRuns = try? TextRunIndexer.runs(in: content, graph: graph),
      globalIndices.allSatisfy(allRuns.indices.contains),
      Self.coversWholeTextInstructions(globalIndices, in: allRuns)
    else { return nil }

    let first = runs[0]
    let firstTransform = TextCanvasSupport.concatenate(first.ctm, first.matrix)
    guard firstTransform.count == 6, firstTransform.allSatisfy(\.isFinite),
      firstTransform[0] > 0, abs(firstTransform[1]) <= 1e-8
    else { return nil }

    // Keep this path to actual multi-line or multi-MCID paragraphs. The
    // established one-line, one-scope writer also supports length changes.
    let selectedInstructionIndices = Set(runs.map(\.instructionIndex))
    let markedRanges = StructureTaggingAssistant.markedRanges(in: content)
    for instructionIndex in selectedInstructionIndices {
      let mcidRanges = markedRanges.filter {
        $0.instructions.contains(instructionIndex) && $0.mcid != nil
      }
      guard mcidRanges.count == 1 else { return nil }
    }
    let distinctMCIDs = Set(selectedInstructionIndices.flatMap { instructionIndex in
      markedRanges.filter {
        $0.instructions.contains(instructionIndex) && $0.mcid != nil
      }.compactMap(\.mcid)
    })
    guard lines.count > 1 || distinctMCIDs.count > 1 else { return nil }

    // The tagged tree must describe the selected run sequence in the same
    // order. A missing, duplicate, or reordered run is not safe to rewrite.
    guard let layout = try? PageTextLayout.build(in: content, graph: graph),
      let orderedClusters = TextReadingOrder.structureClusterOrder(
        pageID: pageID, layout: layout, in: graph, limits: PDFLimits())
    else { return nil }
    let selectedSet = Set(globalIndices)
    var structureRunOrder: [Int] = []
    var seenRuns = Set<Int>()
    for clusterIndex in orderedClusters {
      guard layout.clusters.indices.contains(clusterIndex) else { return nil }
      let runIndex = layout.clusters[clusterIndex].runIndex
      guard selectedSet.contains(runIndex) else { continue }
      if seenRuns.insert(runIndex).inserted {
        structureRunOrder.append(runIndex)
      } else if structureRunOrder.last != runIndex {
        return nil
      }
    }
    guard structureRunOrder == globalIndices else { return nil }
    if let box {
      guard box.x.isFinite, box.firstBaseline.isFinite,
        abs(box.x - (lines.first?.x ?? .infinity)) <= 0.02,
        abs(box.firstBaseline - (lines.first?.baseline ?? .infinity)) <= 0.02,
        lines.count == 1 || box.wraps
      else { return nil }
    }

    // Group source runs by their original baseline. A source line may use a
    // different subset resource from the next line, so validate style within
    // each line and leave unchanged lines byte-for-byte intact.
    var sourceLineRuns: [[Int]] = []
    var sourceLineBaselines: [Double] = []
    for (offset, run) in runs.enumerated() {
      let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      guard transform.count == 6, transform.allSatisfy(\.isFinite),
        transform[0] > 0, abs(transform[1]) <= 1e-8,
        run.text == originalText[globalIndices[offset]],
        !run.text.contains("\n"), !run.text.contains("\r")
      else { return nil }
      let baseline = transform[5]
      if let previous = sourceLineBaselines.last, abs(previous - baseline) <= 0.02 {
        sourceLineRuns[sourceLineRuns.count - 1].append(globalIndices[offset])
      } else {
        guard !sourceLineBaselines.contains(where: { abs($0 - baseline) <= 0.02 }) else {
          return nil
        }
        sourceLineBaselines.append(baseline)
        sourceLineRuns.append([globalIndices[offset]])
      }
    }
    guard sourceLineRuns.count == lines.count else { return nil }

    let standardIndices = try? StandardTextFont.editableRunIndices(pageID: pageID, in: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else { return nil }

    struct OutputGlyph { let text: String; let x: Double }
    var outputByRun: [Int: [OutputGlyph]] = [:]
    var preservedRunIndices = Set<Int>()
    var hasWhitespaceOnlyLineNormalization = false

    for lineIndex in lines.indices {
      let line = lines[lineIndex]
      let sourceIndices = sourceLineRuns[lineIndex]
      guard abs(line.baseline - sourceLineBaselines[lineIndex]) <= 0.02,
        let firstSourceIndex = sourceIndices.first,
        let sourceOffset = globalIndices.firstIndex(of: firstSourceIndex)
      else { return nil }
      let sourceRun = runs[sourceOffset]
      let sourceTransform = TextCanvasSupport.concatenate(sourceRun.ctm, sourceRun.matrix)
      let sourceX = sourceTransform[4] + sourceRun.textSpaceOffset * sourceTransform[0]
      guard abs(line.x - sourceX) <= 0.02 else { return nil }

      if !line.segments.isEmpty {
        guard line.segments.map(\.text).joined() == line.text,
          let firstSegment = line.segments.first,
          abs(firstSegment.x - line.x) <= 0.02
        else { return nil }
      }
      let sourceLineText = sourceIndices.compactMap { originalText[$0] }.joined()
      let sourceScalars = Array(sourceLineText.unicodeScalars)
      let outputScalars = Array(line.text.unicodeScalars)
      let sourceVisibleText = sourceScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
      }
      let outputVisibleText = outputScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
      }
      let sourceWhitespaceCount = sourceScalars.count - sourceVisibleText.count
      let outputWhitespaceCount = outputScalars.count - outputVisibleText.count
      if sourceVisibleText == outputVisibleText && sourceWhitespaceCount == outputWhitespaceCount {
        // Keep visually unchanged lines in their original source instructions;
        // source extraction can place wrapped whitespace at different offsets.
        preservedRunIndices.formUnion(sourceIndices)
        hasWhitespaceOnlyLineNormalization = hasWhitespaceOnlyLineNormalization
          || sourceLineText != line.text
        continue
      }

      let sourceStyle = TextEditTargeting.inputStyle(
        runIndex: firstSourceIndex, runs: allRuns, in: graph)
      guard var lineFormat = PageTextEditing.format(
        for: sourceRun, family: sourceStyle.fontFamily ?? "", pageID: pageID, in: graph),
        lineFormat.customFont == nil,
        let lineFont = IndexedTextFont.resolve(
          resource: sourceRun.fontResource, page: page, in: graph),
        lineFont.fontID == sourceRun.fontID, lineFont.isInlineEditable
      else { return nil }
      lineFormat.size *= sourceTransform[0]
      lineFormat.characterSpacing *= sourceTransform[0]

      if line.segments.isEmpty {
        guard abs(fontSize - lineFormat.size) <= 0.02, color == lineFormat.color,
          PageTextSourceFont.canWriteInline(line.text)
        else { return nil }
      }
      let segments = line.segments.isEmpty
        ? [PageTextSegment(text: line.text, x: line.x, format: lineFormat)]
        : line.segments

      let sourceFontResources = Set(sourceIndices.compactMap { index in
        globalIndices.firstIndex(of: index).map { runs[$0].fontResource }
      })
      guard segments.allSatisfy({ segment in
        !segment.text.isEmpty && segment.format.isValid
          && segment.format.customFont == nil && segment.x.isFinite
          && sourceFontResources.contains(segment.format.sourceFont?.resource ?? sourceRun.fontResource)
      }) else { return nil }

      var pagePen = line.x
      var lineGlyphs: [OutputGlyph] = []
      for segment in segments {
        let segmentResource = segment.format.sourceFont?.resource ?? sourceRun.fontResource
        guard let segmentFont = IndexedTextFont.resolve(
          resource: segmentResource, page: page, in: graph), segmentFont.isInlineEditable
        else { return nil }
        let fontRunIndex = sourceIndices.first(where: { index in
          guard let offset = globalIndices.firstIndex(of: index) else { return false }
          return runs[offset].fontResource == segmentResource
        }) ?? firstSourceIndex
        let segmentStyle = TextEditTargeting.inputStyle(
          runIndex: fontRunIndex, runs: allRuns, in: graph)
        let segmentStandardFont = segment.format.sourceFont == nil
          ? segmentStyle.fontFamily.flatMap(StandardTextFont.init(rawValue:)) : nil
        let segmentRunIndices = sourceIndices.filter { index in
          guard let offset = globalIndices.firstIndex(of: index) else { return false }
          return runs[offset].fontResource == segmentResource
        }
        let mayUseSegmentStandardMetrics = segmentStandardFont != nil
          && standardIndices.map { segmentRunIndices.allSatisfy($0.contains) } == true
          && segmentFont.simple?.differences.isEmpty == true && segmentFont.simple?.toUnicode == nil
        guard abs(segment.x - pagePen) <= 0.02,
          PageTextSourceFont.canWriteInline(segment.text),
          let encoded = segmentFont.encode(segment.text), let glyphs = segmentFont.glyphs(encoded),
          glyphs.map(\.text).joined() == segment.text
        else { return nil }
        for glyph in glyphs {
          guard glyph.text.unicodeScalars.count == 1 else { return nil }
          let glyphWidth: Double
          if let width = glyph.width, width.isFinite, width >= 0 {
            glyphWidth = width
          } else {
            guard mayUseSegmentStandardMetrics, let segmentStandardFont,
              let width = Self.standardAdvance(
                glyph.text, font: segmentStandardFont, size: 1_000,
                charSpacing: 0, wordSpacing: 0, horizontalScale: 100),
              width.isFinite, width >= 0
            else { return nil }
            glyphWidth = width
          }
          let desiredAdvance = glyphWidth * segment.format.size / 1_000
            + segment.format.characterSpacing
          guard desiredAdvance.isFinite, desiredAdvance >= 0 else { return nil }
          lineGlyphs.append(OutputGlyph(text: glyph.text, x: pagePen))
          pagePen += desiredAdvance
        }
      }

      let expectedScalarCount = sourceIndices.reduce(0) { total, index in
        total + (sourceRunOutputCounts[index]
          ?? originalText[index]?.unicodeScalars.count ?? 0)
      }
      guard lineGlyphs.count <= expectedScalarCount else { return nil }
      let omittedScalarCount = expectedScalarCount - lineGlyphs.count
      if omittedScalarCount > 0 {
        let omittedWhitespace = sourceScalars.suffix(omittedScalarCount)
        guard omittedWhitespace.count == omittedScalarCount,
          omittedWhitespace.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        for scalar in omittedWhitespace {
          lineGlyphs.append(OutputGlyph(text: String(scalar), x: pagePen))
        }
      }
      var cursor = 0
      for index in sourceIndices {
        guard let sourceText = originalText[index] else { return nil }
        let count = sourceRunOutputCounts[index] ?? sourceText.unicodeScalars.count
        guard count > 0, cursor + count <= lineGlyphs.count else { return nil }
        outputByRun[index] = Array(lineGlyphs[cursor..<(cursor + count)])
        cursor += count
      }
      guard cursor == lineGlyphs.count else { return nil }
    }

    let instructionRunGroups = Dictionary(grouping: globalIndices.enumerated()) {
      runs[$0.offset].instructionIndex
    }
    for indices in instructionRunGroups.values {
      let runIndices = indices.map(\.element)
      let preservedCount = runIndices.filter(preservedRunIndices.contains).count
      guard preservedCount == 0 || preservedCount == runIndices.count else { return nil }
    }
    let rewrittenIndices = globalIndices.filter { !preservedRunIndices.contains($0) }
    guard !rewrittenIndices.isEmpty || !hasWhitespaceOnlyLineNormalization else { return [] }
    guard !rewrittenIndices.isEmpty else { return nil }
    let offsetsByGlobalIndex = Dictionary(uniqueKeysWithValues: globalIndices.enumerated().map {
      ($1, $0)
    })
    let indicesByInstruction = Dictionary(grouping: rewrittenIndices) {
      index in runs[offsetsByGlobalIndex[index]!].instructionIndex
    }
    var replacements: [(range: Range<Int>, replacement: [UInt8])] = []
    for instructionIndex in indicesByInstruction.keys.sorted() {
      guard let indices = indicesByInstruction[instructionIndex], let firstIndex = indices.first,
        content.instructions.indices.contains(instructionIndex),
        let firstOffset = offsetsByGlobalIndex[firstIndex]
      else { return nil }
      let instruction = content.instructions[instructionIndex]
      guard ["Tj", "TJ"].contains(instruction.operatorName) else { return nil }
      let instructionRun = runs[firstOffset]
      guard let instructionFont = IndexedTextFont.resolve(
        resource: instructionRun.fontResource, page: page, in: graph),
        instructionFont.fontID == instructionRun.fontID,
        instructionFont.isInlineEditable
      else { return nil }
      let transform = TextCanvasSupport.concatenate(instructionRun.ctm, instructionRun.matrix)
      guard transform.count == 6, transform.allSatisfy(\.isFinite),
        transform[0] > 0, abs(transform[1]) <= 1e-8,
        indices.allSatisfy({
          guard let offset = offsetsByGlobalIndex[$0] else { return false }
          let run = runs[offset]
          let runTransform = TextCanvasSupport.concatenate(runs[offset].ctm, runs[offset].matrix)
          return runTransform.count == 6 && runTransform.allSatisfy(\.isFinite)
            && abs(runTransform[5] - transform[5]) <= 0.02
            && run.fontID == instructionRun.fontID
            && run.fontResource == instructionRun.fontResource
            && abs(run.fontSize - instructionRun.fontSize) < 1e-8
            && abs(run.charSpacing - instructionRun.charSpacing) < 1e-8
            && abs(run.fillAlpha - instructionRun.fillAlpha) < 1e-8
            && run.fillColor == instructionRun.fillColor
        })
      else { return nil }

      var oldAdvance = 0.0
      for index in indices {
        guard let offset = offsetsByGlobalIndex[index] else { return nil }
        oldAdvance += advances[offset]
      }
      if case .array(let entries)? = instruction.operands.first?.value {
        for entry in entries {
          switch entry {
          case .integer(let value):
            oldAdvance -= Double(value) * instructionRun.fontSize / 1_000
              * instructionRun.horizontalScale / 100
          case .real(let value):
            oldAdvance -= value * instructionRun.fontSize / 1_000
              * instructionRun.horizontalScale / 100
          case .string: break
          default: return nil
          }
        }
      }
      let denominator = instructionRun.fontSize
        * instructionRun.horizontalScale / 100 * transform[0]
      guard oldAdvance.isFinite, abs(oldAdvance) <= 1_000_000,
        denominator.isFinite, denominator > 0
      else { return nil }

      let instructionGlyphs = indices.flatMap { outputByRun[$0] ?? [] }
      guard !instructionGlyphs.isEmpty else { return nil }
      let instructionStyle = TextEditTargeting.inputStyle(
        runIndex: firstIndex, runs: allRuns, in: graph)
      let instructionStandardFont = instructionStyle.fontFamily.flatMap(
        StandardTextFont.init(rawValue:))
      let mayUseInstructionStandardMetrics = instructionStandardFont != nil
        && standardIndices.map { indices.allSatisfy($0.contains) } == true
        && instructionFont.simple?.differences.isEmpty == true
        && instructionFont.simple?.toUnicode == nil
      var glyphCodes: [[UInt8]] = []
      for glyph in instructionGlyphs {
        guard glyph.text.unicodeScalars.count == 1,
          let codes = instructionFont.encode(glyph.text),
          let decoded = instructionFont.glyphs(codes), decoded.count == 1,
          decoded[0].text == glyph.text
        else { return nil }
        glyphCodes.append(codes)
      }
      var output = Array("[".utf8)
      var pagePen = transform[4]
      for (glyphIndex, glyph) in instructionGlyphs.enumerated() {
        let adjustment = (pagePen - glyph.x) * 1_000 / denominator
        guard adjustment.isFinite, abs(adjustment) <= 1_000_000 else { return nil }
        if abs(adjustment) > 1e-9 {
          output += Array("\(AnnotationSupport.number(adjustment)) ".utf8)
        }
        let codes = glyphCodes[glyphIndex]
        output += ReplaceTextCommand.literalStringBytes(codes)

        let sourceTextAdvance: Double
        if let measured = instructionFont.advance(
            of: codes, fontSize: instructionRun.fontSize,
            charSpacing: instructionRun.charSpacing, wordSpacing: instructionRun.wordSpacing,
            horizontalScale: instructionRun.horizontalScale), measured.isFinite {
          sourceTextAdvance = measured
        } else {
          guard glyph.text.unicodeScalars.count == 1,
            mayUseInstructionStandardMetrics, let instructionStandardFont,
            let measured = Self.standardAdvance(
              glyph.text, font: instructionStandardFont, size: instructionRun.fontSize,
              charSpacing: instructionRun.charSpacing, wordSpacing: instructionRun.wordSpacing,
              horizontalScale: instructionRun.horizontalScale), measured.isFinite
          else { return nil }
          sourceTextAdvance = measured
        }
        pagePen = glyph.x + sourceTextAdvance * transform[0]
      }
      let oldEndX = transform[4] + oldAdvance * transform[0]
      let trailingAdjustment = (pagePen - oldEndX) * 1_000 / denominator
      guard trailingAdjustment.isFinite, abs(trailingAdjustment) <= 1_000_000 else {
        return nil
      }
      if abs(trailingAdjustment) > 1e-9 {
        output += Array(" \(AnnotationSupport.number(trailingAdjustment))".utf8)
      }
      output += Array("] TJ".utf8)
      replacements.append((TextStyleSupport.fullSpan(of: instruction), output))
    }
    return replacements
  }

  private func instructionScopeIsConsistent(
    _ instructionIndices: Set<Int>, scopes: [Int: [Int]]
  ) -> Bool {
    guard let firstIndex = instructionIndices.min(), let expected = scopes[firstIndex] else {
      return false
    }
    return instructionIndices.allSatisfy { scopes[$0] == expected }
  }

  private static func coversWholeTextInstructions(
    _ selectedIndices: [Int], in allRuns: [TextRun]
  ) -> Bool {
    let selected = Set(selectedIndices)
    guard !selected.isEmpty, selected.count == selectedIndices.count,
      selected.allSatisfy(allRuns.indices.contains)
    else { return false }
    let selectedInstructions = Set(selected.map { allRuns[$0].instructionIndex })
    return allRuns.indices.allSatisfy { index in
      !selectedInstructions.contains(allRuns[index].instructionIndex) || selected.contains(index)
    }
  }

  private static func standardAdvance(
    _ text: String, font: StandardTextFont, size: Double, charSpacing: Double,
    wordSpacing: Double, horizontalScale: Double
  ) -> Double? {
    guard StandardTextFont.canEncode(text), size.isFinite, size > 0,
      charSpacing.isFinite, wordSpacing.isFinite, horizontalScale.isFinite else { return nil }
    let scalars = Array(text.unicodeScalars)
    let characters = Array(text.utf16)
    guard scalars.count == characters.count else { return nil }
    let coreTextFont = CTFontCreateWithName(font.rawValue as CFString, 1_000, nil)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(coreTextFont, characters, &glyphs, glyphs.count),
      glyphs.allSatisfy({ $0 != 0 }) else { return nil }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    _ = CTFontGetAdvancesForGlyphs(coreTextFont, .horizontal, glyphs, &advances, glyphs.count)
    guard advances.allSatisfy({ $0.width.isFinite && $0.width >= 0 }) else { return nil }
    let total = zip(scalars, advances).reduce(0.0) { result, pair in
      let (scalar, advance) = pair
      return result + advance.width.rounded() * size / 1_000 + charSpacing
        + (scalar.value == 32 ? wordSpacing : 0)
    }
    let scaled = total * horizontalScale / 100
    return scaled.isFinite ? scaled : nil
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph)
    let context = try resolved(in: graph)
    if let replacements = try inPlaceRewriteRanges(
      content: context.content, runs: context.runs, advances: context.advances,
      font: context.font, graph: graph)
    {
      return try context.content.replacing(ranges: replacements, in: graph)
    }
    if Self.hasTaggedReadingOrder(pageID: pageID, in: graph) {
      throw PDFError(.unsupported, Self.taggedRewriteRefusal)
    }
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
      defaultSize: fontSize, defaultColor: color,
      defaultOpacity: context.runs.first?.fillAlpha ?? 1,
      clippingRect: context.clip, in: &result)
    return result
  }

  public static let standardFonts: Set<String> = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
  ]
}
