import Foundation
import PDFCore

/// PRE-07: Separation/DeviceN spot-color inventory and explicit remapping.
/// Remapping only renames colorants; alternate spaces and tint transforms are
/// preserved. No CMYK conversion, flattening or PDF/X claim is made.
public struct SpotColorUse: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case separation
    case deviceN
  }

  public let name: String
  public let kind: Kind
  public let colorants: [String]
  public let alternateSpace: String
  public let tintTransform: String
  public let pageIndices: [Int]
  public let occurrences: Int
  public let objectIDs: [PDFObjectID]
  public let isShared: Bool
}

public struct SpotColorInventoryReport: Sendable, Equatable {
  public let pageCount: Int
  public let uses: [SpotColorUse]
  public let unsupported: [String]

  public var spotNames: [String] { uses.map(\.name) }
  public var totalUses: Int { uses.reduce(0) { $0 + $1.occurrences } }

  public func report() -> String {
    var lines = [
      "Spot-color inventory — " + String(pageCount) + " page(s), "
        + String(uses.count) + " colorant(s), " + String(totalUses) + " occurrence(s)"
    ]
    for use in uses {
      lines.append(
        "  " + use.kind.rawValue + " " + use.name + " on page(s) "
          + use.pageIndices.map { String($0 + 1) }.joined(separator: ",")
          + "; alternate " + use.alternateSpace + "; tint " + use.tintTransform
          + (use.isShared ? " (shared object)" : ""))
    }
    for reason in unsupported { lines.append("  Unsupported: " + reason) }
    lines.append(
      "Remapping is plate/colorant-name only; appearance through the alternate space "
        + "and tint transform is preserved and no CMYK conversion is claimed.")
    return lines.joined(separator: "\n")
  }
}

public enum SpotColorInventory {
  static let maximumFormDepth = 4
  static let maximumVisitedObjects = 2_000

