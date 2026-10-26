import Foundation
import PDFCore
@testable import PDFEditing
import PDFFixtures
import Testing

/// FRM-06 evidence: accessible validation (readable labels, required errors,
/// supported validation, focus order, announcements, unsupported action
/// identification) and declared show/hide rules; reset uses the existing
/// one-command reset path.
@Suite("Accessible form validation and conditional behavior (FRM-06)")
struct FormAccessibleValidationTests {
  private func parsed(_ data: Data) throws -> PDFGraph {
    try PDFParser.parse(data).graph
  }

  private func commit(
    _ commands: [any PDFEditCommand], to graph: PDFGraph
  ) throws -> PDFGraph {
    try PDFEditingEngine.commit(PDFTransaction(commands), to: graph)
  }

  private func pages(_ graph: PDFGraph) throws -> [PDFObjectID] {
    try PDFPageTree.pageIDs(in: graph)
  }

  private func field(named name: String, in graph: PDFGraph) throws -> FormField? {
    try FormInventory.fields(in: graph, pageIDs: try pages(graph))
      .first { $0.name == name }
  }

  @Test func requiredFieldProducesFocusableError() throws {
    let graph = try parsed(PDFFixtures.formPages())
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let required = report.errors.filter { $0.kind == .requiredField }
    #expect(!required.isEmpty)
    guard let issue = required.first(where: { $0.fieldName == "notes" }) else {
      Issue.record("Expected the required notes field to be reported")
      return
    }
    #expect(issue.label == "notes")
    #expect(issue.isFocusable)
    #expect(issue.focusOrder == 0)
    #expect(issue.focusInstruction.contains("Move focus to notes"))
    #expect(issue.pageIndex != nil)
    #expect(report.focusIssueID == issue.id)
    #expect(report.announcements.joined().contains("Error: notes"))
    #expect(report.announcements.joined().contains("page"))
    #expect(report.hasErrors)
  }

