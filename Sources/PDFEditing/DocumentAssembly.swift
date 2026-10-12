import Foundation
import PDFCore

/// P23-024: page-range parsing with physical indices, reversed ranges, and
/// validation. 1-based in the input, 0-based indices out.
public enum PageRange {
  public static func parse(_ text: String, pageCount: Int) -> [Int] {
    guard pageCount > 0 else { return [] }
    var result: [Int] = []
    var seen: Set<Int> = []
    for token in text.split(separator: ",") {
      let trimmed = token.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
      func index(_ value: Substring) -> Int? {
        guard let number = Int(value), number >= 1 else { return nil }
        return min(number, pageCount) - 1
      }
      var indices: [Int] = []
      switch parts.count {
      case 1:
        guard let single = index(parts[0]) else { continue }
        indices = [single]
      case 2:
        guard !parts[0].isEmpty || !parts[1].isEmpty else { continue }
        let lower = parts[0].isEmpty ? 1 : (Int(parts[0]) ?? 0)
        let upper = parts[1].isEmpty ? pageCount : (Int(parts[1]) ?? 0)
        guard lower >= 1, upper >= 1 else { continue }
        let start = min(max(min(lower, upper), 1), pageCount) - 1
        let end = min(max(max(lower, upper), 1), pageCount) - 1
        indices = Array(start...end)
      default:
        continue
      }
      for index in indices where !seen.contains(index) {
        seen.insert(index)
        result.append(index)
      }
    }
    return result
  }
}

/// P23-008–P23-022: the result of an assembly operation.
public struct DocumentAssemblyReport: Sendable, Equatable {
  public var remappedObjects: Int = 0
  public var deduplicatedObjects: Int = 0
  public var renamedFields: [String] = []
  public var droppedDestinations: Int = 0
  public var droppedOutlines: Int = 0
  public var notes: [String] = []
  public var isEditable: Bool = true

  public init() {}

  public func report() -> String {
    var lines = [
      "Document assembly — \(remappedObjects) object\(remappedObjects == 1 ? "" : "s") remapped"
    ]
    if deduplicatedObjects > 0 {
      lines.append("  Deduplicated \(deduplicatedObjects) identical object(s).")
    }
    if !renamedFields.isEmpty {
      lines.append("  Renamed fields: \(renamedFields.joined(separator: ", "))")
    }
    if droppedDestinations > 0 {
      lines.append("  Dropped \(droppedDestinations) destination(s) whose targets did not survive.")
    }
    if droppedOutlines > 0 {
      lines.append("  Dropped \(droppedOutlines) outline entr\(droppedOutlines == 1 ? "y" : "ies").")
    }
    for note in notes { lines.append("  note: \(note)") }
    return lines.joined(separator: "\n")
  }
}

/// P23: page duplication, crop-box editing, extraction/splitting, and merging
/// with collision-free object remapping. The source graphs are never modified.
public enum DocumentAssembly {
  /// P23-021: how catalog-level data (attachments/name trees, XMP metadata)
  /// is treated. `firstDocument` carries the first source's self-contained
  /// data by remapping it; other sources' catalog data is reported as dropped.
  public enum CatalogDataPolicy: String, Sendable, Equatable {
    case none
    case firstDocument
  }

  /// P23-014: what happens to page labels when pages are assembled.
  public enum LabelPolicy: String, Sendable, Equatable {
    /// Keep the surviving ranges (start indices are shifted for extraction).
    case preserve
    /// Start a fresh decimal numbering.
    case reset
  }

