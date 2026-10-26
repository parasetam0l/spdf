import Foundation
import PDFCore

// FRM-04: calculation/format portability decision and implementation.
//
// Decision (profile "spdf-form-rules-static-value-v1"): sPDF never authors or
// executes document JavaScript. Form behaviour it creates is limited to
// declarative, private-key rules evaluated by sPDF itself, and every result is
// written as an ordinary static field value plus an appearance, so any reader
// shows the same value without recalculating anything. Existing document
// scripts/actions are preserved byte-for-byte, are never executed, and are
// disclosed as outside sPDF's claimed behaviour. The UI identifies app-specific
// rules and offers Freeze Static Results for a portable, rule-free output.

/// FRM-04: how one field's behaviour travels outside sPDF.
public enum FormRulePortabilityClass: String, Sendable, Equatable, CaseIterable {
  /// A value with no rule (or a frozen result): any reader shows /V and the
  /// generated appearance with no recalculation.
  case staticValue
  /// Declarative number/date formatting stored in the private /SPDFFormat key.
  case spdfOnlyFormat
  /// Declarative sum rule stored in the private /SPDFCalculate key.
  case spdfOnlyCalculation
  /// Imported field/form actions (/AA, /A, JavaScript, submit/reset/import and
  /// similar). Preserved untouched and never executed by sPDF.
  case importedScriptPreserved

  public var label: String {
    switch self {
    case .staticValue: return "Static value"
    case .spdfOnlyFormat: return "sPDF-only format rule"
    case .spdfOnlyCalculation: return "sPDF-only calculation"
    case .importedScriptPreserved: return "Imported action (not executed)"
    }
  }

  public var disclosure: String {
    switch self {
    case .staticValue:
      return "Any PDF reader displays the stored value and appearance; no recalculation is required."
    case .spdfOnlyFormat:
      return "The number/date format lives in a private sPDF key. sPDF applies it; Adobe Acrobat and other readers show the stored static value and do not apply the rule."
    case .spdfOnlyCalculation:
      return "The sum rule lives in a private sPDF key. sPDF can recalculate it; Adobe Acrobat and other readers show the stored static value and do not recalculate it."
    case .importedScriptPreserved:
      return "This field/form carries an imported action or script. sPDF preserves it untouched and never executes it; behaviour in other readers is outside sPDF's claimed profile."
    }
  }
}

/// FRM-04: one field's rule and action inventory.
public struct FormFieldRulePortability: Sendable, Equatable {
  public let fieldName: String
  public let kind: FormField.Kind
  public let classes: [FormRulePortabilityClass]
  public let formatSummary: String?
  public let calculationSummary: String?
  /// Imported action kinds, for example ["JavaScript (F)", "SubmitForm (K)"].
  public let importedActionSummaries: [String]
  /// AcroForm /CO calculation-order entries that reference JavaScript.
  public let hasScriptedCalculationOrder: Bool

  public init(
    fieldName: String, kind: FormField.Kind, classes: [FormRulePortabilityClass],
    formatSummary: String?, calculationSummary: String?, importedActionSummaries: [String],
    hasScriptedCalculationOrder: Bool
  ) {
    self.fieldName = fieldName
    self.kind = kind
    self.classes = classes
    self.formatSummary = formatSummary
    self.calculationSummary = calculationSummary
    self.importedActionSummaries = importedActionSummaries
    self.hasScriptedCalculationOrder = hasScriptedCalculationOrder
  }

  public var isAppSpecific: Bool {
    classes.contains(.spdfOnlyFormat) || classes.contains(.spdfOnlyCalculation)
  }

  public var hasImportedActions: Bool { !importedActionSummaries.isEmpty }

  public var disclosure: String {
    classes.filter { $0 != .staticValue }.map(\.disclosure).joined(separator: " ")
  }
}

/// FRM-04: the document-level portability report the UI shows before claiming
/// how a form behaves outside sPDF.
public struct FormRulePortabilityReport: Sendable, Equatable {
  public let profileIdentifier: String
  public let fields: [FormFieldRulePortability]
  public let acroFormScriptCount: Int
  public let acroFormDefaultAppearancePresent: Bool
  public let summary: String
  public let disclosures: [String]

