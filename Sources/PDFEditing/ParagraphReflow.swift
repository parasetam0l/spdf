import Foundation
import PDFCore

/// P19-007–P19-015: fixed-box paragraph reflow with style runs. Reflow is
/// planned first (line breaking, alignment, indentation, spacing, overflow
/// choice, collisions, source map) and only then applied as byte edits inside
/// one content stream. Nothing outside the paragraph's own runs is rewritten.
public struct ParagraphSpan: Sendable, Equatable {
  public let text: String
  /// Index into the candidate's `runStyles`.
  public let styleIndex: Int

  public init(text: String, styleIndex: Int) {
    self.text = text
    self.styleIndex = styleIndex
  }
}

public struct ParagraphReflowOptions: Sendable, Equatable {
  public enum Overflow: String, Sendable, Equatable {
    /// Extra lines may extend past the paragraph box (default).
    case allow
    /// Refuse when the plan does not fit the box.
    case clip
    /// Reduce the font size (down to 4 pt) until the plan fits.
    case shrinkToFit
  }

  /// Paragraph layout. Justified nonfinal lines distribute inter-word space to
  /// the box edge; each paragraph's final line keeps its natural spacing.
  public var alignment: TextParagraphCandidate.Alignment?
  /// Positive indents the first line; negative outdents it (hanging indent).
  public var firstLineIndent: Double?
  public var lineSpacing: Double?
  /// Additional space before the paragraph, moving it down the page.
  public var additionalParagraphSpacingBefore: Double?
  /// Additional space after the paragraph, moving following same-column content down.
  public var additionalParagraphSpacingAfter: Double?
  public var overflow: Overflow
  /// When false (default), a plan that collides with other content is refused.
  public var allowCollisions: Bool
  /// P19-010: styled replacement spans. Defaults to one span with style 0.
  public var spans: [ParagraphSpan]?
  /// P19-023: low-confidence paragraphs are refused unless this is set; when
  /// allowed without spans, the original line styles are preserved.
  public var allowLowConfidence: Bool
  /// P19-016: move following text in the same column (and annotations on it)
  /// down by the paragraph's growth.
  public var downstreamShift: Bool
  /// P19-016: the farthest distance below the paragraph that may move.
  public var maxDownstreamShift: Double

  public init(
    alignment: TextParagraphCandidate.Alignment? = nil, firstLineIndent: Double? = nil,
    lineSpacing: Double? = nil, additionalParagraphSpacingBefore: Double? = nil,
    additionalParagraphSpacingAfter: Double? = nil, overflow: Overflow = .allow,
    allowCollisions: Bool = false,
    spans: [ParagraphSpan]? = nil, allowLowConfidence: Bool = false,
    downstreamShift: Bool = false, maxDownstreamShift: Double = 300
  ) {
    self.alignment = alignment
    self.firstLineIndent = firstLineIndent
    self.lineSpacing = lineSpacing
    self.additionalParagraphSpacingBefore = additionalParagraphSpacingBefore
    self.additionalParagraphSpacingAfter = additionalParagraphSpacingAfter
    self.overflow = overflow
    self.allowCollisions = allowCollisions
    self.spans = spans
    self.allowLowConfidence = allowLowConfidence
    self.downstreamShift = downstreamShift
      || (additionalParagraphSpacingBefore ?? 0) > 0
      || (additionalParagraphSpacingAfter ?? 0) > 0
    self.maxDownstreamShift = maxDownstreamShift
  }
}

public struct ReflowSegment: Sendable, Equatable {
  public let text: String
  public let styleIndex: Int
  public let x: Double
  public let width: Double
}

public struct ReflowLine: Sendable, Equatable {
  public let text: String
  public let segments: [ReflowSegment]
  public let x: Double
  public let y: Double
  public let fontSize: Double
}

public struct ReflowSourceEntry: Sendable, Equatable {
  public let lineIndex: Int
  public let segmentIndex: Int
  public let text: String
  public let styleIndex: Int
  public let sourceRunIndices: [Int]
}

public struct ReflowDownstreamTarget: Sendable, Equatable {
  public let runIndex: Int
  public let x: Double
  public let y: Double
}

public struct ReflowAnnotationTarget: Sendable, Equatable {
  public let objectID: PDFObjectID
  public let rect: [Double]
}

public struct ParagraphReflowCollision: Sendable, Equatable {
  public let description: String
  public let bounds: [Double]
}

public struct ParagraphReflowPlan: Sendable, Equatable {
  public let lines: [ReflowLine]
  public let styles: [ParagraphStyle]
  public let sourceMap: [ReflowSourceEntry]
  /// P19-016/P19-019: how far following content moves and what moves with it.
  public let downstreamDelta: Double
  public let downstreamText: [ReflowDownstreamTarget]
  public let downstreamAnnotations: [ReflowAnnotationTarget]
  public let fontResource: String
  public let fontSize: Double
  public let box: [Double]
  public let overflowed: Bool
  public let warnings: [String]
}

