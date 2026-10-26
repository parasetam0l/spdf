import Foundation
import PDFCore

// MARK: - FRM-06 round-trip-friendly form data

/// FRM-06: one field in the portable, viewer-neutral round-trip bundle. Only
/// values and semantic field facts are carried - never appearance streams,
/// NeedAppearances or other viewer-specific cleanup instructions.
public struct FormRoundTripField: Sendable, Equatable {
  public let name: String
  public let kind: String
  public let value: String?
  public let selectedValues: [String]?
  public let buttonState: String?
  public let required: Bool
  public let readOnly: Bool
  public let tooltip: String?
  public let maxLength: Int?

  public init(
    name: String, kind: String, value: String? = nil,
    selectedValues: [String]? = nil, buttonState: String? = nil,
    required: Bool = false, readOnly: Bool = false, tooltip: String? = nil,
    maxLength: Int? = nil
  ) {
    self.name = name
    self.kind = kind
    self.value = value
    self.selectedValues = selectedValues
    self.buttonState = buttonState
    self.required = required
    self.readOnly = readOnly
    self.tooltip = tooltip
    self.maxLength = maxLength
  }

  var portableValue: FormFieldValue {
    FormFieldValue(
      name: name, kind: kind, value: value,
      selectedIndex: nil, buttonState: buttonState, selectedValues: selectedValues)
  }
}

/// FRM-06: external behavior a round-trip import/export must identify but never
/// execute or mimic (JavaScript/action dictionaries, calculation order, XFA).
public struct FormUnsupportedExternalAction: Sendable, Equatable {
  public let action: String
  public let field: String?
  public let reason: String

  public init(action: String, field: String? = nil, reason: String) {
    self.action = action
    self.field = field
    self.reason = reason
  }
}

/// FRM-06: the portable form-data bundle. Its JSON schema contains values and
/// field semantics only; the viewerInstructionKeys list names the keys that
/// must not be exported or accepted.
public struct FormRoundTripBundle: Sendable, Equatable {
  public static let schemaVersion = 1
  /// Keys that would ask a viewer to clean up, generate or replace appearances.
  public static let viewerInstructionKeys: Set<String> = [
    "NeedAppearances", "AP", "DA", "DR", "XFA", "AA", "JavaScript", "AcroForm",
    "Acquire", "Cleanup",
  ]

  public let fields: [FormRoundTripField]
  public let unsupported: [FormUnsupportedExternalAction]
  public let notes: [String]

  public init(
    fields: [FormRoundTripField],
    unsupported: [FormUnsupportedExternalAction] = [],
    notes: [String] = []
  ) {
    self.fields = fields
    self.unsupported = unsupported
    self.notes = notes
  }

  public var summaryLines: [String] {
    var lines: [String] = []
    lines.append(
      "Round-trip form data: \(fields.count) field value(s); "
        + "\(unsupported.count) unsupported external action(s).")
    if !unsupported.isEmpty {
      for action in unsupported {
        let name = action.field.map { " on \($0)" } ?? ""
        lines.append("Unsupported\(name): \(action.action) - \(action.reason)")
      }
    }
    lines.append(
      "Values only: no NeedAppearances, appearance streams, DA or DR are exported or "
        + "accepted; an import changes values, never viewer cleanup instructions.")
    return lines
  }

  /// Deterministic JSON schema (sorted keys, no viewer-specific instruction
  /// keys), suitable for round trips between independent readers.
  public func jsonData() throws -> Data {
    var entries: [[String: Any]] = []
    for field in fields {
      var entry: [String: Any] = [
        "kind": field.kind,
        "name": field.name,
        "readOnly": field.readOnly,
        "required": field.required,
      ]
      if let value = field.value { entry["value"] = value }
      if let selected = field.selectedValues, !selected.isEmpty {
        entry["selectedValues"] = selected
      }
      if let state = field.buttonState { entry["buttonState"] = state }
      if let tooltip = field.tooltip, !tooltip.isEmpty { entry["tooltip"] = tooltip }
      if let maxLength = field.maxLength { entry["maxLength"] = maxLength }
      entries.append(entry)
    }
    var unsupportedEntries: [[String: Any]] = []
    for action in unsupported {
      var entry: [String: Any] = ["action": action.action, "reason": action.reason]
      if let field = action.field { entry["field"] = field }
      unsupportedEntries.append(entry)
    }
    let payload: [String: Any] = [
      "schemaVersion": Self.schemaVersion,
      "fields": entries,
      "unsupported": unsupportedEntries,
      "notes": notes,
    ]
    for key in payload.keys where Self.viewerInstructionKeys.contains(key) {
      throw PDFError(.unsupported, "The round-trip bundle must not carry viewer instructions")
    }
    return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
  }