  public init(
    profileIdentifier: String, fields: [FormFieldRulePortability], acroFormScriptCount: Int,
    acroFormDefaultAppearancePresent: Bool, summary: String, disclosures: [String]
  ) {
    self.profileIdentifier = profileIdentifier
    self.fields = fields
    self.acroFormScriptCount = acroFormScriptCount
    self.acroFormDefaultAppearancePresent = acroFormDefaultAppearancePresent
    self.summary = summary
    self.disclosures = disclosures
  }

  public var appSpecificFields: [FormFieldRulePortability] { fields.filter(\.isAppSpecific) }
  public var importedActionFields: [FormFieldRulePortability] {
    fields.filter(\.hasImportedActions)
  }
  public var staticFields: [FormFieldRulePortability] {
    fields.filter { !$0.isAppSpecific && !$0.hasImportedActions }
  }
  public var hasAppSpecificRules: Bool { !appSpecificFields.isEmpty }
  public var hasImportedActions: Bool {
    !importedActionFields.isEmpty || acroFormScriptCount > 0
  }
  public var isFullyStatic: Bool { !hasAppSpecificRules && !hasImportedActions }
}

/// FRM-04: the recorded decision. The UI shows these strings verbatim so a
/// user can see exactly what is and is not claimed outside sPDF.
public enum FormRulePortabilityDecision {
  public static let profileIdentifier = "spdf-form-rules-static-value-v1"

  public static let summary =
    "sPDF never authors or executes document JavaScript. Field rules are declarative and "
    + "sPDF-specific; the value and appearance they produce are ordinary static PDF field data, "
    + "so every reader shows the intended values without recalculating. Existing imported "
    + "actions are preserved untouched and never executed."

  public static let claimedProfiles: [String] = [
    "A. Static values: after fill, recalculation or Freeze Static Results, /V and the generated "
      + "widget appearance are ordinary PDF data. Acrobat and other readers display the same value "
      + "with no recalculation.",
    "B. sPDF-only rules: /SPDFCalculate (sum) and /SPDFFormat (number/date) are private keys. "
      + "sPDF evaluates them on request; external readers ignore them and show the static value. "
      + "The UI labels these fields as app-specific and offers Freeze Static Results.",
    "C. Imported actions: existing /AA, /A, /CO and script entries are preserved byte-for-byte and "
      + "never executed. Their external behaviour is not claimed; the UI lists them explicitly.",
  ]

  public static let notClaimed: [String] = [
    "External-reader recalculation of sPDF rules (Acrobat does not see /SPDFCalculate or /SPDFFormat).",
    "Authoring, executing or simulating document JavaScript, XFA scripts or arbitrary actions.",
    "Calculation semantics beyond the declared one-level sum profile and number/date formats.",
    "Trusting a static /V as proof that an external script would compute the same result.",
  ]

  public static let freezeGuarantee =
    "Freeze Static Results writes the current computed value as ordinary /V and /DV, regenerates "
    + "the appearance, and removes the sPDF-only rule keys (optionally marking the field read-only). "
    + "The output contains no sPDF rule and no newly authored script."
}