  public static func inventory(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) -> SpotColorInventoryReport {
    var collector = Collector(graph: graph, limits: limits)
    for (pageIndex, pageID) in pageIDs.enumerated() {
      collector.visitPage(pageID: pageID, pageIndex: pageIndex)
    }
    return SpotColorInventoryReport(
      pageCount: pageIDs.count,
      uses: collector.aggregatedUses().sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }, unsupported: collector.unsupported.sorted())
  }

  struct UseRecord {
    let name: String
    let kind: SpotColorUse.Kind
    let colorants: [String]
    let alternateSpace: String
    let tintTransform: String
    let pageIndex: Int
    let objectID: PDFObjectID?
  }

  struct Collector {
    let graph: PDFGraph
    let limits: PDFLimits
    var records: [UseRecord] = []
    var unsupported: [String] = []
    var visitedForms: Set<PDFObjectID> = []
    var visitedObjects = 0

    mutating func visitPage(pageID: PDFObjectID, pageIndex: Int) {
      guard case .dictionary(let page)? = graph.objects[pageID] else { return }
      visitResources(
        page[PDFName("Resources")], pageIndex: pageIndex, depth: 0,
        context: "page " + String(pageIndex + 1))
    }

    mutating func visitResources(
      _ value: PDFValue?, pageIndex: Int, depth: Int, context: String
    ) {
      guard depth <= maximumFormDepth else {
        unsupported.append("Form nesting exceeds the supported depth at " + context)
        return
      }
      guard let resources = resolvedDictionary(value) else { return }
      if let colorSpaces = resolvedDictionary(resources[PDFName("ColorSpace")]) {
        for (name, value) in colorSpaces {
          inspectColorSpace(
            value, pageIndex: pageIndex,
            context: context + " ColorSpace /" + string(name))
        }
      }
      guard let xObjects = resolvedDictionary(resources[PDFName("XObject")]) else { return }
      for (name, value) in xObjects {
        guard let stream = resolvedStream(value) else { continue }
        let subtype = stream.dictionary[PDFName("Subtype")]
        if subtype == .name(PDFName("Image")) {
          if let colorSpace = stream.dictionary[PDFName("ColorSpace")] {
            inspectColorSpace(
              colorSpace, pageIndex: pageIndex,
              context: context + " image /" + string(name))
          }
        } else if subtype == .name(PDFName("Form")) {
          var formID: PDFObjectID?
          if case .reference(let id) = value { formID = id }
          if let formID {
            guard !visitedForms.contains(formID) else { continue }
            visitedForms.insert(formID)
          }
          let formResources = stream.dictionary[PDFName("Resources")] ?? value
          visitResources(
            formResources, pageIndex: pageIndex, depth: depth + 1,
            context: context + " form /" + string(name))
        }
      }
    }

    mutating func inspectColorSpace(
      _ value: PDFValue, pageIndex: Int, context: String
    ) {
      visitedObjects += 1
      guard visitedObjects <= maximumVisitedObjects else { return }
      guard let (array, objectID) = resolvedArray(value) else { return }
      guard let first = array.first, case .name(let kindName) = first else { return }
      let kind = string(kindName)
      switch kind {
      case "Separation":
        guard array.count >= 4, case .name(let colorant) = array[1] else {
          unsupported.append("Malformed Separation color space at " + context)
          return
        }
        records.append(
          UseRecord(
            name: string(colorant), kind: .separation, colorants: [string(colorant)],
            alternateSpace: describeSpace(array[2]),
            tintTransform: describeFunction(array[3]), pageIndex: pageIndex,
            objectID: objectID))
      case "DeviceN":
        guard array.count >= 4, case .array(let names) = array[1] else {
          unsupported.append("Malformed DeviceN color space at " + context)
          return
        }
        let colorants = names.compactMap { value -> String? in
          if case .name(let name) = value { return string(name) }
          return nil
        }
        guard colorants.count == names.count, !colorants.isEmpty else {
          unsupported.append("DeviceN colorant names are malformed at " + context)
          return
        }
        for colorant in colorants {
          records.append(
            UseRecord(
              name: colorant, kind: .deviceN, colorants: colorants,
              alternateSpace: describeSpace(array[2]),
              tintTransform: describeFunction(array[3]), pageIndex: pageIndex,
              objectID: objectID))
        }
      default:
        return
      }
    }

    func aggregatedUses() -> [SpotColorUse] {
      struct Key: Hashable {
        let name: String
        let kind: SpotColorUse.Kind
        let alternate: String
        let tint: String
      }
      var grouped: [Key: (pages: Set<Int>, count: Int, ids: Set<PDFObjectID>, colorants: [String])] =
        [:]
      for record in records {
        let key = Key(
          name: record.name, kind: record.kind, alternate: record.alternateSpace,
          tint: record.tintTransform)
        var entry = grouped[key] ?? (pages: [], count: 0, ids: [], colorants: record.colorants)
        entry.pages.insert(record.pageIndex)
        entry.count += 1
        if let objectID = record.objectID { entry.ids.insert(objectID) }
        grouped[key] = entry
      }
      return grouped.map { key, value in
        SpotColorUse(
          name: key.name, kind: key.kind, colorants: value.colorants,
          alternateSpace: key.alternate, tintTransform: key.tint,
          pageIndices: value.pages.sorted(), occurrences: value.count,
          objectIDs: value.ids.sorted(), isShared: !value.ids.isEmpty)
      }
    }

    func resolvedDictionary(_ value: PDFValue?) -> [PDFName: PDFValue]? {
      guard let value else { return nil }
      switch value {
      case .dictionary(let dictionary): return dictionary
      case .reference(let id):
        guard case .dictionary(let dictionary)? = graph.objects[id] else { return nil }
        return dictionary
      default: return nil
      }
    }

    func resolvedArray(_ value: PDFValue) -> ([PDFValue], PDFObjectID?)? {
      switch value {
      case .array(let array): return (array, nil)
      case .reference(let id):
        guard case .array(let array)? = graph.objects[id] else { return nil }
        return (array, id)
      default: return nil
      }
    }

    func resolvedStream(_ value: PDFValue) -> PDFStream? {
      switch value {
      case .stream(let stream): return stream
      case .reference(let id):
        guard case .stream(let stream)? = graph.objects[id] else { return nil }
        return stream
      default: return nil
      }
    }

    func string(_ name: PDFName) -> String {
      String(decoding: name.bytes, as: UTF8.self)
    }

    func describeSpace(_ value: PDFValue) -> String {
      switch value {
      case .name(let name): return string(name)
      case .array(let array):
        if let first = array.first, case .name(let name) = first { return string(name) }
        return "array"
      case .reference(let id): return "object " + String(id.number)
      default: return "unknown"
      }
    }

    func describeFunction(_ value: PDFValue) -> String {
      switch value {
      case .reference(let id): return "function object " + String(id.number)
      case .dictionary(let dictionary):
        if let type = dictionary[PDFName("FunctionType")] {
          switch type {
          case .integer(let number): return "FunctionType " + String(number)
          default: return "function dictionary"
          }
        }
        return "function dictionary"
      case .name(let name): return "named " + string(name)
      default: return "unknown"
      }
    }
  }
}

