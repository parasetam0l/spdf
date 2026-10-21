import Foundation
import PDFCore

/// P13-024: one editable text string run on a page, mapped back to the exact
/// operand bytes it came from plus the text state in effect when it is shown.
struct TextRun {
  let pageID: PDFObjectID
  let instructionIndex: Int
  let operandPath: [Int]
  let stringSpan: Range<Int>
  let rawCodes: [UInt8]
  let text: String
  let fontResource: PDFName
  let fontID: PDFObjectID
  let fontSize: Double
  let charSpacing: Double
  let wordSpacing: Double
  let horizontalScale: Double
  let leading: Double
  let rise: Double
  let fillColor: [Double]
  let fillAlpha: Double
  let matrix: [Double]
  /// Graphics transform at this show; kept separate from the text matrix.
  let ctm: [Double]
  let baselineX: Double
  let baselineY: Double
  /// Advance accumulated inside the same TJ array before this run (text-space
  /// units), used to place members after the first.
  let textSpaceOffset: Double
  let hasKnownOffset: Bool
}

/// P13-011..P13-014: walks parsed instructions tracking text objects, font
/// and spacing state, text/line matrices, and the text-show operators.
enum TextRunIndexer {
  private typealias Matrix = [Double]

  private struct TextState {
    var font: IndexedTextFont?
    var fontSize = 0.0
    var charSpacing = 0.0
    var wordSpacing = 0.0
    var horizontalScale = 100.0
    var leading = 0.0
    var rise = 0.0
    /// P19-010: the current non-stroking color, so reflow can preserve it.
    var fillColor = [0.0, 0.0, 0.0]
    var fillAlpha = 1.0
    var ctm = [1.0, 0, 0, 1, 0, 0]
  }