public enum ParagraphReflow {
  struct Context {
    let content: PageContent
    let runs: [TextRun]
    let styles: [ParagraphStyle]
    let fonts: [IndexedTextFont]
  }

  /// Resolve the paragraph's runs, per-style fonts, and editable segment.
  static func context(
    pageID: PDFObjectID, candidate: TextParagraphCandidate, in graph: PDFGraph
  ) throws -> Context {
    // P17-027: a page retained after a delete is stale for editing.
    let view = try PageTreeView(graph: graph)
    guard view.pages.contains(pageID) else {
      throw PDFError(.malformed, "The paragraph's page is no longer in the document")
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    guard !candidate.runIndices.isEmpty else {
      throw PDFError(.malformed, "The paragraph has no text runs")
    }
    var selected: [TextRun] = []
    for index in candidate.runIndices {
      guard index >= 0, index < runs.count else {
        throw PDFError(.malformed, "The paragraph runs changed; re-analyze the page")
      }
      selected.append(runs[index])
    }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    // TXT-02: reflow can replace a complete TJ array, but not a subset of its
    // string members. Partial selections would leave the unselected text
    // behind and shift it when the array is rewritten.
    for run in selected where run.operandPath.count == 2 {
      guard run.operandPath.first == 0,
        run.instructionIndex >= 0, run.instructionIndex < content.instructions.count,
        content.instructions[run.instructionIndex].operatorName == "TJ",
        let array = content.instructions[run.instructionIndex].operands.first,
        case .array(let members) = array.value
      else {
        throw PDFError(.unsupported, "The paragraph's TJ array is malformed")
      }
      let selectedMembers = Set(
        selected.filter { $0.instructionIndex == run.instructionIndex }
          .map { $0.operandPath[1] })
      let stringMembers = members.indices.filter { index in
        guard case .string(let bytes) = members[index] else { return false }
        // Whitespace-only members carry spacing, not paragraph content; they
        // may be cleared with the array without being in the selection.
        return !String(decoding: bytes, as: UTF8.self).allSatisfy(\.isWhitespace)
      }
      guard Set(stringMembers).isSubset(of: selectedMembers) else {
        throw PDFError(
          .unsupported,
          "Reflow needs the complete TJ array; the selection covers only part of it")
      }
    }
    // TXT-01: reflow emits identity text matrices with an explicit font size.
    // It can only represent an unrotated uniform scale folded into that size;
    // rotated, skewed, nonuniform, or spaced runs must refuse rather than move
    // or distort the text.
    for run in selected {
      // Sub-point tracking from TJ compensation is normalized to zero by the
      // identity-matrix rewrite; larger tracking, horizontal scaling, or a
      // baseline rise would visibly change the text and must refuse.
      guard run.uniformPageSpaceScale != nil,
        abs(run.horizontalScale - 100) < 0.01,
        abs(run.charSpacing) < 0.5,
        abs(run.wordSpacing) < 0.5,
        abs(run.rise) < 0.01
      else {
        throw PDFError(
          .unsupported,
          "The paragraph uses a rotated, skewed, nonuniform, or spaced text transform that reflow cannot preserve exactly")
      }
    }
    // P19-010: one font per style, resolved from the runs themselves.
    var styles = candidate.runStyles
    if styles.isEmpty {
      styles = [
        ParagraphStyle(
          fontResource: String(decoding: selected[0].fontResource.bytes, as: UTF8.self),
          fontSize: selected[0].pageSpaceFontSize, fillColor: selected[0].fillColor)
      ]
    }
    var fonts: [IndexedTextFont] = []
    for style in styles {
      let resource = PDFName(style.fontResource)
      guard let font = IndexedTextFont.resolve(
        resource: resource, page: page, in: graph), font.isSupported
      else {
        throw PDFError(
          .unsupported, "The paragraph font \(style.fontResource) is not supported for reflow")
      }
      // P14-023: reflow reuses existing glyph programs (verified per code in
      // encode); a Type 3 font without readable programs refuses here.
      guard font.isEditableForReflow else {
        throw PDFError(
          .unsupported,
          "The paragraph uses a Type 3 font without readable glyph programs; the text is preserved, not rewritten")
      }
      fonts.append(font)
    }
    // TXT-02: a paragraph may span multiple /Contents streams. Each selected
    // run's stream must be editable; the content writer rewrites every touched
    // segment and refuses ambiguous repeated stream objects.
    for run in selected {
      guard let indices = content.segmentIndices(for: run.stringSpan),
        indices.allSatisfy({ content.segments[$0].isEditable })
      else {
        throw PDFError(
          .unsupported, "This content stream uses unsupported filters for editing")
      }
    }
    return Context(
      content: content, runs: selected, styles: styles, fonts: fonts)
  }

  /// Advance of a string in text space (exact when widths exist, estimated
  /// otherwise).
  static func advance(of text: String, font: IndexedTextFont, size: Double) -> Double {
    guard let codes = font.encode(text) else { return 0 }
    if let measured = font.advance(
      of: codes, fontSize: size, charSpacing: 0, wordSpacing: 0, horizontalScale: 100)
    {
      return measured
    }
    if let measured = font.standard14Advance(
      of: codes, fontSize: size, charSpacing: 0, wordSpacing: 0, horizontalScale: 100)
    {
      return measured
    }
    if let glyphs = font.glyphs(codes) {
      var total = 0.0
      for glyph in glyphs {
        total += (glyph.width ?? 500) / 1000 * size
      }
      return total
    }
    return 0.5 * size * Double(max(codes.count, 1))
  }

  struct Token {
    let text: String
    let styleIndex: Int
    var isParagraphEnd = false
  }

  public static func plan(
    pageID: PDFObjectID, candidate: TextParagraphCandidate, replacement: String,
    in graph: PDFGraph, options: ParagraphReflowOptions = .init()
  ) throws -> (plan: ParagraphReflowPlan, collisions: [ParagraphReflowCollision]) {
    let context = try context(pageID: pageID, candidate: candidate, in: graph)
    // P19-023: low-confidence reconstructions are refused unless confirmed.
    if candidate.confidence < 0.6, !options.allowLowConfidence {
      throw PDFError(
        .unsupported,
        "The paragraph reconstruction confidence is low "
          + "(\(Int((candidate.confidence * 100).rounded()))%); confirm explicitly to reflow it")
    }
    let spans = options.spans
      ?? defaultSpans(
        candidate: candidate, replacement: replacement, context: context,
        preserveLineStyles: candidate.confidence < 0.6)
    for span in spans {
      guard span.styleIndex >= 0, span.styleIndex < context.styles.count else {
        throw PDFError(.malformed, "A replacement span references a missing style")
      }
      for paragraph in span.text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard context.fonts[span.styleIndex].encode(String(paragraph)) != nil else {
          throw PDFError(
            .unsupported, "The replacement contains characters this font cannot encode")
        }
      }
    }
    let box = candidate.bounds
    let boxWidth = max(24, box[2] - box[0])
    let boxHeight = max(candidate.fontSize, box[3] - box[1])
    let alignment = options.alignment ?? candidate.alignment
    let spacingBefore = options.additionalParagraphSpacingBefore ?? 0
    let spacingAfter = options.additionalParagraphSpacingAfter ?? 0
    guard [spacingBefore, spacingAfter].allSatisfy({ $0.isFinite && (0...100).contains($0) })
    else {
      throw PDFError(.malformed, "Additional paragraph spacing must be between 0 and 100 points")
    }
    let shiftsDownstream = options.downstreamShift || spacingBefore > 0 || spacingAfter > 0
    let indent = (alignment == .left || alignment == .justified)
      ? (options.firstLineIndent ?? candidate.firstLineIndent) : 0
    var warnings: [String] = []
    let paragraphs = tokenParagraphs(spans: spans)
    let baseSize = context.styles.map(\.fontSize).max() ?? candidate.fontSize

    let sizes: [Double]
    switch options.overflow {
    case .shrinkToFit: sizes = stride(from: baseSize, through: 4, by: -0.5).map { $0 }
    default: sizes = [baseSize]
    }
    var chosen: (lines: [[Token]], size: Double, overflowed: Bool)?
    for size in sizes {
      let spacing = options.lineSpacing ?? max(candidate.lineSpacing, size * 1.05)
      let capacity = max(
        candidate.lineIndices.count, Int(floor((boxHeight - size * 0.2) / spacing)) + 1)
      let lines = wrap(
        paragraphs, width: boxWidth, firstLineWidth: max(24, boxWidth - indent),
        context: context, scale: size / baseSize)
      let verticalOverflow = !lines.isEmpty
        && box[3] - size * 0.8 - spacingBefore
          - Double(lines.count - 1) * spacing - size * 0.2 < box[1] - 0.5
      let overflowed =
        lines.count > capacity || verticalOverflow
        || lines.enumerated().contains { index, line in
          let width = lineWidth(line, context: context, scale: size / baseSize)
          return width + (index == 0 ? indent : 0) > boxWidth + 0.5
        }
      switch options.overflow {
      case .shrinkToFit:
        chosen = (lines, size, overflowed)
        if !overflowed { break }
      case .clip:
        if overflowed {
          throw PDFError(
            .unsupported, "The reflowed text does not fit the paragraph box (clip)")
        }
        chosen = (lines, size, false)
        break
      case .allow:
        if overflowed { warnings.append("The reflowed text extends past the paragraph box.") }
        chosen = (lines, size, overflowed)
        break
      }
      if chosen != nil, options.overflow != .shrinkToFit { break }
    }
    guard let chosen else {
      throw PDFError(.unsupported, "The reflowed text does not fit the paragraph box")
    }
    if options.overflow == .shrinkToFit, chosen.overflowed {
      throw PDFError(
        .unsupported, "The reflowed text does not fit the paragraph box even at the minimum size")
    }

    let size = chosen.size
    let scale = size / baseSize
    let spacing = options.lineSpacing ?? max(candidate.lineSpacing, size * 1.05)
    let ascent = size * 0.8
    var lines: [ReflowLine] = []
    for (index, tokens) in chosen.lines.enumerated() {
      let segments = groupedSegments(tokens, context: context, scale: scale)
      let width = segments.reduce(0.0) { partial, segment in
        partial + segment.width
      } + segments.dropFirst().reduce(0.0) { partial, segment in
        partial + spaceWidth(of: segment.styleIndex, context: context, scale: scale)
      }
      let x: Double
      switch alignment {
      case .center: x = box[0] + (boxWidth - width) / 2
      case .right: x = box[2] - width
      default: x = box[0] + (index == 0 ? indent : 0)
      }
      var cursor = x
      var placed: [ReflowSegment] = []
      let availableWidth = max(0, box[2] - x)
      let naturalWidth = lineWidth(tokens, context: context, scale: scale)
      let shouldJustify = alignment == .justified && tokens.count > 1
        && !(tokens.last?.isParagraphEnd ?? true)
        && naturalWidth < availableWidth - 0.01
      if shouldJustify {
        let addedSpace = (availableWidth - naturalWidth) / Double(tokens.count - 1)
        for (tokenIndex, token) in tokens.enumerated() {
          let tokenWidth = tokenWidth(token, context: context, scale: scale)
          placed.append(
            ReflowSegment(
              text: token.text, styleIndex: token.styleIndex, x: cursor,
              width: tokenWidth))
          cursor += tokenWidth
          if tokenIndex + 1 < tokens.count {
            let nextStyle = tokens[tokenIndex + 1].styleIndex
            let wordSpace = spaceWidth(of: nextStyle, context: context, scale: scale)
            placed.append(
              ReflowSegment(
                text: " ", styleIndex: nextStyle, x: cursor, width: wordSpace))
            cursor += wordSpace + addedSpace
          }
        }
      } else {
        for (segmentIndex, segment) in segments.enumerated() {
          placed.append(
            ReflowSegment(
              text: segment.text, styleIndex: segment.styleIndex, x: cursor,
              width: segment.width))
          cursor += segment.width
          if segmentIndex + 1 < segments.count {
            cursor += spaceWidth(
              of: segments[segmentIndex + 1].styleIndex, context: context, scale: scale)
          }
        }
      }
      lines.append(
        ReflowLine(
          text: tokens.map(\.text).joined(separator: " "), segments: placed, x: x,
          y: box[3] - ascent - spacingBefore - Double(index) * spacing, fontSize: size))
    }

    // P19-024: a source map from new lines/segments back to the original runs.
    var sourceMap: [ReflowSourceEntry] = []
    for (lineIndex, line) in lines.enumerated() {
      for (segmentIndex, segment) in line.segments.enumerated() {
        let source: [Int]
        if lineIndex < candidate.lineRunIndices.count,
          !candidate.lineRunIndices[lineIndex].isEmpty
        {
          source = candidate.lineRunIndices[lineIndex]
        } else {
          let style = context.styles[segment.styleIndex]
          let matched = candidate.runIndices.enumerated().filter { entry in
            guard entry.offset < candidate.runStyles.count else { return false }
            let runStyle = candidate.runStyles[entry.offset]
            return runStyle.fontResource == style.fontResource
              && abs(runStyle.fontSize - style.fontSize) < 0.1
          }.map(\.element)
          source = matched.isEmpty ? candidate.runIndices : matched
        }
        sourceMap.append(
          ReflowSourceEntry(
            lineIndex: lineIndex, segmentIndex: segmentIndex, text: segment.text,
            styleIndex: segment.styleIndex, sourceRunIndices: source))
      }
    }

    // P19-016/P19-019: optional downstream repositioning of following text in
    // the same column plus annotations sitting on it.
    var downstreamDelta = 0.0
    var downstreamText: [ReflowDownstreamTarget] = []
    var downstreamAnnotations: [ReflowAnnotationTarget] = []
    if shiftsDownstream, let lastLine = lines.last {
      let newBottom = lastLine.y - size * 0.2
      // bounds are [x0, y0, x1, y1]: the paragraph's bottom is box[1].
      downstreamDelta = max(0, box[1] - newBottom) + spacingAfter
      if downstreamDelta > 0.01 {
        let allRuns = try TextRunIndexer.runs(in: context.content, graph: graph)
        let paragraphRuns = Set(candidate.runIndices)
        for (index, run) in allRuns.enumerated()
        where !paragraphRuns.contains(index) && run.operandPath.count != 2 {
          guard run.baselineY < box[1],
            run.baselineY >= box[1] - options.maxDownstreamShift
          else { continue }
          let estimatedWidth = 0.5 * run.fontSize * Double(max(run.rawCodes.count, 1))
          let overlap = min(run.baselineX + estimatedWidth, box[2])
            - max(run.baselineX, box[0])
          guard overlap > 0 else { continue }
          downstreamText.append(
            ReflowDownstreamTarget(
              runIndex: index, x: run.baselineX, y: run.baselineY - downstreamDelta))
        }
        if case .dictionary(let page)? = graph.objects[pageID],
          case .array(let annotations)? = page[PDFName("Annots")]
        {
          for value in annotations {
            guard case .reference(let id) = value,
              case .dictionary(let annotation)? = graph.objects[id],
              let rect = Annotation.numbers(annotation[PDFName("Rect")], count: 4)
            else { continue }
            guard rect[3] <= box[1] + 1, rect[3] >= box[1] - options.maxDownstreamShift
            else { continue }
            let overlap = min(rect[2], box[2]) - max(rect[0], box[0])
            guard overlap > 0 else { continue }
            downstreamAnnotations.append(
              ReflowAnnotationTarget(
                objectID: id,
                rect: [rect[0], rect[1] - downstreamDelta, rect[2], rect[3] - downstreamDelta]))
          }
        }
      }
    }
    // P19-015: collisions with other text blocks and annotations.
    var collisions: [ParagraphReflowCollision] = []
    let others = (try? ParagraphReconstruction.candidatesForEditing(pageID: pageID, in: graph)) ?? []
    // Blocks and annotations that the downstream shift moves are not counted
    // as collisions: they travel with the reflowed paragraph (P19-016).
    let movedRuns = Set(downstreamText.map(\.runIndex))
    let movedAnnotations = Set(downstreamAnnotations.map(\.objectID))
    for line in lines {
      let width = line.segments.reduce(0.0) { $0 + $1.width }
        + Double(max(0, line.segments.count - 1)) * 0.5 * line.fontSize
      let rect = [line.x, line.y - line.fontSize * 0.2, line.x + width, line.y + line.fontSize * 0.85]
      for other in others where other.runIndices != candidate.runIndices {
        // Blocks that share runs with this paragraph (manual merges, split
        // parts) are never collisions.
        if !Set(other.runIndices).isDisjoint(with: candidate.runIndices) { continue }
        if shiftsDownstream, !movedRuns.isEmpty,
          other.runIndices.allSatisfy({ movedRuns.contains($0) })
        {
          continue
        }
        if intersects(rect, other.bounds) {
          collisions.append(
            ParagraphReflowCollision(
              description: "text block “\(other.text.prefix(24))”", bounds: other.bounds))
        }
      }
      if case .dictionary(let page)? = graph.objects[pageID],
        case .array(let annotations)? = page[PDFName("Annots")]
      {
        for value in annotations {
          guard case .reference(let id) = value,
            case .dictionary(let annotation)? = graph.objects[id],
            let numbers = Annotation.numbers(annotation[PDFName("Rect")], count: 4)
          else { continue }
          if movedAnnotations.contains(id) { continue }
          if intersects(rect, numbers) {
            collisions.append(
              ParagraphReflowCollision(description: "annotation", bounds: numbers))
          }
        }
      }
    }

    let plan = ParagraphReflowPlan(
      lines: lines, styles: context.styles, sourceMap: sourceMap,
      downstreamDelta: downstreamDelta, downstreamText: downstreamText,
      downstreamAnnotations: downstreamAnnotations,
      fontResource: context.styles[0].fontResource, fontSize: size, box: box,
      overflowed: chosen.overflowed, warnings: warnings)
    return (plan, collisions)
  }

