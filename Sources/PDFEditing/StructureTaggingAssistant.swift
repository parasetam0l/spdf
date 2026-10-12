import Foundation
import PDFCore

/// P33-022/P33-023: assisted tagging suggestions. Suggestions are produced
/// from visual analysis only, carry a confidence and a human-readable reason,
/// and are never part of the document's reading order until a reviewer accepts
/// them: a pending suggestion exists only in the review model, while the
/// structure inventory always reflects confirmed structure.
public struct TaggingSuggestion: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case heading(level: Int)
    case paragraph
    case figure(altText: String?)
    case artifact(headerFooter: Bool)
  }

  /// P33-023: every suggestion is a visual-order guess; the review state is
  /// the only thing that turns it into confirmed structure.
  public enum Origin: Sendable, Equatable {
    case visualOrderGuess
  }

  public let id: UUID
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let kind: Kind
  /// Text runs (indices into the page's run list) in visual order.
  public let runIndices: [Int]
  /// Image XObject resource names for figures.
  public let imageNames: [String]
  public let bounds: [Double]
  public let confidence: Double
  public let reason: String
  public let snippet: String
  public let origin: Origin

  public init(
    id: UUID = UUID(), pageIndex: Int, pageID: PDFObjectID, kind: Kind, runIndices: [Int],
    imageNames: [String] = [], bounds: [Double], confidence: Double, reason: String,
    snippet: String, origin: Origin = .visualOrderGuess
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.kind = kind
    self.runIndices = runIndices
    self.imageNames = imageNames
    self.bounds = bounds
    self.confidence = confidence
    self.reason = reason
    self.snippet = snippet
    self.origin = origin
  }

  /// The role an accepted suggestion would assign.
  public var proposedRole: String {
    switch kind {
    case .heading(let level): return "H\(min(max(level, 1), 6))"
    case .paragraph: return "P"
    case .figure: return "Figure"
    case .artifact: return "Artifact"
    }
  }

  public var label: String {
    switch kind {
    case .heading(let level): return "Heading \(level)"
    case .paragraph: return "Paragraph"
    case .figure: return "Figure"
    case .artifact(let headerFooter): return headerFooter ? "Artifact (header/footer)" : "Artifact"
    }
  }
}

/// P33-022: review state. Nothing is applied until the reviewer accepts.
public struct TaggingReview: Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case pending
    case accepted
    case rejected
  }

  public private(set) var suggestions: [TaggingSuggestion]
  public private(set) var statuses: [UUID: Status]

  public init(suggestions: [TaggingSuggestion]) {
    self.suggestions = suggestions
    self.statuses = [:]
  }

  public func status(of id: UUID) -> Status { statuses[id] ?? .pending }

  public mutating func accept(_ id: UUID) { statuses[id] = .accepted }

  /// Drop suggestions after they have been applied to the document.
  public mutating func remove(_ ids: Set<UUID>) {
    suggestions.removeAll { ids.contains($0.id) }
    for id in ids { statuses.removeValue(forKey: id) }
  }
  public mutating func reject(_ id: UUID) { statuses[id] = .rejected }
  public mutating func acceptAllPending() {
    for suggestion in suggestions where status(of: suggestion.id) == .pending {
      statuses[suggestion.id] = .accepted
    }
  }

  public var pending: [TaggingSuggestion] {
    suggestions.filter { status(of: $0.id) == .pending }
  }
  public var accepted: [TaggingSuggestion] {
    suggestions.filter { status(of: $0.id) == .accepted }
  }
  public var rejected: [TaggingSuggestion] {
    suggestions.filter { status(of: $0.id) == .rejected }
  }

  /// The acceptance command for an accepted suggestion. Figures need
  /// reviewer-supplied alternate text, so nil means "not ready to apply".
  public static func command(
    for suggestion: TaggingSuggestion, altText: String? = nil
  ) -> ApplyTaggingSuggestionCommand? {
    switch suggestion.kind {
    case .heading(let level):
      return ApplyTaggingSuggestionCommand(
        pageID: suggestion.pageID, role: PDFName("H\(min(max(level, 1), 6))"),
        altText: nil, content: .text(runIndices: suggestion.runIndices))
    case .paragraph:
      return ApplyTaggingSuggestionCommand(
        pageID: suggestion.pageID, role: PDFName("P"), altText: nil,
        content: .text(runIndices: suggestion.runIndices))
    case .figure(let proposed):
      let text = altText ?? proposed
      guard let text, !text.isEmpty else { return nil }
      return ApplyTaggingSuggestionCommand(
        pageID: suggestion.pageID, role: PDFName("Figure"), altText: text,
        content: .image(name: suggestion.imageNames.first ?? ""))
    case .artifact(let headerFooter):
      return ApplyTaggingSuggestionCommand(
        pageID: suggestion.pageID, role: PDFName("Artifact"), altText: nil,
        content: .artifact(runIndices: suggestion.runIndices, headerFooter: headerFooter))
    }
  }
}

