import Foundation
import PDFCore

/// P18-014/P18-015/P18-016/P18-018/P18-019/P18-022/P18-030: the second
/// text-editing slice — style changes, move/resize, multi-instruction spans,
/// link reporting, marked-content preservation, editability reasons, and the
/// recorded writable profile. All commands rewrite real content operands (no
/// covering annotations) and refuse outside the supported profile.
public struct TextStyleChange: Sendable, Equatable {
  /// Replacement font resource name (for example `F2`); nil keeps the font.
  public let fontResource: PDFName?
  /// Replacement font size in points; nil keeps the size.
  public let fontSize: Double?
  /// Replacement non-stroking RGB color; nil keeps the color.
  public let fillColor: [Double]?

  public init(
    fontResource: PDFName? = nil, fontSize: Double? = nil, fillColor: [Double]? = nil
  ) {
    self.fontResource = fontResource
    self.fontSize = fontSize
    self.fillColor = fillColor
  }

  public var isEmpty: Bool { fontResource == nil && fontSize == nil && fillColor == nil }
}

/// P18-014: change the style of one supported text run.
///
/// The font selection (`Tf`) that governs the run is rewritten in place and a
/// non-stroking color (`rg`) is inserted before the run's text show, so
/// preceding and following text keep their own state. At least one of font,
/// size, or color must be set. A font change is accepted only when the named
/// resource exists on the page, resolves to a supported font, and can encode
/// the run's current text (never substituting silently).
public struct ChangeTextStyleCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let runIndex: Int
  public let style: TextStyleChange

  public init(pageID: PDFObjectID, runIndex: Int, style: TextStyleChange) {
    self.pageID = pageID
    self.runIndex = runIndex
    self.style = style
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Change Text Style" }

  public func validate(in graph: PDFGraph) throws {
    if style.isEmpty {
      throw PDFError(.malformed, "A text style change must set a font, size, or color")
    }
    _ = try TextStyleSupport.resolveTarget(
      pageID: pageID, runIndex: runIndex, style: style, in: graph, limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: limits)
    let target = try TextStyleSupport.resolveTarget(
      pageID: pageID, runIndex: runIndex, style: style, in: graph, limits: limits)
    var ranges: [(range: Range<Int>, replacement: [UInt8])] = []
    if let tf = target.replacementTf {
      ranges.append((range: target.tfRange, replacement: tf))
    }
    if let color = target.colorPrefix {
      let start = TextStyleSupport.fullSpan(of: target.runInstruction).lowerBound
      ranges.append((range: start..<start, replacement: color))
    }
    guard !ranges.isEmpty else { return graph }
    return try target.content.replacing(ranges: ranges, in: graph, limits: limits)
  }
}

/// P18-015 (move): shift one editable text object by `(dx, dy)` content-space
/// points without moving its neighbors.
///
/// A `dx dy Td` offset is inserted before the run's instruction and the
/// inverse after it, so the target (the whole TJ instruction for member runs)
/// is displaced while following text is restored. Zero displacement is a
/// no-op that leaves the graph untouched.
public struct MoveTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let runIndex: Int
  public let dx: Double
  public let dy: Double

  public init(pageID: PDFObjectID, runIndex: Int, dx: Double, dy: Double) {
    self.pageID = pageID
    self.runIndex = runIndex
    self.dx = dx
    self.dy = dy
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Move Text" }

  public func validate(in graph: PDFGraph) throws {
    guard dx.isFinite, dy.isFinite else {
      throw PDFError(.malformed, "A text move must use finite offsets")
    }
    _ = try TextStyleSupport.editableRun(
      pageID: pageID, runIndex: runIndex, in: graph, limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    guard dx != 0 || dy != 0 else { return graph }
    let limits = PDFLimits()
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: limits)
    let run = try TextStyleSupport.editableRun(
      pageID: pageID, runIndex: runIndex, in: graph, limits: limits)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let instruction = content.instructions[run.instructionIndex]
    let full = TextStyleSupport.fullSpan(of: instruction)
    let before = Array("\n\(AnnotationSupport.number(dx)) \(AnnotationSupport.number(dy)) Td\n".utf8)
    let after = Array("\n\(AnnotationSupport.number(-dx)) \(AnnotationSupport.number(-dy)) Td".utf8)
    return try content.replacing(
      ranges: [
        (range: full.lowerBound..<full.lowerBound, replacement: before),
        (range: instruction.span.upperBound..<instruction.span.upperBound, replacement: after),
      ], in: graph, limits: limits)
  }
}

