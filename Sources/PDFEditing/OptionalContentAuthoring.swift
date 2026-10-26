import Foundation
import PDFCore

// SPC-03: optional-content (layer) inventory and authoring.
// Existing handling is read-only display policy in MacServices. This file adds
// an audited inventory plus supported authoring: naming, defaults, flat order,
// membership marking, print/view usage and layer-definition merge.
// Boundary: nested /Order structures, automatic visibility (/AS), OCMD and
// non-flat configurations are detected and refused rather than rewritten.

public enum LayerPrintState: String, Sendable, CaseIterable, Equatable {
  case on
  case off
  case unspecified

  public var title: String {
    switch self {
    case .on: return "Print ON"
    case .off: return "Print OFF"
    case .unspecified: return "Print default"
    }
  }

  var pdfName: PDFName {
    switch self {
    case .on: return PDFName("ON")
    case .off: return PDFName("OFF")
    case .unspecified: return PDFName("Unspecified")
    }
  }
}

public struct OptionalContentLayer: Sendable, Equatable, Identifiable {
  public var id: PDFObjectID { objectID }
  public let objectID: PDFObjectID
  public let name: String?
  public let defaultVisible: Bool
  public let printState: LayerPrintState
  public let viewState: LayerPrintState
  public let orderIndex: Int?
  public let membershipCount: Int
  public let annotationCount: Int

  public init(
    objectID: PDFObjectID, name: String?, defaultVisible: Bool,
    printState: LayerPrintState, viewState: LayerPrintState, orderIndex: Int?,
    membershipCount: Int, annotationCount: Int
  ) {
    self.objectID = objectID
    self.name = name
    self.defaultVisible = defaultVisible
    self.printState = printState
    self.viewState = viewState
    self.orderIndex = orderIndex
    self.membershipCount = membershipCount
    self.annotationCount = annotationCount
  }
}

public struct OptionalContentLayerInventory: Sendable, Equatable {
  public let layers: [OptionalContentLayer]
  public let order: [PDFObjectID]
  public let defaultOn: [PDFObjectID]
  public let defaultOff: [PDFObjectID]
  public let hasOCProperties: Bool
  public let issues: [String]

  public init(
    layers: [OptionalContentLayer], order: [PDFObjectID], defaultOn: [PDFObjectID],
    defaultOff: [PDFObjectID], hasOCProperties: Bool, issues: [String]
  ) {
    self.layers = layers
    self.order = order
    self.defaultOn = defaultOn
    self.defaultOff = defaultOff
    self.hasOCProperties = hasOCProperties
    self.issues = issues
  }

  public func layer(_ id: PDFObjectID) -> OptionalContentLayer? {
    layers.first { $0.objectID == id }
  }

  public func layer(named name: String) -> OptionalContentLayer? {
    layers.first { $0.name == name }
  }
}

