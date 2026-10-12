import Foundation
import PDFCore

/// P33-001: one child of a structure element in reading order.
public enum PDFStructureChild: Sendable, Equatable {
  /// A nested structure element.
  case element(PDFStructureElement)
  /// Marked content on a page (an MCID kid).
  case content(pageIndex: Int?, mcid: Int)
  /// An object reference (annotation or form widget) through /OBJR.
  case objectReference(annotationObjectID: PDFObjectID, pageIndex: Int?)
  /// A reference that does not resolve.
  case unresolved(reference: PDFObjectID)
}

/// P33-001/P33-002/P33-007: one structure element with resolved roles and
/// presentation metadata.
public struct PDFStructureElement: Sendable, Equatable {
  public let objectID: PDFObjectID?
  public let rawRole: String
  /// The role after applying the document role map.
  public let role: String
  public let title: String?
  public let alt: String?
  public let actualText: String?
  public let language: String?
  public let classNames: [String]
  public let pageIndex: Int?
  public let parentObjectID: PDFObjectID?
  public let children: [PDFStructureChild]

  /// P33-007: the presentation grouping used by the inspector.
  public var presentationRole: String {
    switch role {
    case "H1", "H2", "H3", "H4", "H5", "H6": return "heading"
    case "P": return "paragraph"
    case "L", "LI", "LBody", "Lbl": return "list"
    case "Table", "TR", "TD", "TH", "THead", "TBody", "TFoot": return "table"
    case "Figure": return "figure"
    case "Link": return "link"
    case "Form": return "form"
    case "Span", "Quote", "Note", "Reference", "Code", "Caption": return "inline"
    case "Artifact": return "artifact"
    case "Sect", "Div", "Part", "Art", "NonStruct", "Private": return "group"
    default: return "other"
    }
  }
}

/// P33-020: a detected structure problem.
public struct PDFStructureIssue: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case danglingReference
    case orphanedElement
    case duplicateMCID
    case missingParentTreeEntry
    case unresolvedRole
    case unmarkedPage
    case missingStructureRoot
    /// P38-011: a structure element reference that would revisit an element
    /// already parsed (a cyclic or repeated structure tree).
    case cyclicReference
  }

  public let kind: Kind
  public let objectID: PDFObjectID?
  public let pageIndex: Int?
  public let message: String
}

/// P33-001–P33-005: the structure tree inventory with reading order, role and
/// class maps, ParentTree resolution, MCID-to-content mapping, and object
/// references.
public struct PDFStructureInventory: Sendable, Equatable {
  public let rootObjectID: PDFObjectID?
  public let roleMap: [String: String]
  public let classMap: [String: [PDFName: PDFValue]]
  public let elements: [PDFStructureElement]
  public let parentTreeKeys: [Int]
  /// Per page: the StructParents key when present.
  public let pageStructParents: [Int?]
  /// Per page: marked-content IDs in content order.
  public let pageMCIDs: [[Int]]
  public let issues: [PDFStructureIssue]
  public let hasMarkInfo: Bool
  public let language: String?
  public let isTagged: Bool

  public func elements(pageIndex: Int) -> [PDFStructureElement] {
    elements.filter { $0.pageIndex == pageIndex }
  }
}

public enum PDFStructureInspector {
  /// Standard structure roles this profile recognizes (P33-007/P33-030).
  public static let standardRoles: Set<String> = [
    "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI",
    "Index", "NonStruct", "Private", "P", "H", "H1", "H2", "H3", "H4", "H5", "H6",
    "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot",
    "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby",
    "Warichu", "Figure", "Formula", "Form", "Artifact",
  ]

