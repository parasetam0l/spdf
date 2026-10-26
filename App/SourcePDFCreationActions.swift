import AppKit
import PDFCore
import PDFEditing
import SwiftUI

/// EXP-04/EXP-05: approved creation-route panel model. Handoffs are
/// user-directed: the app opens the source in a local application (or the
/// user's browser) and then verifies the produced PDF; nothing is uploaded and
/// no embedded browser/Office engine runs.
@MainActor
final class SourcePDFCreationModel: ObservableObject {
  @Published var kind: SourceDocumentKind = .docx
  @Published private(set) var sourceURL: URL?
  @Published private(set) var verification: SourcePDFCreationVerification?
  @Published private(set) var boundedPreview: Data?
  @Published private(set) var createdPDF: Data?
  @Published private(set) var message: String?

  var decision: SourcePDFCreationDecision { SourcePDFCreationPolicy.decision(for: kind) }
  var decisions: [SourcePDFCreationDecision] { SourcePDFCreationPolicy.decisions }
  var reportText: String { verification?.plainText ?? "No produced PDF verified yet." }
  var disclosure: String { SourcePDFCreationPolicy.boundaryDisclosure }

  func chooseSource() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message =
      "Choose a local source file. Office/RTF files are handed to a locally installed "
      + "application; HTML is printed from your browser. Nothing is uploaded."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    sourceURL = url
    if let detected = SourcePDFCreationPolicy.decision(forFileURL: url) {
      kind = detected.kind
      message = nil
    } else {
      message = "No approved creation route exists for .\(url.pathExtension); choose "
        + "DOCX/XLSX/PPTX/RTF/HTML/TXT."
    }
  }

  /// User-directed handoff step: open the source in the chosen local app.
  func openSourceLocally() {
    guard let sourceURL else {
      message = "Choose a source file first."
      return
    }
    guard decision.route != .boundedSwiftImport else {
      message = "Plain text uses the bounded Swift import (Create Text PDF)."
      return
    }
    let opened = NSWorkspace.shared.open(sourceURL)
    message = opened
      ? "Opened locally. Follow the handoff steps on this panel, save the PDF, then verify it."
      : "macOS could not open the file; choose another locally installed application."
  }

  func createBoundedPlainText() {
    guard kind == .plainText, let sourceURL else {
      message = "Choose a plain-text file to use the bounded import."
      return
    }
    do {
      let text = try String(contentsOf: sourceURL, encoding: .utf8)
      createdPDF = try SourcePDFBoundedCreation.make(text: text)
      message = "Plain-text PDF created with sPDF pagination. Save it, then verify it."
    } catch {
      message = "Could not create the text PDF: \(error.localizedDescription)"
    }
  }

  func saveCreatedPDF() {
    guard let createdPDF else {
      createBoundedPlainText()
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue =
      (sourceURL?.deletingPathExtension().lastPathComponent ?? "Created") + ".pdf"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try createdPDF.write(to: url, options: .atomic)
      message = "Saved \(url.lastPathComponent)."
    } catch {
      message = error.localizedDescription
    }
  }

  func verifyProducedPDF() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose the PDF produced by the handoff (or by sPDF) to verify it."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let expectations = SourcePDFCreationExpectations(
        requiresTextContent: true,
        requiresLinks: decision.route == .browserPrintHandoff,
        requiresStructureTags: false, requiresEmbeddedFonts: false)
      guard let report = SourcePDFCreationVerifier.verify(
        data, for: kind, expectations: expectations)
      else {
        message = "The selected file could not be parsed as a PDF."
        return
      }
      verification = report
      message = report.isSatisfied
        ? "Machine checks passed; check page layout, fonts and links visually."
        : "Some expected features were not found; review the report before relying on it."
    } catch {
      message = error.localizedDescription
    }
  }
}

extension SPDFDocument {
  /// Hook: call from the "Create PDF from Source Document…" menu item.
  @MainActor
  func sourcePDFCreationModel() -> SourcePDFCreationModel {
    SourcePDFCreationModel()
  }

  var canShowSourcePDFCreationPanel: Bool { true }

  /// Hook: File > Create PDF from Source Document…
  @MainActor
  func showSourcePDFCreationPanel() {
    let model = sourcePDFCreationModel()
    let hosting = NSHostingView(rootView: SourcePDFCreationPanel(model: model))
    hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
    let alert = NSAlert()
    alert.messageText = "Create PDF from Source Document"
    alert.alertStyle = .informational
    alert.informativeText =
      "Approved local routes only: bounded plain-text import, local native-application "
      + "handoff for Office/RTF, or a browser print handoff for HTML. No upload, no "
      + "embedded web view, no unapproved converter."
    alert.accessoryView = hosting
    alert.addButton(withTitle: "Done")
    alert.runModal()
  }
}