/// FRM-04: static analysis of rules and imported actions. Nothing here executes
/// a document action.
public enum FormRulePortability {
  public static func analyze(
    in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> FormRulePortabilityReport {
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    let acroForm = FormInventory.acroFormDictionary(in: graph)
    let calculationOrder = calculationOrderIsScripted(acroForm)
    var entries: [FormFieldRulePortability] = []
    for field in fields {
      var dictionary: [PDFName: PDFValue] = [:]
      if let fieldID = field.fieldID, case .dictionary(let stored)? = graph.objects[fieldID] {
        dictionary = stored
      }
      let format = FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")])
      let calculation = FormFieldFormatting.parseCalculation(
        dictionary[PDFName("SPDFCalculate")])
      let actions = importedActions(in: dictionary)
      var classes: [FormRulePortabilityClass] = []
      if format != nil { classes.append(.spdfOnlyFormat) }
      if calculation != nil { classes.append(.spdfOnlyCalculation) }
      if !actions.isEmpty { classes.append(.importedScriptPreserved) }
      if classes.isEmpty { classes.append(.staticValue) }
      entries.append(
        FormFieldRulePortability(
          fieldName: field.name, kind: field.kind, classes: classes,
          formatSummary: format.map(description(format:)),
          calculationSummary: calculation.map(description(calculation:)),
          importedActionSummaries: actions, hasScriptedCalculationOrder: calculationOrder))
    }
    let acroFormScripts = importedActions(in: acroForm ?? [:]).count
    var disclosures: [String] = [FormRulePortabilityDecision.summary]
    if entries.contains(where: { $0.classes.contains(.spdfOnlyFormat) }) {
      disclosures.append(FormRulePortabilityClass.spdfOnlyFormat.disclosure)
    }
    if entries.contains(where: { $0.classes.contains(.spdfOnlyCalculation) }) {
      disclosures.append(FormRulePortabilityClass.spdfOnlyCalculation.disclosure)
    }
    if entries.contains(where: \.hasImportedActions) || acroFormScripts > 0 {
      disclosures.append(FormRulePortabilityClass.importedScriptPreserved.disclosure)
    }
    if calculationOrder {
      disclosures.append(
        "The form declares a /CO calculation order that includes a script; sPDF never runs it. "
          + "External recalculation order and results are not claimed.")
    }
    let appSpecific = entries.filter(\.isAppSpecific).count
    let withActions = entries.filter(\.hasImportedActions).count
    let summary: String
    if entries.isEmpty {
      summary = "This document has no form fields, so no calculation or format behaviour applies."
    } else if appSpecific == 0 && withActions == 0 && acroFormScripts == 0 {
      summary =
        "All " + String(entries.count)
        + " field(s) use static values only; no sPDF-only rule and no imported action is present."
    } else {
      summary =
        String(appSpecific) + " of " + String(entries.count) + " field(s) carry an sPDF-only rule"
        + (withActions > 0 ? ", " + String(withActions) + " field(s) carry an imported action" : "")
        + (acroFormScripts > 0 ? ", and the AcroForm has " + String(acroFormScripts) + " action(s)" : "")
        + ". External readers show static values; freeze the results for a rule-free copy."
    }
    return FormRulePortabilityReport(
      profileIdentifier: FormRulePortabilityDecision.profileIdentifier, fields: entries,
      acroFormScriptCount: acroFormScripts,
      acroFormDefaultAppearancePresent: acroForm?[PDFName("DA")] != nil,
      summary: summary, disclosures: disclosures)
  }

  /// A machine-readable copy for evidence and support reports.
  public static func json(_ report: FormRulePortabilityReport) -> Data? {
    let payload: [String: Any] = [
      "profile": report.profileIdentifier,
      "summary": report.summary,
      "fields": report.fields.map { field -> [String: Any] in
        [
          "name": field.fieldName, "kind": field.kind.rawValue,
          "classes": field.classes.map(\.rawValue),
          "format": field.formatSummary ?? "",
          "calculation": field.calculationSummary ?? "",
          "actions": field.importedActionSummaries,
        ]
      },
      "disclosures": report.disclosures,
      "notClaimed": FormRulePortabilityDecision.notClaimed,
    ]
    return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
  }

  /// Description of the declared rule profile for one field, used by the UI.
  public static func describe(field: FormField, in graph: PDFGraph) -> (format: String?, calculation: String?) {
    guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
    else { return (nil, nil) }
    let format = FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")])
    let calculation = FormFieldFormatting.parseCalculation(dictionary[PDFName("SPDFCalculate")])
    return (format.map(description(format:)), calculation.map(description(calculation:)))
  }

  public static func description(format: AuthoredFieldFormat) -> String {
    switch format {
    case .number(let decimals, let prefix, let suffix):
      var text = "Number, " + String(decimals) + " decimal(s)"
      if let prefix { text += ", prefix " + prefix }
      if let suffix { text += ", suffix " + suffix }
      return text
    case .date(let style):
      return "Date, " + style.rawValue + " style"
    }
  }

  public static func description(calculation: AuthoredCalculation) -> String {
    switch calculation {
    case .sum(let fields):
      return "Sum of " + (fields.isEmpty ? "no fields" : fields.joined(separator: ", "))
    }
  }

  // MARK: Imported action inventory (never executed)

  static func importedActions(in dictionary: [PDFName: PDFValue]) -> [String] {
    var summaries: [String] = []
    if case .dictionary(let additional)? = dictionary[PDFName("AA")] {
      for key in ["F", "K", "V", "C"] {
        summaries += actionSummaries(
          additional[PDFName(key)], trigger: key, prefix: "field /AA")
      }
    }
    if dictionary[PDFName("A")] != nil {
      summaries += actionSummaries(dictionary[PDFName("A")], trigger: "A", prefix: "field /A")
    }
    if case .dictionary(let openAction)? = dictionary[PDFName("OpenAction")] {
      _ = openAction
      summaries.append("OpenAction")
    }
    return summaries
  }

  static func actionSummaries(
    _ value: PDFValue?, trigger: String, prefix: String
  ) -> [String] {
    var summaries: [String] = []
    func walk(_ value: PDFValue, depth: Int) {
      guard depth < 4 else { return }
      switch value {
      case .dictionary(let action):
        let kind: String
        if case .name(let name)? = action[PDFName("S")] {
          kind = String(decoding: name.bytes, as: UTF8.self)
        } else {
          kind = "Unknown"
        }
        summaries.append(prefix + " " + kind + " (" + trigger + ")")
        for key in ["Next", "A"] {
          if let next = action[PDFName(key)] { walk(next, depth: depth + 1) }
        }
      case .array(let actions):
        for action in actions { walk(action, depth: depth + 1) }
      default:
        break
      }
    }
    if let value { walk(value, depth: 0) }
    return summaries
  }

  static func calculationOrderIsScripted(_ acroForm: [PDFName: PDFValue]?) -> Bool {
    guard let acroForm, case .array(let order)? = acroForm[PDFName("CO")] else { return false }
    return !order.isEmpty
  }
}

// MARK: - Declarative calculation engine

/// FRM-04: one computed declarative result.
public struct FormCalculatedValue: Sendable, Equatable {
  public let fieldName: String
  public let numericValue: Double
  public let formattedValue: String
  public init(fieldName: String, numericValue: Double, formattedValue: String) {
    self.fieldName = fieldName
    self.numericValue = numericValue
    self.formattedValue = formattedValue
  }
}

/// FRM-04: evaluate the declared sum rules in dependency order with cycle
/// detection. Never executes a script or an imported action.
public enum FormCalculationEngine {
  public static func evaluate(
    in graph: PDFGraph, pageIDs: [PDFObjectID], onlyFields: Set<String>? = nil
  ) throws -> [FormCalculatedValue] {
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    var byName: [String: FormField] = [:]
    for field in fields where byName[field.name] == nil { byName[field.name] = field }
    var rules: [String: AuthoredCalculation] = [:]
    var formats: [String: AuthoredFieldFormat] = [:]
    for (name, field) in byName {
      guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
      else { continue }
      if let rule = FormFieldFormatting.parseCalculation(dictionary[PDFName("SPDFCalculate")]) {
        rules[name] = rule
      }
      if let format = FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")]) {
        formats[name] = format
      }
    }
    guard !rules.isEmpty else { return [] }

