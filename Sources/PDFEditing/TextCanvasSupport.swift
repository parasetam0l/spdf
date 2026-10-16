import Foundation
import PDFCore

/// One text-show instruction, including every string in a TJ array. A page
/// editor must not hide or move just one member while leaving its siblings.
public struct PageTextBlock: Sendable, Equatable {
  public let runIndices: [Int]
  public let text: String
  public let rect: [Double]
  public let style: TextInputStyle
  public let fontResource: PDFName
}

public enum PageTextEditing {
  public struct ListMarker: Sendable, Equatable {
    public let runIndex: Int
    public let x: Double
    public let baseline: Double
    public let fontSize: Double
    public let isStandalone: Bool
  }

  /// List markers remain useful boundaries even when their symbol font is
  /// outside the writable profile. Discover them without rewriting the glyph.
  public static func listMarkers(pageID: PDFObjectID, in graph: PDFGraph) throws -> [ListMarker] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    let bulletSymbols = Set(["•", "◦", "▪", "‣", "⁃", "∙", "●", "○", "➢", "➤", "►", "▶"])
    let symbolFamilies = Set(["wingdings", "wingdings2", "wingdings3", "webdings", "zapfdingbats"])
    var names: [PDFName: String] = [:]
    var result: [ListMarker] = []
    for (index, run) in runs.enumerated() {
      let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let token = String(text.prefix { !$0.isWhitespace })
      guard !token.isEmpty else { continue }
      var isMarker = bulletSymbols.contains(token)
      if !isMarker, token.count >= 2, token.count <= 8, let end = token.last,
        end == "." || end == ")" {
        let label = token.dropLast()
        let digits = label.count <= 3 && label.allSatisfy { $0.isASCII && $0.isNumber }
        let letter = label.count == 1 && label.allSatisfy { $0.isASCII && $0.isLetter }
        let roman = String(label).range(of: "^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$",
          options: [.regularExpression, .caseInsensitive]) != nil
        isMarker = digits || letter || roman
      }
      if !isMarker, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
        (0xE000...0xF8FF).contains(scalar.value) {
        if names[run.fontResource] == nil {
          names[run.fontResource] = IndexedTextFont.resolve(resource: run.fontResource, page: page, in: graph)?
            .baseFont.split(separator: "+").last.map { String($0).lowercased() } ?? ""
        }
        isMarker = symbolFamilies.contains(names[run.fontResource] ?? "")
      }
      guard isMarker, run.hasKnownOffset, abs(run.rise) < 1e-6,
        TextCanvasSupport.renderingMode(at: run.instructionIndex, in: content) == 0 else { continue }
      let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      let size = run.fontSize * transform[0]
      let x = transform[4] + run.textSpaceOffset * transform[0]
      guard transform[0] > 0, abs(transform[0] - transform[3]) < 1e-6,
        abs(transform[1]) < 1e-6, abs(transform[2]) < 1e-6,
        [x, transform[5], size].allSatisfy(\.isFinite), (2...144).contains(size) else { continue }
      result.append(.init(runIndex: index, x: x, baseline: transform[5], fontSize: size,
        isStandalone: token == text))
      guard result.count <= 4_096 else { throw PDFError(.limitExceeded, "Too many list markers for paragraph discovery") }
    }
    return result
  }

  /// Painted horizontal rules separate table rows and sections even when the
  /// words on either side happen to round-trip as a wrapped paragraph.
  public static func paragraphSeparators(pageID: PDFObjectID, in graph: PDFGraph) throws -> [[Double]] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    var transform = [1.0, 0, 0, 1, 0, 0]
    var stack: [[Double]] = []
    var current: [Double]?
    var start: [Double]?
    var path: [[Double]] = []
    var result: [[Double]] = []
    func point(_ x: Double, _ y: Double) -> [Double] {
      [transform[0] * x + transform[2] * y + transform[4],
        transform[1] * x + transform[3] * y + transform[5]]
    }
    func line(_ a: [Double], _ b: [Double]) { path.append(a + b) }
    for instruction in content.instructions {
      let numbers = instruction.operands.compactMap { operand -> Double? in
        switch operand.value { case .integer(let n): return Double(n); case .real(let n): return n; default: return nil }
      }
      switch instruction.operatorName {
      case "q": stack.append(transform)
      case "Q": transform = stack.popLast() ?? transform
      case "cm": if numbers.count == 6 { transform = TextCanvasSupport.concatenate(transform, numbers) }
      case "m": if numbers.count == 2 { current = point(numbers[0], numbers[1]); start = current }
      case "l":
        if numbers.count == 2, let a = current {
          let b = point(numbers[0], numbers[1]); line(a, b); current = b
        }
      case "re":
        if numbers.count == 4 {
          let x = numbers[0], y = numbers[1], w = numbers[2], h = numbers[3]
          let corners = [point(x, y), point(x + w, y), point(x + w, y + h), point(x, y + h)]
          for index in 0..<4 { line(corners[index], corners[(index + 1) % 4]) }
          current = corners[0]; start = current
        }
      case "h": if let a = current, let b = start { line(a, b); current = b }
      case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
        if ["s", "b", "b*"].contains(instruction.operatorName), let a = current, let b = start { line(a, b) }
        result += path.filter { abs($0[1] - $0[3]) <= 0.75 && abs($0[0] - $0[2]) >= 12 }
        path.removeAll(keepingCapacity: true); current = nil; start = nil
      case "n": path.removeAll(keepingCapacity: true); current = nil; start = nil
      case "c", "v", "y": current = nil
      default: break
      }
      guard path.count <= 16_384, result.count <= 4_096 else {
        throw PDFError(.limitExceeded, "Too many vector rules for paragraph discovery")
      }
    }
    return result
  }

  public struct SourceRun: Sendable {
    public let index: Int
    public let instruction: Int
    public let x: Double
    public let baseline: Double
    public let text: String
    public let format: PageTextFormat
    public let fragments: [PageTextFragment]
    public let textScale: Double
  }

  public static func fontProfiles(pageID: PDFObjectID, in graph: PDFGraph) throws -> [PDFName: PageTextFontProfile] {
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [:] }
    let runs = try TextRunIndexer.runs(in: PageContent.load(pageID: pageID, in: graph), graph: graph)
    var result: [PDFName: PageTextFontProfile] = [:]
    for resource in Set(runs.map(\.fontResource)) {
      result[resource] = IndexedTextFont.resolve(resource: resource, page: page, in: graph)?.profile
    }
    return result
  }

  static func format(for run: TextRun, family: String, pageID: PDFObjectID, in graph: PDFGraph,
    standard: Set<PDFName>? = nil, profiles: [PDFName: PageTextFontProfile]? = nil) -> PageTextFormat? {
    if let profile = (profiles ?? (try? fontProfiles(pageID: pageID, in: graph)) ?? [:])[run.fontResource] {
      guard PageTextSourceFont.canWriteInline(run.text) else { return nil }
      let glyphs = run.text.unicodeScalars.compactMap { profile.glyphs[String($0)] }
      guard glyphs.count == run.text.unicodeScalars.count,
        glyphs.flatMap(\.codes) == run.rawCodes else { return nil }
      return .init(size: run.fontSize, color: run.fillColor, sourceFont: profile.source,
        characterSpacing: run.charSpacing)
    }
    let standard = standard ?? standardResources(pageID: pageID, in: graph)
    guard let face = StandardTextFont(rawValue: family), standard.contains(run.fontResource) else { return nil }
    return .init(font: face, size: run.fontSize, color: run.fillColor, characterSpacing: run.charSpacing)
  }
  private static func standardResources(pageID: PDFObjectID, in graph: PDFGraph) -> Set<PDFName> {
    guard let content = try? PageContent.load(pageID: pageID, in: graph),
      let runs = try? TextRunIndexer.runs(in: content, graph: graph),
      let indices = try? StandardTextFont.editableRunIndices(pageID: pageID, in: graph) else { return [] }
    return Set(indices.map { runs[$0].fontResource })
  }

  public static func sourceRuns(pageID: PDFObjectID, in graph: PDFGraph) throws -> [SourceRun] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    let profiles = try fontProfiles(pageID: pageID, in: graph)
    let standard = standardResources(pageID: pageID, in: graph)
    var fonts: [PDFName: IndexedTextFont] = [:]
    for resource in Set(runs.map(\.fontResource)) {
      fonts[resource] = IndexedTextFont.resolve(resource: resource, page: page, in: graph)
    }
    return runs.indices.compactMap { index in
      let run = runs[index]
      let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
      guard transform[0] > 0, abs(transform[0] - transform[3]) < 1e-6,
        abs(transform[1]) < 1e-6, abs(transform[2]) < 1e-6,
        run.horizontalScale == 100, run.rise == 0,
        TextCanvasSupport.renderingMode(at: run.instructionIndex, in: content) == 0 else { return nil }
      let style = TextEditTargeting.inputStyle(runIndex: index, runs: runs, in: graph)
      guard var format = format(for: run, family: style.fontFamily ?? "", pageID: pageID,
        in: graph, standard: standard, profiles: profiles), run.hasKnownOffset,
        let font = fonts[run.fontResource],
        let glyphs = font.glyphs(run.rawCodes), font.encode(run.text) == run.rawCodes else { return nil }
      format.size *= transform[0]
      format.characterSpacing *= transform[0]
      guard format.isValid else { return nil }
      let fragments = glyphs.map { glyph -> PageTextFragment in
        var format = format
        if glyph.codes == [32] { format.characterSpacing += run.wordSpacing * transform[0] }
        return .init(text: glyph.text, format: format)
      }
      return .init(index: index, instruction: run.instructionIndex,
        x: transform[4] + run.textSpaceOffset * transform[0], baseline: transform[5],
        text: run.text, format: format, fragments: fragments, textScale: transform[0])
    }
  }

  public static func hidingParagraph(pageID: PDFObjectID, originalText: [Int: String],
    standardFontAdvances: [Int: Double], in graph: PDFGraph) throws -> PDFGraph {
    try RewritePageTextCommand(pageID: pageID, originalText: originalText, lines: [],
      fontSize: 12, color: [0, 0, 0], standardFontAdvances: standardFontAdvances).validate(in: graph)
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph)
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    let instructions = Set(originalText.keys.map { runs[$0].instructionIndex })
    let ranges = instructions.sorted().flatMap { index -> [(range: Range<Int>, replacement: [UInt8])] in
      let range = TextStyleSupport.fullSpan(of: content.instructions[index])
      return [(range.lowerBound..<range.lowerBound, Array("\n3 Tr\n".utf8)),
        (range.upperBound..<range.upperBound, Array("\n0 Tr\n".utf8))]
    }
    return try content.replacing(ranges: ranges, in: graph)
  }
  public static func blocks(pageID: PDFObjectID, in graph: PDFGraph) throws -> [PageTextBlock] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else { return [] }
    var fonts: [PDFName: IndexedTextFont] = [:]
    for resource in Set(runs.map(\.fontResource)) {
      fonts[resource] = IndexedTextFont.resolve(resource: resource, page: page, in: graph)
    }
    let grouped = Dictionary(grouping: runs.indices, by: { runs[$0].instructionIndex })
    return grouped.keys.sorted().compactMap { instruction in
      guard let indices = grouped[instruction], let first = indices.first,
        let font = fonts[runs[first].fontResource], font.isInlineEditable || font.simple?.isEditable == true,
        let segment = content.segmentIndex(for: runs[first].stringSpan), content.segments[segment].isEditable,
        TextCanvasSupport.renderingMode(at: instruction, in: content) == 0,
        let rect = TextEditTargeting.union(
          layout.clusters.filter {
            indices.contains($0.runIndex)
          }.map(\.bounds))
      else { return nil }
      let text = indices.map { runs[$0].text }.joined()
      guard !text.isEmpty else { return nil }
      return PageTextBlock(
        runIndices: indices, text: text, rect: rect,
        style: TextEditTargeting.inputStyle(runIndex: first, runs: runs, in: graph),
        fontResource: runs[first].fontResource)
    }
  }

  /// A rendering-only graph: invisible glyphs retain their original advances
  /// and all background content. The document session never adopts this graph.
  public static func hidingBlock(pageID: PDFObjectID, runIndex: Int, in graph: PDFGraph) throws
    -> PDFGraph
  {
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: PDFLimits())
    let run = try TextStyleSupport.editableRun(
      pageID: pageID, runIndex: runIndex,
      in: graph, limits: PDFLimits())
    let content = try PageContent.load(pageID: pageID, in: graph)
    guard TextCanvasSupport.renderingMode(at: run.instructionIndex, in: content) == 0 else {
      throw PDFError(
        .unsupported, "This text uses a paint or clipping mode that cannot be edited inline")
    }
    let instruction = content.instructions[run.instructionIndex]
    let transform = TextCanvasSupport.concatenate(run.ctm, run.matrix)
    let ordinaryTransform =
      transform[0] > 0 && abs(transform[0] - transform[3]) < 1e-6
      && abs(transform[1]) < 1e-6 && abs(transform[2]) < 1e-6
    let ordinarySpacing =
      abs(run.charSpacing) < 1e-6 && abs(run.wordSpacing) < 1e-6
      && abs(run.horizontalScale - 100) < 1e-6
    let adjustedArray: Bool
    if case .array(let members)? = instruction.operands.first?.value {
      adjustedArray = members.contains {
        switch $0 {
        case .integer(let value): return value != 0
        case .real(let value): return abs(value) > 1e-6
        default: return false
        }
      }
    } else {
      adjustedArray = false
    }
    guard ordinaryTransform, ordinarySpacing, !adjustedArray else {
      throw PDFError(
        .unsupported,
        "Inline editing currently requires horizontal text with ordinary character spacing")
    }
    let range = TextStyleSupport.fullSpan(of: instruction)
    return try content.replacing(
      ranges: [
        (range.lowerBound..<range.lowerBound, Array("\n3 Tr\n".utf8)),
        (range.upperBound..<range.upperBound, Array("\n0 Tr\n".utf8)),
      ], in: graph, limits: PDFLimits())
  }
}

enum TextCanvasSupport {
  static func renderingMode(at instructionIndex: Int, in content: PageContent) -> Int {
    var mode = 0
    var stack: [Int] = []
    for instruction in content.instructions.prefix(instructionIndex + 1) {
      switch instruction.operatorName {
      case "q": stack.append(mode)
      case "Q": mode = stack.popLast() ?? mode
      case "Tr":
        if case .integer(let value)? = instruction.operands.first?.value { mode = Int(value) }
      default: break
      }
    }
    return mode
  }
  static func concatenate(_ a: [Double], _ b: [Double]) -> [Double] {
    [
      a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
      a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
      a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5],
    ]
  }

  static func localDelta(dx: Double, dy: Double, ctm: [Double]) throws -> (Double, Double) {
    let determinant = ctm[0] * ctm[3] - ctm[1] * ctm[2]
    guard determinant.isFinite, abs(determinant) > 1e-10 else {
      throw PDFError(.unsupported, "The text has a singular graphics transform")
    }
    return ((ctm[3] * dx - ctm[2] * dy) / determinant, (-ctm[1] * dx + ctm[0] * dy) / determinant)
  }
}