public enum OptionalContentInventory {
  public static func inspect(in graph: PDFGraph) -> OptionalContentLayerInventory {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else {
      return OptionalContentLayerInventory(
        layers: [], order: [], defaultOn: [], defaultOff: [],
        hasOCProperties: false, issues: ["The document catalog is missing"])
    }
    guard let propertiesValue = catalog[PDFName("OCProperties")] else {
      return OptionalContentLayerInventory(
        layers: [], order: [], defaultOn: [], defaultOff: [],
        hasOCProperties: false, issues: [])
    }
    guard case .dictionary(let properties) = resolved(propertiesValue, in: graph) else {
      return OptionalContentLayerInventory(
        layers: [], order: [], defaultOn: [], defaultOff: [],
        hasOCProperties: true, issues: ["/OCProperties is not a dictionary"])
    }
    var issues: [String] = []
    var layerObjects: [PDFObjectID] = []
    if case .array(let entries)? = properties[PDFName("OCGs")] {
      for entry in entries {
        guard case .reference(let id) = entry else {
          issues.append("/OCGs contains an entry that is not an indirect object")
          continue
        }
        layerObjects.append(id)
      }
    }
    var defaults: [PDFName: PDFValue] = [:]
    if let value = properties[PDFName("D")] {
      if case .dictionary(let dictionary) = resolved(value, in: graph) {
        defaults = dictionary
      } else {
        issues.append("/OCProperties /D is not a dictionary")
      }
    }
    var on: [PDFObjectID] = []
    var off: [PDFObjectID] = []
    if case .array(let values)? = defaults[PDFName("ON")] {
      on = values.compactMap { reference($0) }
      if on.count != values.count { issues.append("/D /ON contains a non-reference") }
    }
    if case .array(let values)? = defaults[PDFName("OFF")] {
      off = values.compactMap { reference($0) }
      if off.count != values.count { issues.append("/D /OFF contains a non-reference") }
    }
    var order: [PDFObjectID] = []
    if let value = defaults[PDFName("Order")] {
      if case .array(let values) = resolved(value, in: graph) {
        for value in values {
          if case .reference(let id) = value {
            order.append(id)
          } else if case .array = value {
            issues.append(
              "Nested /Order arrays are detected and not rewritten by the supported flat order profile")
          } else {
            issues.append("/D /Order contains an unsupported entry")
          }
        }
      } else {
        issues.append("/D /Order is not an array")
      }
    }
    if !issues.contains(where: { $0.contains("Nested /Order") }),
      !layerObjects.isEmpty, order.isEmpty
    {
      issues.append("/D /Order is missing; layer order is not declared")
    }
    if !layerObjects.isEmpty {
      let missing = Set(layerObjects).subtracting(Set(order))
      if !missing.isEmpty, !order.isEmpty {
        issues.append("/D /Order omits \(missing.count) layer(s); order support is incomplete")
      }
    }
    let membership = layerMembership(in: graph, layerObjects: Set(layerObjects))
    var layers: [OptionalContentLayer] = []
    var seenNames: Set<String> = []
    for id in layerObjects {
      guard case .dictionary(let group)? = graph.objects[id] else {
        issues.append("Layer object \(id.number) is missing or not a dictionary")
        continue
      }
      var name: String?
      if case .string(let data)? = group[PDFName("Name")] {
        let decoded = AnnotationText.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
        if decoded.isEmpty {
          issues.append("Layer object \(id.number) has an empty /Name")
        } else {
          name = decoded
          if seenNames.contains(decoded) {
            issues.append("Duplicate layer name: " + decoded)
          }
          seenNames.insert(decoded)
        }
      } else {
        issues.append("Layer object \(id.number) has no /Name")
      }
      let printState = usageState(
        group: group, category: "Print", key: "PrintState", graph: graph,
        issues: &issues, layerID: id)
      let viewState = usageState(
        group: group, category: "View", key: "ViewState", graph: graph,
        issues: &issues, layerID: id)
      let visible: Bool = !off.contains(id)
      if on.contains(id), off.contains(id) {
        issues.append("Layer \(name ?? String(id.number)) is in both /ON and /OFF")
      }
      layers.append(
        OptionalContentLayer(
          objectID: id, name: name, defaultVisible: visible, printState: printState,
          viewState: viewState, orderIndex: order.firstIndex(of: id),
          membershipCount: membership.content[id] ?? 0,
          annotationCount: membership.annotations[id] ?? 0))
    }
    let referencedInContent = Set(membership.content.keys).subtracting(Set(layerObjects))
    for id in referencedInContent {
      issues.append("Content references layer object \(id.number) that is absent from /OCGs")
    }
    if properties[PDFName("AS")] != nil {
      issues.append("/OCProperties /AS automatic state is present and is not authored")
    }
    return OptionalContentLayerInventory(
      layers: layers, order: order, defaultOn: on, defaultOff: off,
      hasOCProperties: true, issues: issues)
  }

  static func resolved(_ value: PDFValue, in graph: PDFGraph) -> PDFValue {
    if case .reference(let id) = value, let object = graph.objects[id] { return object }
    return value
  }

  static func reference(_ value: PDFValue) -> PDFObjectID? {
    if case .reference(let id) = value { return id }
    return nil
  }

  static func usageState(
    group: [PDFName: PDFValue], category: String, key: String, graph: PDFGraph,
    issues: inout [String], layerID: PDFObjectID
  ) -> LayerPrintState {
    guard case .dictionary(let usage)? = group[PDFName("Usage")].map({
      resolved($0, in: graph)
    }) else { return .unspecified }
    guard let categoryValue = usage[PDFName(category)] else { return .unspecified }
    guard case .dictionary(let categoryDictionary) = resolved(categoryValue, in: graph) else {
      issues.append("Layer \(layerID.number) /Usage /\(category) is not a dictionary")
      return .unspecified
    }
    guard let stateValue = categoryDictionary[PDFName(key)] else { return .unspecified }
    guard case .name(let state) = stateValue else {
      issues.append("Layer \(layerID.number) /Usage /\(category) /\(key) is not a name")
      return .unspecified
    }
    switch state {
    case PDFName("ON"): return .on
    case PDFName("OFF"): return .off
    case PDFName("Unspecified"): return .unspecified
    default:
      issues.append(
        "Layer \(layerID.number) /Usage /\(category) /\(key) has an unsupported value")
      return .unspecified
    }
  }

  struct Membership {
    var content: [PDFObjectID: Int] = [:]
    var annotations: [PDFObjectID: Int] = [:]
  }

