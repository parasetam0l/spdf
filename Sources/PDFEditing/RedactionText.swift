import Foundation
import PDFCore

// MARK: - Hidden text inventory (RED-02 explicit scope)

/// What hidden text a page carries. Hidden text is invisible text that is
/// still extractable: a generated OCR layer or text drawn with a hidden text
/// rendering mode (3 fill/clip and 7 clip). Redaction must account for it so a
/// removed word cannot survive in an unseen copy.
public struct RedactionHiddenTextInventory: Sendable, Equatable {
  public let generatedLayerStreamIDs: [PDFObjectID]
  /// Invisible text runs in the page's own content streams (not the OCR layer).
  public let hiddenRunCount: Int
  /// True when a hidden text-show operator exists that this profile cannot
  /// index (for example an unsupported font). Applying is then refused instead
  /// of leaving an uninspectable hidden copy behind.
  public let hasUninspectableHiddenText: Bool

  /// True when hidden text the profile can enumerate is present. Unreadable
  /// hidden text is reported separately so a disclosure never claims hidden
  /// text on a page that merely contains an unsupported visible font.
  public var hasHiddenText: Bool {
    !generatedLayerStreamIDs.isEmpty || hiddenRunCount > 0
  }
}

enum RedactionHiddenText {
  struct HiddenInfo {
    let hiddenRunIndices: Set<Int>
    let layerRunIndices: Set<Int>
    let uninspectable: Bool
  }

  static func inventory(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> RedactionHiddenTextInventory {
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    let info = try hiddenInfo(
      pageID: pageID, in: graph, content: content, runs: runs, limits: limits)
    let layerIDs = info.layerRunIndices.compactMap { index -> PDFObjectID? in
      guard runs.indices.contains(index) else { return nil }
      let span = runs[index].stringSpan
      return content.segments.first {
        $0.range.contains(span.lowerBound)
          && OCRLayer.layerStreamIDs(in: graph, pageID: pageID).contains($0.objectID)
      }?.objectID
    }
    let visibleLayerIDs = Set(layerIDs)
    return RedactionHiddenTextInventory(
      generatedLayerStreamIDs: visibleLayerIDs.sorted { $0.number < $1.number },
      hiddenRunCount: info.hiddenRunIndices.count,
      hasUninspectableHiddenText: info.uninspectable)
  }

  /// Classify every text run as hidden, part of a generated OCR layer, or
  /// ordinary visible text. Text rendering mode follows the graphics-state
  /// stack (q/Q saves and restores it).
  static func hiddenInfo(
    pageID: PDFObjectID, in graph: PDFGraph, content: PageContent, runs: [TextRun],
    limits: PDFLimits
  ) throws -> HiddenInfo {
    let layerIDs = Set(OCRLayer.layerStreamIDs(in: graph, pageID: pageID))
    let layerRanges = content.segments.filter { layerIDs.contains($0.objectID) }.map(\.range)
    // Text rendering mode at each text-show instruction.
    var showModes: [Int: Int] = [:]
    var stack: [Int] = []
    var mode = 0
    var stringMembers: [Int: Int] = [:]
    for (index, instruction) in content.instructions.enumerated() {
      switch instruction.operatorName {
      case "q":
        stack.append(mode)
      case "Q":
        if let saved = stack.popLast() { mode = saved }
      case "Tr":
        if let value = RedactionTextNumbers.number(instruction.operands.first?.value) {
          mode = Int(value)
        }
      case "Tj", "'":
        showModes[index] = mode
        stringMembers[index] = 1
      case "\"":
        showModes[index] = mode
        stringMembers[index] = 1
      case "TJ":
        showModes[index] = mode
        if case .array(let members)? = instruction.operands.first?.value {
          stringMembers[index] = members.reduce(0) { count, value in
            if case .string = value { return count + 1 }
            return count
          }
        } else {
          stringMembers[index] = 0
        }
      default:
        break
      }
    }
    var hidden: Set<Int> = []
    var layer: Set<Int> = []
    var runsPerInstruction: [Int: Int] = [:]
    for (index, run) in runs.enumerated() {
      runsPerInstruction[run.instructionIndex, default: 0] += 1
      let inLayer = layerRanges.contains { $0.contains(run.stringSpan.lowerBound) }
      if inLayer {
        layer.insert(index)
        continue
      }
      if let showMode = showModes[run.instructionIndex], showMode == 3 || showMode == 7 {
        hidden.insert(index)
      }
    }
    var uninspectable = false
    for (instructionIndex, expected) in stringMembers {
      if (runsPerInstruction[instructionIndex] ?? 0) != expected {
        uninspectable = true
        break
      }
    }
    return HiddenInfo(
      hiddenRunIndices: hidden, layerRunIndices: layer, uninspectable: uninspectable)
  }
}

/// Small numeric helpers shared by the redaction text path.
enum RedactionTextNumbers {
  static func number(_ value: PDFValue?) -> Double? {
    switch value {
    case .integer(let raw)?: return Double(raw)
    case .real(let raw)?: return raw
    default: return nil
    }
  }
}

// MARK: - Glyph-precise text removal

/// Analysis of what a text mark removes from one page. It is non-mutating and
/// shared by the review plan and the apply command so the review and the
/// removal can never disagree.
struct RedactionTextAnalysis: Sendable, Equatable {
  /// Page-content runs whose glyphs are removed, by run index.
  var removedGlyphs: [Int: Set<Int>]
  /// Review clusters under the mark (including hidden/OCR layer clusters that
  /// are removed by layer removal rather than glyph editing).
  var removedClusterCount: Int
  /// Hidden/OCR-layer clusters under the mark; the generated layer is removed
  /// wholesale.
  var layerClusterCount: Int
  /// Distinct runs targeted by the mark.
  var runCount: Int