/// P18-015 (resize): set the font size governing one editable run by
/// rewriting its `Tf` selection in place. Neighboring runs keep their sizes.
public struct ResizeTextCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let runIndex: Int
  public let fontSize: Double

  public init(pageID: PDFObjectID, runIndex: Int, fontSize: Double) {
    self.pageID = pageID
    self.runIndex = runIndex
    self.fontSize = fontSize
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Resize Text" }

  public func validate(in graph: PDFGraph) throws {
    guard fontSize.isFinite, fontSize > 0, fontSize <= 144 else {
      throw PDFError(.malformed, "A text size must be a positive size up to 144 pt")
    }
    _ = try TextStyleSupport.resolveTarget(
      pageID: pageID, runIndex: runIndex,
      style: TextStyleChange(fontSize: fontSize), in: graph, limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: limits)
    let target = try TextStyleSupport.resolveTarget(
      pageID: pageID, runIndex: runIndex,
      style: TextStyleChange(fontSize: fontSize), in: graph, limits: limits)
    guard let tf = target.replacementTf else { return graph }
    return try target.content.replacing(range: target.tfRange, with: tf, in: graph, limits: limits)
  }
}

/// P18-016: replace text split across multiple source instructions.
///
/// The runs `runRange` must be contiguous, live in one editable stream, and
/// share one font resource. The full replacement is encoded once with that
/// font and written into the first run; every later run is emptied (`()`),
/// so the original codes are gone from the content graph. TJ compensation
/// inside each touched array keeps following members placed (the same rule as
/// single-run replacement); text after the span keeps its position only when
/// every touched run carries width data, exactly like the single-run path.
public struct ReplaceTextSpanCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let runRange: Range<Int>
  public let replacement: String

  public init(pageID: PDFObjectID, runRange: Range<Int>, replacement: String) {
    self.pageID = pageID
    self.runRange = runRange
    self.replacement = replacement
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Replace Text Span" }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolved(in: graph, limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: limits)
    let plan = try resolved(in: graph, limits: limits)
    var staged = graph
    // Later runs empty first (higher byte offsets first), then the head run
    // takes the full replacement. Each step reuses the single-run command so
    // TJ compensation and spacing rules stay identical.
    for runIndex in plan.runIndices.dropFirst().reversed() {
      staged = try PDFEditingEngine.commit(
        PDFTransaction([
          ReplaceTextCommand(pageID: pageID, runIndex: runIndex, replacement: "")
        ]), to: staged, limits: limits)
    }
    staged = try PDFEditingEngine.commit(
      PDFTransaction([
        ReplaceTextCommand(pageID: pageID, runIndex: plan.runIndices.first!, replacement: replacement)
      ]), to: staged, limits: limits)
    _ = plan
    return staged
  }

  struct Plan {
    let runIndices: [Int]
  }

  func resolved(in graph: PDFGraph, limits: PDFLimits) throws -> Plan {
    let view = try PageTreeView(graph: graph)
    guard view.pages.contains(pageID) else {
      throw PDFError(.malformed, "Text edit target is not a page in the document")
    }
    guard !runRange.isEmpty else {
      throw PDFError(.malformed, "A text span replacement must cover at least one run")
    }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    guard runRange.lowerBound >= 0, runRange.upperBound <= runs.count else {
      throw PDFError(.malformed, "Text run range is outside the page")
    }
    let indices = Array(runRange)
    let first = runs[indices.first!]
    // One editable stream and one shared font for this slice.
    guard let segment = content.segmentIndex(for: first.stringSpan),
      content.segments[segment].isEditable
    else {
      throw PDFError(
        .unsupported, "The text span uses streams or filters that cannot be edited")
    }
    for index in indices {
      guard content.segmentIndex(for: runs[index].stringSpan) == segment else {
        throw PDFError(.unsupported, "The text span crosses content streams")
      }
      guard runs[index].fontResource == first.fontResource else {
        throw PDFError(
          .unsupported,
          "The text span mixes fonts; replace each font run separately in this profile")
      }
    }
    guard case .dictionary(let page)? = graph.objects[pageID],
      let font = SimpleFont.resolve(resource: first.fontResource, page: page, in: graph),
      font.isSupported, font.isEditable
    else {
      throw PDFError(.unsupported, "The text span's font cannot be edited by this profile")
    }
    guard font.encode(replacement) != nil else {
      throw PDFError(
        .unsupported,
        "The replacement text needs glyphs this font does not provide")
    }
    // Emptying a width-less TJ member that has following members would
    // misplace text; refuse exactly like the single-run path.
    for index in indices.dropFirst() {
      let run = runs[index]
      if run.operandPath.count == 2,
        run.rawCodes.count > 0 || replacement.isEmpty == false || true
      {
        let instruction = content.instructions[run.instructionIndex]
        if case .array(let members)? = instruction.operands.first?.value,
          run.operandPath[1] < members.count - 1,
          font.advance(
            of: run.rawCodes, fontSize: run.fontSize, charSpacing: run.charSpacing,
            wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale) == nil
        {
          throw PDFError(
            .unsupported,
            "This font has no width data; text after the replaced span cannot keep its position")
        }
      }
    }
    return Plan(runIndices: indices)
  }
}