  static func layerMembership(
    in graph: PDFGraph, layerObjects: Set<PDFObjectID>
  ) -> Membership {
    var membership = Membership()
    let pageIDs = (try? PageTreeView(graph: graph).pages) ?? []
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      let resources = pageResources(pageID: pageID, graph: graph)
      var properties: [PDFName: PDFObjectID] = [:]
      if case .dictionary(let dictionary)? = resources[PDFName("Properties")] {
        for (name, value) in dictionary {
          if case .reference(let id) = value { properties[name] = id }
        }
      }
      if let content = try? PageContent.load(pageID: pageID, in: graph) {
        for instruction in content.instructions {
          let op = instruction.operatorName
          if (op == "BDC" || op == "BMC"),
            instruction.operands.count >= 2,
            case .name(let tag) = instruction.operands[0].value,
            tag == PDFName("OC"),
            case .name(let property) = instruction.operands[1].value,
            let layer = properties[property]
          {
            membership.content[layer, default: 0] += 1
          }
        }
      }
      if case .array(let annots)? = page[PDFName("Annots")] {
        for value in annots {
          guard case .reference(let annotID) = value,
            case .dictionary(let annotation)? = graph.objects[annotID],
            case .reference(let layer)? = annotation[PDFName("OC")]
          else { continue }
          membership.annotations[layer, default: 0] += 1
        }
      }
    }
    return membership
  }

  static func pageResources(
    pageID: PDFObjectID, graph: PDFGraph
  ) -> [PDFName: PDFValue] {
    var current: PDFObjectID? = pageID
    var depth = 0
    while let id = current, depth < 32 {
      guard case .dictionary(let page)? = graph.objects[id] else { break }
      if let value = page[PDFName("Resources")] {
        if case .dictionary(let resources) = resolved(value, in: graph) {
          return resources
        }
        if case .reference(let resourcesID) = value,
          case .dictionary(let resources)? = graph.objects[resourcesID]
        {
          return resources
        }
      }
      if case .reference(let parent)? = page[PDFName("Parent")] {
        current = parent
      } else {
        current = nil
      }
      depth += 1
    }
    return [:]
  }
}

public enum LayerAuditSeverity: String, Sendable, CaseIterable, Equatable {
  case error
  case warning
  case info
}

public struct LayerAuditFinding: Sendable, Equatable, Identifiable {
  public var id: String { rule + "/" + detail }
  public let rule: String
  public let severity: LayerAuditSeverity
  public let detail: String

  public init(rule: String, severity: LayerAuditSeverity, detail: String) {
    self.rule = rule
    self.severity = severity
    self.detail = detail
  }
}

public struct OptionalContentAudit: Sendable, Equatable {
  public let inventory: OptionalContentLayerInventory
  public let findings: [LayerAuditFinding]
  public let boundaryNotes: [String]

  public init(
    inventory: OptionalContentLayerInventory, findings: [LayerAuditFinding],
    boundaryNotes: [String]
  ) {
    self.inventory = inventory
    self.findings = findings
    self.boundaryNotes = boundaryNotes
  }

  public var report: String {
    var lines = [
      "Layer audit - \(inventory.layers.count) layer(s)",
      "  Default ON: \(inventory.defaultOn.count); default OFF: \(inventory.defaultOff.count); "
        + "order entries: \(inventory.order.count)",
      "  Layers: "
        + (inventory.layers.map { $0.name ?? ("object " + String($0.objectID.number)) }
          .joined(separator: ", ")),
    ]
    for finding in findings {
      lines.append("  [\(finding.severity.rawValue)] \(finding.rule): " + finding.detail)
    }
    for note in boundaryNotes { lines.append("  Note: " + note) }
    return lines.joined(separator: "\n")
  }
}

