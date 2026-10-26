import Foundation
import PDFCore

// FRM-08: save-time form validation. Every finding is visible, graded and tied
// to a field where possible so the UI can list it before a save. Validation is
// read-only: it never executes an imported action, never writes a script and
// never mutates the graph.

public enum FormValidationSeverity: String, Sendable, Equatable, CaseIterable {
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

public enum FormValidationCode: String, Sendable, Equatable {
  case noForm
  case requiredFieldEmpty
  case valueExceedsMaxLength
  case valueViolatesFormat
  case invalidChoiceSelection
  case calculationReferenceMissing
  case calculationCycle
  case importedActionPresent
  case scriptedCalculationOrder
  case appearanceMissing
  case needAppearancesSet
  case orphanedWidget
  case duplicateFieldName
  case combMissingMaxLength
  case richValueMismatch
  case xfaPresent
  case signedDocumentWillBeInvalidated
  case unsignedSignatureField
}

/// FRM-08: one visible save-time finding.
public struct FormValidationFinding: Sendable, Equatable, Identifiable {
  public let code: FormValidationCode
  public let severity: FormValidationSeverity
  public let fieldName: String?
  public let message: String
  /// What the profile does (or does not claim) about this finding.
  public let disclosure: String

  public var id: String {
    code.rawValue + "/" + (fieldName ?? "-") + "/" + message
  }

  public init(
    code: FormValidationCode, severity: FormValidationSeverity, fieldName: String?,
    message: String, disclosure: String
  ) {
    self.code = code
    self.severity = severity
    self.fieldName = fieldName
    self.message = message
    self.disclosure = disclosure
  }
}

/// FRM-08: the whole save-time report.
public struct FormSaveValidationReport: Sendable, Equatable {
  public let findings: [FormValidationFinding]
  public let fieldCount: Int
  public let pageCount: Int
  public let summary: String
  /// Text a save-confirmation alert can show verbatim.
  public let saveDisclosure: String

  public init(
    findings: [FormValidationFinding], fieldCount: Int, pageCount: Int, summary: String,
    saveDisclosure: String
  ) {
    self.findings = findings
    self.fieldCount = fieldCount
    self.pageCount = pageCount
    self.summary = summary
    self.saveDisclosure = saveDisclosure
  }

  public var errors: [FormValidationFinding] { findings.filter { $0.severity == .error } }
  public var warnings: [FormValidationFinding] { findings.filter { $0.severity == .warning } }
  public var notes: [FormValidationFinding] { findings.filter { $0.severity == .note } }
  public var isClean: Bool { findings.isEmpty }
  public var hasBlockingErrors: Bool { !errors.isEmpty }
}

public enum FormSaveValidation {
  /// Validate the form for saving. Read-only; safe to call from a save path.
  public static func validate(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) -> FormSaveValidationReport {
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    var findings: [FormValidationFinding] = []
    let acroForm = FormInventory.acroFormDictionary(in: graph)
    let fieldIDs = Set(fields.compactMap(\.fieldID))
    func dictionary(for field: FormField) -> [PDFName: PDFValue] {
      guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID]
      else { return [:] }
      return dictionary
    }

    if fields.isEmpty {
      findings.append(
        FormValidationFinding(
          code: .noForm, severity: .note, fieldName: nil,
          message: "This document has no AcroForm fields; form validation found nothing to check.",
          disclosure: "No form data is written or changed."))
    }

    // Duplicate full names make fill-by-name ambiguous.
    var nameCounts: [String: Int] = [:]
    for field in fields { nameCounts[field.name, default: 0] += 1 }
    for (name, count) in nameCounts where count > 1 {
      findings.append(
        FormValidationFinding(
          code: .duplicateFieldName, severity: .error, fieldName: name,
          message: name + " appears " + String(count)
            + " times; fill-by-name cannot tell the fields apart.",
          disclosure: "Values may be written to only the first canonical field."))
    }

    let engineFindings = calculationFindings(in: graph, pageIDs: pageIDs)
    findings += engineFindings

