import AppKit
import PDFCore
import PDFEditing
import SwiftUI

// MARK: - FRM-06 accessible form panel

@MainActor
final class FormAccessibleModel: ObservableObject {
  @Published private(set) var report: FormAccessibleValidationReport?
  @Published private(set) var rules: [FormShowHideRule] = []
  @Published private(set) var showHideReport: FormShowHideReport?
  @Published var statusText: String?
  @Published var errorText: String?
  @Published private(set) var reportVersion = 0

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    load()
  }

  var fields: [FormAccessibleField] { report?.fields ?? [] }
  var issues: [FormAccessibleIssue] { report?.issues ?? [] }
  var focusIssue: FormAccessibleIssue? { report?.focusIssue }

  func load() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      report = nil
      return
    }
    report = FormAccessibleValidation.validate(
      in: graph, pageIDs: document.editSession.pageIDs)
    evaluateRules(announce: false)
    reportVersion &+= 1
    errorText = nil
  }

  func validate() {
    load()
    guard let report else { return }
    statusText = report.summaryLines.first
    if let focusIssue {
      announce(focusIssue.announcement + " " + focusIssue.focusInstruction)
    } else {
      announce(report.announcements.joined(separator: " "))
    }
  }

  func focusFirstError() -> FormAccessibleIssue? {
    guard let focusIssue else { return nil }
    focus(focusIssue)
    return focusIssue
  }

  func focus(_ issue: FormAccessibleIssue) {
    if let pageIndex = issue.pageIndex {
      document?.viewer?.go(to: pageIndex + 1)
    }
    announce(issue.announcement + " " + issue.focusInstruction)
    statusText = "Focused " + issue.label + ": " + issue.message
  }

  func resetForm() {
    guard let document, let graph = document.editSession.currentGraph else { return }
    _ = graph
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([ResetFormCommand()]), actionName: "Reset Form")
    else {
      errorText = "The reset was refused by the document session."
      return
    }
    load()
    statusText = "Form values restored to their defaults; read-only fields were untouched."
    announce("Form reset. " + (report?.announcements.joined(separator: " ") ?? ""))
  }

  func addRule(
    conditionField: String, expectedValue: String, targetField: String,
    behavior: FormShowHideBehavior
  ) {
    let trimmed = expectedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let rule = FormShowHideRule(
      conditionField: conditionField,
      expectedValue: trimmed.isEmpty ? nil : trimmed,
      targetFields: targetField.isEmpty ? [] : [targetField],
      behavior: behavior, note: "declared in the accessible form review")
    rules.append(rule)
    evaluateRules(announce: true)
  }

  func removeRule(at index: Int) {
    guard rules.indices.contains(index) else { return }
    rules.remove(at: index)
    evaluateRules(announce: true)
  }

  func evaluateRules(announce shouldAnnounce: Bool) {
    guard let document, let graph = document.editSession.currentGraph else { return }
    do {
      showHideReport = try FormDeclaredShowHide.evaluate(
        rules: rules, in: graph, pageIDs: document.editSession.pageIDs)
      if shouldAnnounce, let showHideReport {
        announce(showHideReport.summaryLines.prefix(2).joined(separator: " "))
      }
      errorText = nil
    } catch {
      showHideReport = nil
      errorText = error.localizedDescription
    }
  }

  func announce(_ message: String) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: trimmed,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
}

// MARK: - Window

@MainActor
final class FormAccessibleWindowController: NSWindowController {
  let model: FormAccessibleModel