public enum OptionalContentAuditService {
  public static func audit(in graph: PDFGraph) -> OptionalContentAudit {
    let inventory = OptionalContentInventory.inspect(in: graph)
    var findings: [LayerAuditFinding] = []
    for issue in inventory.issues {
      let severity: LayerAuditSeverity =
        (issue.contains("missing") || issue.contains("Duplicate")
          || issue.contains("absent") || issue.contains("empty") || issue.contains("not a"))
        ? .error : .warning
      findings.append(LayerAuditFinding(rule: "Structure", severity: severity, detail: issue))
    }
    if !inventory.hasOCProperties {
      findings.append(
        LayerAuditFinding(
          rule: "OptionalContent", severity: .info,
          detail: "No /OCProperties; this document has no optional-content layers."))
    }
    if inventory.layers.contains(where: { $0.name == nil }) {
      findings.append(
        LayerAuditFinding(
          rule: "Naming", severity: .warning,
          detail: "At least one layer has no supported user name."))
    }
    if inventory.layers.contains(where: { $0.membershipCount == 0 && $0.annotationCount == 0 }) {
      findings.append(
        LayerAuditFinding(
          rule: "Membership", severity: .info,
          detail: "At least one layer has no detected content or annotation membership."))
    }
    if inventory.layers.contains(where: { $0.printState != .unspecified }) {
      findings.append(
        LayerAuditFinding(
          rule: "PrintVisibility", severity: .info,
          detail: "Print visibility states are declared and preserved; no print engine is claimed."))
    }
    findings.append(
      LayerAuditFinding(
        rule: "DisplayFiltering", severity: .info,
        detail: "The current Core Graphics/PDFKit display path is composite; authored default and "
          + "print states persist but are not rendered as filtering in this app."))
    let notes = [
      "Supported profile: flat /Order, /D /ON+/OFF defaults, /Usage /Print and /Usage /View state, "
        + "content membership through /Properties + marked content /OC, annotation /OC references.",
      "Nested /Order arrays, /OCProperties /AS automatic state and OCMD are audited but not authored.",
    ]
    return OptionalContentAudit(inventory: inventory, findings: findings, boundaryNotes: notes)
  }
}

// MARK: - Supported layer authoring

enum LayerAuthoringSupport {
  static func resolved(_ value: PDFValue?, in graph: PDFGraph) -> PDFValue? {
    guard let value else { return nil }
    if case .reference(let id) = value { return graph.objects[id] }
    return value
  }

  static func catalog(
    in graph: PDFGraph
  ) throws -> (id: PDFObjectID, dictionary: [PDFName: PDFValue]) {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else {
      throw PDFError(.malformed, "The document catalog is missing")
    }
    return (catalogID, catalog)
  }

  static func properties(
    in catalog: [PDFName: PDFValue], graph: PDFGraph
  ) -> [PDFName: PDFValue] {
    if let value = catalog[PDFName("OCProperties")],
      case .dictionary(let properties) = resolved(value, in: graph)
    {
      return properties
    }
    return [:]
  }

  static func defaults(
    in properties: [PDFName: PDFValue], graph: PDFGraph
  ) -> [PDFName: PDFValue] {
    if let value = properties[PDFName("D")],
      case .dictionary(let defaults) = resolved(value, in: graph)
    {
      return defaults
    }
    return [:]
  }

  static func layers(in properties: [PDFName: PDFValue], graph: PDFGraph) -> [PDFObjectID] {
    guard case .array(let entries)? = properties[PDFName("OCGs")] else { return [] }
    return entries.compactMap { value in
      if case .reference(let id) = value { return id }
      return nil
    }
  }

  static func references(_ value: PDFValue?, in graph: PDFGraph) -> [PDFObjectID] {
    guard let value = resolved(value, in: graph),
      case .array(let entries) = value
    else { return [] }
    return entries.compactMap { entry in
      if case .reference(let id) = entry { return id }
      return nil
    }
  }

  static func order(
    in defaults: [PDFName: PDFValue], graph: PDFGraph
  ) throws -> [PDFValue] {
    guard let value = defaults[PDFName("Order")] else { return [] }
    guard let resolvedValue = resolved(value, in: graph),
      case .array(let entries) = resolvedValue
    else {
      throw PDFError(.unsupported, "The layer /Order is not an array")
    }
    for entry in entries {
      if case .array = entry {
        throw PDFError(
          .unsupported, "Nested layer /Order arrays are outside the supported flat profile")
      }
      if case .reference = entry { continue }
      throw PDFError(.unsupported, "The layer /Order contains an unsupported entry")
    }
    return entries
  }

  static func uniqueLayerName(
    _ proposed: String, existing: [String], suffix: String = " (imported)"
  ) -> String {
    guard existing.contains(proposed) else { return proposed }
    var index = 1
    var candidate = proposed + suffix
    while existing.contains(candidate) {
      index += 1
      candidate = proposed + " " + String(index) + suffix
    }
    return candidate
  }

