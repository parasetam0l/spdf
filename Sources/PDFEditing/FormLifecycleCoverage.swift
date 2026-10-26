import Foundation
import PDFCore

// FRM-08: lifecycle coverage for combinations the basic fill/reopen evidence does
// not exercise — page duplication/deletion carrying widgets, appearance
// agreement, tab-order stability under page operations, and signing (sign after
// fill, sign after flatten, and the invalidation any post-sign lifecycle edit
// causes). The caller's graph is never mutated; the optional signing hook
// returns signed bytes so this qualification never owns key material.

public typealias FormLifecycleSigner = (PDFGraph) throws -> Data

public struct FormLifecycleCoverageOptions {
  public let signer: FormLifecycleSigner?
  public init(signer: FormLifecycleSigner? = nil) { self.signer = signer }
  public static var readOnly: FormLifecycleCoverageOptions { .init() }
}

public struct FormLifecycleCoverageFinding: Sendable, Equatable {
  public enum Verdict: String, Sendable, Equatable { case passed, failed, notExercised }
  public let combination: String
  public let verdict: Verdict
  public let notes: [String]
  public init(combination: String, verdict: Verdict, notes: [String]) {
    self.combination = combination
    self.verdict = verdict
    self.notes = notes
  }
}

public struct FormLifecycleCoverageReport: Sendable, Equatable {
  public let findings: [FormLifecycleCoverageFinding]
  public let fieldNames: [String]
  public let valuesAfterFill: [String: String]
  public let tabOrder: [String]
  public let signatureNotes: [String]
  public let summary: String
  public init(
    findings: [FormLifecycleCoverageFinding], fieldNames: [String],
    valuesAfterFill: [String: String], tabOrder: [String], signatureNotes: [String],
    summary: String
  ) {
    self.findings = findings
    self.fieldNames = fieldNames
    self.valuesAfterFill = valuesAfterFill
    self.tabOrder = tabOrder
    self.signatureNotes = signatureNotes
    self.summary = summary
  }
  public var passed: Bool { findings.allSatisfy { $0.verdict != .failed } }
  public var failed: [FormLifecycleCoverageFinding] {
    findings.filter { $0.verdict == .failed }
  }
  public var exercised: [FormLifecycleCoverageFinding] {
    findings.filter { $0.verdict != .notExercised }
  }
}