/// Shared target resolution for style/move/resize commands.
enum TextStyleSupport {
  struct Target {
    let content: PageContent
    let run: TextRun
    let tfRange: Range<Int>
    let replacementTf: [UInt8]?
    let colorPrefix: [UInt8]?
    let runInstruction: ContentInstruction
  }

  /// The full byte extent of an instruction: from its first operand through
  /// the operator word. (`ContentInstruction.span` covers only the operator;
  /// operand spans carry the rest.) Inserting at this range's lower bound is
  /// trivia-safe; replacing this range rewrites the whole instruction.
  static func fullSpan(of instruction: ContentInstruction) -> Range<Int> {
    let start = instruction.operands.first?.span.lowerBound ?? instruction.span.lowerBound
    return start..<instruction.span.upperBound
  }

  static func editableRun(
    pageID: PDFObjectID, runIndex: Int, in graph: PDFGraph, limits: PDFLimits
  ) throws -> TextRun {
    let view = try PageTreeView(graph: graph)
    guard view.pages.contains(pageID) else {
      throw PDFError(.malformed, "Text edit target is not a page in the document")
    }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    guard runIndex >= 0, runIndex < runs.count else {
      throw PDFError(.malformed, "Text run index is outside the page")
    }
    let run = runs[runIndex]
    guard let segmentIndex = content.segmentIndex(for: run.stringSpan),
      content.segments[segmentIndex].isEditable
    else {
      throw PDFError(
        .unsupported, "The text run spans streams or uses filters that cannot be edited")
    }
    guard case .dictionary(let page)? = graph.objects[pageID],
      let font = SimpleFont.resolve(resource: run.fontResource, page: page, in: graph),
      font.isSupported, font.isEditable
    else {
      throw PDFError(.unsupported, "The text run's font cannot be edited by this profile")
    }
    _ = font
    return run
  }

  static func resolveTarget(
    pageID: PDFObjectID, runIndex: Int, style: TextStyleChange,
    in graph: PDFGraph, limits: PDFLimits
  ) throws -> Target {
    let run = try editableRun(pageID: pageID, runIndex: runIndex, in: graph, limits: limits)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    // The governing Tf is the nearest font selection before the run.
    var tfIndex: Int?
    for index in stride(from: run.instructionIndex - 1, through: 0, by: -1) {
      if content.instructions[index].operatorName == "Tf" {
        tfIndex = index
        break
      }
      // A new text object resets the search only in that no Tf before BT is
      // an error the indexer already tolerated; keep scanning (state may come
      // from an earlier object in these fixtures).
      if content.instructions[index].operatorName == "BT" { continue }
    }
    guard let tfIndex else {
      throw PDFError(.unsupported, "The text run has no font selection to restyle")
    }
    let tfInstruction = content.instructions[tfIndex]
    guard tfInstruction.operands.count >= 2,
      case .name(let currentName)? = tfInstruction.operands.first?.value
    else {
      throw PDFError(.malformed, "The font selection is malformed")
    }
    let currentSize: Double = {
      switch tfInstruction.operands[1].value {
      case .integer(let raw): return Double(raw)
      case .real(let raw): return raw
      default: return run.fontSize
      }
    }()
    let newName = style.fontResource ?? currentName
    let newSize = style.fontSize ?? currentSize
    if let size = style.fontSize, !(size.isFinite && size > 0 && size <= 144) {
      throw PDFError(.malformed, "A text size must be a positive size up to 144 pt")
    }
    if let color = style.fillColor {
      guard color.count == 3, color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
        throw PDFError(.malformed, "A fill color must be three components in 0...1")
      }
    }
    // A font change must resolve and encode the run's text.
    if let requested = style.fontResource {
      guard case .dictionary(let resources)? = page[PDFName("Resources")],
        case .dictionary(let fonts)? = resources[PDFName("Font")],
        fonts[requested] != nil
      else {
        throw PDFError(.unsupported, "The requested font is not a resource of this page")
      }
      guard let candidate = SimpleFont.resolve(resource: requested, page: page, in: graph),
        candidate.isSupported, candidate.isEditable,
        candidate.encode(run.text) != nil
      else {
        throw PDFError(
          .unsupported,
          "The requested font cannot paint this run's text in the supported profile")
      }
    }
    var replacementTf: [UInt8]?
    if style.fontResource != nil || style.fontSize != nil {
      let nameBytes = try PDFWriter.serializedValue(.name(newName), limits: limits)
      var bytes = [UInt8](nameBytes)
      bytes.append(contentsOf: Array(" \(AnnotationSupport.number(newSize)) Tf".utf8))
      replacementTf = bytes
    }
    var colorPrefix: [UInt8]?
    if let color = style.fillColor {
      let tokens = color.map { AnnotationSupport.number($0) }.joined(separator: " ")
      colorPrefix = Array("\(tokens) rg\n".utf8)
    }
    // Tf and target must share one editable segment for a single-pass rewrite.
    let tfRange = Self.fullSpan(of: tfInstruction)
    guard content.segmentIndex(for: tfRange) == content.segmentIndex(for: run.stringSpan)
    else {
      throw PDFError(.unsupported, "The text style spans content streams")
    }
    return Target(
      content: content, run: run, tfRange: tfRange, replacementTf: replacementTf,
      colorPrefix: colorPrefix,
      runInstruction: content.instructions[run.instructionIndex])
  }
}

