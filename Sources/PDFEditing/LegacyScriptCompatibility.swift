import CryptoKit
import Foundation
import PDFCore

// MARK: - Decision profile

/// SPC-06: the declared decision for legacy Acrobat JavaScript. sPDF never
/// evaluates document JavaScript. It inventories scripts and actions without
/// exposing script source, maps the deterministic subset of behaviour to
/// declarative private rules it controls, and offers an explicit neutralized
/// copy that removes JavaScript actions while preserving everything else.
public enum LegacyScriptTrigger: String, Sendable, Equatable, CaseIterable {
  case documentOpen
  case documentClose
  case willSave
  case didSave
  case willPrint
  case didPrint
  case pageOpen
  case pageClose
  case mouseUp
  case mouseDown
  case mouseEnter
  case mouseExit
  case keystroke
  case format
  case validate
  case calculate
  /// Document-wide named JavaScript (the /Names /JavaScript tree), invoked by
  /// other scripts rather than by an automatic trigger.
  case documentWideFunction
  /// A user-triggered annotation or field action without a declarative event.
  case otherAction

  public var title: String {
    switch self {
    case .documentOpen: return "Document open"
    case .documentClose: return "Document close"
    case .willSave: return "Will save"
    case .didSave: return "Did save"
    case .willPrint: return "Will print"
    case .didPrint: return "Did print"
    case .pageOpen: return "Page open"
    case .pageClose: return "Page close"
    case .mouseUp: return "Mouse up"
    case .mouseDown: return "Mouse down"
    case .mouseEnter: return "Mouse enter"
    case .mouseExit: return "Mouse exit"
    case .keystroke: return "Keystroke"
    case .format: return "Format"
    case .validate: return "Validate"
    case .calculate: return "Calculate"
    case .documentWideFunction: return "Document-wide function"
    case .otherAction: return "Other action"
    }
  }

  public var isAutomatic: Bool {
    switch self {
    case .documentOpen, .documentClose, .willSave, .didSave, .willPrint, .didPrint,
      .pageOpen, .pageClose, .mouseUp, .mouseDown, .mouseEnter, .mouseExit,
      .keystroke, .format, .validate, .calculate:
      return true
    case .documentWideFunction, .otherAction:
      return false
    }
  }

  /// Map a raw /AA trigger key and its owner to the declared event.
  static func from(trigger: PDFName, owner: ScriptOwner) -> LegacyScriptTrigger {
    let key = String(decoding: trigger.bytes, as: UTF8.self)
    switch (owner, key) {
    case (_, "OpenAction"): return .documentOpen
    case (_, "A"): return .otherAction
    case (.field, "K"): return .keystroke
    case (.field, "F"): return .format
    case (.field, "V"): return .validate
    case (.field, "C"): return .calculate
    case (.page, "O"): return .pageOpen
    case (.page, "C"): return .pageClose
    case (_, "O"): return .documentOpen
    case (_, "C"): return .documentClose
    case (_, "WC"): return .documentClose
    case (_, "WS"): return .willSave
    case (_, "DS"): return .didSave
    case (_, "WP"): return .willPrint
    case (_, "DP"): return .didPrint
    case (_, "U"): return .mouseUp
    case (_, "D"): return .mouseDown
    case (_, "E"): return .mouseEnter
    case (_, "X"): return .mouseExit
    case (_, "PO"): return .pageOpen
    case (_, "PC"): return .pageClose
    default: return .otherAction
    }
  }
}

enum ScriptOwner: Sendable, Equatable {
  case catalog
  case page
  case annotation
  case field
  case acroForm
}

/// SPC-06: where one inventoried action lives.
public enum ScriptActionLocation: Sendable, Equatable {
  case catalog
  case page(index: Int)
  case annotation(pageIndex: Int, annotationIndex: Int)
  case field(name: String)
  case acroForm

  public var title: String {
    switch self {
    case .catalog: return "Catalog"
    case .page(let index): return "Page \(index + 1)"
    case .annotation(let pageIndex, let annotationIndex):
      return "Page \(pageIndex + 1) annotation \(annotationIndex + 1)"
    case .field(let name): return "Field \(name)"
    case .acroForm: return "AcroForm"
    }
  }
}

