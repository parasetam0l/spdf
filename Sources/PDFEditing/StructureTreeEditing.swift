import Foundation
import PDFCore

// A11Y-01: structure-tree editing beyond role/alt-text. These commands create,
// delete and reparent elements, attach existing MCIDs/object references with valid
// ParentTree entries, and add artifact controls. They are pure graph transforms
// (the same transaction model the Undo stack restores), so parent trees, MCIDs
// and object references are verified here and again after save/reopen.

/// Shared ParentTree maintenance for the structure-editing commands.
enum StructureParentTreeSupport {
  static func structTreeRootID(in graph: PDFGraph) -> PDFObjectID? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .reference(let rootID)? = catalog[PDFName("StructTreeRoot")]
    else { return nil }
    return rootID
  }

  static func pageStructParents(pageID: PDFObjectID, in graph: PDFGraph) throws -> Int {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard case .integer(let key)? = page[PDFName("StructParents")] else {
      throw PDFError(.malformed, "The page has no /StructParents key")
    }
    guard let value = Int(exactly: key) else {
      throw PDFError(.malformed, "The page StructParents key is not an integer")
    }
    return value
  }

  /// The page's marked-content IDs in content order.
  static func markedMCIDs(pageID: PDFObjectID, in graph: PDFGraph) throws -> Set<Int> {
    let content = try PageContent.load(pageID: pageID, in: graph)
    var ids: Set<Int> = []
    for range in StructureTaggingAssistant.markedRanges(in: content) {
      if let mcid = range.mcid { ids.insert(mcid) }
    }
    return ids
  }

  /// Read and write the StructTreeRoot ParentTree number tree (Nums-only or with
  /// Kids, which the inspector also resolves). Reads return the number tree root
  /// value and a setter closure that writes it back (direct or indirect).
  struct NumberTreeEditor {
    var graph: PDFGraph
    let rootID: PDFObjectID
    var dictionary: [PDFName: PDFValue]

    static func open(in graph: PDFGraph) throws -> NumberTreeEditor {
      guard let rootID = structTreeRootID(in: graph),
        case .dictionary(let root)? = graph.objects[rootID]
      else {
        throw PDFError(.unsupported, "The document has no indirect StructTreeRoot")
      }
      var editor = NumberTreeEditor(graph: graph, rootID: rootID, dictionary: root)
      _ = try editor.resolveNumberTree()
      return editor
    }

    mutating func resolveNumberTree() throws -> [PDFName: PDFValue] {
      guard case .reference(let treeID)? = dictionary[PDFName("ParentTree")] else {
        dictionary[PDFName("ParentTree")] = .dictionary([PDFName("Nums"): .array([])])
        return [PDFName("Nums"): .array([])]
      }
      guard case .dictionary(let tree)? = graph.objects[treeID] else {
        throw PDFError(.malformed, "The ParentTree object is missing")
      }
      return tree
    }

    /// Sets (or clears with nil) the mapping for a page StructParents or an
    /// annotation StructParent. For array-shaped page mappings, mcid selects the
    /// slot.
    mutating func set(
      structKey: Int, mcid: Int?, to elementID: PDFObjectID?
    ) throws {
      guard case .reference(let treeID)? = dictionary[PDFName("ParentTree")],
        case .dictionary(var tree)? = graph.objects[treeID],
        case .array(var numbers)? = tree[PDFName("Nums")]
      else {
        throw PDFError(.malformed, "The ParentTree number tree is missing or malformed")
      }
      guard let keyIndex = numbers.indices.first(where: { index in
        index % 2 == 0 && numbers[index] == .integer(Int64(structKey))
      }) else {
        throw PDFError(.malformed, "The ParentTree has no entry for struct parent \(structKey)")
      }
      let valueIndex = keyIndex + 1
      guard valueIndex < numbers.count else {
        throw PDFError(.malformed, "The ParentTree entry is truncated")
      }
      switch numbers[valueIndex] {
      case .array(var entries):
        guard let mcid else {
          throw PDFError(.malformed, "A page ParentTree entry needs an MCID")
        }
        guard mcid >= 0 else {
          throw PDFError(.malformed, "The MCID is negative")
        }
        while entries.count <= mcid { entries.append(.null) }
        entries[mcid] = elementID.map { PDFValue.reference($0) } ?? .null
        numbers[valueIndex] = .array(entries)
      case .reference, .null, .integer:
        if let mcid {
          guard mcid == 0 else {
            throw PDFError(.malformed, "The ParentTree entry is not a page MCID array")
          }
        }
        numbers[valueIndex] = elementID.map { PDFValue.reference($0) } ?? .null
      default:
        throw PDFError(.malformed, "The ParentTree entry shape is unsupported")
      }
      tree[PDFName("Nums")] = .array(numbers)
      graph.objects[treeID] = .dictionary(tree)
    }

    mutating func clear(elementIDs: Set<PDFObjectID>) {
      guard case .reference(let treeID)? = dictionary[PDFName("ParentTree")],
        case .dictionary(var tree)? = graph.objects[treeID],
        case .array(var numbers)? = tree[PDFName("Nums")]
      else { return }
      func cleared(_ value: PDFValue) -> PDFValue {
        switch value {
        case .reference(let id):
          return elementIDs.contains(id) ? .null : value
        case .array(let entries):
          return .array(entries.map(cleared))
        case .dictionary(let dictionary):
          return .dictionary(dictionary.mapValues(cleared))
        default:
          return value
        }
      }
      numbers = numbers.map(cleared)
      tree[PDFName("Nums")] = .array(numbers)
      graph.objects[treeID] = .dictionary(tree)
    }

    mutating func elementIDs(structKey: Int, mcid: Int?) -> [PDFObjectID] {
      guard case .reference(let treeID)? = dictionary[PDFName("ParentTree")],
        case .dictionary(let tree)? = graph.objects[treeID],
        case .array(let numbers)? = tree[PDFName("Nums")]
      else { return [] }
      guard let keyIndex = numbers.indices.first(where: { index in
        index % 2 == 0 && numbers[index] == .integer(Int64(structKey))
      }), keyIndex + 1 < numbers.count
      else { return [] }
      func ids(_ value: PDFValue) -> [PDFObjectID] {
        switch value {
        case .reference(let id): return [id]
        case .array(let entries):
          if let mcid {
            guard entries.indices.contains(mcid) else { return [] }
            return ids(entries[mcid])
          }
          return entries.flatMap(ids)
        default: return []
        }
      }
      return ids(numbers[keyIndex + 1])
    }

    mutating func commit() {
      graph.objects[rootID] = .dictionary(dictionary)
    }
  }

  /// All element object IDs in a subtree (the root included).
  static func subtreeIDs(from elementID: PDFObjectID, in graph: PDFGraph) -> [PDFObjectID] {
    var result: [PDFObjectID] = []
    var stack = [elementID]
    var seen: Set<PDFObjectID> = []
    while let id = stack.popLast() {
      guard !seen.contains(id) else { continue }
      seen.insert(id)
      result.append(id)
      guard case .dictionary(let dictionary)? = graph.objects[id],
        case .array(let kids)? = dictionary[PDFName("K")]
      else { continue }
      for kid in kids {
        if case .reference(let nested) = kid { stack.append(nested) }
      }
    }
    return result
  }

  static func parentID(of elementID: PDFObjectID, in graph: PDFGraph) throws -> PDFObjectID {
    let dictionary = try StructureEditSupport.element(elementID, in: graph)
    guard case .reference(let parent)? = dictionary[PDFName("P")] else {
      throw PDFError(.malformed, "The element has no parent")
    }
    return parent
  }

  static func childReferences(of parentID: PDFObjectID, in graph: PDFGraph) throws
    -> [PDFValue]
  {
    let parent = try StructureEditSupport.element(parentID, in: graph)
    guard case .array(let kids)? = parent[PDFName("K")] else {
      throw PDFError(.malformed, "The parent has no children")
    }
    return kids
  }

  static func writeChildren(
    _ kids: [PDFValue], parentID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    var parent = try StructureEditSupport.element(parentID, in: graph)
    parent[PDFName("K")] = .array(kids)
    StructureEditSupport.write(parent, id: parentID, to: &graph)
  }

  static func isValidRole(_ role: PDFName) -> Bool {
    PDFStructureInspector.standardRoles.contains(String(decoding: role.bytes, as: UTF8.self))
  }
}

