import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

// MARK: - Model

/// FRM/REV export panel state: printable review summaries (REV-04) and
/// portable comparison reports (REV-07). The panel only collects options; the
/// SPDFDocument extension renders pages and writes the report PDF.
@MainActor
final class ReviewReportsPanelModel: ObservableObject {
  @Published var reviewTitle = "Review Summary"
  @Published var sourceDescription = ""
  @Published var includePageImages = true
  @Published var includeReplyThreads = true
  @Published var filterText = ""
  @Published var filterAuthor = ""
  @Published var filterType = "Any"
  @Published var filterState = "Any"
  @Published var pageFrom = ""
  @Published var pageTo = ""
  @Published var typeOptions: [String] = ["Any"]
  @Published var stateOptions: [String] = ["Any"]
  @Published var totalComments = 0
  @Published var matchedComments = 0
  @Published var reviewNote: String?
  @Published var reviewError: String?

  @Published var comparisonAvailable = false
  @Published var comparisonTitle = "Comparison Report"
  @Published var leftLabel = "Left document"
  @Published var rightLabel = "Right document"
  @Published var includeUnchangedPairs = false
  @Published var comparisonIncludePageImages = true
  @Published var comparisonIncludeRegionImages = true
  @Published var mappingWasEdited = false
  @Published var comparisonChangeCount = 0
  @Published var comparisonPairCount = 0
  @Published var comparisonNote: String?
  @Published var comparisonError: String?

  private weak var document: SPDFDocument?

  init(document: SPDFDocument) {
    self.document = document
    refresh()
  }

  func refresh() {
    guard let document else { return }
    let types = document.reviewCommentSubtypeNames()
    let states = document.reviewCommentStateNames()
    typeOptions = ["Any"] + types
    stateOptions = ["Any"] + states
    if !typeOptions.contains(filterType) { filterType = "Any" }
    if !stateOptions.contains(filterState) { filterState = "Any" }
    let counts = document.reviewSummaryCounts(
      filter: makeFilter(includePageRange: false), pageIndices: nil)
    totalComments = counts.total
    matchedComments = counts.matched
    if comparisonSession(for: document) != nil {
      comparisonAvailable = true
      configureComparisonDefaults(for: document)
    } else {
      comparisonAvailable = false
    }
  }

  private func comparisonSession(for document: SPDFDocument) -> ComparisonSession? {
    document.comparisonSession
  }

  private func configureComparisonDefaults(for document: SPDFDocument) {
    guard let session = document.comparisonSession else { return }
    if leftLabel == "Left document" {
      leftLabel = session.leftDocument.documentURL?.lastPathComponent ?? "Left document"
    }
    if rightLabel == "Right document" {
      rightLabel = session.rightDocument.documentURL?.lastPathComponent ?? "Right document"
    }
    comparisonPairCount = session.result.pageMapping.count
    comparisonChangeCount = session.result.changes.count
  }

  // MARK: Filters

  func makeFilter(includePageRange: Bool = true) -> CommentFilter {
    var filter = CommentFilter()
    let text = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty { filter.text = text }
    let author = filterAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
    if !author.isEmpty { filter.author = author }
    if filterType != "Any", !filterType.isEmpty {
      filter.subtype = PDFName(filterType)
    }
    if filterState != "Any", !filterState.isEmpty {
      filter.state = PDFName(filterState)
    }
    return filter
  }

  func validatedPageIndices() throws -> Set<Int>? {
    guard let document else { return nil }
    let fromText = pageFrom.trimmingCharacters(in: .whitespacesAndNewlines)
    let toText = pageTo.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fromText.isEmpty || !toText.isEmpty else { return nil }
    let pageCount = document.editSession.pageIDs.count
    guard pageCount > 0 else {
      throw PDFError(.malformed, "The document has no pages")
    }
    let from = Int(fromText) ?? 1
    let to = Int(toText) ?? pageCount
    guard from >= 1, to >= from, to <= pageCount else {
      throw PDFError(
        .malformed,
        "Enter a page range between 1 and \(pageCount) with the first page not after the last")
    }
    return Set((from - 1)...(to - 1))
  }

  // MARK: Review summary

  func exportReviewSummary() {
    guard let document else { return }
    reviewNote = nil
    reviewError = nil
    let pageIndices: Set<Int>?
    do {
      pageIndices = try validatedPageIndices()
    } catch {
      reviewError = error.localizedDescription
      return
    }
    let source = sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let options = ReviewSummaryOptions(
      title: reviewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Review Summary" : reviewTitle,
      sourceDescription: source.isEmpty
        ? document.fileURL?.lastPathComponent : source,
      documentRevision: document.editSession.documentRevision,
      filter: makeFilter(),
      pageIndices: pageIndices,
      includeReplyThreads: includeReplyThreads,
      includePageImages: includePageImages)
    document.presentReviewSummaryExport(options: options) { [weak self] message, error in
      guard let self else { return }
      if let error {
        self.reviewError = error.localizedDescription
      } else if let message {
        self.reviewNote = message
      }
    }
  }

  // MARK: Comparison report