  /// P19-023: default replacement spans. High-confidence paragraphs use one
  /// span with the dominant style; low-confidence paragraphs keep each
  /// original line's style by distributing the replacement proportionally.
  static func defaultSpans(
    candidate: TextParagraphCandidate, replacement: String, context: Context,
    preserveLineStyles: Bool
  ) -> [ParagraphSpan] {
    guard preserveLineStyles, candidate.lineRunIndices.count > 1,
      !candidate.runStyles.isEmpty
    else {
      return [ParagraphSpan(text: replacement, styleIndex: 0)]
    }
    let words = replacement.split(separator: " ").map(String.init)
    var spans: [ParagraphSpan] = []
    for (lineIndex, runs) in candidate.lineRunIndices.enumerated() {
      let start = words.count * lineIndex / candidate.lineRunIndices.count
      let end = words.count * (lineIndex + 1) / candidate.lineRunIndices.count
      guard start < end, let firstRun = runs.first else { continue }
      let styleIndex = context.styles.firstIndex { style in
        style.fontResource == candidate.runStyles[min(firstRun, candidate.runStyles.count - 1)]
          .fontResource
          && abs(
            style.fontSize
              - candidate.runStyles[min(firstRun, candidate.runStyles.count - 1)].fontSize)
            < 0.1
      } ?? 0
      spans.append(ParagraphSpan(text: words[start..<end].joined(separator: " "), styleIndex: styleIndex))
    }
    return spans.isEmpty ? [ParagraphSpan(text: replacement, styleIndex: 0)] : spans
  }

