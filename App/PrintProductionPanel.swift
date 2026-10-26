import AppKit
import MacServices
import PDFCore
import PDFEditing
import SwiftUI

/// PRE-07/PRE-08 App surface: prepress review and advanced printing. Preview
/// and verification happen in the core planner/MacServices; this panel only
/// collects options and reports the explicit profile/boundary.
@MainActor
final class PrintProductionPanelModel: ObservableObject {
  enum LayoutChoice: String, CaseIterable, Identifiable {
    case single, nUp, booklet, poster
    var id: String { rawValue }
    var title: String {
      switch self {
      case .single: return "Single page"
      case .nUp: return "N-up"
      case .booklet: return "Booklet"
      case .poster: return "Poster/tiling"
      }
    }
  }

  @Published var layout: LayoutChoice = .single
  @Published var rows = 2
  @Published var columns = 2
  @Published var posterOverlap = 0.0
  @Published var scaleMode = 0  // 0 fit, 1 actual, 2 custom
  @Published var customScale = 1.0
  @Published var margin = 18.0
  @Published var gutter = 12.0
  @Published var includeComments = false
  @Published var mixedPageSizes = false
  @Published var duplex = 0  // 0 simplex, 1 long edge, 2 short edge
  @Published private(set) var status: String?
  @Published private(set) var problem: String?
  @Published private(set) var planSummary: String?
  @Published private(set) var spotInventory: String?
  @Published private(set) var hairlineReport: String?

  private let graphProvider: @MainActor () -> PDFGraph?
  private let sourceProvider: @MainActor () -> Data?

  init(
    graphProvider: @escaping @MainActor () -> PDFGraph?,
    sourceProvider: @escaping @MainActor () -> Data?
  ) {
    self.graphProvider = graphProvider
    self.sourceProvider = sourceProvider
  }

  var options: PDFAdvancedPrintOptions {
    let layoutValue: PDFAdvancedPrintLayout
    switch layout {
    case .single: layoutValue = .single
    case .nUp: layoutValue = .nUp(rows: max(1, rows), columns: max(1, columns))
    case .booklet: layoutValue = .booklet
    case .poster:
      layoutValue = .poster(
        rows: max(1, rows), columns: max(1, columns), overlap: max(0, posterOverlap))
    }
    let scale: PDFPrintScaleMode
    switch scaleMode {
    case 1: scale = .actual
    case 2: scale = .custom(max(0.05, customScale))
    default: scale = .fit
    }
    return PDFAdvancedPrintOptions(
      layout: layoutValue, scale: scale, paperSize: nil,
      margin: max(0, margin), gutter: max(0, gutter),
      includeComments: includeComments, mixedPageSizes: mixedPageSizes,
      duplex: duplex == 1 ? .longEdge : (duplex == 2 ? .shortEdge : .simplex))
  }