public struct SpotColorRemapRequest: Sendable, Equatable {
  /// Original colorant/plate name -> new colorant/plate name.
  public let mappings: [String: String]
  public let reason: String?

  public init(mappings: [String: String], reason: String? = nil) {
    self.mappings = mappings
    self.reason = reason
  }
}

public struct SpotColorRemapReport: Sendable, Equatable {
  public let mappings: [String: String]
  public let renamedOccurrences: Int
  public let renamedColorants: [String]
  public let mergedTargets: [String: [String]]
  public let unknownSources: [String]
  public let skippedIdentity: [String]
  public let affectedPageIndices: [Int]
  public let objectIDs: [PDFObjectID]
  public let sharedObjectDisclosure: [String]
  public let disclosure: String

  public func report() -> String {
    var lines = [
      "Spot-color remap — " + String(renamedOccurrences) + " colorant occurrence(s) renamed"
    ]
    for (source, target) in mappings.sorted(by: { $0.key < $1.key }) {
      lines.append("  " + source + " -> " + target)
    }
    if !mergedTargets.isEmpty {
      for (target, sources) in mergedTargets.sorted(by: { $0.key < $1.key }) {
        lines.append(
          "  Plates merged into " + target + ": " + sources.sorted().joined(separator: ", "))
      }
    }
    if !unknownSources.isEmpty {
      lines.append("  Unmatched source name(s): " + unknownSources.sorted().joined(separator: ", "))
    }
    if !skippedIdentity.isEmpty {
      lines.append("  Identity mapping(s) skipped: " + skippedIdentity.sorted().joined(separator: ", "))
    }
    lines.append(
      "  Pages: " + affectedPageIndices.map { String($0 + 1) }.joined(separator: ","))
    for line in sharedObjectDisclosure { lines.append("  " + line) }
    lines.append(disclosure)
    return lines.joined(separator: "\n")
  }
}

public enum SpotColorRemap {
  public static let disclosure =
    "Plate-colorant-name remap only: alternate spaces, tint transforms and page content are "
    + "unchanged; this is not a CMYK conversion, flattening or PDF/X conformance claim."

  public static func validate(_ request: SpotColorRemapRequest) throws {
    guard !request.mappings.isEmpty else {
      throw PDFError(.malformed, "The spot-color remap has no mappings")
    }
    for (source, target) in request.mappings {
      guard !source.isEmpty, isValidColorantName(source) else {
        throw PDFError(.malformed, "The source spot-color name is not a valid colorant name")
      }
      guard !target.isEmpty, isValidColorantName(target) else {
        throw PDFError(.unsupported, "The target spot-color name is not a valid colorant name")
      }
    }
  }

