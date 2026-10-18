import Foundation
import PDFCore

/// P23-001: move one page to a new position in the flattened page order.
/// The surrounding tree shape stays intact (no flattening), page identity is
/// stable, and every interior Count is recomputed.
public struct ReorderPagesCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let toIndex: Int

  public init(pageID: PDFObjectID, toIndex: Int) {
    self.pageID = pageID
    self.toIndex = toIndex
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Move Page" }

  public func validate(in graph: PDFGraph) throws {
    let view = try PageTreeView(graph: graph)
    guard view.pages.contains(pageID) else {
      throw PDFError(.malformed, "Reorder target is not a page")
    }
    // toIndex addresses the final order among the remaining pages, so the
    // valid range is 0...pages.count - 1.
    guard toIndex >= 0, toIndex <= max(0, view.pages.count - 1) else {
      throw PDFError(.malformed, "Page destination is outside the document")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var editor = try PageTreeEditor(graph: graph)
    let view = editor.view
    guard let oldParent = view.parents[pageID], let oldIndex = view.indices[pageID] else {
      throw PDFError(.malformed, "Reorder target is not a page")
    }
    var kids = view.kids
    guard var oldChildren = kids[oldParent], oldIndex < oldChildren.count else {
      throw PDFError(.malformed, "Page-tree index is inconsistent")
    }
    oldChildren.remove(at: oldIndex)
    kids[oldParent] = oldChildren

    let remaining = view.pages.filter { $0 != pageID }
    let targetParent: PDFObjectID
    var targetIndex: Int
    if remaining.isEmpty {
      targetParent = view.rootID
      targetIndex = kids[targetParent]?.count ?? 0
    } else if toIndex == 0 {
      let anchor = remaining[0]
      targetParent = view.parents[anchor]!
      var anchorIndex = view.indices[anchor]!
      if targetParent == oldParent, oldIndex < anchorIndex { anchorIndex -= 1 }
      targetIndex = anchorIndex
    } else {
      let anchor = remaining[min(toIndex, remaining.count) - 1]
      targetParent = view.parents[anchor]!
      var anchorIndex = view.indices[anchor]!
      if targetParent == oldParent, oldIndex < anchorIndex { anchorIndex -= 1 }
      targetIndex = anchorIndex + 1
    }
    var targetChildren = kids[targetParent] ?? []
    targetChildren.insert(pageID, at: min(targetIndex, targetChildren.count))
    kids[targetParent] = targetChildren

    for (node, children) in kids { try editor.setKids(node, children) }
    try editor.refreshCounts()
    return editor.graph
  }
}

/// P23-002: delete pages after a preflight that refuses documents where a
/// deleted page is referenced outside the page tree (destinations, outlines,
/// annotations, catalog entries), so no dangling reference can be produced.
/// The page objects themselves stay in the graph under the retention policy.
public struct DeletePagesCommand: PDFEditCommand, Equatable, Sendable {
  public let pageIDs: [PDFObjectID]

  public init(pageIDs: [PDFObjectID]) {
    self.pageIDs = pageIDs
  }

  /// P17-012: the pages this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }
  public var name: String { "Delete Page" }

  public func validate(in graph: PDFGraph) throws {
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "Deletion requires at least one page")
    }
    var seen: Set<PDFObjectID> = []
    for id in pageIDs {
      guard seen.insert(id).inserted else {
        throw PDFError(.malformed, "Deletion lists the same page twice")
      }
    }
    let view = try PageTreeView(graph: graph)
    let targets = Set(pageIDs)
    for id in pageIDs {
      guard view.pages.contains(id) else {
        throw PDFError(.malformed, "Deletion target is not a page")
      }
    }
    guard view.pages.count > targets.count else {
      throw PDFError(.unsupported, "A document must keep at least one page")
    }
    // Preflight: every reference to a deleted page must be a page-tree Kids
    // edge; anything else would dangle after deletion.
    func scan(_ value: PDFValue, depth: Int) throws {
      guard depth <= 64 else { throw PDFError(.limitExceeded, "Reference scan is too deep") }
      switch value {
      case .reference(let id):
        if targets.contains(id) {
          throw PDFError(
            .unsupported, "A deleted page is still referenced elsewhere in the document")
        }
      case .array(let values):
        for value in values { try scan(value, depth: depth + 1) }
      case .dictionary(let dictionary):
        for value in dictionary.values { try scan(value, depth: depth + 1) }
      case .stream(let stream):
        try scan(.dictionary(stream.dictionary), depth: depth + 1)
      default:
        break
      }
    }
    for (id, value) in graph.objects {
      if case .dictionary(let dictionary) = value,
        dictionary[PDFName("Type")] == .name(PDFName("Pages"))
      {
        // Kids edges are the ones deletion rewrites; scan every other key.
        for (key, entry) in dictionary where key != PDFName("Kids") {
          try scan(entry, depth: 0)
        }
      } else {
        try scan(value, depth: 0)
      }
    }
    try scan(.dictionary(graph.trailer), depth: 0)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var editor = try PageTreeEditor(graph: graph)
    let view = editor.view
    let targets = Set(pageIDs)
    var kids = view.kids
    for (node, children) in kids {
      kids[node] = children.filter { !targets.contains($0) }
    }
    for (node, children) in kids { try editor.setKids(node, children) }
    try editor.refreshCounts()
    return editor.graph
  }
}

/// P23-004: insert a blank page with an explicit MediaBox at a flattened
/// index. The new object identity is allocated above every existing number,
/// so insertion can never collide with an existing object (P09-008).
public struct InsertBlankPageCommand: PDFEditCommand, Equatable, Sendable {
  public let atIndex: Int
  public let width: Int64
  public let height: Int64

  public init(atIndex: Int, width: Int64, height: Int64) {
    self.atIndex = atIndex
    self.width = width
    self.height = height
  }

  public var name: String { "Insert Blank Page" }

  public func validate(in graph: PDFGraph) throws {
    guard width > 0, height > 0, width <= 200_000, height <= 200_000 else {
      throw PDFError(.malformed, "Blank page size is invalid")
    }
    let view = try PageTreeView(graph: graph)
    guard atIndex >= 0, atIndex <= view.pages.count else {
      throw PDFError(.malformed, "Blank page index is outside the document")
    }
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    guard next > 0, next <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for a new page object")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var editor = try PageTreeEditor(graph: graph)
    let view = editor.view
    let newID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    var kids = view.kids
    let parent: PDFObjectID
    let index: Int
    if view.pages.isEmpty {
      parent = view.rootID
      index = 0
    } else if atIndex == 0 {
      parent = view.parents[view.pages[0]]!
      index = view.indices[view.pages[0]]!
    } else {
      let anchor = view.pages[atIndex - 1]
      parent = view.parents[anchor]!
      index = view.indices[anchor]! + 1
    }
    var children = kids[parent] ?? []
    children.insert(newID, at: min(index, children.count))
    kids[parent] = children
    for (node, nodes) in kids { try editor.setKids(node, nodes) }
    editor.graph.objects[newID] = .dictionary([
      PDFName("Type"): .name(PDFName("Page")),
      PDFName("Parent"): .reference(parent),
      PDFName("Resources"): .dictionary([:]),
      PDFName("MediaBox"): .array([
        .integer(0), .integer(0), .integer(width), .integer(height),
      ]),
    ])
    // Keep the declared object-count consistent so graph verification and
    // the writer agree on the serialized trailer.
    editor.graph.trailer[PDFName("Size")] = .integer(Int64(newID.number) + 1)
    try editor.refreshCounts()
    return editor.graph
  }
}