  init(document: SPDFDocument) {
    let model = FormAccessibleModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Form Validation and Accessibility"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 820, height: 560)
    panel.contentView = NSHostingView(
      rootView: FormAccessibleView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the accessible form panel")
  }

  func refresh() { model.load() }
}

// MARK: - View

struct FormAccessibleView: View {
  @ObservedObject var model: FormAccessibleModel
  @State private var focusedIssueID: String?
  @FocusState private var focusedField: String?
  @State private var conditionField = ""
  @State private var expectedValue = ""
  @State private var targetField = ""
  @State private var behavior: FormShowHideBehavior = .hide

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if let error = model.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let status = model.statusText {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HSplitView {
        fieldList
          .frame(minWidth: 320, idealWidth: 380)
        issueList
          .frame(minWidth: 380)
      }
      Divider()
      rulesSection
      Text(
        model.report?.keyboardHint
          ?? "Press Return to validate; the first error receives focus.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(minWidth: 820, minHeight: 560)
    .onChange(of: model.reportVersion) { _, _ in
      focusedField = model.report?.focusIssueID
    }
    .accessibilityLabel("Form validation and accessibility")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Form Validation and Accessibility")
          .font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 10) {
        Button("Validate") { model.validate() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("Validate form")
          .accessibilityHint("Return validates and moves focus to the first error.")
        Button("Focus First Error") {
          if let issue = model.focusFirstError() {
            focusedField = issue.id
            focusedIssueID = issue.id
          }
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .accessibilityLabel("Focus first form error")
        Button("Reset Form") { model.resetForm() }
          .accessibilityLabel("Reset form to defaults")
        Button("Refresh") { model.load() }
        Spacer()
        Text(focusSummary)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var focusSummary: String {
    guard let report = model.report else { return "No validation report" }
    return "\(report.errors.count) error(s), \(report.warnings.count) warning(s)"
      + (model.focusIssue.map { " | focus: \($0.label)" } ?? "")
  }

  private var fieldList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Fields").font(.headline)
      if model.fields.isEmpty {
        Text("This document has no form fields.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        List {
          ForEach(model.fields) { field in
            VStack(alignment: .leading, spacing: 2) {
              Text(field.label)
                .font(.caption.weight(.semibold))
              Text(field.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              if field.required {
                Text("Required")
                  .font(.caption2)
                  .foregroundStyle(.orange)
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(field.label)
            .accessibilityValue(field.summary)
            .accessibilityHint(
              field.required ? "Required field" : "Optional field")
          }
        }
        .listStyle(.sidebar)
      }
    }
  }

  private var issueList: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Findings").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(model.issues) { issue in
            issueRow(issue)
          }
          if let actions = model.report?.unsupportedExternalActions, !actions.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              Text("Unsupported external actions (never executed)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
              ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Text(action)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(8)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
          }
          if let lines = model.report?.summaryLines, !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }
  }

  private func issueRow(_ issue: FormAccessibleIssue) -> some View {
    let selected = focusedIssueID == issue.id
      || (focusedIssueID == nil && model.report?.focusIssueID == issue.id)
    return HStack(alignment: .top, spacing: 8) {
      Text(issue.severity == .error ? "!" : issue.severity == .warning ? "?" : "i")
        .font(.caption.weight(.bold))
        .foregroundStyle(
          issue.severity == .error
            ? Color.red : (issue.severity == .warning ? Color.orange : Color.secondary))
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.kind.title + ": " + issue.label)
          .font(.caption.weight(issue.isFocusable ? .semibold : .regular))
        Text(issue.message)
          .font(.caption2)
          .fixedSize(horizontal: false, vertical: true)
        Text(issue.focusInstruction)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(6)
    .background(
      selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
    .onTapGesture {
      focusedIssueID = issue.id
      focusedField = issue.id
      model.focus(issue)
    }
    .focusable()
    .focused($focusedField, equals: issue.id)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(issue.kind.title + ", " + issue.label)
    .accessibilityValue(issue.message)
    .accessibilityHint(issue.focusInstruction)
  }

  private var rulesSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Declared show/hide rules").font(.headline)
      Text(
        "Declare a review rule for conditional fields. Rules are evaluated read-only; "
          + "imported JavaScript show/hide actions are identified but never executed.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Picker("When", selection: $conditionField) {
          Text("Choose field").tag("")
          ForEach(model.fields) { field in
            Text(field.label).tag(field.name)
          }
        }
        .frame(width: 170)
        .accessibilityLabel("Rule condition field")
        TextField("equals value (blank = empty/off)", text: $expectedValue)
          .textFieldStyle(.roundedBorder)
          .frame(width: 190)
          .accessibilityLabel("Rule expected value")
        Picker("then", selection: $targetField) {
          Text("Choose target").tag("")
          ForEach(model.fields) { field in
            Text(field.label).tag(field.name)
          }
        }
        .frame(width: 170)
        .accessibilityLabel("Rule target field")
        Picker("", selection: $behavior) {
          Text("Hide").tag(FormShowHideBehavior.hide)
          Text("Show").tag(FormShowHideBehavior.show)
        }
        .frame(width: 90)
        .accessibilityLabel("Rule behavior")
        Button("Add Rule") {
          guard !conditionField.isEmpty, !targetField.isEmpty else {
            model.statusText = "Choose a condition field and a target field first."
            return
          }
          model.addRule(
            conditionField: conditionField, expectedValue: expectedValue,
            targetField: targetField, behavior: behavior)
          expectedValue = ""
        }
        .accessibilityLabel("Add declared show or hide rule")
        Button("Evaluate") { model.evaluateRules(announce: true) }
          .accessibilityLabel("Evaluate declared rules")
        Spacer()
      }
      if !model.rules.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(model.rules.enumerated()), id: \.offset) { index, rule in
            HStack(spacing: 6) {
              Text(rule.declaration)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
              Spacer()
              Button("Remove") { model.removeRule(at: index) }
                .buttonStyle(.link)
                .accessibilityLabel("Remove rule " + String(index + 1))
            }
          }
        }
      }
      if let showHide = model.showHideReport {
        Text(showHide.summaryLines.joined(separator: " "))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Document route

extension SPDFDocument {
  var canShowFormAccessiblePanel: Bool {
    editSession.currentGraph != nil
  }

  func presentFormAccessiblePanel() {
    if let controller = windowControllers.compactMap({
      $0 as? FormAccessibleWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FormAccessibleWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
