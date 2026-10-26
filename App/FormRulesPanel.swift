import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

// FRM-04: the recorded calculation/format portability decision and the
// rule/action inventory, with Recalculate and Freeze Static Results routes.
// Nothing here executes an imported document action or authors a script.

@MainActor
final class FormRulesPanelModel: ObservableObject {
  struct RuleRow: Identifiable, Equatable {
    let id: String
    let fieldName: String
    let kindLabel: String
    let classes: [String]
    let formatSummary: String
    let calculationSummary: String
    let actions: [String]
    let disclosure: String
    let isAppSpecific: Bool
  }

  @Published var statusText = "No form rules have been analysed yet."
  @Published var errorText: String?
  @Published var rows: [RuleRow] = []
  @Published var summary = ""
  @Published var disclosures: [String] = []
  @Published var claimedProfiles: [String] = FormRulePortabilityDecision.claimedProfiles
  @Published var notClaimed: [String] = FormRulePortabilityDecision.notClaimed
  @Published var freezeGuarantee = FormRulePortabilityDecision.freezeGuarantee
  @Published var hasRules = false
  @Published var hasImportedActions = false
  @Published var canRecalculate = true
  @Published var stripRules = true
  @Published var writeDefaultValue = true
  @Published var makeReadOnly = false
  @Published var freezeStatus = ""
  @Published var recalculateStatus = ""

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  func refresh() {
    guard let document else { return }
    if let report = document.formRulesReport() {
      rows = report.fields.map { field in
        RuleRow(
          id: field.fieldName, fieldName: field.fieldName,
          kindLabel: field.kind.rawValue,
          classes: field.classes.map(\.label),
          formatSummary: field.formatSummary ?? "",
          calculationSummary: field.calculationSummary ?? "",
          actions: field.importedActionSummaries,
          disclosure: field.disclosure, isAppSpecific: field.isAppSpecific)
      }
      summary = report.summary
      disclosures = report.disclosures
      hasRules = report.hasAppSpecificRules
      hasImportedActions = report.hasImportedActions
      canRecalculate = hasRules
      if statusText == "No form rules have been analysed yet." {
        statusText = report.summary
      }
    } else {
      rows = []
      summary = ""
      disclosures = []
      hasRules = false
      hasImportedActions = false
      canRecalculate = false
      statusText = "No document or no readable form is open."
    }
    errorText = nil
  }

  func recalculate() {
    errorText = nil
    recalculateStatus = ""
    guard let document else { return }
    if document.recalculateFormRules() {
      recalculateStatus = "Recalculated the declared sPDF rules. One Undo restores the previous values."
      statusText = "Recalculation complete."
    } else {
      errorText = document.formRulesLastError ?? "The form could not be recalculated."
      statusText = "Recalculation refused; nothing was changed."
    }
    refresh()
  }

  func freeze() {
    errorText = nil
    freezeStatus = ""
    guard let document else { return }
    if document.freezeFormStaticResults(
      stripRules: stripRules, writeDefaultValue: writeDefaultValue,
      makeReadOnly: makeReadOnly)
    {
      freezeStatus =
        "Frozen the current results as ordinary static field data. One Undo restores the rules."
      statusText = "Static results written."
    } else {
      errorText = document.formRulesLastError ?? "The results could not be frozen."
      statusText = "Freeze refused; nothing was changed."
    }
    refresh()
  }

  func copyReportJSON() {
    guard let document, let report = document.formRulesReport(),
      let data = FormRulePortability.json(report)
    else {
      errorText = "There is no portability report to copy."
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setData(data, forType: .string)
    freezeStatus = "Copied the portability report JSON to the clipboard."
  }
}

@MainActor
final class FormRulesPanelController: NSWindowController {
  let model: FormRulesPanelModel

