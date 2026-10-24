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

/// PAG-09: move one bookmark before or after its adjacent sibling.
public enum BookmarkMoveDirection: String, Sendable, Equatable {
  case up
  case down
}

public struct MoveBookmarkCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: PDFObjectID
  public let direction: BookmarkMoveDirection

  public init(objectID: PDFObjectID, direction: BookmarkMoveDirection) {
    self.objectID = objectID
    self.direction = direction
  }

  public var name: String {
    direction == .up ? "Move Bookmark Up" : "Move Bookmark Down"
  }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary(let item)? = graph.objects[objectID],
      item[PDFName("Title")] != nil,
      let parentID = OutlineSupport.parentID(of: item, in: graph)
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    switch direction {
    case .up:
      guard case .reference(let previous)? = item[PDFName("Prev")] else {
        throw PDFError(.malformed, "The bookmark is already first")
      }
      _ = previous
    case .down:
      guard case .reference(let next)? = item[PDFName("Next")] else {
        throw PDFError(.malformed, "The bookmark is already last")
      }
      _ = next
    }
    _ = parentID
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var item)? = graph.objects[objectID],
      let parentID = OutlineSupport.parentID(of: item, in: graph),
      case .dictionary(var parent)? = graph.objects[parentID]
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    let previous: PDFObjectID?
    if case .reference(let id)? = item[PDFName("Prev")] { previous = id } else { previous = nil }
    let next: PDFObjectID?
    if case .reference(let id)? = item[PDFName("Next")] { next = id } else { next = nil }

    switch direction {
    case .up:
      guard let previous,
        case .dictionary(var previousItem)? = graph.objects[previous]
      else { throw PDFError(.malformed, "The previous bookmark is missing") }
      let beforePrevious: PDFObjectID?
      if case .reference(let id)? = previousItem[PDFName("Prev")] {
        beforePrevious = id
      } else {
        beforePrevious = nil
      }
      if let beforePrevious,
        case .dictionary(var itemBefore)? = graph.objects[beforePrevious]
      {
        itemBefore[PDFName("Next")] = .reference(objectID)
        graph.objects[beforePrevious] = .dictionary(itemBefore)
      } else {
        parent[PDFName("First")] = .reference(objectID)
      }
      item[PDFName("Prev")] = beforePrevious.map { .reference($0) } ?? .null
      item[PDFName("Next")] = .reference(previous)
      previousItem[PDFName("Prev")] = .reference(objectID)
      previousItem[PDFName("Next")] = next.map { .reference($0) } ?? .null
      if previousItem[PDFName("Next")] == .null { previousItem[PDFName("Next")] = nil }
      if next == nil {
        parent[PDFName("Last")] = .reference(previous)
      }
      if let next,
        case .dictionary(var nextItem)? = graph.objects[next]
      {
        nextItem[PDFName("Prev")] = .reference(previous)
        graph.objects[next] = .dictionary(nextItem)
      }
      graph.objects[previous] = .dictionary(previousItem)
    case .down:
      guard let next,
        case .dictionary(var nextItem)? = graph.objects[next]
      else { throw PDFError(.malformed, "The next bookmark is missing") }
      let afterNext: PDFObjectID?
      if case .reference(let id)? = nextItem[PDFName("Next")] {
        afterNext = id
      } else {
        afterNext = nil
      }
      item[PDFName("Prev")] = .reference(next)
      item[PDFName("Next")] = afterNext.map { .reference($0) } ?? .null
      nextItem[PDFName("Prev")] = previous.map { .reference($0) } ?? .null
      if nextItem[PDFName("Prev")] == .null { nextItem[PDFName("Prev")] = nil }
      nextItem[PDFName("Next")] = .reference(objectID)
      if let previous,
        case .dictionary(var previousItem)? = graph.objects[previous]
      {
        previousItem[PDFName("Next")] = .reference(next)
        graph.objects[previous] = .dictionary(previousItem)
      } else {
        parent[PDFName("First")] = .reference(next)
      }
      if let afterNext,
        case .dictionary(var itemAfter)? = graph.objects[afterNext]
      {
        itemAfter[PDFName("Prev")] = .reference(objectID)
        graph.objects[afterNext] = .dictionary(itemAfter)
      } else {
        parent[PDFName("Last")] = .reference(objectID)
      }
      graph.objects[next] = .dictionary(nextItem)
    }
    // A nil Prev/Next must be omitted rather than written as null.
    if item[PDFName("Prev")] == .null { item[PDFName("Prev")] = nil }
    if item[PDFName("Next")] == .null { item[PDFName("Next")] = nil }
    graph.objects[objectID] = .dictionary(item)
    graph.objects[parentID] = .dictionary(parent)
    return graph
  }
}

