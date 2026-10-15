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
  public static func blocks(pageID: PDFObjectID, in graph: PDFGraph) throws -> [PageTextBlock] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    let layout = try PageTextLayout.build(pageID: pageID, in: graph)
    let grouped = Dictionary(grouping: runs.indices, by: { runs[$0].instructionIndex })
    return grouped.keys.sorted().compactMap { instruction in
      guard let indices = grouped[instruction], let first = indices.first,
        (try? TextStyleSupport.editableRun(
          pageID: pageID, runIndex: first,
          in: graph, limits: PDFLimits())) != nil,
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
