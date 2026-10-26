import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-07/FRM-08 evidence artifact writer (opt-in):
///   SPDF_FRM0708_ARTIFACT_DIR=<dir> swift test --filter FormResponsesLifecycleArtifactTests
/// Writes completed forms, the collected CSV/XLSX table, the save-time validation
/// report, the lifecycle qualification report and the filled/flattened PDFs that
/// the independent-reader script inspects.
@Suite("Form responses and lifecycle artifacts")
struct FormResponsesLifecycleArtifactTests {
  @Test func writesArtifactsWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directoryPath = environment["SPDF_FRM0708_ARTIFACT_DIR"], !directoryPath.isEmpty
    else { return }
    let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let (firstGraph, _) = try form(
      [.text("Name"), .text("Email"), .checkbox("Agree")],
      values: ["Name": "Asha Demir", "Email": "asha@example.com", "Agree": "Yes"])
    let (secondGraph, secondPage) = try form(
      [.text("Name"), .text("Email"), .checkbox("Agree")],
      values: ["Name": "Asha Demir", "Email": "asha@example.com", "Agree": "Yes"])
    let (thirdGraph, _) = try form(
      [.text("Name"), .text("Phone"), .choice("Plan", ["Basic", "Pro"])],
      values: ["Name": "Boris Yilmaz", "Phone": "+90 555 000 00 00", "Plan": "Pro"])
    let firstData = try PDFWriter.write(firstGraph)
    let secondData = try PDFWriter.write(secondGraph)
    let thirdData = try PDFWriter.write(thirdGraph)
    try firstData.write(to: directory.appendingPathComponent("frm07-form-a.pdf"))
    try secondData.write(to: directory.appendingPathComponent("frm07-form-b.pdf"))
    try thirdData.write(to: directory.appendingPathComponent("frm07-form-c.pdf"))
    let firstHash = stableDigest(firstData)
    let secondHash = stableDigest(secondData)
    let thirdHash = stableDigest(thirdData)

    let firstSource = try FormResponseCollection.readPDFSource(firstData, displayName: "form-a.pdf")
    let secondSource = try FormResponseCollection.readPDFSource(secondData, displayName: "form-b.pdf")
    let thirdSource = try FormResponseCollection.readPDFSource(thirdData, displayName: "form-c.pdf")
    let xfdf = FormDataExchange.export(
      try FormValues.values(in: secondGraph, pageIDs: [secondPage]), format: .xfdf)
    try xfdf.write(to: directory.appendingPathComponent("frm07-last-saved.xfdf"))
    let dataSource = try FormResponseCollection.readFormDataSource(
      xfdf, format: .xfdf, displayName: "last-saved.xfdf")
    let table = FormResponseCollection.merge(
      [firstSource, secondSource, thirdSource, dataSource])
    #expect(table.duplicateSubmissionCount == 1)
    try table.exportCSV().write(to: directory.appendingPathComponent("frm07-responses.csv"))
    try table.exportXLSX().write(to: directory.appendingPathComponent("frm07-responses.xlsx"))

    // The source files must be byte-identical after collection.
    #expect(firstHash == stableDigest(try Data(contentsOf: directory.appendingPathComponent("frm07-form-a.pdf"))))
    #expect(secondHash == stableDigest(try Data(contentsOf: directory.appendingPathComponent("frm07-form-b.pdf"))))
    #expect(thirdHash == stableDigest(try Data(contentsOf: directory.appendingPathComponent("frm07-form-c.pdf"))))

    var columnsJSON: [[String: Any]] = []
    for column in table.columns {
      columnsJSON.append([
        "name": column.name,
        "kinds": column.kinds,
        "missingFrom": column.missingSourceNames,
        "emptyIn": column.emptySourceNames,
        "typeConflict": column.isTypeConflict,
      ])
    }
    var rowsJSON: [[String: Any]] = []
    for row in table.rows {
      var cellsJSON: [[String: Any]] = []
      for cell in row.cells {
        cellsJSON.append([
          "status": cell.status.rawValue,
          "value": cell.value?.displayText ?? "",
        ])
      }
      rowsJSON.append([
        "source": row.displayName,
        "duplicateOf": row.duplicateOf ?? "",
        "cells": cellsJSON,
      ])
    }
    var issuesJSON: [[String: Any]] = []
    for issue in table.issues {
      issuesJSON.append([
        "kind": issue.kind.rawValue,
        "field": issue.fieldName ?? "",
        "source": issue.sourceName ?? "",
        "message": issue.message,
      ])
    }
    let hashes: [String: String] = [
      "form-a.pdf": firstHash,
      "form-b.pdf": secondHash,
      "form-c.pdf": thirdHash,
    ]
    let collectionReport: [String: Any] = [
      "summary": table.summary,
      "sourceHashes": hashes,
      "duplicateSubmissionCount": table.duplicateSubmissionCount,
      "missingValueCount": table.missingValueCount,
      "typeConflictColumns": table.typeConflictColumns.map(\.name),
      "columns": columnsJSON,
      "rows": rowsJSON,
      "issues": issuesJSON,
    ]
    try writeJSON(collectionReport, to: directory.appendingPathComponent("frm07-collection.json"))