/// P33-022: bounded visual analysis producing reviewable suggestions.
public enum StructureTaggingAssistant {
  public struct Limits: Sendable {
    public var maxPages: Int
    public var maxSuggestionsPerPage: Int
    public var maxBlocksPerPage: Int

    public init(maxPages: Int = 64, maxSuggestionsPerPage: Int = 200, maxBlocksPerPage: Int = 500) {
      self.maxPages = maxPages
      self.maxSuggestionsPerPage = maxSuggestionsPerPage
      self.maxBlocksPerPage = maxBlocksPerPage
    }
  }

  /// Analyze pages (page index = position in the array) and return
  /// suggestions in visual order. Content that already carries marked content
  /// with an MCID is never suggested again.
  public static func analyze(
    pageIDs: [PDFObjectID], in graph: PDFGraph, limits: Limits = Limits()
  ) throws -> [TaggingSuggestion] {
    var suggestions: [TaggingSuggestion] = []
    var bandBlocks: [BandKey: [BandOccurrence]] = [:]

    for (pageIndex, pageID) in pageIDs.prefix(limits.maxPages).enumerated() {
      try Task.checkCancellation()
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      let pageBounds = bounds(of: page)
      let height = max(1, pageBounds[3] - pageBounds[1])
      let topBand = pageBounds[3] - 0.08 * height
      let bottomBand = pageBounds[1] + 0.08 * height

      let content = try PageContent.load(pageID: pageID, in: graph)
      let taggedRanges = markedRanges(in: content)
      let layout = try PageTextLayout.build(pageID: pageID, in: graph)
      let runs = try TextRunIndexer.runs(in: content, graph: graph)
      let bodySize = bodyFontSize(of: layout)

      var pageSuggestions: [TaggingSuggestion] = []
      let blocks = textBlocks(of: layout, maxBlocks: limits.maxBlocksPerPage)
      for block in blocks {
        try Task.checkCancellation()
        if block.runIndices.contains(where: { runIndex in
          guard runIndex < runs.count else { return false }
          return isTagged(instruction: runs[runIndex].instructionIndex, in: taggedRanges)
        }) { continue }
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let centerY = (block.bounds[1] + block.bounds[3]) / 2
        if centerY > topBand || centerY < bottomBand {
          let key = BandKey(
            band: centerY > topBand ? "top" : "bottom",
            x: (block.bounds[0] / 4).rounded(), text: text)
          bandBlocks[key, default: []].append(
            BandOccurrence(pageIndex: pageIndex, pageID: pageID, block: block, text: text))
          continue
        }
        if block.lineCount == 1, block.maxFontSize >= max(14, bodySize * 1.2),
          text.count <= 120
        {
          let ratio = block.maxFontSize / max(bodySize, 1)
          let level = ratio >= 1.8 ? 1 : (ratio >= 1.5 ? 2 : 3)
          pageSuggestions.append(
            TaggingSuggestion(
              pageIndex: pageIndex, pageID: pageID, kind: .heading(level: level),
              runIndices: block.runIndices, bounds: block.bounds,
              confidence: min(0.95, 0.5 + 0.25 * (ratio - 1.2)),
              reason:
                "single line at \(formatted(block.maxFontSize)) pt versus \(formatted(bodySize)) pt body text",
              snippet: text))
        } else {
          let bodyLike = block.maxFontSize <= bodySize * 1.2
          pageSuggestions.append(
            TaggingSuggestion(
              pageIndex: pageIndex, pageID: pageID, kind: .paragraph,
              runIndices: block.runIndices, bounds: block.bounds,
              confidence: bodyLike ? (block.lineCount > 1 ? 0.7 : 0.6) : 0.5,
              reason:
                "text block of \(block.lineCount) line\(block.lineCount == 1 ? "" : "s") at \(formatted(block.maxFontSize)) pt",
              snippet: text))
        }
      }

      // Figures: image XObjects not drawn inside marked content with an MCID.
      let placements = try imagePlacements(in: content, graph: graph)
      for placement in placements {
        try Task.checkCancellation()
        if isTagged(instruction: placement.instructionIndex, in: taggedRanges) { continue }
        pageSuggestions.append(
          TaggingSuggestion(
            pageIndex: pageIndex, pageID: pageID, kind: .figure(altText: nil),
            runIndices: [], imageNames: [placement.name], bounds: placement.bounds,
            confidence: 0.5, reason: "image without alternate text", snippet: placement.name))
      }

      suggestions.append(
        contentsOf: pageSuggestions.sorted { $0.bounds[3] > $1.bounds[3] }
          .prefix(limits.maxSuggestionsPerPage))
    }

    // Running headers/footers: identical text at the same position on two or
    // more pages is a strong artifact candidate.
    for (_, occurrences) in bandBlocks where occurrences.count >= 2 {
      for occurrence in occurrences {
        let suggestion = TaggingSuggestion(
          pageIndex: occurrence.pageIndex, pageID: occurrence.pageID,
          kind: .artifact(headerFooter: true), runIndices: occurrence.block.runIndices,
          bounds: occurrence.block.bounds,
          confidence: min(0.9, 0.5 + 0.1 * Double(min(occurrences.count, 4))),
          reason:
            "same text repeats on \(occurrences.count) pages at the same position (running header/footer)",
          snippet: occurrence.text)
        suggestions.append(suggestion)
      }
    }

    return suggestions.sorted {
      $0.pageIndex != $1.pageIndex ? $0.pageIndex < $1.pageIndex : $0.bounds[3] > $1.bounds[3]
    }
  }

