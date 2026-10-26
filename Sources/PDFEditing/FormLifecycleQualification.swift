import Foundation
import PDFCore

// FRM-08: lifecycle qualification for forms. A scripted sequence runs the graph
// through fill -> save/reopen -> page operations -> save/reopen -> flatten ->
// export and checks that canonical values, widget appearances and field order
// agree at every stage. The caller's graph is never mutated (the sequence runs
// on copies), so this is safe to offer as a read-only qualification report.

public struct FormLifecycleStage: Sendable, Equatable {
  public let name: String
  public let passed: Bool
  public let notes: [String]
  public init(name: String, passed: Bool, notes: [String]) {
    self.name = name
    self.passed = passed
    self.notes = notes
  }
}

public struct FormLifecycleQualificationReport: Sendable, Equatable {
  public let stages: [FormLifecycleStage]
  public let fieldNames: [String]
  public let valuesAfterFill: [String: String]
  public let signatureNotes: [String]
  public let summary: String

  public init(
    stages: [FormLifecycleStage], fieldNames: [String], valuesAfterFill: [String: String],
    signatureNotes: [String], summary: String
  ) {
    self.stages = stages
    self.fieldNames = fieldNames
    self.valuesAfterFill = valuesAfterFill
    self.signatureNotes = signatureNotes
    self.summary = summary
  }

  public var passed: Bool { stages.allSatisfy(\.passed) }
  public var failedStages: [FormLifecycleStage] { stages.filter { !$0.passed } }
}