  @Test func tooltipProvidesReadableAccessibleLabel() throws {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [SetFormFieldTooltipCommand(fieldName: "notes", tooltip: "Additional notes")],
      to: graph)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let issue = try #require(
      report.errors.first { $0.fieldName == "notes" && $0.kind == .requiredField })
    #expect(issue.label == "Additional notes")
    #expect(report.announcements.joined().contains("Additional notes"))
    #expect(report.focusIssue?.label == "Additional notes")
    let fields = report.fields
    let notes = try #require(fields.first { $0.name == "notes" })
    #expect(notes.label == "Additional notes")
    #expect(notes.required)
    let locked = try #require(fields.first { $0.name == "locked" })
    #expect(locked.readOnly)
  }

  @Test func fillingRequiredFieldClearsErrorsAndAnnouncesClean() throws {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [SetFormTextCommand(fieldName: "notes", text: "filled note")], to: graph)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    #expect(!report.errors.contains { $0.kind == .requiredField })
    #expect(!report.hasErrors)
    #expect(report.focusIssueID == nil)
    #expect(report.announcements.joined().contains("No blocking form errors"))
    #expect(report.announcements.joined().contains("Form validation complete"))
  }

  @Test func maxLengthViolationIsReportedWithFocus() throws {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [SetFormFieldValidationCommand(fieldName: "name", maxLength: 3)], to: graph)
    // Set an over-limit raw value the way an imported/foreign file can contain
    // one; the owned fill command would refuse it.
    let name = try #require(try field(named: "name", in: graph))
    let nameID = try #require(name.fieldID)
    guard case .dictionary(var dictionary)? = graph.objects[nameID] else {
      Issue.record("name dictionary missing")
      return
    }
    dictionary[PDFName("V")] = .string(Data("Alice".utf8))
    graph.objects[nameID] = .dictionary(dictionary)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let issue = try #require(
      report.errors.first { $0.fieldName == "name" && $0.kind == .valueTooLong })
    #expect(issue.message.contains("5"))
    #expect(issue.message.contains("3"))
    #expect(issue.isFocusable)
    #expect(issue.focusInstruction.contains("name"))
  }

  @Test func invalidChoiceValueIsReported() throws {
    var graph = try parsed(PDFFixtures.formPages())
    let department = try #require(try field(named: "department", in: graph))
    let fieldID = try #require(department.fieldID)
    guard case .dictionary(var dictionary)? = graph.objects[fieldID] else {
      Issue.record("department dictionary missing")
      return
    }
    dictionary[PDFName("V")] = .string(Data("Bogus export".utf8))
    graph.objects[fieldID] = .dictionary(dictionary)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let issue = try #require(
      report.errors.first { $0.fieldName == "department" && $0.kind == .choiceSelection })
    #expect(issue.message.contains("Bogus export"))
    #expect(issue.isFocusable)
  }

  @Test func unsupportedExternalActionsAreIdentifiedButNotExecuted() throws {
    var graph = try parsed(PDFFixtures.formPages())
    let name = try #require(try field(named: "name", in: graph))
    let fieldID = try #require(name.fieldID)
    guard case .dictionary(var dictionary)? = graph.objects[fieldID] else {
      Issue.record("name dictionary missing")
      return
    }
    dictionary[PDFName("AA")] = .dictionary([
      PDFName("K"): .dictionary([
        PDFName("S"): .name(PDFName("JavaScript")),
        PDFName("JS"): .string(Data("app.alert('should never run')".utf8)),
      ])
    ])
    graph.objects[fieldID] = .dictionary(dictionary)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    #expect(!report.unsupportedExternalActions.isEmpty)
    #expect(
      report.unsupportedExternalActions.contains { $0.contains("additional actions") })
    let issue = try #require(
      report.issues.first {
        $0.kind == .unsupportedExternalAction && $0.fieldName == "name"
      })
    #expect(issue.severity == .warning)
    #expect(issue.disclosure.contains("never executed"))
    #expect(report.summaryLines.joined().contains("never executed"))
    // The warning is not the focus target; real errors remain first.
    #expect(report.focusIssue?.kind == .requiredField)
    #expect(!report.announcements.joined().contains("should never run"))
  }

  @Test func focusOrderFollowsPageReadingOrder() throws {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [
        SetFormFieldFlagsCommand(fieldName: "name", required: true),
        SetFormFieldFlagsCommand(fieldName: "notes", required: true),
      ], to: graph)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let focusable = report.issues.filter(\.isFocusable)
    #expect(focusable.count >= 2)
    #expect(focusable.map(\.focusOrder) == Array(0..<focusable.count))
    guard let first = focusable.first, let second = focusable.dropFirst().first else {
      Issue.record("Expected two focusable errors")
      return
    }
    #expect((first.pageIndex ?? Int.max) <= (second.pageIndex ?? Int.max))
    #expect(report.focusIssueID == first.id)
    #expect(report.announcements.contains { $0.contains(first.label) })
    #expect(report.summaryLines.joined().contains("Return validates"))
    #expect(FormAccessibleValidation.keyboardHintForSummary.contains("Return"))
  }

  @Test func resetRestoresDefaultsWithoutTouchingReadOnlyFields() throws {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [
        SetFormTextCommand(fieldName: "name", text: "Alice"),
        SetFormTextCommand(fieldName: "notes", text: "changed note"),
      ], to: graph)
    graph = try commit([ResetFormCommand()], to: graph)
    let report = FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let filledFields = Dictionary(
      uniqueKeysWithValues: report.fields.map { ($0.name, $0) })
    #expect(filledFields["name"]?.value == "")
    #expect(filledFields["notes"]?.value == "default notes")
    #expect(filledFields["locked"]?.value == "locked")
    #expect(!report.errors.contains { $0.kind == .requiredField })
  }

  @Test func declaredShowHideRulesHideAndShowFieldsLastRuleWins() throws {
    var graph = try parsed(PDFFixtures.formPages())
    graph = try commit(
      [SetFormTextCommand(fieldName: "name", text: "Alice")], to: graph)
    let hideRule = FormShowHideRule(
      conditionField: "name", expectedValue: "Alice", targetFields: ["notes"],
      behavior: .hide, note: "hide notes for this branch")
    let showRule = FormShowHideRule(
      conditionField: "name", expectedValue: "Alice", targetFields: ["notes"],
      behavior: .show)
    var report = try FormDeclaredShowHide.evaluate(
      rules: [hideRule], in: graph, pageIDs: try pages(graph))
    #expect(report.hiddenFields == ["notes"])
    #expect(report.visibleFields.contains("name"))
    #expect(report.evaluation(for: "notes")?.appliedRule?.contains("hide") == true)
    #expect(report.summaryLines.joined().contains("declared for review only"))
    // Last matching rule wins.
    report = try FormDeclaredShowHide.evaluate(
      rules: [hideRule, showRule], in: graph, pageIDs: try pages(graph))
    #expect(!report.hiddenFields.contains("notes"))
    #expect(report.evaluation(for: "notes")?.visible == true)
    // Missing condition/target fields are warned about, not silently applied.
    let missing = FormShowHideRule(
      conditionField: "missing-condition", expectedValue: nil,
      targetFields: ["missing-target"], behavior: .hide)
    let warnings = try FormDeclaredShowHide.evaluate(
      rules: [missing], in: graph, pageIDs: try pages(graph))
    #expect(!warnings.warnings.isEmpty)
    #expect(warnings.evaluation(for: "notes")?.visible == true)
    // Conditional rules do not mutate the document.
    let after = try FormAccessibleValidation.validate(
      in: graph, pageIDs: try pages(graph))
    let notesValue = after.fields.first { $0.name == "notes" }?.value
    #expect(notesValue == nil || notesValue == "")
  }

  @Test func choiceConditionMatchesSelectedExportValues() throws {
    let graph = try parsed(PDFFixtures.formPages())
    let department = try #require(try field(named: "department", in: graph))
    #expect(FormDeclaredShowHide.conditionMatches(
      field: department, expected: "Engineering"))
    #expect(!FormDeclaredShowHide.conditionMatches(
      field: department, expected: "Sales"))
    let notes = try #require(try field(named: "notes", in: graph))
    #expect(FormDeclaredShowHide.conditionMatches(field: notes, expected: nil))
    #expect(FormDeclaredShowHide.conditionMatches(field: notes, expected: ""))
  }
}