  func exportComparisonReport() {
    guard let document, document.comparisonSession != nil else {
      comparisonError = "Open Tools > Compare With... to create a comparison session first."
      return
    }
    comparisonNote = nil
    comparisonError = nil
    let options = ComparisonReportOptions(
      title: comparisonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Comparison Report" : comparisonTitle,
      leftLabel: leftLabel.isEmpty ? "Left document" : leftLabel,
      rightLabel: rightLabel.isEmpty ? "Right document" : rightLabel,
      mappingWasEdited: mappingWasEdited,
      includeUnchangedPairs: includeUnchangedPairs,
      includePageImages: comparisonIncludePageImages)
    document.presentComparisonReportExport(
      options: options, includePageImages: comparisonIncludePageImages,
      includeRegionImages: comparisonIncludeRegionImages
    ) { [weak self] message, error in
      guard let self else { return }
      if let error {
        self.comparisonError = error.localizedDescription
      } else if let message {
        self.comparisonNote = message
      }
    }
  }
}

// MARK: - Window controller

@MainActor
final class ReviewReportsPanelController: NSWindowController {
  let model: ReviewReportsPanelModel

  init(document: SPDFDocument) {
    let model = ReviewReportsPanelModel(document: document)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Review Reports"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 760, height: 620)
    panel.contentView = NSHostingView(rootView: ReviewReportsView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the review reports panel")
  }

  func refresh() {
    model.refresh()
  }
}

// MARK: - View

struct ReviewReportsView: View {
  @ObservedObject var model: ReviewReportsPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        Divider()
        reviewSection
        Divider()
        comparisonSection
      }
      .padding(18)
    }
    .frame(minWidth: 760, minHeight: 620)
    .accessibilityLabel("Review and comparison reports")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Review Reports").font(.title2.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close review reports")
      }
      Text(
        "Portable PDF reports generated locally: a printable review summary with page context and "
          + "comment anchors, and a self-contained comparison report with page images, regions, "
          + "chosen options and mapping/uncertainty records.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Review summary

  private var reviewSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Review Summary (PDF)").font(.headline)
      Text(
        "Includes the actual comments that match the filters, their stable identities, numbered "
          + "page-context anchors and reply threads. The document is never modified.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        labeledField("Title", text: $model.reviewTitle)
        labeledField("Source description", text: $model.sourceDescription)
      }
      HStack(spacing: 10) {
        labeledField("Text contains", text: $model.filterText)
        labeledField("Author", text: $model.filterAuthor)
      }
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Type").font(.caption2).foregroundStyle(.secondary)
          Picker("Comment type", selection: $model.filterType) {
            ForEach(model.typeOptions, id: \.self) { name in Text(name).tag(name) }
          }
          .labelsHidden()
          .frame(width: 150)
          .accessibilityLabel("Comment type filter")
        }
        VStack(alignment: .leading, spacing: 3) {
          Text("State").font(.caption2).foregroundStyle(.secondary)
          Picker("Comment state", selection: $model.filterState) {
            ForEach(model.stateOptions, id: \.self) { name in Text(name).tag(name) }
          }
          .labelsHidden()
          .frame(width: 150)
          .accessibilityLabel("Comment state filter")
        }
        labeledField("Pages from", text: $model.pageFrom, width: 70)
        labeledField("to", text: $model.pageTo, width: 70)
        Spacer()
      }
      HStack(spacing: 18) {
        Toggle("Include page images", isOn: $model.includePageImages)
        Toggle("Include reply threads", isOn: $model.includeReplyThreads)
        Spacer()
        Button("Refresh Counts") { model.refresh() }
          .accessibilityLabel("Refresh comment counts")
      }
      Text(
        "\(model.matchedComments) of \(model.totalComments) comment(s) match the current filters.")
        .font(.caption.weight(.medium))
        .accessibilityLabel("Matching comment count")
      HStack {
        Button {
          model.exportReviewSummary()
        } label: {
          Label("Export Review Summary (PDF)...", systemImage: "doc.richtext")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Export review summary PDF")
        Spacer()
      }
      if let note = model.reviewNote {
        Label(note, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error = model.reviewError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: Comparison report

  private var comparisonSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Comparison Report (PDF)").font(.headline)
      if model.comparisonAvailable {
        Text(
          "Records the chosen comparison options, the full page mapping, per-change summaries and bounds, "
            + "rendered page images and change-region crops, plus explicit uncertainty/mapping provenance.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          labeledField("Title", text: $model.comparisonTitle)
          labeledField("Left label", text: $model.leftLabel)
          labeledField("Right label", text: $model.rightLabel)
        }
        HStack(spacing: 18) {
          Toggle("Include unchanged pairs", isOn: $model.includeUnchangedPairs)
          Toggle("Include page images", isOn: $model.comparisonIncludePageImages)
          Toggle("Include region crops", isOn: $model.comparisonIncludeRegionImages)
        }
        Toggle(
          "Record the page mapping as manually corrected",
          isOn: $model.mappingWasEdited)
          .accessibilityLabel("Record manually corrected page mapping")
        Text(
          "\(model.comparisonChangeCount) change(s) across \(model.comparisonPairCount) page-mapping pair(s).")
          .font(.caption.weight(.medium))
        HStack {
          Button {
            model.exportComparisonReport()
          } label: {
            Label("Export Comparison Report (PDF)...", systemImage: "rectangle.split.2x1")
          }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel("Export comparison report PDF")
          Spacer()
        }
        if let note = model.comparisonNote {
          Label(note, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.comparisonError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Label(
          "Open Tools > Compare With... to create a comparison session; the portable comparison "
            + "report is available once two documents are compared.",
          systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Comparison report unavailable")
      }
    }
  }

  private func labeledField(
    _ label: String, text: Binding<String>, width: CGFloat? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      TextField(label, text: text)
        .textFieldStyle(.roundedBorder)
        .frame(width: width)
        .accessibilityLabel(label)
    }
  }
}
