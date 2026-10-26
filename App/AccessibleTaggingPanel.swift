import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

// A11Y-03: the extended assisted-tagging review panel. Suggestions stay
// proposals until reviewed; reviewers can accept, reject or correct a kind, and
// the panel states explicitly that accepted suggestions are not a
// conformance claim.

@MainActor
final class AccessibleTaggingPanelModel: ObservableObject {
  struct Row: Identifiable, Equatable {
    let id: UUID
    let label: String
    let snippet: String
    let reason: String
    let confidence: String
    let status: AccessibleTaggingReview.Status
    let correctedRole: String?
  }

  @Published var rows: [Row] = []
  @Published var summary = "Analyze the document to review assisted tagging suggestions."
  @Published var disclaimer = AccessibleTaggingAssistant.conformanceDisclaimer
  @Published var notes: [String] = []
  @Published var statusText = "Nothing is tagged before you accept and apply a suggestion."
  @Published var errorText: String?
  @Published var isTagged = false

  private weak var document: SPDFDocument?
  private var review: AccessibleTaggingReview?

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  func refresh() {
    guard let document else { return }
    if let analysis = document.accessibleTaggingAnalysis() {
      review = AccessibleTaggingReview(suggestions: analysis.suggestions)
      summary = analysis.summary
      notes = analysis.notes
      statusText = "Suggestions are unconfirmed until accepted and applied."
      rebuildRows()
      isTagged = document.accessibleStructureIsTagged()
    } else {
      errorText = "No document content is available to analyze."
    }
  }

  private func rebuildRows() {
    guard let review else {
      rows = []
      return
    }
    rows = review.suggestions.map { suggestion in
      Row(
        id: suggestion.id, label: suggestion.label, snippet: suggestion.snippet,
        reason: suggestion.reason,
        confidence: String(Int((suggestion.confidence * 100).rounded())) + "%",
        status: review.status(of: suggestion.id),
        correctedRole: review.corrections[suggestion.id] == nil
          ? nil : suggestion.corrected(to: review.corrections[suggestion.id]!).proposedRole)
    }
  }

  func accept(_ id: UUID) {
    guard var review else { return }
    review.accept(id)
    self.review = review
    rebuildRows()
  }

  func reject(_ id: UUID) {
    guard var review else { return }
    review.reject(id)
    self.review = review
    rebuildRows()
  }

  func correct(_ id: UUID, kind: AccessibleTaggingSuggestion.Kind) {
    guard var review else { return }
    review.correct(id, to: kind)
    self.review = review
    rebuildRows()
  }

  func applyAccepted() {
    guard let document, let review, !review.accepted.isEmpty else {
      errorText = "Accept at least one suggestion first."
      return
    }
    errorText = nil
    if document.applyAccessibleTaggingReview(review) {
      statusText = "Applied the accepted suggestions as reviewed content."
      refresh()
    } else {
      errorText = document.accessibleTaggingLastError ?? "Applying the accepted suggestions failed."
    }
  }

  func correctionOptions() -> [(String, AccessibleTaggingSuggestion.Kind)] {
    [
      ("Paragraph", .paragraph), ("Heading 1", .heading(level: 1)),
      ("Heading 2", .heading(level: 2)), ("Heading 3", .heading(level: 3)),
      ("Caption", .caption), ("Artifact", .artifact(headerFooter: false)),
    ]
  }
}

@MainActor
final class AccessibleTaggingPanelController: NSWindowController {
  let model: AccessibleTaggingPanelModel

