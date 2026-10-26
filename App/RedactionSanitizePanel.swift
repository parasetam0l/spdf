import AppKit
import DocumentSession
import Foundation
import PDFCore
import PDFEditing
import SwiftUI

// RED-05: Tools > Security > Sanitize Hidden Data… route. The panel reviews
// every retained-data category, exposes a selective policy, saves a verified
// sanitized copy through VerifiedFileWriter (never in place) and can validate
// the saved bytes with RED-06 seeds. ApplicationDelegate owns the menu hook.

private enum RedactionSanitizationAssociationKeys {
  nonisolated(unsafe) static var controller: UInt8 = 0
}

@MainActor
final class RedactionSanitizationModel: ObservableObject {
  weak var document: SPDFDocument?
  @Published var policy: RedactionSanitizationPolicy = .secure
  @Published var attachmentAllowList: String = ""
  @Published var seeds: String = ""
  @Published var reviewText: String = ""
  @Published var reportText: String = ""
  @Published var verificationText: String = ""
  @Published var status: String = "Review the retained data, then save a sanitized copy."

  func review() {
    guard let document, let review = document.redactionHiddenDataReview() else {
      status = "Open a document to review retained data."
      return
    }
    reviewText = review.summary
    policy = document.redactionSanitizationPolicyDefaults(for: review)
    status = "Review only: nothing has been removed or saved yet."
  }

  func effectivePolicy() -> RedactionSanitizationPolicy {
    var policy = policy
    let names = attachmentAllowList.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    policy.allowedAttachmentNames = Set(names)
    if policy.removeAttachments && !names.isEmpty {
      // Keep only the allow-listed files.
      policy.allowedAttachmentNames = Set(names)
    }
    return policy
  }

  func saveSanitizedCopy() {
    guard let document else {
      status = "Open a document first."
      return
    }
    guard let sourceURL = document.fileURL else {
      status = "Save the source document before writing a sanitized copy."
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      sourceURL.deletingPathExtension().lastPathComponent + " (sanitized).pdf"
    panel.allowedContentTypes = [.pdf]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      let result = try document.saveRedactionSanitizedCopy(
        policy: effectivePolicy(), destination: destination,
        seeds: seedList())
      reportText = result.report.summary
      verificationText = result.verification.summary
      status = result.verification.passed
        ? "Saved a sanitized copy. The saved bytes were verified against the policy."
        : "Saved a copy, but verification needs attention. See the report."
    } catch {
      status = "Sanitization failed: " + error.localizedDescription
    }
  }

  func validateSavedCopy() {
    guard let document, let sourceURL = document.fileURL else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let outcome = try document.validateRedactionSanitizedOutput(
        at: url, seeds: seedList(), policy: effectivePolicy())
      reportText = outcome.report.summary
      verificationText = outcome.verification.summary
      status = outcome.verification.passed
        ? "Independent inspection found no protected seed in the selected output."
        : "Independent inspection found an issue in the selected output."
    } catch {
      status = "Validation failed: " + error.localizedDescription
    }
  }

  private func seedList() -> [String] {
    seeds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  func isRemoved(_ category: RedactionHiddenDataCategory) -> Bool {
    switch category {
    case .documentInfo: return policy.removeDocumentInfo
    case .xmpMetadata: return policy.removeXMPMetadata
    case .pageMetadata: return policy.removePageMetadata
    case .comments: return policy.removeComments
    case .links: return !policy.keepLinks
    case .formValues: return policy.clearFormValues
    case .xfaForms: return policy.removeXFA
    case .attachments: return policy.removeAttachments
    case .actions: return policy.removeActions
    case .optionalContent: return policy.removeOptionalContent
    case .alternateText: return policy.removeAlternateText
    case .ocrLayers: return policy.removeOCRLayers
    case .thumbnails: return policy.removeThumbnails
    case .privateApplicationData: return policy.removePrivateApplicationData
    case .documentIdentifiers: return policy.removeDocumentIdentifiers
    case .unreachableObjects: return policy.removeUnreachableObjects
    case .earlierRevisions: return true
    case .signatures: return false
    case .encryption: return false
    }
  }

  func setRemoved(_ category: RedactionHiddenDataCategory, _ removed: Bool) {
    switch category {
    case .documentInfo: policy.removeDocumentInfo = removed
    case .xmpMetadata: policy.removeXMPMetadata = removed
    case .pageMetadata: policy.removePageMetadata = removed
    case .comments: policy.removeComments = removed
    case .links: policy.keepLinks = !removed
    case .formValues: policy.clearFormValues = removed
    case .xfaForms: policy.removeXFA = removed
    case .attachments: policy.removeAttachments = removed
    case .actions: policy.removeActions = removed
    case .optionalContent: policy.removeOptionalContent = removed
    case .alternateText: policy.removeAlternateText = removed
    case .ocrLayers: policy.removeOCRLayers = removed
    case .thumbnails: policy.removeThumbnails = removed
    case .privateApplicationData: policy.removePrivateApplicationData = removed
    case .documentIdentifiers: policy.removeDocumentIdentifiers = removed
    case .unreachableObjects: policy.removeUnreachableObjects = removed
    case .earlierRevisions, .signatures, .encryption:
      break
    }
  }
}