  static func validateLayerName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 256 else {
      throw PDFError(.malformed, "A layer name must be non-empty and at most 256 characters")
    }
    return trimmed
  }

  static func nextObjectID(in graph: PDFGraph) throws -> PDFObjectID {
    let base = graph.objects.keys.map(\.number).max() ?? 0
    guard base + 1 <= 100_000_000 else {
      throw PDFError(.limitExceeded, "No room remains for layer objects")
    }
    return PDFObjectID(base + 1)
  }

  static func setSize(_ id: PDFObjectID, in graph: inout PDFGraph) {
    graph.trailer[PDFName("Size")] = .integer(Int64(id.number) + 1)
  }

  static func usage(
    printState: LayerPrintState?, viewState: LayerPrintState?, graph: PDFGraph,
    existing: [PDFName: PDFValue]?
  ) -> [PDFName: PDFValue] {
    var usage = existing ?? [:]
    if let printState {
      var category: [PDFName: PDFValue] = [:]
      if case .dictionary(let current)? = usage[PDFName("Print")].flatMap({
        resolved($0, in: graph)
      }) {
        category = current
      }
      category[PDFName("PrintState")] = .name(printState.pdfName)
      usage[PDFName("Print")] = .dictionary(category)
    }
    if let viewState {
      var category: [PDFName: PDFValue] = [:]
      if case .dictionary(let current)? = usage[PDFName("View")].flatMap({
        resolved($0, in: graph)
      }) {
        category = current
      }
      category[PDFName("ViewState")] = .name(viewState.pdfName)
      usage[PDFName("View")] = .dictionary(category)
    }
    return usage
  }

  static func existingUsage(
    of layerID: PDFObjectID, graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    guard case .dictionary(let group)? = graph.objects[layerID],
      let value = group[PDFName("Usage")],
      case .dictionary(let usage) = resolved(value, in: graph)
    else { return nil }
    return usage
  }

  static func refuseAutomaticState(in properties: [PDFName: PDFValue]) throws {
    if properties[PDFName("AS")] != nil {
      throw PDFError(
        .unsupported,
        "/OCProperties /AS automatic visibility is present; authored changes would be "
          + "ambiguous, so this document is left untouched")
    }
  }

  static func write(
    catalogID: PDFObjectID, catalog: [PDFName: PDFValue],
    properties: [PDFName: PDFValue], graph: inout PDFGraph
  ) {
    var updatedCatalog = catalog
    updatedCatalog[PDFName("OCProperties")] = .dictionary(properties)
    graph.objects[catalogID] = .dictionary(updatedCatalog)
  }
}

public struct AddLayerCommand: PDFEditCommand, Equatable, Sendable {
  public let layerName: String
  public let defaultVisible: Bool
  public let printState: LayerPrintState
  public let orderIndex: Int?

  public init(
    name: String, defaultVisible: Bool = true,
    printState: LayerPrintState = .unspecified, orderIndex: Int? = nil
  ) {
    self.layerName = name
    self.defaultVisible = defaultVisible
    self.printState = printState
    self.orderIndex = orderIndex
  }

  public var name: String { "Add Layer" }

  public func validate(in graph: PDFGraph) throws {
    let catalog = try LayerAuthoringSupport.catalog(in: graph).dictionary
    let trimmed = try LayerAuthoringSupport.validateLayerName(layerName)
    let inventory = OptionalContentInventory.inspect(in: graph)
    guard !inventory.layers.contains(where: { $0.name == trimmed }) else {
      throw PDFError(.malformed, "A layer named " + trimmed + " already exists")
    }
    if let orderIndex, orderIndex < 0 {
      throw PDFError(.malformed, "Layer order index must not be negative")
    }
    try LayerAuthoringSupport.refuseAutomaticState(
      in: LayerAuthoringSupport.properties(in: catalog, graph: graph))
    _ = try LayerAuthoringSupport.nextObjectID(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let (catalogID, catalog) = try LayerAuthoringSupport.catalog(in: graph)
    let layerID = try LayerAuthoringSupport.nextObjectID(in: graph)
    let trimmed = try LayerAuthoringSupport.validateLayerName(layerName)
    var group: [PDFName: PDFValue] = [
      PDFName("Type"): .name(PDFName("OCG")),
      PDFName("Name"): .string(AnnotationText.encode(trimmed)),
    ]
    if printState != .unspecified {
      group[PDFName("Usage")] = .dictionary(
        LayerAuthoringSupport.usage(
          printState: printState, viewState: nil, graph: graph, existing: nil))
    }
    graph.objects[layerID] = .dictionary(group)
    var properties = LayerAuthoringSupport.properties(in: catalog, graph: graph)
    var layers = LayerAuthoringSupport.layers(in: properties, graph: graph)
    layers.append(layerID)
    properties[PDFName("OCGs")] = .array(layers.map { .reference($0) })
    var defaults = LayerAuthoringSupport.defaults(in: properties, graph: graph)
    var on = LayerAuthoringSupport.references(defaults[PDFName("ON")], in: graph)
    var off = LayerAuthoringSupport.references(defaults[PDFName("OFF")], in: graph)
    on.removeAll { $0 == layerID }
    off.removeAll { $0 == layerID }
    if defaultVisible { on.append(layerID) } else { off.append(layerID) }
    defaults[PDFName("ON")] = .array(on.map { .reference($0) })
    defaults[PDFName("OFF")] = .array(off.map { .reference($0) })
    var order = try LayerAuthoringSupport.order(in: defaults, graph: graph)
    let insertion = min(max(0, orderIndex ?? order.count), order.count)
    order.insert(.reference(layerID), at: insertion)
    defaults[PDFName("Order")] = .array(order)
    properties[PDFName("D")] = .dictionary(defaults)
    LayerAuthoringSupport.write(
      catalogID: catalogID, catalog: catalog, properties: properties, graph: &graph)
    LayerAuthoringSupport.setSize(layerID, in: &graph)
    return graph
  }
}

public struct RenameLayerCommand: PDFEditCommand, Equatable, Sendable {
  public let layerID: PDFObjectID
  public let layerName: String