  /// Split styled spans into token paragraphs, keeping combining marks with
  /// their base character (P19-011).
  static func tokenParagraphs(spans: [ParagraphSpan]) -> [[Token]] {
    var result: [[Token]] = []
    var current: [Token] = []
    for span in spans {
      let characters = Array(span.text)
      var word = ""
      func flush() {
        guard !word.isEmpty else { return }
        current.append(Token(text: word, styleIndex: span.styleIndex))
        word = ""
      }
      for character in characters {
        if character == "\n" {
          flush()
          if let lastIndex = current.indices.last {
            current[lastIndex].isParagraphEnd = true
          }
          result.append(current)
          current = []
          continue
        }
        if character == " " {
          flush()
          continue
        }
        if word.isEmpty, let scalar = character.unicodeScalars.first,
          CharacterSet.nonBaseCharacters.contains(scalar), let last = current.popLast()
        {
          // A combining mark never starts a word; attach it to the previous.
          word = last.text + String(character)
          continue
        }
        word.append(character)
      }
      flush()
    }
    if let lastIndex = current.indices.last {
      current[lastIndex].isParagraphEnd = true
    }
    result.append(current)
    return result
  }

  /// P19-018: wrap `text` and return at most `capacity` lines plus the words
  /// that did not fit (rejoined in order).
  static func wrapFilling(
    _ text: String, width: Double, context: Context, capacity: Int
  ) -> (lines: [[Token]], leftover: String) {
    let paragraphs = tokenParagraphs(spans: [ParagraphSpan(text: text, styleIndex: 0)])
    let all = wrap(paragraphs, width: width, context: context, scale: 1)
    guard all.count > capacity else { return (all, "") }
    let leftover = all.dropFirst(capacity).flatMap { $0 }.map(\.text)
      .joined(separator: " ")
    return (Array(all.prefix(capacity)), leftover)
  }