    enum Visit { case visiting, done(Double) }
    var state: [String: Visit] = [:]
    var results: [String: Double] = [:]

    func rawNumeric(_ name: String) -> Double {
      guard let field = byName[name] else { return 0 }
      guard let raw = field.stringValue else { return 0 }
      return FormFieldFormatting.numericValue(raw) ?? 0
    }

    func value(of name: String) throws -> Double {
      if case .done(let value)? = state[name] { return value }
      if case .visiting? = state[name] {
        throw PDFError(
          .unsupported,
          "The calculation references itself through " + name + "; sPDF refuses cyclical rules")
      }
      guard let rule = rules[name] else { return rawNumeric(name) }
      state[name] = .visiting
      var total = 0.0
      switch rule {
      case .sum(let references):
        for reference in references {
          guard byName[reference] != nil else {
            throw PDFError(.malformed, "Calculation references the missing field " + reference)
          }
          total += try value(of: reference)
        }
      }
      state[name] = .done(total)
      results[name] = total
      return total
    }

    for name in rules.keys.sorted() { _ = try value(of: name) }
    var output: [FormCalculatedValue] = []
    for name in rules.keys.sorted() {
      if let onlyFields, !onlyFields.contains(name) { continue }
      guard let total = results[name] else { continue }
      let rawText = String(format: "%g", total)
      var formatted = rawText
      if let format = formats[name] {
        guard let applied = FormFieldFormatting.format(rawText, rule: format) else {
          throw PDFError(
            .unsupported,
            "The computed value for " + name + " does not satisfy its declared format rule")
        }
        formatted = applied
      }
      output.append(
        FormCalculatedValue(fieldName: name, numericValue: total, formattedValue: formatted))
    }
    return output
  }
}