  public static func inspect(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> PDFStructureInventory {
    var issues: [PDFStructureIssue] = []
    var roleMap: [String: String] = [:]
    var classMap: [String: [PDFName: PDFValue]] = [:]
    var elements: [PDFStructureElement] = []
    var rootObjectID: PDFObjectID?
    var parentTreeEntries: [Int: PDFValue] = [:]
    var language: String?
    var hasMarkInfo = false

    func resolved(_ value: PDFValue?) -> PDFValue? {
      guard let value else { return nil }
      if case .reference(let id) = value { return graph.objects[id] }
      return value
    }

    func string(_ value: PDFValue?) -> String? {
      guard case .string(let data)? = resolved(value) else { return nil }
      if data.count >= 2, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF {
        return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
      }
      return String(decoding: data, as: UTF8.self)
    }

    func name(_ value: PDFValue?) -> String? {
      guard case .name(let name)? = resolved(value) else { return nil }
      return String(decoding: name.bytes, as: UTF8.self)
    }

    // P33-003: number-tree resolution for /ParentTree.
    func numberTree(_ value: PDFValue?, depth: Int = 0) -> [Int: PDFValue] {
      guard depth <= limits.nesting, case .dictionary(let dictionary)? = resolved(value) else {
        return [:]
      }
      var result: [Int: PDFValue] = [:]
      if case .array(let numbers)? = dictionary[PDFName("Nums")] {
        var index = 0
        while index + 1 < numbers.count {
          if case .integer(let key) = numbers[index], let int = Int(exactly: key) {
            result[int] = numbers[index + 1]
          }
          index += 2
        }
      }
      if case .array(let kids)? = dictionary[PDFName("Kids")] {
        for kid in kids { result.merge(numberTree(kid, depth: depth + 1)) { _, new in new } }
      }
      return result
    }

    // Catalog: structure root, MarkInfo, language.
    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    {
      if case .dictionary(let markInfo)? = resolved(catalog[PDFName("MarkInfo")]),
        case .boolean(let marked)? = markInfo[PDFName("Marked")]
      {
        hasMarkInfo = marked
      }
      language = string(catalog[PDFName("Lang")])
      if case .reference(let structID)? = catalog[PDFName("StructTreeRoot")] {
        rootObjectID = structID
      } else if case .dictionary(let direct)? = catalog[PDFName("StructTreeRoot")] {
        _ = direct
        // Direct roots are not addressable; keep the inventory usable.
        rootObjectID = nil
      }
    }

    if let rootObjectID, case .dictionary(let root)? = graph.objects[rootObjectID] {
      if case .dictionary(let map)? = resolved(root[PDFName("RoleMap")]) {
        for (key, value) in map {
          if let target = name(value) {
            roleMap[String(decoding: key.bytes, as: UTF8.self)] = target
          }
        }
      }
      if case .dictionary(let map)? = resolved(root[PDFName("ClassMap")]) {
        for (key, value) in map {
          if case .dictionary(let attributes)? = resolved(value) {
            classMap[String(decoding: key.bytes, as: UTF8.self)] = attributes
          }
        }
      }
      parentTreeEntries = numberTree(root[PDFName("ParentTree")])
    } else if hasMarkInfo {
      issues.append(
        PDFStructureIssue(
          kind: .missingStructureRoot, objectID: nil, pageIndex: nil,
          message: "The document is marked but has no StructTreeRoot"))
    }

    // Per-page StructParents and marked-content IDs (P33-004).
    var pageStructParents: [Int?] = []
    var pageMCIDs: [[Int]] = []
    for (index, pageID) in pageIDs.enumerated() {
      var key: Int?
      if case .dictionary(let page)? = graph.objects[pageID],
        case .integer(let raw)? = page[PDFName("StructParents")]
      {
        key = Int(exactly: raw)
      }
      pageStructParents.append(key)
      var mcids: [Int] = []
      if let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits) {
        for instruction in content.instructions where instruction.operatorName == "BDC" {
          guard let properties = instruction.operands.last?.value,
            case .dictionary(let dictionary) = properties,
            case .integer(let raw)? = dictionary[PDFName("MCID")],
            let mcid = Int(exactly: raw)
          else { continue }
          mcids.append(mcid)
        }
      }
      pageMCIDs.append(mcids)
      if mcids.isEmpty, key != nil, rootObjectID != nil {
        issues.append(
          PDFStructureIssue(
            kind: .unmarkedPage, objectID: pageID, pageIndex: index,
            message: "Page \(index + 1) declares StructParents but has no marked content"))
      }
      if key != nil, let key, parentTreeEntries[key] == nil, rootObjectID != nil {
        issues.append(
          PDFStructureIssue(
            kind: .missingParentTreeEntry, objectID: pageID, pageIndex: index,
            message: "Page \(index + 1) StructParents key \(key) has no ParentTree entry"))
      }
      let duplicates = Dictionary(grouping: mcids, by: { $0 }).filter { $0.value.count > 1 }
      for (mcid, _) in duplicates {
        issues.append(
          PDFStructureIssue(
            kind: .duplicateMCID, objectID: pageID, pageIndex: index,
            message: "Page \(index + 1) repeats MCID \(mcid)"))
      }
    }

    func pageIndex(for pageReference: PDFValue?) -> Int? {
      guard case .reference(let id)? = pageReference else { return nil }
      return pageIDs.firstIndex(of: id)
    }

    func resolvedRole(_ rawRole: String) -> String {
      var role = rawRole
      var hops = 0
      while let mapped = roleMap[role], hops < 8 {
        role = mapped
        hops += 1
      }
      return role
    }

    // P33-001/P33-002/P33-005: recursive element parsing.
    func parseElement(
      value: PDFValue, parentObjectID: PDFObjectID?, inheritedPageIndex: Int?, depth: Int,
      ancestors: Set<PDFObjectID>
    ) -> PDFStructureElement? {
      guard depth <= limits.nesting else { return nil }
      let dictionary: [PDFName: PDFValue]
      let objectID: PDFObjectID?
      switch value {
      case .reference(let id):
        guard case .dictionary(let resolved)? = graph.objects[id] else {
          issues.append(
            PDFStructureIssue(
              kind: .danglingReference, objectID: id, pageIndex: nil,
              message: "A structure reference does not resolve"))
          return nil
        }
        // P38-011: a reference that revisits an element on the current path is
        // a cyclic structure tree and must not recurse again.
        guard !ancestors.contains(id) else {
          issues.append(
            PDFStructureIssue(
              kind: .cyclicReference, objectID: id, pageIndex: nil,
              message: "A structure element reference revisits an element on its own path"))
          return nil
        }
        dictionary = resolved
        objectID = id
      case .dictionary(let direct):
        dictionary = direct
        objectID = nil
      default:
        return nil
      }
      let rawRole = name(dictionary[PDFName("S")]) ?? "Unknown"
      let role = resolvedRole(rawRole)
      if !standardRoles.contains(role) {
        issues.append(
          PDFStructureIssue(
            kind: .unresolvedRole, objectID: objectID, pageIndex: nil,
            message: "Role \(rawRole) does not resolve to a standard role"))
      }
      var classNames: [String] = []
      if let single = name(dictionary[PDFName("C")]) {
        classNames = [single]
      } else if case .array(let values)? = dictionary[PDFName("C")] {
        classNames = values.compactMap { name($0) }
      }
      let elementPageIndex = pageIndex(for: dictionary[PDFName("Pg")]) ?? inheritedPageIndex
      if let pageReference = dictionary[PDFName("Pg")], elementPageIndex == nil {
        issues.append(
          PDFStructureIssue(
            kind: .orphanedElement, objectID: objectID, pageIndex: nil,
            message: "A structure element references a page that is not in the document"))
      }

      var children: [PDFStructureChild] = []
      let childAncestors = objectID.map { ancestors.union([$0]) } ?? ancestors
      func appendChild(_ childValue: PDFValue) {
        switch childValue {
        case .integer(let raw):
          if let mcid = Int(exactly: raw) {
            children.append(.content(pageIndex: elementPageIndex, mcid: mcid))
          }
        case .reference(let id):
          if case .dictionary(let target)? = graph.objects[id] {
            if target[PDFName("Type")] == .name(PDFName("OBJR")) {
              if case .reference(let object)? = target[PDFName("Obj")] {
                children.append(
                  .objectReference(
                    annotationObjectID: object, pageIndex: pageIndex(for: target[PDFName("Pg")])))
              }
            } else if target[PDFName("Subtype")] != nil, target[PDFName("S")] == nil {
              // A direct annotation reference (older style).
              children.append(
                .objectReference(
                  annotationObjectID: id, pageIndex: pageIndex(for: target[PDFName("Pg")])))
            } else if let element = parseElement(
              value: childValue, parentObjectID: objectID, inheritedPageIndex: elementPageIndex,
              depth: depth + 1, ancestors: childAncestors)
            {
              children.append(.element(element))
            }
          } else {
            children.append(.unresolved(reference: id))
            issues.append(
              PDFStructureIssue(
                kind: .danglingReference, objectID: id, pageIndex: nil,
                message: "A /K reference does not resolve"))
          }
        case .dictionary(let dictionary):
          if dictionary[PDFName("Type")] == .name(PDFName("MCR")) {
            if case .integer(let raw)? = dictionary[PDFName("MCID")],
              let mcid = Int(exactly: raw)
            {
              children.append(
                .content(pageIndex: pageIndex(for: dictionary[PDFName("Pg")]), mcid: mcid))
            }
          } else if dictionary[PDFName("Type")] == .name(PDFName("OBJR")) {
            if case .reference(let object)? = dictionary[PDFName("Obj")] {
              children.append(
                .objectReference(
                  annotationObjectID: object, pageIndex: pageIndex(for: dictionary[PDFName("Pg")])))
            }
          } else if let element = parseElement(
            value: childValue, parentObjectID: objectID, inheritedPageIndex: elementPageIndex,
            depth: depth + 1, ancestors: childAncestors)
          {
            children.append(.element(element))
          }
        default:
          break
        }
      }
      switch dictionary[PDFName("K")] {
      case .array(let values)?:
        for value in values { appendChild(value) }
      case let value?:
        appendChild(value)
      default:
        break
      }

      return PDFStructureElement(
        objectID: objectID, rawRole: rawRole, role: role,
        title: string(dictionary[PDFName("T")]), alt: string(dictionary[PDFName("Alt")]),
        actualText: string(dictionary[PDFName("ActualText")]),
        language: string(dictionary[PDFName("Lang")]), classNames: classNames,
        pageIndex: elementPageIndex, parentObjectID: parentObjectID, children: children)
    }

    if let rootObjectID, case .dictionary(let root)? = graph.objects[rootObjectID] {
      func walk(_ value: PDFValue, depth: Int, ancestors: Set<PDFObjectID>) {
        guard depth <= limits.nesting else { return }
        switch value {
        case .array(let values):
          for value in values { walk(value, depth: depth + 1, ancestors: ancestors) }
        case .reference, .dictionary:
          guard let element = parseElement(
            value: value, parentObjectID: rootObjectID, inheritedPageIndex: nil, depth: depth,
            ancestors: ancestors)
          else { return }
          elements.append(element)
          let childAncestors =
            element.objectID.map { ancestors.union([$0]) } ?? ancestors
          for child in element.children {
            if case .element(let nested) = child {
              walk(
                .reference(nested.objectID ?? PDFObjectID(0)), depth: depth + 1,
                ancestors: childAncestors)
            }
          }
        default:
          break
        }
      }
      switch root[PDFName("K")] {
      case .array(let values)?:
        for value in values { walk(value, depth: 0, ancestors: []) }
      case let value?:
        walk(value, depth: 0, ancestors: [])
      default:
        break
      }
    }

    // P33-003: ParentTree entries must resolve; MCID entries must match page
    // content.
    for (key, value) in parentTreeEntries {
      let entries: [PDFValue]
      if case .array(let values) = value { entries = values } else { entries = [value] }
      for (index, entry) in entries.enumerated() {
        guard case .reference(let id) = entry else { continue }
        if graph.objects[id] == nil {
          issues.append(
            PDFStructureIssue(
              kind: .danglingReference, objectID: id, pageIndex: nil,
              message: "ParentTree key \(key) references a missing object"))
          continue
        }
        if let pageIndex = pageStructParents.firstIndex(of: key),
          pageIndex < pageMCIDs.count,
          !pageMCIDs[pageIndex].contains(index)
        {
          issues.append(
            PDFStructureIssue(
              kind: .missingParentTreeEntry, objectID: id, pageIndex: pageIndex,
              message: "ParentTree key \(key) index \(index) has no matching MCID"))
        }
      }
    }

    // P33-005: annotation and widget StructParent links.
    for (index, pageID) in pageIDs.enumerated() {
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations {
        guard case .integer(let raw)? = annotation.dictionary[PDFName("StructParent")],
          let key = Int(exactly: raw)
        else { continue }
        if parentTreeEntries[key] == nil {
          issues.append(
            PDFStructureIssue(
              kind: .missingParentTreeEntry, objectID: annotation.objectID, pageIndex: index,
              message: "An annotation references StructParent \(key) with no ParentTree entry"))
        }
      }
    }

    return PDFStructureInventory(
      rootObjectID: rootObjectID, roleMap: roleMap, classMap: classMap, elements: elements,
      parentTreeKeys: parentTreeEntries.keys.sorted(), pageStructParents: pageStructParents,
      pageMCIDs: pageMCIDs, issues: issues, hasMarkInfo: hasMarkInfo, language: language,
      isTagged: rootObjectID != nil || hasMarkInfo)
  }
}