/// SPC-06: the declared operation class of an action or script. Only the
/// controlled classes are prohibited by default; inventory records them so the
/// user can see what a script would have tried to reach.
public enum DeclaredScriptOperation: String, Sendable, Equatable, CaseIterable {
  case fileSystemAccess
  case networkAccess
  case applicationLaunchOrExecution
  case formDataTransfer
  case embeddedContentPlayback
  case securityOrSignature
  case other

  public var title: String {
    switch self {
    case .fileSystemAccess: return "File access"
    case .networkAccess: return "Network access"
    case .applicationLaunchOrExecution: return "Launch or execution"
    case .formDataTransfer: return "Form data transfer"
    case .embeddedContentPlayback: return "Embedded media playback"
    case .securityOrSignature: return "Security or signature"
    case .other: return "Other"
    }
  }

  /// The declared control rule: these are never performed by sPDF and require
  /// an explicit user action outside the script layer.
  public var isControlled: Bool {
    self == .fileSystemAccess || self == .networkAccess || self == .applicationLaunchOrExecution
  }
}

/// SPC-06: one inventoried action. Script source is never retained: only the
/// digest and byte count are reported.
public struct ScriptedAction: Sendable, Equatable {
  public let location: ScriptActionLocation
  public let trigger: LegacyScriptTrigger
  /// Raw /S action name, for example JavaScript, Launch or URI.
  public let kind: String
  public let isJavaScript: Bool
  public let scriptByteCount: Int?
  public let scriptDigest: String?
  public let operations: [DeclaredScriptOperation]
  public let isDocumentWide: Bool

  public init(
    location: ScriptActionLocation, trigger: LegacyScriptTrigger, kind: String,
    isJavaScript: Bool, scriptByteCount: Int?, scriptDigest: String?,
    operations: [DeclaredScriptOperation], isDocumentWide: Bool
  ) {
    self.location = location
    self.trigger = trigger
    self.kind = kind
    self.isJavaScript = isJavaScript
    self.scriptByteCount = scriptByteCount
    self.scriptDigest = scriptDigest
    self.operations = operations
    self.isDocumentWide = isDocumentWide
  }

  public var summary: String {
    "\(kind) action at \(location.title) (\(trigger.title))"
  }
}

/// SPC-06: the read-only inventory. Scanning never executes or mutates.
public struct LegacyScriptInventory: Sendable, Equatable {
  public let actions: [ScriptedAction]
  public let scriptedFieldNames: [String]
  public let hasScriptedCalculationOrder: Bool

  public var javascriptActions: [ScriptedAction] { actions.filter(\.isJavaScript) }
  public var automaticActions: [ScriptedAction] { actions.filter { $0.trigger.isAutomatic } }
  public var hasScripts: Bool { !javascriptActions.isEmpty }
  public var hasAnyAction: Bool { !actions.isEmpty }

  public var operations: [DeclaredScriptOperation] {
    var result: Set<DeclaredScriptOperation> = []
    for action in actions {
      for operation in action.operations { result.insert(operation) }
    }
    return DeclaredScriptOperation.allCases.filter { result.contains($0) }
  }

  public var controlledOperations: [DeclaredScriptOperation] {
    operations.filter(\.isControlled)
  }

  public var summary: String {
    if !hasAnyAction { return "No actions or JavaScript are present." }
    var parts = [
      "\(javascriptActions.count) "
        + "\(javascriptActions.count == 1 ? "JavaScript action" : "JavaScript actions")",
      "\(automaticActions.count) automatic",
    ]
    if !controlledOperations.isEmpty {
      parts.append(
        "controlled operations: "
          + controlledOperations.map(\.title).joined(separator: ", "))
    }
    if hasScriptedCalculationOrder { parts.append("scripted calculation order") }
    return parts.joined(separator: "; ") + "."
  }
}

/// SPC-06: the declared disposition for one event.
public struct LegacyScriptEventDecision: Sendable, Equatable, Identifiable {
  public let trigger: LegacyScriptTrigger
  public let declarativeEquivalent: String
  public let supported: Bool
  public let reason: String

  public var id: String { trigger.rawValue }
}

/// SPC-06: the document-level decision report the UI shows.
public struct LegacyScriptCompatibilityReport: Sendable, Equatable {
  public let profileIdentifier: String
  public let inventory: LegacyScriptInventory
  public let eventDecisions: [LegacyScriptEventDecision]
  public let disclosures: [String]
  public let summary: String

