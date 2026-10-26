import AppKit
import PDFCore
import PDFEditing
import SwiftUI

// FRM-08: Form > Qualify Lifecycle… route. Read-only: runs the lifecycle
// coverage matrix on copies of the current graph and shows the agreement report.
// The signing combinations need a signing hook, which this read-only panel does
// not supply; they are reported as not exercised rather than silently passing.
// ApplicationDelegate owns the menu hook (reported to the Lead).

private enum FormLifecycleCoverageAssociationKeys {
  nonisolated(unsafe) static var controller: UInt8 = 0
}

@MainActor
final class FormLifecycleCoverageModel: ObservableObject {
  weak var document: SPDFDocument?
  @Published var reportText = ""
  @Published var status = "Run the qualification to inspect lifecycle combinations."

  func run() {
    guard let document else {
      status = "Open a form document first."
      return
    }
    guard let graph = document.editSession.currentGraph else {
      status = "There is no document to qualify."
      return
    }
    do {
      let pageIDs = try PDFPageTree.pageIDs(in: graph)
      let report = try FormLifecycleCoverage.run(in: graph, pageIDs: pageIDs)
      var lines = [report.summary, ""]
      for finding in report.findings {
        lines.append("[\(finding.verdict.rawValue)] \(finding.combination)")
        for note in finding.notes { lines.append("    " + note) }
      }
      if !report.signatureNotes.isEmpty {
        lines.append("")
        lines.append("Signature constraints:")
        for note in report.signatureNotes { lines.append("    " + note) }
      }
      lines.append("")
      lines.append("Tab order: " + report.tabOrder.joined(separator: " -> "))
      reportText = lines.joined(separator: "\n")
      status = report.passed
        ? "All exercised combinations agree. The document was not modified."
        : "Some lifecycle combinations disagree; see the report."
    } catch {
      reportText = ""
      status = "Qualification failed: " + error.localizedDescription
    }
  }
}

struct FormLifecycleCoveragePanel: View {
  @ObservedObject var model: FormLifecycleCoverageModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Form Lifecycle Qualification").font(.headline)
      Text(
        "Qualifies page duplication/deletion with fields, appearance and tab-order "
          + "agreement, and signing constraints. Read-only: it runs on copies of the "
          + "document and never changes the open file."
      ).font(.caption).foregroundStyle(.secondary)
      Divider()
      HStack {
        Button("Run Qualification") { model.run() }
        Spacer()
      }
      ScrollView {
        Text(model.reportText)
          .font(.caption.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(model.status).font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(minWidth: 620, minHeight: 560)
    .onAppear { model.run() }
  }
}

@MainActor
final class FormLifecycleCoverageWindowController: NSWindowController {
  convenience init(model: FormLifecycleCoverageModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Form Lifecycle Qualification"
    window.contentView = NSHostingView(rootView: FormLifecycleCoveragePanel(model: model))
    self.init(window: window)
  }
}

extension SPDFDocument {
  func formLifecycleCoverageReport() -> FormLifecycleCoverageReport? {
    guard let graph = editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else { return nil }
    return try? FormLifecycleCoverage.run(in: graph, pageIDs: pageIDs)
  }

  /// Form > Qualify Lifecycle…: read-only lifecycle coverage report.
  func showFormLifecycleCoverage() {
    if let existing = objc_getAssociatedObject(
      self, &FormLifecycleCoverageAssociationKeys.controller)
      as? FormLifecycleCoverageWindowController
    {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let model = FormLifecycleCoverageModel()
    model.document = self
    let controller = FormLifecycleCoverageWindowController(model: model)
    objc_setAssociatedObject(
      self, &FormLifecycleCoverageAssociationKeys.controller, controller,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    controller.showWindow(nil)
  }
}

