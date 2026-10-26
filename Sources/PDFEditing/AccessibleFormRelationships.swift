import Foundation
import PDFCore

// A11Y-04: accessible form relationships and the combined document narration.
// Field labels (/TU with a field-name fallback), kinds, required state, widget
// count, page positions and the current tab order are exposed as a read model;
// the narration is the screen-reader-shaped transcript used for qualification.

public struct AccessibleFormFieldRelationship: Sendable, Equatable, Identifiable {
  public enum LabelSource: String, Sendable, Equatable {
    case tooltip
    case fieldName
  }

  public var id: String { name }
  public let name: String
  public let label: String
  public let labelSource: LabelSource
  public let kind: String
  public let required: Bool
  public let readOnly: Bool
  /// Zero-based tab position in the document's current field order.
  public let tabOrderIndex: Int
  public let pageIndex: Int?
  public let rect: [Double]?
  public let widgetCount: Int
  public let valueSummary: String?

  public init(
    name: String, label: String, labelSource: LabelSource, kind: String,
    required: Bool, readOnly: Bool, tabOrderIndex: Int, pageIndex: Int?, rect: [Double]?,
    widgetCount: Int, valueSummary: String?
  ) {
    self.name = name
    self.label = label
    self.labelSource = labelSource
    self.kind = kind
    self.required = required
    self.readOnly = readOnly
    self.tabOrderIndex = tabOrderIndex
    self.pageIndex = pageIndex
    self.rect = rect
    self.widgetCount = widgetCount
    self.valueSummary = valueSummary
  }

  public var positionLabel: String {
    guard let pageIndex else { return "no page position" }
    return "page " + String(pageIndex + 1)
  }
}

public struct AccessibleFormIssue: Sendable, Equatable, Identifiable {
  public enum Kind: String, Sendable, Equatable {
    case missingLabel
    case duplicateName
  }

  public let kind: Kind
  public let fieldName: String
  public let message: String
  public var id: String { kind.rawValue + "/" + fieldName }
  public init(kind: Kind, fieldName: String, message: String) {
    self.kind = kind
    self.fieldName = fieldName
    self.message = message
  }
}

public struct AccessibleFormRelationships: Sendable, Equatable {
  public let fields: [AccessibleFormFieldRelationship]
  public let issues: [AccessibleFormIssue]
  /// True when the order is the AcroForm field order (no explicit /CO was read).
  public let tabOrderIsDocumentOrder: Bool

  public init(
    fields: [AccessibleFormFieldRelationship], issues: [AccessibleFormIssue],
    tabOrderIsDocumentOrder: Bool
  ) {
    self.fields = fields
    self.issues = issues
    self.tabOrderIsDocumentOrder = tabOrderIsDocumentOrder
  }

  public var labelledFieldCount: Int {
    fields.filter { $0.labelSource == .tooltip }.count
  }
  public var unlabelledFieldCount: Int { fields.count - labelledFieldCount }
  public var summary: String {
    guard !fields.isEmpty else { return "No form fields." }
    var text = String(fields.count) + " form field" + (fields.count == 1 ? "" : "s")
    text += ", " + String(labelledFieldCount) + " with a readable label"
    if unlabelledFieldCount > 0 {
      text += ", " + String(unlabelledFieldCount) + " falling back to the field name"
    }
    text += ", tab order " + (tabOrderIsDocumentOrder ? "document order." : "explicit order.")
    return text
  }

  /// A11Y-04: screen-reader-shaped description of field relationships.
  public func narrationLines() -> [String] {
    guard !fields.isEmpty else { return ["Form: no fillable fields."] }
    var lines: [String] = []
    lines.append(
      "Form: " + String(fields.count) + " field" + (fields.count == 1 ? "" : "s")
        + ", tab order " + (tabOrderIsDocumentOrder ? "document order." : "explicit order."))
    for field in fields {
      var text = "Field " + String(field.tabOrderIndex + 1) + ", \"" + field.label + "\""
      if field.labelSource == .fieldName {
        text += " (no tooltip; accessible name is the field name \"" + field.name + "\")"
      } else if field.label != field.name {
        text += " (field name \"" + field.name + "\")"
      }
      text += ", " + field.kind
      if field.required { text += ", required" }
      if field.readOnly { text += ", read-only" }
      if field.widgetCount > 1 { text += ", " + String(field.widgetCount) + " widgets" }
      text += ", " + field.positionLabel
      if let valueSummary = field.valueSummary, !valueSummary.isEmpty {
        text += ", value \"" + valueSummary + "\""
      }
      lines.append(text + ".")
    }
    lines.append(
      "Tab order: " + fields.sorted { $0.tabOrderIndex < $1.tabOrderIndex }
        .map(\.label).joined(separator: ", ") + ".")
    for issue in issues { lines.append("Issue: " + issue.message) }
    return lines
  }
}

