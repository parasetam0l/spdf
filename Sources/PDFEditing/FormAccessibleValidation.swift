import Foundation
import PDFCore

// FRM-06: accessible form validation and declared conditional behavior. The
// layer is read-only: it inspects the existing form (never executes an imported
// action or script), turns findings into readable labels with page/rect focus
// targets, and evaluates caller-declared show/hide rules so keyboard and
// screen-reader users get the right error and focus.

public enum FormAccessibleIssueKind: String, Sendable, CaseIterable, Equatable {
  case requiredField
  case valueTooLong
  case choiceSelection
  case duplicateName
  case readOnlyRequired
  case unsupportedExternalAction
  case other

  public var title: String {
    switch self {
    case .requiredField: return "Required field"
    case .valueTooLong: return "Value too long"
    case .choiceSelection: return "Choice selection"
    case .duplicateName: return "Duplicate field name"
    case .readOnlyRequired: return "Read-only required field"
    case .unsupportedExternalAction: return "Unsupported external action"
    case .other: return "Form validation"
    }
  }
}

/// FRM-06: accessible severity. Errors block submission; warnings are visible
/// but not focus-blocking notes.
public enum FormAccessibleSeverity: String, Sendable, CaseIterable, Equatable {
  case error
  case warning
  case note

  public var label: String {
    switch self {
    case .error: return "Error"
    case .warning: return "Warning"
    case .note: return "Note"
    }
  }
}

/// FRM-06: one validation finding with everything a screen reader and the
/// keyboard focus flow need: readable label, message, page/rect and a stable
/// id for focus movement.
public struct FormAccessibleIssue: Sendable, Equatable, Identifiable {
  public let id: String
  public let kind: FormAccessibleIssueKind
  public let severity: FormAccessibleSeverity
  public let fieldName: String?
  /// Readable label: the field tooltip (/TU) when present, otherwise the name.
  public let label: String
  public let message: String
  public let disclosure: String
  public let pageIndex: Int?
  public let rect: [Double]?
  /// Reading-order position among the focusable issues (0 is the first).
  public let focusOrder: Int?

  public init(
    id: String, kind: FormAccessibleIssueKind, severity: FormAccessibleSeverity,
    fieldName: String?, label: String, message: String, disclosure: String,
    pageIndex: Int?, rect: [Double]?, focusOrder: Int?
  ) {
    self.id = id
    self.kind = kind
    self.severity = severity
    self.fieldName = fieldName
    self.label = label
    self.message = message
    self.disclosure = disclosure
    self.pageIndex = pageIndex
    self.rect = rect
    self.focusOrder = focusOrder
  }

  public var isFocusable: Bool { focusOrder != nil }

  public var focusInstruction: String {
    guard let pageIndex else {
      return "Review the form-wide issue and correct the field values."
    }
    return "Move focus to " + label + " on page " + String(pageIndex + 1) + "."
  }

  public var announcement: String {
    var text = severity.label + ": " + label + ". " + message
    if !disclosure.isEmpty { text += " " + disclosure }
    if let pageIndex { text += " Page " + String(pageIndex + 1) + "." }
    return text
  }
}

/// FRM-06: one fillable field with its accessible name, value and focus target.
public struct FormAccessibleField: Sendable, Equatable, Identifiable {
  public var id: String { name }
  public let name: String
  public let label: String
  public let kind: FormField.Kind
  public let required: Bool
  public let readOnly: Bool
  public let value: String?
  public let pageIndex: Int?
  public let rect: [Double]?

  public init(
    name: String, label: String, kind: FormField.Kind, required: Bool, readOnly: Bool,
    value: String?, pageIndex: Int?, rect: [Double]?
  ) {
    self.name = name
    self.label = label
    self.kind = kind
    self.required = required
    self.readOnly = readOnly
    self.value = value
    self.pageIndex = pageIndex
    self.rect = rect
  }

