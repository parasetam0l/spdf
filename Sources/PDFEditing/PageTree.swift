import Foundation
import PDFCore

/// Small public surface for page-tree queries used by sessions and UI code.
public enum PDFPageTree {
  /// Flattened document order using stable page identities.
  public static func pageIDs(in graph: PDFGraph) throws -> [PDFObjectID] {
    try PageTreeView(graph: graph).pages
  }
}

/// Read-only view of a page tree with parent/index links, used by structural
/// commands to rebuild only the arrays they must change.
struct PageTreeView {
  let catalogID: PDFObjectID
  let rootID: PDFObjectID
  let pages: [PDFObjectID]
  let parents: [PDFObjectID: PDFObjectID]
  let indices: [PDFObjectID: Int]
  let pagesNodes: Set<PDFObjectID>
  let kids: [PDFObjectID: [PDFObjectID]]

  init(graph: PDFGraph) throws {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let rootID)? = catalog[PDFName("Pages")]
    else { throw PDFError(.malformed, "Missing catalog or page-tree root") }
    var pages: [PDFObjectID] = []
    var parents: [PDFObjectID: PDFObjectID] = [:]
    var indices: [PDFObjectID: Int] = [:]
    var pagesNodes: Set<PDFObjectID> = []
    var kids: [PDFObjectID: [PDFObjectID]] = [:]
    var visited: Set<PDFObjectID> = []
    func walk(_ id: PDFObjectID, parent: PDFObjectID?, indexInParent: Int?) throws {
      guard visited.insert(id).inserted else {
        throw PDFError(.malformed, "Page tree contains a cycle or repeated node")
      }
      guard visited.count <= graph.objects.count else {
        throw PDFError(.limitExceeded, "Page tree exceeds the object count")
      }
      guard case .dictionary(let dictionary)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page-tree reference is not a dictionary")
      }
      if dictionary[PDFName("Type")] == .name(PDFName("Page")) {
        guard let parent, let indexInParent else {
          throw PDFError(.malformed, "Page leaf is the page-tree root")
        }
        parents[id] = parent
        indices[id] = indexInParent
        pages.append(id)
        return
      }
      guard dictionary[PDFName("Type")] == .name(PDFName("Pages")),
        case .array(let children)? = dictionary[PDFName("Kids")]
      else { throw PDFError(.malformed, "Invalid page-tree node") }
      pagesNodes.insert(id)
      var childIDs: [PDFObjectID] = []
      for (index, child) in children.enumerated() {
        guard case .reference(let childID) = child else {
          throw PDFError(.malformed, "Page-tree child is not an indirect reference")
        }
        childIDs.append(childID)
        try walk(childID, parent: id, indexInParent: index)
      }
      kids[id] = childIDs
    }
    try walk(rootID, parent: nil, indexInParent: nil)
    self.catalogID = catalogID
    self.rootID = rootID
    self.pages = pages
    self.parents = parents
    self.indices = indices
    self.pagesNodes = pagesNodes
    self.kids = kids
  }
}

/// Mutable page-tree surgery on top of a graph: writes Kids arrays back as
/// indirect references and recomputes every interior Count bottom-up.
struct PageTreeEditor {
  var graph: PDFGraph
  let view: PageTreeView

  init(graph: PDFGraph) throws {
    self.graph = graph
    view = try PageTreeView(graph: graph)
  }

  mutating func setKids(_ node: PDFObjectID, _ children: [PDFObjectID]) throws {
    guard case .dictionary(var dictionary)? = graph.objects[node] else {
      throw PDFError(.malformed, "Page-tree node is missing", offset: nil)
    }
    dictionary[PDFName("Kids")] = .array(children.map(PDFValue.reference))
    graph.objects[node] = .dictionary(dictionary)
  }

  mutating func refreshCounts() throws {
    let current = try PageTreeView(graph: graph)
    var counts: [PDFObjectID: Int] = [:]
    func count(_ id: PDFObjectID, depth: Int) throws -> Int {
      guard depth <= 64 else {
        throw PDFError(.limitExceeded, "Page tree is too deep")
      }
      guard let children = current.kids[id] else { return 1 }
      var total = 0
      for child in children { total += try count(child, depth: depth + 1) }
      counts[id] = total
      return total
    }
    _ = try count(current.rootID, depth: 0)
    for (id, value) in counts {
      guard case .dictionary(var dictionary)? = graph.objects[id] else { continue }
      dictionary[PDFName("Count")] = .integer(Int64(value))
      graph.objects[id] = .dictionary(dictionary)
    }
  }
}