  /// Greedy word wrap with punctuation rules; long words are never hyphenated
  /// or split silently.
  static func wrap(
    _ paragraphs: [[Token]], width: Double, firstLineWidth: Double? = nil,
    context: Context, scale: Double
  ) -> [[Token]] {
    var lines: [[Token]] = []
    var isFirstLine = true
    for paragraph in paragraphs {
      var current: [Token] = []
      for token in paragraph {
        if current.isEmpty {
          current = [token]
          continue
        }
        let candidate = current + [token]
        let availableWidth = isFirstLine ? (firstLineWidth ?? width) : width
        if lineWidth(candidate, context: context, scale: scale) <= availableWidth {
          current = candidate
          continue
        }
        if let first = token.text.first, ".,;:!?)]}»…".contains(first) {
          current = candidate
          continue
        }
        if let last = current.last?.text.last, "([{«".contains(last) {
          let moved = current.removeLast()
          lines.append(current)
          isFirstLine = false
          current = [moved, token]
          continue
        }
        lines.append(current)
        isFirstLine = false
        current = [token]
      }
      lines.append(current)
      isFirstLine = false
    }
    return lines
  }

  static func lineWidth(_ tokens: [Token], context: Context, scale: Double) -> Double {
    tokens.reduce(0.0) { $0 + tokenWidth($1, context: context, scale: scale) }
      + spacesWidth(tokens, context: context, scale: scale)
  }