  /// P23-003: duplicate a page after itself. Resources are shared by default;
  /// `duplicateResources` shallow-copies the resources dictionary so the copy
  /// can be edited independently.
  public static func duplicatePage(
    _ pageID: PDFObjectID, in graph: PDFGraph, duplicateResources: Bool = false,
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, newPageID: PDFObjectID) {
    var graph = graph
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let pageIDs = try PDFPageTree.pageIDs(in: graph)
    guard let index = pageIDs.firstIndex(of: pageID) else {
      throw PDFError(.malformed, "Page is not reachable from the page tree")
    }
    let newPageID = nextObjectID(in: graph)
    var copy = page
    if duplicateResources, let resources = page[PDFName("Resources")] {
      switch resources {
      case .dictionary(let dictionary):
        let newResourcesID = PDFObjectID(newPageID.number + 1)
        graph.objects[newResourcesID] = .dictionary(dictionary)
        copy[PDFName("Resources")] = .reference(newResourcesID)
      case .reference(let id):
        guard case .dictionary(let dictionary)? = graph.objects[id] else {
          throw PDFError(.malformed, "Page resources are missing")
        }
        let newResourcesID = PDFObjectID(newPageID.number + 1)
        graph.objects[newResourcesID] = .dictionary(dictionary)
        copy[PDFName("Resources")] = .reference(newResourcesID)
      default:
        break
      }
    }
    graph.objects[newPageID] = .dictionary(copy)
    // Insert after the original page and repair counts on every ancestor.
    guard case .reference(let parentID)? = copy[PDFName("Parent")],
      case .dictionary(var parent)? = graph.objects[parentID],
      case .array(var kids)? = parent[PDFName("Kids")]
    else {
      throw PDFError(.malformed, "The page's parent tree node is malformed")
    }
    let position = min(index + 1, kids.count)
    kids.insert(.reference(newPageID), at: position)
    parent[PDFName("Kids")] = .array(kids)
    graph.objects[parentID] = .dictionary(parent)
    try repairCounts(from: parentID, in: &graph, limits: limits)
    return (graph, newPageID)
  }