  public init(layerID: PDFObjectID, name: String) {
    self.layerID = layerID
    self.layerName = name
  }

  public var name: String { "Rename Layer" }

  public func validate(in graph: PDFGraph) throws {
    let inventory = OptionalContentInventory.inspect(in: graph)
    guard inventory.layer(layerID) != nil else {
      throw PDFError(.malformed, "The selected layer does not exist")
    }
    let trimmed = try LayerAuthoringSupport.validateLayerName(layerName)
    guard !inventory.layers.contains(where: { $0.objectID != layerID && $0.name == trimmed })
    else {
      throw PDFError(.malformed, "Another layer already uses the name " + trimmed)
    }
    let catalog = try LayerAuthoringSupport.catalog(in: graph).dictionary
    try LayerAuthoringSupport.refuseAutomaticState(
      in: LayerAuthoringSupport.properties(in: catalog, graph: graph))
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var group)? = graph.objects[layerID] else {
      throw PDFError(.malformed, "The selected layer does not exist")
    }
    group[PDFName("Name")] = .string(
      AnnotationText.encode(try LayerAuthoringSupport.validateLayerName(layerName)))
    graph.objects[layerID] = .dictionary(group)
    return graph
  }
}

public struct SetLayerVisibilityCommand: PDFEditCommand, Equatable, Sendable {
  public let layerID: PDFObjectID
  public let screenVisible: Bool?
  public let printVisible: Bool?
  public let viewVisible: Bool?

  public init(
    layerID: PDFObjectID, screenVisible: Bool? = nil, printVisible: Bool? = nil,
    viewVisible: Bool? = nil
  ) {
    self.layerID = layerID
    self.screenVisible = screenVisible
    self.printVisible = printVisible
    self.viewVisible = viewVisible
  }

  public var name: String { "Set Layer Visibility" }

  public func validate(in graph: PDFGraph) throws {
    guard screenVisible != nil || printVisible != nil || viewVisible != nil else {
      throw PDFError(.malformed, "A layer visibility change needs at least one state")
    }
    guard OptionalContentInventory.inspect(in: graph).layer(layerID) != nil else {
      throw PDFError(.malformed, "The selected layer does not exist")
    }
    let catalog = try LayerAuthoringSupport.catalog(in: graph).dictionary
    try LayerAuthoringSupport.refuseAutomaticState(
      in: LayerAuthoringSupport.properties(in: catalog, graph: graph))
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let (catalogID, catalog) = try LayerAuthoringSupport.catalog(in: graph)
    var properties = LayerAuthoringSupport.properties(in: catalog, graph: graph)
    var defaults = LayerAuthoringSupport.defaults(in: properties, graph: graph)
    if let screenVisible {
      var on = LayerAuthoringSupport.references(defaults[PDFName("ON")], in: graph)
      var off = LayerAuthoringSupport.references(defaults[PDFName("OFF")], in: graph)
      on.removeAll { $0 == layerID }
      off.removeAll { $0 == layerID }
      if screenVisible { on.append(layerID) } else { off.append(layerID) }
      defaults[PDFName("ON")] = .array(on.map { .reference($0) })
      defaults[PDFName("OFF")] = .array(off.map { .reference($0) })
    }
    let printState = printVisible.map { $0 ? LayerPrintState.on : LayerPrintState.off }
    let viewState = viewVisible.map { $0 ? LayerPrintState.on : LayerPrintState.off }
    if printState != nil || viewState != nil {
      guard case .dictionary(var group)? = graph.objects[layerID] else {
        throw PDFError(.malformed, "The selected layer does not exist")
      }
      group[PDFName("Usage")] = .dictionary(
        LayerAuthoringSupport.usage(
          printState: printState, viewState: viewState, graph: graph,
          existing: LayerAuthoringSupport.existingUsage(of: layerID, graph: graph)))
      graph.objects[layerID] = .dictionary(group)
    }
    properties[PDFName("D")] = .dictionary(defaults)
    LayerAuthoringSupport.write(
      catalogID: catalogID, catalog: catalog, properties: properties, graph: &graph)
    return graph
  }
}

