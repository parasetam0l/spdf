import AppKit
import DocumentSession
import Foundation
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

/// SPC-06/SPC-07: the compatibility-decision panel. It reports the declared
/// legacy-JavaScript and XFA decisions for the open document and offers explicit
/// sanitized copies; it never executes scripts or XFA and never mutates the
/// open document. The Lead wires the hook methods into the search/inspect menus.
@MainActor
enum CompatibilityDecisionsFlow {
  static func present(for document: SPDFDocument) {
    guard let data = sourceData(of: document) else {
      presentAlert(
        "Compatibility Decisions Unavailable",
        "Open or save a document before inspecting its compatibility decisions.")
      return
    }
    let parsed: ParsedPDF
    do {
      parsed = try PDFParser.parse(
        data, limits: SPDFDocumentResourcePolicy.parsingLimits)
    } catch {
      presentAlert(
        "Compatibility Decisions Unavailable",
        "The document could not be parsed: \(error.localizedDescription)")
      return
    }
    let pageIDs = parsed.pageIDs
    let report = LegacyScriptCompatibility.report(in: parsed.graph, pageIDs: pageIDs)
    let xfa = XFACompatibility.profile(in: parsed.graph, pageIDs: pageIDs)
    while true {
      let hosting = NSHostingView(
        rootView: CompatibilityDecisionsView(report: report, xfa: xfa))
      hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
      let alert = NSAlert()
      alert.messageText = "Legacy Compatibility Decisions"
      alert.alertStyle = .informational
      alert.informativeText =
        "\(report.profileIdentifier) / \(XFACompatibilityProfile.profileIdentifier)"
      alert.accessoryView = hosting
      alert.addButton(withTitle: "Remove JavaScript Actions (Copy)...")
      alert.addButton(withTitle: "Flatten Form (Copy)...")
      alert.addButton(withTitle: "Done")
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        guard report.removalAvailable else {
          presentAlert(
            "Nothing to Remove",
            "No JavaScript actions are present in this document.")
          continue
        }
        removeJavaScriptActions(from: parsed, document: document)
      case .alertSecondButtonReturn:
        guard xfa.flatteningAvailable else {
          presentAlert(
            "Flatten Unavailable",
            "No AcroForm fallback fields are available to flatten. XFA-only forms are "
              + "preserved but not rendered or filled.")
          continue
        }
        flattenForm(from: parsed, document: document)
      default:
        return
      }
    }
  }

  private static func sourceData(of document: SPDFDocument) -> Data? {
    if let snapshot = document.sourceStore.snapshot() { return snapshot.data }
    if let graph = document.editSession.currentGraph,
      let data = try? PDFWriter.write(graph)
    {
      return data
    }
    return nil
  }

  private static func removeJavaScriptActions(
    from parsed: ParsedPDF, document: SPDFDocument
  ) {
    let command = RemoveJavaScriptActionsCommand()
    do {
      let cleaned = try command.apply(to: parsed.graph)
      guard let destination = chooseDestination(
        for: document, suffix: "-no-js", title: "Save Copy Without JavaScript Actions")
      else { return }
      let output = try PDFWriter.write(cleaned)
      try VerifiedFileWriter.write(output, to: destination) { written in
        let verification = try PDFParser.parse(
          written, limits: SPDFDocumentResourcePolicy.parsingLimits)
        let inventory = LegacyScriptCompatibility.inventory(
          in: verification.graph, pageIDs: verification.pageIDs)
        guard !inventory.hasScripts else {
          throw PDFError(.malformed, "The written copy still contains JavaScript actions")
        }
      }
      presentAlert(
        "JavaScript Actions Removed",
        "Saved \(destination.lastPathComponent) without document JavaScript actions. "
          + "Non-JavaScript actions were preserved, and the open document is unchanged. "
          + "The written copy is a full rewrite, so removed scripts are not recoverable "
          + "from earlier revisions of the output.")
    } catch {
      presentError("The JavaScript-free copy could not be written", error)
    }
  }

  private static func flattenForm(from parsed: ParsedPDF, document: SPDFDocument) {
    let command = FlattenFormCommand()
    do {
      let flattened = try command.apply(to: parsed.graph)
      guard let destination = chooseDestination(
        for: document, suffix: "-flat", title: "Save Flattened Static Copy")
      else { return }
      let output = try PDFWriter.write(flattened)
      try VerifiedFileWriter.write(output, to: destination) { written in
        let verification = try PDFParser.parse(
          written, limits: SPDFDocumentResourcePolicy.parsingLimits)
        let profile = XFACompatibility.profile(
          in: verification.graph, pageIDs: verification.pageIDs)
        guard profile.acroFormFieldCount == 0 else {
          throw PDFError(.malformed, "The written copy still contains form fields")
        }
      }
      presentAlert(
        "Flattened Static Copy Written",
        "Saved \(destination.lastPathComponent). The AcroForm fallback widgets are now "
          + "page content and the form is no longer interactive; the original file with "
          + "its XFA data is retained unchanged.")
    } catch {
      presentError("The flattened copy could not be written", error)
    }
  }

  private static func chooseDestination(
    for document: SPDFDocument, suffix: String, title: String
  ) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    let base = document.fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + suffix + ".pdf"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private static func presentAlert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private static func presentError(_ title: String, _ error: Error) {
    presentAlert(title, error.localizedDescription)
  }
}