  /// P23-006/P23-007: set the CropBox (non-destructive; content and pixels are
  /// untouched — this is not redaction).
  public static func setCropBox(
    _ box: [Double], pageID: PDFObjectID, in graph: PDFGraph
  ) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    guard box.count == 4, box[2] > box[0], box[3] > box[1] else {
      throw PDFError(.malformed, "The crop box is empty")
    }
    let media = DocumentInventoryBox.mediaBox(of: page, in: graph)
    guard box[0] >= media[0] - 0.5, box[1] >= media[1] - 0.5,
      box[2] <= media[2] + 0.5, box[3] <= media[3] + 0.5
    else {
      throw PDFError(.malformed, "The crop box must stay inside the MediaBox")
    }
    page[PDFName("CropBox")] = .array(box.map { .real($0) })
    graph.objects[pageID] = .dictionary(page)
    return graph
  }

  /// P23-008/P23-009: extract the selected pages into a new document. Content,
  /// annotations, and resources come along; destinations and outlines are
  /// remapped when their targets survive and dropped (with a report) when they
  /// do not.
  public static func extract(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], labels: LabelPolicy = .preserve,
    catalogData: CatalogDataPolicy = .firstDocument, limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: DocumentAssemblyReport) {
    try assemble(
      sources: [(graph: graph, pageIDs: pageIDs)], labels: labels,
      catalogData: catalogData, limits: limits)
  }

  /// P23-010: merge documents in the given order with collision-free object
  /// remapping. P23-022: encrypted or signed inputs are refused.
  public static func merge(
    _ sources: [(graph: PDFGraph, pageIDs: [PDFObjectID])], labels: LabelPolicy = .reset,
    catalogData: CatalogDataPolicy = .firstDocument, limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: DocumentAssemblyReport) {
    guard !sources.isEmpty else {
      throw PDFError(.malformed, "No documents were given to merge")
    }
    for source in sources {
      if source.graph.trailer[PDFName("Encrypt")] != nil {
        throw PDFError(.unsupported, "Encrypted documents must be unlocked before merging")
      }
      let signatures = (try? PDFSignatureInventory.signatures(in: source.graph)) ?? []
      if !signatures.isEmpty {
        throw PDFError(.unsupported, "Signed documents cannot be merged without invalidating signatures")
      }
    }
    return try assemble(
      sources: sources, labels: labels, catalogData: catalogData, limits: limits)
  }

  // MARK: - Core assembly

  static func assemble(
    sources: [(graph: PDFGraph, pageIDs: [PDFObjectID])], labels: LabelPolicy,
    catalogData: CatalogDataPolicy = .firstDocument, limits: PDFLimits
  ) throws -> (graph: PDFGraph, report: DocumentAssemblyReport) {
    var report = DocumentAssemblyReport()
    var objects: [PDFObjectID: PDFValue] = [:]
    var nextNumber = 1
    var kids: [PDFValue] = []
    var pageIndexMap: [Int: [PDFObjectID: PDFObjectID]] = [:]
    var combinedPageCount = 0
    var firstCatalog: [PDFName: PDFValue]?
    var assignedFieldNames: Set<String> = []

    // Reserve 1 = catalog, 2 = pages.
    nextNumber = 3

    for (sourceIndex, source) in sources.enumerated() {
      try Task.checkCancellation()
      var remap: [PDFObjectID: PDFObjectID] = [:]
      var reverseRemap: [PDFObjectID: PDFObjectID] = [:]
      let selectedPages = Set(source.pageIDs)
      // Pre-assign page identities so destinations that point forward in the
      // selection resolve regardless of processing order.
      for pageID in source.pageIDs {
        guard nextNumber <= limits.objects else {
          throw PDFError(.limitExceeded, "The merged document exceeds the object limit")
        }
        remap[pageID] = PDFObjectID(nextNumber)
        nextNumber += 1
      }
      // P23-012: dedupe only demonstrably identical objects (exact dictionary
      // and bytes) within this assembly.
      var dedupe: [String: PDFObjectID] = [:]
      var indexMap: [PDFObjectID: PDFObjectID] = [:]

      func fingerprint(_ value: PDFValue) -> String? {
        guard case .stream(let stream) = value else { return nil }
        var hasher = StableHasher()
        hasher.combine(stream.bytes)
        for key in stream.dictionary.keys.sorted(by: { $0.bytes.count < $1.bytes.count }) {
          hasher.combine(String(decoding: key.bytes, as: UTF8.self))
        }
        return hasher.hexDigest + "-\(stream.bytes.count)"
      }

      func remapValue(_ value: PDFValue, depth: Int) throws -> PDFValue {
        guard depth <= limits.nesting else {
          throw PDFError(.limitExceeded, "Assembly exceeds the nesting limit")
        }
        switch value {
        case .reference(let id):
          guard let newID = try remapObject(id, depth: depth + 1) else {
            // A page that was not selected is dropped, not copied.
            report.droppedDestinations += 1
            return .null
          }
          return .reference(newID)
        case .array(let values):
          return .array(try values.map { try remapValue($0, depth: depth + 1) })
        case .dictionary(let dictionary):
          var result: [PDFName: PDFValue] = [:]
          for (key, value) in dictionary {
            result[key] = try remapValue(value, depth: depth + 1)
          }
          // Link actions whose destination page did not survive are removed
          // rather than left dangling.
          if case .array(let destination)? = result[PDFName("Dest")],
            case .null = destination.first ?? .null
          {
            result[PDFName("Dest")] = nil
            report.droppedDestinations += 1
          }
          if case .dictionary(let action)? = result[PDFName("A")],
            action[PDFName("S")] == .name(PDFName("GoTo")),
            case .array(let destination)? = action[PDFName("D")],
            case .null = destination.first ?? .null
          {
            result[PDFName("A")] = nil
            report.droppedDestinations += 1
          }
          return .dictionary(result)
        case .stream(let stream):
          let dictionary = try remapValue(.dictionary(stream.dictionary), depth: depth + 1)
          guard case .dictionary(let remappedDictionary) = dictionary else {
            throw PDFError(.malformed, "Stream dictionary remap failed")
          }
          return .stream(PDFStream(dictionary: remappedDictionary, bytes: stream.bytes))
        default:
          return value
        }
      }

      func remapObject(_ id: PDFObjectID, depth: Int) throws -> PDFObjectID? {
        if let existing = remap[id] { return existing }
        // Pages are only carried when they were explicitly selected.
        if case .dictionary(let sourceObject)? = source.graph.objects[id],
          sourceObject[PDFName("Type")] == .name(PDFName("Page")),
          !selectedPages.contains(id)
        {
          return nil
        }
        guard case .stream(let stream)? = source.graph.objects[id],
          let key = fingerprint(.stream(stream)),
          let deduplicated = dedupe[key]
        else {
          return try allocate(id, depth: depth)
        }
        remap[id] = deduplicated
        report.deduplicatedObjects += 1
        return deduplicated
      }

      func allocate(_ id: PDFObjectID, depth: Int) throws -> PDFObjectID? {
        guard depth <= limits.nesting else {
          throw PDFError(.limitExceeded, "Assembly exceeds the nesting limit")
        }
        guard case .some(let value) = source.graph.objects[id] else { return nil }
        guard nextNumber <= limits.objects else {
          throw PDFError(.limitExceeded, "The merged document exceeds the object limit")
        }
        let newID = PDFObjectID(nextNumber)
        nextNumber += 1
        remap[id] = newID
        reverseRemap[newID] = id
        let remapped = try remapValue(value, depth: depth + 1)
        objects[newID] = remapped
        if case .stream = value, let key = fingerprint(value) {
          dedupe[key] = newID
        }
        report.remappedObjects += 1
        return newID
      }

      for pageID in source.pageIDs {
        try Task.checkCancellation()
        guard case .dictionary(let page)? = source.graph.objects[pageID] else {
          throw PDFError(.malformed, "A selected page is missing")
        }
        var newPage = page
        // Page-tree links are rebuilt below; drop the source parent.
        newPage[PDFName("Parent")] = nil
        guard let newPageID = remap[pageID] else {
          throw PDFError(.malformed, "A selected page has no assembly identity")
        }
        reverseRemap[newPageID] = pageID
        for (key, value) in page where key != PDFName("Parent") {
          newPage[key] = try remapValue(value, depth: 0)
        }
        // P23-018/P23-019: widgets keep their page association; field-name
        // collisions across sources are renamed with a suffix.
        if case .array(let annotations)? = newPage[PDFName("Annots")] {
          var keptAnnotations: [PDFValue] = []
          for (annotationIndex, annotation) in annotations.enumerated() {
            guard case .reference(let annotationID) = annotation,
              case .dictionary(var dictionary)? = objects[annotationID]
            else {
              keptAnnotations.append(annotation)
              continue
            }
            // A link whose destination page did not survive loses its target
            // and is removed rather than left inert (P23-015/P23-017).
            if dictionary[PDFName("Subtype")] == .name(PDFName("Link")) {
              let sourceHadTarget: Bool
              if let sourceAnnotationID = reverseRemap[annotationID],
                case .dictionary(let sourceDictionary)? = source.graph.objects[
                  sourceAnnotationID] {
                sourceHadTarget = sourceDictionary[PDFName("Dest")] != nil
                  || sourceDictionary[PDFName("A")] != nil
              } else {
                sourceHadTarget = false
              }
              let remappedTarget = dictionary[PDFName("Dest")] != nil
                || dictionary[PDFName("A")] != nil
              if sourceHadTarget, !remappedTarget {
                report.droppedDestinations += 1
                continue
              }
            }
            let isField =
              dictionary[PDFName("Subtype")] == .name(PDFName("Widget"))
              || dictionary[PDFName("FT")] != nil
            if isField, let name = fieldName(dictionary[PDFName("T")]) {
              if assignedFieldNames.contains(name) {
                let renamed = "\(name)_\(sourceIndex + 1)"
                dictionary[PDFName("T")] = .string(AnnotationText.encode(renamed))
                objects[annotationID] = .dictionary(dictionary)
                report.renamedFields.append("\(name) → \(renamed)")
                assignedFieldNames.insert(renamed)
              } else {
                assignedFieldNames.insert(name)
              }
            }
            _ = annotationIndex
            keptAnnotations.append(.reference(annotationID))
          }
          newPage[PDFName("Annots")] = keptAnnotations.isEmpty ? nil : .array(keptAnnotations)
        }
        objects[newPageID] = .dictionary(newPage)
        indexMap[pageID] = newPageID
        kids.append(.reference(newPageID))
        combinedPageCount += 1
      }
      pageIndexMap[sourceIndex] = indexMap
      if firstCatalog == nil,
        case .reference(let catalogID)? = source.graph.trailer[PDFName("Root")],
        case .dictionary(let catalog)? = source.graph.objects[catalogID]
      {
        firstCatalog = catalog
      }
    }

    // P23-016: rebuild outlines from every source, remapping destinations to
    // surviving pages and dropping items (with a count) whose targets did not.
    var outlineRoot: PDFObjectID?
    var outlineChains: [(first: PDFObjectID, last: PDFObjectID, count: Int)] = []
    let outlineRootID = PDFObjectID(nextNumber)
    nextNumber += 1
    for (sourceIndex, source) in sources.enumerated() {
      guard let indexMap = pageIndexMap[sourceIndex],
        case .reference(let catalogID)? = source.graph.trailer[PDFName("Root")],
        case .dictionary(let sourceCatalog)? = source.graph.objects[catalogID],
        case .reference(let outlinesID)? = sourceCatalog[PDFName("Outlines")],
        case .dictionary(let outlines)? = source.graph.objects[outlinesID]
      else { continue }

      func itemDestination(_ item: [PDFName: PDFValue]) -> [PDFValue]? {
        if case .array(let destination)? = item[PDFName("Dest")] { return destination }
        if case .dictionary(let action)? = item[PDFName("A")],
          action[PDFName("S")] == .name(PDFName("GoTo")),
          case .array(let destination)? = action[PDFName("D")]
        {
          return destination
        }
        return nil
      }

      func rebuildChain(
        firstID: PDFObjectID?, parent: PDFObjectID, depth: Int
      ) -> (first: PDFObjectID?, last: PDFObjectID?, count: Int) {
        guard depth <= 32, let firstID else { return (nil, nil, 0) }
        var firstNew: PDFObjectID?
        var lastNew: PDFObjectID?
        var count = 0
        var visited: Set<PDFObjectID> = []
        var currentID: PDFObjectID? = firstID
        while let id = currentID, !visited.contains(id) {
          visited.insert(id)
          guard case .dictionary(let item)? = source.graph.objects[id] else { break }
          let nextID: PDFObjectID? = {
            if case .reference(let next)? = item[PDFName("Next")] { return next }
            return nil
          }()
          let newID = PDFObjectID(nextNumber)
          nextNumber += 1
          let children = rebuildChain(
            firstID: {
              if case .reference(let child)? = item[PDFName("First")] { return child }
              return nil
            }(), parent: newID, depth: depth + 1)
          var destinationPage: PDFObjectID?
          if let destination = itemDestination(item),
            case .reference(let sourcePage) = destination.first ?? .null
          {
            destinationPage = indexMap[sourcePage]
          }
          if destinationPage == nil, children.first == nil {
            report.droppedOutlines += 1
            currentID = nextID
            continue
          }
          var dictionary: [PDFName: PDFValue] = [
            PDFName("Title"): item[PDFName("Title")] ?? .string(Data("Untitled".utf8)),
            PDFName("Parent"): .reference(parent),
          ]
          if let destinationPage {
            dictionary[PDFName("Dest")] = .array([
              .reference(destinationPage), .name(PDFName("Fit")),
            ])
          }
          if let childFirst = children.first, let childLast = children.last {
            dictionary[PDFName("First")] = .reference(childFirst)
            dictionary[PDFName("Last")] = .reference(childLast)
            dictionary[PDFName("Count")] = .integer(Int64(children.count))
          }
          if let previous = lastNew {
            dictionary[PDFName("Prev")] = .reference(previous)
            if case .dictionary(var previousItem)? = objects[previous] {
              previousItem[PDFName("Next")] = .reference(newID)
              objects[previous] = .dictionary(previousItem)
            }
          }
          objects[newID] = .dictionary(dictionary)
          if firstNew == nil { firstNew = newID }
          lastNew = newID
          count += 1
          currentID = nextID
        }
        return (firstNew, lastNew, count)
      }

      let chain = rebuildChain(
        firstID: {
          if case .reference(let id)? = outlines[PDFName("First")] { return id }
          return nil
        }(), parent: outlineRootID, depth: 0)
      if let first = chain.first, let last = chain.last {
        outlineChains.append((first, last, chain.count))
      }
    }
    if !outlineChains.isEmpty {
      // Sibling chains from different sources are linked into one tree.
      for index in 1..<outlineChains.count {
        let previous = outlineChains[index - 1].last
        let current = outlineChains[index].first
        if case .dictionary(var previousItem)? = objects[previous] {
          previousItem[PDFName("Next")] = .reference(current)
          objects[previous] = .dictionary(previousItem)
        }
        if case .dictionary(var currentItem)? = objects[current] {
          currentItem[PDFName("Prev")] = .reference(previous)
          objects[current] = .dictionary(currentItem)
        }
      }
      let total = outlineChains.reduce(0) { $0 + $1.count }
      objects[outlineRootID] = .dictionary([
        PDFName("Type"): .name(PDFName("Outlines")),
        PDFName("First"): .reference(outlineChains[0].first),
        PDFName("Last"): .reference(outlineChains[outlineChains.count - 1].last),
        PDFName("Count"): .integer(Int64(total)),
      ])
      outlineRoot = outlineRootID
    }

    // Catalog: preserve the first source's document-level data (P23-021) and
    // point at the new page tree.
    var catalog: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("Catalog")),
      PDFName("Pages"): .reference(PDFObjectID(2)),
    ]
    if let first = firstCatalog {
      // P23-021: only self-contained scalar catalog data is carried over; the
      // rest is reported rather than left dangling.
      for key in ["Lang", "PageLayout", "PageMode"] {
        if let value = first[PDFName(key)] { catalog[PDFName(key)] = value }
      }
      var dropped: [String] = []
      if first[PDFName("StructTreeRoot")] != nil {
        dropped.append("structure tree")
      }
      if first[PDFName("Names")] != nil { dropped.append("name trees (destinations, attachments)") }
      if first[PDFName("Dests")] != nil { dropped.append("legacy destinations") }
      if first[PDFName("Metadata")] != nil { dropped.append("XMP metadata") }
      if first[PDFName("AcroForm")] != nil { dropped.append("AcroForm") }
      if !dropped.isEmpty {
        report.notes.append(
          "Document-level data not carried over: " + dropped.joined(separator: ", ")
          + ". Fields and annotations on the selected pages are preserved.")
      }
      // P23-014: page labels policy.
      switch labels {
      case .preserve:
        if first[PDFName("PageLabels")] != nil, sources.count > 1 {
          report.notes.append("Page labels were reset because multiple documents were merged.")
        }
      case .reset:
        break
      }
    }
    if let outlineRoot {
      catalog[PDFName("Outlines")] = .reference(outlineRoot)
    }
    // P23-021: carry the first source's self-contained catalog data by
    // remapping it; other sources' catalog data is dropped and reported.
    if catalogData == .firstDocument, let first = sources.first {
      var carried: [String] = []
      let carriedData = try carryCatalogData(
        source: first.graph, keys: ["Names", "Metadata", "StructTreeRoot"],
        into: &objects, nextNumber: &nextNumber, pageMap: pageIndexMap[0] ?? [:],
        limits: limits)
      if let names = carriedData.values["Names"] {
        catalog[PDFName("Names")] = names
        carried.append("attachments/name trees")
      }
      if let metadata = carriedData.values["Metadata"] {
        catalog[PDFName("Metadata")] = metadata
        carried.append("XMP metadata")
      }
      if let structureRoot = carriedData.values["StructTreeRoot"] {
        catalog[PDFName("StructTreeRoot")] = structureRoot
        carried.append("structure tree")
      }
      if sources.count > 1 {
        report.notes.append(
          "Catalog data from later documents (attachments, name trees, metadata) was not carried over.")
      }
      if !carried.isEmpty {
        report.notes.append("Carried from the first document: " + carried.joined(separator: ", ") + ".")
      }
    }
    objects[PDFObjectID(1)] = .dictionary(catalog)
    objects[PDFObjectID(2)] = .dictionary([
      PDFName("Type"): .name(PDFName("Pages")),
      PDFName("Count"): .integer(Int64(combinedPageCount)),
      PDFName("Kids"): .array(kids),
    ])

    _ = pageIndexMap

    var graph = PDFGraph(
      version: sources.first?.graph.version ?? "1.7", objects: objects,
      trailer: [PDFName("Root"): .reference(PDFObjectID(1))])
    if sources.count > 1 {
      report.notes.append("Field names were made unique across the merged documents.")
    }
    try repairCounts(from: PDFObjectID(2), in: &graph, limits: limits)
    return (graph, report)
  }

  /// P23-021: remap a catalog data subtree (for example `/Names`) into the
  /// assembled objects. Returns the number of objects copied (0 drops the
  /// subtree). Pages are never copied; references to unselected pages become
  /// null so no dangling target remains.
  static func carryCatalogData(
    source: PDFGraph, keys: [String], into objects: inout [PDFObjectID: PDFValue],
    nextNumber: inout Int, pageMap: [PDFObjectID: PDFObjectID], limits: PDFLimits
  ) throws -> (copied: Int, values: [String: PDFValue]) {
    guard case .reference(let catalogID)? = source.trailer[PDFName("Root")],
      case .dictionary(let sourceCatalog)? = source.objects[catalogID]
    else { return (0, [:]) }
    var remap: [PDFObjectID: PDFObjectID] = [:]
    for (sourcePage, newPage) in pageMap { remap[sourcePage] = newPage }
    var copied = 0

    func remapValue(_ value: PDFValue, depth: Int) throws -> PDFValue {
      guard depth <= limits.nesting else {
        throw PDFError(.limitExceeded, "Catalog data exceeds the nesting limit")
      }
      switch value {
      case .reference(let id):
        if let existing = remap[id] { return .reference(existing) }
        guard case .some(let object) = source.objects[id] else { return .null }
        if case .dictionary(let dictionary) = object,
          dictionary[PDFName("Type")] == .name(PDFName("Page"))
        {
          return .null
        }
        if case .dictionary(let dictionary) = object,
          dictionary[PDFName("Type")] == .name(PDFName("Pages"))
        {
          // Structure nodes are rebuilt separately.
          return .null
        }
        return try .reference(allocate(id, object: object, depth: depth + 1))
      case .array(let values):
        return .array(try values.map { try remapValue($0, depth: depth + 1) })
      case .dictionary(let dictionary):
        var result: [PDFName: PDFValue] = [:]
        for (key, value) in dictionary {
          result[key] = try remapValue(value, depth: depth + 1)
        }
        return .dictionary(result)
      case .stream(let stream):
        let dictionary = try remapValue(.dictionary(stream.dictionary), depth: depth + 1)
        guard case .dictionary(let remapped) = dictionary else {
          throw PDFError(.malformed, "Stream dictionary remap failed")
        }
        return .stream(PDFStream(dictionary: remapped, bytes: stream.bytes))
      default:
        return value
      }
    }

    func allocate(_ id: PDFObjectID, object: PDFValue, depth: Int) throws -> PDFObjectID {
      guard nextNumber <= limits.objects else {
        throw PDFError(.limitExceeded, "Catalog data exceeds the object limit")
      }
      let newID = PDFObjectID(nextNumber)
      nextNumber += 1
      remap[id] = newID
      objects[newID] = try remapValue(object, depth: depth + 1)
      copied += 1
      return newID
    }

    var values: [String: PDFValue] = [:]
    for key in keys {
      guard let value = sourceCatalog[PDFName(key)] else { continue }
      values[key] = try remapValue(value, depth: 0)
    }
    return (copied, values)
  }

  static func fieldName(_ value: PDFValue?) -> String? {
    guard case .string(let data)? = value else { return nil }
    let name = AnnotationText.decode(data)
    return name.isEmpty ? nil : name
  }

  /// P23-013: recompute `/Count` on every ancestor and make `/Parent` links
  /// consistent for the assembled tree.
  static func repairCounts(
    from nodeID: PDFObjectID, in graph: inout PDFGraph, limits: PDFLimits
  ) throws {
    guard case .dictionary(var node)? = graph.objects[nodeID] else { return }
    if case .array(let kids)? = node[PDFName("Kids")] {
      var count = 0
      for kid in kids {
        guard case .reference(let kidID) = kid,
          case .dictionary(var child)? = graph.objects[kidID]
        else { continue }
        if child[PDFName("Type")] == .name(PDFName("Page")) {
          count += 1
        } else {
          try repairCounts(from: kidID, in: &graph, limits: limits)
          if case .dictionary(let repaired)? = graph.objects[kidID],
            case .integer(let childCount)? = repaired[PDFName("Count")]
          {
            count += Int(childCount)
          }
        }
        child[PDFName("Parent")] = .reference(nodeID)
        graph.objects[kidID] = .dictionary(child)
      }
      node[PDFName("Count")] = .integer(Int64(count))
      graph.objects[nodeID] = .dictionary(node)
    }
  }

  static func nextObjectID(in graph: PDFGraph) -> PDFObjectID {
    PDFObjectID((graph.objects.keys.map(\.number).max() ?? 0) + 1)
  }
}