    for field in fields {
      let fieldDictionary = dictionary(for: field)
      // Required fields with no value are visible before saving.
      if field.isRequired, isEmptyAnswer(field) {
        findings.append(
          FormValidationFinding(
            code: .requiredFieldEmpty, severity: .error, fieldName: field.name,
            message: field.name + " is required but has no value.",
            disclosure: "The value stays as saved; other readers may refuse the submission."))
      }
      // /MaxLen and declared format rules are enforced at fill time; a value that
      // violates them now (for example after an import) is a save-time error.
      if let maxLength = field.maxLength, let value = field.stringValue,
        value.count > maxLength
      {
        findings.append(
          FormValidationFinding(
            code: .valueExceedsMaxLength, severity: .error, fieldName: field.name,
            message: field.name + " holds " + String(value.count) + " characters but its limit is "
              + String(maxLength) + ".",
            disclosure: "Readers that enforce /MaxLen will truncate or refuse the value."))
      }
      if let rule = FormFieldFormatting.parseFormat(fieldDictionary[PDFName("SPDFFormat")]),
        let value = field.stringValue, !value.isEmpty,
        FormFieldFormatting.format(value, rule: rule) == nil
      {
        findings.append(
          FormValidationFinding(
            code: .valueViolatesFormat, severity: .warning, fieldName: field.name,
            message: field.name + " does not match its declared sPDF format rule.",
            disclosure: "The sPDF-only format rule is not applied by other readers; the stored "
              + "static value is what they show."))
      }
      if field.kind == .choice, !field.options.isEmpty {
        for index in field.selectedIndexes where !field.options.indices.contains(index) {
          findings.append(
            FormValidationFinding(
              code: .invalidChoiceSelection, severity: .error, fieldName: field.name,
              message: field.name + " selects an option index that does not exist.",
              disclosure: "The selection is kept as stored; readers may show nothing."))
        }
      }
      if field.isComb, field.maxLength == nil {
        findings.append(
          FormValidationFinding(
            code: .combMissingMaxLength, severity: .warning, fieldName: field.name,
            message: field.name + " is a comb field without /MaxLen, so cell layout is undefined.",
            disclosure: "sPDF refuses comb fills without a declared cell count."))
      }
      // Widgets need a normal appearance when NeedAppearances is off.
      let hasNeedAppearances: Bool = {
        guard let acroForm else { return false }
        if case .boolean(true)? = acroForm[PDFName("NeedAppearances")] { return true }
        return false
      }()
      var missingAppearanceWidgets = 0
      for widget in field.widgets {
        guard let objectID = widget.objectID,
          case .dictionary(let widgetDictionary)? = graph.objects[objectID]
        else { continue }
        let hasAppearance: Bool = {
          if case .dictionary(let appearance)? = widgetDictionary[PDFName("AP")] {
            return appearance[PDFName("N")] != nil
          }
          return false
        }()
        if !hasAppearance && !hasNeedAppearances { missingAppearanceWidgets += 1 }
      }
      if missingAppearanceWidgets > 0 {
        findings.append(
          FormValidationFinding(
            code: .appearanceMissing, severity: .warning, fieldName: field.name,
            message: field.name + " has " + String(missingAppearanceWidgets)
              + " widget(s) without a normal appearance and /NeedAppearances is false.",
            disclosure: "Some readers will show the field blank until it is regenerated."))
      }
      if field.isRichText, case .string(let richData)? = fieldDictionary[PDFName("RV")],
        let decoded = FormRichTextRTF.decode(String(decoding: richData, as: UTF8.self)),
        decoded.plainText != (field.stringValue ?? ""),
        field.flags & 8192 == 0
      {
        findings.append(
          FormValidationFinding(
            code: .richValueMismatch, severity: .warning, fieldName: field.name,
            message: field.name + " has a rich (/RV) value that does not match its plain value.",
            disclosure: "The plain /V value is authoritative; independent readers may show the "
              + "rich formatting only when it decodes."))
      }
    }

    if let acroForm, case .boolean(true)? = acroForm[PDFName("NeedAppearances")] {
      findings.append(
        FormValidationFinding(
          code: .needAppearancesSet, severity: .note, fieldName: nil,
          message: "The form requests /NeedAppearances; some readers will regenerate appearances.",
          disclosure: "Authored sPDF appearances are authoritative; other readers may redraw."))
    }
    let orphanedCount = FormInventory.orphanedWidgets(in: graph, pageIDs: pageIDs).count
    if orphanedCount > 0 {
      findings.append(
        FormValidationFinding(
          code: .orphanedWidget, severity: .warning, fieldName: nil,
          message: String(orphanedCount) + " widget(s) are not linked to a field.",
          disclosure: "Orphaned widgets are preserved but cannot be filled or validated."))
    }

    let portability = FormRulePortability.analyze(in: graph, pageIDs: pageIDs)
    for field in portability.fields where !field.importedActionSummaries.isEmpty {
      findings.append(
        FormValidationFinding(
          code: .importedActionPresent, severity: .warning, fieldName: field.fieldName,
          message: field.fieldName + " carries an imported action or script: "
            + field.importedActionSummaries.joined(separator: ", ") + ".",
          disclosure: "sPDF preserves it untouched and never executes it; behaviour in other "
            + "readers is outside sPDF's claimed profile."))
    }
    if portability.acroFormScriptCount > 0 {
      findings.append(
        FormValidationFinding(
          code: .importedActionPresent, severity: .warning, fieldName: nil,
          message: "The AcroForm carries " + String(portability.acroFormScriptCount)
            + " imported action(s).",
          disclosure: "Preserved untouched and never executed by sPDF."))
    }
    if portability.fields.contains(where: \.hasScriptedCalculationOrder) {
      findings.append(
        FormValidationFinding(
          code: .scriptedCalculationOrder, severity: .warning, fieldName: nil,
          message: "The form declares a /CO calculation order that includes a script.",
          disclosure: "sPDF never runs the script; external recalculation is not claimed."))
    }