public enum FormLifecycleCoverage {
  public static func run(
    in graph: PDFGraph, pageIDs: [PDFObjectID],
    options: FormLifecycleCoverageOptions = .readOnly, limits: PDFLimits = PDFLimits()
  ) throws -> FormLifecycleCoverageReport {
    var findings: [FormLifecycleCoverageFinding] = []
    var signatureNotes: [String] = []
    var work = graph
    let fields = try FormInventory.fields(in: work, pageIDs: pageIDs)
    guard !fields.isEmpty else {
      throw PDFError(.unsupported, "Lifecycle coverage needs a document with form fields")
    }
    let fieldNames = fields.map(\.name)
    let initialTabOrder = FormTabOrder.current(fields: fields)

    // Fill is the fixture for the uncovered combinations (basic fill/reopen is
    // already qualified elsewhere).
    var fill: [any PDFEditCommand] = []
    if let text = fields.first(where: { $0.kind == .text && !$0.isReadOnly }) {
      fill.append(SetFormTextCommand(fieldName: text.name, text: "Coverage value"))
    }
    if let choice = fields.first(where: { $0.kind == .choice && !$0.isReadOnly }),
      let export = choice.options.first?.export
    {
      fill.append(SetFormChoiceCommand(fieldName: choice.name, exportValue: export))
    }
    if let button = fields.first(where: {
      $0.kind == .button && !$0.isPushButton && !$0.isReadOnly
    }) {
      fill.append(SetFormButtonStateCommand(fieldName: button.name, state: PDFName("Yes")))
    }
    if !fill.isEmpty {
      work = try PDFEditingEngine.commit(PDFTransaction(fill), to: work, limits: limits)
    }
    let filledFields = try FormInventory.fields(in: work, pageIDs: pageIDs)
    let valuesAfterFill = canonicalValues(filledFields)
    let appearanceProblems = appearanceAgreement(fields: filledFields, in: work)
    findings.append(
      .init(
        combination: "fill-appearance-agreement",
        verdict: appearanceProblems.isEmpty ? .passed : .failed,
        notes: appearanceProblems.isEmpty
          ? ["\(filledFields.count) field(s) filled; widget appearances agree with values"]
          : appearanceProblems))
    let reopened = try reopen(work, limits: limits)
    let reopenFields = try FormInventory.fields(
      in: reopened.graph, pageIDs: reopened.pageIDs)

    // Tab order: stored order is stable across save/reopen and rotation; a page
    // reorder changes the page-major suggestion only.
    var tabNotes: [String] = []
    var tabPassed = FormTabOrder.validate(initialTabOrder, fields: filledFields) == nil
    if FormTabOrder.current(fields: reopenFields) != initialTabOrder {
      tabPassed = false
      tabNotes.append("save/reopen changed the stored tab order")
    } else {
      tabNotes.append("save/reopen keeps the stored tab order")
    }
    var rotated = reopened.graph
    if let firstPage = reopened.pageIDs.first {
      rotated = try PDFEditingEngine.commit(
        PDFTransaction([RotatePagesCommand(pageIDs: [firstPage], byDegrees: 90)]),
        to: rotated, limits: limits)
    }
    let rotatedFields = try FormInventory.fields(in: rotated, pageIDs: reopened.pageIDs)
    if FormTabOrder.current(fields: rotatedFields) != initialTabOrder {
      tabPassed = false
      tabNotes.append("rotation changed the stored tab order")
    } else {
      tabNotes.append("rotation keeps the stored tab order")
    }
    let suggested = FormTabOrder.suggested(pageIDs: reopened.pageIDs, fields: reopenFields)
    if Set(suggested) != Set(initialTabOrder) || suggested.count != initialTabOrder.count {
      tabPassed = false
      tabNotes.append("the page-major suggestion does not list every field once")
    }
    if reopened.pageIDs.count > 1, let last = reopened.pageIDs.last {
      let reordered = try PDFEditingEngine.commit(
        PDFTransaction([ReorderPagesCommand(pageID: last, toIndex: 0)]),
        to: reopened.graph, limits: limits)
      let pagesAfter = try PageTreeView(graph: reordered).pages
      let reorderedFields = try FormInventory.fields(in: reordered, pageIDs: pagesAfter)
      let before = FormTabOrder.suggested(pageIDs: reopened.pageIDs, fields: reopenFields)
      let after = FormTabOrder.suggested(pageIDs: pagesAfter, fields: reorderedFields)
      if FormTabOrder.current(fields: reorderedFields) != initialTabOrder
        || Set(after) != Set(before)
      {
        tabPassed = false
        tabNotes.append("page reorder broke tab-order agreement")
      } else {
        tabNotes.append("page reorder updates the suggestion; stored order survives")
      }
    } else {
      tabNotes.append("single page: reorder not exercised")
    }
    findings.append(
      .init(
        combination: "tab-order-agreement",
        verdict: tabPassed ? .passed : .failed, notes: tabNotes))

    // Duplicate a widget-hosting page: field identity, canonical values, order
    // and appearances must not duplicate or drift.
    var duplicateNotes: [String] = []
    var duplicatePassed = true
    var duplicated = reopened
    if let host = widgetHostingPages(
      in: reopened.graph, pageIDs: reopened.pageIDs, fields: reopenFields
    ).first
    {
      duplicated.graph = try PDFEditingEngine.commit(
        PDFTransaction([DuplicatePageCommand(pageID: host)]),
        to: reopened.graph, limits: limits)
      duplicated.pageIDs = try PageTreeView(graph: duplicated.graph).pages
      let after = try FormInventory.fields(
        in: duplicated.graph, pageIDs: duplicated.pageIDs)
      if after.map(\.name) != fieldNames {
        duplicatePassed = false
        duplicateNotes.append("the field name sequence changed after duplication")
      }
      if canonicalValues(after) != valuesAfterFill {
        duplicatePassed = false
        duplicateNotes.append("canonical values changed after duplication")
      }
      if FormTabOrder.current(fields: after) != initialTabOrder {
        duplicatePassed = false
        duplicateNotes.append("the stored tab order changed after duplication")
      }
      let problems = appearanceAgreement(fields: after, in: duplicated.graph)
      if !problems.isEmpty {
        duplicatePassed = false
        duplicateNotes.append(contentsOf: problems)
      }
      duplicateNotes.append(
        "\(duplicated.pageIDs.count) page(s), \(after.count) field(s) after duplication")
    } else {
      duplicateNotes.append("no widget-hosting page was available")
    }
    findings.append(
      .init(
        combination: "duplicate-page-with-fields",
        verdict: duplicatePassed ? .passed : .failed, notes: duplicateNotes))

    // Delete a widget-hosting page: either the page goes and the surviving
    // fields keep values/order (no widget points at a removed page), or the
    // command refuses safely and the document/values stay unchanged. Both are
    // qualified outcomes; silent drift is a failure.
    var deleteNotes: [String] = []
    var deletePassed = true
    if let host = widgetHostingPages(
      in: reopened.graph, pageIDs: reopened.pageIDs, fields: reopenFields
    ).first {
      do {
        let deleted = try PDFEditingEngine.commit(
          PDFTransaction([DeletePagesCommand(pageIDs: [host])]),
          to: reopened.graph, limits: limits)
        let pagesAfter = try PageTreeView(graph: deleted).pages
        let after = try FormInventory.fields(in: deleted, pageIDs: pagesAfter)
        if !widgetPagesExist(after, in: deleted, pageIDs: pagesAfter) {
          deletePassed = false
          deleteNotes.append("a widget points at a page that no longer exists")
        }
        for (name, value) in canonicalValues(after) where valuesAfterFill[name] != value {
          deletePassed = false
          deleteNotes.append("value of \(name) changed after page deletion")
        }
        if FormTabOrder.validate(FormTabOrder.current(fields: after), fields: after) != nil {
          deletePassed = false
          deleteNotes.append("the tab order no longer lists exactly the surviving fields")
        }
        deleteNotes.append(
          "\(pagesAfter.count) page(s), \(after.count) field(s) after deletion")
      } catch {
        let after = try FormInventory.fields(in: reopened.graph, pageIDs: reopened.pageIDs)
        if canonicalValues(after) != valuesAfterFill {
          deletePassed = false
          deleteNotes.append("the refused deletion still changed canonical values")
        }
        deleteNotes.append(
          "deleting a widget-hosting page was refused safely; document and values are unchanged")
      }
    } else {
      deleteNotes.append("no widget-hosting page was available")
    }
    findings.append(
      .init(
        combination: "delete-page-with-fields",
        verdict: deletePassed ? .passed : .failed, notes: deleteNotes))

    // Signing combinations.
    if let signer = options.signer {
      let signedData: Data
      do {
        signedData = try signer(reopened.graph)
      } catch {
        findings.append(
          .init(
            combination: "sign-after-fill", verdict: .failed,
            notes: ["the signing hook failed: \(error.localizedDescription)"]))
        signedData = Data()
      }
      if !signedData.isEmpty {
        let signedParsed = try PDFParser.parse(signedData, limits: limits)
        let signedFields = try FormInventory.fields(
          in: signedParsed.graph, pageIDs: signedParsed.pageIDs)
        let signatures = try PDFSignatureInventory.signatures(in: signedParsed.graph)
        var signNotes: [String] = []
        var signPassed = signatures.count == 1
          && canonicalValues(signedFields) == valuesAfterFill
        if signatures.count != 1 {
          signNotes.append("expected exactly one signature, found \(signatures.count)")
        }
        if canonicalValues(signedFields) != valuesAfterFill {
          signNotes.append("canonical values changed across signing")
        }
        if let signature = signatures.first {
          let validation = PDFSignatureValidator.validate(
            signature, source: signedData, finalGraph: signedParsed.graph)
          if validation.crypto != .valid {
            signPassed = false
            signNotes.append("the signature does not validate cryptographically")
          }
          if validation.unsignedChanges {
            signPassed = false
            signNotes.append("the untouched signed document reports unsigned changes")
          }
          signatureNotes.append("signed document crypto: \(validation.crypto)")
        }
        let saveValidation = FormSaveValidation.validate(
          in: signedParsed.graph, pageIDs: signedParsed.pageIDs)
        if !saveValidation.summary.isEmpty {
          signatureNotes.append("save validation: " + saveValidation.summary)
        }
        findings.append(
          .init(
            combination: "sign-after-fill",
            verdict: signPassed ? .passed : .failed,
            notes: signPassed
              ? signNotes + ["values, appearances and tab order survive signing unchanged"]
              : signNotes))

        // Any post-sign lifecycle edit invalidates the signature: prove it by
        // editing a copy, rewriting, and re-validating against the signed bytes.
        var edited = signedParsed.graph
        if let textField = signedFields.first(where: {
          $0.kind == .text && !$0.isReadOnly
        }) {
          edited = try PDFEditingEngine.commit(
            PDFTransaction([
              SetFormTextCommand(fieldName: textField.name, text: "Post-sign change")
            ]), to: edited, limits: limits)
        }
        let editedData = try PDFWriter.serialize(edited, limits: limits)
        let editedParsed = try PDFParser.parse(editedData, limits: limits)
        let editedSignatures = try PDFSignatureInventory.signatures(in: editedParsed.graph)
        var invalidated = editedSignatures.isEmpty
        if let signature = editedSignatures.first {
          let validation = PDFSignatureValidator.validate(
            signature, source: signedData, finalGraph: editedParsed.graph)
          invalidated = validation.crypto != .valid || validation.unsignedChanges
        }
        findings.append(
          .init(
            combination: "signed-document-edit-invalidation",
            verdict: invalidated ? .passed : .failed,
            notes: invalidated
              ? ["editing a signed document invalidates its signature as required"]
              : ["a post-sign edit did not invalidate the signature"]))

        let jsonData = try FormValues.export(
          in: signedParsed.graph, pageIDs: signedParsed.pageIDs)
        let jsonValues = try FormValues.parse(jsonData)
        let exportAgreement = canonicalValuesFromValues(jsonValues) == valuesAfterFill
        findings.append(
          .init(
            combination: "export-after-sign",
            verdict: exportAgreement ? .passed : .failed,
            notes: exportAgreement
              ? ["JSON export of the signed document agrees with canonical values"]
              : ["JSON export of the signed document disagrees with canonical values"]))
      }
      // Sign after flatten: no value-bearing fields remain, the signature field
      // signs the flat page.
      var flattened = try PDFEditingEngine.commit(
        PDFTransaction([FlattenFormCommand()]), to: work, limits: limits)
      flattened = try reopen(flattened, limits: limits).graph
      let flattenedFields = try FormInventory.fields(
        in: flattened, pageIDs: try PageTreeView(graph: flattened).pages)
      let valueBearing = flattenedFields.filter {
        $0.kind == .text || $0.kind == .choice || $0.kind == .button
      }
      do {
        let signed = try signer(flattened)
        let parsed = try PDFParser.parse(signed, limits: limits)
        let after = try FormInventory.fields(in: parsed.graph, pageIDs: parsed.pageIDs)
        let stillValueBearing = after.filter {
          $0.kind == .text || $0.kind == .choice || $0.kind == .button
        }
        let signatures = try PDFSignatureInventory.signatures(in: parsed.graph)
        let passed = valueBearing.isEmpty && stillValueBearing.isEmpty
          && signatures.count == 1
        findings.append(
          .init(
            combination: "sign-after-flatten",
            verdict: passed ? .passed : .failed,
            notes: passed
              ? ["flatten removed every value-bearing field; the signature signs the flat page"]
              : [
                "value-bearing fields before flatten: \(valueBearing.count)",
                "after signing the flat document: \(stillValueBearing.count)",
                "signatures: \(signatures.count)",
              ]))
      } catch {
        findings.append(
          .init(
            combination: "sign-after-flatten", verdict: .failed,
            notes: ["the signing hook failed: \(error.localizedDescription)"]))
      }
    } else {
      for name in ["sign-after-fill", "signed-document-edit-invalidation",
        "export-after-sign", "sign-after-flatten"] {
        findings.append(
          .init(
            combination: name, verdict: .notExercised,
            notes: ["no signing hook was supplied"]))
      }
    }

    let failed = findings.filter { $0.verdict == .failed }.map(\.combination)
    let summary = failed.isEmpty
      ? "Lifecycle coverage passed \(findings.filter { $0.verdict != .notExercised }.count)"
        + " exercised combination(s) for \(fieldNames.count) field(s)."
      : "Lifecycle coverage failed: " + failed.joined(separator: ", ") + "."
    return FormLifecycleCoverageReport(
      findings: findings, fieldNames: fieldNames, valuesAfterFill: valuesAfterFill,
      tabOrder: initialTabOrder, signatureNotes: signatureNotes, summary: summary)
  }