/// P33-018/P33-021: a bounded structure repair with an explicit report.
public struct PDFStructureRepairReport: Sendable, Equatable {
  public let removedKids: Int
  public let removedElements: Int
  public let removedParentTreeEntries: Int
  public let transformations: [String]

  public var isEmpty: Bool {
    removedKids == 0 && removedElements == 0 && removedParentTreeEntries == 0
  }

  public var summary: String {
    transformations.isEmpty ? "no changes" : transformations.joined(separator: ", ")
  }
}

public enum PDFStructureRepair {
  /// P33-021: remove dangling references, elements whose page no longer
  /// exists, and ParentTree entries that no longer resolve; the ParentTree is
  /// rebuilt compactly from the surviving entries.
  public static func pruneDangling(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: PDFStructureRepairReport) {
    try repair(
      graph: graph, pageIDs: pageIDs, limits: limits, pruneMissingMCIDs: false, removingPages: [])
  }

  /// P33-015/P33-016/P33-027: remove structure references to content that no
  /// longer exists on the pages (removed marked content after redaction or
  /// page removal), including the /Alt and /ActualText of emptied elements.
  public static func pruneRemovedContent(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: PDFStructureRepairReport) {
    try repair(
      graph: graph, pageIDs: pageIDs, limits: limits, pruneMissingMCIDs: true, removingPages: [])
  }