  public var jsonText: String { (try? jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// FRM-06: capture, verify and apply the portable form-data bundle without
/// touching appearances or asking any viewer to clean up.
public enum FormRoundTripData {
  public static func capture(
    in graph: PDFGraph, pageIDs: [PDFObjectID],
    unsupportedExternalActions: [FormUnsupportedExternalAction] = []
  ) throws -> FormRoundTripBundle {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let values = try FormValues.values(in: graph, pageIDs: pageIDs)
    var captured: [FormRoundTripField] = []
    var unsupported = unsupportedExternalActions
    for field in fields {
      switch field.kind {
      case .text, .choice, .button where !field.isPushButton:
        let value = values.first { $0.name == field.name }
        captured.append(
          FormRoundTripField(
            name: field.name,
            kind: value?.kind ?? kindName(field.kind),
            value: value?.value,
            selectedValues: value?.selectedValues,
            buttonState: value?.buttonState,
            required: field.isRequired,
            readOnly: field.isReadOnly,
            tooltip: fieldDictionary(field: field, in: graph)
              .flatMap { dictionary -> String? in
                guard case .string(let data)? = dictionary[PDFName("TU")] else { return nil }
                return AnnotationText.decode(data)
              },
            maxLength: field.maxLength))
      case .signature:
        unsupported.append(
          FormUnsupportedExternalAction(
            action: "signature field", field: field.name,
            reason: "signature data is not exported as form values"))
      default:
        if field.isPushButton {
          unsupported.append(
            FormUnsupportedExternalAction(
              action: "push-button action", field: field.name,
              reason: "button actions are never executed or carried as values"))
        }
      }
    }
    unsupported.append(contentsOf: detectExternalActions(in: graph, pageIDs: pageIDs))
    var notes = [
      "Values and field semantics only; appearances and NeedAppearances are not carried.",
      "Importing these values never writes viewer cleanup instructions.",
    ]
    if !unsupported.isEmpty {
      notes.append("Unsupported external actions are listed above and are not executed.")
    }
    return FormRoundTripBundle(
      fields: captured.sorted { $0.name < $1.name },
      unsupported: unsupported, notes: notes)
  }

  /// Parse a portable bundle. Files that request viewer-specific cleanup or
  /// execution are refused instead of being silently applied.
  public static func parse(_ data: Data) throws -> FormRoundTripBundle {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["schemaVersion"] as? Int, version == FormRoundTripBundle.schemaVersion
    else {
      throw PDFError(.malformed, "The form-data bundle is not a supported schema")
    }
    for key in object.keys where FormRoundTripBundle.viewerInstructionKeys.contains(key) {
      throw PDFError(
        .unsupported,
        "The form-data bundle asks for viewer-specific cleanup instructions (\(key)); "
          + "only plain field values are accepted")
    }
    let entries = object["fields"] as? [[String: Any]] ?? []
    let unsupportedEntries = object["unsupported"] as? [[String: Any]] ?? []
    let notes = object["notes"] as? [String] ?? []
    var fields: [FormRoundTripField] = []
    for entry in entries {
      guard let name = entry["name"] as? String, !name.isEmpty,
        let kind = entry["kind"] as? String
      else { continue }
      fields.append(
        FormRoundTripField(
          name: name, kind: kind, value: entry["value"] as? String,
          selectedValues: entry["selectedValues"] as? [String],
          buttonState: entry["buttonState"] as? String,
          required: entry["required"] as? Bool ?? false,
          readOnly: entry["readOnly"] as? Bool ?? false,
          tooltip: entry["tooltip"] as? String,
          maxLength: entry["maxLength"] as? Int))
    }
    var unsupported: [FormUnsupportedExternalAction] = []
    for entry in unsupportedEntries {
      guard let action = entry["action"] as? String, let reason = entry["reason"] as? String
      else { continue }
      unsupported.append(
        FormUnsupportedExternalAction(
          action: action, field: entry["field"] as? String, reason: reason))
    }
    return FormRoundTripBundle(
      fields: fields.sorted { $0.name < $1.name }, unsupported: unsupported, notes: notes)
  }

  /// Map the bundle's values onto the target document's own fields. Import
  /// writes values only: no appearance, DA, DR or NeedAppearances changes.
  public static func commands(
    for bundle: FormRoundTripBundle, in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> (commands: [any PDFEditCommand], skipped: [String], ambiguous: [String]) {
    try FormValues.commands(
      for: bundle.fields.map(\.portableValue), in: graph, pageIDs: pageIDs)
  }

  /// Compare two captured bundles field-by-field for an honest round-trip
  /// report (missing, extra, changed).
  public static func compare(
    original: FormRoundTripBundle, imported: FormRoundTripBundle
  ) -> FormRoundTripComparison {
    let originalByName = Dictionary(uniqueKeysWithValues: original.fields.map { ($0.name, $0) })
    let importedByName = Dictionary(uniqueKeysWithValues: imported.fields.map { ($0.name, $0) })
    var changed: [String] = []
    var missing: [String] = []
    var extra: [String] = []
    for (name, field) in originalByName.sorted(by: { $0.key < $1.key }) {
      guard let importedField = importedByName[name] else {
        missing.append(name)
        continue
      }
      if field.value != importedField.value
        || field.selectedValues != importedField.selectedValues
        || field.buttonState != importedField.buttonState
        || field.kind != importedField.kind
      {
        changed.append(name)
      }
    }
    for name in importedByName.keys.sorted() where originalByName[name] == nil {
      extra.append(name)
    }
    return FormRoundTripComparison(
      changed: changed, missing: missing, extra: extra,
      fieldCount: originalByName.count)
  }

  // MARK: Internals

  static func kindName(_ kind: FormField.Kind) -> String {
    switch kind {
    case .text: return "text"
    case .choice: return "choice"
    case .button: return "button"
    case .signature: return "signature"
    default: return "unknown"
    }
  }

  static func fieldDictionary(
    field: FormField, in graph: PDFGraph
  ) -> [PDFName: PDFValue]? {
    guard let fieldID = field.fieldID,
      case .dictionary(let dictionary)? = graph.objects[fieldID]
    else { return nil }
    return dictionary
  }

  /// Identify external behavior without executing it: field/widget additional
  /// actions, push-button actions, XFA, calculation order and document-level
  /// JavaScript names. The round-trip bundle carries values only.
  static func detectExternalActions(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> [FormUnsupportedExternalAction] {
    var actions: [FormUnsupportedExternalAction] = []
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    for field in fields {
      var dictionaries: [(String, [PDFName: PDFValue])] = []
      if let dictionary = fieldDictionary(field: field, in: graph) {
        dictionaries.append(("field", dictionary))
      }
      for widget in field.widgets {
        if let widgetID = widget.objectID,
          case .dictionary(let dictionary)? = graph.objects[widgetID]
        {
          dictionaries.append(("widget", dictionary))
        }
      }
      for (owner, dictionary) in dictionaries {
        if let aa = dictionary[PDFName("AA")] {
          let keys = actionKeys(aa)
          actions.append(
            FormUnsupportedExternalAction(
              action: "additional actions" + (keys.isEmpty ? "" : " [\(keys)]"),
              field: field.name,
              reason: owner + " actions are never executed"))
        }
        if dictionary[PDFName("A")] != nil {
          actions.append(
            FormUnsupportedExternalAction(
              action: "activation action", field: field.name,
              reason: "button activation actions are never executed"))
        }
      }
    }
    if let catalog = catalogDictionary(in: graph) {
      if let acroFormValue = catalog[PDFName("AcroForm")],
        let acroForm = dictionaryValue(acroFormValue, in: graph)
      {
        if acroForm[PDFName("XFA")] != nil {
          actions.append(
            FormUnsupportedExternalAction(
              action: "XFA form data",
              reason: "XFA packets are not interpreted or exported as values"))
        }
        if acroForm[PDFName("CO")] != nil {
          actions.append(
            FormUnsupportedExternalAction(
              action: "calculation order",
              reason: "calculation scripts are never executed; static values are exported"))
        }
      }
      if let namesValue = catalog[PDFName("Names")],
        let names = dictionaryValue(namesValue, in: graph),
        names[PDFName("JavaScript")] != nil
      {
        actions.append(
          FormUnsupportedExternalAction(
            action: "document JavaScript",
            reason: "document scripts are never executed; values are exported as-is"))
      }
    }
    return actions
  }

  static func actionKeys(_ value: PDFValue) -> String {
    guard case .dictionary(let dictionary) = value else { return "" }
    return dictionary.keys.map { String(decoding: $0.bytes, as: UTF8.self) }.sorted()
      .joined(separator: ",")
  }

  static func catalogDictionary(in graph: PDFGraph) -> [PDFName: PDFValue]? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID]
    else { return nil }
    return catalog
  }

  static func dictionaryValue(_ value: PDFValue, in graph: PDFGraph) -> [PDFName: PDFValue]? {
    switch value {
    case .dictionary(let dictionary): return dictionary
    case .reference(let id):
      if case .dictionary(let dictionary)? = graph.objects[id] { return dictionary }
      return nil
    default: return nil
    }
  }
}

public struct FormRoundTripComparison: Sendable, Equatable {
  public let changed: [String]
  public let missing: [String]
  public let extra: [String]
  public let fieldCount: Int

  public var isRoundTripClean: Bool {
    changed.isEmpty && missing.isEmpty && extra.isEmpty
  }

  public var summaryLines: [String] {
    var lines: [String] = []
    lines.append(
      "Round-trip comparison: \(fieldCount) field(s); changed: \(changed.count); "
        + "missing: \(missing.count); extra: \(extra.count).")
    if !changed.isEmpty { lines.append("Changed: " + changed.joined(separator: ", ")) }
    if !missing.isEmpty { lines.append("Missing: " + missing.joined(separator: ", ")) }
    if !extra.isEmpty { lines.append("Extra: " + extra.joined(separator: ", ")) }
    if isRoundTripClean { lines.append("All values round-tripped exactly.") }
    return lines
  }
}
