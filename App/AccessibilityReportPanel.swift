import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - A11Y-05/A11Y-06 report model

@MainActor
final class AccessibilityReportModel: ObservableObject {
  @Published private(set) var report: AccessibilityNavigableReport?
  @Published private(set) var conformance: AccessibleOutputConformanceReport?
  @Published private(set) var rerunReport: AccessibilityNavigableReport?
  @Published private(set) var validatorResult: ArchivalValidationResult?
  @Published private(set) var validatorMessage: String?
  @Published private(set) var humanResults: [String: AccessibilityHumanCheckResult] = [:]
  @Published var preparedTitle = ""
  @Published var preparedLanguage = ""
  @Published private(set) var validationGeneration = 0
  @Published var statusText: String?
  @Published var errorText: String?

  private weak var document: SPDFDocument?
  private let profile = AccessibleOutputProfile()

  init(document: SPDFDocument) {
    self.document = document
    load()
  }

  var outcomes: [AccessibilityRuleOutcome] { report?.outcomes ?? [] }
  var findings: [AccessibilityNavigableFinding] { report?.findings ?? [] }
  var humanChecks: [AccessibleOutputHumanCheck] {
    AccessibleOutputProfileValidation.humanChecks(for: profile, results: humanResults)
  }

  var verdict: AccessibleOutputVerdict { conformance?.verdict ?? .notVerified }