// MARK: - Views

struct CompatibilityDecisionsView: View {
  let report: LegacyScriptCompatibilityReport
  let xfa: XFACompatibilityProfile

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("Legacy JavaScript").font(.headline)
        Text(report.summary).font(.caption).foregroundStyle(.secondary)
        Text("Profile: \(report.profileIdentifier)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("Actions inventoried: \(report.inventory.actions.count) "
          + "(\(report.inventory.javascriptActions.count) JavaScript)")
          .font(.caption2)
        if !report.inventory.controlledOperations.isEmpty {
          Text("Controlled operations: "
            + report.inventory.controlledOperations.map(\.title).joined(separator: ", "))
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        if !report.inventory.scriptedFieldNames.isEmpty {
          Text("Scripted fields: "
            + report.inventory.scriptedFieldNames.joined(separator: ", "))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        ForEach(Array(report.inventory.actions.enumerated()), id: \.offset) { _, action in
          HStack(alignment: .top, spacing: 6) {
            Text(action.location.title).font(.caption2).frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
              Text("\(action.kind) - \(action.trigger.title)")
                .font(.caption2)
              if !action.operations.isEmpty {
                Text(action.operations.map(\.title).joined(separator: ", "))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        Text("Declared event equivalents").font(.caption.weight(.medium)).padding(.top, 4)
        ForEach(report.eventDecisions) { decision in
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: decision.supported
              ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundStyle(decision.supported ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text("\(decision.trigger.title): \(decision.declarativeEquivalent)")
                .font(.caption2)
              Text(decision.reason).font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        Divider()
        Text("XFA").font(.headline)
        Text(xfa.summary).font(.caption).foregroundStyle(.secondary)
        Text("Profile: \(XFACompatibilityProfile.profileIdentifier)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text("Kind: \(xfa.kind.title) - packets: \(xfa.packetCount) - bytes: "
          + "\(xfa.xfaByteCount) - AcroForm fallback fields: \(xfa.acroFormFieldCount)")
          .font(.caption2)
        Text("Rendering: \(xfa.renderDecision)").font(.caption2)
        Text("Filling: \(xfa.fillDecision)").font(.caption2)
        Text("Authoring: \(xfa.authoringDecision)").font(.caption2)
        Text("Flattening: \(xfa.flatteningDecision)").font(.caption2)
        Text("Disclosures").font(.caption.weight(.medium)).padding(.top, 4)
        ForEach(Array((report.disclosures + xfa.disclosures).enumerated()), id: \.offset) {
          _, disclosure in
          Text("- " + disclosure).font(.caption2).foregroundStyle(.secondary)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 660, minHeight: 460)
  }
}

// MARK: - SPDFDocument hooks (no stored state)

extension SPDFDocument {
  /// Hook: Inspect > Legacy Compatibility Decisions....
  func presentCompatibilityDecisions() {
    CompatibilityDecisionsFlow.present(for: self)
  }

  /// Hook: SPC-06 focused entry point (same report and sanitized copy offer).
  func presentLegacyScriptCompatibility() {
    CompatibilityDecisionsFlow.present(for: self)
  }

  /// Hook: SPC-07 focused entry point (same report and flatten action).
  func presentXFACompatibility() {
    CompatibilityDecisionsFlow.present(for: self)
  }
}