/// PAG-09: make a bookmark the last child of its previous sibling.
public struct NestBookmarkCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: PDFObjectID

  public init(objectID: PDFObjectID) {
    self.objectID = objectID
  }

  public var name: String { "Nest Bookmark" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary(let item)? = graph.objects[objectID],
      item[PDFName("Title")] != nil,
      let parentID = OutlineSupport.parentID(of: item, in: graph),
      case .dictionary(let parent)? = graph.objects[parentID]
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    guard case .reference(let previous)? = item[PDFName("Prev")],
      previous != objectID,
      case .dictionary(let previousItem)? = graph.objects[previous],
      previousItem[PDFName("Title")] != nil
    else {
      throw PDFError(.malformed, "The bookmark has no previous sibling to nest under")
    }
    guard !OutlineSupport.contains(previous, parentID: objectID, in: graph) else {
      throw PDFError(.malformed, "A bookmark cannot be nested under its own child")
    }
    _ = parent
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var item)? = graph.objects[objectID],
      let parentID = OutlineSupport.parentID(of: item, in: graph),
      case .reference(let previous)? = item[PDFName("Prev")]
    else {
      throw PDFError(.malformed, "The bookmark is missing")
    }
    let contribution = OutlineSupport.visibleContribution(objectID, in: graph)
    try OutlineSupport.detach(
      objectID, item: item, parentID: parentID, contribution: contribution, in: &graph)
    let previousChild = OutlineSupport.append(
      objectID, under: previous, contribution: contribution, in: &graph)
    item[PDFName("Prev")] = previousChild.map { .reference($0) } ?? .null
    if item[PDFName("Prev")] == .null { item[PDFName("Prev")] = nil }
    item[PDFName("Next")] = nil
    item[PDFName("Parent")] = .reference(previous)
    graph.objects[objectID] = .dictionary(item)
    return graph
  }
}

/// PAG-09: outdent a nested bookmark one level, immediately after its former
/// parent.
public struct OutdentBookmarkCommand: PDFEditCommand, Equatable, Sendable {
  public let objectID: PDFObjectID

  public init(objectID: PDFObjectID) {
    self.objectID = objectID
  }

  public var name: String { "Outdent Bookmark" }
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary(let item)? = graph.objects[objectID],
      item[PDFName("Title")] != nil,
      case .reference(let parentID)? = item[PDFName("Parent")],
      case .dictionary(let parent)? = graph.objects[parentID],
      parent[PDFName("Title")] != nil
    else {
      throw PDFError(.malformed, "Only a nested bookmark can be outdented")
    }
    _ = parent
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var item)? = graph.objects[objectID],
      case .reference(let parentID)? = item[PDFName("Parent")],
      case .dictionary(var parent)? = graph.objects[parentID],
      let grandparentID = OutlineSupport.parentID(of: parent, in: graph)
    else {
      throw PDFError(.malformed, "Only a nested bookmark can be outdented")
    }
    let contribution = OutlineSupport.visibleContribution(objectID, in: graph)
    try OutlineSupport.detach(
      objectID, item: item, parentID: parentID, contribution: contribution, in: &graph)
    // Re-read the parent after detaching changed its Count/First/Last.
    guard case .dictionary(var updatedParent)? = graph.objects[parentID] else {
      throw PDFError(.malformed, "The parent bookmark is missing")
    }
    let parentNext: PDFObjectID?
    if case .reference(let id)? = updatedParent[PDFName("Next")] {
      parentNext = id
    } else {
      parentNext = nil
    }
    item[PDFName("Prev")] = .reference(parentID)
    item[PDFName("Next")] = parentNext.map { .reference($0) } ?? .null
    item[PDFName("Parent")] = .reference(grandparentID)
    updatedParent[PDFName("Next")] = .reference(objectID)
    graph.objects[parentID] = .dictionary(updatedParent)
    if let parentNext,
      case .dictionary(var nextItem)? = graph.objects[parentNext]
    {
      nextItem[PDFName("Prev")] = .reference(objectID)
      graph.objects[parentNext] = .dictionary(nextItem)
    } else if case .dictionary(var grandparent)? = graph.objects[grandparentID] {
      grandparent[PDFName("Last")] = .reference(objectID)
      OutlineSupport.increment(
        &grandparent, by: contribution, key: PDFName("Count"))
      graph.objects[grandparentID] = .dictionary(grandparent)
    } else {
      throw PDFError(.malformed, "The outline tree is missing")
    }
    if parentNext != nil,
      case .dictionary(var grandparent)? = graph.objects[grandparentID]
    {
      OutlineSupport.increment(
        &grandparent, by: contribution, key: PDFName("Count"))
      graph.objects[grandparentID] = .dictionary(grandparent)
    }
    if item[PDFName("Next")] == .null { item[PDFName("Next")] = nil }
    graph.objects[objectID] = .dictionary(item)
    return graph
  }
}