public enum FormLifecycleQualification {
  public static func run(
    in graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits = PDFLimits()
  ) throws -> FormLifecycleQualificationReport {
    var stages: [FormLifecycleStage] = []
    var work = graph
    var pages = pageIDs
    let fields = try FormInventory.fields(in: work, pageIDs: pages)
    guard !fields.isEmpty else {
      throw PDFError(.unsupported, "Lifecycle qualification needs a document with form fields")
    }
    let fieldNames = fields.map(\.name)
    stages.append(
      FormLifecycleStage(
        name: "inventory", passed: true,
        notes: [String(fields.count) + " field(s) across " + String(pages.count) + " page(s)"]))
    let initialValues = try canonicalValues(in: work, pageIDs: pages)
    let initialAppearanceCount = widgetAppearanceCount(in: work, pageIDs: pages)

    // 1. Fill representative field kinds.
    var fillCommands: [any PDFEditCommand] = []
    var fillNotes: [String] = []
    if let text = fields.first(where: { $0.kind == .text && !$0.isReadOnly }) {
      fillCommands.append(SetFormTextCommand(fieldName: text.name, text: "Lifecycle value"))
      fillNotes.append("text " + text.name + " = Lifecycle value")
    }
    if let choice = fields.first(where: { $0.kind == .choice && !$0.isReadOnly }),
      let firstExport = choice.options.first?.export
    {
      fillCommands.append(
        SetFormChoiceCommand(fieldName: choice.name, exportValue: firstExport))
      fillNotes.append("choice " + choice.name + " = " + firstExport)
    }
    if let button = fields.first(where: { $0.kind == .button && !$0.isPushButton && !$0.isReadOnly })
    {
      fillCommands.append(
        SetFormButtonStateCommand(fieldName: button.name, state: PDFName("Yes")))
      fillNotes.append("button " + button.name + " = Yes")
    }
    if !fillCommands.isEmpty {
      work = try PDFEditingEngine.commit(PDFTransaction(fillCommands), to: work, limits: limits)
    }
    let valuesAfterFill = try canonicalValues(in: work, pageIDs: pages)
    let fillChanged = valuesAfterFill != initialValues
    stages.append(
      FormLifecycleStage(
        name: "fill", passed: fillCommands.isEmpty ? true : fillChanged,
        notes: fillCommands.isEmpty
          ? ["No writable field kind was available; existing values are carried forward."]
          : fillNotes))

    // 2. Save and reopen: values, pages and appearances survive.
    let reopened = try reopen(work, limits: limits)
    let reopenedValues = try canonicalValues(in: reopened.graph, pageIDs: reopened.pageIDs)
    let reopenedAppearances = widgetAppearanceCount(
      in: reopened.graph, pageIDs: reopened.pageIDs)
    stages.append(
      FormLifecycleStage(
        name: "save-reopen", passed: reopenedValues == valuesAfterFill
          && reopened.pageIDs.count == pages.count
          && reopenedAppearances >= initialAppearanceCount,
        notes: [
          String(reopened.pageIDs.count) + " page(s) after reopen",
          String(reopenedValues.count) + " value(s) preserved",
          String(reopenedAppearances) + " widget appearance(s) present",
        ]))
    work = reopened.graph
    pages = reopened.pageIDs

    // 3. Page operations, then save and reopen again.
    var pageNotes: [String] = []
    if let firstPage = pages.first {
      work = try PDFEditingEngine.commit(
        PDFTransaction([RotatePagesCommand(pageIDs: [firstPage], byDegrees: 90)]), to: work,
        limits: limits)
      pageNotes.append("rotated page 1 by 90 degrees")
    }
    if pages.count > 1, let last = pages.last {
      work = try PDFEditingEngine.commit(
        PDFTransaction([ReorderPagesCommand(pageID: last, toIndex: 0)]), to: work, limits: limits)
      pageNotes.append("reordered the last page to the front")
    }
    work = try PDFEditingEngine.commit(
      PDFTransaction([
        InsertBlankPageCommand(atIndex: 0, width: 612, height: 792)
      ]), to: work, limits: limits)
    pageNotes.append("inserted a blank page")
    let afterInsert = try PageTreeView(graph: work).pages
    let insertedPage = afterInsert[0]
    work = try PDFEditingEngine.commit(
      PDFTransaction([DeletePagesCommand(pageIDs: [insertedPage])]), to: work, limits: limits)
    pageNotes.append("removed the inserted page again")
    let pageReopened = try reopen(work, limits: limits)
    let pageValues = try canonicalValues(in: pageReopened.graph, pageIDs: pageReopened.pageIDs)
    let orderAfter = try FormInventory.fields(
      in: pageReopened.graph, pageIDs: pageReopened.pageIDs
    ).map(\.name)
    let widgetsInRange = try widgetPagesInRange(
      in: pageReopened.graph, pageIDs: pageReopened.pageIDs)
    stages.append(
      FormLifecycleStage(
        name: "page-operations",
        passed: pageValues == valuesAfterFill && orderAfter == fieldNames && widgetsInRange,
        notes: pageNotes + [
          String(pageReopened.pageIDs.count) + " page(s) after reopen",
          orderAfter == fieldNames ? "field order preserved" : "field order changed",
          widgetsInRange ? "every widget is attached to an existing page" : "a widget page is stale",
        ]))
    work = pageReopened.graph
    pages = pageReopened.pageIDs

    // 4. Flatten: fields become page content; the form tree is gone.
    var flattened = try PDFEditingEngine.commit(
      PDFTransaction([FlattenFormCommand()]), to: work, limits: limits)
    let flattenedReopened = try reopen(flattened, limits: limits)
    let flattenedFields = try FormInventory.fields(
      in: flattenedReopened.graph, pageIDs: flattenedReopened.pageIDs)
    let contentBefore = pageContentBytes(in: work, pageIDs: pages)
    let contentAfter = pageContentBytes(in: flattenedReopened.graph, pageIDs: flattenedReopened.pageIDs)
    stages.append(
      FormLifecycleStage(
        name: "flatten",
        passed: flattenedFields.isEmpty && contentAfter > contentBefore,
        notes: [
          flattenedFields.isEmpty
            ? "no fillable fields remain after flatten"
            : String(flattenedFields.count) + " field(s) remain after flatten",
          "page content grew from " + String(contentBefore) + " to "
            + String(contentAfter) + " bytes",
        ]))
    flattened = flattenedReopened.graph

    // 5. Export values as JSON and XFDF and read them back.
    var exportNotes: [String] = []
    var exportPassed = true
    let jsonData = try FormValues.export(in: work, pageIDs: pages)
    let jsonValues = try FormValues.parse(jsonData)
    let jsonCanonical = canonicalValues(from: jsonValues)
    exportNotes.append(String(jsonValues.count) + " value(s) in the JSON export")
    if jsonCanonical != valuesAfterFill {
      exportPassed = false
      exportNotes.append("JSON export values differ from the in-document values")
    }
    let xfdfData = FormDataExchange.export(
      try FormValues.values(in: work, pageIDs: pages), format: .xfdf)
    let xfdfEntries = try FormDataExchange.parse(xfdfData, format: .xfdf)
    let xfdfNames = Set(xfdfEntries.map(\.name))
    let jsonNames = Set(jsonValues.map(\.name))
    exportNotes.append(String(xfdfEntries.count) + " value(s) in the XFDF export")
    if xfdfNames != jsonNames {
      exportPassed = false
      exportNotes.append("XFDF and JSON exports disagree about which fields exist")
    }
    stages.append(
      FormLifecycleStage(name: "export", passed: exportPassed, notes: exportNotes))

    // 6. Save-time validation on the post-page-operations document.
    let validation = FormSaveValidation.validate(in: work, pageIDs: pages)
    stages.append(
      FormLifecycleStage(
        name: "save-validation", passed: !validation.hasBlockingErrors,
        notes: [validation.summary]
          + Array(validation.errors.map { $0.message }.prefix(4))))

    // 7. Signature constraints.
    let signatures = (try? PDFSignatureInventory.signatures(in: work)) ?? []
    let signatureFieldCount = (try? FormInventory.fields(in: work, pageIDs: pages))?
      .filter { $0.kind == .signature }.count ?? 0
    var signatureNotes: [String] = []
    if signatures.isEmpty {
      signatureNotes.append(
        signatureFieldCount > 0
          ? String(signatureFieldCount) + " unsigned signature field(s); nothing is signed by save"
          : "no signature field or digital signature is present")
    } else {
      signatureNotes.append(
        String(signatures.count) + " digital signature(s) present; changing values invalidates them")
    }
    let signatureStagePassed = signatures.count
      == ((try? PDFSignatureInventory.signatures(in: flattened))?.count ?? 0)
    stages.append(
      FormLifecycleStage(
        name: "signature-constraints", passed: signatureStagePassed, notes: signatureNotes))

    let failed = stages.filter { !$0.passed }.map(\.name)
    let summary = failed.isEmpty
      ? "Lifecycle qualification passed all " + String(stages.count) + " stages for "
        + String(fieldNames.count) + " field(s)."
      : "Lifecycle qualification failed: " + failed.joined(separator: ", ") + "."
    return FormLifecycleQualificationReport(
      stages: stages, fieldNames: fieldNames, valuesAfterFill: valuesAfterFill,
      signatureNotes: signatureNotes, summary: summary)
  }