  public var isControlled: Bool { true }
  public var removalAvailable: Bool {
    inventory.hasScripts || inventory.hasScriptedCalculationOrder
  }
  public var hasControlledOperations: Bool { !inventory.controlledOperations.isEmpty }
}

public enum LegacyScriptPolicy {
  public static let profileIdentifier = "spdf-legacy-js-isolated-v1"
  public static let executionRule =
    "sPDF never evaluates document JavaScript or automatic actions. Arbitrary "
    + "scripts are disabled by default and are not a compatibility layer; only the "
    + "declared declarative equivalents below are owned behaviour."
  public static let controlledRule =
    "File-system access, network access and application launch/execution are "
    + "controlled: they are inventoried, never performed by sPDF, and an explicit "
    + "user action outside the script layer is required for any equivalent operation."

  public static let eventDecisions: [LegacyScriptEventDecision] = [
    LegacyScriptEventDecision(
      trigger: .calculate,
      declarativeEquivalent: "sPDF private static calculation rules (/SPDFCalculate)",
      supported: true,
      reason: "Sum-style calculations are evaluated by sPDF itself and written as a "
        + "static value plus appearance; no script is executed."),
    LegacyScriptEventDecision(
      trigger: .format,
      declarativeEquivalent: "sPDF private static format rules (/SPDFFormat)",
      supported: true,
      reason: "Number/date formatting is applied by sPDF and stored as a static value; "
        + "other readers show the stored value."),
    LegacyScriptEventDecision(
      trigger: .validate,
      declarativeEquivalent: "sPDF accessible validation rules",
      supported: true,
      reason: "Required/format validation is evaluated by sPDF as declared rules."),
    LegacyScriptEventDecision(
      trigger: .keystroke,
      declarativeEquivalent: "None",
      supported: false,
      reason: "Per-keystroke scripting has no bounded declarative equivalent in this "
        + "profile; imported keystroke scripts are preserved but never executed."),
    LegacyScriptEventDecision(
      trigger: .documentOpen,
      declarativeEquivalent: "None",
      supported: false,
      reason: "No automatic script runs on open. Imported open actions are inert."),
    LegacyScriptEventDecision(
      trigger: .documentWideFunction,
      declarativeEquivalent: "None",
      supported: false,
      reason: "Document-wide JavaScript functions are preserved for byte fidelity but are "
        + "never loaded, compiled or called by sPDF."),
    LegacyScriptEventDecision(
      trigger: .otherAction,
      declarativeEquivalent: "Explicit user commands only",
      supported: false,
      reason: "Actions such as submit, import, launch and URI are inventoried and never "
        + "executed automatically; equivalent operations require explicit user actions."),
  ]

  public static func decision(
    for trigger: LegacyScriptTrigger
  ) -> LegacyScriptEventDecision {
    eventDecisions.first { $0.trigger == trigger }
      ?? LegacyScriptEventDecision(
        trigger: trigger, declarativeEquivalent: "None", supported: false,
        reason: "This automatic event has no declarative equivalent in the profile.")
  }
}

// MARK: - Scanner