/// A11Y-04: the combined table and form relationship model.
public struct AccessibleDocumentRelationships: Sendable, Equatable {
  public let tables: [AccessibleTable]
  public let form: AccessibleFormRelationships

  public init(tables: [AccessibleTable], form: AccessibleFormRelationships) {
    self.tables = tables
    self.form = form
  }

  public var tableIssueCount: Int { tables.reduce(0) { $0 + $1.issues.count } }
  public var summary: String {
    var text = String(tables.count) + " table" + (tables.count == 1 ? "" : "s")
    text += ", " + String(tableIssueCount) + " table relationship issue"
      + (tableIssueCount == 1 ? "" : "s") + "; " + form.summary
    return text
  }

  /// A11Y-04: one transcript a screen reader should be able to follow, plus the
  /// explicit note that this is a structural description rather than a
  /// conformance claim.
  public func narrationLines() -> [String] {
    var lines: [String] = []
    for (index, table) in tables.enumerated() {
      lines.append(contentsOf: table.narrationLines(tableNumber: index + 1))
    }
    lines.append(contentsOf: form.narrationLines())
    lines.append(
      "Note: this transcript describes structure relationships only; it is not an "
        + "accessibility-conformance claim.")
    return lines
  }

  public func transcript() -> String { narrationLines().joined(separator: "\n") }
}

public enum AccessibleDocumentRelationshipsBuilder {
  public static func build(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> AccessibleDocumentRelationships {
    let tables = AccessibleTableStructure.tables(in: graph, pageIDs: pageIDs)
    return AccessibleDocumentRelationships(
      tables: tables, form: formRelationships(in: graph, pageIDs: pageIDs))
  }

  public static func formRelationships(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> AccessibleFormRelationships {
    let inventory = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    let accessible = (try? FormAccessibleValidation.fields(in: graph, pageIDs: pageIDs)) ?? []
    var issues: [AccessibleFormIssue] = []
    var nameCounts: [String: Int] = [:]
    for field in inventory { nameCounts[field.name, default: 0] += 1 }
    for (name, count) in nameCounts.sorted(by: { $0.key < $1.key }) where count > 1 {
      issues.append(
        AccessibleFormIssue(
          kind: .duplicateName, fieldName: name,
          message: name + " appears " + String(count) + " times in the AcroForm; the tab order "
            + "cannot distinguish the copies."))
    }
    let tabOrder = FormTabOrder.current(fields: inventory)
    var fields: [AccessibleFormFieldRelationship] = []
    for (index, field) in inventory.enumerated() {
      let label = accessible.first { $0.name == field.name }?.label ?? field.name
      let labelSource: AccessibleFormFieldRelationship.LabelSource =
        label == field.name ? .fieldName : .tooltip
      if labelSource == .fieldName {
        issues.append(
          AccessibleFormIssue(
            kind: .missingLabel, fieldName: field.name,
            message: field.name + " has no tooltip (/TU); readers fall back to the field name."))
      }
      let widget = field.widgets.first { $0.pageIndex != nil && $0.rect != nil }
        ?? field.widgets.first
      let value = FormAccessibleValidation.accessibleValue(field)
      fields.append(
        AccessibleFormFieldRelationship(
          name: field.name, label: label, labelSource: labelSource,
          kind: field.kind.rawValue,
          required: field.isRequired, readOnly: field.isReadOnly,
          tabOrderIndex: tabOrder.firstIndex(of: field.name) ?? index,
          pageIndex: widget?.pageIndex, rect: widget?.rect,
          widgetCount: field.widgets.count,
          valueSummary: value?.isEmpty == false ? value : nil))
    }
    return AccessibleFormRelationships(
      fields: fields, issues: issues, tabOrderIsDocumentOrder: true)
  }
}