  static func tokenWidth(_ token: Token, context: Context, scale: Double) -> Double {
    let style = context.styles[token.styleIndex]
    return advance(
      of: token.text, font: context.fonts[token.styleIndex],
      size: style.fontSize * scale)
  }

  static func spaceWidth(of styleIndex: Int, context: Context, scale: Double) -> Double {
    let style = context.styles[styleIndex]
    return advance(
      of: " ", font: context.fonts[styleIndex],
      size: style.fontSize * scale)
  }

  static func spacesWidth(_ tokens: [Token], context: Context, scale: Double) -> Double {
    guard tokens.count > 1 else { return 0 }
    var total = 0.0
    for index in 1..<tokens.count {
      total += spaceWidth(of: tokens[index].styleIndex, context: context, scale: scale)
    }
    return total
  }

  struct UnplacedSegment {
    let text: String
    let styleIndex: Int
    let width: Double
  }

  /// Group consecutive same-style tokens into segments.
  static func groupedSegments(
    _ tokens: [Token], context: Context, scale: Double
  ) -> [UnplacedSegment] {
    var result: [UnplacedSegment] = []
    var currentText = ""
    var currentStyle = -1
    func flush() {
      guard currentStyle >= 0, !currentText.isEmpty else { return }
      result.append(
        UnplacedSegment(
          text: currentText, styleIndex: currentStyle,
          width: advance(
            of: currentText, font: context.fonts[currentStyle],
            size: context.styles[currentStyle].fontSize * scale)))
      currentText = ""
    }
    for token in tokens {
      if token.styleIndex != currentStyle {
        flush()
        currentStyle = token.styleIndex
        currentText = token.text
      } else {
        currentText += " " + token.text
      }
    }
    flush()
    return result
  }