public enum LegacyScriptCompatibility {
  /// Inventory every catalog/page/annotation/field action, the document-wide
  /// JavaScript name tree and the scripted calculation order. Read-only.
  public static func inventory(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> LegacyScriptInventory {
    var actions: [ScriptedAction] = []
    var scriptedFieldNames: Set<String> = []
    let catalog = catalogDictionary(in: graph)
    let names = namesDictionary(in: graph)

    func collect(
      _ value: PDFValue, location: ScriptActionLocation, trigger: PDFName,
      owner: ScriptOwner, isDocumentWide: Bool = false, depth: Int = 0
    ) {
      guard depth <= 8, let dictionary = dictionary(value, in: graph) else { return }
      let kind = name(dictionary[PDFName("S")]) ?? "Unknown"
      let isJavaScript = kind == "JavaScript"
      var byteCount: Int?
      var digest: String?
      var detectedOperations: Set<DeclaredScriptOperation> = []
      if isJavaScript {
        if let script = scriptBytes(dictionary[PDFName("JS")], in: graph),
          let text = String(data: script, encoding: .utf8)
            ?? String(data: script, encoding: .isoLatin1)
        {
          byteCount = script.count
          digest = sha256(script)
          detectedOperations.formUnion(operations(inScript: text))
        }
      } else {
        detectedOperations.formUnion(operations(forActionKind: kind))
      }
      let declaredTrigger = LegacyScriptTrigger.from(trigger: trigger, owner: owner)
      let action = ScriptedAction(
        location: location, trigger: declaredTrigger, kind: kind,
        isJavaScript: isJavaScript, scriptByteCount: byteCount, scriptDigest: digest,
        operations: DeclaredScriptOperation.allCases.filter {
          detectedOperations.contains($0)
        },
        isDocumentWide: isDocumentWide)
      actions.append(action)
      if isJavaScript, case .field = location {
        if case .field(let fieldName) = location { scriptedFieldNames.insert(fieldName) }
      }
      if let next = dictionary[PDFName("Next")] {
        switch next {
        case .array(let values):
          for item in values {
            collect(
              item, location: location, trigger: trigger, owner: owner,
              isDocumentWide: isDocumentWide, depth: depth + 1)
          }
        default:
          collect(
            next, location: location, trigger: trigger, owner: owner,
            isDocumentWide: isDocumentWide, depth: depth + 1)
        }
      }
    }

    // Catalog actions.
    if let catalog {
      if let openAction = catalog[PDFName("OpenAction")] {
        collect(
          openAction, location: .catalog, trigger: PDFName("OpenAction"), owner: .catalog)
      }
      if let additional = dictionary(catalog[PDFName("AA")], in: graph) {
        for key in additional.keys.sorted() {
          collect(
            additional[key]!, location: .catalog, trigger: key, owner: .catalog)
        }
      }
    }
    // Document-wide JavaScript name tree.
    if let names, let jsTree = names[PDFName("JavaScript")] {
      for action in nameTreeValues(jsTree, in: graph) {
        collect(
          action, location: .catalog, trigger: PDFName("JavaScript"), owner: .catalog,
          isDocumentWide: true)
      }
    }
    // Page and annotation actions.
    for (pageIndex, pageID) in pageIDs.enumerated() {
      guard case .dictionary(let page)? = graph.objects[pageID] else { continue }
      if let additional = dictionary(page[PDFName("AA")], in: graph) {
        for key in additional.keys.sorted() {
          collect(
            additional[key]!, location: .page(index: pageIndex), trigger: key,
            owner: .page)
        }
      }
      let annotations = (try? AnnotationInventory.annotations(in: graph, pageID: pageID)) ?? []
      for annotation in annotations {
        let location = ScriptActionLocation.annotation(
          pageIndex: pageIndex, annotationIndex: annotation.index)
        if let action = annotation.dictionary[PDFName("A")] {
          collect(action, location: location, trigger: PDFName("A"), owner: .annotation)
        }
        if let additional = dictionary(annotation.dictionary[PDFName("AA")], in: graph) {
          for key in additional.keys.sorted() {
            collect(
              additional[key]!, location: location, trigger: key, owner: .annotation)
          }
        }
      }
    }
    // Form field actions.
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    for field in fields {
      guard let fieldID = field.fieldID,
        case .dictionary(let fieldDictionary)? = graph.objects[fieldID]
      else { continue }
      let location = ScriptActionLocation.field(name: field.name)
      if let action = fieldDictionary[PDFName("A")] {
        collect(action, location: location, trigger: PDFName("A"), owner: .field)
      }
      if let additional = dictionary(fieldDictionary[PDFName("AA")], in: graph) {
        for key in additional.keys.sorted() {
          collect(additional[key]!, location: location, trigger: key, owner: .field)
        }
      }
    }
    // AcroForm-level actions and calculation order.
    var hasScriptedCalculationOrder = false
    if let acroForm = acroFormDictionary(in: graph) {
      if let additional = dictionary(acroForm[PDFName("AA")], in: graph) {
        for key in additional.keys.sorted() {
          collect(additional[key]!, location: .acroForm, trigger: key, owner: .acroForm)
        }
      }
      if case .array(let order)? = acroForm[PDFName("CO")], !order.isEmpty {
        let scripted = actions.contains {
          $0.isJavaScript && $0.trigger == .calculate
        }
        hasScriptedCalculationOrder = scripted
      }
    }
    return LegacyScriptInventory(
      actions: actions,
      scriptedFieldNames: scriptedFieldNames.sorted(),
      hasScriptedCalculationOrder: hasScriptedCalculationOrder)
  }

  public static func report(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> LegacyScriptCompatibilityReport {
    let inventory = self.inventory(in: graph, pageIDs: pageIDs)
    var disclosures = [
      LegacyScriptPolicy.executionRule,
      LegacyScriptPolicy.controlledRule,
      "Imported scripts and actions are preserved byte-for-byte in ordinary opens and "
        + "saves; they are never compiled, evaluated or triggered by sPDF.",
      "Only a digest and byte count of each script are reported; the script source is "
        + "not copied into the compatibility report.",
      "Remove JavaScript Actions writes a new copy without JavaScript actions and their "
        + "action chains; non-JavaScript actions are preserved.",
    ]
    if inventory.hasScriptedCalculationOrder {
      disclosures.append(
        "The AcroForm calculation order references scripted fields; only declared sPDF "
          + "calculation rules are evaluated, never the imported calculation script.")
    }
    let summary: String
    if inventory.hasAnyAction {
      summary =
        inventory.summary
        + " The declared profile is \(LegacyScriptPolicy.profileIdentifier): scripts are "
        + "inert, controlled operations are never performed, and the declarative rules "
        + "above are the only owned behaviour."
    } else {
      summary = "No document JavaScript or actions are present."
    }
    return LegacyScriptCompatibilityReport(
      profileIdentifier: LegacyScriptPolicy.profileIdentifier,
      inventory: inventory,
      eventDecisions: LegacyScriptPolicy.eventDecisions,
      disclosures: disclosures,
      summary: summary)
  }

  // MARK: Action helpers

  static func operations(forActionKind kind: String) -> Set<DeclaredScriptOperation> {
    switch kind {
    case "Launch":
      return [.applicationLaunchOrExecution]
    case "URI":
      return [.networkAccess]
    case "SubmitForm", "ImportData", "ResetForm":
      return [.formDataTransfer]
    case "Sound", "Movie", "Rendition":
      return [.embeddedContentPlayback]
    case "GoTo", "GoToR", "GoToE", "Named", "Thread", "Trans":
      return []
    case "JavaScript":
      return []
    default:
      return [.other]
    }
  }

  /// Conservative keyword classification of a script source. The text is only
  /// scanned for declared capability markers; it is never executed and is not
  /// retained in the inventory.
  static func operations(inScript text: String) -> Set<DeclaredScriptOperation> {
    var result: Set<DeclaredScriptOperation> = []
    let lower = text.lowercased()
    func contains(_ needles: [String]) -> Bool {
      needles.contains { lower.contains($0) }
    }
    if contains([
      "readfileintostream", "writefile", "getfile", "saveas", "importdataobject",
      "exportdataobject", "opendoc", "createDataObject",
    ]) {
      result.insert(.fileSystemAccess)
    }
    if contains([
      "launchurl", "geturl", "submitform", "maildoc", "soap", "upload", "download",
      "post(", "xmlData", ".net.",
    ]) {
      result.insert(.networkAccess)
    }
    if contains(["launch", "exec", "eval", "run(", "execmenuitem"]) {
      result.insert(.applicationLaunchOrExecution)
    }
    if contains([
      "importdataobject", "exportdataobject", "submitform", "resetform", "getfield",
      "setfield", "calculate", "exportastext",
    ]) {
      result.insert(.formDataTransfer)
    }
    if contains(["sound", "movie", "rendition", "play("]) {
      result.insert(.embeddedContentPlayback)
    }
    if contains(["encrypt", "signature", "certify", "security", "certificate"]) {
      result.insert(.securityOrSignature)
    }
    return result
  }

  static func scriptBytes(_ value: PDFValue?, in graph: PDFGraph) -> Data? {
    switch value {
    case .string(let data)?:
      return data
    case .stream(let stream)?:
      return stream.bytes
    case .reference(let id)?:
      return scriptBytes(graph.objects[id], in: graph)
    default:
      return nil
    }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func name(_ value: PDFValue?) -> String? {
    guard case .name(let name)? = value else { return nil }
    return String(decoding: name.bytes, as: UTF8.self)
  }

  static func dictionary(_ value: PDFValue?, in graph: PDFGraph) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary)?:
      return dictionary
    case .reference(let id)?:
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default:
      return nil
    }
  }