  public var summary: String {
    var parts: [String] = [label]
    if label != name { parts.append("(" + name + ")") }
    if required { parts.append("required") }
    if readOnly { parts.append("read-only") }
    if let value, !value.isEmpty { parts.append("value: " + value) }
    return parts.joined(separator: ", ")
  }
}

/// FRM-06: the fill-time accessible validation report.
public struct FormAccessibleValidationReport: Sendable, Equatable {
  public let fields: [FormAccessibleField]
  public let issues: [FormAccessibleIssue]
  public let focusIssueID: String?
  public let announcements: [String]
  public let supportedValidationLines: [String]
  public let unsupportedExternalActions: [String]
  public let summaryLines: [String]

  public init(
    fields: [FormAccessibleField], issues: [FormAccessibleIssue],
    focusIssueID: String?, announcements: [String],
    supportedValidationLines: [String], unsupportedExternalActions: [String],
    summaryLines: [String]
  ) {
    self.fields = fields
    self.issues = issues
    self.focusIssueID = focusIssueID
    self.announcements = announcements
    self.supportedValidationLines = supportedValidationLines
    self.unsupportedExternalActions = unsupportedExternalActions
    self.summaryLines = summaryLines
  }

  public var errors: [FormAccessibleIssue] { issues.filter { $0.severity == .error } }
  public var warnings: [FormAccessibleIssue] { issues.filter { $0.severity == .warning } }
  public var notes: [FormAccessibleIssue] { issues.filter { $0.severity == .note } }
  public var hasErrors: Bool { !errors.isEmpty }
  public var focusIssue: FormAccessibleIssue? {
    issues.first { $0.id == focusIssueID }
  }

  public var keyboardHint: String {
    "Press Return to validate; the first error receives focus. Use Tab/Shift-Tab to "
      + "move between findings."
  }
}

// MARK: - Declared show/hide rules

public enum FormShowHideBehavior: String, Sendable, CaseIterable, Equatable {
  case show
  case hide

  public var title: String { self == .show ? "Show" : "Hide" }
}

public struct FormShowHideRule: Sendable, Equatable, Identifiable {
  public let conditionField: String
  /// nil/"Off"/"" means "the condition field is empty / off / unselected".
  public let expectedValue: String?
  public let targetFields: [String]
  public let behavior: FormShowHideBehavior
  public let note: String?

  public var id: String {
    conditionField + "|" + (expectedValue ?? "empty") + "|"
      + targetFields.joined(separator: ",") + "|" + behavior.rawValue
  }

  public init(
    conditionField: String, expectedValue: String?, targetFields: [String],
    behavior: FormShowHideBehavior, note: String? = nil
  ) {
    self.conditionField = conditionField
    self.expectedValue = expectedValue
    self.targetFields = targetFields
    self.behavior = behavior
    self.note = note
  }

  public var declaration: String {
    let condition = expectedValue.map { "\"" + $0 + "\"" } ?? "empty/off"
    return "When " + conditionField + " is " + condition + ", "
      + behavior.rawValue + " " + targetFields.joined(separator: ", ")
      + (note.map { " (" + $0 + ")" } ?? "")
  }
}

public struct FormShowHideEvaluation: Sendable, Equatable, Identifiable {
  public var id: String { fieldName }
  public let fieldName: String
  public let visible: Bool
  public let appliedRule: String?
  public let reason: String

  public init(
    fieldName: String, visible: Bool, appliedRule: String?, reason: String
  ) {
    self.fieldName = fieldName
    self.visible = visible
    self.appliedRule = appliedRule
    self.reason = reason
  }

  public var declaration: String {
    (visible ? "Shown: " : "Hidden: ") + fieldName + " - " + reason
  }
}

public struct FormShowHideReport: Sendable, Equatable {
  public let evaluations: [FormShowHideEvaluation]
  public let warnings: [String]
  public let summaryLines: [String]

  public init(
    evaluations: [FormShowHideEvaluation], warnings: [String], summaryLines: [String]
  ) {
    self.evaluations = evaluations
    self.warnings = warnings
    self.summaryLines = summaryLines
  }

  public var hiddenFields: [String] {
    evaluations.filter { !$0.visible }.map(\.fieldName)
  }

