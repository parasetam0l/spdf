import AppKit
import Combine
import MacServices
import SwiftUI

// UX-01/UX-02: qualification panel. It shows the declared keyboard/VoiceOver
// contract, the manual protocol and its limits, the compact-window minimums per
// workflow, and live headless qualification reports. It never claims synthetic
// speech is real VoiceOver output.

@MainActor
final class UXQualificationPanelModel: ObservableObject {
  struct ContractRow: Identifiable, Equatable {
    let id: String
    let transition: String
    let announcement: String
    let keys: String
    let restoresFocus: Bool
  }

  struct ScenarioRow: Identifiable, Equatable {
    let id: String
    let title: String
    let minimum: String
    let controls: String
    let passed: Bool
    let issues: String
  }

  @Published var contractRows: [ContractRow] = []
  @Published var protocolLines: [String] = []
  @Published var protocolLimits: [String] = []
  @Published var scenarioRows: [ScenarioRow] = []
  @Published var probeSummary = ""
  @Published var probeIssues: [String] = []
  @Published var workflowSummary = ""
  @Published var statusText = "Qualification is headless; real VoiceOver speech needs the "
    + "manual protocol."
  @Published var errorText: String?
  private var manualProtocolText = ""

  init(document: SPDFDocument?) {
    reload()
  }

  func reload() {
    contractRows = UXAccessibilityContract.requirements.map { requirement in
      ContractRow(
        id: requirement.transition.rawValue,
        transition: requirement.transition.rawValue,
        announcement: requirement.announcement.spokenText,
        keys: requirement.keyboardCommand.keys + " — " + requirement.keyboardCommand.action,
        restoresFocus: requirement.restoresFocus)
    }
    protocolLines = UXAccessibilityContract.manualVoiceOverProtocol
    protocolLimits = UXAccessibilityContract.manualProtocolLimits
    manualProtocolText = (["sPDF UX-01 manual VoiceOver protocol"] + protocolLines
      + ["", "Limits:"] + protocolLimits).joined(separator: "\n")

    let reports = CompactWindowQualification.runAll()
    scenarioRows = reports.map { report in
      ScenarioRow(
        id: report.scenario.rawValue,
        title: report.scenario.title,
        minimum: report.minimum.description,
        controls: report.scenario.requiredControlIDs.joined(separator: ", "),
        passed: report.passed,
        issues: report.issues.map(\.message).joined(separator: "; "))
    }

    let probe = UXAppKitProbe.run()
    probeSummary = String(probe.elements.count) + " AppKit element(s) probed, "
      + String(probe.keyViewOrder.count) + " in the key view loop; attributes "
      + (probe.report.passed ? "complete." : "have issues.")
    probeIssues = probe.report.issues
    workflowSummary = "Manual protocol rows: " + String(protocolLines.count)
      + "; compact scenarios passed: "
      + String(reports.filter(\.passed).count) + "/" + String(reports.count) + "."
    statusText = probe.report.passed && reports.allSatisfy(\.passed)
      ? "Headless qualification passed; record the manual VoiceOver protocol for the speech claim."
      : "Headless qualification has issues; see the details below."
  }

  func copyManualProtocol() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(manualProtocolText, forType: .string)
    statusText = "Copied the manual VoiceOver protocol and its limits."
  }
}

@MainActor
final class UXQualificationPanelController: NSWindowController {
  let model: UXQualificationPanelModel
  init(document: SPDFDocument?) {
    let model = UXQualificationPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 860),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "UX Qualification"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 900, height: 640)
    panel.contentView = NSHostingView(rootView: UXQualificationPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the UX qualification panel")
  }
}

extension SPDFDocument {
  /// UX-01/UX-02 hook: show the keyboard/VoiceOver contract and compact-window
  /// qualification report. Read-only; nothing is applied to the document.
  func showUXQualificationPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? UXQualificationPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = UXQualificationPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowUXQualificationPanel: Bool { true }
}

struct UXQualificationPanelView: View {
  @ObservedObject var model: UXQualificationPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        contractSection
        Divider()
        compactSection
        Divider()
        protocolSection
      }
      .padding(16)
    }
    .frame(minWidth: 900, minHeight: 640)
    .accessibilityLabel("Keyboard, VoiceOver and compact-window qualification")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("UX Qualification").font(.title3).bold()
        Spacer()
        Button("Run Again") { model.reload() }
        Button("Copy Manual Protocol") { model.copyManualProtocol() }
      }
      Text(model.workflowSummary).font(.callout)
      Text(model.probeSummary).font(.caption)
      Text(model.statusText).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var contractSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Keyboard and VoiceOver contract").font(.headline)
      ForEach(model.contractRows) { row in
        HStack(alignment: .top, spacing: 8) {
          Text(row.transition).font(.caption.weight(.semibold)).frame(width: 150, alignment: .leading)
          VStack(alignment: .leading, spacing: 1) {
            Text(row.announcement).font(.caption2)
            Text(row.keys + (row.restoresFocus ? " · restores focus" : ""))
              .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var compactSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Compact windows — declared minimum sizes").font(.headline)
      ForEach(model.scenarioRows) { row in
        HStack(alignment: .top, spacing: 8) {
          Text(row.passed ? "Pass" : "Fail").font(.caption2).bold()
            .foregroundStyle(row.passed ? Color.green : Color.red)
            .frame(width: 40, alignment: .leading)
          Text(row.title).font(.caption.weight(.semibold)).frame(width: 220, alignment: .leading)
          Text(row.minimum).font(.caption2).frame(width: 100, alignment: .leading)
          Text(row.controls).font(.caption2).foregroundStyle(.secondary)
          if !row.issues.isEmpty {
            Text(row.issues).font(.caption2).foregroundStyle(.red)
          }
        }
      }
    }
  }

  private var protocolSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Manual VoiceOver protocol (human acceptance step)").font(.headline)
      ForEach(Array(model.protocolLines.enumerated()), id: \.offset) { item in
        Text(String(item.offset + 1) + ". " + item.element).font(.caption2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Protocol limits").font(.headline)
      ForEach(Array(model.protocolLimits.enumerated()), id: \.offset) { item in
        Text("· " + item.element).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
