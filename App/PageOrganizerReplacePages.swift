import AppKit
import PDFCore
import PDFEditing
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PAG-04 Replace Pages model

/// PAG-04 review model: choose a source PDF and replacement range, preview the
/// retention matrix without mutating anything, then apply one transaction.
@MainActor
final class ReplacePagesModel: ObservableObject {
  @Published var sourceName = "No source selected"
  @Published var sourcePageCount = 0
  @Published var sourceRange = ""
  @Published var formConflictPolicy: ReplacePagesOptions.FormFieldConflictPolicy = .rename
  @Published var pageLabelPolicy: ReplacePagesOptions.PageLabelPolicy = .retainDestination
  @Published var structurePolicy: ReplacePagesOptions.StructureTreePolicy = .dropDestination
  @Published var previewLines: [String] = []
  @Published var message: String?
  @Published var errorMessage: String?
  @Published var canApply = false

  private weak var document: SPDFDocument?
  private let destinationPageIDs: [PDFObjectID]
  private var sourceBytes: Data?
  private var sourcePageIndices: [Int] = []
  private let onApplied: (() -> Void)?

  init(
    document: SPDFDocument?, destinationPageIDs: [PDFObjectID],
    onApplied: (() -> Void)? = nil
  ) {
    self.document = document
    self.destinationPageIDs = destinationPageIDs
    self.onApplied = onApplied
  }

  var destinationSummary: String {
    "\(destinationPageIDs.count) destination page(s) will be replaced."
  }

  func chooseSource() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.message = "Choose the PDF that supplies the replacement pages."
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let parsed = try PDFParser.parse(data)
      let pages = try PDFPageTree.pageIDs(in: parsed.graph)
      sourceBytes = data
      sourcePageCount = pages.count
      sourceName = url.lastPathComponent
      sourceRange = pages.count == 1 ? "1" : "1-\(pages.count)"
      previewLines = []
      canApply = false
      message = "Selected \(pages.count) source page(s)."
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      sourceBytes = nil
      sourcePageCount = 0
    }
  }

  func preview() {
    guard let document, let graph = document.editSession.currentGraph else {
      errorMessage = "This document is not editable by the owned core."
      return
    }
    guard let sourceBytes else {
      errorMessage = "Choose a source PDF first."
      return
    }
    guard let indices = resolvedSourceIndices() else { return }
    let command = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes,
      destinationPageIDs: destinationPageIDs,
      sourcePageIndices: indices,
      options: options)
    do {
      let result = try command.preflight(
        in: graph, limits: SPDFDocumentResourcePolicy.parsingLimits)
      previewLines = result.report.matrixLines
      sourcePageIndices = indices
      canApply = true
      errorMessage = nil
      message = "Preview only; nothing has been changed yet."
    } catch {
      previewLines = []
      canApply = false
      errorMessage = error.localizedDescription
    }
  }

  func apply() {
    guard let document, let sourceBytes else { return }
    guard let indices = resolvedSourceIndices() else { return }
    let command = ReplacePagesCommand(
      sourceDocumentBytes: sourceBytes,
      destinationPageIDs: destinationPageIDs,
      sourcePageIndices: indices,
      options: options)
    guard document.applyPageOrganizerTransaction(
      PDFTransaction([command]), actionName: "Replace Pages")
    else {
      errorMessage = "The replacement was refused."
      return
    }
    message = "Replace Pages applied as one undoable step."
    onApplied?()
    NSApp.keyWindow?.performClose(nil)
  }

  private var options: ReplacePagesOptions {
    ReplacePagesOptions(
      formFieldConflicts: formConflictPolicy,
      pageLabels: pageLabelPolicy,
      structureTree: structurePolicy)
  }

  private func resolvedSourceIndices() -> [Int]? {
    guard !sourceRange.trimmingCharacters(in: .whitespaces).isEmpty else {
      errorMessage = "Enter the replacement page range."
      return nil
    }
    let indices = PageRange.parse(sourceRange, pageCount: sourcePageCount)
    guard !indices.isEmpty else {
      errorMessage = "The replacement page range does not contain any source page."
      return nil
    }
    return indices
  }
}

// MARK: - Replace Pages sheet

struct ReplacePagesPanel: View {
  @ObservedObject var model: ReplacePagesModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Replace Pages").font(.title3.weight(.semibold))
        Spacer()
        Button("Cancel") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
      }
      Text(
        "The selected destination pages and everything attached to them are replaced by the "
          + "chosen source pages. The retention matrix below states exactly what is dropped, "
          + "imported or retained before you apply.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(model.destinationSummary).font(.caption.weight(.medium))
      HStack(spacing: 8) {
        Button("Choose Source PDF…") { model.chooseSource() }
          .accessibilityLabel("Choose replacement PDF")
        Text(model.sourceName).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("Replacement pages").font(.caption)
        TextField("1-2", text: $model.sourceRange)
          .textFieldStyle(.roundedBorder)
          .frame(width: 110)
          .accessibilityLabel("Replacement source page range")
          .disabled(model.sourcePageCount == 0)
      }
      HStack(spacing: 14) {
        Picker("Form-field names", selection: $model.formConflictPolicy) {
          ForEach(ReplacePagesOptions.FormFieldConflictPolicy.allCases, id: \.self) { policy in
            Text(policy.title).tag(policy)
          }
        }
        .frame(width: 250)
        .accessibilityLabel("Form field conflict policy")
        Picker("Page labels", selection: $model.pageLabelPolicy) {
          ForEach(ReplacePagesOptions.PageLabelPolicy.allCases, id: \.self) { policy in
            Text(policy.title).tag(policy)
          }
        }
        .frame(width: 230)
        .accessibilityLabel("Page label policy")
        Picker("Structure tree", selection: $model.structurePolicy) {
          ForEach(ReplacePagesOptions.StructureTreePolicy.allCases, id: \.self) { policy in
            Text(policy.title).tag(policy)
          }
        }
        .frame(width: 260)
        .accessibilityLabel("Structure tree policy")
        Spacer()
      }
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let message = model.message {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(Array(model.previewLines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 150, maxHeight: 240)
      .padding(8)
      .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
      HStack {
        Button("Preview Retention Matrix") { model.preview() }
          .accessibilityLabel("Preview replacement retention matrix")
        Spacer()
        Button("Replace Pages") { model.apply() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canApply)
          .accessibilityLabel("Apply page replacement")
      }
    }
    .padding(16)
    .frame(minWidth: 720, minHeight: 560)
  }
}
