import Foundation
import PDFCore

/// A11Y-03: acceptance of a reviewed list suggestion. A list cannot be one flat
/// structure element, so this command builds an L element with one LI child per
/// item and wraps each item's show operation in its own marked-content
/// sequence. Review is required: the command only runs for an accepted
/// suggestion.
public struct ApplyAccessibleListSuggestionCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  /// Run indices per list item, in reading order.
  public let itemRunIndices: [[Int]]

  public init(pageID: PDFObjectID, itemRunIndices: [[Int]]) {
    self.pageID = pageID
    self.itemRunIndices = itemRunIndices
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Apply List Tagging Suggestion" }
  public static let maxItems = 500

  struct ItemSpan {
    let start: Int
    let end: Int
    let runs: [Int]
  }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard !itemRunIndices.isEmpty else {
      throw PDFError(.malformed, "A list needs at least one item")
    }
    guard itemRunIndices.count <= Self.maxItems else {
      throw PDFError(.limitExceeded, "A list suggestion has too many items")
    }
    let flattened = itemRunIndices.flatMap { $0 }
    guard !flattened.isEmpty, Set(flattened).count == flattened.count else {
      throw PDFError(.malformed, "List items must reference distinct text runs")
    }
    _ = try itemSpans(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let content = try PageContent.load(pageID: pageID, in: graph)
    let spans = try itemSpans(in: graph)

    var nextObjectNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let rootState = try structureRoot(
      in: &graph, nextObjectNumber: &nextObjectNumber)
    let rootID = rootState.rootID
    var root = rootState.root
    var nums = parentTreeNumbers(in: root)

    guard case .dictionary(let pageDictionary)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    let structParentsKey: Int
    if case .integer(let existing)? = pageDictionary[PDFName("StructParents")] {
      structParentsKey = Int(existing)
    } else {
      structParentsKey = max((nums.keys.max() ?? -1) + 1, 0)
    }
    var entries: [PDFValue]
    if case .array(let existing)? = nums[structParentsKey] {
      entries = existing
    } else {
      entries = []
    }
    let baseMCID = entries.count
    if entries.count < baseMCID + spans.count {
      entries.append(
        contentsOf: Array(repeating: PDFValue.null, count: baseMCID + spans.count - entries.count))
    }

    let listID = PDFObjectID(nextObjectNumber)
    nextObjectNumber += 1
    var itemRefs: [PDFValue] = []
    var insertions: [(range: Range<Int>, replacement: [UInt8])] = []
    for (index, span) in spans.enumerated() {
      let mcid = baseMCID + index
      let itemID = PDFObjectID(nextObjectNumber)
      nextObjectNumber += 1
      let item: [PDFName: PDFValue] = [
        PDFName("Type"): .name(PDFName("StructElem")),
        PDFName("S"): .name(PDFName("LI")),
        PDFName("P"): .reference(listID),
        PDFName("Pg"): .reference(pageID),
        PDFName("K"): .integer(Int64(mcid)),
      ]
      graph.objects[itemID] = .dictionary(item)
      entries[mcid] = .reference(itemID)
      itemRefs.append(.reference(itemID))
      insertions.append(
        (
          range: span.start..<span.start,
          replacement: Array(" /LI <</MCID \(mcid)>> BDC\n".utf8)
        ))
      insertions.append((range: span.end..<span.end, replacement: Array("\nEMC ".utf8)))
      _ = span.runs
    }
    nums[structParentsKey] = .array(entries)

    let list: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(PDFName("L")),
      PDFName("P"): .reference(rootID),
      PDFName("Pg"): .reference(pageID),
      PDFName("K"): .array(itemRefs),
    ]
    graph.objects[listID] = .dictionary(list)

    var kids: [PDFValue] = []
    if case .array(let existing)? = root[PDFName("K")] { kids = existing }
    kids.append(.reference(listID))
    root[PDFName("K")] = .array(kids)
    root[PDFName("ParentTree")] = parentTreeValue(nums)
    root[PDFName("ParentTreeNextKey")] = .integer(Int64(max((nums.keys.max() ?? -1) + 1, 0)))
    graph.objects[rootID] = .dictionary(root)

    if case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    {
      catalog[PDFName("StructTreeRoot")] = .reference(rootID)
      if catalog[PDFName("MarkInfo")] == nil {
        catalog[PDFName("MarkInfo")] = .dictionary([PDFName("Marked"): .boolean(true)])
      }
      graph.objects[catalogID] = .dictionary(catalog)
    }

    if pageDictionary[PDFName("StructParents")] == nil {
      var page = pageDictionary
      page[PDFName("StructParents")] = .integer(Int64(structParentsKey))
      graph.objects[pageID] = .dictionary(page)
    }

    return try content.replacing(ranges: insertions, in: graph)
  }

  // MARK: - Target resolution

  func itemSpans(in graph: PDFGraph) throws -> [ItemSpan] {
    let content = try PageContent.load(pageID: pageID, in: graph)
    let runs = try TextRunIndexer.runs(in: content, graph: graph)
    let ranges = StructureTaggingAssistant.markedRanges(in: content)
    var spans: [ItemSpan] = []
    for item in itemRunIndices {
      var starts: [Int] = []
      var ends: [Int] = []
      for runIndex in item {
        guard runIndex >= 0, runIndex < runs.count else {
          throw PDFError(.malformed, "A list item references a missing text run")
        }
        let run = runs[runIndex]
        let instruction = run.instructionIndex
        guard instruction < content.instructions.count else {
          throw PDFError(.malformed, "A list item references a missing instruction")
        }
        let command = content.instructions[instruction]
        guard command.operatorName == "Tj" || command.operatorName == "TJ"
          || command.operatorName == "'" || command.operatorName == "\""
        else {
          throw PDFError(.unsupported, "A list item is not a text-show operation")
        }
        if StructureTaggingAssistant.isTagged(instruction: instruction, in: ranges) {
          throw PDFError(.malformed, "The suggested list content is already tagged")
        }
        let start = command.operands.first?.span.lowerBound ?? command.span.lowerBound
        starts.append(start)
        ends.append(command.span.upperBound)
      }
      guard let start = starts.min(), let end = ends.max(), start < end else {
        throw PDFError(.malformed, "A list item has no text to wrap")
      }
      guard let segmentIndex = content.segmentIndex(for: start..<end),
        content.segmentIndex(for: start..<start) == segmentIndex,
        content.segmentIndex(for: end..<end) == segmentIndex
      else {
        throw PDFError(.unsupported, "A list item spans multiple content streams")
      }
      guard content.segments[segmentIndex].isEditable else {
        throw PDFError(.unsupported, "This content stream uses unsupported filters")
      }
      spans.append(ItemSpan(start: start, end: end, runs: item))
    }
    let sorted = spans.sorted { $0.start < $1.start }
    for (previous, next) in zip(sorted, sorted.dropFirst()) {
      guard previous.end <= next.start else {
        throw PDFError(.malformed, "List items share one text-show operation and cannot be split")
      }
    }
    return spans
  }

  // MARK: - Structure root and parent tree

  struct RootState {
    let rootID: PDFObjectID
    let root: [PDFName: PDFValue]
  }

  func structureRoot(in graph: inout PDFGraph, nextObjectNumber: inout Int) throws -> RootState {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    if case .reference(let rootID)? = catalog[PDFName("StructTreeRoot")],
      case .dictionary(let root)? = graph.objects[rootID]
    {
      return RootState(rootID: rootID, root: root)
    }
    let rootID = PDFObjectID(nextObjectNumber)
    nextObjectNumber += 1
    let root: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructTreeRoot")),
      PDFName("K"): .array([]),
      PDFName("ParentTree"): .dictionary([PDFName("Nums"): .array([])]),
      PDFName("ParentTreeNextKey"): .integer(0),
    ]
    graph.objects[rootID] = .dictionary(root)
    return RootState(rootID: rootID, root: root)
  }

  func parentTreeNumbers(in root: [PDFName: PDFValue]) -> [Int: PDFValue] {
    var nums: [Int: PDFValue] = [:]
    guard case .dictionary(let dictionary)? = root[PDFName("ParentTree")],
      case .array(let numbers)? = dictionary[PDFName("Nums")]
    else { return nums }
    var index = 0
    while index + 1 < numbers.count {
      if case .integer(let key) = numbers[index] {
        nums[Int(key)] = numbers[index + 1]
      }
      index += 2
    }
    return nums
  }

  func parentTreeValue(_ nums: [Int: PDFValue]) -> PDFValue {
    .dictionary([
      PDFName("Nums"): .array(
        nums.keys.sorted().flatMap { key -> [PDFValue] in
          [.integer(Int64(key)), nums[key] ?? .null]
        })
    ])
  }
}