  static func intersects(_ left: [Double], _ right: [Double]) -> Bool {
    let width = min(left[2], right[2]) - max(left[0], right[0])
    let height = min(left[3], right[3]) - max(left[1], right[1])
    return width > 1 && height > 1
  }
}

/// P19-007/P19-010/P19-012–P19-015: apply a planned reflow. The paragraph's
/// own runs are emptied and every line is emitted as a balanced `BT … ET`
/// block with per-segment fonts and colors; other content is untouched.
/// P17-005: copy-on-write for page content streams. A stream shared between
/// pages is copied before an edit so writing one page never changes another;
/// unshared content is returned untouched.
enum PageContentCopy {
  /// Ensure `pageID`'s content stream objects are private to that page.
  /// Each shared stream object is copied to a fresh object and this page's
  /// `/Contents` entries (a single reference or array members) are repointed
  /// at the copy. Multiple references to one object inside the page copy
  /// once. Returns the input graph unchanged when nothing is shared.
  static func makePrivate(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    // This page's content object IDs from its /Contents entry.
    guard case .dictionary(let page)? = graph.objects[pageID] else { return graph }
    var ownedIDs: [PDFObjectID] = []
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      ownedIDs = [id]
    case .array(let members)?:
      ownedIDs = members.compactMap {
        if case .reference(let id) = $0 { return id }
        return nil
      }
    default:
      return graph
    }
    guard !ownedIDs.isEmpty else { return graph }
    // Which of those objects do other pages reference?
    var shared: Set<PDFObjectID> = []
    let pages = try PDFPageTree.pageIDs(in: graph)
    for otherID in pages where otherID != pageID {
      guard case .dictionary(let other)? = graph.objects[otherID] else { continue }
      var otherIDs: [PDFObjectID] = []
      switch other[PDFName("Contents")] {
      case .reference(let id)?:
        otherIDs = [id]
      case .array(let members)?:
        otherIDs = members.compactMap {
          if case .reference(let id) = $0 { return id }
          return nil
        }
      default:
        break
      }
      for id in otherIDs where ownedIDs.contains(id) {
        shared.insert(id)
      }
    }
    guard !shared.isEmpty else { return graph }
    var graph = graph
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    var mapping: [PDFObjectID: PDFObjectID] = [:]
    for id in ownedIDs where shared.contains(id) {
      if let existing = mapping[id] { continue }
      guard case .stream(let stream)? = graph.objects[id] else { continue }
      let copy = PDFObjectID(nextNumber)
      nextNumber += 1
      graph.objects[copy] = .stream(stream)
      mapping[id] = copy
    }
    guard !mapping.isEmpty else { return graph }
    // Repoint this page's /Contents at the copies.
    var updated = page
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      if let copy = mapping[id] {
        updated[PDFName("Contents")] = .reference(copy)
      }
    case .array(let members)?:
      updated[PDFName("Contents")] = .array(
        members.map { member -> PDFValue in
          if case .reference(let id) = member, let copy = mapping[id] {
            return .reference(copy)
          }
          return member
        })
    default:
      break
    }
    graph.objects[pageID] = .dictionary(updated)
    _ = limits
    return graph
  }
}