  public var visibleFields: [String] {
    evaluations.filter(\.visible).map(\.fieldName)
  }

  public func evaluation(for fieldName: String) -> FormShowHideEvaluation? {
    evaluations.first { $0.fieldName == fieldName }
  }
}

// MARK: - Accessible validation

public enum FormAccessibleValidation {
  /// Readable label from /TU (tooltip/accessible name), falling back to the
  /// fully-qualified field name.
  public static func label(for field: FormField, in graph: PDFGraph) -> String {
    guard let fieldID = field.fieldID,
      case .dictionary(let dictionary)? = graph.objects[fieldID],
      case .string(let data)? = dictionary[PDFName("TU")]
    else { return field.name }
    let label = AnnotationText.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? field.name : label
  }

  public static func fields(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> [FormAccessibleField] {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    return fields.map { field in
      let widget = field.widgets.first { $0.pageIndex != nil && $0.rect != nil }
        ?? field.widgets.first
      return FormAccessibleField(
        name: field.name, label: label(for: field, in: graph), kind: field.kind,
        required: field.isRequired, readOnly: field.isReadOnly,
        value: accessibleValue(field), pageIndex: widget?.pageIndex, rect: widget?.rect)
    }
  }

  /// FRM-06: validate the form for fill-time review, order the findings in page
  /// reading order and choose the first real error as the keyboard/screen-reader
  /// focus target. Read-only: no document action or script is executed.
  public static func validate(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) -> FormAccessibleValidationReport {
    _ = limits
    let inventory = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    let accessibleFields = (try? fields(in: graph, pageIDs: pageIDs)) ?? []
    var drafts: [FormAccessibleIssue] = []
    func issue(
      kind: FormAccessibleIssueKind, severity: FormAccessibleSeverity,
      field: FormField?, label: String, message: String, disclosure: String,
      idSuffix: String = ""
    ) -> FormAccessibleIssue {
      let widget = field?.widgets.first { $0.pageIndex != nil && $0.rect != nil }
      return FormAccessibleIssue(
        id: kind.rawValue + "/" + (field?.name ?? "-") + "/" + idSuffix,
        kind: kind, severity: severity, fieldName: field?.name, label: label,
        message: message, disclosure: disclosure,
        pageIndex: widget?.pageIndex, rect: widget?.rect, focusOrder: nil)
    }

    var nameCounts: [String: Int] = [:]
    for field in inventory { nameCounts[field.name, default: 0] += 1 }
    for (name, count) in nameCounts.sorted(by: { $0.key < $1.key }) where count > 1 {
      let first = inventory.first { $0.name == name }
      drafts.append(
        issue(
          kind: .duplicateName, severity: .error, field: first,
          label: first.map { label(for: $0, in: graph) } ?? name,
          message: name + " appears " + String(count)
            + " times; fill-by-name cannot tell the fields apart.",
          disclosure: "Use the field list to review each repeated name explicitly.",
          idSuffix: "count" + String(count)))
    }

    for field in inventory {
      let fieldLabel = label(for: field, in: graph)
      if field.isRequired, valueIsEmpty(field) {
        if field.isReadOnly {
          drafts.append(
            issue(
              kind: .readOnlyRequired, severity: .warning, field: field,
              label: fieldLabel,
              message: fieldLabel + " is required but read-only and empty.",
              disclosure: "The author must supply a value; the reader cannot fill it."))
        } else {
          drafts.append(
            issue(
              kind: .requiredField, severity: .error, field: field, label: fieldLabel,
              message: fieldLabel + " is required but has no value.",
              disclosure: "Choose a value before saving or submitting."))
        }
      }
      if !field.isReadOnly, let maxLength = field.maxLength,
        let value = field.stringValue, value.count > maxLength
      {
        drafts.append(
          issue(
            kind: .valueTooLong, severity: .error, field: field, label: fieldLabel,
            message: fieldLabel + " holds " + String(value.count)
              + " characters but its limit is " + String(maxLength) + ".",
            disclosure: "Shorten the value; other readers may truncate or refuse it."))
      }
      if field.kind == .choice, let invalid = invalidChoiceValues(field), !invalid.isEmpty {
        drafts.append(
          issue(
            kind: .choiceSelection, severity: .error, field: field, label: fieldLabel,
            message: fieldLabel + " holds value(s) not offered by the field: "
              + invalid.joined(separator: ", ") + ".",
            disclosure: "Choose one of the declared export values."))
      }
    }

    var unsupported: [String] = []
    let external = unsupportedExternalActions(in: graph, pageIDs: pageIDs, inventory: inventory)
    for action in external.actions {
      unsupported.append(action.message)
      let field = action.fieldName.flatMap { name in inventory.first { $0.name == name } }
      drafts.append(
        issue(
          kind: .unsupportedExternalAction, severity: .warning, field: field,
          label: field.map { label(for: $0, in: graph) } ?? action.message,
          message: action.message, disclosure: action.disclosure,
          idSuffix: action.key))
    }
    if inventory.isEmpty {
      drafts.append(
        FormAccessibleIssue(
          id: "noForm/-/none", kind: .other, severity: .note, fieldName: nil,
          label: "Form", message: "This document has no AcroForm fields.",
          disclosure: "Nothing is changed by validation.", pageIndex: nil, rect: nil,
          focusOrder: nil))
    }

    // Reading order: page, then top-to-bottom, then left-to-right. Form-wide
    // issues sort last within their severity group.
    let sortedDrafts = drafts.sorted { lhs, rhs in
      let leftPage = lhs.pageIndex ?? Int.max
      let rightPage = rhs.pageIndex ?? Int.max
      if leftPage != rightPage { return leftPage < rightPage }
      let leftY = -(lhs.rect?[3] ?? 0)
      let rightY = -(rhs.rect?[3] ?? 0)
      if leftY != rightY { return leftY < rightY }
      let leftX = lhs.rect?[0] ?? 0
      let rightX = rhs.rect?[0] ?? 0
      if leftX != rightX { return leftX < rightX }
      return lhs.id < rhs.id
    }
    var focusOrder = 0
    var issues: [FormAccessibleIssue] = []
    for draft in sortedDrafts {
      if draft.severity == .error, draft.fieldName != nil {
        issues.append(
          FormAccessibleIssue(
            id: draft.id, kind: draft.kind, severity: draft.severity,
            fieldName: draft.fieldName, label: draft.label, message: draft.message,
            disclosure: draft.disclosure, pageIndex: draft.pageIndex,
            rect: draft.rect, focusOrder: focusOrder))
        focusOrder += 1
      } else {
        issues.append(draft)
      }
    }
    let focusIssue = issues.first { $0.isFocusable }
    var announcements: [String] = []
    announcements.append(
      "Form validation complete. " + String(issues.filter { $0.severity == .error }.count)
        + " error(s), " + String(issues.filter { $0.severity == .warning }.count)
        + " warning(s), " + String(issues.filter { $0.severity == .note }.count) + " note(s).")
    if let focusIssue {
      announcements.append(focusIssue.announcement)
      announcements.append(focusIssue.focusInstruction)
    } else if issues.contains(where: { $0.severity == .error }) {
      announcements.append("A form-wide error needs review before saving.")
    } else {
      announcements.append("No blocking form errors were found.")
    }
    var summaryLines: [String] = []
    summaryLines.append(
      "Accessible form validation: " + String(accessibleFields.count) + " field(s); "
        + String(issues.count) + " finding(s); focus target: "
        + (focusIssue?.label ?? "none") + ".")
    if let focusIssue {
      summaryLines.append("First focusable error: " + focusIssue.focusInstruction)
    }
    if !unsupported.isEmpty {
      summaryLines.append(
        "Unsupported external actions are identified but never executed ("
          + String(unsupported.count) + ").")
    }
    summaryLines.append(keyboardHintForSummary)
    return FormAccessibleValidationReport(
      fields: accessibleFields, issues: issues, focusIssueID: focusIssue?.id,
      announcements: announcements,
      supportedValidationLines: supportedValidationLines,
      unsupportedExternalActions: unsupported, summaryLines: summaryLines)
  }

  /// What this profile validates at fill time (no JavaScript and no arbitrary
  /// format scripts are executed).
  public static let supportedValidationLines: [String] = [
    "Required fields (empty text, unselected choices and Off buttons are errors).",
    "Maximum length (/MaxLen) violations.",
    "Choice values that are not among the field export values (/Opt).",
    "Duplicate field names and required-but-read-only authoring warnings.",
    "Imported actions/scripts/XFA/calculation order are identified, never executed.",
  ]

  static let keyboardHintForSummary =
    "Keyboard/screen-reader flow: Return validates, focus moves to the first error "
    + "in page reading order, and announcements name the label, page and message."

  public static func accessibleValue(_ field: FormField) -> String? {
    switch field.kind {
    case .text:
      return field.stringValue
    case .choice:
      return field.selectedOption?.display ?? field.stringValue
    case .button:
      guard field.isChecked else { return "Off" }
      return field.buttonState.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "On"
    default:
      return nil
    }
  }

  static func valueIsEmpty(_ field: FormField) -> Bool {
    switch field.kind {
    case .text:
      return (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .choice:
      if !field.selectedIndexes.isEmpty { return false }
      return (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .button:
      return !field.isChecked
    default:
      return false
    }
  }

  static func invalidChoiceValues(_ field: FormField) -> [String]? {
    let exports = Set(field.options.map(\.export))
    var found: [String] = []
    if case .array(let values)? = field.value {
      for value in values {
        guard case .string(let data) = value else { continue }
        let text = AnnotationText.decode(data)
        if !text.isEmpty, !exports.contains(text) { found.append(text) }
      }
    } else if let raw = field.stringValue, !raw.isEmpty, !exports.contains(raw) {
      found.append(raw)
    }
    return found
  }

  struct ExternalAction {
    let key: String
    let fieldName: String?
    let message: String
    let disclosure: String
  }

  /// Identify (never execute) field/widget actions, push-button actions, XFA,
  /// calculation order and document JavaScript.
  static func unsupportedExternalActions(
    in graph: PDFGraph, pageIDs: [PDFObjectID], inventory: [FormField]
  ) -> (actions: [ExternalAction], pageIDs: [PDFObjectID]) {
    var actions: [ExternalAction] = []
    for field in inventory {
      var dictionaries: [(String, [PDFName: PDFValue])] = []
      if let fieldID = field.fieldID,
        case .dictionary(let dictionary)? = graph.objects[fieldID]
      {
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
        if dictionary[PDFName("AA")] != nil {
          actions.append(
            ExternalAction(
              key: "aa/" + owner, fieldName: field.name,
              message: field.name + " declares " + owner + " additional actions.",
              disclosure: "External actions are never executed; values stay static."))
        }
        if dictionary[PDFName("A")] != nil, field.kind == .button {
          actions.append(
            ExternalAction(
              key: "action/" + owner, fieldName: field.name,
              message: field.name + " is a push button with an activation action.",
              disclosure: "Button actions are never executed."))
        }
      }
    }
    if let catalog = catalogDictionary(in: graph) {
      if let acroFormValue = catalog[PDFName("AcroForm")],
        let acroForm = dictionaryValue(acroFormValue, in: graph)
      {
        if acroForm[PDFName("XFA")] != nil {
          actions.append(
            ExternalAction(
              key: "xfa", fieldName: nil, message: "The form declares XFA form data.",
              disclosure: "XFA packets are not interpreted or executed."))
        }
        if acroForm[PDFName("CO")] != nil {
          actions.append(
            ExternalAction(
              key: "co", fieldName: nil,
              message: "The form declares a calculation order.",
              disclosure: "Calculations are never executed; static values are shown."))
        }
      }
      if let namesValue = catalog[PDFName("Names")],
        let names = dictionaryValue(namesValue, in: graph),
        names[PDFName("JavaScript")] != nil
      {
        actions.append(
          ExternalAction(
            key: "js", fieldName: nil,
            message: "The document declares JavaScript names.",
            disclosure: "Document scripts are never executed."))
      }
    }
    return (actions, pageIDs)
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

// MARK: - Declared show/hide rules

public enum FormDeclaredShowHide {
  /// Evaluate caller-declared show/hide rules against current values. Rules are
  /// applied in order; the last matching rule for a target wins. Fields not
  /// mentioned by any rule stay visible. External JavaScript is never run.
  public static func evaluate(
    rules: [FormShowHideRule], in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) throws -> FormShowHideReport {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    var fieldByName: [String: FormField] = [:]
    for field in fields { fieldByName[field.name] = field }
    var visibility: [String: Bool] = [:]
    var applied: [String: String] = [:]
    var reasons: [String: String] = [:]
    var warnings: [String] = []
    for (index, rule) in rules.enumerated() {
      guard let conditionField = fieldByName[rule.conditionField] else {
        warnings.append(
          "Rule " + String(index + 1) + " references missing condition field "
            + rule.conditionField + "; it was not applied.")
        continue
      }
      let matches = conditionMatches(field: conditionField, expected: rule.expectedValue)
      let missingTargets = rule.targetFields.filter { fieldByName[$0] == nil }
      if !missingTargets.isEmpty {
        warnings.append(
          "Rule " + String(index + 1) + " references missing target field(s): "
            + missingTargets.joined(separator: ", ") + ".")
      }
      guard matches else { continue }
      for target in rule.targetFields where fieldByName[target] != nil {
        visibility[target] = (rule.behavior == .show)
        applied[target] = rule.declaration
        reasons[target] = "condition " + rule.conditionField + " matched"
      }
    }
    var evaluations: [FormShowHideEvaluation] = []
    for field in fields {
      let visible = visibility[field.name] ?? true
      let rule = applied[field.name]
      evaluations.append(
        FormShowHideEvaluation(
          fieldName: field.name, visible: visible, appliedRule: rule,
          reason: rule.map { "declared rule: " + $0 }
            ?? "no declared rule applies; shown by default"))
    }
    var summaryLines: [String] = []
    summaryLines.append(
      "Declared show/hide rules: " + String(rules.count) + " rule(s); "
        + String(evaluations.filter { !$0.visible }.count) + " hidden field(s) of "
        + String(evaluations.count) + ".")
    for rule in rules { summaryLines.append("Rule: " + rule.declaration) }
    for evaluation in evaluations where !evaluation.visible {
      summaryLines.append(evaluation.declaration)
    }
    if !warnings.isEmpty { summaryLines.append(contentsOf: warnings.map { "Warning: " + $0 }) }
    summaryLines.append(
      "Rules are declared for review only; imported JavaScript show/hide actions are "
        + "identified as unsupported and are never executed.")
    return FormShowHideReport(
      evaluations: evaluations, warnings: warnings, summaryLines: summaryLines)
  }

  public static func conditionMatches(field: FormField, expected: String?) -> Bool {
    let trimmedExpected = expected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch field.kind {
    case .text:
      let value = (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedExpected.isEmpty ? value.isEmpty : value == trimmedExpected
    case .choice:
      var values = field.selectedIndexes.compactMap { index in
        field.options.indices.contains(index) ? field.options[index].export : nil
      }
      if values.isEmpty {
        if case .array(let rawValues)? = field.value {
          values = rawValues.compactMap { value in
            guard case .string(let data) = value else { return nil }
            return AnnotationText.decode(data)
          }
        } else if let raw = field.stringValue, !raw.isEmpty {
          values = [raw]
        }
      }
      if trimmedExpected.isEmpty { return values.isEmpty }
      return values.contains(trimmedExpected)
    case .button:
      let state = field.buttonState.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "Off"
      if trimmedExpected.isEmpty || trimmedExpected == "Off" { return state == "Off" }
      return state == trimmedExpected
    default:
      return false
    }
  }
}