struct RedactionSanitizePanel: View {
  @ObservedObject var model: RedactionSanitizationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sanitize Hidden Data").font(.headline)
      Text(
        "Review what the document retains, choose what the sanitized copy removes, "
          + "and save a new verified file. The source is never modified."
      ).font(.caption).foregroundStyle(.secondary)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          Text("Selective policy").font(.subheadline)
          ForEach(RedactionHiddenDataCategory.allCases, id: \.rawValue) { category in
            Toggle(
              category.title,
              isOn: Binding(
                get: { model.isRemoved(category) },
                set: { model.setRemoved(category, $0) }))
              .toggleStyle(.checkbox)
              .disabled(category == .earlierRevisions || category == .signatures
                || category == .encryption)
          }
          HStack {
            Text("Keep attachments named:").font(.caption)
            TextField("comma-separated", text: $model.attachmentAllowList)
              .textFieldStyle(.roundedBorder).frame(width: 220)
          }
          HStack {
            Text("Adversarial seeds:").font(.caption)
            TextField("comma-separated protected values", text: $model.seeds)
              .textFieldStyle(.roundedBorder)
          }
        }
      }.frame(maxHeight: 220)
      HStack {
        Button("Review Retained Data") { model.review() }
        Button("Save Sanitized Copy…") { model.saveSanitizedCopy() }
        Button("Validate Output…") { model.validateSavedCopy() }
      }
      Divider()
      ScrollView {
        Text(model.reportText.isEmpty ? model.reviewText : model.reportText)
          .font(.caption.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 160)
      if !model.verificationText.isEmpty {
        Text(model.verificationText).font(.caption).textSelection(.enabled)
      }
      Text(model.status).font(.caption).foregroundStyle(.secondary)
      Text(
        "Removed data may remain in the open source, undo history and recovery "
          + "snapshots; only the saved sanitized copy is verified."
      ).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(minWidth: 560, minHeight: 620)
    .onAppear { model.review() }
  }
}

@MainActor
final class RedactionSanitizePanelController: NSWindowController {
  convenience init(model: RedactionSanitizationModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Sanitize Hidden Data"
    window.contentView = NSHostingView(rootView: RedactionSanitizePanel(model: model))
    self.init(window: window)
  }
}

// MARK: - Document routes (RED-05/RED-06)

extension SPDFDocument {
  func redactionHiddenDataReview() -> RedactionHiddenDataReview? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? RedactionHiddenDataReviewer.review(in: graph)
  }

  func redactionSanitizationPolicyDefaults(
    for review: RedactionHiddenDataReview
  ) -> RedactionSanitizationPolicy {
    var policy = RedactionSanitizationPolicy.secure
    if review.count(.xfaForms) > 0 { policy.removeXFA = true }
    return policy
  }

  func saveRedactionSanitizedCopy(
    policy: RedactionSanitizationPolicy, destination: URL, seeds: [String] = []
  ) throws -> (report: RedactionSanitizationReport, verification: RedactionSanitizationVerification) {
    guard let graph = editSession.currentGraph else {
      throw PDFError(.unsupported, "There is no document to sanitize")
    }
    if let fileURL, destination.standardizedFileURL == fileURL.standardizedFileURL {
      throw PDFError(
        .unsupported, "A sanitized copy must be saved to a new file, never over the source")
    }
    let staged = try RedactionSanitizer.sanitize(in: graph, policy: policy)
    let data = try PDFWriter.write(staged.graph)
    try VerifiedFileWriter.write(data, to: destination, expectedGraph: staged.graph)
    let written = try Data(contentsOf: destination)
    let verification = RedactionSanitizedOutputVerifier.verify(
      data: written, report: staged.report, seeds: seeds)
    return (staged.report, verification)
  }

  func validateRedactionSanitizedOutput(
    at url: URL, seeds: [String], policy: RedactionSanitizationPolicy
  ) throws -> (report: RedactionSanitizationReport, verification: RedactionSanitizationVerification) {
    let parsed = try PDFParser.parse(try Data(contentsOf: url))
    let staged = try RedactionSanitizer.sanitize(in: parsed.graph, policy: policy)
    let data = try Data(contentsOf: url)
    let verification = RedactionSanitizedOutputVerifier.verify(
      data: data, report: staged.report, seeds: seeds)
    return (staged.report, verification)
  }

  /// Tools > Security > Sanitize Hidden Data…: review retained data, choose a
  /// selective policy and save a verified sanitized copy. Hook only; the panel
  /// never mutates the open document.
  func showRedactionSanitization() {
    if let existing = objc_getAssociatedObject(
      self, &RedactionSanitizationAssociationKeys.controller)
      as? RedactionSanitizePanelController
    {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let model = RedactionSanitizationModel()
    model.document = self
    let controller = RedactionSanitizePanelController(model: model)
    objc_setAssociatedObject(
      self, &RedactionSanitizationAssociationKeys.controller, controller,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    controller.showWindow(nil)
  }
}

