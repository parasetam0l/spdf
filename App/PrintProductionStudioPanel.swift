import AppKit
import DocumentSession
import PDFCore
import PDFEditing
import SwiftUI

// PRE-03/PRE-04: Tools > Print Production > Preflight and PDF/X Export… window.
// Read-only on the open document: preflight runs on a copy, fixups are staged and
// previewed, exports are written to a NEW verified file. ApplicationDelegate owns
// the menu hook (reported to the Lead); SPDFDocument is not edited.

private enum PrintProductionAssociationKeys {
  nonisolated(unsafe) static var controller: UInt8 = 0
}

@MainActor
final class PrintProductionStudioModel: ObservableObject {
  weak var document: SPDFDocument?
  @Published var profile: PDFXProfile = .x4
  @Published var ruleSet: PreflightRuleSet = .printDelivery
  @Published var findingsText = ""
  @Published var fixupText = ""
  @Published var status = "Run preflight to inspect the document."
  @Published var reportText = ""
  private var session: PreflightFixupSession?

  func runPreflight() {
    guard let graph = document?.editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else {
      status = "Open a document first."
      return
    }
    var session = PreflightFixupSession(
      graph: graph, pageIDs: pageIDs, ruleSet: ruleSet, profile: profile)
    session.rerun()
    self.session = session
    findingsText = session.report.text()
    fixupText = ""
    status = session.report.passed
      ? "Preflight has no errors; warnings remain visible."
      : "Preflight found errors; inspect the staged fixups."
  }

  func preview(_ fixup: PreflightFixup) {
    guard var session else { return }
    fixupText = session.preview(fixup).summary
    self.session = session
  }

  func apply(_ fixup: PreflightFixup) {
    guard var session else { return }
    do {
      let result = try session.apply(fixup)
      self.session = session
      findingsText = session.report.text()
      fixupText = result.summary + "\n" + result.preview.summary
      status = "Staged \(fixup.title) on a copy; the document was not modified."
    } catch {
      status = "Fixup failed: " + error.localizedDescription
    }
  }

  func exportPDFX() {
    guard let session, let document else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue =
      (document.fileURL?.deletingPathExtension().lastPathComponent ?? "document")
      + " " + profile.identification.replacingOccurrences(of: "/", with: "-") + ".pdf"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    if let source = document.fileURL, destination.standardizedFileURL == source.standardizedFileURL {
      status = "Choose a new file: the source must not be overwritten."
      return
    }
    do {
      let pageIDs = try PDFPageTree.pageIDs(in: session.graph)
      let planned = PDFXExporter.plan(
        session.graph, pageIDs: pageIDs, profile: profile)
      guard planned.isExportable else {
        status = "PDF/X refused: " + planned.refusals.joined(separator: "; ")
        return
      }
      let staged = try PDFXExporter.stage(plan: planned, graph: session.graph, pageIDs: pageIDs)
      let data = try PDFWriter.write(staged.graph)
      let validation = PDFXExporter.verify(data: data, profile: profile)
      guard validation.passed else {
        status = "PDF/X byte validation failed: " + validation.issues.joined(separator: "; ")
        return
      }
      try VerifiedFileWriter.write(data, to: destination) { bytes in
        let written = PDFXExporter.verify(data: bytes, profile: self.profile)
        guard written.passed else {
          throw PDFError(.malformed, written.issues.joined(separator: "; "))
        }
      }
      status = "Wrote a verified \(profile.identification) declared-subset copy."
      reportText = session.exportReport() + "\n\n" + validation.summary
    } catch {
      status = "Export failed: " + error.localizedDescription
    }
  }

  func copyReport() {
    guard let session else { return }
    reportText = session.exportReport()
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(reportText, forType: .string)
    status = "Preflight report copied to the pasteboard."
  }
}

struct PrintProductionStudioPanel: View {
  @ObservedObject var model: PrintProductionStudioModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Preflight and PDF/X Export").font(.headline)
      Text(
        "Declared profile subsets: required page boxes, embedded fonts, output intent, "
          + "identification XMP and permitted content rules. Color-managed conversion "
          + "is not claimed; fixups are staged on copies and the source is never modified."
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Picker("Profile", selection: $model.profile) {
          ForEach(PDFXProfile.allCases, id: \.rawValue) { profile in
            Text(profile.identification).tag(profile)
          }
        }.frame(width: 240)
        Picker(
          "Rule set", selection: Binding(
            get: { model.ruleSet.name },
            set: { name in
              switch name {
              case PreflightRuleSet.pdfx4.name: model.ruleSet = .pdfx4
              case PreflightRuleSet.pdfx1a.name: model.ruleSet = .pdfx1a
              default: model.ruleSet = .printDelivery
              }
            })
        ) {
          Text(PreflightRuleSet.printDelivery.name)
            .tag(PreflightRuleSet.printDelivery.name)
          Text(PreflightRuleSet.pdfx4.name).tag(PreflightRuleSet.pdfx4.name)
          Text(PreflightRuleSet.pdfx1a.name).tag(PreflightRuleSet.pdfx1a.name)
        }.frame(width: 240)
        Button("Run Preflight") { model.runPreflight() }
      }
      HStack {
        Text("Staged fixups:").font(.caption)
        ForEach(
          [PreflightFixup.addTrimBoxes, .addOutputIntent, .addPDFXIdentification,
           .flattenAnnotations, .flattenFormFields], id: \.rawValue
        ) { fixup in
          Button(fixup.title) { model.apply(fixup) }
            .controlSize(.small)
        }
      }
      Divider()
      ScrollView {
        Text(model.findingsText.isEmpty ? "No preflight run yet." : model.findingsText)
          .font(.caption.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 180)
      if !model.fixupText.isEmpty {
        Text(model.fixupText).font(.caption2.monospaced()).textSelection(.enabled)
      }
      HStack {
        Button("Export PDF/X…") { model.exportPDFX() }
        Button("Copy Report") { model.copyReport() }
      }
      if !model.reportText.isEmpty {
        ScrollView {
          Text(model.reportText).font(.caption2.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 140)
      }
      Text(model.status).font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(minWidth: 720, minHeight: 620)
    .onAppear { model.runPreflight() }
  }
}

@MainActor
final class PrintProductionStudioWindowController: NSWindowController {
  convenience init(model: PrintProductionStudioModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Preflight and PDF/X Export"
    window.contentView = NSHostingView(rootView: PrintProductionStudioPanel(model: model))
    self.init(window: window)
  }
}

extension SPDFDocument {
  /// Tools > Print Production > Preflight and PDF/X Export…: read-only preflight,
  /// staged fixups and verified PDF/X derivative export.
  func showPrintProductionStudio() {
    if let existing = objc_getAssociatedObject(
      self, &PrintProductionAssociationKeys.controller)
      as? PrintProductionStudioWindowController
    {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let model = PrintProductionStudioModel()
    model.document = self
    let controller = PrintProductionStudioWindowController(model: model)
    objc_setAssociatedObject(
      self, &PrintProductionAssociationKeys.controller, controller,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    controller.showWindow(nil)
  }
}