    // Lifecycle fixture: filled form, qualification report, flattened copy,
    // save-time validation report and the expected canonical values.
    let (lifecycleGraph, lifecyclePages) = try lifecycleForm()
    let filled = try PDFEditingEngine.commit(
      PDFTransaction([
        SetFormTextCommand(fieldName: "Name", text: "Asha Demir"),
        SetFormChoiceCommand(fieldName: "Plan", exportValue: "Pro"),
        SetFormButtonStateCommand(fieldName: "Agree", state: PDFName("Yes")),
      ]), to: lifecycleGraph)
    try PDFWriter.write(filled).write(to: directory.appendingPathComponent("frm08-filled.pdf"))
    let qualification = try FormLifecycleQualification.run(in: filled, pageIDs: lifecyclePages)
    #expect(qualification.passed, "lifecycle qualification failed: \(qualification.summary)")
    let expectedValues = try FormLifecycleQualification.canonicalValues(
      in: filled, pageIDs: lifecyclePages)
    var stagesJSON: [[String: Any]] = []
    for stage in qualification.stages {
      stagesJSON.append([
        "name": stage.name,
        "passed": stage.passed,
        "notes": stage.notes,
      ])
    }
    let lifecycleReport: [String: Any] = [
      "passed": qualification.passed,
      "summary": qualification.summary,
      "fieldNames": qualification.fieldNames,
      "valuesAfterFill": qualification.valuesAfterFill,
      "signatureNotes": qualification.signatureNotes,
      "stages": stagesJSON,
    ]
    try writeJSON(lifecycleReport, to: directory.appendingPathComponent("frm08-lifecycle.json"))
    try writeJSON(expectedValues, to: directory.appendingPathComponent("frm08-expected-values.json"))
    let validation = FormSaveValidation.validate(in: filled, pageIDs: lifecyclePages)
    var findingsJSON: [[String: Any]] = []
    for finding in validation.findings {
      findingsJSON.append([
        "code": finding.code.rawValue,
        "severity": finding.severity.rawValue,
        "field": finding.fieldName ?? "",
        "message": finding.message,
      ])
    }
    let validationReport: [String: Any] = [
      "summary": validation.summary,
      "saveDisclosure": validation.saveDisclosure,
      "hasBlockingErrors": validation.hasBlockingErrors,
      "findings": findingsJSON,
    ]
    try writeJSON(validationReport, to: directory.appendingPathComponent("frm08-validation.json"))
    let flattened = try PDFEditingEngine.commit(
      PDFTransaction([FlattenFormCommand()]), to: filled)
    try PDFWriter.write(flattened).write(to: directory.appendingPathComponent("frm08-flattened.pdf"))
    let flattenedParsed = try PDFParser.parse(try PDFWriter.write(flattened))
    let flattenedFields = try FormInventory.fields(
      in: flattenedParsed.graph, pageIDs: flattenedParsed.pageIDs)
    #expect(flattenedFields.isEmpty)
  }

  enum Spec {
    case text(String)
    case choice(String, [String])
    case checkbox(String)
    case signature(String)
  }

  private func form(_ specs: [Spec], values: [String: String]) throws
    -> (graph: PDFGraph, pageID: PDFObjectID)
  {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    var graph = parsed.graph
    let pageID = parsed.pageIDs[0]
    var commands: [any PDFEditCommand] = []
    var row = 0
    for spec in specs {
      let rect: [Double] = [72, Double(700 - row * 40), 272, Double(724 - row * 40)]
      row += 1
      switch spec {
      case .text(let name):
        commands.append(AddTextFieldCommand(pageID: pageID, rect: rect, name: name))
      case .choice(let name, let options):
        commands.append(
          AddChoiceFieldCommand(
            pageID: pageID, rect: rect, name: name,
            options: options.map { AuthoredChoiceOption(exportValue: $0) }))
      case .checkbox(let name):
        commands.append(AddCheckboxCommand(pageID: pageID, rect: rect, name: name))
      case .signature(let name):
        commands.append(AddSignatureFieldCommand(pageID: pageID, rect: rect, name: name))
      }
    }
    graph = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    var fill: [any PDFEditCommand] = []
    for spec in specs {
      switch spec {
      case .text(let name):
        if let value = values[name] {
          fill.append(SetFormTextCommand(fieldName: name, text: value))
        }
      case .choice(let name, let options):
        if let value = values[name], options.contains(value) {
          fill.append(SetFormChoiceCommand(fieldName: name, exportValue: value))
        }
      case .checkbox(let name):
        if let value = values[name], value != "Off" {
          fill.append(SetFormButtonStateCommand(fieldName: name, state: PDFName("Yes")))
        }
      case .signature:
        break
      }
    }
    if !fill.isEmpty { graph = try PDFEditingEngine.commit(PDFTransaction(fill), to: graph) }
    return (graph, pageID)
  }

  private func lifecycleForm() throws -> (graph: PDFGraph, pageIDs: [PDFObjectID]) {
    let graph = PDFFixtures.graph(pages: 2)
    let pageIDs = try PageTreeView(graph: graph).pages
    let first = pageIDs[0]
    let edited = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: first, rect: [72, 600, 272, 624], name: "Name"),
        AddChoiceFieldCommand(
          pageID: first, rect: [72, 560, 272, 584], name: "Plan",
          options: [AuthoredChoiceOption(exportValue: "Basic"),
            AuthoredChoiceOption(exportValue: "Pro")]),
        AddCheckboxCommand(pageID: first, rect: [72, 520, 90, 538], name: "Agree"),
        AddSignatureFieldCommand(pageID: first, rect: [72, 480, 272, 504], name: "Signature1"),
      ]), to: graph)
    return (edited, pageIDs)
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }

  private func stableDigest(_ data: Data) -> String {
    var digest: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      digest ^= UInt64(byte)
      digest = digest &* 0x0000_0100_0000_01B3
    }
    return String(format: "%016llx", digest) + "-" + String(data.count)
  }
}