  public static func apply(
    _ graph: PDFGraph, pageIDs: [PDFObjectID], request: SpotColorRemapRequest,
    limits: PDFLimits = PDFLimits()
  ) throws -> (graph: PDFGraph, report: SpotColorRemapReport) {
    try validate(request)
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages were selected for spot-color remapping")
    }
    var mappings: [String: String] = [:]
    var skippedIdentity: [String] = []
    for (source, target) in request.mappings {
      if source == target { skippedIdentity.append(source); continue }
      mappings[source] = target
    }
    var state = RemapState(mappings: mappings)
    var graph = graph
    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard case .dictionary(var page)? = graph.objects[pageID] else {
        throw PDFError(.malformed, "A selected page is missing for spot-color remapping")
      }
      guard var resourcesValue = page[PDFName("Resources")] else { continue }
      resourcesValue = rewriteResourcesValue(
        resourcesValue, graph: &graph, pageIndex: pageIndex, state: &state,
        limits: limits, depth: 0)
      page[PDFName("Resources")] = resourcesValue
      graph.objects[pageID] = .dictionary(page)
    }
    let merged = Dictionary(grouping: state.foundSources.sorted(), by: { mappings[$0] ?? $0 })
      .filter { $0.value.count > 1 }
    let report = SpotColorRemapReport(
      mappings: mappings, renamedOccurrences: state.renamedOccurrences,
      renamedColorants: state.foundSources.sorted(),
      mergedTargets: Dictionary(uniqueKeysWithValues: merged.map { ($0.key, $0.value) }),
      unknownSources: mappings.keys.filter { !state.foundSources.contains($0) }.sorted(),
      skippedIdentity: skippedIdentity,
      affectedPageIndices: state.affectedPages.sorted(),
      objectIDs: state.objectIDs.sorted(),
      sharedObjectDisclosure: state.sharedObject ? [
        "Indirect color-space/stream objects are shared by reference; the rename applies "
          + "everywhere those objects are used, not only on the selected pages."
      ] : [], disclosure: disclosure)
    return (graph, report)
  }

  static func isValidColorantName(_ name: String) -> Bool {
    let bytes = [UInt8](name.utf8)
    guard !bytes.isEmpty, bytes.count <= 120 else { return false }
    let delimiters: Set<UInt8> = [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25, 0x23]
    for byte in bytes {
      if byte < 0x20 || byte > 0x7E || delimiters.contains(byte) { return false }
    }
    return true
  }

  struct RemapState {
    let mappings: [String: String]
    var renamedOccurrences = 0
    var foundSources: Set<String> = []
    var affectedPages: Set<Int> = []
    var objectIDs: Set<PDFObjectID> = []
    var sharedObject = false
  }

  static func rewriteResourcesValue(
    _ value: PDFValue, graph: inout PDFGraph, pageIndex: Int, state: inout RemapState,
    limits: PDFLimits, depth: Int
  ) -> PDFValue {
    guard depth <= SpotColorInventory.maximumFormDepth else { return value }
    if case .reference(let id) = value,
      case .dictionary(var resources)? = graph.objects[id]
    {
      rewriteResourcesDictionary(
        &resources, graph: &graph, pageIndex: pageIndex, state: &state, limits: limits,
        depth: depth)
      graph.objects[id] = .dictionary(resources)
      return value
    }
    if case .dictionary(var resources) = value {
      rewriteResourcesDictionary(
        &resources, graph: &graph, pageIndex: pageIndex, state: &state, limits: limits,
        depth: depth)
      return .dictionary(resources)
    }
    return value
  }

  static func rewriteResourcesDictionary(
    _ resources: inout [PDFName: PDFValue], graph: inout PDFGraph, pageIndex: Int,
    state: inout RemapState, limits: PDFLimits, depth: Int
  ) {
    if case .dictionary(var colorSpaces)? = resources[PDFName("ColorSpace")] {
      for (name, value) in colorSpaces {
        colorSpaces[name] = rewriteColorSpaceValue(
          value, graph: &graph, pageIndex: pageIndex, state: &state)
      }
      resources[PDFName("ColorSpace")] = .dictionary(colorSpaces)
    } else if case .reference(let colorSpaceID)? = resources[PDFName("ColorSpace")],
      case .dictionary(var colorSpaces)? = graph.objects[colorSpaceID]
    {
      for (name, value) in colorSpaces {
        colorSpaces[name] = rewriteColorSpaceValue(
          value, graph: &graph, pageIndex: pageIndex, state: &state)
      }
      graph.objects[colorSpaceID] = .dictionary(colorSpaces)
      resources[PDFName("ColorSpace")] = .reference(colorSpaceID)
    }
    guard case .dictionary(var xObjects)? = resources[PDFName("XObject")] else { return }
    for (name, value) in xObjects {
      xObjects[name] = rewriteXObjectValue(
        value, graph: &graph, pageIndex: pageIndex, state: &state, limits: limits,
        depth: depth)
    }
    resources[PDFName("XObject")] = .dictionary(xObjects)
  }

  static func rewriteXObjectValue(
    _ value: PDFValue, graph: inout PDFGraph, pageIndex: Int, state: inout RemapState,
    limits: PDFLimits, depth: Int
  ) -> PDFValue {
    guard depth <= SpotColorInventory.maximumFormDepth else { return value }
    var objectID: PDFObjectID?
    var stream: PDFStream?
    switch value {
    case .stream(let value):
      stream = value
    case .reference(let id):
      if case .stream(let value)? = graph.objects[id] {
        stream = value
        objectID = id
      }
    default:
      return value
    }
    guard var stream else { return value }
    var dictionary = stream.dictionary
    if dictionary[PDFName("Subtype")] == .name(PDFName("Image")) {
      if let colorSpace = dictionary[PDFName("ColorSpace")] {
        dictionary[PDFName("ColorSpace")] = rewriteColorSpaceValue(
          colorSpace, graph: &graph, pageIndex: pageIndex, state: &state)
      }
    } else if dictionary[PDFName("Subtype")] == .name(PDFName("Form")) {
      if let formResources = dictionary[PDFName("Resources")] {
        dictionary[PDFName("Resources")] = rewriteResourcesValue(
          formResources, graph: &graph, pageIndex: pageIndex, state: &state, limits: limits,
          depth: depth + 1)
      }
    }
    stream.dictionary = dictionary
    if let objectID {
      graph.objects[objectID] = .stream(stream)
      return value
    }
    return .stream(stream)
  }

  static func rewriteColorSpaceValue(
    _ value: PDFValue, graph: inout PDFGraph, pageIndex: Int, state: inout RemapState
  ) -> PDFValue {
    switch value {
    case .array(let array):
      return .array(rename(array: array, pageIndex: pageIndex, state: &state))
    case .reference(let id):
      if case .array(let array)? = graph.objects[id] {
        state.objectIDs.insert(id)
        state.sharedObject = true
        let renamed = rename(array: array, pageIndex: pageIndex, state: &state)
        graph.objects[id] = .array(renamed)
      }
      return value
    default:
      return value
    }
  }

  static func rename(
    array: [PDFValue], pageIndex: Int, state: inout RemapState
  ) -> [PDFValue] {
    guard let first = array.first, case .name(let kind) = first else { return array }
    let kindName = String(decoding: kind.bytes, as: UTF8.self)
    if kindName == "Separation" {
      guard array.count >= 4, case .name(let colorant) = array[1] else { return array }
      let name = String(decoding: colorant.bytes, as: UTF8.self)
      guard let target = state.mappings[name] else { return array }
      var result = array
      result[1] = .name(PDFName(target))
      state.foundSources.insert(name)
      state.renamedOccurrences += 1
      state.affectedPages.insert(pageIndex)
      return result
    }
    if kindName == "DeviceN" {
      guard array.count >= 4, case .array(let names) = array[1] else { return array }
      var result = array
      var newNames: [PDFValue] = []
      var renamedAny = false
      for value in names {
        guard case .name(let colorant) = value else {
          newNames.append(value)
          continue
        }
        let name = String(decoding: colorant.bytes, as: UTF8.self)
        if let target = state.mappings[name] {
          newNames.append(.name(PDFName(target)))
          state.foundSources.insert(name)
          state.renamedOccurrences += 1
          state.affectedPages.insert(pageIndex)
          renamedAny = true
        } else {
          newNames.append(value)
        }
      }
      if renamedAny {
        result[1] = .array(newNames)
      }
      return result
    }
    return array
  }
}

/// PRE-07: undoable graph command wrapper for an explicit spot remap.
public struct SpotColorRemapCommand: PDFEditCommand, Equatable, Sendable {
  public let pageIDs: [PDFObjectID]
  public let request: SpotColorRemapRequest

  public init(pageIDs: [PDFObjectID], request: SpotColorRemapRequest) {
    self.pageIDs = pageIDs
    self.request = request
  }

  public var name: String { "Remap Spot Colors" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { pageIDs }

  public func validate(in graph: PDFGraph) throws {
    try SpotColorRemap.validate(request)
    guard !pageIDs.isEmpty else {
      throw PDFError(.malformed, "No pages are selected for spot-color remapping")
    }
    for pageID in pageIDs {
      guard case .dictionary? = graph.objects[pageID] else {
        throw PDFError(.malformed, "A selected page is missing")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try SpotColorRemap.apply(graph, pageIDs: pageIDs, request: request).graph
  }
}