    if FormXAFFlag.hasXFA(in: graph) {
      findings.append(
        FormValidationFinding(
          code: .xfaPresent, severity: .warning, fieldName: nil,
          message: "This document contains XFA form data.",
          disclosure: FormXAFFlag.authoringWarning))
    }

    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    if !signatures.isEmpty {
      findings.append(
        FormValidationFinding(
          code: .signedDocumentWillBeInvalidated, severity: .warning, fieldName: nil,
          message: String(signatures.count)
            + " digital signature(s) are present; changing and saving form values will "
            + "invalidate them unless a permitted incremental update is used.",
          disclosure: "Signature validity is a reader-verified property; sPDF does not re-sign "
            + "or claim the changed revision stays valid."))
    }
    for field in fields where field.kind == .signature && field.value == nil {
      findings.append(
        FormValidationFinding(
          code: .unsignedSignatureField, severity: .note, fieldName: field.name,
          message: field.name + " is an unsigned signature field.",
          disclosure: "Signing is a separate explicit workflow; nothing is signed by saving."))
    }
    _ = fieldIDs

    let fieldCount = fields.count
    let pageCount = pageIDs.count
    let errorCount = findings.filter { $0.severity == .error }.count
    let warningCount = findings.filter { $0.severity == .warning }.count
    let noteCount = findings.filter { $0.severity == .note }.count
    let summary: String
    if findings.isEmpty {
      summary = "Form validation found no save-time issues in "
        + String(fieldCount) + " field(s)."
    } else {
      summary = String(errorCount) + " error(s), " + String(warningCount) + " warning(s), "
        + String(noteCount) + " note(s) across " + String(fieldCount) + " field(s)."
    }
    let saveDisclosure: String
    if errorCount > 0 {
      saveDisclosure = summary
        + " Saving now keeps the current values; fix the errors if the form must validate "
        + "elsewhere. No document script is executed by sPDF."
    } else if warningCount > 0 {
      saveDisclosure = summary
        + " Saving keeps the current values and appearances; listed actions are preserved but "
        + "not executed by sPDF."
    } else if noteCount > 0 {
      saveDisclosure = summary
    } else {
      saveDisclosure = "Form validation is clean; saving writes the current values and appearances."
    }
    return FormSaveValidationReport(
      findings: findings, fieldCount: fieldCount, pageCount: pageCount, summary: summary,
      saveDisclosure: saveDisclosure)
  }

  /// Machine-readable report for evidence and support.
  public static func json(_ report: FormSaveValidationReport) -> Data? {
    let payload: [String: Any] = [
      "summary": report.summary,
      "fieldCount": report.fieldCount,
      "pageCount": report.pageCount,
      "saveDisclosure": report.saveDisclosure,
      "findings": report.findings.map { finding -> [String: Any] in
        [
          "code": finding.code.rawValue,
          "severity": finding.severity.rawValue,
          "field": finding.fieldName ?? "",
          "message": finding.message,
          "disclosure": finding.disclosure,
        ]
      },
    ]
    return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
  }

  // MARK: Helpers

  static func isEmptyAnswer(_ field: FormField) -> Bool {
    switch field.kind {
    case .text:
      return (field.stringValue ?? "").isEmpty
    case .choice:
      return field.selectedIndexes.isEmpty
        && (field.stringValue ?? "").isEmpty
    case .button:
      if field.isPushButton { return false }
      let state: String
      if let buttonState = field.buttonState {
        state = String(decoding: buttonState.bytes, as: UTF8.self)
      } else {
        state = "Off"
      }
      return state == "Off"
    default:
      return field.value == nil
    }
  }

  static func calculationFindings(in graph: PDFGraph, pageIDs: [PDFObjectID])
    -> [FormValidationFinding]
  {
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    var rules: [String: AuthoredCalculation] = [:]
    for field in fields {
      guard let fieldID = field.fieldID, case .dictionary(let dictionary)? = graph.objects[fieldID],
        let rule = FormFieldFormatting.parseCalculation(dictionary[PDFName("SPDFCalculate")])
      else { continue }
      rules[field.name] = rule
    }
    var findings: [FormValidationFinding] = []
    let names = Set(fields.map(\.name))
    for (name, rule) in rules {
      for reference in rule.fields where !names.contains(reference) {
        findings.append(
          FormValidationFinding(
            code: .calculationReferenceMissing, severity: .error, fieldName: name,
            message: name + " calculates from the missing field " + reference + ".",
            disclosure: "sPDF recalculation will refuse; external readers do not run sPDF rules."))
      }
    }
    do {
      _ = try FormCalculationEngine.evaluate(in: graph, pageIDs: pageIDs)
    } catch {
      findings.append(
        FormValidationFinding(
          code: .calculationCycle, severity: .error, fieldName: nil,
          message: "The declared calculation rules cannot be evaluated: "
            + error.localizedDescription,
          disclosure: "Recalculation is refused with this message; no value is guessed."))
    }
    return findings
  }
}