  func load() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      report = nil
      conformance = nil
      return
    }
    if preparedTitle.isEmpty {
      preparedTitle =
        PrepareAccessibleProfileCommand.existingTitle(in: graph)
        ?? document.fileURL?.deletingPathExtension().lastPathComponent ?? ""
    }
    if preparedLanguage.isEmpty {
      preparedLanguage = currentLanguage(in: graph) ?? "en-US"
    }
    let pageIDs = document.editSession.pageIDs
    report = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: pageIDs, humanChecks: manualBooleans,
      independentValidator: validatorResult,
      validatorUnavailableReason: validatorUnavailableReason)
    reloadConformance(graph: graph, pageIDs: pageIDs)
    validationGeneration &+= 1
    errorText = nil
  }

  func refresh() {
    rerunReport = nil
    load()
  }

  func setHumanCheck(_ ruleID: String, result: AccessibilityHumanCheckResult) {
    humanResults[ruleID] = result
    guard let document, let graph = document.editSession.currentGraph else { return }
    let pageIDs = document.editSession.pageIDs
    report = AccessibilityReportBuilder.build(
      graph: graph, pageIDs: pageIDs, humanChecks: manualBooleans,
      independentValidator: validatorResult,
      validatorUnavailableReason: validatorUnavailableReason)
    reloadConformance(graph: graph, pageIDs: pageIDs)
    validationGeneration &+= 1
    statusText = "Human checks updated; the profile verdict is recalculated from real evidence."
  }

  func runIndependentValidator() {
    guard let document, let graph = document.editSession.currentGraph else { return }
    var snapshot = graph
    if document.editSession.isProtected {
      snapshot.trailer[PDFName("Encrypt")] = nil
    }
    do {
      let data = try PDFWriter.write(
        snapshot, limits: SPDFDocumentResourcePolicy.parsingLimits)
      validatorResult = ArchivalDerivative.validateAccessibility(data)
      if let result = validatorResult {
        validatorMessage = result.report()
        statusText = result.isCompliant
          ? "Independent validator reports compliance; human checks are still required for a pass."
          : "Independent validator reports noncompliance; the profile cannot pass."
      } else {
        validatorMessage = "Independent validator unavailable (not a pass)."
        statusText = nil
        errorText = "veraPDF is not available, so independent validation could not be run. "
          + "Unavailable validation is never represented as a pass."
      }
      rerunReport = nil
      load()
    } catch {
      errorText = error.localizedDescription
    }
  }

  func prepareProfile() {
    guard let document else { return }
    let title = preparedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let language = preparedLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      return
    }
    let command = PrepareAccessibleProfileCommand(
      title: title.isEmpty ? nil : title,
      language: language.isEmpty ? nil : language)
    do {
      try command.validate(in: graph)
    } catch {
      errorText = error.localizedDescription
      return
    }
    guard
      document.applyPageOrganizerTransaction(
        PDFTransaction([command]), actionName: "Complete PDF/UA Profile Metadata")
    else {
      errorText = "Completing the profile metadata was refused by the document session."
      return
    }
    statusText =
      "Declared PDF/UA-1 metadata written (title, language, DisplayDocTitle, XMP id). "
      + "Conformance still requires independent validation and human checks."
    rerunReport = nil
    load()
  }

  func rerun(ruleID: String) {
    guard let document, let graph = document.editSession.currentGraph else { return }
    rerunReport = AccessibilityReportBuilder.rerun(
      ruleIDs: [ruleID], graph: graph, pageIDs: document.editSession.pageIDs,
      humanChecks: manualBooleans, independentValidator: validatorResult,
      validatorUnavailableReason: validatorUnavailableReason)
    statusText = "Reran only the affected check: " + ruleID + "."
    validationGeneration &+= 1
  }

  func focus(_ object: AccessibilityObjectReference) {
    if let pageIndex = object.pageIndex {
      document?.viewer?.go(to: pageIndex + 1)
    }
    if object.kind == .structureElement || object.role != nil {
      document?.viewer?.showStructure()
    }
    announce(
      object.navigationLine
        + (object.detail.map { ". " + $0 } ?? ""))
  }

  func showRemedy(_ tool: AccessibilityRemediationTool) {
    announce(tool.title + ": " + tool.routeHint)
    statusText = tool.title + " — " + tool.routeHint
    if tool == .structureInspector {
      document?.viewer?.showStructure()
    }
  }

  func exportReport() {
    guard let document else { return }
    var text = "sPDF Editor accessibility report\n\n"
    text += conformance?.report ?? report?.report ?? "No report available."
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-accessibility-report.txt"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        self?.statusText = "Accessibility report exported."
        self?.errorText = nil
      } catch {
        self?.errorText = error.localizedDescription
      }
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

  private var manualBooleans: [String: Bool] {
    humanResults.compactMapValues { result -> Bool? in
      switch result {
      case .pass: return true
      case .fail: return false
      case .notChecked: return nil
      }
    }
  }

  private var validatorUnavailableReason: String? {
    if validatorResult != nil { return nil }
    return "The independent validator has not produced a verdict."
  }

  private func reloadConformance(graph: PDFGraph, pageIDs: [PDFObjectID]) {
    conformance = AccessibleOutputProfileValidation.evaluate(
      profile: profile, graph: graph, pageIDs: pageIDs,
      humanCheckResults: humanResults, independentValidator: validatorResult,
      validatorUnavailableReason: validatorUnavailableReason)
  }

  private func currentLanguage(in graph: PDFGraph) -> String? {
    guard case .reference(let catalogID)? = graph.trailer[PDFName("Root")],
      case .dictionary(let catalog)? = graph.objects[catalogID],
      case .string(let data)? = catalog[PDFName("Lang")]
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

// MARK: - Window

@MainActor
final class AccessibilityReportWindowController: NSWindowController {
  let model: AccessibilityReportModel

  init(document: SPDFDocument) {
    let model = AccessibilityReportModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Accessibility Report"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 900, height: 620)
    panel.contentView = NSHostingView(rootView: AccessibilityReportView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the accessibility report")
  }

  func refresh() { model.refresh() }
}

// MARK: - View

struct AccessibilityReportView: View {
  @ObservedObject var model: AccessibilityReportModel
  @FocusState private var focusedOutcomeID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      verdictBanner
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
        outcomeList
          .frame(minWidth: 480, idealWidth: 560)
        sidebar
          .frame(minWidth: 340)
      }
    }
    .padding(14)
    .frame(minWidth: 900, minHeight: 620)
    .onChange(of: model.validationGeneration) { _, _ in
      focusedOutcomeID = model.report?.failures.first?.id
    }
    .accessibilityLabel("Accessibility report and PDF/UA profile")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Accessibility Report").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 10) {
        Button("Refresh") { model.refresh() }
        Button("Run Independent Validator") { model.runIndependentValidator() }
          .keyboardShortcut("v", modifiers: [.command, .shift])
          .accessibilityLabel("Run independent PDF/UA validator")
        Button("Export Report…") { model.exportReport() }
        Spacer()
        Text(AccessibleOutputStandard.supportedStandards.map(\.shortTitle).joined(separator: ", "))
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("Unsupported: PDF/UA-2 (never validated)")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      Text(
        "Automatic rules are separated from manual checks. Every finding links to affected "
          + "objects and remediation tools, and rerunning a check evaluates only that rule. "
          + "A PDF/UA pass requires machine rules, a compliant independent validator verdict "
          + "and every human check passed; unavailable validation is never a pass.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var verdictBanner: some View {
    let verdict = model.verdict
    return HStack(spacing: 10) {
      Text("PDF/UA-1 profile: " + verdict.title)
        .font(.headline)
        .foregroundStyle(
          verdict == .pass ? Color.green : (verdict == .fail ? Color.red : Color.orange))
      Spacer()
      Text(
        model.conformance?.validatorUnavailable == true
          ? "Independent validation unavailable — NOT a pass"
          : "Independent validator: "
            + (model.conformance?.independentValidator?.isCompliant == true
              ? "compliant" : "not compliant/unavailable"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(
      (verdict == .pass ? Color.green : Color.orange).opacity(0.10),
      in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("PDF/UA-1 profile verdict: " + verdict.title)
  }

  private var outcomeList: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Rules and findings").font(.headline)
        Spacer()
        Text(model.report?.summaryLines.first ?? "")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(model.outcomes) { outcome in
            outcomeRow(outcome)
          }
          if let rerun = model.rerunReport {
            VStack(alignment: .leading, spacing: 2) {
              Text("Rerun result (only affected checks)")
                .font(.caption.weight(.semibold))
              ForEach(rerun.outcomes) { outcome in
                Text("[\(outcome.status.title)] \(outcome.rule.id): " + outcome.detail)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
          }
        }
      }
    }
  }

  private func outcomeRow(_ outcome: AccessibilityRuleOutcome) -> some View {
    let focused = focusedOutcomeID == outcome.id
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(outcome.status.title)
          .font(.caption2.weight(.bold))
          .foregroundStyle(statusColor(outcome.status))
        Text(outcome.rule.id)
          .font(.caption.monospaced())
        Text(outcome.rule.mode.title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Rerun") { model.rerun(ruleID: outcome.rule.id) }
          .buttonStyle(.link)
          .accessibilityLabel("Rerun only " + outcome.rule.title)
        if outcome.status == .manual {
          Text("human check")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        if outcome.status == .unavailable {
          Text("not a pass")
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }
      Text(outcome.detail)
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(outcome.findings) { finding in
        VStack(alignment: .leading, spacing: 2) {
          Text(finding.detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
          HStack(spacing: 6) {
            ForEach(finding.objects) { object in
              Button(object.navigationLine) { model.focus(object) }
                .buttonStyle(.link)
                .font(.caption2)
                .accessibilityLabel("Go to affected object " + object.navigationLine)
            }
            ForEach(finding.remediationTools, id: \.self) { tool in
              Button(tool.title) { model.showRemedy(tool) }
                .buttonStyle(.link)
                .font(.caption2)
                .accessibilityLabel("Remediate with " + tool.title)
            }
          }
        }
        .padding(.leading, 8)
      }
    }
    .padding(7)
    .background(
      focused ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04),
      in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
    .onTapGesture { focusedOutcomeID = outcome.id }
    .focusable()
    .focused($focusedOutcomeID, equals: outcome.id)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      outcome.rule.title + ", " + outcome.status.title)
    .accessibilityValue(outcome.detail)
  }

  private func statusColor(_ status: AccessibilityRuleStatus) -> Color {
    switch status {
    case .pass: return .green
    case .warning: return .orange
    case .fail: return .red
    case .manual: return .orange
    case .unavailable: return .red
    }
  }

  private var sidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        preparedMetadata
        requiredActions
        humanChecks
        validatorReport
        standardNote
      }
    }
  }

  private var preparedMetadata: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Complete PDF/UA-1 metadata").font(.headline)
      HStack(spacing: 6) {
        TextField("Document title", text: $model.preparedTitle)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Document title for PDF/UA profile")
        TextField("Language", text: $model.preparedLanguage)
          .textFieldStyle(.roundedBorder)
          .frame(width: 95)
          .accessibilityLabel("Document language for PDF/UA profile")
      }
      Button("Write Required Metadata") { model.prepareProfile() }
        .accessibilityLabel("Write required PDF/UA metadata")
      Text(
        "Writes the title, /Lang, DisplayDocTitle and the declared PDF/UA-1 XMP identifier "
          + "only when the document is already tagged. This is not a conformance claim.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var requiredActions: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Required actions").font(.headline)
      if let actions = model.conformance?.requiredActions, !actions.isEmpty {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
          Text(action)
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("None: every required profile item passes.")
          .font(.caption2)
          .foregroundStyle(.green)
      }
    }
  }

  private var humanChecks: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Human checks").font(.headline)
      ForEach(model.humanChecks) { check in
        VStack(alignment: .leading, spacing: 2) {
          Text(check.question)
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
          Picker(
            "",
            selection: Binding(
              get: { check.result },
              set: { model.setHumanCheck(check.ruleID, result: $0) })
          ) {
            ForEach(AccessibilityHumanCheckResult.allCases, id: \.self) { result in
              Text(result.title).tag(result)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityLabel("Human check result for " + check.question)
        }
      }
    }
  }

  private var validatorReport: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Independent validation").font(.headline)
      Text(
        model.validatorMessage
          ?? "Not run yet. Unavailable validation is never a pass.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var standardNote: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Declared standard").font(.headline)
      ForEach(Array(AccessibleOutputProfile().summaryLines.enumerated()), id: \.offset) {
        _, line in
        Text(line)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Document route

extension SPDFDocument {
  var canShowAccessibilityReport: Bool {
    editSession.currentGraph != nil
  }

  func presentAccessibilityReport() {
    if let controller = windowControllers.compactMap({
      $0 as? AccessibilityReportWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = AccessibilityReportWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