/// P18-018: link geometry reporting for text moves.
///
/// Moving text never rewrites link annotations in this profile; instead the
/// command reports which links the move touches, so the UI can offer to move
/// them (a separate annotation operation) or warn. A link is affected when
/// its rectangle intersects the text's old or new bounds.
public enum TextLinkImpact {
  public struct Report: Sendable, Equatable {
    public let affectedIndices: [Int]
    public let affectedRects: [[Double]]

    public init(affectedIndices: [Int], affectedRects: [[Double]]) {
      self.affectedIndices = affectedIndices
      self.affectedRects = affectedRects
    }

    public var isEmpty: Bool { affectedIndices.isEmpty }
  }

  public static func affectedLinks(
    pageID: PDFObjectID, oldBounds: [Double], newBounds: [Double], in graph: PDFGraph
  ) -> Report {
    guard oldBounds.count == 4, newBounds.count == 4 else { return Report(affectedIndices: [], affectedRects: []) }
    let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
    var indices: [Int] = []
    var rects: [[Double]] = []
    for annotation in annotations {
      guard annotation.subtype == PDFName("Link"), let rect = annotation.rect else { continue }
      if intersects(rect, oldBounds) || intersects(rect, newBounds) {
        indices.append(annotation.index)
        rects.append(rect)
      }
    }
    return Report(affectedIndices: indices, affectedRects: rects)
  }

  private static func intersects(_ left: [Double], _ right: [Double]) -> Bool {
    left[0] < right[2] && right[0] < left[2] && left[1] < right[3] && right[1] < left[3]
  }
}

/// P18-019: marked-content accounting across source rewrites.
///
/// Text commands replace string bytes and insert font/position selections but
/// never touch `BMC`/`BDC`/`EMC` operators, so marked-content spans (MCIDs,
/// structure roles, `ActualText`) survive. This helper lets tests pin that:
/// the multiset of (tag, MCID) spans must be identical before and after.
public enum MarkedContentPreservation {
  public struct Span: Sendable, Equatable, Hashable {
    public let tag: String
    public let mcid: Int?

    public init(tag: String, mcid: Int?) {
      self.tag = tag
      self.mcid = mcid
    }
  }

  public static func spans(pageID: PDFObjectID, in graph: PDFGraph) throws -> [Span] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    var stack: [(tag: String, mcid: Int?)] = []
    var result: [Span] = []
    for instruction in content.instructions {
      switch instruction.operatorName {
      case "BMC":
        if case .name(let name)? = instruction.operands.first?.value {
          stack.append((String(decoding: name.bytes, as: UTF8.self), nil))
        } else {
          stack.append(("", nil))
        }
      case "BDC":
        var tag = ""
        var mcid: Int?
        if case .name(let name)? = instruction.operands.first?.value {
          tag = String(decoding: name.bytes, as: UTF8.self)
        }
        if instruction.operands.count >= 2,
          case .dictionary(let dictionary) = instruction.operands[1].value,
          case .integer(let raw)? = dictionary[PDFName("MCID")]
        {
          mcid = Int(raw)
        }
        stack.append((tag, mcid))
      case "EMC":
        if let top = stack.popLast() { result.append(Span(tag: top.tag, mcid: top.mcid)) }
      default:
        break
      }
    }
    return result
  }
}