/// P23-003/P23-023: the organizer's duplicate action as a transaction command.
public struct DuplicatePageCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let duplicateResources: Bool

  public init(pageID: PDFObjectID, duplicateResources: Bool = false) {
    self.pageID = pageID
    self.duplicateResources = duplicateResources
  }

  /// P17-012: the page this command changes.
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Duplicate Page" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    _ = try PDFPageTree.pageIDs(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try DocumentAssembly.duplicatePage(
      pageID, in: graph, duplicateResources: duplicateResources).graph
  }
}

/// Shared box resolution for page attributes and crop editing.
enum DocumentInventoryBox {
  static func mediaBox(of page: [PDFName: PDFValue], in graph: PDFGraph) -> [Double] {
    var current = page
    for _ in 0..<64 {
      if case .array(let values)? = current[PDFName("MediaBox")] {
        let numbers = values.compactMap { value -> Double? in
          switch value {
          case .integer(let number): return Double(number)
          case .real(let number): return number
          default: return nil
          }
        }
        if numbers.count == 4 { return numbers }
      }
      guard case .reference(let parentID)? = current[PDFName("Parent")],
        case .dictionary(let parent)? = graph.objects[parentID]
      else { break }
      current = parent
    }
    return [0, 0, 612, 792]
  }
}