  /// P33-016: remove every structure reference to a page that is about to be
  /// deleted, so the deletion preflight passes and no dangling references
  /// remain.
  public static func pruneReferences(
    toPage pageID: PDFObjectID, in graph: PDFGraph, pageIDs: [PDFObjectID],
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: PDFStructureRepairReport) {
    try repair(
      graph: graph, pageIDs: pageIDs, limits: limits, pruneMissingMCIDs: false,
      removingPages: [pageID])
  }

  static func repair(
    graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits, pruneMissingMCIDs: Bool,
    removingPages: Set<PDFObjectID>
  ) throws -> (graph: PDFGraph, report: PDFStructureRepairReport) {
    var graph = graph
    var removedKids = 0
    var removedElements = 0
    var removedParentTreeEntries = 0

    // Live MCIDs per page: a marked-content sequence only counts as live
    // when it still contains visible or text content. Redaction empties the
    // text inside a sequence, which must then not survive in the structure.
    func instructionCarriesContent(_ instruction: ContentInstruction) -> Bool {
      switch instruction.operatorName {
      case "Tj", "'", "\"":
        return instruction.operands.contains { operand in
          if case .string(let data) = operand.value { return !data.isEmpty }
          return false
        }
      case "TJ":
        return instruction.operands.contains { operand in
          guard case .array(let values) = operand.value else { return false }
          return values.contains { value in
            if case .string(let data) = value { return !data.isEmpty }
            return false
          }
        }
      case "Do", "sh", "f", "F", "f*", "S", "s", "B", "B*", "b", "b*", "re":
        return true
      default:
        return instruction.isInlineImage
      }
    }

    var liveMCIDs: [PDFObjectID: Set<Int>] = [:]
    for pageID in pageIDs {
      var live: Set<Int> = []
      if let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits) {
        var stack: [(mcid: Int?, hasContent: Bool)] = []
        for instruction in content.instructions {
          switch instruction.operatorName {
          case "BDC", "BMC":
            var mcid: Int?
            if case .dictionary(let dictionary)? = instruction.operands.last?.value,
              case .integer(let raw)? = dictionary[PDFName("MCID")],
              let value = Int(exactly: raw)
            {
              mcid = value
            }
            stack.append((mcid, false))
          case "EMC":
            if let top = stack.popLast(), let mcid = top.mcid, top.hasContent {
              live.insert(mcid)
            }
          default:
            if instructionCarriesContent(instruction) {
              for index in stack.indices { stack[index].hasContent = true }
            }
          }
        }
        for top in stack {
          if let mcid = top.mcid, top.hasContent { live.insert(mcid) }
        }
      }
      liveMCIDs[pageID] = live
    }