  func pageBoxes() -> [[Double]] {
    guard let graph = graphProvider() else { return [] }
    guard let pageIDs = try? PDFPageTree.pageIDs(in: graph) else { return [] }
    return pageIDs.compactMap { pageID in
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let values)? = page[PDFName("MediaBox")]
      else { return nil }
      let numbers = values.compactMap { value -> Double? in
        switch value {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
      guard numbers.count == 4 else { return nil }
      return [0, 0, numbers[2], numbers[3]]
    }
  }

  func pageIDs() -> [PDFObjectID]? {
    guard let graph = graphProvider() else { return nil }
    return try? PDFPageTree.pageIDs(in: graph)
  }

  func refreshPlan() {
    let boxes = pageBoxes()
    guard !boxes.isEmpty else {
      planSummary = "No editable pages are available."
      return
    }
    do {
      let plan = try PDFAdvancedPrintPlanner.plan(pageBoxes: boxes, options: options)
      planSummary = plan.report()
      problem = nil
    } catch {
      planSummary = nil
      problem = error.localizedDescription
    }
  }

  func refreshPrepress() {
    guard let graph = graphProvider(), let pageIDs = pageIDs() else {
      spotInventory = nil
      hairlineReport = nil
      return
    }
    let spots = SpotColorInventory.inventory(graph, pageIDs: pageIDs)
    spotInventory = spots.report()
    do {
      let hairlines = try HairlineChecker.check(graph, pageIDs: pageIDs)
      hairlineReport = hairlines.report()
    } catch {
      hairlineReport = "Hairline check failed: " + error.localizedDescription
    }
    refreshPlan()
  }

  func exportAdvancedPDF(to url: URL) {
    guard let graph = graphProvider(), let pageIDs = pageIDs() else {
      problem = "No editable pages are available."
      return
    }
    do {
      let report = try PDFAdvancedPrintExport.writePDF(
        pageIDs: pageIDs, in: graph, options: options, to: url)
      status = "Wrote " + String(report.outputPageCount) + " page(s) to "
        + url.lastPathComponent + "."
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  func writeFlatteningPreviews(to directory: URL) {
    guard let graph = graphProvider(), let pageIDs = pageIDs() else { return }
    do {
      let report = try PDFPrintPreviewExport.writePNGPreviews(
        pageIDs: pageIDs, in: graph, to: directory)
      status = "Wrote " + String(report.pageCount) + " flattening preview(s)."
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  func exportProductionMarks(to url: URL) {
    guard let graph = graphProvider(), let pageIDs = pageIDs() else { return }
    let inks = spotInkNames()
    do {
      let layout = try PDFProductionMarksExport.writePDF(
        pageIDs: pageIDs, in: graph,
        options: ProductionMarksOptions(
          margin: max(12, margin), jobLabel: "sPDF print job",
          inks: inks.map { ProductionInk(name: $0, isProcess: isProcessInk($0)) }),
        to: url)
      status = "Wrote production marks for " + String(layout.pages.count) + " page(s)."
      problem = nil
    } catch {
      problem = error.localizedDescription
    }
  }

  private func spotInkNames() -> [String] {
    guard let graph = graphProvider(), let pageIDs = pageIDs() else { return [] }
    let report = SpotColorInventory.inventory(graph, pageIDs: pageIDs)
    return report.spotNames
  }

  private func isProcessInk(_ name: String) -> Bool {
    ["Cyan", "Magenta", "Yellow", "Black"].contains(name)
  }

  var auditReport: String { PDFNativePrintAudit.report() }
}

/// PRE-07/PRE-08 panel: options, plan/preview, prepress reports and exports.
struct PrintProductionPanel: View {
  @ObservedObject var model: PrintProductionPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Print Production").font(.headline)
        Text(
          "Advanced layouts are planned and drawn by the owned print pipeline. "
            + "Output is appearance-oriented; no PDF/X conformance or overprint simulation "
            + "is claimed. Comments are drawn from annotation appearances when enabled."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Divider()
        layoutControls
        Divider()
        prepressControls
        Divider()
        if let planSummary = model.planSummary {
          Text("Plan").font(.subheadline.weight(.semibold))
          Text(planSummary).font(.caption.monospaced()).textSelection(.enabled)
        }
        if let spot = model.spotInventory {
          DisclosureGroup("Spot-color inventory") {
            Text(spot).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        if let hairlines = model.hairlineReport {
          DisclosureGroup("Hairline review") {
            Text(hairlines).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        if let status = model.status {
          Text(status).font(.caption).foregroundStyle(.green)
        }
        if let problem = model.problem {
          Text(problem).font(.caption).foregroundStyle(.red)
        }
        exportButtons
        Divider()
        Text(model.auditReport).font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 680, minHeight: 560)
    .onAppear {
      model.refreshPrepress()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Print production")
  }

  private var layoutControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Layout").font(.subheadline.weight(.semibold))
      Picker("Layout", selection: $model.layout) {
        ForEach(PrintProductionPanelModel.LayoutChoice.allCases) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .pickerStyle(.segmented)
      if model.layout == .nUp || model.layout == .poster {
        HStack {
          Stepper("Rows: \(model.rows)", value: $model.rows, in: 1...8)
          Stepper("Columns: \(model.columns)", value: $model.columns, in: 1...8)
        }
      }
      if model.layout == .poster {
        HStack {
          Text("Overlap")
          Slider(value: $model.posterOverlap, in: 0...72, step: 1)
          Text(String(format: "%.0f pt", model.posterOverlap))
            .font(.caption.monospaced())
        }
      }
      Picker("Scale", selection: $model.scaleMode) {
        Text("Fit").tag(0)
        Text("Actual size").tag(1)
        Text("Custom").tag(2)
      }
      .pickerStyle(.segmented)
      if model.scaleMode == 2 {
        HStack {
          Text("Custom scale")
          Slider(value: $model.customScale, in: 0.25...2.5, step: 0.05)
          Text(String(format: "%.2f", model.customScale)).font(.caption.monospaced())
        }
      }
      HStack {
        Stepper("Margin: \(Int(model.margin)) pt", value: $model.margin, in: 0...96, step: 3)
        Stepper("Gutter: \(Int(model.gutter)) pt", value: $model.gutter, in: 0...96, step: 3)
      }
      Toggle("Print comments/annotation appearances", isOn: $model.includeComments)
      Toggle("Preserve mixed page sizes (single-page layout)", isOn: $model.mixedPageSizes)
      Picker("Duplex", selection: $model.duplex) {
        Text("Simplex").tag(0)
        Text("Long edge").tag(1)
        Text("Short edge").tag(2)
      }
      .pickerStyle(.segmented)
      HStack {
        Button("Refresh plan and prepress reports") { model.refreshPrepress() }
      }
    }
  }

  private var prepressControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Prepress review").font(.subheadline.weight(.semibold))
      Text(
        "Spot-color remapping is available as an undoable command in the core "
          + "(SpotColorRemapCommand); this panel reports the plates and hairlines but does "
          + "not silently convert inks or widen strokes."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var exportButtons: some View {
    HStack {
      Button("Export Print-Ready PDF…") { chooseAdvancedPDFDestination() }
      Button("Write Flattening Previews…") { choosePreviewDirectory() }
      Button("Export Production Marks…") { chooseMarksDestination() }
    }
  }

  private func chooseAdvancedPDFDestination() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = "advanced-print.pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportAdvancedPDF(to: url)
  }

  private func choosePreviewDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Write Previews Here"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.writeFlatteningPreviews(to: url)
  }

  private func chooseMarksDestination() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = "production-marks.pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.exportProductionMarks(to: url)
  }
}

extension SPDFDocument {
  var canShowPrintProductionPanel: Bool {
    viewer != nil || editSession.currentGraph != nil
  }

  @MainActor
  func printProductionPanelModel() -> PrintProductionPanelModel {
    PrintProductionPanelModel(
      graphProvider: { [weak self] in
        guard let self else { return nil }
        if let graph = self.editSession.currentGraph { return graph }
        guard let source = self.sourceStore.snapshot()?.data else { return nil }
        return (try? PDFParser.parse(
          source, limits: SPDFDocumentResourcePolicy.parsingLimits))?.graph
      },
      sourceProvider: { [weak self] in self?.sourceStore.snapshot()?.data })
  }

  /// Hook: call from a Tools > Print Production menu item.
  @MainActor
  func presentPrintProductionPanel() {
    let model = printProductionPanelModel()
    model.refreshPrepress()
    let hosting = NSHostingView(rootView: PrintProductionPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
    let alert = NSAlert()
    alert.messageText = "Print Production"
    alert.alertStyle = .informational
    alert.informativeText =
      "Booklet, poster/tiling, N-up, scaling, comments, mixed sizes and duplex ordering. "
        + "Export is appearance-oriented and verification is against independent renders; "
        + "no PDF/X or overprint-simulation claim."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }
}
