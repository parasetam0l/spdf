import AppKit
import DocumentSession
import PDFCore
import PDFEditing
import SwiftUI

// PRE-09: Tools > Print Production > Quality Optimization… window. Plans and
// measures quality/size presets on a copy, shows the per-resource before/after
// report and writes a verified optimized copy to a NEW file. The open document is
// never modified. ApplicationDelegate owns the menu hook (reported to the Lead).

private enum QualityOptimizationAssociationKeys {
  nonisolated(unsafe) static var controller: UInt8 = 0
}

@MainActor
final class QualityOptimizationModel: ObservableObject {
  weak var document: SPDFDocument?
  @Published var preset: OptimizationQualityPreset = .web
  @Published var reportText = ""
  @Published var status = "Choose a preset and plan the optimization."
  private var plan: QualityOptimizationPlan?
  private var optimizedData: Data?

  func planOptimization() {
    guard let document, let graph = document.editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else {
      status = "Open a document first."
      return
    }
    do {
      let planned = try QualityOptimizer.plan(
        graph, pageIDs: pageIDs, preset: preset)
      plan = planned
      optimizedData = nil
      reportText = planned.summary
      status = planned.isUsable
        ? "Plan is usable; export writes a measured copy to a new file."
        : "Plan refused: retained content would be invalidated or an image is unsupported."
    } catch {
      plan = nil
      reportText = ""
      status = "Planning failed: " + error.localizedDescription
    }
  }

  func exportOptimizedCopy() {
    guard let document, let plan else { return }
    guard plan.isUsable else {
      status = "The plan is not usable; nothing will be written."
      return
    }
    guard let graph = document.editSession.currentGraph,
      let pageIDs = try? PDFPageTree.pageIDs(in: graph)
    else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue =
      (document.fileURL?.deletingPathExtension().lastPathComponent ?? "document")
      + " optimized.pdf"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    if let source = document.fileURL, destination.standardizedFileURL == source.standardizedFileURL {
      status = "Choose a new file: the source must not be overwritten."
      return
    }
    do {
      let applied = try QualityOptimizer.apply(plan, to: graph, pageIDs: pageIDs)
      let data = try PDFWriter.write(applied.graph)
      let pageCount = pageIDs.count
      try VerifiedFileWriter.write(data, to: destination) { bytes in
        let parsed = try PDFParser.parse(bytes)
        guard parsed.graph.objects.count > 0, parsed.pageIDs.count == pageCount else {
          throw PDFError(.malformed, "Optimized copy failed page-count verification")
        }
      }
      optimizedData = data
      reportText = applied.report.summary
      status = "Wrote a verified optimized copy; the source was not modified."
    } catch {
      status = "Export failed: " + error.localizedDescription
    }
  }
}

struct QualityOptimizationPanel: View {
  @ObservedObject var model: QualityOptimizationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Quality-Aware Optimization").font(.headline)
      Text(
        "Presets trade size for image resolution. The default is lossless; lossy "
          + "quantization is explicit in the smallest preset. Forms, OCR layers, tags, "
          + "masks and fonts are preserved or the operation refuses."
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Picker("Preset", selection: $model.preset) {
          ForEach(OptimizationQualityPreset.allCases, id: \.rawValue) { preset in
            Text(preset.title).tag(preset)
          }
        }.frame(width: 260)
        Button("Plan") { model.planOptimization() }
        Button("Export Optimized Copy…") { model.exportOptimizedCopy() }
      }
      Divider()
      ScrollView {
        Text(model.reportText.isEmpty ? "No plan yet." : model.reportText)
          .font(.caption.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(model.status).font(.caption).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(minWidth: 680, minHeight: 480)
    .onAppear { model.planOptimization() }
  }
}

@MainActor
final class QualityOptimizationWindowController: NSWindowController {
  convenience init(model: QualityOptimizationModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Quality Optimization"
    window.contentView = NSHostingView(rootView: QualityOptimizationPanel(model: model))
    self.init(window: window)
  }
}

extension SPDFDocument {
  /// Tools > Print Production > Quality Optimization…: plan/measure presets and
  /// export a verified optimized copy. The open document is read-only here.
  func showQualityOptimization() {
    if let existing = objc_getAssociatedObject(
      self, &QualityOptimizationAssociationKeys.controller)
      as? QualityOptimizationWindowController
    {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let model = QualityOptimizationModel()
    model.document = self
    let controller = QualityOptimizationWindowController(model: model)
    objc_setAssociatedObject(
      self, &QualityOptimizationAssociationKeys.controller, controller,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    controller.showWindow(nil)
  }
}

