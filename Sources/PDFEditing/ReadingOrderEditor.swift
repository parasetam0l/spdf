import Foundation
import PDFCore

// A11Y-02: visual reading-order editing. The inventory connects structure tags to
// page-space overlay bounds (resolved through MCIDs, image placements and /OBJR
// annotation rectangles) and the reorder command changes only the structure tree
// order, never page paint. The qualification proves the two are independent and
// survive save/reopen.

public struct ReadingOrderItem: Sendable, Equatable {
  public let elementID: PDFObjectID
  public let pageIndex: Int
  public let role: String
  public let textSnippet: String
  /// Page-space union of the element's marked content/object geometry; nil when
  /// the element has no resolvable page geometry.
  public let bounds: [Double]?
  public let contentKind: String
  public let orderIndex: Int

  public init(
    elementID: PDFObjectID, pageIndex: Int, role: String, textSnippet: String,
    bounds: [Double]?, contentKind: String, orderIndex: Int
  ) {
    self.elementID = elementID
    self.pageIndex = pageIndex
    self.role = role
    self.textSnippet = textSnippet
    self.bounds = bounds
    self.contentKind = contentKind
    self.orderIndex = orderIndex
  }
}

public struct ReadingOrderPage: Sendable, Equatable {
  public let pageIndex: Int
  public let pageID: PDFObjectID
  public let items: [ReadingOrderItem]
  public let untaggedMCIDs: [Int]
  public let issues: [String]
  public init(
    pageIndex: Int, pageID: PDFObjectID, items: [ReadingOrderItem],
    untaggedMCIDs: [Int], issues: [String]
  ) {
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.items = items
    self.untaggedMCIDs = untaggedMCIDs
    self.issues = issues
  }
  public var orderDescription: String {
    items.map { $0.role + "[" + String($0.elementID.number) + "]" }.joined(separator: " -> ")
  }
}

public struct PDFReadingOrderInventory: Sendable, Equatable {
  public let pages: [ReadingOrderPage]
  public let summary: String
  public init(pages: [ReadingOrderPage], summary: String) {
    self.pages = pages
    self.summary = summary
  }
}

public enum ReadingOrderEditor {
  public static func inventory(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> PDFReadingOrderInventory {
    let structure = try PDFStructureInspector.inspect(in: graph, pageIDs: pageIDs, limits: limits)
    var pages: [ReadingOrderPage] = []
    for (pageIndex, pageID) in pageIDs.enumerated() {
      let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
      let ranges = StructureTaggingAssistant.markedRanges(in: content)
      let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
      let runs = try TextRunIndexer.runs(in: content, graph: graph, limits: limits)
      let images = (try? StructureTaggingAssistant.imagePlacements(
        in: content, graph: graph)) ?? []
      var rangeByMCID: [Int: Range<Int>] = [:]
      for range in ranges {
        if let mcid = range.mcid { rangeByMCID[mcid] = range.instructions }
      }
      func contentBounds(mcid: Int) -> [Double]? {
        guard let range = rangeByMCID[mcid] else { return nil }
        var rects: [[Double]] = []
        for (runIndex, run) in runs.enumerated() where range.contains(run.instructionIndex) {
          for cluster in layout.clusters where cluster.runIndex == runIndex {
            rects.append(cluster.bounds)
          }
        }
        for image in images where range.contains(image.instructionIndex) {
          rects.append(image.bounds)
        }
        return union(rects)
      }
      var mappedMCIDs: Set<Int> = []
      var items: [ReadingOrderItem] = []
      var issues: [String] = []
      for element in structure.elements {
        guard element.pageIndex == pageIndex, let elementID = element.objectID else { continue }
        var rects: [[Double]] = []
        var kinds: Set<String> = []
        for child in element.children {
          switch child {
          case .content(_, let mcid):
            mappedMCIDs.insert(mcid)
            if let bounds = contentBounds(mcid: mcid) {
              rects.append(bounds)
              kinds.insert("content")
            } else {
              kinds.insert("content")
            }
          case .objectReference(let annotationID, _):
            if let bounds = annotationBounds(annotationID: annotationID, in: graph) {
              rects.append(bounds)
            }
            kinds.insert("annotation")
          case .element, .unresolved:
            break
          }
        }
        guard !kinds.isEmpty else { continue }
        let snippet: String
        do {
          snippet = String(
            try PDFStructureText.text(
              of: element, pageIDs: pageIDs, in: graph
            ).prefix(60))
        } catch {
          snippet = ""
        }
        items.append(
          ReadingOrderItem(
            elementID: elementID, pageIndex: pageIndex, role: element.role,
            textSnippet: snippet, bounds: union(rects),
            contentKind: kinds.sorted().joined(separator: "+"),
            orderIndex: items.count))
      }
      let untagged = structure.pageMCIDs.indices.contains(pageIndex)
        ? structure.pageMCIDs[pageIndex].filter { !mappedMCIDs.contains($0) }
        : []
      if !untagged.isEmpty {
        issues.append(
          String(untagged.count) + " marked-content item(s) on this page are not mapped to a tag")
      }
      if items.isEmpty {
        issues.append("No tagged page content was found on this page")
      }
      pages.append(
        ReadingOrderPage(
          pageIndex: pageIndex, pageID: pageID, items: items,
          untaggedMCIDs: untagged, issues: issues))
    }
    let tagged = pages.reduce(0) { $0 + $1.items.count }
    let summary = "Reading order: " + String(tagged) + " tagged item(s) across "
      + String(pages.count) + " page(s)."
    return PDFReadingOrderInventory(pages: pages, summary: summary)
  }

  static func annotationBounds(annotationID: PDFObjectID, in graph: PDFGraph) -> [Double]? {
    guard case .dictionary(let annotation)? = graph.objects[annotationID],
      case .array(let values)? = annotation[PDFName("Rect")]
    else { return nil }
    let numbers = values.compactMap { value -> Double? in
      switch value {
      case .integer(let number): return Double(number)
      case .real(let number): return number
      default: return nil
      }
    }
    guard numbers.count == 4 else { return nil }
    return [
      min(numbers[0], numbers[2]), min(numbers[1], numbers[3]),
      max(numbers[0], numbers[2]), max(numbers[1], numbers[3]),
    ]
  }

  static func union(_ rects: [[Double]]) -> [Double]? {
    let valid = rects.filter { $0.count == 4 }
    guard !valid.isEmpty else { return nil }
    var minX = valid[0][0]
    var minY = valid[0][1]
    var maxX = valid[0][2]
    var maxY = valid[0][3]
    for rect in valid.dropFirst() {
      minX = min(minX, rect[0])
      minY = min(minY, rect[1])
      maxX = max(maxX, rect[2])
      maxY = max(maxY, rect[3])
    }
    return [minX, minY, maxX, maxY]
  }

  /// Page paint bytes; used to prove reading-order edits do not move paint.
  public static func pagePaintBytes(pageID: PDFObjectID, in graph: PDFGraph) throws -> Data {
    let content = try PageContent.load(pageID: pageID, in: graph)
    var data = Data()
    for segment in content.segments { data.append(contentsOf: segment.decoded) }
    return data
  }
}

/// A11Y-02: reorder the tagged elements of one page without touching any other
/// structure child and without rewriting page content. Every listed element must
/// already be tagged to the same page under the same parent; their existing
/// parent slots are filled in the requested order, so non-page children keep
/// their positions.
public struct ReorderPageReadingOrderCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let orderedElementIDs: [PDFObjectID]
  public init(pageID: PDFObjectID, orderedElementIDs: [PDFObjectID]) {
    self.pageID = pageID
    self.orderedElementIDs = orderedElementIDs
  }
  public var name: String { "Reorder Page Reading Order" }