  init(document: SPDFDocument) {
    let model = FormRulesPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Form Rules and Portability"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 860, height: 620)
    panel.contentView = NSHostingView(rootView: FormRulesPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the form rules panel")
  }

  func refresh() { model.refresh() }
}

private enum FormRulesAssociationKeys {
  /// Address used only as an associated-object key; the value is never read.
  nonisolated(unsafe) static var error: UInt8 = 0
}

extension SPDFDocument {
  /// Form > Field Rules and Portability…: show the recorded decision and the
  /// per-field rule/action inventory.
  func showFormRulesPanel() {
    if let controller = windowControllers.compactMap({ $0 as? FormRulesPanelController }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FormRulesPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowFormRulesPanel: Bool { viewer != nil && editSession.currentGraph != nil }

  var formRulesLastError: String? {
    get {
      objc_getAssociatedObject(self, &FormRulesAssociationKeys.error) as? String
    }
    set {
      objc_setAssociatedObject(
        self, &FormRulesAssociationKeys.error, newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }

  func formRulesReport() -> FormRulePortabilityReport? {
    guard let graph = editSession.currentGraph else { return nil }
    return FormRulePortability.analyze(in: graph, pageIDs: editSession.pageIDs)
  }

  // MARK: Shared advanced-form transaction route

  /// One panel action becomes one edit-session transaction and one native undo
  /// group, then the viewer reloads without installing the design canvas.
  @discardableResult
  func applyFormAdvancedTransaction(_ transaction: PDFTransaction, actionName: String) -> Bool {
    guard requireContentEditing(for: actionName) else { return false }
    guard finishPendingEdits() else { return false }
    do {
      try editSession.apply(transaction)
    } catch {
      _ = presentError(error)
      formRulesLastError = error.localizedDescription
      formRichTextLastError = error.localizedDescription
      return false
    }
    registerFormAdvancedUndo(actionName: actionName)
    formRulesLastError = nil
    reloadFormAdvancedViewer()
    return true
  }

  private func registerFormAdvancedUndo(actionName: String) {
    guard let undoManager else {
      updateChangeCount(.changeDone)
      return
    }
    let revision = editSession.documentRevision
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performFormAdvancedUndo(registeredRevision: revision, actionName: actionName)
    }
    undoManager.setActionName(actionName)
    undoManager.endUndoGrouping()
  }

  func performFormAdvancedUndo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performFormAdvancedRedo(registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    reloadFormAdvancedViewer()
  }

  func performFormAdvancedRedo(registeredRevision: UInt64?, actionName: String) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performFormAdvancedUndo(registeredRevision: revision, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    reloadFormAdvancedViewer()
  }

  func reloadFormAdvancedViewer() {
    guard let data = try? editSession.bytesForSave(),
      let source = try? PDFSource(data: data)
    else { return }
    let page = viewer?.pageNumber ?? 0
    let tool = viewer?.activeTool ?? .select
    try? viewer?.open(source)
    _ = viewer?.activateTool(tool)
    if page > 0 { viewer?.go(to: page) }
    refreshForms()
    refreshComments()
    refreshFonts()
    refreshDocumentInfo()
    workspaceDocumentState.hasChanges = isDocumentEdited
    workspaceDocumentState.canUndo = editSession.canUndo
    workspaceDocumentState.canRedo = editSession.canRedo
    for controller in windowControllers {
      if let rules = controller as? FormRulesPanelController { rules.refresh() }
      if let rich = controller as? FormRichTextPanelController { rich.refresh() }
    }
    formDesignSession.canvas?.refreshFromDocument()
    formDesignSession.panelController?.refresh()
  }

  /// Recalculate the declared sPDF rules as one undoable transaction.
  @discardableResult
  func recalculateFormRules() -> Bool {
    let command = RecalculateFormCommand()
    guard let graph = editSession.currentGraph else { return false }
    do {
      try command.validate(in: graph)
    } catch {
      formRulesLastError = error.localizedDescription
      return false
    }
    let applied = applyFormAdvancedTransaction(
      PDFTransaction([command]), actionName: "Recalculate Form")
    if !applied, formRulesLastError == nil {
      formRulesLastError = "The document is not editable right now."
    }
    return applied
  }

  /// Freeze the declared rule results as ordinary static values (FRM-04).
  @discardableResult
  func freezeFormStaticResults(
    stripRules: Bool, writeDefaultValue: Bool, makeReadOnly: Bool
  ) -> Bool {
    let command = FreezeFormResultsCommand(
      stripRules: stripRules, writeDefaultValue: writeDefaultValue, makeReadOnly: makeReadOnly)
    guard let graph = editSession.currentGraph else { return false }
    do {
      try command.validate(in: graph)
    } catch {
      formRulesLastError = error.localizedDescription
      return false
    }
    let applied = applyFormAdvancedTransaction(
      PDFTransaction([command]), actionName: "Freeze Form Results")
    if !applied, formRulesLastError == nil {
      formRulesLastError = "The document is not editable right now."
    }
    return applied
  }
}

// MARK: - SwiftUI panel

struct FormRulesPanelView: View {
  @ObservedObject var model: FormRulesPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        decisionSection
        Divider()
        inventorySection
        Divider()
        actionSection
        footer
      }
      .padding(18)
    }
    .frame(minWidth: 860, minHeight: 620)
    .accessibilityLabel("Form rules and portability")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Form Rules and Portability").font(.title3).bold()
      Text(model.summary.isEmpty ? model.statusText : model.summary)
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      Text(
        "Profile: " + FormRulePortabilityDecision.profileIdentifier
          + ". sPDF authors and executes no document JavaScript.")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var decisionSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recorded portability decision").font(.headline)
      Text("Claimed:").font(.caption).bold()
      ForEach(model.claimedProfiles.indices, id: \.self) { index in
        Text(model.claimedProfiles[index]).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Not claimed:").font(.caption).bold()
      ForEach(model.notClaimed.indices, id: \.self) { index in
        Text("• " + model.notClaimed[index]).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var inventorySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Field rule inventory").font(.headline)
        Spacer()
        Text(model.hasRules ? "sPDF-only rules present" : "Static values only")
          .font(.caption).foregroundStyle(model.hasRules ? Color.orange : Color.secondary)
        if model.hasImportedActions {
          Text("imported actions preserved").font(.caption).foregroundStyle(.purple)
        }
      }
      if model.rows.isEmpty {
        Text("No form fields are present.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(model.rows) { row in
        FormRulesRowView(row: row)
      }
    }
  }

  private var actionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recalculation and static results").font(.headline)
      Text(
        "Recalculate evaluates only the declared sPDF sum/format rules. Freeze Static Results "
          + "writes the current values as ordinary static field data so any reader shows them "
          + "without recalculating.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Button("Recalculate Now") { model.recalculate() }
          .disabled(!model.canRecalculate)
          .accessibilityLabel("Recalculate the declared form rules")
        Button("Copy Portability Report (JSON)") { model.copyReportJSON() }
      }
      HStack(spacing: 16) {
        Toggle("Remove sPDF rule keys", isOn: $model.stripRules)
        Toggle("Write frozen value as default", isOn: $model.writeDefaultValue)
        Toggle("Mark frozen fields read-only", isOn: $model.makeReadOnly)
      }
      .font(.caption)
      Button("Freeze Static Results") { model.freeze() }
        .disabled(!model.hasRules)
        .accessibilityLabel("Freeze form results as static values")
      if !model.recalculateStatus.isEmpty {
        Text(model.recalculateStatus).font(.caption2).foregroundStyle(.green)
      }
      if !model.freezeStatus.isEmpty {
        Text(model.freezeStatus).font(.caption2).foregroundStyle(.green)
      }
      Text(model.freezeGuarantee).font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(model.disclosures.indices, id: \.self) { index in
        Text(model.disclosures[index]).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct FormRulesRowView: View {
  let row: FormRulesPanelModel.RuleRow

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(row.fieldName).font(.caption).bold()
        Text(row.kindLabel).font(.caption2).foregroundStyle(.secondary)
        ForEach(row.classes.indices, id: \.self) { index in
          Text(row.classes[index])
            .font(.caption2)
            .padding(.horizontal, 5)
            .background(
              (row.isAppSpecific ? Color.orange : Color.secondary).opacity(0.15),
              in: Capsule())
        }
        Spacer()
      }
      if !row.formatSummary.isEmpty {
        Text("Format: " + row.formatSummary).font(.caption2).foregroundStyle(.secondary)
      }
      if !row.calculationSummary.isEmpty {
        Text("Calculation: " + row.calculationSummary)
          .font(.caption2).foregroundStyle(.secondary)
      }
      ForEach(row.actions.indices, id: \.self) { index in
        Text("Imported action: " + row.actions[index]).font(.caption2)
          .foregroundStyle(.purple)
      }
      if !row.disclosure.isEmpty {
        Text(row.disclosure).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(6)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }
}