  // MARK: Helpers

  struct Reopened {
    let graph: PDFGraph
    let pageIDs: [PDFObjectID]
  }

  static func reopen(_ graph: PDFGraph, limits: PDFLimits) throws -> Reopened {
    let data = try PDFWriter.serialize(graph, limits: limits)
    let parsed = try PDFParser.parse(data, limits: limits)
    return Reopened(graph: parsed.graph, pageIDs: parsed.pageIDs)
  }

  /// Canonical value strings keyed by fully qualified field name.
  public static func canonicalValues(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> [String: String]
  {
    canonicalValues(from: try FormValues.values(in: graph, pageIDs: pageIDs))
  }

  static func canonicalValues(from values: [FormFieldValue]) -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
      result[value.name] = FormResponseValue.from(fieldValue: value).canonical
    }
    return result
  }

  static func widgetAppearanceCount(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> Int {
    let fields = (try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? []
    var count = 0
    for field in fields {
      for widget in field.widgets {
        guard let objectID = widget.objectID,
          case .dictionary(let dictionary)? = graph.objects[objectID],
          case .dictionary(let appearance)? = dictionary[PDFName("AP")]
        else { continue }
        if appearance[PDFName("N")] != nil { count += 1 }
      }
    }
    return count
  }

  /// Total decoded page-content bytes; flattening moves appearances into page
  /// content so this grows even though the form tree disappears.
  static func pageContentBytes(in graph: PDFGraph, pageIDs: [PDFObjectID]) -> Int {
    var total = 0
    func add(_ value: PDFValue) {
      guard case .reference(let objectID) = value,
        case .stream(let stream)? = graph.objects[objectID],
        let decoded = try? PDFFilters.decoded(stream)
      else { return }
      total += decoded.count
    }
    for pageID in pageIDs {
      guard case .dictionary(let page)? = graph.objects[pageID],
        let contents = page[PDFName("Contents")]
      else { continue }
      if case .array(let values) = contents {
        for value in values { add(value) }
      } else {
        add(contents)
      }
    }
    return total
  }

  static func widgetPagesInRange(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws -> Bool {
    let pageSet = Set(pageIDs)
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
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