/// A11Y-01: create a new structure element under a grouping parent. The element
/// can own an existing page MCID (with a fresh ParentTree mapping) or reference
/// an existing annotation/widget object through /OBJR.
public struct CreateStructureElementCommand: PDFEditCommand, Equatable, Sendable {
  public let parentID: PDFObjectID
  public let role: PDFName
  public let insertionIndex: Int?
  public let title: String?
  public let pageID: PDFObjectID?
  public let mcid: Int?
  public let objectReference: PDFObjectID?

  public init(
    parentID: PDFObjectID, role: PDFName, insertionIndex: Int? = nil, title: String? = nil,
    pageID: PDFObjectID? = nil, mcid: Int? = nil, objectReference: PDFObjectID? = nil
  ) {
    self.parentID = parentID
    self.role = role
    self.insertionIndex = insertionIndex
    self.title = title
    self.pageID = pageID
    self.mcid = mcid
    self.objectReference = objectReference
  }

  public var name: String { "Create Structure Element" }

  public func validate(in graph: PDFGraph) throws {
    _ = try StructureEditSupport.element(parentID, in: graph)
    let kids = try StructureParentTreeSupport.childReferences(of: parentID, in: graph)
    let index = insertionIndex ?? kids.count
    guard index >= 0, index <= kids.count else {
      throw PDFError(.malformed, "The insertion index is outside the parent's children")
    }
    guard StructureParentTreeSupport.isValidRole(role) else {
      throw PDFError(.unsupported, "The role is not a standard structure role")
    }
    guard mcid == nil || objectReference == nil else {
      throw PDFError(.malformed, "An element is either marked content or an object reference")
    }
    if let mcid {
      guard let pageID else {
        throw PDFError(.malformed, "Marked content needs a page")
      }
      guard try StructureParentTreeSupport.markedMCIDs(pageID: pageID, in: graph)
        .contains(mcid)
      else {
        throw PDFError(.malformed, "The page has no marked content with MCID \(mcid)")
      }
      let structKey = try StructureParentTreeSupport.pageStructParents(
        pageID: pageID, in: graph)
      var tree = try StructureParentTreeSupport.NumberTreeEditor.open(in: graph)
      let existing = tree.elementIDs(structKey: structKey, mcid: mcid)
      guard existing.isEmpty else {
        throw PDFError(.malformed, "MCID \(mcid) is already mapped to a structure element")
      }
    }
    if let objectReference {
      guard graph.objects[objectReference] != nil else {
        throw PDFError(.malformed, "The referenced annotation object is missing")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var kids = try StructureParentTreeSupport.childReferences(of: parentID, in: graph)
    let index = insertionIndex ?? kids.count
    let newID = StructureEditSupport.nextObjectID(in: graph)
    var element: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(role),
      PDFName("P"): .reference(parentID),
    ]
    if let title, !title.isEmpty { element[PDFName("T")] = .string(Data(title.utf8)) }
    if let pageID { element[PDFName("Pg")] = .reference(pageID) }
    if let mcid {
      element[PDFName("K")] = .integer(Int64(mcid))
      if let pageID {
        let structKey = try StructureParentTreeSupport.pageStructParents(
          pageID: pageID, in: graph)
        var tree = try StructureParentTreeSupport.NumberTreeEditor.open(in: graph)
        try tree.set(structKey: structKey, mcid: mcid, to: newID)
        tree.commit()
        graph = tree.graph
      }
    } else if let objectReference, let pageID {
      element[PDFName("K")] = .array([
        .dictionary([
          PDFName("Type"): .name(PDFName("OBJR")),
          PDFName("Obj"): .reference(objectReference),
          PDFName("Pg"): .reference(pageID),
        ])
      ])
      if case .dictionary(let annotation)? = graph.objects[objectReference],
        case .integer(let structParent)? = annotation[PDFName("StructParent")],
        let key = Int(exactly: structParent)
      {
        var tree = try StructureParentTreeSupport.NumberTreeEditor.open(in: graph)
        try tree.set(structKey: key, mcid: nil, to: newID)
        tree.commit()
        graph = tree.graph
      }
    }
    graph.objects[newID] = .dictionary(element)
    kids.insert(.reference(newID), at: index)
    try StructureParentTreeSupport.writeChildren(kids, parentID: parentID, in: &graph)
    return graph
  }
}

/// A11Y-01: delete an element and its subtree. The page paint is preserved; only
/// the tags, ParentTree mappings and object references go away.
public struct DeleteStructureElementCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public init(elementID: PDFObjectID) { self.elementID = elementID }
  public var name: String { "Delete Structure Element" }