public struct ReorderLayersCommand: PDFEditCommand, Equatable, Sendable {
  public let orderedLayerIDs: [PDFObjectID]

  public init(orderedLayerIDs: [PDFObjectID]) {
    self.orderedLayerIDs = orderedLayerIDs
  }

  public var name: String { "Reorder Layers" }

  public func validate(in graph: PDFGraph) throws {
    let inventory = OptionalContentInventory.inspect(in: graph)
    let existing = inventory.layers.map(\.objectID)
    guard Set(existing) == Set(orderedLayerIDs), existing.count == orderedLayerIDs.count else {
      throw PDFError(.malformed, "Layer order must list every existing layer exactly once")
    }
    let catalog = try LayerAuthoringSupport.catalog(in: graph).dictionary
    let properties = LayerAuthoringSupport.properties(in: catalog, graph: graph)
    try LayerAuthoringSupport.refuseAutomaticState(in: properties)
    _ = try LayerAuthoringSupport.order(
      in: LayerAuthoringSupport.defaults(in: properties, graph: graph), graph: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let (catalogID, catalog) = try LayerAuthoringSupport.catalog(in: graph)
    var properties = LayerAuthoringSupport.properties(in: catalog, graph: graph)
    var defaults = LayerAuthoringSupport.defaults(in: properties, graph: graph)
    defaults[PDFName("Order")] = .array(orderedLayerIDs.map { .reference($0) })
    properties[PDFName("D")] = .dictionary(defaults)
    LayerAuthoringSupport.write(
      catalogID: catalogID, catalog: catalog, properties: properties, graph: &graph)
    return graph
  }
}

public struct MarkContentOnLayerCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let layerID: PDFObjectID
  public let instructionRange: Range<Int>

  public init(pageID: PDFObjectID, layerID: PDFObjectID, instructionRange: Range<Int>) {
    self.pageID = pageID
    self.layerID = layerID
    self.instructionRange = instructionRange
  }

  public var name: String { "Mark Content on Layer" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard OptionalContentInventory.inspect(in: graph).layer(layerID) != nil else {
      throw PDFError(.malformed, "The selected layer does not exist")
    }
    guard !instructionRange.isEmpty, instructionRange.lowerBound >= 0 else {
      throw PDFError(.malformed, "A non-empty instruction range is required")
    }
    let content = try PageContent.load(pageID: pageID, in: graph)
    guard instructionRange.upperBound <= content.instructions.count,
      instructionRange.lowerBound < content.instructions.count
    else {
      throw PDFError(.malformed, "The instruction range is outside the page content")
    }
    let first = content.instructions[instructionRange.lowerBound]
    let last = content.instructions[instructionRange.upperBound - 1]
    let start = first.operands.first?.span.lowerBound ?? first.span.lowerBound
    let end = last.span.upperBound
    guard let segments = content.segmentIndices(for: start..<end), segments.count == 1,
      content.segments[segments[0]].isEditable
    else {
      throw PDFError(
        .unsupported,
        "Marking content across more than one content stream or a non-editable stream is "
          + "outside the supported profile")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var resources: [PDFName: PDFValue] = [:]
    if let value = page[PDFName("Resources")] {
      if case .dictionary(let dictionary) = LayerAuthoringSupport.resolved(value, in: graph) {
        resources = dictionary
      }
    }
    if resources.isEmpty {
      resources = OptionalContentInventory.pageResources(pageID: pageID, graph: graph)
    }
    var properties: [PDFName: PDFValue] = [:]
    if case .dictionary(let dictionary)? = resources[PDFName("Properties")] {
      properties = dictionary
    }
    var resourceName: PDFName?
    for (name, value) in properties {
      if case .reference(let id) = value, id == layerID {
        resourceName = name
        break
      }
    }
    if resourceName == nil {
      var index = 1
      while properties[PDFName("OC" + String(index))] != nil { index += 1 }
      resourceName = PDFName("OC" + String(index))
      properties[resourceName!] = .reference(layerID)
    }
    resources[PDFName("Properties")] = .dictionary(properties)
    page[PDFName("Resources")] = .dictionary(resources)
    graph.objects[pageID] = .dictionary(page)
    let content = try PageContent.load(pageID: pageID, in: graph)
    let first = content.instructions[instructionRange.lowerBound]
    let last = content.instructions[instructionRange.upperBound - 1]
    let start = first.operands.first?.span.lowerBound ?? first.span.lowerBound
    let end = last.span.upperBound
    var prefix = Data("/OC /".utf8)
    prefix.append(contentsOf: resourceName!.bytes)
    prefix.append(contentsOf: Data(" BDC\n".utf8))
    let suffix = Data("\nEMC\n".utf8)
    graph = try content.replacing(
      ranges: [
        (start..<start, Array(prefix)),
        (end..<end, Array(suffix)),
      ], in: graph)
    return graph
  }
}

// MARK: - Layer import / merge

public struct LayerMergeReport: Sendable, Equatable {
  public let imported: [String]
  public let skipped: [String]
  public let notes: [String]
  public let importedObjectIDs: [PDFObjectID]