  var removesOCRLayer: Bool { layerClusterCount > 0 }
}

enum RedactionTextPrecision {
  /// Validate that the glyphs under the mark can be removed exactly, and
  /// report what would be removed. Throws before any mutation.
  static func analyze(
    pageID: PDFObjectID, rects: [[Double]], hiddenOnly: Bool, in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> RedactionTextAnalysis {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    guard content.segments.allSatisfy(\.isEditable) else {
      throw PDFError(
        .unsupported, "This page content uses filters that text redaction cannot edit safely")
    }
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    let hiddenInfo = try RedactionHiddenText.hiddenInfo(
      pageID: pageID, in: graph, content: content, runs: runs, limits: limits)
    guard !hiddenInfo.uninspectable else {
      throw PDFError(
        .unsupported,
        "This page contains text in a font this redaction profile cannot inspect")
    }
    let layout = try PageTextLayout.buildForParagraphEditing(
      pageID: pageID, in: graph, limits: limits)
    var clustersByRun: [Int: [Int: TextCluster]] = [:]
    for cluster in layout.clusters {
      clustersByRun[cluster.runIndex, default: [:]][cluster.glyphIndex] = cluster
    }
    var removedGlyphs: [Int: Set<Int>] = [:]
    var layerRuns: Set<Int> = []
    var removedClusters = 0
    var layerClusters = 0
    for cluster in layout.clusters {
      guard RedactRegionsCommand.intersects(cluster.bounds, anyRegion: rects) else { continue }
      let runIndex = cluster.runIndex
      if hiddenOnly && !hiddenInfo.hiddenRunIndices.contains(runIndex)
        && !hiddenInfo.layerRunIndices.contains(runIndex)
      {
        continue
      }
      removedClusters += 1
      if hiddenInfo.layerRunIndices.contains(runIndex) {
        layerClusters += 1
        layerRuns.insert(runIndex)
        continue
      }
      guard runs.indices.contains(runIndex) else {
        throw PDFError(.malformed, "A reviewed text run is missing from the page")
      }
      guard cluster.text.unicodeScalars.count <= 1 else {
        throw PDFError(
          .unsupported,
          "The reviewed text uses a ligature or combined glyph; remove the whole run in the paragraph editor instead")
      }
      guard cluster.advance != nil else {
        throw PDFError(
          .unsupported,
          "This font has no width data; removed glyphs cannot keep the following text in place")
      }
      try validateEditableRun(
        runs[runIndex], content: content, page: page, graph: graph, limits: limits)
      removedGlyphs[runIndex, default: []].insert(cluster.glyphIndex)
    }
    _ = clustersByRun
    return RedactionTextAnalysis(
      removedGlyphs: removedGlyphs, removedClusterCount: removedClusters,
      layerClusterCount: layerClusters, runCount: removedGlyphs.count + layerRuns.count)
  }

  /// Full removal of every hidden text run in the page's own content (the
  /// generated OCR layer is removed separately). Used when a page is affected
  /// by redaction and the hidden-text policy removes hidden copies entirely.
  static func allHiddenRunRemovals(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> [Int: Set<Int>] {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    let info = try RedactionHiddenText.hiddenInfo(
      pageID: pageID, in: graph, content: content, runs: runs, limits: limits)
    guard !info.uninspectable else {
      throw PDFError(
        .unsupported,
        "This page contains hidden text in a font this redaction profile cannot inspect")
    }
    var removals: [Int: Set<Int>] = [:]
    for runIndex in info.hiddenRunIndices.sorted() {
      guard runs.indices.contains(runIndex) else { continue }
      let run = runs[runIndex]
      try validateEditableRun(run, content: content, page: page, graph: graph, limits: limits)
      guard let font = IndexedTextFont.resolve(
        resource: run.fontResource, page: page, in: graph),
        let glyphs = font.glyphs(run.rawCodes)
      else {
        throw PDFError(
          .unsupported,
          "This page contains hidden text in a font this redaction profile cannot inspect")
      }
      removals[runIndex] = Set(glyphs.indices)
    }
    return removals
  }

  static func validateEditableRun(
    _ run: TextRun, content: PageContent, page: [PDFName: PDFValue], graph: PDFGraph,
    limits: PDFLimits
  ) throws {
    guard content.instructions.indices.contains(run.instructionIndex) else {
      throw PDFError(.malformed, "A reviewed text run is missing its instruction")
    }
    let operatorName = content.instructions[run.instructionIndex].operatorName
    guard operatorName == "Tj" || operatorName == "TJ" else {
      throw PDFError(
        .unsupported,
        "Text redaction supports Tj and TJ runs only; this run uses " + operatorName)
    }
    guard content.segmentIndex(for: run.stringSpan) != nil else {
      throw PDFError(
        .unsupported, "The reviewed text run spans streams that cannot be edited precisely")
    }
    let segmentIndices = content.segmentIndices(for: run.stringSpan) ?? []
    for index in segmentIndices where segmentIndices.count == 1 {
      let objectID = content.segments[index].objectID
      if content.segments.filter({ $0.objectID == objectID }).count > 1 {
        throw PDFError(
          .unsupported, "A repeated page content stream cannot be edited selectively")
      }
    }
    guard let font = SimpleFont.resolve(
      resource: run.fontResource, page: page, in: graph)
    else {
      throw PDFError(
        .unsupported, "The reviewed text's font cannot be edited by this profile")
    }
    guard font.isSupported, font.isEditable else {
      throw PDFError(
        .unsupported, "The reviewed text's font cannot be edited by this profile")
    }
    guard !font.isType3 else {
      throw PDFError(
        .unsupported, "Type 3 glyph programs can paint beyond their text bounds and are not redacted here")
    }
    _ = limits
  }

  /// Rewrite the inspected runs so the reviewed glyphs disappear while every
  /// following glyph keeps its page position. One content rewrite per touched
  /// instruction; nothing else in the page changes.
  static func apply(
    pageID: PDFObjectID, removals: [Int: Set<Int>], in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    guard !removals.isEmpty else { return graph }
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let graph = try PageContentCopy.makePrivate(pageID: pageID, in: graph, limits: limits)
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
    let layout = try PageTextLayout.buildForParagraphEditing(
      pageID: pageID, in: graph, limits: limits)
    var clustersByRun: [Int: [Int: TextCluster]] = [:]
    for cluster in layout.clusters {
      clustersByRun[cluster.runIndex, default: [:]][cluster.glyphIndex] = cluster
    }

    struct InstructionEdit {
      let instructionIndex: Int
      /// Replacement value per TJ member index, or [0] for a Tj operand.
      var memberReplacements: [Int: [PDFValue]]
    }
    var edits: [Int: InstructionEdit] = [:]
    for runIndex in removals.keys.sorted() {
      guard runs.indices.contains(runIndex) else {
        throw PDFError(.malformed, "A redaction text run is missing from the page")
      }
      let run = runs[runIndex]
      let glyphs = try glyphValues(
        run, page: page, graph: graph, content: content)
      guard let removed = removals[runIndex], !removed.isEmpty else { continue }
      guard removed.allSatisfy({ glyphs.indices.contains($0) }) else {
        throw PDFError(.malformed, "A redaction glyph index is outside its text run")
      }
      let values = try replacementValues(
        run: run, glyphs: glyphs, removed: removed,
        clusters: clustersByRun[runIndex] ?? [:], limits: limits)
      let memberIndex = run.operandPath.count == 2 ? run.operandPath[1] : 0
      edits[run.instructionIndex, default: InstructionEdit(
        instructionIndex: run.instructionIndex, memberReplacements: [:])]
        .memberReplacements[memberIndex] = values
    }

    var ranges: [(range: Range<Int>, replacement: [UInt8])] = []
    for instructionIndex in edits.keys.sorted() {
      guard content.instructions.indices.contains(instructionIndex) else {
        throw PDFError(.malformed, "A redaction instruction is missing from the page")
      }
      let instruction = content.instructions[instructionIndex]
      let edit = edits[instructionIndex]!
      let values: [PDFValue]
      switch instruction.operatorName {
      case "Tj":
        guard let replaced = edit.memberReplacements[0] else { continue }
        values = replaced
      case "TJ":
        guard let operand = instruction.operands.first,
          case .array(let members) = operand.value
        else {
          throw PDFError(.malformed, "A TJ instruction lost its array")
        }
        var rebuilt: [PDFValue] = []
        for (memberIndex, member) in members.enumerated() {
          if let replacement = edit.memberReplacements[memberIndex] {
            rebuilt.append(contentsOf: replacement)
          } else {
            rebuilt.append(member)
          }
        }
        values = rebuilt
      default:
        throw PDFError(
          .unsupported,
          "Text redaction supports Tj and TJ runs only; this run uses "
            + instruction.operatorName)
      }
      guard let operand = instruction.operands.first else {
        throw PDFError(.malformed, "A text-show instruction lost its operand")
      }
      let serialized = try PDFWriter.serializedValue(.array(values), limits: limits)
      var bytes = [UInt8](serialized)
      bytes.append(contentsOf: Array(" TJ".utf8))
      // ContentInstruction.span covers the operator only; replace the operand
      // together with the operator so the original array/string is gone.
      ranges.append((operand.span.lowerBound..<instruction.span.upperBound, bytes))
    }
    guard !ranges.isEmpty else { return graph }
    return try content.replacing(ranges: ranges, in: graph, limits: limits)
  }

  static func glyphValues(
    _ run: TextRun, page: [PDFName: PDFValue], graph: PDFGraph, content: PageContent
  ) throws -> [IndexedTextFont.Glyph] {
    guard let font = IndexedTextFont.resolve(
      resource: run.fontResource, page: page, in: graph),
      let glyphs = font.glyphs(run.rawCodes)
    else {
      throw PDFError(
        .unsupported, "The reviewed text's font cannot be edited by this profile")
    }
    return glyphs
  }

  /// Build the TJ values that replace one reviewed run: kept glyph strings in
  /// order, with a displacement number wherever removed glyphs left a gap, so
  /// the run keeps its original advance and following text does not move.
  static func replacementValues(
    run: TextRun, glyphs: [IndexedTextFont.Glyph], removed: Set<Int>,
    clusters: [Int: TextCluster], limits: PDFLimits
  ) throws -> [PDFValue] {
    let em = run.fontSize / 1_000 * run.horizontalScale / 100
    guard em.isFinite, abs(em) > 1e-9 else {
      throw PDFError(
        .unsupported,
        "The reviewed text has no usable font size; glyph positions cannot be preserved")
    }
    var values: [PDFValue] = []
    var keptCodes: [UInt8] = []
    var gap = 0.0
    func flushKept() {
      if !keptCodes.isEmpty {
        values.append(.string(Data(keptCodes)))
        keptCodes.removeAll()
      }
    }
    func flushGap() {
      guard abs(gap) > 1e-9 else {
        gap = 0
        return
      }
      values.append(ReplaceTextCommand.adjustmentValue(-gap / em))
      gap = 0
    }
    for (index, glyph) in glyphs.enumerated() {
      if removed.contains(index) {
        flushKept()
        guard let cluster = clusters[index], let advance = cluster.advance else {
          throw PDFError(
            .unsupported,
            "This font has no width data; removed glyphs cannot keep the following text in place")
        }
        gap += advance
        continue
      }
      if abs(gap) > 1e-9 { flushGap() }
      keptCodes.append(contentsOf: glyph.codes)
    }
    flushKept()
    flushGap()
    _ = limits
    return values
  }
}