  public func validate(in graph: PDFGraph) throws {
    _ = try StructureEditSupport.element(elementID, in: graph)
    guard let rootID = StructureParentTreeSupport.structTreeRootID(in: graph) else {
      throw PDFError(.unsupported, "The document has no structure tree root")
    }
    guard elementID != rootID else {
      throw PDFError(.unsupported, "The structure tree root cannot be deleted")
    }
    _ = try StructureParentTreeSupport.parentID(of: elementID, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let removed = Set(
      StructureParentTreeSupport.subtreeIDs(from: elementID, in: graph))
    let parentID = try StructureParentTreeSupport.parentID(of: elementID, in: graph)
    var kids = try StructureParentTreeSupport.childReferences(of: parentID, in: graph)
    kids.removeAll { value in
      if case .reference(let id) = value { return id == elementID }
      return false
    }
    try StructureParentTreeSupport.writeChildren(kids, parentID: parentID, in: &graph)

    var tree = try StructureParentTreeSupport.NumberTreeEditor.open(in: graph)
    tree.clear(elementIDs: removed)
    tree.commit()
    graph = tree.graph

    for id in removed {
      guard case .dictionary(let dictionary)? = graph.objects[id],
        case .array(let childValues)? = dictionary[PDFName("K")]
      else { continue }
      for child in childValues {
        guard case .dictionary(let objectReference) = child,
          objectReference[PDFName("Type")] == .name(PDFName("OBJR")),
          case .reference(let annotationID)? = objectReference[PDFName("Obj")],
          case .dictionary(var annotation)? = graph.objects[annotationID]
        else { continue }
        annotation.removeValue(forKey: PDFName("StructParent"))
        graph.objects[annotationID] = .dictionary(annotation)
      }
    }
    for id in removed { graph.objects[id] = nil }
    return graph
  }
}

/// A11Y-01: reparent an element (and its subtree) under another grouping
/// element. ParentTree/MCID mappings are unchanged because they key on the leaf
/// element, not on its ancestors.
public struct ReparentStructureElementCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let newParentID: PDFObjectID
  public let insertionIndex: Int?
  public init(elementID: PDFObjectID, newParentID: PDFObjectID, insertionIndex: Int? = nil) {
    self.elementID = elementID
    self.newParentID = newParentID
    self.insertionIndex = insertionIndex
  }
  public var name: String { "Reparent Structure Element" }

