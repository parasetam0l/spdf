import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// PRE-06: separation and overprint preview panel. Read-only; exposes the
// decision-first disclosure, process/spot plate coverage, overprint counts and
// the declared approximation boundary. Third-party print agreement is not
// claimed because no reference renderer is available here.

@MainActor
final class SeparationPreviewModel: ObservableObject {
  @Published private(set) var report: SeparationPreviewReport?
  @Published private(set) var statusText: String?
  @Published private(set) var errorText: String?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  var pages: [SeparationPagePreview] { report?.pages ?? [] }
  var canFocusFirstPage: Bool { !pages.isEmpty }

  func refresh() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorText = "This document is not editable by the owned core."
      report = nil
      return
    }
    report = SeparationOverprintPreview.analyze(
      graph: graph, pageIDs: document.editSession.pageIDs)
    errorText = nil
    statusText = "Previewed \(pages.count) page(s); public Apple APIs cannot supply plates, "
      + "so this is the declared owned analyzer."
  }

  func focus(pageIndex: Int) {
    document?.viewer?.go(to: pageIndex + 1)
  }

  func exportReport() {
    guard let report else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    let base = document?.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-separation-overprint-preview.txt"
    let text = report.report()
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        self?.statusText = "Separation/overprint report exported."
      } catch {
        self?.errorText = error.localizedDescription
      }
    }
  }
}

@MainActor
final class SeparationPreviewWindowController: NSWindowController {
  let model: SeparationPreviewModel

  init(document: SPDFDocument) {
    let model = SeparationPreviewModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Separation & Overprint Preview"
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: SeparationPreviewView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for separation preview")
  }

  func refresh() { model.refresh() }
}

struct SeparationPreviewView: View {
  @ObservedObject var model: SeparationPreviewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Separation & Overprint Preview").font(.title3.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      if let report = model.report {
        disclosure(report)
        if let status = model.statusText {
          Text(status).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.errorText {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(report.pages) { page in
              pageCard(page)
            }
            if report.pages.isEmpty {
              Text("No pages to preview.").foregroundStyle(.secondary)
            }
          }
        }
      } else if let error = model.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
      HStack {
        Button("Refresh") { model.refresh() }
        Button("First Page") {
          model.focus(pageIndex: 0)
        }
        .disabled(!model.canFocusFirstPage)
        Spacer()
        Button("Export Report…") { model.exportReport() }
          .disabled(model.report == nil)
      }
    }
    .padding(14)
    .frame(minWidth: 820, minHeight: 560)
    .accessibilityLabel("Separation and overprint preview")
  }

  private func disclosure(_ report: SeparationPreviewReport) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(report.claimedProfile)
        .font(.headline)
      ForEach(Array(report.publicAPIDecision.reasons.enumerated()), id: \.offset) {
        _, reason in
        Text("• " + reason)
          .font(.caption2)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text("Independent print reference: " + report.independentReferenceStatus)
        .font(.caption2)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      Text("Claimed accuracy: " + report.claimedAccuracy)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }

  private func pageCard(_ page: SeparationPagePreview) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text("Page \(page.pageIndex + 1)").font(.headline)
        Spacer()
        Button("Go to Page") { model.focus(pageIndex: page.pageIndex) }
          .buttonStyle(.link)
          .accessibilityLabel("Go to page \(page.pageIndex + 1)")
      }
      if page.plates.isEmpty {
        Text("No process/spot ink was found.").font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(page.plates, id: \.plate) { plate in
          HStack(spacing: 8) {
            Text(plate.plate.displayName).font(.caption)
            Text(String(format: "%.3f%%", plate.percent))
              .font(.caption.monospaced())
            Text("(\(plate.operationCount) op)")
              .font(.caption2)
              .foregroundStyle(.secondary)
            Spacer()
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            plate.plate.displayName + ", " + String(format: "%.3f", plate.percent)
              + " percent coverage")
        }
      }
      Text(
        "Overprint operations: \(page.overprintOperations); knockouts: "
          + "\(page.knockoutOperations).")
        .font(.caption2)
        .foregroundStyle(.secondary)
      ForEach(Array(page.overprintFindings.enumerated()), id: \.offset) { _, finding in
        Text("Overprint overlap: " + String(format: "%.3f%%", finding.overprintAreaFraction * 100))
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      ForEach(Array(page.ignoredNotes.enumerated()), id: \.offset) { _, note in
        Text("Note: " + note).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
  }
}

extension SPDFDocument {
  var canShowSeparationPreview: Bool { editSession.currentGraph != nil }

  func presentSeparationPreview() {
    if let controller = windowControllers.compactMap({
      $0 as? SeparationPreviewWindowController
    }).first {
      controller.refresh()
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SeparationPreviewWindowController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}
