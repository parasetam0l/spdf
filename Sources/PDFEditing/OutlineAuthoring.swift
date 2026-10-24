import Foundation
import PDFCore

/// PAG-09: add one top-level bookmark pointing at a page.
public struct AddBookmarkCommand: PDFEditCommand, Equatable, Sendable {
  public let title: String
  public let pageID: PDFObjectID

  public init(title: String, pageID: PDFObjectID) {
    self.title = title
    self.pageID = pageID
  }

  public var name: String { "Add Bookmark" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "A bookmark needs a title")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "The document catalog is missing")
    }
    let outlinesID: PDFObjectID
    var outlines: [PDFName: PDFValue]
    if case .reference(let id)? = catalog[PDFName("Outlines")],
      case .dictionary(let existing)? = graph.objects[id]
    {
      outlinesID = id
      outlines = existing
    } else {
      outlinesID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
      outlines = [PDFName("Type"): .name(PDFName("Outlines"))]
      catalog[PDFName("Outlines")] = .reference(outlinesID)
      graph.objects[catalogID] = .dictionary(catalog)
      graph.objects[outlinesID] = .dictionary(outlines)
    }
    var lastID: PDFObjectID?
    if case .reference(let firstID)? = outlines[PDFName("First")] {
      var cursor: PDFObjectID? = firstID
      var visited = Set<PDFObjectID>()
      while let id = cursor, visited.insert(id).inserted {
        lastID = id
        guard case .dictionary(let item)? = graph.objects[id],
          case .reference(let next)? = item[PDFName("Next")]
        else { break }
        cursor = next
      }
    }
    let newID = PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
    var item: [PDFName: PDFValue] = [
      PDFName("Title"): .string(AnnotationText.encode(title)),
      PDFName("Parent"): .reference(outlinesID),
      PDFName("Dest"): .array([
        .reference(pageID), .name(PDFName("XYZ")), .null, .null, .null,
      ]),
    ]
    if let lastID, case .dictionary(var last)? = graph.objects[lastID] {
      last[PDFName("Next")] = .reference(newID)
      item[PDFName("Prev")] = .reference(lastID)
      graph.objects[lastID] = .dictionary(last)
    } else {
      outlines[PDFName("First")] = .reference(newID)
    }
    outlines[PDFName("Last")] = .reference(newID)
    if case .integer(let count)? = outlines[PDFName("Count")] {
      outlines[PDFName("Count")] = .integer(count + 1)
    } else {
      outlines[PDFName("Count")] = .integer(1)
    }
    graph.objects[newID] = .dictionary(item)
    graph.objects[outlinesID] = .dictionary(outlines)
    graph.trailer[PDFName("Size")] = .integer(Int64(newID.number + 1))
    return graph
  }
}

/// PAG-09: edit a bookmark's title and page destination in place.
public struct EditBookmarkCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: PDFObjectID
  public let title: String
  public let pageID: PDFObjectID

  public init(objectID: PDFObjectID, title: String, pageID: PDFObjectID) {
    self.objectID = objectID
    self.title = title
    self.pageID = pageID
  }

  public var name: String { "Edit Bookmark" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary(let item)? = graph.objects[objectID],
      item[PDFName("Title")] != nil
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "A bookmark needs a title")
    }
    try AnnotationSupport.validatePage(pageID, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var item)? = graph.objects[objectID] else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    item[PDFName("Title")] = .string(AnnotationText.encode(title))
    item[PDFName("Dest")] = .array([
      .reference(pageID), .name(PDFName("XYZ")), .null, .null, .null,
    ])
    item[PDFName("A")] = nil
    graph.objects[objectID] = .dictionary(item)
    return graph
  }
}

/// PAG-09: remove one bookmark and its descendants. Sibling links are
/// repaired; other bookmarks are untouched.
public struct RemoveBookmarkCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: PDFObjectID

  public init(objectID: PDFObjectID) {
    self.objectID = objectID
  }

  public var name: String { "Remove Bookmark" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary(let item)? = graph.objects[objectID],
      item[PDFName("Title")] != nil
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    guard let parent = parentID(of: item, in: graph) else {
      throw PDFError(.malformed, "The bookmark has no parent")
    }
    _ = parent
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(let item)? = graph.objects[objectID],
      let parentID = parentID(of: item, in: graph),
      case .dictionary(var parent)? = graph.objects[parentID]
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    let previous: PDFObjectID?
    if case .reference(let id)? = item[PDFName("Prev")] { previous = id } else { previous = nil }
    let next: PDFObjectID?
    if case .reference(let id)? = item[PDFName("Next")] { next = id } else { next = nil }
    if let previous, case .dictionary(var dictionary)? = graph.objects[previous] {
      if let next { dictionary[PDFName("Next")] = .reference(next) } else {
        dictionary[PDFName("Next")] = nil
      }
      graph.objects[previous] = .dictionary(dictionary)
    } else if let next {
      parent[PDFName("First")] = .reference(next)
    } else {
      parent[PDFName("First")] = nil
    }
    if let next, case .dictionary(var dictionary)? = graph.objects[next] {
      if let previous { dictionary[PDFName("Prev")] = .reference(previous) } else {
        dictionary[PDFName("Prev")] = nil
      }
      graph.objects[next] = .dictionary(dictionary)
    } else if let previous {
      parent[PDFName("Last")] = .reference(previous)
    } else {
      parent[PDFName("Last")] = nil
    }
    if case .integer(let count)? = parent[PDFName("Count")], count > 0 {
      parent[PDFName("Count")] = .integer(count - 1)
    }
    graph.objects[parentID] = .dictionary(parent)
    removeSubtree(objectID, in: &graph)
    return graph
  }

  private func parentID(of item: [PDFName: PDFValue], in graph: PDFGraph) -> PDFObjectID? {
    if case .reference(let id)? = item[PDFName("Parent")] { return id }
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let outlinesID)? = catalog[PDFName("Outlines")]
    else { return nil }
    return outlinesID
  }

  private func removeSubtree(_ id: PDFObjectID, in graph: inout PDFGraph) {
    guard case .dictionary(let item)? = graph.objects[id] else { return }
    if case .reference(let child)? = item[PDFName("First")] {
      var cursor: PDFObjectID? = child
      var visited = Set<PDFObjectID>()
      while let current = cursor, visited.insert(current).inserted {
        let next: PDFObjectID?
        if case .dictionary(let dictionary)? = graph.objects[current],
          case .reference(let value)? = dictionary[PDFName("Next")]
        {
          next = value
        } else {
          next = nil
        }
        removeSubtree(current, in: &graph)
        cursor = next
      }
    }
    graph.objects[id] = nil
  }
}
