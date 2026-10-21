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
        transform[0] > 0, abs(transform[0] - transform[3]) < 1e-6,
        abs(transform[1]) < 1e-6, abs(transform[2]) < 1e-6,
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
      x: Double, baseline: Double) -> [[Double]]?
    {
      guard size.isFinite, size > 0, spacing.isFinite,
        x.isFinite, baseline.isFinite else { return nil }
      if text.isEmpty { return [] }

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
            let bounds = [
              x + pen + Double(box[0]) * unitScale,
              baseline + Double(box[1]) * unitScale,
              x + pen + Double(box[2]) * unitScale,
              baseline + Double(box[3]) * unitScale,
            ]
            guard bounds.allSatisfy(\.isFinite) else { return nil }
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
            let bounds = [
              x + pen + Double(box[0]) * unitScale,
              baseline + Double(box[1]) * unitScale,
              x + pen + Double(box[2]) * unitScale,
              baseline + Double(box[3]) * unitScale,
            ]
            guard bounds.allSatisfy(\.isFinite) else { return nil }
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
          let bounds = [
            x + pen + Double(rect.minX) * scale,
            baseline + Double(rect.minY) * scale,
            x + pen + Double(rect.maxX) * scale,
            baseline + Double(rect.maxY) * scale,
          ]
          guard bounds.allSatisfy(\.isFinite) else { return nil }
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
            x: segment.x, baseline: line.baseline) {
            let expansion = segment.format.syntheticBoldStrokeWidth / 2
            editedGlyphBounds += ink.map { bounds in
              [bounds[0] - expansion, bounds[1] - expansion,
                bounds[2] + expansion, bounds[3] + expansion]
            }
          } else {
            let expansion = segment.format.syntheticBoldStrokeWidth / 2
            editedGlyphBounds.append([
              segment.x + measured.min - expansion,
              line.baseline - segment.format.size * 0.2 - expansion,
              segment.x + measured.max + expansion,
              line.baseline + segment.format.size * 0.85 + expansion,
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