    func resolvePageID(_ value: PDFValue?) -> PDFObjectID? {
      guard case .reference(let id)? = value, pageIDs.contains(id) else { return nil }
      return id
    }

    // Prune element kids depth-first; returns whether the element survives.
    func pruneElement(_ id: PDFObjectID, depth: Int) -> Bool {
      guard depth <= limits.nesting, case .dictionary(var dictionary)? = graph.objects[id] else {
        return false
      }
      if let pageReference = dictionary[PDFName("Pg")],
        case .reference(let pageID) = pageReference,
        !pageIDs.contains(pageID) || removingPages.contains(pageID)
      {
        return false
      }
      var keptKids: [PDFValue] = []
      var kidRemoved = false
      func keep(_ value: PDFValue) -> Bool {
        switch value {
        case .integer(let raw):
          guard pruneMissingMCIDs, let mcid = Int(exactly: raw) else { return true }
          guard let pageID = resolvePageID(dictionary[PDFName("Pg")]),
            let live = liveMCIDs[pageID]
          else { return true }
          if !live.contains(mcid) {
            kidRemoved = true
            return false
          }
          return true
        case .reference(let childID):
          guard case .dictionary(let target)? = graph.objects[childID] else {
            kidRemoved = true
            return false
          }
          if target[PDFName("Type")] == .name(PDFName("OBJR"))
            || (target[PDFName("Subtype")] != nil && target[PDFName("S")] == nil)
          {
            return true
          }
          if pruneElement(childID, depth: depth + 1) {
            return true
          }
          kidRemoved = true
          return false
        case .dictionary(let direct):
          if direct[PDFName("Type")] == .name(PDFName("MCR")),
            case .integer(let raw)? = direct[PDFName("MCID")],
            pruneMissingMCIDs, let mcid = Int(exactly: raw),
            let pageID = resolvePageID(direct[PDFName("Pg")] ?? dictionary[PDFName("Pg")]),
            let live = liveMCIDs[pageID], !live.contains(mcid)
          {
            kidRemoved = true
            return false
          }
          return true
        default:
          return true
        }
      }
      switch dictionary[PDFName("K")] {
      case .array(let values)?:
        keptKids = values.filter { keep($0) }
        dictionary[PDFName("K")] = .array(keptKids)
      case let value?:
        if keep(value) {
          keptKids = [value]
        } else {
          dictionary[PDFName("K")] = .array([])
        }
      default:
        keptKids = []
      }
      if kidRemoved { removedKids += 1 }
      // An element that lost all of its content is removed (its /Alt and
      // /ActualText must not survive the content).
      let isLeafRole = !["Document", "Part", "Art", "Sect", "Div", "L", "LI", "LBody", "Table", "TR", "TBody", "THead", "TFoot", "TOC"].contains(
        String(decoding: (dictionary[PDFName("S")].flatMap { value -> [UInt8]? in
          if case .name(let name) = value { return name.bytes }
          return nil
        }) ?? [], as: UTF8.self))
      if keptKids.isEmpty, pruneMissingMCIDs, isLeafRole,
        dictionary[PDFName("Alt")] != nil || dictionary[PDFName("ActualText")] != nil
          || dictionary[PDFName("S")] != nil
      {
        return false
      }
      graph.objects[id] = .dictionary(dictionary)
      return true
    }