  static func runs(
    in content: PageContent, graph: PDFGraph, limits: PDFLimits = PDFLimits(),
    resources: [PDFName: PDFValue]? = nil, allowStandard14MetricFallback: Bool = false
  ) throws -> [TextRun] {
    let page: [PDFName: PDFValue]
    if let resources {
      // P18-017: form-local indexing resolves fonts against the form's own
      // resources (falling back to the page's, chosen by the caller).
      page = [PDFName("Resources"): .dictionary(resources)]
    } else if case .dictionary(let dictionary)? = graph.objects[content.pageID] {
      page = dictionary
    } else {
      throw PDFError(.malformed, "Page is missing")
    }

    var runs: [TextRun] = []
    var state = TextState()
    var stateStack: [TextState] = []
    var matrix: Matrix = [1, 0, 0, 1, 0, 0]
    var lineMatrix: Matrix = [1, 0, 0, 1, 0, 0]
    var fonts: [PDFName: IndexedTextFont] = [:]
    var knownFonts = Set<PDFName>()

    func number(_ operand: ContentOperand?) -> Double? {
      switch operand?.value {
      case .integer(let value)?: return Double(value)
      case .real(let value)?: return value
      default: return nil
      }
    }

    func translate(_ tx: Double, _ ty: Double, _ matrix: Matrix) -> Matrix {
      [matrix[0], matrix[1], matrix[2], matrix[3],
        matrix[4] + tx * matrix[0] + ty * matrix[2],
        matrix[5] + tx * matrix[1] + ty * matrix[3]]
    }

    func appendRun(
      instructionIndex: Int, path: [Int], span: Range<Int>, codes: [UInt8],
      textSpaceOffset: Double = 0, hasKnownOffset: Bool = true
    ) {
      guard let font = state.font else { return }
      runs.append(
        TextRun(
          pageID: content.pageID, instructionIndex: instructionIndex, operandPath: path,
          stringSpan: span, rawCodes: codes, text: font.decode(codes),
          fontResource: font.resource, fontID: font.fontID, fontSize: state.fontSize,
          charSpacing: state.charSpacing, wordSpacing: state.wordSpacing,
          horizontalScale: state.horizontalScale, leading: state.leading, rise: state.rise,
          fillColor: state.fillColor, fillAlpha: state.fillAlpha,
          matrix: matrix, ctm: state.ctm, baselineX: matrix[4], baselineY: matrix[5],
          textSpaceOffset: textSpaceOffset, hasKnownOffset: hasKnownOffset))
    }

    func advance(_ codes: [UInt8]) -> Double? {
      guard let font = state.font else { return nil }
      return font.advance(of: codes, fontSize: state.fontSize,
        charSpacing: state.charSpacing, wordSpacing: state.wordSpacing,
        horizontalScale: state.horizontalScale)
        ?? (allowStandard14MetricFallback
          ? font.standard14Advance(of: codes, fontSize: state.fontSize,
            charSpacing: state.charSpacing, wordSpacing: state.wordSpacing,
            horizontalScale: state.horizontalScale)
          : nil)
    }

    func advancePen(_ codes: [UInt8]) {
      guard let amount = advance(codes) else { return }
      matrix[4] += amount * matrix[0]
      matrix[5] += amount * matrix[1]
    }
    for (index, instruction) in content.instructions.enumerated() {
      try Task.checkCancellation()
      switch instruction.operatorName {
      case "BT":
        matrix = [1, 0, 0, 1, 0, 0]
        lineMatrix = matrix
      case "ET":
        break
      case "q":
        guard stateStack.count < limits.nesting else {
          throw PDFError(.limitExceeded, "Graphics state stack exceeds the configured limit")
        }
        stateStack.append(state)
      case "Q":
        if let saved = stateStack.popLast() { state = saved }
      case "cm":
        let values = instruction.operands.compactMap { number($0) }
        if values.count == 6 { state.ctm = TextCanvasSupport.concatenate(state.ctm, values) }
      case "Tf":
        guard case .name(let name)? = instruction.operands.first?.value,
          let size = number(instruction.operands.count > 1 ? instruction.operands[1] : nil)
        else { break }
        if knownFonts.insert(name).inserted {
          fonts[name] = IndexedTextFont.resolve(resource: name, page: page, in: graph)
        }
        state.font = fonts[name]
        state.fontSize = size
      case "Tc":
        state.charSpacing = number(instruction.operands.first) ?? state.charSpacing
      case "Tw":
        state.wordSpacing = number(instruction.operands.first) ?? state.wordSpacing
      case "Tz":
        state.horizontalScale = number(instruction.operands.first) ?? state.horizontalScale
      case "TL":
        state.leading = number(instruction.operands.first) ?? state.leading
      case "Ts":
        state.rise = number(instruction.operands.first) ?? state.rise
      case "g":
        if let value = number(instruction.operands.first) {
          state.fillColor = [value, value, value]
        }
      case "rg":
        let values = instruction.operands.prefix(3).compactMap { operand -> Double? in
          switch operand.value {
          case .integer(let value): return Double(value)
          case .real(let value): return value
          default: return nil
          }
        }
        if values.count == 3 { state.fillColor = values }
      case "k":
        let values = instruction.operands.prefix(4).compactMap { operand -> Double? in
          switch operand.value {
          case .integer(let value): return Double(value)
          case .real(let value): return value
          default: return nil
          }
        }
        if values.count == 4 {
          let (c, m, y, k) = (values[0], values[1], values[2], values[3])
          state.fillColor = [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)]
        }
      case "gs":
        guard case .name(let name)? = instruction.operands.first?.value,
          case .dictionary(let resources)? = FontValue.resolve(
            page[PDFName("Resources")], in: graph),
          case .dictionary(let states)? = FontValue.resolve(
            resources[PDFName("ExtGState")], in: graph),
          case .dictionary(let stateDictionary)? = FontValue.resolve(states[name], in: graph)
        else { break }
        let alpha: Double?
        switch stateDictionary[PDFName("ca")] {
        case .integer(let value)?: alpha = Double(value)
        case .real(let value)?: alpha = value
        default: alpha = nil
        }
        guard let alpha, alpha.isFinite, (0...1).contains(alpha) else { break }
        state.fillAlpha = alpha
      case "Td", "TD":
        guard let tx = number(instruction.operands.first),
          let ty = number(instruction.operands.count > 1 ? instruction.operands[1] : nil)
        else { break }
        if instruction.operatorName == "TD" { state.leading = -ty }
        lineMatrix = translate(tx, ty, lineMatrix)
        matrix = lineMatrix
      case "Tm":
        let values = instruction.operands.prefix(6).compactMap { operand -> Double? in
          switch operand.value {
          case .integer(let value): return Double(value)
          case .real(let value): return value
          default: return nil
          }
        }
        if values.count == 6 {
          lineMatrix = values
          matrix = values
        }
      case "T*":
        lineMatrix = translate(0, -state.leading, lineMatrix)
        matrix = lineMatrix
      case "Tj":
        if case .string(let codes)? = instruction.operands.first?.value,
          let span = instruction.operands.first?.span
        {
          appendRun(instructionIndex: index, path: [0], span: span, codes: [UInt8](codes))
          advancePen([UInt8](codes))
        }
      case "TJ":
        let spans = arrayMemberSpans(in: content, instructionIndex: index)
        if case .array(let members)? = instruction.operands.first?.value {
          var offset = 0.0
          var offsetKnown = true
          for (memberIndex, member) in members.enumerated() {
            switch member {
            case .string(let codes):
              if memberIndex < spans.count {
                appendRun(
                  instructionIndex: index, path: [0, memberIndex], span: spans[memberIndex],
                  codes: [UInt8](codes), textSpaceOffset: offset, hasKnownOffset: offsetKnown)
              }
              if let advance = advance([UInt8](codes)) {
                offset += advance
              } else {
                offsetKnown = false
              }
            case .integer(let raw):
              offset -= Double(raw) * state.fontSize / 1000 * state.horizontalScale / 100
            case .real(let raw):
              offset -= raw * state.fontSize / 1000 * state.horizontalScale / 100
            default:
              offsetKnown = false
            }
          }
          if offsetKnown {
            matrix[4] += offset * matrix[0]
            matrix[5] += offset * matrix[1]
          }
        }
      case "'":
        lineMatrix = translate(0, -state.leading, lineMatrix)
        matrix = lineMatrix
        if case .string(let codes)? = instruction.operands.first?.value,
          let span = instruction.operands.first?.span
        {
          appendRun(instructionIndex: index, path: [0], span: span, codes: [UInt8](codes))
          advancePen([UInt8](codes))
        }
      case "\"":
        state.wordSpacing = number(instruction.operands.first) ?? state.wordSpacing
        state.charSpacing =
          number(instruction.operands.count > 1 ? instruction.operands[1] : nil)
          ?? state.charSpacing
        lineMatrix = translate(0, -state.leading, lineMatrix)
        matrix = lineMatrix
        if instruction.operands.count > 2,
          case .string(let codes) = instruction.operands[2].value
        {
          appendRun(
            instructionIndex: index, path: [2], span: instruction.operands[2].span,
            codes: [UInt8](codes))
          advancePen([UInt8](codes))
        }
      default:
        break
      }
    }
    return runs
  }

  /// Byte spans of every member of a TJ array operand, aligned by index.
  private static func arrayMemberSpans(in content: PageContent, instructionIndex: Int)
    -> [Range<Int>]
  {
    guard let operand = content.instructions[instructionIndex].operands.first,
      case .array = operand.value,
      var parser = try? PDFSyntaxParser(bytes: content.bytes, offset: operand.span.lowerBound)
    else { return [] }
    guard parser.peekByte == 91, (try? parser.setOffset(parser.offset + 1)) != nil else {
      return []
    }
    var spans: [Range<Int>] = []
    while true {
      parser.skipTrivia()
      guard let byte = parser.peekByte, byte != 93 else { break }
      let start = parser.offset
      guard (try? parser.value()) != nil else { return spans }
      spans.append(start..<parser.offset)
    }
    return spans
  }
}