/// FRM-04: freeze the declared rule results as ordinary static field data so the
/// output behaves identically outside sPDF. One undoable command.
public struct FreezeFormResultsCommand: PDFEditCommand, Equatable, Sendable {
  /// nil freezes every field that carries a /SPDFCalculate rule.
  public let fieldNames: [String]?
  /// Remove /SPDFCalculate and /SPDFFormat after writing the static value.
  public let stripRules: Bool
  /// Copy the frozen value to /DV so Reset returns the frozen result.
  public let writeDefaultValue: Bool
  /// Mark frozen fields read-only so an external fill cannot silently diverge.
  public let makeReadOnly: Bool

  public init(
    fieldNames: [String]? = nil, stripRules: Bool = true, writeDefaultValue: Bool = true,
    makeReadOnly: Bool = false
  ) {
    self.fieldNames = fieldNames
    self.stripRules = stripRules
    self.writeDefaultValue = writeDefaultValue
    self.makeReadOnly = makeReadOnly
  }

  public var name: String { "Freeze Form Results" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [] }

  public func validate(in graph: PDFGraph) throws {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      catalog[PDFName("AcroForm")] != nil
    else { throw PDFError(.malformed, "The document has no form") }
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    if let fieldNames {
      let names = Set(fields.map(\.name))
      for name in fieldNames where !names.contains(name) {
        throw PDFError(.malformed, "Freeze target field is missing: " + name)
      }
      guard !fieldNames.isEmpty else {
        throw PDFError(.malformed, "Choose at least one field to freeze")
      }
      let hasRule = fieldNames.contains { name in
        guard let field = fields.first(where: { $0.name == name }),
          let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
        else { return false }
        return FormFieldFormatting.parseCalculation(
          dictionary[PDFName("SPDFCalculate")]) != nil
          || FormFieldFormatting.parseFormat(dictionary[PDFName("SPDFFormat")]) != nil
      }
      guard hasRule else {
        throw PDFError(.unsupported, "The selected fields have no sPDF rule to freeze")
      }
    } else {
      let hasCalculated = fields.contains { field in
        guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
        else { return false }
        return FormFieldFormatting.parseCalculation(
          dictionary[PDFName("SPDFCalculate")]) != nil
      }
      guard hasCalculated else {
        throw PDFError(.unsupported, "No calculated field is present to freeze")
      }
    }
    _ = try FormCalculationEngine.evaluate(in: graph, pageIDs: pageIDs)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    let pageIDs = try PageTreeView(graph: graph).pages
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    let targets = Set(fieldNames ?? fields.compactMap { field -> String? in
      guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
      else { return nil }
      return FormFieldFormatting.parseCalculation(dictionary[PDFName("SPDFCalculate")]) != nil
        ? field.name : nil
    })
    let computed = try FormCalculationEngine.evaluate(
      in: graph, pageIDs: pageIDs, onlyFields: targets)
    var nextNumber = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let helveticaID = try FormAuthoringSupport.ensureAcroForm(in: &graph).helveticaID
    for value in computed {
      guard let field = fields.first(where: { $0.name == value.fieldName }),
        let fieldID = field.fieldID,
        case .dictionary(var dictionary)? = graph.objects[fieldID]
      else { continue }
      dictionary[PDFName("V")] = .string(AnnotationText.encode(value.formattedValue))
      if writeDefaultValue {
        dictionary[PDFName("DV")] = .string(AnnotationText.encode(value.formattedValue))
      }
      if makeReadOnly {
        let flags: Int64
        if case .integer(let raw)? = dictionary[PDFName("Ff")] { flags = raw } else { flags = 0 }
        dictionary[PDFName("Ff")] = .integer(flags | 1)
      }
      if stripRules {
        dictionary.removeValue(forKey: PDFName("SPDFCalculate"))
        dictionary.removeValue(forKey: PDFName("SPDFFormat"))
      }
      graph.objects[fieldID] = .dictionary(dictionary)
      // Static appearance at the stored size/color; no rule is consulted.
      let da = SetFormTextCommand.parseDA(SetFormTextCommand.daValue(for: field, in: graph))
      for widget in field.widgets {
        guard let widgetID = widget.objectID, let rect = widget.rect else { continue }
        let appearance = SetFormTextCommand.textAppearance(
          text: value.formattedValue, rect: rect, multiline: field.isMultiline, da: da,
          fontID: helveticaID, comb: field.isComb, maxLength: field.maxLength)
        nextNumber = try SetFormTextCommand.installAppearance(
          appearance, widgetID: widgetID, in: &graph, nextNumber: nextNumber)
      }
    }
    graph.trailer[PDFName("Size")] = .integer(Int64(nextNumber))
    return graph
  }
}
