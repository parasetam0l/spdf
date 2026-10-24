import Foundation
import PDFCore

/// P24-022: one exported field value in the local exchange schema.
public struct FormFieldValue: Sendable, Equatable {
  public let name: String
  public let kind: String
  public let value: String?
  public let selectedIndex: Int?
  public let buttonState: String?

  public init(
    name: String, kind: String, value: String? = nil, selectedIndex: Int? = nil,
    buttonState: String? = nil
  ) {
    self.name = name
    self.kind = kind
    self.value = value
    self.selectedIndex = selectedIndex
    self.buttonState = buttonState
  }
}

/// P24-022: explicit local import/export of supported field values as JSON
/// with a schema version. Unknown fields are reported, never guessed.
public enum FormValues {
  public static let schemaVersion = 1

  public static func export(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws -> Data {
    let values = try self.values(in: graph, pageIDs: pageIDs)
    var entries: [[String: Any]] = []
    for field in values {
      switch field.kind {
      case "text":
        entries.append(["name": field.name, "kind": "text", "value": field.value ?? ""])
      case "choice":
        entries.append([
          "name": field.name, "kind": "choice", "value": field.value ?? "",
          "selectedIndex": field.selectedIndex ?? -1,
        ])
      case "button":
        entries.append([
          "name": field.name, "kind": "button", "state": field.buttonState ?? "Off",
        ])
      default:
        continue
      }
    }
    let payload: [String: Any] = ["schemaVersion": schemaVersion, "fields": entries]
    return try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
  }

  /// Current values in the portable exchange shape. FDF/XFDF writers reuse
  /// this instead of re-reading the form inventory.
  public static func values(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> [FormFieldValue] {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    var values: [FormFieldValue] = []
    for field in fields {
      switch field.kind {
      case .text:
        values.append(
          FormFieldValue(name: field.name, kind: "text", value: field.stringValue ?? ""))
      case .choice:
        values.append(
          FormFieldValue(
            name: field.name, kind: "choice", value: field.stringValue ?? "",
            selectedIndex: field.selectedIndexes.first ?? -1))
      case .button where !field.isPushButton:
        values.append(
          FormFieldValue(
            name: field.name, kind: "button",
            buttonState: field.buttonState.map { String(decoding: $0.bytes, as: UTF8.self) }
              ?? "Off"))
      default:
        continue
      }
    }
    return values
  }

  public static func parse(_ data: Data) throws -> [FormFieldValue] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["schemaVersion"] as? Int, version == schemaVersion,
      let entries = object["fields"] as? [[String: Any]]
    else {
      throw PDFError(.malformed, "Form value import is not a supported schema")
    }
    return entries.compactMap { entry in
      guard let name = entry["name"] as? String, let kind = entry["kind"] as? String else {
        return nil
      }
      return FormFieldValue(
        name: name, kind: kind, value: entry["value"] as? String,
        selectedIndex: entry["selectedIndex"] as? Int, buttonState: entry["state"] as? String)
    }
  }

  /// Map imported values to fill commands. Fields that are missing or whose
  /// type does not match are returned in `skipped` instead of being guessed.
  /// P25-023: when a document contains several fields with the same full name
  /// (possible in documents authored elsewhere; radio groups share one parent
  /// field and are not affected), the first canonical field is filled and the
  /// name is reported in `ambiguous` so the caller can surface the shadowing.
  public static func commands(
    for values: [FormFieldValue], in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> (commands: [any PDFEditCommand], skipped: [String], ambiguous: [String]) {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let nameCounts = Dictionary(grouping: fields, by: \.name).mapValues(\.count)
    var commands: [any PDFEditCommand] = []
    var skipped: [String] = []
    var ambiguous: [String] = []
    for value in values {
      if (nameCounts[value.name] ?? 0) > 1, !ambiguous.contains(value.name) {
        ambiguous.append(value.name)
      }
      guard let field = fields.first(where: { $0.name == value.name }) else {
        skipped.append(value.name)
        continue
      }
      guard !field.isReadOnly else {
        skipped.append(value.name)
        continue
      }
      switch (field.kind, value.kind) {
      case (.text, "text"):
        commands.append(SetFormTextCommand(fieldName: value.name, text: value.value ?? ""))
      case (.choice, "choice"):
        guard let exportValue = value.value, !exportValue.isEmpty,
          field.options.contains(where: { $0.export == exportValue })
        else {
          skipped.append(value.name)
          continue
        }
        commands.append(SetFormChoiceCommand(fieldName: value.name, exportValue: exportValue))
      case (.button, "button"):
        let state = value.buttonState.flatMap { $0 == "Off" ? nil : PDFName($0) }
        commands.append(SetFormButtonStateCommand(fieldName: value.name, state: state))
      default:
        skipped.append(value.name)
      }
    }
    return (commands, skipped, ambiguous)
  }
}
