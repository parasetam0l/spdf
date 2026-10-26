import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-08 evidence: fill -> page operations -> save/reopen -> flatten -> export
/// lifecycle qualification keeps canonical values, appearances and field order
/// consistent, and save validation is visible at each stage.
@Suite("Form lifecycle qualification")
struct FormLifecycleQualificationTests {
  private func authoredForm(pages: Int = 1, requiredEmpty: Bool = false) throws
    -> (graph: PDFGraph, pageIDs: [PDFObjectID])
  {
    let graph = PDFFixtures.graph(pages: pages)
    let pageIDs = try PageTreeView(graph: graph).pages
    let first = pageIDs[0]
    let rects: [[Double]] = pages > 1
      ? [[72, 600, 272, 624], [72, 560, 272, 584], [72, 520, 90, 538], [72, 480, 272, 504]]
      : [[72, 600, 272, 624], [72, 560, 272, 584], [72, 520, 90, 538], [72, 480, 272, 504]]
    var commands: [any PDFEditCommand] = [
      AddTextFieldCommand(pageID: first, rect: rects[0], name: "Name"),
      AddChoiceFieldCommand(
        pageID: first, rect: rects[1], name: "Plan",
        options: [
          AuthoredChoiceOption(exportValue: "Basic"),
          AuthoredChoiceOption(exportValue: "Pro"),
        ]),
      AddCheckboxCommand(pageID: first, rect: rects[2], name: "Agree"),
      AddSignatureFieldCommand(pageID: first, rect: rects[3], name: "Signature1"),
    ]
    if requiredEmpty {
      // The qualification fills the first writable text field, so this second
      // required field intentionally stays empty to exercise the save check.
      commands.append(
        AddTextFieldCommand(
          pageID: first, rect: [300, 600, 500, 624], name: "RequiredNotes",
          required: true))
    }
    let edited = try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
    return (edited, pageIDs)
  }

  @Test func qualificationPassesEveryStageForAnAuthoredForm() throws {
    let (graph, pageIDs) = try authoredForm(pages: 2)
    let report = try FormLifecycleQualification.run(in: graph, pageIDs: pageIDs)
    #expect(
      report.passed,
      "\(report.failedStages.map { $0.name + ": " + $0.notes.joined(separator: ", ") }.joined(separator: " | "))")
    #expect(report.fieldNames == ["Name", "Plan", "Agree", "Signature1"])
    #expect(report.valuesAfterFill["Name"] == "text:Lifecycle value")
    #expect(report.valuesAfterFill["Plan"] == "choice:Basic")
    #expect(report.valuesAfterFill["Agree"] == "button:Yes")
    let stageNames = report.stages.map(\.name)
    #expect(stageNames == [
      "inventory", "fill", "save-reopen", "page-operations", "flatten", "export",
      "save-validation", "signature-constraints",
    ])
    #expect(report.summary.contains("passed all"))
  }

  @Test func qualificationDoesNotMutateTheCallerGraph() throws {
    let (graph, pageIDs) = try authoredForm()
    let before = graph
    let pagesBefore = pageIDs
    _ = try FormLifecycleQualification.run(in: graph, pageIDs: pageIDs)
    #expect(graph == before)
    #expect(pageIDs == pagesBefore)
    // The caller's values are still the unfilled ones.
    let values = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    #expect(values.first { $0.name == "Name" }?.stringValue == nil)
  }

  @Test func requiredEmptyFieldFailsTheSaveValidationStageOnly() throws {
    let (graph, pageIDs) = try authoredForm(requiredEmpty: true)
    let report = try FormLifecycleQualification.run(in: graph, pageIDs: pageIDs)
    #expect(!report.passed)
    #expect(report.failedStages.map(\.name) == ["save-validation"])
    let stage = try #require(report.failedStages.first)
    #expect(stage.notes.joined().contains("required"))
  }

  @Test func qualificationRefusesDocumentsWithoutFields() throws {
    let parsed = try PDFParser.parse(PDFFixtures.onePage())
    #expect(throws: PDFError.self) {
      _ = try FormLifecycleQualification.run(in: parsed.graph, pageIDs: parsed.pageIDs)
    }
  }

  @Test func exportStageKeepsUnicodeValuesAndChoiceIdentities() throws {
    var (graph, pageIDs) = try authoredForm()
    let firstPage = try #require(pageIDs.first)
    graph = try PDFEditingEngine.commit(
      PDFTransaction([
        AddTextFieldCommand(pageID: firstPage, rect: [300, 560, 500, 584], name: "Note"),
        SetFormTextCommand(fieldName: "Note", text: "Grüße, Åsa"),
        SetFormChoiceCommand(fieldName: "Plan", exportValue: "Pro"),
        SetFormButtonStateCommand(fieldName: "Agree", state: PDFName("Yes")),
      ]), to: graph)
    let report = try FormLifecycleQualification.run(in: graph, pageIDs: pageIDs)
    // The qualification fills Name/Plan/Agree; the pre-existing Unicode value in
    // Note must survive every stage and both export formats.
    #expect(report.valuesAfterFill["Note"] == "text:Grüße, Åsa")
    #expect(report.valuesAfterFill["Plan"] == "choice:Basic")
    let exportStage = try #require(report.stages.first { $0.name == "export" })
    #expect(exportStage.passed, "\(exportStage.notes.joined(separator: "; "))")
  }
}