  static func catalogDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { return nil }
    return catalog
  }

  static func namesDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard let catalog = catalogDictionary(in: graph) else { return nil }
    return dictionary(catalog[PDFName("Names")], in: graph)
  }

  static func acroFormDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard let catalog = catalogDictionary(in: graph) else { return nil }
    return dictionary(catalog[PDFName("AcroForm")], in: graph)
  }

  static func nameTreeValues(_ value: PDFValue, in graph: PDFGraph) -> [PDFValue] {
    var result: [PDFValue] = []
    var budget = 1_000
    func walk(_ value: PDFValue, depth: Int) {
      guard depth < 16, budget > 0, let dictionary = dictionary(value, in: graph) else { return }
      if case .array(let pairs)? = dictionary[PDFName("Names")] {
        var index = 1
        while index < pairs.count, budget > 0 {
          result.append(pairs[index])
          budget -= 1
          index += 2
        }
      }
      if case .array(let kids)? = dictionary[PDFName("Kids")] {
        for kid in kids { walk(kid, depth: depth + 1) }
      }
    }
    walk(value, depth: 0)
    return result
  }

  static func fieldID(named name: String, fields: [FormField]) -> PDFObjectID? {
    fields.first { $0.name == name }?.fieldID
  }
}

// MARK: - Neutralization command