  public init(
    imported: [String], skipped: [String], notes: [String],
    importedObjectIDs: [PDFObjectID]
  ) {
    self.imported = imported
    self.skipped = skipped
    self.notes = notes
    self.importedObjectIDs = importedObjectIDs
  }

  public var report: String {
    var lines = ["Layer merge - \(imported.count) imported, \(skipped.count) skipped"]
    for name in imported { lines.append("  Imported: " + name) }
    for name in skipped { lines.append("  Skipped: " + name) }
    for note in notes { lines.append("  Note: " + note) }
    return lines.joined(separator: "\n")
  }
}

public enum OptionalContentLayerMerge {
  /// SPC-03: import/merge layer definitions with unique names and explicit
  /// default/print/view state. Target layers are not renamed or reordered.
  public static func merge(
    _ source: PDFGraph, into target: PDFGraph, renameConflicts: Bool = true
  ) throws -> (graph: PDFGraph, report: LayerMergeReport) {
    let sourceInventory = OptionalContentInventory.inspect(in: source)
    guard !sourceInventory.layers.isEmpty else {
      throw PDFError(.unsupported, "The source document has no optional-content layers")
    }
    let targetInventory = OptionalContentInventory.inspect(in: target)
    var graph = target
    let (catalogID, catalog) = try LayerAuthoringSupport.catalog(in: graph)
    var properties = LayerAuthoringSupport.properties(in: catalog, graph: graph)
    try LayerAuthoringSupport.refuseAutomaticState(in: properties)
    var layers = LayerAuthoringSupport.layers(in: properties, graph: graph)
    var defaults = LayerAuthoringSupport.defaults(in: properties, graph: graph)
    var on = LayerAuthoringSupport.references(defaults[PDFName("ON")], in: graph)
    var off = LayerAuthoringSupport.references(defaults[PDFName("OFF")], in: graph)
    var order = try LayerAuthoringSupport.order(in: defaults, graph: graph)
    var imported: [String] = []
    var skipped: [String] = []
    var importedIDs: [PDFObjectID] = []
    let existingNames = targetInventory.layers.compactMap(\.name)
    for layer in sourceInventory.layers {
      let proposed = layer.name ?? ("Imported Layer " + String(layer.objectID.number))
      if existingNames.contains(proposed) || imported.contains(proposed) {
        guard renameConflicts else {
          skipped.append(proposed)
          continue
        }
      }
      let uniqueName = LayerAuthoringSupport.uniqueLayerName(
        proposed, existing: existingNames + imported)
      guard case .dictionary(let sourceGroup)? = source.objects[layer.objectID] else {
        skipped.append(proposed)
        continue
      }
      let newID = try LayerAuthoringSupport.nextObjectID(in: graph)
      var group = sourceGroup
      group[PDFName("Name")] = .string(AnnotationText.encode(uniqueName))
      graph.objects[newID] = .dictionary(group)
      layers.append(newID)
      importedIDs.append(newID)
      if layer.defaultVisible { on.append(newID) } else { off.append(newID) }
      order.append(.reference(newID))
      imported.append(uniqueName)
    }
    properties[PDFName("OCGs")] = .array(layers.map { .reference($0) })
    defaults[PDFName("ON")] = .array(on.map { .reference($0) })
    defaults[PDFName("OFF")] = .array(off.map { .reference($0) })
    defaults[PDFName("Order")] = .array(order)
    properties[PDFName("D")] = .dictionary(defaults)
    LayerAuthoringSupport.write(
      catalogID: catalogID, catalog: catalog, properties: properties, graph: &graph)
    if let highest = importedIDs.map(\.number).max() {
      graph.trailer[PDFName("Size")] = .integer(Int64(highest) + 1)
    }
    let report = LayerMergeReport(
      imported: imported, skipped: skipped,
      notes: [
        "Imported layers carry definitions/state only; source content is not copied.",
        "Default screen state imported into /D /ON or /OFF; print/view usage dictionaries "
          + "are copied as authored.",
      ],
      importedObjectIDs: importedIDs)
    return (graph, report)
  }
}