  // MARK: - Internals

  struct TextBlock {
    let lineCount: Int
    let maxFontSize: Double
    let runIndices: [Int]
    let bounds: [Double]
    let text: String
  }

  private struct BandKey: Hashable {
    let band: String
    let x: Double
    let text: String
  }

  private struct BandOccurrence {
    let pageIndex: Int
    let pageID: PDFObjectID
    let block: TextBlock
    let text: String
  }

  private static func formatted(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }

  /// P33-023-adjacent: instruction index ranges that already carry marked
  /// content, with the MCID when one is present.
  struct MarkedRange {
    let instructions: Range<Int>
    let mcid: Int?
  }

  static func markedRanges(in content: PageContent) -> [MarkedRange] {
    var stack: [(start: Int, mcid: Int?)] = []
    var ranges: [MarkedRange] = []
    for (index, instruction) in content.instructions.enumerated() {
      switch instruction.operatorName {
      case "BDC", "BMC":
        var mcid: Int?
        if instruction.operatorName == "BDC", instruction.operands.count >= 2,
          case .dictionary(let dictionary) = instruction.operands[1].value,
          case .integer(let value)? = dictionary[PDFName("MCID")]
        {
          mcid = Int(value)
        }
        stack.append((index, mcid))
      case "EMC":
        if let top = stack.popLast() {
          ranges.append(MarkedRange(instructions: top.start..<(index + 1), mcid: top.mcid))
        }
      default:
        break
      }
    }
    return ranges
  }

  static func isTagged(instruction: Int, in ranges: [MarkedRange]) -> Bool {
    ranges.contains { $0.mcid != nil && $0.instructions.contains(instruction) }
  }

  static func bodyFontSize(of layout: PageTextLayout) -> Double {
    var counts: [Int: Int] = [:]
    for cluster in layout.clusters where !cluster.isWhitespace {
      let rounded = Int(cluster.fontSize.rounded())
      counts[rounded, default: 0] += 1
    }
    guard let best = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else {
      return 12
    }
    return Double(best.key)
  }