public struct ReflowParagraphCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let candidate: TextParagraphCandidate
  public let replacement: String
  public let options: ParagraphReflowOptions

  public init(
    pageID: PDFObjectID, candidate: TextParagraphCandidate, replacement: String,
    options: ParagraphReflowOptions = .init()
  ) {
    self.pageID = pageID
    self.candidate = candidate
    self.replacement = replacement
    self.options = options
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Reflow Paragraph" }

  public func validate(in graph: PDFGraph) throws {
    let (_, collisions) = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: graph,
      options: options)
    if !collisions.isEmpty, !options.allowCollisions {
      throw PDFError(
        .unsupported,
        "The reflowed text would collide with \(collisions.count) item(s): "
          + collisions.prefix(3).map(\.description).joined(separator: ", "))
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    // P17-005: copy shared page content before rewriting it.
    let page = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: PDFLimits())
    let (plan, _) = try ParagraphReflow.plan(
      pageID: pageID, candidate: candidate, replacement: replacement, in: page,
      options: options)
    let context = try ParagraphReflow.context(pageID: pageID, candidate: candidate, in: page)
    var ranges: [(range: Range<Int>, replacement: [UInt8])] = []
    var clearedTJInstructions = Set<Int>()
    for run in context.runs {
      if run.operandPath.count == 2 {
        // Clear the complete TJ array once; the coverage check in `context`
        // guarantees every string member belongs to this paragraph.
        guard !clearedTJInstructions.contains(run.instructionIndex),
          run.instructionIndex >= 0,
          run.instructionIndex < context.content.instructions.count,
          let array = context.content.instructions[run.instructionIndex].operands.first
        else { continue }
        clearedTJInstructions.insert(run.instructionIndex)
        ranges.append((array.span, Array("[]".utf8)))
      } else {
        ranges.append((run.stringSpan, ReplaceTextCommand.literalStringBytes([])))
      }
    }
    let lastInstruction = context.runs.map(\.instructionIndex).max()
    guard let lastInstruction, lastInstruction < context.content.instructions.count else {
      throw PDFError(.malformed, "The paragraph instructions are missing")
    }
    // Append after the enclosing ET so the new text objects stay balanced.
    var insertAt = context.content.instructions[lastInstruction].span.upperBound
    var cursor = lastInstruction + 1
    while cursor < context.content.instructions.count {
      if context.content.instructions[cursor].operatorName == "ET" {
        insertAt = context.content.instructions[cursor].span.upperBound
        break
      }
      cursor += 1
    }
    var bytes: [UInt8] = []
    for line in plan.lines {
      bytes.append(contentsOf: Array("\nBT\n".utf8))
      for segment in line.segments {
        let style = plan.styles[segment.styleIndex]
        bytes.append(
          contentsOf: Array(
            "/\(style.fontResource) \(AnnotationSupport.number(style.fontSize)) Tf\n".utf8))
        let color = style.fillColor.count == 3 ? style.fillColor : [0, 0, 0]
        let colorLine =
          "\(AnnotationSupport.number(color[0])) \(AnnotationSupport.number(color[1])) "
          + "\(AnnotationSupport.number(color[2])) rg\n"
        bytes.append(contentsOf: Array(colorLine.utf8))
        let matrixLine =
          "1 0 0 1 \(AnnotationSupport.number(segment.x)) "
          + "\(AnnotationSupport.number(line.y)) Tm "
        bytes.append(contentsOf: Array(matrixLine.utf8))
        let font = context.fonts[segment.styleIndex]
        let codes = font.encode(segment.text) ?? []
        bytes.append(contentsOf: ReplaceTextCommand.literalStringBytes(codes))
        bytes.append(contentsOf: Array(" Tj\n".utf8))
      }
      bytes.append(contentsOf: Array("ET".utf8))
    }
    ranges.append((insertAt..<insertAt, bytes))
    // P19-016: reposition following text runs (Tm only; font/size unchanged).
    let allRuns = try TextRunIndexer.runs(in: context.content, graph: page)
    for target in plan.downstreamText {
      guard target.runIndex >= 0, target.runIndex < allRuns.count else { continue }
      let run = allRuns[target.runIndex]
      let prefix =
        "1 0 0 1 \(AnnotationSupport.number(target.x)) "
        + "\(AnnotationSupport.number(target.y)) Tm "
      ranges.append(
        (run.stringSpan.lowerBound..<run.stringSpan.lowerBound, Array(prefix.utf8)))
    }
    var result = try context.content.replacing(ranges: ranges, in: page)
    // P19-019: annotations on the moved text move with it.
    for target in plan.downstreamAnnotations {
      guard case .dictionary(var annotation)? = result.objects[target.objectID] else { continue }
      annotation[PDFName("Rect")] = .array(target.rect.map { PDFValue.real($0) })
      if case .array(let quadPoints)? = annotation[PDFName("QuadPoints")] {
        var shifted: [PDFValue] = []
        for (index, value) in quadPoints.enumerated() {
          if index % 2 == 1, case .real(let y) = value {
            shifted.append(.real(y - plan.downstreamDelta))
          } else if index % 2 == 1, case .integer(let y) = value {
            shifted.append(.real(Double(y) - plan.downstreamDelta))
          } else {
            shifted.append(value)
          }
        }
        annotation[PDFName("QuadPoints")] = .array(shifted)
      }
      result.objects[target.objectID] = .dictionary(annotation)
    }
    return result
  }
}
