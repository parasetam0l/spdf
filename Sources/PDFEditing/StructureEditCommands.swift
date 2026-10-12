import Foundation
import PDFCore

/// Shared helpers for structure edits: elements are indirect StructElem
/// dictionaries, and every command preserves unknown keys by mutating the
/// dictionary in place.
enum StructureEditSupport {
  static func element(_ id: PDFObjectID, in graph: PDFGraph) throws -> [PDFName: PDFValue] {
    guard case .dictionary(let dictionary)? = graph.objects[id],
      dictionary[PDFName("Type")] == .name(PDFName("StructElem"))
        || dictionary[PDFName("Type")] == .name(PDFName("StructTreeRoot"))
        || dictionary[PDFName("S")] != nil
    else {
      throw PDFError(.malformed, "The target is not a structure element")
    }
    return dictionary
  }

  /// The element's role after applying the document role map.
  static func resolvedRole(of dictionary: [PDFName: PDFValue], in graph: PDFGraph) -> String? {
    guard case .name(let raw)? = dictionary[PDFName("S")] else { return nil }
    var role = String(decoding: raw.bytes, as: UTF8.self)
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID],
      case .reference(let structID)? = catalog[PDFName("StructTreeRoot")],
      case .dictionary(let root)? = graph.objects[structID],
      case .dictionary(let roleMap)? = root[PDFName("RoleMap")]
    else { return role }
    var hops = 0
    while case .name(let mapped)? = roleMap[PDFName(role)], hops < 8 {
      role = String(decoding: mapped.bytes, as: UTF8.self)
      hops += 1
    }
    return role
  }

  static func write(_ dictionary: [PDFName: PDFValue], id: PDFObjectID, to graph: inout PDFGraph) {
    graph.objects[id] = .dictionary(dictionary)
  }

  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }

  static func string(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

/// P33-008: assign a standard structure role with explicit semantics. Custom
/// roles must already resolve through the document role map.
public struct SetStructureRoleCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let role: PDFName

  public init(elementID: PDFObjectID, role: PDFName) {
    self.elementID = elementID
    self.role = role
  }

  public var name: String { "Set Structure Role" }

  public func validate(in graph: PDFGraph) throws {
    _ = try StructureEditSupport.element(elementID, in: graph)
    let roleString = String(decoding: role.bytes, as: UTF8.self)
    guard PDFStructureInspector.standardRoles.contains(roleString) else {
      throw PDFError(.unsupported, "Only standard structure roles can be assigned")
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

/// P33-009: alternate text for supported figures. Visible content is never
/// touched.
public struct SetStructureAltTextCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  /// nil removes the alternate text.
  public let alt: String?

  public init(elementID: PDFObjectID, alt: String?) {
    self.elementID = elementID
    self.alt = alt
  }

  public var name: String { "Set Alternate Text" }

  public func validate(in graph: PDFGraph) throws {
    let dictionary = try StructureEditSupport.element(elementID, in: graph)
    let role = StructureEditSupport.resolvedRole(of: dictionary, in: graph)
    guard role == "Figure" else {
      throw PDFError(.unsupported, "Alternate text applies to Figure elements")
    }
    if let alt, alt.isEmpty {
      throw PDFError(.malformed, "Alternate text must not be empty; remove it instead")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var dictionary = try StructureEditSupport.element(elementID, in: graph)
    if let alt {
      dictionary[PDFName("Alt")] = .string(Data(alt.utf8))
    } else {
      dictionary.removeValue(forKey: PDFName("Alt"))
    }
    StructureEditSupport.write(dictionary, id: elementID, to: &graph)
    return graph
  }
}

/// P33-011: actual-text replacement for supported elements. It changes only
/// the accessibility text, never the visible content.
public struct SetStructureActualTextCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  /// nil removes the replacement.
  public let actualText: String?

  public init(elementID: PDFObjectID, actualText: String?) {
    self.elementID = elementID
    self.actualText = actualText
  }

  public var name: String { "Set Actual Text" }

  public func validate(in graph: PDFGraph) throws {
    _ = try StructureEditSupport.element(elementID, in: graph)
    if let actualText, actualText.isEmpty {
      throw PDFError(.malformed, "Actual text must not be empty; remove it instead")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var dictionary = try StructureEditSupport.element(elementID, in: graph)
    if let actualText {
      dictionary[PDFName("ActualText")] = .string(Data(actualText.utf8))
    } else {
      dictionary.removeValue(forKey: PDFName("ActualText"))
    }
    StructureEditSupport.write(dictionary, id: elementID, to: &graph)
    return graph
  }
}

/// P33-010: document-level language (nil element) or element-level language.
public struct SetStructureLanguageCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID?
  /// nil removes the language value.
  public let language: String?

  public init(elementID: PDFObjectID? = nil, language: String?) {
    self.elementID = elementID
    self.language = language
  }

  public var name: String { "Set Language" }

  public func validate(in graph: PDFGraph) throws {
    if let language {
      let pattern = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/
      guard language.wholeMatch(of: pattern) != nil else {
        throw PDFError(.malformed, "Language tags use forms such as en or en-US")
      }
    }
    if let elementID {
      _ = try StructureEditSupport.element(elementID, in: graph)
    } else {
      guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
        case .dictionary(let catalog)? = graph.objects[rootID]
      else { throw PDFError(.malformed, "The catalog is missing") }
      _ = catalog
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    if let elementID {
      var dictionary = try StructureEditSupport.element(elementID, in: graph)
      if let language {
        dictionary[PDFName("Lang")] = .string(Data(language.utf8))
      } else {
        dictionary.removeValue(forKey: PDFName("Lang"))
      }
      StructureEditSupport.write(dictionary, id: elementID, to: &graph)
      return graph
    }
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    else { throw PDFError(.malformed, "The catalog is missing") }
    if let language {
      catalog[PDFName("Lang")] = .string(Data(language.utf8))
    } else {
      catalog.removeValue(forKey: PDFName("Lang"))
    }
    graph.objects[rootID] = .dictionary(catalog)
    return graph
  }
}

/// P33-012: reorder one parent's children, changing reading order without
/// touching paint order (content streams are never rewritten).
public struct ReorderStructureChildrenCommand: PDFEditCommand, Equatable, Sendable {
  public let parentID: PDFObjectID
  public let fromIndex: Int
  public let toIndex: Int

  public init(parentID: PDFObjectID, fromIndex: Int, toIndex: Int) {
    self.parentID = parentID
    self.fromIndex = fromIndex
    self.toIndex = toIndex
  }

  public var name: String { "Reorder Structure Children" }

  public func validate(in graph: PDFGraph) throws {
    let parent = try StructureEditSupport.element(parentID, in: graph)
    guard case .array(let kids)? = parent[PDFName("K")], !kids.isEmpty,
      kids.indices.contains(fromIndex), kids.indices.contains(toIndex)
    else {
      throw PDFError(.malformed, "The parent has no child at that position")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var parent = try StructureEditSupport.element(parentID, in: graph)
    guard case .array(var kids)? = parent[PDFName("K")] else {
      throw PDFError(.malformed, "The parent has no children")
    }
    let child = kids.remove(at: fromIndex)
    kids.insert(child, at: toIndex)
    parent[PDFName("K")] = .array(kids)
    StructureEditSupport.write(parent, id: parentID, to: &graph)
    return graph
  }
}

/// P33-013: mark a supported decorative element as an artifact. Artifacts
/// carry no alternate or actual text.
public struct MarkStructureArtifactCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID

  public init(elementID: PDFObjectID) {
    self.elementID = elementID
  }

  public var name: String { "Mark as Artifact" }

  public func validate(in graph: PDFGraph) throws {
    let dictionary = try StructureEditSupport.element(elementID, in: graph)
    let role = StructureEditSupport.resolvedRole(of: dictionary, in: graph)
    guard role != "Artifact" else {
      throw PDFError(.malformed, "The element is already an artifact")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var dictionary = try StructureEditSupport.element(elementID, in: graph)
    dictionary[PDFName("S")] = .name(PDFName("Artifact"))
    dictionary.removeValue(forKey: PDFName("Alt"))
    dictionary.removeValue(forKey: PDFName("ActualText"))
    StructureEditSupport.write(dictionary, id: elementID, to: &graph)
    return graph
  }
}

/// P33-014: group sibling elements under a new grouping element, keeping
/// their relative reading order.
public struct GroupStructureElementsCommand: PDFEditCommand, Equatable, Sendable {
  public let parentID: PDFObjectID
  public let elementIDs: [PDFObjectID]
  public let role: PDFName

  public init(parentID: PDFObjectID, elementIDs: [PDFObjectID], role: PDFName = PDFName("Sect")) {
    self.parentID = parentID
    self.elementIDs = elementIDs
    self.role = role
  }

  public var name: String { "Group Structure Elements" }

  public func validate(in graph: PDFGraph) throws {
    guard elementIDs.count >= 2 else {
      throw PDFError(.malformed, "Grouping needs at least two elements")
    }
    let groupingRoles: Set<String> = ["Sect", "Div", "Part", "Art", "L", "Table", "NonStruct"]
    guard groupingRoles.contains(String(decoding: role.bytes, as: UTF8.self)) else {
      throw PDFError(.unsupported, "Grouping uses Sect, Div, Part, Art, L, Table, or NonStruct")
    }
    let parent = try StructureEditSupport.element(parentID, in: graph)
    guard case .array(let kids)? = parent[PDFName("K")] else {
      throw PDFError(.malformed, "The parent has no children")
    }
    let references = kids.compactMap { value -> PDFObjectID? in
      if case .reference(let id) = value { return id }
      return nil
    }
    for id in elementIDs {
      guard references.contains(id) else {
        throw PDFError(.malformed, "A grouped element is not a child of the parent")
      }
    }
    guard Set(elementIDs).count == elementIDs.count else {
      throw PDFError(.malformed, "Grouping lists an element twice")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var parent = try StructureEditSupport.element(parentID, in: graph)
    guard case .array(var kids)? = parent[PDFName("K")] else {
      throw PDFError(.malformed, "The parent has no children")
    }
    let grouped = Set(elementIDs)
    let groupID = StructureEditSupport.nextObjectID(in: graph)
    var group: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): .name(role),
      PDFName("P"): .reference(parentID),
      PDFName("K"): .array(elementIDs.map { .reference($0) }),
    ]
    // Inherit the page from the first grouped element when present.
    if let firstID = elementIDs.first,
      case .dictionary(let first)? = graph.objects[firstID],
      case .reference(let pageID)? = first[PDFName("Pg")]
    {
      group[PDFName("Pg")] = .reference(pageID)
    }
    graph.objects[groupID] = .dictionary(group)

    var rebuilt: [PDFValue] = []
    var inserted = false
    for value in kids {
      guard case .reference(let id) = value else {
        rebuilt.append(value)
        continue
      }
      if grouped.contains(id) {
        if !inserted {
          rebuilt.append(.reference(groupID))
          inserted = true
        }
        continue
      }
      rebuilt.append(value)
    }
    parent[PDFName("K")] = .array(rebuilt)
    StructureEditSupport.write(parent, id: parentID, to: &graph)
    return graph
  }
}

/// P33-014: split an element's children at a position into two elements of
/// the same role.
public struct SplitStructureElementCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let atIndex: Int

  public init(elementID: PDFObjectID, atIndex: Int) {
    self.elementID = elementID
    self.atIndex = atIndex
  }

  public var name: String { "Split Structure Element" }

  public func validate(in graph: PDFGraph) throws {
    let element = try StructureEditSupport.element(elementID, in: graph)
    guard case .array(let kids)? = element[PDFName("K")], kids.count >= 2,
      atIndex >= 1, atIndex < kids.count
    else {
      throw PDFError(.malformed, "The split position must leave both halves non-empty")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var element = try StructureEditSupport.element(elementID, in: graph)
    guard case .array(let kids)? = element[PDFName("K")],
      case .reference(let parentID)? = element[PDFName("P")]
    else {
      throw PDFError(.malformed, "The element has no parent or children")
    }
    let splitID = StructureEditSupport.nextObjectID(in: graph)
    var split: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("StructElem")),
      PDFName("S"): element[PDFName("S")] ?? .name(PDFName("Span")),
      PDFName("P"): .reference(parentID),
      PDFName("K"): .array(Array(kids[atIndex...])),
    ]
    if let page = element[PDFName("Pg")] { split[PDFName("Pg")] = page }
    graph.objects[splitID] = .dictionary(split)
    element[PDFName("K")] = .array(Array(kids[..<atIndex]))
    StructureEditSupport.write(element, id: elementID, to: &graph)

    // Insert the new element right after the original in the parent.
    var parent = try StructureEditSupport.element(parentID, in: graph)
    if case .array(var parentKids)? = parent[PDFName("K")] {
      var rebuilt: [PDFValue] = []
      for value in parentKids {
        rebuilt.append(value)
        if case .reference(let id) = value, id == elementID {
          rebuilt.append(.reference(splitID))
        }
      }
      parentKids = rebuilt
      parent[PDFName("K")] = .array(parentKids)
      StructureEditSupport.write(parent, id: parentID, to: &graph)
    }
    return graph
  }
}

/// P33-019: table header relationships for the supported profile: /Scope on
/// TH elements through a table attribute object.
public struct SetTableHeaderScopeCommand: PDFEditCommand, Equatable, Sendable {
  public let elementID: PDFObjectID
  public let scope: PDFName

  public init(elementID: PDFObjectID, scope: PDFName) {
    self.elementID = elementID
    self.scope = scope
  }

  public var name: String { "Set Table Header Scope" }

  public func validate(in graph: PDFGraph) throws {
    let dictionary = try StructureEditSupport.element(elementID, in: graph)
    let role = StructureEditSupport.resolvedRole(of: dictionary, in: graph)
    guard role == "TH" else {
      throw PDFError(.unsupported, "Header scope applies to TH elements")
    }
    guard ["Column", "Row", "Both"].contains(String(decoding: scope.bytes, as: UTF8.self)) else {
      throw PDFError(.malformed, "Scope is Column, Row, or Both")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    var dictionary = try StructureEditSupport.element(elementID, in: graph)
    switch dictionary[PDFName("A")] {
    case .reference(let attributesID)?:
      guard case .dictionary(var attributes)? = graph.objects[attributesID] else {
        throw PDFError(.malformed, "The attribute object is missing")
      }
      attributes[PDFName("O")] = .name(PDFName("Table"))
      attributes[PDFName("Scope")] = .name(scope)
      graph.objects[attributesID] = .dictionary(attributes)
    case .dictionary(var attributes)?:
      attributes[PDFName("O")] = .name(PDFName("Table"))
      attributes[PDFName("Scope")] = .name(scope)
      dictionary[PDFName("A")] = .dictionary(attributes)
    default:
      dictionary[PDFName("A")] = .dictionary([
        PDFName("O"): .name(PDFName("Table")),
        PDFName("Scope"): .name(scope),
      ])
    }
    StructureEditSupport.write(dictionary, id: elementID, to: &graph)
    return graph
  }
}