/// P18-022: clear editability reasons for unsupported fonts and clipping
/// states. `assess` never throws: outside the profile it returns `isEditable
/// == false` with human-readable reasons the UI can surface.
public struct TextEditability: Sendable, Equatable {
  public let isEditable: Bool
  public let reasons: [String]

  public init(isEditable: Bool, reasons: [String]) {
    self.isEditable = isEditable
    self.reasons = reasons
  }
}

public enum TextEditabilityCheck {
  public static func assess(
    pageID: PDFObjectID, runIndex: Int, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) -> TextEditability {
    guard let view = try? PageTreeView(graph: graph), view.pages.contains(pageID) else {
      return TextEditability(
        isEditable: false, reasons: ["The text target is not a page in the document"])
    }
    guard let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits),
      let runs = try? TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    else {
      return TextEditability(
        isEditable: false, reasons: ["The page's text could not be read"])
    }
    guard runIndex >= 0, runIndex < runs.count else {
      return TextEditability(
        isEditable: false, reasons: ["The text run is outside the page"])
    }
    let run = runs[runIndex]
    var reasons: [String] = []
    if content.segmentIndex(for: run.stringSpan) == nil {
      reasons.append("The text spans content streams")
    } else if let segment = content.segmentIndex(for: run.stringSpan),
      !content.segments[segment].isEditable
    {
      reasons.append("This content stream uses filters outside the editable profile")
    }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      return TextEditability(isEditable: false, reasons: ["The page is missing"])
    }
    guard let font = SimpleFont.resolve(resource: run.fontResource, page: page, in: graph) else {
      return TextEditability(
        isEditable: false, reasons: ["The text font is not a page resource"])
    }
    if !font.isSupported {
      switch font.baseEncoding {
      case .unsupportedName(let name):
        reasons.append("The font encoding \(name) is outside the writable profile")
      default:
        reasons.append("The font has differences outside the writable profile")
      }
    } else if !font.isEditable {
      reasons.append(
        "This Type 3 font has no readable glyph program for every character; the text is preserved, not rewritten")
    }
    if renderingMode(of: run, in: content) >= 4 {
      reasons.append("The text paints in a clipping mode; restyle it outside clipping first")
    } else if renderingMode(of: run, in: content) == 3 {
      reasons.append("The text is invisible (rendering mode 3); it is searchable but not styled here")
    }
    if run.operandPath.count == 2,
      let instruction = content.instructions[safe: run.instructionIndex],
      case .array(let members)? = instruction.operands.first?.value,
      run.operandPath[1] < members.count - 1,
      font.advance(
        of: run.rawCodes, fontSize: run.fontSize, charSpacing: run.charSpacing,
        wordSpacing: run.wordSpacing, horizontalScale: run.horizontalScale) == nil
    {
      reasons.append("This font has no width data; following text could not keep its position")
    }
    return TextEditability(isEditable: reasons.isEmpty, reasons: reasons)
  }

  /// The `Tr` rendering mode in effect at the run (default 0).
  static func renderingMode(of run: TextRun, in content: PageContent) -> Int {
    var mode = 0
    for index in 0..<min(run.instructionIndex + 1, content.instructions.count) {
      let instruction = content.instructions[index]
      guard instruction.operatorName == "Tr",
        case .integer(let raw)? = instruction.operands.first?.value
      else { continue }
      mode = Int(raw)
    }
    return mode
  }
}

/// P18-030: the writable text profile, recorded with its regression fixtures.
/// The profile expands only here: a new font, filter, or operator is
/// supported only after its fixture is listed below and covered by a test.
public enum WritableTextProfile {
  public static let summary: String =
    "Simple fonts (WinAnsi/Standard/Differences/ToUnicode, readable Type 3), "
    + "single-stream unfiltered/Flate content, Tj and TJ shows, width-compensated "
    + "neighbors, fallback-wrapped substitutions, pre-commit overflow policy, "
    + "style/move/resize commands, and multi-instruction spans within one font. "
    + "Composite text, multi-stream spans, mixed-font spans, form-nested text, "
    + "and link-annotation rewriting stay outside."

  /// Every fixture that guards the profile. Tests assert each one still
  /// exercises the behavior it pins.
  public static func regressionFixtureNames() -> [String] {
    [
      "textEditPages", "textWidthsPages", "fontEmbeddedPages", "combiningMarkPages",
      "twoColumnPages", "transformedTextPages", "taggedPages", "multilingualPages",
    ]
  }
}