/// SPC-06: write a copy without JavaScript actions and their action chains.
/// Non-JavaScript actions, form values, appearances and unrelated objects are
/// preserved; the command always requires a full rewrite so a removed script
/// is not recoverable from an earlier revision of the output.
public struct RemoveJavaScriptActionsCommand: PDFEditCommand, Equatable, Sendable {
  public init() {}

  public var name: String { "Remove JavaScript Actions" }
  public var requiresFullRewriteOnSave: Bool { true }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    let pageIDs = (try? PageTreeView(graph: graph).pages) ?? []
    let inventory = LegacyScriptCompatibility.inventory(in: graph, pageIDs: pageIDs)
    guard inventory.hasScripts else {
      throw PDFError(.malformed, "No JavaScript actions are present to remove")
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    scrubCatalog(&graph)
    for pageID in pageIDs {
      guard case .dictionary(var page)? = graph.objects[pageID] else { continue }
      scrubAdditionalActions(&page, in: &graph)
      if case .array(var annotations)? = page[PDFName("Annots")] {
        for index in annotations.indices {
          switch annotations[index] {
          case .reference(let annotationID):
            if let scrubbed = try scrubAnnotation(
              graph.objects[annotationID], in: &graph)
            {
              graph.objects[annotationID] = scrubbed
            }
          case .dictionary:
            if let scrubbed = try scrubAnnotation(annotations[index], in: &graph) {
              annotations[index] = scrubbed
            }
          default:
            break
          }
        }
        page[PDFName("Annots")] = .array(annotations)
      }
      graph.objects[pageID] = .dictionary(page)
    }
    scrubFormFields(&graph)
    return graph
  }

  // MARK: Scrubbing

  private func isJavaScript(_ value: PDFValue, in graph: PDFGraph) -> Bool {
    guard let dictionary = LegacyScriptCompatibility.dictionary(value, in: graph) else {
      return false
    }
    return LegacyScriptCompatibility.name(dictionary[PDFName("S")]) == "JavaScript"
  }

  private func scrubActionValue(_ value: PDFValue, in graph: inout PDFGraph) -> PDFValue? {
    switch value {
    case .array(let values):
      var kept: [PDFValue] = []
      for item in values {
        if let remaining = scrubActionValue(item, in: &graph) { kept.append(remaining) }
      }
      return kept.isEmpty ? nil : .array(kept)
    default:
      if isJavaScript(value, in: graph) { return nil }
      return value
    }
  }

  private func scrubAdditionalActions(
    _ dictionary: inout [PDFName: PDFValue], in graph: inout PDFGraph
  ) {
    guard case .dictionary(var additional)? = dictionary[PDFName("AA")] else { return }
    var changed = false
    for key in Array(additional.keys) {
      guard let value = additional[key] else { continue }
      let scrubbed = scrubActionValue(value, in: &graph)
      if scrubbed == nil {
        additional.removeValue(forKey: key)
        changed = true
      } else if let scrubbed, scrubbed != value {
        additional[key] = scrubbed
        changed = true
      }
    }
    if changed {
      dictionary[PDFName("AA")] = additional.isEmpty ? nil : .dictionary(additional)
    }
  }