  public func validate(in graph: PDFGraph) throws {
    _ = try StructureEditSupport.element(elementID, in: graph)
    _ = try StructureEditSupport.element(newParentID, in: graph)
    guard elementID != newParentID else {
      throw PDFError(.malformed, "An element cannot be its own parent")
    }
    let newKids = try StructureParentTreeSupport.childReferences(
      of: newParentID, in: graph)
    let index = insertionIndex ?? newKids.count
    guard index >= 0, index <= newKids.count else {
      throw PDFError(.malformed, "The insertion index is outside the new parent's children")
    }
    var cursor: PDFObjectID? = newParentID
    var steps = 0
    while let id = cursor, steps < 4096 {
      if id == elementID {
        throw PDFError(.malformed, "Reparenting would create a cycle")
      }
      cursor = try? StructureParentTreeSupport.parentID(of: id, in: graph)
      steps += 1
    }
    _ = try StructureParentTreeSupport.parentID(of: elementID, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let oldParentID = try StructureParentTreeSupport.parentID(of: elementID, in: graph)
    if oldParentID == newParentID {
      var kids = try StructureParentTreeSupport.childReferences(of: oldParentID, in: graph)
      guard let from = kids.firstIndex(where: { value in
        if case .reference(let id) = value { return id == elementID }
        return false
      }) else {
        throw PDFError(.malformed, "The element is not a child of its parent")
      }
      let child = kids.remove(at: from)
      var index = insertionIndex ?? kids.count
      if from < index { index -= 1 }
      index = max(0, min(index, kids.count))
      kids.insert(child, at: index)
      try StructureParentTreeSupport.writeChildren(kids, parentID: oldParentID, in: &graph)
      return graph
    }
    var oldKids = try StructureParentTreeSupport.childReferences(of: oldParentID, in: graph)
    guard let from = oldKids.firstIndex(where: { value in
      if case .reference(let id) = value { return id == elementID }
      return false
    }) else {
      throw PDFError(.malformed, "The element is not a child of its parent")
    }
    oldKids.remove(at: from)
    try StructureParentTreeSupport.writeChildren(
      oldKids, parentID: oldParentID, in: &graph)
    var newKids = try StructureParentTreeSupport.childReferences(
      of: newParentID, in: graph)
    let index = max(0, min(insertionIndex ?? newKids.count, newKids.count))
    newKids.insert(.reference(elementID), at: index)
    try StructureParentTreeSupport.writeChildren(
      newKids, parentID: newParentID, in: &graph)
    var element = try StructureEditSupport.element(elementID, in: graph)
    element[PDFName("P")] = .reference(newParentID)
    StructureEditSupport.write(element, id: elementID, to: &graph)
    return graph
  }
}

/// A11Y-01: artifact controls. Mark a whole subtree as artifacts (roles become
/// Artifact, Alternate/Actual text is cleared); restore one element's semantic
/// role afterwards. Paint and content references are never changed.
public struct MarkStructureSubtreeArtifactCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public init(elementID: PDFObjectID) { self.elementID = elementID }
  public var name: String { "Mark Subtree as Artifact" }

