import AppKit
import Combine
import Foundation
import MacServices
import SwiftUI

// UX-04: bounded large-document processing. The panel shows the declared
// classes, budgets, named machine and the architecture decision, and can run the
// measured 500-page class (and opt-in 2,000-page class). Measurements are shown
// with pass/fail and are never presented as claims for other machines.

@MainActor
final class LargeDocumentBudgetPanelModel: ObservableObject {
  struct ClassRow: Identifiable, Equatable {
    let id: String
    let title: String
    let declared: String
    let openSeconds: Double
    let saveSeconds: Double
    let textSecondsPerPage: Double
    let cancellationSeconds: Double
    let residentMemoryMB: Double
    let notes: String
  }

  struct MeasurementRow: Identifiable, Equatable {
    let id: String
    let classID: String
    let passed: Bool
    let summary: String
    let issues: String
  }

  @Published var rows: [ClassRow] = []
  @Published var measurements: [MeasurementRow] = []
  @Published var machine = ""
  @Published var decisionLines: [String] = []
  @Published var statusText = "Run a class to measure it on this machine."
  @Published var busy = false

  init(document: SPDFDocument?) {
    machine = UXLargeDocumentProfile.machineName
    rows = UXLargeDocumentProfile.classes.map { documentClass in
      let budget = UXLargeDocumentProfile.budget(for: documentClass.id)
      return ClassRow(
        id: documentClass.id, title: documentClass.title,
        declared: documentClass.declaredPages.map { String($0) + " pages" }
          ?? (documentClass.declaredBytes.map { String($0 / (1_024 * 1_024)) + " MB" } ?? "declared"),
        openSeconds: budget?.openSeconds ?? 0,
        saveSeconds: budget?.saveSeconds ?? 0,
        textSecondsPerPage: budget?.textSecondsPerPage ?? 0,
        cancellationSeconds: budget?.cancellationSeconds ?? 0,
        residentMemoryMB: budget?.residentMemoryMB ?? 0,
        notes: documentClass.notes)
    }
    let decision = UXLargeDocumentProfile.decision
    decisionLines = ["Approach: " + decision.currentApproach,
      "Bounded caches: " + decision.boundedCaches.joined(separator: " "),
      "Cancellable work: " + decision.cancellableWork.joined(separator: " "),
      "Not implemented: " + decision.notImplemented.joined(separator: " ")]
  }

  func run(classID: String) {
    guard !busy else { return }
    busy = true
    statusText = "Measuring " + classID + " on " + machine + "…"
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      do {
        let measurement = try UXLargeDocumentQualification.measure(classID: classID)
        let summary = "open " + format(measurement.openSeconds) + "s, save "
          + format(measurement.saveSeconds) + "s, text/page "
          + format(measurement.textSecondsPerPage) + "s, cancel "
          + format(measurement.cancellationSeconds) + "s, "
          + format(measurement.residentMemoryMB) + "MB, "
          + String(measurement.pageCount) + " pages, "
          + String(measurement.byteCount) + " bytes"
        measurements.removeAll { $0.classID == classID }
        measurements.append(
          MeasurementRow(
            id: classID, classID: classID, passed: measurement.passed, summary: summary,
            issues: measurement.issues.joined(separator: "; ")))
        statusText = measurement.passed
          ? "Measured " + classID + " within its declared budgets on " + machine + "."
          : "Measured " + classID + " has budget issues; see the result."
      } catch {
        statusText = "Measurement failed: " + error.localizedDescription
      }
      busy = false
    }
  }

  private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}

@MainActor
final class LargeDocumentBudgetPanelController: NSWindowController {
  let model: LargeDocumentBudgetPanelModel
  init(document: SPDFDocument?) {
    let model = LargeDocumentBudgetPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Large-Document Budget"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 820, height: 520)
    panel.contentView = NSHostingView(rootView: LargeDocumentBudgetPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the large-document budget panel")
  }
}

extension SPDFDocument {
  /// UX-04 hook: declared budgets, decision record and measured classes.
  func showLargeDocumentBudgetPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? LargeDocumentBudgetPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = LargeDocumentBudgetPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowLargeDocumentBudgetPanel: Bool { true }
}

struct LargeDocumentBudgetPanelView: View {
  @ObservedObject var model: LargeDocumentBudgetPanelModel

  /// Split out of the view builder so the type-checker does not have to solve
  /// the whole concatenation as one expression (CI type-check budget).
  private func budgetSummary(_ row: LargeDocumentBudgetPanelModel.ClassRow) -> String {
    let open = format(row.openSeconds)
    let save = format(row.saveSeconds)
    let text = format(row.textSecondsPerPage)
    let cancel = format(row.cancellationSeconds)
    let memory = format(row.residentMemoryMB)
    return "Budgets: open ≤ \(open)s, save ≤ \(save)s, text/page ≤ \(text)s, "
      + "cancel ≤ \(cancel)s, memory ≤ \(memory)MB"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Large-Document Budget").font(.title3).bold()
          Spacer()
          Text(model.machine).font(.caption).foregroundStyle(.secondary)
        }
        Text(model.statusText).font(.caption)
        ForEach(model.rows) { row in
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text(row.title).font(.caption.weight(.semibold))
              Text(row.declared).font(.caption2).foregroundStyle(.secondary)
              Spacer()
              Button("Measure") { model.run(classID: row.id) }
                .disabled(model.busy)
            }
            Text(budgetSummary(row)).font(.caption2)
            Text(row.notes).font(.caption2).foregroundStyle(.secondary)
            if let measurement = model.measurements.first(where: { $0.classID == row.id }) {
              Text((measurement.passed ? "Pass: " : "Fail: ") + measurement.summary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(measurement.passed ? Color.green : Color.red)
              if !measurement.issues.isEmpty {
                Text(measurement.issues).font(.caption2).foregroundStyle(.red)
              }
            }
          }
          .padding(8)
          .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        Divider()
        Text("Decision record").font(.headline)
        ForEach(Array(model.decisionLines.enumerated()), id: \.offset) { item in
          Text("· " + item.element).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text("Budgets and measurements are for the named machine; they are not claims for other "
          + "hardware or for lazy parsing, which is explicitly not implemented.").font(.caption2)
      }
      .padding(16)
    }
    .frame(minWidth: 820, minHeight: 520)
    .accessibilityLabel("Large-document budget and measured classes")
  }

  private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