  static func textBlocks(of layout: PageTextLayout, maxBlocks: Int) -> [TextBlock] {
    struct Line {
      let baseline: Double
      let maxFontSize: Double
      let runIndices: [Int]
      let bounds: [Double]
      let text: String
    }
    var lines: [Line] = []
    for range in layout.lines {
      let all = range.map { layout.clusters[$0] }
      let clusters = all.filter { !$0.isWhitespace }
      guard !clusters.isEmpty else { continue }
      var bounds = [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                    -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude]
      var runIndices: [Int] = []
      var text = ""
      for cluster in all { text += cluster.text }
      for cluster in clusters {
        bounds[0] = min(bounds[0], cluster.bounds[0])
        bounds[1] = min(bounds[1], cluster.bounds[1])
        bounds[2] = max(bounds[2], cluster.bounds[2])
        bounds[3] = max(bounds[3], cluster.bounds[3])
        if runIndices.last != cluster.runIndex { runIndices.append(cluster.runIndex) }
      }
      lines.append(
        Line(
          baseline: clusters.map { $0.origin[1] }.reduce(0, +) / Double(clusters.count),
          maxFontSize: clusters.map(\.fontSize).max() ?? 12, runIndices: runIndices,
          bounds: bounds, text: text.trimmingCharacters(in: .whitespaces)))
    }
    lines.sort { $0.baseline > $1.baseline }

    var blocks: [TextBlock] = []
    var current: [Line] = []
    func flush() {
      guard let first = current.first else { return }
      var bounds = first.bounds
      var runIndices: [Int] = []
      var text = ""
      var maxFontSize = 0.0
      for line in current {
        bounds[0] = min(bounds[0], line.bounds[0])
        bounds[1] = min(bounds[1], line.bounds[1])
        bounds[2] = max(bounds[2], line.bounds[2])
        bounds[3] = max(bounds[3], line.bounds[3])
        for index in line.runIndices where !runIndices.contains(index) { runIndices.append(index) }
        text += text.isEmpty ? line.text : "\n" + line.text
        maxFontSize = max(maxFontSize, line.maxFontSize)
      }
      blocks.append(
        TextBlock(
          lineCount: current.count, maxFontSize: maxFontSize, runIndices: runIndices,
          bounds: bounds, text: text))
      current = []
    }
    for line in lines {
      if let previous = current.last {
        let gap = previous.baseline - line.baseline
        if gap > 1.6 * max(previous.maxFontSize, line.maxFontSize) {
          flush()
        }
      }
      current.append(line)
      if blocks.count >= maxBlocks {
        current = []
        break
      }
    }
    flush()
    return blocks
  }

  struct PlacedImage {
    let name: String
    let bounds: [Double]
    let instructionIndex: Int
  }

  static func imagePlacements(in content: PageContent, graph: PDFGraph) throws -> [PlacedImage] {
    guard case .dictionary(let page)? = graph.objects[content.pageID] else { return [] }
    var resources: [PDFName: PDFValue] = [:]
    if case .dictionary(let dictionary)? = page[PDFName("Resources")] {
      resources = dictionary
    } else if case .reference(let id)? = page[PDFName("Resources")],
      case .dictionary(let dictionary)? = graph.objects[id]
    {
      resources = dictionary
    }
    var xobjects: [PDFName: PDFValue] = [:]
    switch resources[PDFName("XObject")] {
    case .dictionary(let dictionary)?:
      xobjects = dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { xobjects = dictionary }
    default:
      break
    }

    var ctm: [Double] = [1, 0, 0, 1, 0, 0]
    var stack: [[Double]] = []
    var placements: [PlacedImage] = []
    for (index, instruction) in content.instructions.enumerated() {
      switch instruction.operatorName {
      case "q":
        stack.append(ctm)
      case "Q":
        if let restored = stack.popLast() { ctm = restored }
      case "cm":
        let values = instruction.operands.compactMap(number)
        if values.count == 6 { ctm = concatenate(values, ctm) }
      case "Do":
        guard let name = instruction.operands.first?.value,
          case .name(let resourceName) = name,
          let object = xobjects[resourceName]
        else { continue }
        var dictionary: [PDFName: PDFValue]?
        switch object {
        case .dictionary(let direct):
          dictionary = direct
        case .stream(let stream):
          dictionary = stream.dictionary
        case .reference(let id):
          switch graph.objects[id] {
          case .dictionary(let referenced)?: dictionary = referenced
          case .stream(let stream)?: dictionary = stream.dictionary
          default: break
          }
        default:
          break
        }
        guard dictionary?[PDFName("Subtype")] == .name(PDFName("Image")) else { continue }
        var corners: [[Double]] = []
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
          corners.append([
            ctm[0] * x + ctm[2] * y + ctm[4], ctm[1] * x + ctm[3] * y + ctm[5],
          ])
        }
        let xs = corners.map { $0[0] }
        let ys = corners.map { $0[1] }
        placements.append(
          PlacedImage(
            name: String(decoding: resourceName.bytes, as: UTF8.self),
            bounds: [xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0],
            instructionIndex: index))
      default:
        break
      }
    }
    return placements
  }

  static func number(_ operand: ContentOperand) -> Double? {
    switch operand.value {
    case .integer(let value): return Double(value)
    case .real(let value): return value
    default: return nil
    }
  }

  static func concatenate(_ m: [Double], _ ctm: [Double]) -> [Double] {
    [
      ctm[0] * m[0] + ctm[2] * m[1], ctm[1] * m[0] + ctm[3] * m[1],
      ctm[0] * m[2] + ctm[2] * m[3], ctm[1] * m[2] + ctm[3] * m[3],
      ctm[0] * m[4] + ctm[2] * m[5] + ctm[4], ctm[1] * m[4] + ctm[3] * m[5] + ctm[5],
    ]
  }

  static func bounds(of page: [PDFName: PDFValue]) -> [Double] {
    for key in ["CropBox", "MediaBox"] {
      if case .array(let values)? = page[PDFName(key)], values.count == 4 {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
    }
    return [0, 0, 612, 792]
  }
}