  public func validate(in graph: PDFGraph) throws {
    _ = try StructureEditSupport.element(elementID, in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    for id in StructureParentTreeSupport.subtreeIDs(from: elementID, in: graph) {
      guard case .dictionary(var dictionary)? = graph.objects[id] else { continue }
      dictionary[PDFName("S")] = .name(PDFName("Artifact"))
      dictionary.removeValue(forKey: PDFName("Alt"))
      dictionary.removeValue(forKey: PDFName("ActualText"))
      graph.objects[id] = .dictionary(dictionary)
    }
    return graph
  }
}

/// A11Y-01: restore a semantic role on an element previously marked as artifact.
public struct UnmarkStructureArtifactCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let role: PDFName
  public init(elementID: PDFObjectID, role: PDFName = PDFName("P")) {
    self.elementID = elementID
    self.role = role
  }
  public var name: String { "Restore Structure Role" }

  public func validate(in graph: PDFGraph) throws {
    let dictionary = try StructureEditSupport.element(elementID, in: graph)
    guard StructureEditSupport.resolvedRole(of: dictionary, in: graph) == "Artifact" else {
      throw PDFError(.malformed, "The element is not marked as an artifact")
    }
    guard StructureParentTreeSupport.isValidRole(role),
      String(decoding: role.bytes, as: UTF8.self) != "Artifact"
    else {
      throw PDFError(.unsupported, "Restoring an artifact needs a non-artifact standard role")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var dictionary = try StructureEditSupport.element(elementID, in: graph)
    dictionary[PDFName("S")] = .name(role)
    StructureEditSupport.write(dictionary, id: elementID, to: &graph)
    return graph
  }
}