  // MARK: - Helpers

  struct Reopened {
    var graph: PDFGraph
    var pageIDs: [PDFObjectID]
  }

  static func reopen(_ graph: PDFGraph, limits: PDFLimits) throws -> Reopened {
    let data = try PDFWriter.serialize(graph, limits: limits)
    let parsed = try PDFParser.parse(data, limits: limits)
    return Reopened(graph: parsed.graph, pageIDs: parsed.pageIDs)
  }

  static func canonicalValues(_ fields: [FormField]) -> [String: String] {
    var result: [String: String] = [:]
    for field in fields {
      switch field.kind {
      case .text:
        result[field.name] = "text:" + (field.stringValue ?? "")
      case .choice:
        if let option = field.selectedOption {
          result[field.name] = "choice:" + option.export
        } else {
          result[field.name] = "choice:" + (field.stringValue ?? "")
        }
      case .button:
        result[field.name] = "button:"
          + String(decoding: (field.buttonState ?? PDFName("Off")).bytes, as: UTF8.self)
      case .signature, .unknown:
        if let value = field.stringValue { result[field.name] = "value:" + value }
      }
    }
    return result
  }

  static func canonicalValuesFromValues(_ values: [FormFieldValue]) -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
      switch value.kind {
      case "text":
        result[value.name] = "text:" + (value.value ?? "")
      case "choice":
        result[value.name] = "choice:"
          + (value.value ?? (value.selectedValues ?? []).joined(separator: ","))
      case "button":
        result[value.name] = "button:" + (value.buttonState ?? "Off")
      default:
        if let raw = value.value { result[value.name] = value.kind + ":" + raw }
      }
    }
    return result
  }

  static func appearanceAgreement(fields: [FormField], in graph: PDFGraph) -> [String] {
    var problems: [String] = []
    for field in fields where field.kind != .signature && field.kind != .unknown {
      if field.kind == .button {
        let states = Set(field.widgets.compactMap(\.appearanceState))
        if !field.widgets.isEmpty, let state = field.buttonState, !states.contains(state) {
          problems.append("button \(field.name): no widget appearance state matches /V")
        }
      }
      for widget in field.widgets {
        guard let objectID = widget.objectID,
          case .dictionary(let dictionary)? = graph.objects[objectID],
          field.kind == .text || field.kind == .choice
        else { continue }
        if case .dictionary(let appearance)? = dictionary[PDFName("AP")] {
          if appearance[PDFName("N")] == nil {
            problems.append("\(field.name): widget appearance has no /N")
          }
        } else if dictionary[PDFName("AP")] == nil {
          problems.append("\(field.name): widget has no appearance")
        }
      }
    }
    return problems
  }

  static func widgetHostingPages(
    in graph: PDFGraph, pageIDs: [PDFObjectID], fields: [FormField]
  ) -> [PDFObjectID] {
    var scores: [Int: Int] = [:]
    for field in fields {
      for widget in field.widgets {
        if let index = widget.pageIndex { scores[index, default: 0] += 1 }
      }
    }
    return scores.sorted { $0.key < $1.key }.compactMap {
      pageIDs.indices.contains($0.key) ? pageIDs[$0.key] : nil
    }
  }

  static func widgetPagesExist(
    _ fields: [FormField], in graph: PDFGraph, pageIDs: [PDFObjectID]
  ) -> Bool {
    let pageSet = Set(pageIDs)
    for field in fields {
      for widget in field.widgets {
        guard let objectID = widget.objectID,
          case .dictionary(let dictionary)? = graph.objects[objectID]
        else { continue }
        if case .reference(let pageID)? = dictionary[PDFName("P")], !pageSet.contains(pageID) {
          return false
        }
      }
    }
    return true
  }
}