/// P33-022: acceptance of a reviewed suggestion. Text and figure acceptance
/// wraps the target instructions in marked content with a fresh MCID, adds
/// the ParentTree entry, and creates the structure element; artifact
/// acceptance only wraps the content (artifacts never enter the structure
/// tree). Visible content bytes inside the wrap are never rewritten.
public struct ApplyTaggingSuggestionCommand: PDFEditCommand, Equatable, Sendable {
  public enum Content: Equatable, Sendable {
    case text(runIndices: [Int])
    case image(name: String)
    case artifact(runIndices: [Int], headerFooter: Bool)
  }

  public let pageID: PDFObjectID
  public let role: PDFName
  public let altText: String?
  public let content: Content

  public init(pageID: PDFObjectID, role: PDFName, altText: String?, content: Content) {
    self.pageID = pageID
    self.role = role
    self.altText = altText
    self.content = content
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Apply Tagging Suggestion" }

  private var isArtifact: Bool {
    if case .artifact = content { return true }
    return false
  }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    let roleString = String(decoding: role.bytes, as: UTF8.self)
    if !isArtifact {
      guard PDFStructureInspector.standardRoles.contains(roleString), roleString != "Artifact" else {
        throw PDFError(.unsupported, "Only standard structure roles can be assigned")
      }
      if roleString == "Figure" {
        guard let altText, !altText.isEmpty else {
          throw PDFError(
            .malformed, "Figure suggestions need alternate text before they can be accepted")
        }
      }
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    _ = try target(in: content, graph: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let content = try PageContent.load(pageID: pageID, in: graph)
    let target = try target(in: content, graph: graph)

    var mcid: Int?
    var tagBytes: [UInt8]
    switch target.kind {
    case .text:
      let next = try nextMCID(in: graph, pageID: pageID)
      mcid = next
      tagBytes = Array(
        " /\(String(decoding: role.bytes, as: UTF8.self)) <</MCID \(next)>> BDC\n".utf8)
    case .image:
      let next = try nextMCID(in: graph, pageID: pageID)
      mcid = next
      tagBytes = Array(
        " /\(String(decoding: role.bytes, as: UTF8.self)) <</MCID \(next)>> BDC\n".utf8)
    case .artifact(_, let headerFooter):
      tagBytes = Array(
        (" /Artifact " + (headerFooter ? "<</Type /Pagination>>" : "<</Type /Layout>>") + " BDC\n")
          .utf8)
    }
    let emcBytes = Array("\nEMC ".utf8)
    graph = try content.replacing(
      ranges: [
        (target.start..<target.start, tagBytes), (target.end..<target.end, emcBytes),
      ], in: graph)

    guard let mcid else { return graph }
    try addStructure(
      elementFor: mcid, pageID: pageID, role: role, altText: altText, to: &graph)
    return graph
  }

  private struct Target {
    let start: Int
    let end: Int
    let kind: Content
  }

  private func target(in content: PageContent, graph: PDFGraph) throws -> Target {
    let instructions = content.instructions
    var first: Int?
    var last: Int?
    switch self.content {
    case .text(let runIndices), .artifact(let runIndices, _):
      let runs = try TextRunIndexer.runs(in: content, graph: graph)
      let wanted = Set(runIndices)
      // Expand each wanted run to its enclosing BT..ET text object: operands
      // must never be separated from their operator by the wrap.
      var starts: [Int] = []
      var ends: [Int] = []
      for (index, run) in runs.enumerated() where wanted.contains(index) {
        let instruction = run.instructionIndex
        guard instruction < instructions.count else { continue }
        var start = instruction
        while start > 0, instructions[start].operatorName != "BT" { start -= 1 }
        var end = instruction
        while end + 1 < instructions.count, instructions[end].operatorName != "ET" { end += 1 }
        guard instructions[start].operatorName == "BT", instructions[end].operatorName == "ET"
        else {
          throw PDFError(.malformed, "The suggested text is not inside a text object")
        }
        starts.append(start)
        ends.append(end)
      }
      first = starts.min()
      last = ends.max()
      guard let start = first, let end = last, start <= end else {
        throw PDFError(.malformed, "The suggested text is no longer present on the page")
      }
      let ranges = StructureTaggingAssistant.markedRanges(in: content)
      for instruction in start...end {
        if StructureTaggingAssistant.isTagged(instruction: instruction, in: ranges) {
          throw PDFError(.malformed, "The suggested content is already tagged")
        }
      }
      let startOffset = instructions[start].span.lowerBound
      let endOffset = instructions[end].span.upperBound
      guard let segmentIndex = content.segmentIndex(for: startOffset..<endOffset),
        content.segmentIndex(for: startOffset..<startOffset) == segmentIndex,
        content.segmentIndex(for: endOffset..<endOffset) == segmentIndex
      else {
        throw PDFError(.unsupported, "The suggestion spans multiple content streams")
      }
      guard content.segments[segmentIndex].isEditable else {
        throw PDFError(.unsupported, "This content stream uses unsupported filters for editing")
      }
      return Target(start: startOffset, end: endOffset, kind: self.content)
    case .image(let name):
      guard let index = instructions.firstIndex(where: { instruction in
        guard instruction.operatorName == "Do",
          case .name(let resource) = instruction.operands.first?.value
        else { return false }
        return String(decoding: resource.bytes, as: UTF8.self) == name
      }) else {
        throw PDFError(.malformed, "The suggested image is no longer present on the page")
      }
      let ranges = StructureTaggingAssistant.markedRanges(in: content)
      guard !StructureTaggingAssistant.isTagged(instruction: index, in: ranges) else {
        throw PDFError(.malformed, "The suggested content is already tagged")
      }
      let instruction = instructions[index]
      // Include the resource-name operand so the wrap never separates it from
      // the Do operator.
      let start = instruction.operands.first?.span.lowerBound ?? instruction.span.lowerBound
      let end = instruction.span.upperBound
      guard let segmentIndex = content.segmentIndex(for: start..<end),
        content.segmentIndex(for: start..<start) == segmentIndex,
        content.segmentIndex(for: end..<end) == segmentIndex
      else {
        throw PDFError(.unsupported, "The suggestion spans multiple content streams")
      }
      guard content.segments[segmentIndex].isEditable else {
        throw PDFError(.unsupported, "This content stream uses unsupported filters for editing")
      }
      return Target(start: start, end: end, kind: self.content)
    }
  }

  /// The next free MCID for the page, allocating a StructParents key and
  /// ParentTree entry list when the page has none.
  private func nextMCID(in graph: PDFGraph, pageID: PDFObjectID) throws -> Int {
    let (rootID, root) = try structureRoot(in: graph)
    let parentTree = try parentTreeEntry(in: root, rootID: rootID, graph: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    if case .integer(let key)? = page[PDFName("StructParents")] {
      if let array = parentTree.array(for: Int(key)) {
        return array.count
      }
      return 0
    }
    return 0
  }

  private func addStructure(
    elementFor mcid: Int, pageID: PDFObjectID, role: PDFName, altText: String?, to graph: inout
      PDFGraph
  ) throws {
    let (rootID, rootDictionary) = try structureRoot(in: graph)
    var root = rootDictionary
    if graph.objects[rootID] == nil {
      graph.objects[rootID] = .dictionary(root)
    }
    var parentTree = try parentTreeEntry(in: root, rootID: rootID, graph: graph)
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }

    // Ensure the page has a StructParents key and the ParentTree an array.
    var pageDictionary = page
    let key: Int
    if case .integer(let existing)? = pageDictionary[PDFName("StructParents")] {
      key = Int(existing)
      if parentTree.array(for: key) == nil {
        parentTree.setArray([], for: key)
      }
    } else {
      key = parentTree.nextKey
      parentTree.setArray([], for: key)
      pageDictionary[PDFName("StructParents")] = .integer(Int64(key))
      graph.objects[pageID] = .dictionary(pageDictionary)
    }

    let elementID = StructureEditSupport.nextObjectID(in: graph)
    var element: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(role),
      PDFName("P"): .reference(rootID),
      PDFName("Pg"): .reference(pageID),
      PDFName("K"): .integer(Int64(mcid)),
    ]
    if let altText { element[PDFName("Alt")] = .string(Data(altText.utf8)) }
    graph.objects[elementID] = .dictionary(element)

    var array = parentTree.array(for: key) ?? []
    if array.count <= mcid { array.append(contentsOf: Array(repeating: PDFValue.null, count: mcid + 1 - array.count)) }
    array[mcid] = .reference(elementID)
    parentTree.setArray(array, for: key)

    var kids: [PDFValue] = []
    if case .array(let existing)? = root[PDFName("K")] { kids = existing }
    kids.append(.reference(elementID))
    root[PDFName("K")] = .array(kids)
    root[PDFName("ParentTree")] = parentTree.value
    root[PDFName("ParentTreeNextKey")] = .integer(Int64(parentTree.nextKey))
    graph.objects[rootID] = .dictionary(root)

    // MarkInfo: the document now contains marked content.
    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("StructTreeRoot")] = .reference(rootID)
      if catalog[PDFName("MarkInfo")] == nil {
        catalog[PDFName("MarkInfo")] = .dictionary([PDFName("Marked"): .boolean(true)])
      }
      graph.objects[catalogID] = .dictionary(catalog)
    }
  }

  private func structureRoot(in graph: PDFGraph) throws -> (PDFObjectID, [PDFName: PDFValue]) {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    if case .reference(let rootID)? = catalog[PDFName("StructTreeRoot")],
      case .dictionary(let root)? = graph.objects[rootID]
    {
      return (rootID, root)
    }
    let rootID = StructureEditSupport.nextObjectID(in: graph)
    return (
      rootID,
      [
        PDFName("Type"): .name(PDFName("StructTreeRoot")),
        PDFName("K"): .array([]),
        PDFName("ParentTree"): .dictionary([PDFName("Nums"): .array([])]),
        PDFName("ParentTreeNextKey"): .integer(0),
      ]
    )
  }

  /// Read/modify helper over /ParentTree /Nums.
  private struct ParentTree {
    var nums: [Int: PDFValue] = [:]
    var nextKey: Int {
      max((nums.keys.max() ?? -1) + 1, 0)
    }
    func array(for key: Int) -> [PDFValue]? {
      guard case .array(let values)? = nums[key] else { return nil }
      return values
    }
    mutating func setArray(_ array: [PDFValue], for key: Int) {
      nums[key] = .array(array)
    }
    var value: PDFValue {
      .dictionary([
        PDFName("Nums"): .array(
          nums.keys.sorted().flatMap { key -> [PDFValue] in
            [.integer(Int64(key)), nums[key] ?? .null]
          })
      ])
    }
  }

  private func parentTreeEntry(
    in root: [PDFName: PDFValue], rootID: PDFObjectID, graph: PDFGraph
  ) throws -> ParentTree {
    var parentTree = ParentTree()
    guard case .dictionary(let dictionary)? = root[PDFName("ParentTree")] else {
      return parentTree
    }
    guard case .array(let numbers)? = dictionary[PDFName("Nums")] else { return parentTree }
    var index = 0
    while index + 1 < numbers.count {
      if case .integer(let key) = numbers[index] {
        parentTree.nums[Int(key)] = numbers[index + 1]
      }
      index += 2
    }
    return parentTree
  }
}