/// P17-021: import selected pages from another document into the open one as
/// a single transaction. The imported document is parsed from its bytes at
/// apply time, its reachable objects are remapped with collision-free
/// identities through the tested assembly path, the pages land at the
/// requested index, and undo restores the exact prior bytes (the command is
/// one undo entry). Encrypted or signed inputs are refused like any merge.
public struct ImportPagesCommand: PDFEditCommand, Equatable, Sendable {
  /// The other document's full bytes.
  public let documentBytes: Data
  /// Zero-based indices of the pages to import, in the import document.
  public let pageIndices: [Int]
  /// Where the imported pages land in the destination's flattened order.
  public let atIndex: Int

  public init(documentBytes: Data, pageIndices: [Int], atIndex: Int) {
    self.documentBytes = documentBytes
    self.pageIndices = pageIndices
    self.atIndex = atIndex
  }

  public var name: String { "Import Pages" }

  /// The imported pages do not exist in the destination before the commit, so
  /// the change set is conservative (unknown pages are treated as all).
  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  /// Parse and validate the import without mutating anything.
  func resolved(_ graph: PDFGraph, limits: PDFLimits) throws -> (source: PDFGraph, pages: [PDFObjectID]) {
    guard !documentBytes.isEmpty else {
      throw PDFError(.malformed, "No document bytes were given to import")
    }
    guard !pageIndices.isEmpty else {
      throw PDFError(.malformed, "Select at least one page to import")
    }
    guard Set(pageIndices).count == pageIndices.count else {
      throw PDFError(.malformed, "The import page selection repeats a page")
    }
    let parsed: ParsedPDF
    do {
      parsed = try PDFParser.parse(documentBytes, limits: limits)
    } catch let error as PDFError {
      throw error
    }
    if parsed.graph.trailer[PDFName("Encrypt")] != nil {
      throw PDFError(.unsupported, "Encrypted documents must be unlocked before importing pages")
    }
    let signatures = (try? PDFSignatureInventory.signatures(in: parsed.graph)) ?? []
    guard signatures.isEmpty else {
      throw PDFError(
        .unsupported, "Signed documents cannot be imported without invalidating signatures")
    }
    if graph.trailer[PDFName("Encrypt")] != nil {
      throw PDFError(.unsupported, "Unlock the destination document before importing pages")
    }
    let sourcePages = try PDFPageTree.pageIDs(in: parsed.graph)
    for index in pageIndices {
      guard index >= 0, index < sourcePages.count else {
        throw PDFError(.malformed, "An import page index is outside the other document")
      }
    }
    let destinationPages = try PDFPageTree.pageIDs(in: graph)
    guard atIndex >= 0, atIndex <= destinationPages.count else {
      throw PDFError(.malformed, "The import position is outside the document")
    }
    return (parsed.graph, pageIndices.map { sourcePages[$0] })
  }

  public func validate(in graph: PDFGraph) throws {
    _ = try resolved(graph, limits: PDFLimits())
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    let limits = PDFLimits()
    let (source, pages) = try resolved(graph, limits: limits)
    let destinationPages = try PDFPageTree.pageIDs(in: graph)
    // The tested assembly path remaps every reachable object with
    // collision-free identities, repairs the tree, and renames colliding
    // field names; the destination comes first so its identities win.
    let merged = try DocumentAssembly.merge(
      [
        (graph: graph, pageIDs: destinationPages),
        (graph: source, pageIDs: pages),
      ], labels: .preserve, catalogData: .firstDocument, limits: limits)
    // The imported pages are appended; move them to the requested index in
    // order, one reorder step each, inside this same commit.
    let mergedPages = try PDFPageTree.pageIDs(in: merged.graph)
    let imported = Array(mergedPages.suffix(pages.count))
    var result = merged.graph
    for (offset, pageID) in imported.enumerated() {
      let target = min(atIndex + offset, max(0, destinationPages.count + offset))
      result = try PDFEditingEngine.commit(
        PDFTransaction([ReorderPagesCommand(pageID: pageID, toIndex: target)]),
        to: result, limits: limits)
    }
    return result
  }
}