/// Shared outline-link mechanics for bookmark reorder and hierarchy changes.
enum OutlineSupport {
  static func parentID(of item: [PDFName: PDFValue], in graph: PDFGraph) -> PDFObjectID? {
    if case .reference(let id)? = item[PDFName("Parent")] { return id }
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let outlinesID)? = catalog[PDFName("Outlines")]
    else { return nil }
    return outlinesID
  }

  static func contains(
    _ ancestorID: PDFObjectID, parentID: PDFObjectID, in graph: PDFGraph
  ) -> Bool {
    var cursor: PDFObjectID? = parentID
    var visited = Set<PDFObjectID>()
    while let id = cursor, visited.insert(id).inserted {
      if id == ancestorID { return true }
      guard case .dictionary(let item)? = graph.objects[id],
        case .reference(let parent)? = item[PDFName("Parent")]
      else { return false }
      cursor = parent
    }
    return false
  }

  /// The number of visible outline rows contributed by a subtree: the item
  /// itself plus its positive /Count when it is open.
  static func visibleContribution(_ id: PDFObjectID, in graph: PDFGraph) -> Int {
    guard case .dictionary(let item)? = graph.objects[id],
      case .integer(let count)? = item[PDFName("Count")],
      count > 0
    else { return 1 }
    return Int(count) + 1
  }

  static func decrement(
    _ dictionary: inout [PDFName: PDFValue], by amount: Int, key: PDFName
  ) {
    if case .integer(let count)? = dictionary[key] {
      dictionary[key] = .integer(max(0, count - Int64(amount)))
    }
  }

  static func increment(
    _ dictionary: inout [PDFName: PDFValue], by amount: Int, key: PDFName
  ) {
    if case .integer(let count)? = dictionary[key] {
      dictionary[key] = .integer(count + Int64(amount))
    } else {
      dictionary[key] = .integer(Int64(amount))
    }
  }

  static func detach(
    _ objectID: PDFObjectID, item: [PDFName: PDFValue], parentID: PDFObjectID,
    contribution: Int, in graph: inout PDFGraph
  ) throws {
    guard case .dictionary(var parent)? = graph.objects[parentID] else {
      throw PDFError(.malformed, "The bookmark parent is missing")
    }
    let previous: PDFObjectID?
    if case .reference(let id)? = item[PDFName("Prev")] { previous = id } else { previous = nil }
    let next: PDFObjectID?
    if case .reference(let id)? = item[PDFName("Next")] { next = id } else { next = nil }
    if let previous,
      case .dictionary(var previousItem)? = graph.objects[previous]
    {
      previousItem[PDFName("Next")] = next.map { .reference($0) } ?? .null
      if previousItem[PDFName("Next")] == .null { previousItem[PDFName("Next")] = nil }
      graph.objects[previous] = .dictionary(previousItem)
    } else {
      parent[PDFName("First")] = next.map { .reference($0) } ?? .null
      if parent[PDFName("First")] == .null { parent[PDFName("First")] = nil }
    }
    if let next,
      case .dictionary(var nextItem)? = graph.objects[next]
    {
      nextItem[PDFName("Prev")] = previous.map { .reference($0) } ?? .null
      if nextItem[PDFName("Prev")] == .null { nextItem[PDFName("Prev")] = nil }
      graph.objects[next] = .dictionary(nextItem)
    } else {
      parent[PDFName("Last")] = previous.map { .reference($0) } ?? .null
      if parent[PDFName("Last")] == .null { parent[PDFName("Last")] = nil }
    }
    decrement(&parent, by: contribution, key: PDFName("Count"))
    graph.objects[parentID] = .dictionary(parent)
  }

  @discardableResult
  static func append(
    _ objectID: PDFObjectID, under parentID: PDFObjectID, contribution: Int,
    in graph: inout PDFGraph
  ) -> PDFObjectID? {
    guard case .dictionary(var parent)? = graph.objects[parentID] else { return nil }
    let lastID: PDFObjectID?
    if case .reference(let id)? = parent[PDFName("Last")] { lastID = id } else { lastID = nil }
    if let lastID, case .dictionary(var last)? = graph.objects[lastID] {
      last[PDFName("Next")] = .reference(objectID)
      graph.objects[lastID] = .dictionary(last)
    } else {
      parent[PDFName("First")] = .reference(objectID)
    }
    parent[PDFName("Last")] = .reference(objectID)
    increment(&parent, by: contribution, key: PDFName("Count"))
    graph.objects[parentID] = .dictionary(parent)
    return lastID
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
