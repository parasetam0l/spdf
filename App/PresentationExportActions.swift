import AppKit
import DocumentSession
import Foundation
import MacServices
import PDFCore
import PDFEditing
import UniformTypeIdentifiers

/// EXP-03: user-reachable PowerPoint export. The document is reconstructed with
/// the existing page analysis (editable text/images/shapes where reliably
/// recovered, a clearly labelled raster fallback for anything else), packaged
/// as a deterministic PPTX, and paired with the truthful editability report
/// (Markdown and JSON) written next to the presentation.
extension SPDFDocument {
  /// EXP-03: the presentation export needs a parsed document with at least one page.
  var canExportPresentation: Bool {
    editSession.currentGraph != nil && !editSession.pageIDs.isEmpty
  }

  /// What an export wrote, for the completion alert and for diagnostics.
  struct PresentationExportSummary: Sendable, Equatable {
    let slideCount: Int
    let editableTextCount: Int
    let editableImageCount: Int
    let editableShapeCount: Int
    let rasterFallbackSlideCount: Int
    let byteCount: Int
    let reportMarkdownURL: URL
    let reportJSONURL: URL
  }

  /// EXP-03: File → Export → PowerPoint Presentation (PPTX)…, including the
  /// reconstruction boundary explanation and the save panel.
  func exportPresentation() {
    guard finishPendingEdits() else { return }
    guard canExportPresentation else {
      let alert = NSAlert()
      alert.messageText = "Nothing to Export"
      alert.informativeText =
        "Open a PDF document with at least one page before exporting a presentation."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }
    let alert = NSAlert()
    alert.messageText = "Export PowerPoint Presentation"
    alert.informativeText =
      "The pages are reconstructed as a PowerPoint presentation. Reliably recovered text, "
      + "images and shapes become editable slide objects; any page that cannot be "
      + "reconstructed becomes a clearly labelled raster image that is not editable. "
      + "The editability report (Markdown and JSON) is saved next to the presentation, "
      + "and the source PDF is not modified. Layout, line breaks and font substitution may "
      + "differ in a presentation application; this export does not claim a pixel-exact "
      + "round trip."
    alert.addButton(withTitle: "Export…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let panel = NSSavePanel()
    if let type = UTType(filenameExtension: "pptx") {
      panel.allowedContentTypes = [type]
    }
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    panel.nameFieldStringValue = (base.isEmpty ? "Document" : base) + ".pptx"
    panel.prompt = "Export"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      Task { @MainActor in
        do {
          let summary = try await self.exportPresentation(to: url)
          guard !TerminationCoordinator.shared.isPreparing else { return }
          let alert = NSAlert()
          alert.messageText = "PowerPoint Presentation Exported"
          var details = [
            "\(summary.slideCount) slide\(summary.slideCount == 1 ? "" : "s") written: "
              + "\(summary.editableTextCount) editable text box(es), "
              + "\(summary.editableImageCount) editable picture(s), "
              + "\(summary.editableShapeCount) editable shape(s)."
          ]
          if summary.rasterFallbackSlideCount > 0 {
            details.append(
              "\(summary.rasterFallbackSlideCount) page(s) are labelled raster fallbacks and "
                + "are not editable; the report lists them.")
          }
          details.append("Report: \(summary.reportMarkdownURL.lastPathComponent)")
          alert.informativeText = details.joined(separator: "\n\n")
          alert.addButton(withTitle: "OK")
          alert.runModal()
        } catch {
          self.presentError(error)
        }
      }
    }
  }

  /// EXP-03: testable path behind the panel. Writes the PPTX and its report
  /// sidecars through the derivative gate; no App file is edited by this task.
  @discardableResult
  func exportPresentation(to url: URL) async throws -> PresentationExportSummary {
    guard finishPendingEdits() else {
      throw PDFError(.unsupported, "Finish the current edit before exporting a presentation")
    }
    guard let graph = editSession.currentGraph, !editSession.pageIDs.isEmpty else {
      throw PDFError(.malformed, "There is no document to export")
    }
    try DerivativeOutputPolicy.validateDestination(url, source: fileURL)
    let pageIDs = editSession.pageIDs
    let title = fileURL?.deletingPathExtension().lastPathComponent
      ?? "Reconstructed presentation"
    let job = jobCenter.start(title: "Exporting PowerPoint", total: 1)
    withUnsafeCurrentTask { task in jobCenter.attach(id: job) { task?.cancel() } }
    defer { jobCenter.finish(id: job) }

    let document = try await Task.detached(priority: .userInitiated) {
      try PresentationExportService.reconstruct(
        pageIDs: pageIDs, in: graph, title: title,
        options: PresentationExportOptions())
    }.value
    try Task.checkCancellation()
    let data = try PPTXExport.package(document: document)
    try Task.checkCancellation()
    try data.write(to: url, options: .atomic)
    jobCenter.update(id: job, completed: 1)
    let reportURLs = try PresentationExportActions.writeReportSidecars(
      report: document.report, nextTo: url)
    return PresentationExportSummary(
      slideCount: document.slides.count,
      editableTextCount: document.report.slides.reduce(0) { $0 + $1.editableTextCount },
      editableImageCount: document.report.slides.reduce(0) { $0 + $1.editableImageCount },
      editableShapeCount: document.report.slides.reduce(0) { $0 + $1.editableShapeCount },
      rasterFallbackSlideCount: document.report.rasterFallbackSlideCount,
      byteCount: data.count, reportMarkdownURL: reportURLs.markdown,
      reportJSONURL: reportURLs.json)
  }
}

/// EXP-03: deterministic report sidecar names next to the exported package.
enum PresentationExportActions {
  struct ReportSidecarURLs: Sendable, Equatable {
    let markdown: URL
    let json: URL
  }

  static func sidecarURLs(nextTo presentation: URL) -> ReportSidecarURLs {
    let base = presentation.deletingPathExtension()
    return ReportSidecarURLs(
      markdown: base.appendingPathExtension("editability.md"),
      json: base.appendingPathExtension("editability.json"))
  }

  static func writeReportSidecars(
    report: PresentationEditabilityReport, nextTo presentation: URL
  ) throws -> ReportSidecarURLs {
    let urls = sidecarURLs(nextTo: presentation)
    try Data(report.markdown().utf8).write(to: urls.markdown, options: .atomic)
    try report.jsonData().write(to: urls.json, options: .atomic)
    return urls
  }
}