    if case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID],
      case .reference(let structID)? = catalog[PDFName("StructTreeRoot")],
      case .dictionary(var root)? = graph.objects[structID]
    {
      switch root[PDFName("K")] {
      case .array(let values)?:
        var kept: [PDFValue] = []
        for value in values {
          guard case .reference(let id) = value, graph.objects[id] != nil else {
            removedElements += 1
            continue
          }
          if pruneElement(id, depth: 0) {
            kept.append(value)
          } else {
            removedElements += 1
          }
        }
        root[PDFName("K")] = .array(kept)
      default:
        break
      }
      // ParentTree: drop entries that reference missing objects.
      if case .reference(let parentTreeID)? = root[PDFName("ParentTree")],
        case .dictionary(var parentTree)? = graph.objects[parentTreeID],
        case .array(let numbers)? = parentTree[PDFName("Nums")]
      {
        var keptNumbers: [PDFValue] = []
        var index = 0
        while index + 1 < numbers.count {
          let key = numbers[index]
          let value = numbers[index + 1]
          let entries: [PDFValue]
          if case .array(let values) = value { entries = values } else { entries = [value] }
          let survivors = entries.filter { entry in
            guard case .reference(let id) = entry else { return true }
            return graph.objects[id] != nil
          }
          if survivors.isEmpty {
            removedParentTreeEntries += 1
          } else {
            keptNumbers.append(key)
            keptNumbers.append(survivors.count == 1 ? survivors[0] : .array(survivors))
          }
          index += 2
        }
        parentTree[PDFName("Nums")] = .array(keptNumbers)
        graph.objects[parentTreeID] = .dictionary(parentTree)
      }
      graph.objects[structID] = .dictionary(root)
    }

    var transformations: [String] = []
    if removedKids > 0 { transformations.append("removed \(removedKids) dangling kids") }
    if removedElements > 0 { transformations.append("removed \(removedElements) elements") }
    if removedParentTreeEntries > 0 {
      transformations.append("removed \(removedParentTreeEntries) ParentTree entries")
    }
    return (
      graph,
      PDFStructureRepairReport(
        removedKids: removedKids, removedElements: removedElements,
        removedParentTreeEntries: removedParentTreeEntries, transformations: transformations)
    )
  }
}