  init(document: SPDFDocument) {
    let model = AccessibleTaggingPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Assisted Tagging"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 820, height: 560)
    panel.contentView = NSHostingView(rootView: AccessibleTaggingPanelView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the assisted tagging panel")
  }
}

extension SPDFDocument {
  /// A11Y-03: open the reviewed assisted-tagging panel.
  func showAccessibleTaggingPanel() {
    if let controller = windowControllers.compactMap({
      $0 as? AccessibleTaggingPanelController
    }).first {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = AccessibleTaggingPanelController(document: self)
    addWindowController(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  var canShowAccessibleTaggingPanel: Bool { editSession.currentGraph != nil }

  func accessibleTaggingAnalysis() -> AccessibleTaggingAnalysis? {
    guard let graph = editSession.currentGraph else { return nil }
    return try? AccessibleTaggingAssistant.analyze(pageIDs: editSession.pageIDs, in: graph)
  }

  func accessibleStructureIsTagged() -> Bool {
    guard let graph = editSession.currentGraph else { return false }
    let inventory = try? PDFStructureInspector.inspect(in: graph, pageIDs: editSession.pageIDs)
    return inventory?.isTagged ?? false
  }

  /// A11Y-03: apply only accepted (and corrected) suggestions in one undoable
  /// transaction. Figures need alternate text; suggestions without it are
  /// refused rather than guessed.
  @discardableResult
  func applyAccessibleTaggingReview(_ review: AccessibleTaggingReview) -> Bool {
    guard canEditContent else { return false }
    var commands: [any PDFEditCommand] = []
    for suggestion in review.accepted {
      guard let command = review.command(for: suggestion) else { continue }
      commands.append(command)
    }
    guard !commands.isEmpty else {
      accessibleTaggingLastError = "Figures need alternate text before they can be applied."
      return false
    }
    guard let undoManager else { return false }
    let revision = editSession.documentRevision
    do {
      try editSession.apply(PDFTransaction(commands))
    } catch {
      accessibleTaggingLastError = error.localizedDescription
      return false
    }
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { document in
      document.performAccessibleTaggingUndo(registeredRevision: revision)
    }
    undoManager.setActionName("Apply Tagging Suggestions")
    undoManager.endUndoGrouping()
    accessibleTaggingLastError = nil
    refreshStructure()
    return true
  }

  private func performAccessibleTaggingUndo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.undo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performAccessibleTaggingRedo(registeredRevision: revision)
    }
    undoManager?.setActionName("Apply Tagging Suggestions")
    refreshStructure()
  }

  private func performAccessibleTaggingRedo(registeredRevision: UInt64?) {
    guard canEditContent else { return }
    if let registeredRevision, editSession.documentRevision != registeredRevision { return }
    guard editSession.redo() else { return }
    let revision = editSession.documentRevision
    undoManager?.registerUndo(withTarget: self) { document in
      document.performAccessibleTaggingUndo(registeredRevision: revision)
    }
    undoManager?.setActionName("Apply Tagging Suggestions")
    refreshStructure()
  }

  var accessibleTaggingLastError: String? {
    get {
      objc_getAssociatedObject(self, &AccessibleTaggingAssociationKeys.error) as? String
    }
    set {
      objc_setAssociatedObject(
        self, &AccessibleTaggingAssociationKeys.error, newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}

private enum AccessibleTaggingAssociationKeys {
  nonisolated(unsafe) static var error: UInt8 = 0
}

// MARK: - SwiftUI panel

struct AccessibleTaggingPanelView: View {
  @ObservedObject var model: AccessibleTaggingPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        header
        Divider()
        if model.rows.isEmpty {
          ContentUnavailableView(
            "No Suggestions", systemImage: "wand.and.stars",
            description: Text(
              "Analyze the document to list headings, lists, multicolumn paragraphs, "
                + "figures/captions and untagged content for review."))
        } else {
          ForEach(model.rows) { row in
            rowView(row)
          }
        }
        footer
      }
      .padding(16)
    }
    .frame(minWidth: 820, minHeight: 560)
    .accessibilityLabel("Assisted tagging review")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Assisted Tagging").font(.title3).bold()
        Spacer()
        Button("Analyze Again") { model.refresh() }
        Button("Apply Accepted") { model.applyAccepted() }
          .disabled(model.rows.filter { $0.status == .accepted }.isEmpty)
      }
      Text(model.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
      Text(model.statusText).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func rowView(_ row: AccessibleTaggingPanelModel.Row) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(row.label).font(.caption.weight(.semibold))
        if let corrected = row.correctedRole {
          Text("corrected to " + corrected).font(.caption2).foregroundStyle(.purple)
        }
        Text(row.confidence).font(.caption2).foregroundStyle(.secondary)
        Spacer()
        Text(row.status == .accepted ? "accepted" : (row.status == .rejected ? "rejected" : "pending"))
          .font(.caption2).foregroundStyle(color(for: row.status))
        Button("Accept") { model.accept(row.id) }
          .buttonStyle(.link)
        Button("Reject") { model.reject(row.id) }
          .buttonStyle(.link)
        Menu("Correct Kind") {
          ForEach(Array(model.correctionOptions().enumerated()), id: \.offset) { item in
            Button(item.element.0) { model.correct(row.id, kind: item.element.1) }
          }
        }
        .frame(width: 130)
      }
      if !row.snippet.isEmpty {
        Text(row.snippet).font(.caption2).foregroundStyle(.primary)
          .lineLimit(2)
      }
      Text(row.reason).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(8)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = model.errorText {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Text(model.disclaimer).font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(model.notes, id: \.self) { note in
        Text(note).font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func color(for status: AccessibleTaggingReview.Status) -> Color {
    switch status {
    case .pending: return .secondary
    case .accepted: return .green
    case .rejected: return .red
    }
  }
}