  private func scrubAnnotation(
    _ value: PDFValue?, in graph: inout PDFGraph
  ) throws -> PDFValue? {
    switch value {
    case .reference(let id)?:
      if case .dictionary(var dictionary)? = graph.objects[id] {
        if let action = dictionary[PDFName("A")],
          scrubActionValue(action, in: &graph) == nil
        {
          dictionary[PDFName("A")] = nil
        }
        scrubAdditionalActions(&dictionary, in: &graph)
        graph.objects[id] = .dictionary(dictionary)
      }
      return value
    case .dictionary(var dictionary)?:
      if let action = dictionary[PDFName("A")],
        scrubActionValue(action, in: &graph) == nil
      {
        dictionary[PDFName("A")] = nil
      }
      scrubAdditionalActions(&dictionary, in: &graph)
      return .dictionary(dictionary)
    default:
      return value
    }
  }

  private func scrubCatalog(_ graph: inout PDFGraph) {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(var catalog)? = graph.objects[rootID]
    else { return }
    if let openAction = catalog[PDFName("OpenAction")] {
      switch openAction {
      case .array(let values):
        let kept = values.compactMap { scrubActionValue($0, in: &graph) }
        catalog[PDFName("OpenAction")] = kept.isEmpty ? nil : .array(kept)
      default:
        if isJavaScript(openAction, in: graph) { catalog[PDFName("OpenAction")] = nil }
      }
    }
    scrubAdditionalActions(&catalog, in: &graph)
    if case .dictionary(var names)? = catalog[PDFName("Names")] {
      names[PDFName("JavaScript")] = nil
      catalog[PDFName("Names")] = names.isEmpty ? nil : .dictionary(names)
    } else if case .reference(let namesID)? = catalog[PDFName("Names")],
      case .dictionary(var names)? = graph.objects[namesID]
    {
      names[PDFName("JavaScript")] = nil
      graph.objects[namesID] = names.isEmpty ? PDFValue.dictionary([:]) : .dictionary(names)
      if names.isEmpty { catalog[PDFName("Names")] = nil }
    }
    if case .dictionary(var acro)? = catalog[PDFName("AcroForm")] {
      scrubAdditionalActions(&acro, in: &graph)
      catalog[PDFName("AcroForm")] = .dictionary(acro)
    } else if case .reference(let acroID)? = catalog[PDFName("AcroForm")],
      case .dictionary(var acro)? = graph.objects[acroID]
    {
      scrubAdditionalActions(&acro, in: &graph)
      graph.objects[acroID] = .dictionary(acro)
    }
    graph.objects[rootID] = .dictionary(catalog)
  }

  private func scrubFormFields(_ graph: inout PDFGraph) {
    guard case .reference(let rootID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[rootID]
    else { return }
    if case .dictionary(var acro)? = catalog[PDFName("AcroForm")] {
      if case .array(let fields)? = acro[PDFName("Fields")] {
        acro[PDFName("Fields")] = .array(fields.map { scrubFieldValue($0, in: &graph) })
      }
      var updated = catalog
      updated[PDFName("AcroForm")] = .dictionary(acro)
      graph.objects[rootID] = .dictionary(updated)
    } else if case .reference(let acroID)? = catalog[PDFName("AcroForm")],
      case .dictionary(var acro)? = graph.objects[acroID]
    {
      if case .array(let fields)? = acro[PDFName("Fields")] {
        acro[PDFName("Fields")] = .array(fields.map { scrubFieldValue($0, in: &graph) })
      }
      graph.objects[acroID] = .dictionary(acro)
    }
  }

  private func scrubFieldValue(_ value: PDFValue, in graph: inout PDFGraph) -> PDFValue {
    switch value {
    case .reference(let id):
      if case .dictionary(var dictionary)? = graph.objects[id] {
        scrubFieldDictionary(&dictionary, in: &graph)
        graph.objects[id] = .dictionary(dictionary)
      }
      return value
    case .dictionary(var dictionary):
      scrubFieldDictionary(&dictionary, in: &graph)
      return .dictionary(dictionary)
    default:
      return value
    }
  }

  private func scrubFieldDictionary(
    _ dictionary: inout [PDFName: PDFValue], in graph: inout PDFGraph
  ) {
    if let action = dictionary[PDFName("A")],
      scrubActionValue(action, in: &graph) == nil
    {
      dictionary[PDFName("A")] = nil
    }
    scrubAdditionalActions(&dictionary, in: &graph)
    if case .array(let kids)? = dictionary[PDFName("Kids")] {
      dictionary[PDFName("Kids")] = .array(kids.map { scrubFieldValue($0, in: &graph) })
    }
  }
}