  public func validate(in graph: PDFGraph) throws {
    guard orderedElementIDs.count >= 2 else {
      throw PDFError(.malformed, "Reading-order editing needs at least two elements")
    }
    guard Set(orderedElementIDs).count == orderedElementIDs.count else {
      throw PDFError(.malformed, "The reading order lists an element twice")
    }
    guard case .dictionary = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    var parentID: PDFObjectID?
    for elementID in orderedElementIDs {
      let element = try StructureEditSupport.element(elementID, in: graph)
      guard case .reference(let elementParent)? = element[PDFName("P")] else {
        throw PDFError(.malformed, "A listed element has no parent")
      }
      if let parentID, parentID != elementParent {
        throw PDFError(.malformed, "The listed elements do not share one parent")
      }
      parentID = elementParent
      let kids = try StructureParentTreeSupport.childReferences(of: elementParent, in: graph)
      guard kids.contains(where: { value in
        if case .reference(let id) = value { return id == elementID }
        return false
      }) else {
        throw PDFError(.malformed, "A listed element is not a child of its parent")
      }
      if case .reference(let elementPage)? = element[PDFName("Pg")], elementPage != pageID {
        throw PDFError(.malformed, "A listed element is tagged to another page")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let first = try StructureEditSupport.element(orderedElementIDs[0], in: graph)
    guard case .reference(let parentID)? = first[PDFName("P")] else {
      throw PDFError(.malformed, "The element has no parent")
    }
    var kids = try StructureParentTreeSupport.childReferences(of: parentID, in: graph)
    let listed = Set(orderedElementIDs)
    var slots: [Int] = []
    for (index, value) in kids.enumerated() {
      if case .reference(let id) = value, listed.contains(id) { slots.append(index) }
    }
    guard slots.count == orderedElementIDs.count else {
      throw PDFError(.malformed, "The listed elements are not all children of the parent")
    }
    for (slot, elementID) in zip(slots, orderedElementIDs) {
      kids[slot] = .reference(elementID)
    }
    try StructureParentTreeSupport.writeChildren(kids, parentID: parentID, in: &graph)
    return graph
  }
}

public struct ReadingOrderQualificationReport: Sendable, Equatable {
  public let pageIndex: Int
  public let orderBefore: String
  public let orderAfter: String
  public let paintBytesUnchanged: Bool
  public let boundsUnchanged: Bool
  public let orderChanged: Bool
  public let saveReopenPreserved: Bool
  public let issuesAfterSave: [String]
  public let findings: [String]
  public init(
    pageIndex: Int, orderBefore: String, orderAfter: String, paintBytesUnchanged: Bool,
    boundsUnchanged: Bool, orderChanged: Bool, saveReopenPreserved: Bool,
    issuesAfterSave: [String], findings: [String]
  ) {
    self.pageIndex = pageIndex
    self.orderBefore = orderBefore
    self.orderAfter = orderAfter
    self.paintBytesUnchanged = paintBytesUnchanged
    self.boundsUnchanged = boundsUnchanged
    self.orderChanged = orderChanged
    self.saveReopenPreserved = saveReopenPreserved
    self.issuesAfterSave = issuesAfterSave
    self.findings = findings
  }
  public var passed: Bool {
    paintBytesUnchanged && boundsUnchanged && orderChanged && saveReopenPreserved
      && issuesAfterSave.isEmpty
  }
  public var summary: String {
    passed
      ? "Reading order is independently editable: paint and overlay bounds are unchanged and the order survives save/reopen."
      : "Reading-order qualification failed: " + findings.joined(separator: "; ")
  }
}

extension ReadingOrderEditor {
  /// A11Y-02 qualification: invert the first page with at least two tagged
  /// items, then prove that page paint and overlay bounds are unchanged, the
  /// structure order really changed, and save/reopen preserves it with no issues.
  public static func qualify(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> ReadingOrderQualificationReport {
    let inventory = try ReadingOrderEditor.inventory(in: graph, pageIDs: pageIDs, limits: limits)
    guard let page = inventory.pages.first(where: { $0.items.count >= 2 }),
      let pageID = pageIDs.indices.contains(page.pageIndex) ? pageIDs[page.pageIndex] : nil
    else {
      throw PDFError(.unsupported, "No page has at least two tagged reading-order items")
    }
    var findings: [String] = []
    let orderBefore = page.orderDescription
    let boundsBefore = Dictionary(
      uniqueKeysWithValues: page.items.map { ($0.elementID, $0.bounds) })
    let paintBefore = try ReadingOrderEditor.pagePaintBytes(pageID: pageID, in: graph)
    let reversed = Array(page.items.map(\.elementID).reversed())
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        ReorderPageReadingOrderCommand(pageID: pageID, orderedElementIDs: reversed)
      ]), to: graph, limits: limits)
    let afterInventory = try ReadingOrderEditor.inventory(
      in: edited, pageIDs: pageIDs, limits: limits)
    guard let afterPage = afterInventory.pages.first(where: { $0.pageIndex == page.pageIndex })
    else {
      throw PDFError(.malformed, "The edited page disappeared from the inventory")
    }
    let orderAfter = afterPage.orderDescription
    let orderChanged = orderAfter != orderBefore
    if !orderChanged { findings.append("the structure order did not change") }
    let paintAfter = try ReadingOrderEditor.pagePaintBytes(pageID: pageID, in: edited)
    let paintBytesUnchanged = paintAfter == paintBefore
    if !paintBytesUnchanged { findings.append("page paint bytes changed") }
    var boundsUnchanged = true
    let boundsAfter = Dictionary(
      uniqueKeysWithValues: afterPage.items.map { ($0.elementID, $0.bounds) })
    for (elementID, bounds) in boundsBefore {
      if boundsAfter[elementID] != bounds {
        boundsUnchanged = false
        findings.append("overlay bounds of element " + String(elementID.number) + " changed")
      }
    }
    let reopened: ParsedPDF
    do {
      let data = try PDFWriter.serialize(edited, limits: limits)
      reopened = try PDFParser.parse(data, limits: limits)
    } catch {
      findings.append("the edited document does not save/reopen: " + error.localizedDescription)
      return ReadingOrderQualificationReport(
        pageIndex: page.pageIndex, orderBefore: orderBefore, orderAfter: orderAfter,
        paintBytesUnchanged: paintBytesUnchanged, boundsUnchanged: boundsUnchanged,
        orderChanged: orderChanged, saveReopenPreserved: false, issuesAfterSave: [],
        findings: findings)
    }
    let reopenedInventory = try PDFStructureInspector.inspect(
      in: reopened.graph, pageIDs: reopened.pageIDs, limits: limits)
    let issuesAfterSave = reopenedInventory.issues.map(\.message)
    let reopenedOrder = try ReadingOrderEditor.inventory(
      in: reopened.graph, pageIDs: reopened.pageIDs, limits: limits
    ).pages.first { $0.pageIndex == page.pageIndex }?.orderDescription
    let saveReopenPreserved = reopenedOrder == orderAfter
    if !saveReopenPreserved { findings.append("save/reopen did not preserve the order") }
    if !issuesAfterSave.isEmpty { findings.append("save/reopen reports structure issues") }
    return ReadingOrderQualificationReport(
      pageIndex: page.pageIndex, orderBefore: orderBefore, orderAfter: orderAfter,
      paintBytesUnchanged: paintBytesUnchanged, boundsUnchanged: boundsUnchanged,
      orderChanged: orderChanged, saveReopenPreserved: saveReopenPreserved,
      issuesAfterSave: issuesAfterSave, findings: findings)
  }
}

