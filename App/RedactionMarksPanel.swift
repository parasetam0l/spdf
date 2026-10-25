import AppKit
import Combine
import PDFCore
import PDFEditing
import SwiftUI

// MARK: - Panel model

/// RED-01/RED-02 review state for the redaction marks window. All actions are
/// delegate calls into SPDFDocument extension routes; the model never edits the
/// session graph directly.
@MainActor
final class RedactionMarksPanelModel: ObservableObject {
  static let termSetDefaultsKey = "com.parasetam0l.spdf.redactionTermSets"

  struct MarkRow: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let status: String
    let refusal: String?
    let isPending: Bool
    let isEditable: Bool
    let pageIndex: Int
    let rects: [[Double]]
    let reason: String?
    /// RED-03: exact overlay lines painted for this mark.
    let overlayText: [String]
    /// RED-04: what the mark removes (whole image draws, forms, vector paint).
    let removalItems: [String]
  }

  struct HitRow: Identifiable {
    let id: String
    let pageLabel: String
    let context: String
    let source: String
    let hidden: Bool
    let refusal: String?
    let isSelected: Bool
    let isEligible: Bool
    /// RED-04: raster-removal disclosure for a scan-backed match.
    let note: String?
  }

  @Published var statusDescription = "No redaction marks. Nothing has been removed."
  @Published var planSummary = ""
  @Published var planStatus = ""
  @Published var overlaySummary = ""
  @Published var disclosures: [String] = []
  @Published var markRows: [MarkRow] = []
  @Published var canApply = false
  @Published var pendingCount = 0
  @Published var appliedCount = 0
  @Published var refusedCount = 0
  @Published var hiddenPolicy: RedactionHiddenTextPolicy = .removeFromAffectedPages {
    didSet {
      session.options.hiddenTextPolicy = hiddenPolicy
      refreshPlan()
    }
  }

  // MARK: RED-03 overlay and repeated-region settings

  static let overlayFillColors: [[Double]] = [
    [0, 0, 0], [0.25, 0.25, 0.25], [0.7, 0, 0], [0.9, 0.9, 0.9],
  ]
  static let overlayFillNames = ["Black", "Dark gray", "Red", "Light gray"]
  static let overlayTextColors: [[Double]] = [[1, 1, 1], [0, 0, 0], [1, 0.85, 0.2]]
  static let overlayTextNames = ["White", "Black", "Amber"]
  static let overlayReasonChoices: [String] =
    ["No reason code"] + RedactionReasonCode.presets.map(\.label) + ["Custom…"]

  @Published var overlayEnabled = true { didSet { syncOverlay() } }
  @Published var overlayFillColor = 0 { didSet { syncOverlay() } }
  @Published var overlayTextColor = 0 { didSet { syncOverlay() } }
  @Published var overlayReplacementText = "" { didSet { syncOverlay() } }
  @Published var overlayReasonChoice = 0 { didSet { syncOverlay() } }
  @Published var overlayCustomReason = "" { didSet { syncOverlay() } }
  @Published var overlayShowsReasonCode = true { didSet { syncOverlay() } }
  @Published var overlayFontSize = "9" { didSet { syncOverlay() } }
  /// RED-03: 1-based page range for a repeated region, e.g. "1-3, 5".
  @Published var repeatedRegionPages = ""
  private var suppressesOverlaySync = false

  @Published var noteText: String?
  @Published var errorMessage: String?

  @Published var editingMarkID: UUID?
  @Published var editX0 = ""
  @Published var editY0 = ""
  @Published var editX1 = ""
  @Published var editY1 = ""
  @Published var editReason = ""

  @Published var query = ""
  @Published var patternName = ""
  @Published var patternExpression = ""
  @Published var scope: RedactionSearchScope = .document
  @Published var matchCase = false
  @Published var wholeWord = false
  @Published var includeHiddenText = false
  @Published var termSetName = ""
  @Published var savedSetNames: [String] = []
  @Published var activeSetNames: Set<String> = []
  @Published var searchSummary = ""
  @Published var searchError: String?
  @Published var hitRows: [HitRow] = []
  @Published var selectedHitCount = 0
  @Published var markableHitCount = 0

  @Published var rectanglePage = ""
  @Published var rectangleX0 = ""
  @Published var rectangleY0 = ""
  @Published var rectangleX1 = ""
  @Published var rectangleY1 = ""

  private weak var document: SPDFDocument?
  private let session: RedactionMarksSession
  private var queue: RedactionReviewQueue?

  init(document: SPDFDocument, session: RedactionMarksSession) {
    self.document = document
    self.session = session
    self.hiddenPolicy = session.options.hiddenTextPolicy
    loadSavedTermSets()
    loadOverlayFields(from: session.overlay)
    refreshAll()
  }

  // MARK: RED-03 overlay settings

  func loadOverlayFields(from overlay: RedactionOverlayOptions) {
    suppressesOverlaySync = true
    defer { suppressesOverlaySync = false }
    overlayEnabled = overlay.paintsOverlay
    overlayFillColor = Self.nearestColorIndex(overlay.fillColor, Self.overlayFillColors)
    overlayTextColor = Self.nearestColorIndex(overlay.textColor, Self.overlayTextColors)
    overlayReplacementText = overlay.replacementText ?? ""
    overlayShowsReasonCode = overlay.showsReasonCode
    overlayFontSize = Self.number(overlay.fontSize)
    if let code = overlay.reasonCode {
      let presets = RedactionReasonCode.presets
      if let index = presets.firstIndex(where: { $0.code == code.code }) {
        overlayReasonChoice = index + 1
        overlayCustomReason = ""
      } else {
        overlayReasonChoice = presets.count + 1
        overlayCustomReason = code.label
      }
    } else {
      overlayReasonChoice = 0
      overlayCustomReason = ""
    }
  }

  var selectedOverlayReasonCode: RedactionReasonCode? {
    guard overlayReasonChoice > 0 else { return nil }
    let presets = RedactionReasonCode.presets
    if overlayReasonChoice <= presets.count { return presets[overlayReasonChoice - 1] }
    let label = overlayCustomReason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    return RedactionReasonCode(code: "custom", label: label)
  }

  func currentOverlay() -> RedactionOverlayOptions {
    let fill = Self.overlayFillColors[
      max(0, min(overlayFillColor, Self.overlayFillColors.count - 1))]
    let text = Self.overlayTextColors[
      max(0, min(overlayTextColor, Self.overlayTextColors.count - 1))]
    let replacement = overlayReplacementText.trimmingCharacters(in: .whitespacesAndNewlines)
    return RedactionOverlayOptions(
      paintsOverlay: overlayEnabled, fillColor: fill, textColor: text,
      replacementText: replacement.isEmpty ? nil : overlayReplacementText,
      reasonCode: selectedOverlayReasonCode,
      showsReasonCode: overlayShowsReasonCode,
      fontSize: Double(overlayFontSize) ?? 9,
      fontFamily: .helvetica, textAlignment: .center)
  }

  func syncOverlay() {
    guard !suppressesOverlaySync else { return }
    let overlay = currentOverlay()
    guard (try? overlay.validate()) != nil else {
      errorMessage =
        "Review the overlay settings: text must use printable Latin-1 characters and the size must be 2-96."
      return
    }
    session.overlay = overlay
    errorMessage = nil
    refreshPlan()
  }

  func resetOverlayToFillOnly() {
    suppressesOverlaySync = true
    overlayEnabled = true
    overlayFillColor = 0
    overlayTextColor = 0
    overlayReplacementText = ""
    overlayReasonChoice = 0
    overlayCustomReason = ""
    overlayShowsReasonCode = false
    overlayFontSize = "9"
    suppressesOverlaySync = false
    syncOverlay()
    noteText = "Overlay reset to a plain fill. Removal settings are unchanged."
  }

  static func nearestColorIndex(_ color: [Double], _ presets: [[Double]]) -> Int {
    guard color.count == 3 else { return 0 }
    var best = 0
    var bestDistance = Double.infinity
    for (index, preset) in presets.enumerated() {
      let distance = zip(color, preset).reduce(0.0) {
        $0 + ($1.0 - $1.1) * ($1.0 - $1.1)
      }
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    return best
  }

  // MARK: Refresh

  func refreshAll() {
    session.options.hiddenTextPolicy = hiddenPolicy
    let plan = document?.redactionPlan(options: session.options)
    planSummary = plan?.summary ?? ""
    planStatus = plan?.statusDescription ?? session.store.statusDescription
    overlaySummary = plan?.overlay.summary ?? session.overlay.summary
    statusDescription = session.store.statusDescription
    disclosures = plan?.disclosures ?? []
    pendingCount = session.store.pendingCount
    appliedCount = session.store.appliedCount
    refusedCount = plan?.refusedCount ?? 0
    canApply = (plan?.canApply ?? false) && session.store.hasUnappliedMarks
    markRows = makeMarkRows(plan: plan)
    noteText = nil
  }

  func refreshPlan() {
    let plan = document?.redactionPlan(options: session.options)
    planSummary = plan?.summary ?? ""
    planStatus = plan?.statusDescription ?? session.store.statusDescription
    overlaySummary = plan?.overlay.summary ?? session.overlay.summary
    disclosures = plan?.disclosures ?? []
    refusedCount = plan?.refusedCount ?? 0
    canApply = (plan?.canApply ?? false) && session.store.hasUnappliedMarks
    markRows = makeMarkRows(plan: plan)
  }

  func note(_ text: String) {
    noteText = text
    errorMessage = nil
    refreshAll()
    noteText = text
  }

  private func makeMarkRows(plan: RedactionMarkPlan?) -> [MarkRow] {
    session.store.marks.map { mark in
      let entry = plan?.entries.first { $0.id == mark.id }
      let status: String
      var refusal: String?
      switch entry?.status {
      case .pending: status = "Pending — not applied"
      case .applied: status = "Applied"
      case .coveredByPageMark: status = "Covered by whole-page mark"
      case .refused(let reason):
        status = "Cannot apply"
        refusal = reason
      case nil:
        status = session.store.isApplied(mark.id) ? "Applied" : "Pending — not applied"
      }
      var details: [String] = [mark.sourceLabel]
      if let entry {
        if entry.textRuns > 0 { details.append(String(entry.textRuns) + " text run(s)") }
        if entry.hiddenTextRuns > 0 {
          details.append(String(entry.hiddenTextRuns) + " hidden run(s) removed on the page")
        }
        if entry.images > 0 { details.append(String(entry.images) + " image draw(s)") }
        if entry.annotations > 0 {
          details.append(String(entry.annotations) + " annotation(s)")
        }
        if entry.formFields > 0 { details.append(String(entry.formFields) + " form field(s)") }
      }
      let rectText = mark.rects.map { rect in
        "[" + rect.map { Self.number($0) }.joined(separator: ", ") + "]"
      }.joined(separator: " ")
      return MarkRow(
        id: mark.id,
        title: "Page " + String(mark.pageIndex + 1) + " · " + mark.kind.title
          + (mark.isHiddenText ? " (hidden)" : "")
          + (mark.removesRasterPaint ? " (scan)" : ""),
        detail: details.joined(separator: " · ") + " — " + rectText,
        status: status,
        refusal: refusal,
        isPending: !session.store.isApplied(mark.id),
        isEditable: mark.kind != .page && !session.store.isApplied(mark.id),
        pageIndex: mark.pageIndex,
        rects: mark.rects,
        reason: mark.reason,
        overlayText: entry?.overlayText ?? [],
        removalItems: entry?.removalItems ?? [])
    }
  }

  // MARK: Mark editing

  func beginEditing(_ row: MarkRow) {
    guard row.isEditable else { return }
    editingMarkID = row.id
    editX0 = Self.number(row.rects.first?[0] ?? 0)
    editY0 = Self.number(row.rects.first?[1] ?? 0)
    editX1 = Self.number(row.rects.first?[2] ?? 0)
    editY1 = Self.number(row.rects.first?[3] ?? 0)
    editReason = row.reason ?? ""
    errorMessage = nil
  }

  func cancelEditing() {
    editingMarkID = nil
    errorMessage = nil
  }

  func commitEditing() {
    guard let id = editingMarkID else { return }
    guard let rect = Self.parseRect(editX0, editY0, editX1, editY1) else {
      errorMessage = "Enter four finite numbers with x1 greater than x0 and y1 greater than y0."
      return
    }
    do {
      try session.store.updateGeometry(id: id, rects: [rect])
      session.store.updateReason(id: id, reason: editReason.isEmpty ? nil : editReason)
      editingMarkID = nil
      errorMessage = nil
      refreshAll()
      noteText = "Mark geometry updated — it is pending again; nothing has been removed yet."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func removeMark(_ row: MarkRow) {
    session.store.remove(id: row.id)
    if editingMarkID == row.id { editingMarkID = nil }
    refreshAll()
    noteText = "Removed the pending mark. The document was not changed."
  }

  func navigate(to pageIndex: Int) {
    document?.viewer?.go(to: pageIndex + 1)
  }

  // MARK: Staging

  func markCurrentSelection() {
    guard let document else { return }
    if !document.markSelectionForRedaction() {
      errorMessage = "Select text on the page first, or use a rectangle or whole-page mark."
      return
    }
    errorMessage = nil
    refreshAll()
  }

  func markCurrentPage() {
    guard let document else { return }
    if !document.markCurrentPageForRedaction() {
      errorMessage = "No page is shown to mark."
      return
    }
    errorMessage = nil
    refreshAll()
  }

  func addRectangleMark() {
    guard let document else { return }
    guard let pageNumber = Int(rectanglePage.trimmingCharacters(in: .whitespaces)),
      pageNumber >= 1
    else {
      errorMessage = "Enter the 1-based page number for the rectangle."
      return
    }
    guard let rect = Self.parseRect(rectangleX0, rectangleY0, rectangleX1, rectangleY1) else {
      errorMessage = "Enter four finite numbers with x1 greater than x0 and y1 greater than y0."
      return
    }
    if !document.markRedactionRegion(pageIndex: pageNumber - 1, rect: rect) {
      errorMessage = "The rectangle could not be staged on that page."
      return
    }
    errorMessage = nil
    refreshAll()
  }

  /// RED-03: stage the same rectangle on every page of the entered range.
  func addRepeatedRegion() {
    guard let document else { return }
    guard let rect = Self.parseRect(rectangleX0, rectangleY0, rectangleX1, rectangleY1) else {
      errorMessage = "Enter four finite numbers with x1 greater than x0 and y1 greater than y0."
      return
    }
    let range = repeatedRegionPages.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !range.isEmpty else {
      errorMessage = "Enter a page range such as 1-3 or 2, 4-6 for the repeated region."
      return
    }
    let added = document.markRepeatedRedactionRegion(pageRange: range, rect: rect)
    guard added > 0 else {
      errorMessage = "The repeated region could not be staged for that page range."
      return
    }
    errorMessage = nil
    refreshAll()
    noteText = "Staged " + String(added)
      + " repeated region mark(s) as pending — nothing has been removed yet."
  }

  // MARK: Search

  func runSearch() {
    guard let document else { return }
    let pageIDs = document.redactionPageIDs()
    guard !pageIDs.isEmpty else {
      searchError = "The document has no pages to search."
      return
    }
    var queries: [String] = []
    for line in query.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { queries.append(trimmed) }
    }
    var patterns: [RedactionPattern] = []
    let expression = patternExpression.trimmingCharacters(in: .whitespacesAndNewlines)
    if !expression.isEmpty {
      patterns.append(
        RedactionPattern(
          name: patternName.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Custom pattern" : patternName.trimmingCharacters(in: .whitespaces),
          expression: expression, caseSensitive: matchCase))
    }
    var termSets: [RedactionTermSet] = []
    for name in activeSetNames.sorted() {
      if let set = session.termSets.set(named: name) { termSets.append(set) }
    }
    guard !queries.isEmpty || !patterns.isEmpty || !termSets.isEmpty else {
      searchError = "Enter a word or phrase, choose a term set, or enter a pattern."
      return
    }
    let currentPageIndex = max(0, min((document.viewer?.pageNumber ?? 1) - 1, pageIDs.count - 1))
    let request = RedactionSearchRequest(
      scope: scope, pageIDs: pageIDs, currentPageIndex: currentPageIndex,
      selectionRects: scope == .selection ? document.redactionSelectionRects() : nil,
      queries: queries, patterns: patterns, termSets: termSets,
      options: TextSearchOptions(caseSensitive: matchCase, wholeWord: wholeWord),
      includeHiddenText: includeHiddenText)
    do {
      let preview = try document.redactionSearchPreview(request)
      session.lastSearchRequest = request
      queue = RedactionReviewQueue(hits: preview.hits)
      searchSummary = preview.summary
      searchError = nil
      rebuildHitRows()
    } catch {
      session.lastSearchRequest = nil
      queue = nil
      hitRows = []
      searchSummary = ""
      searchError = error.localizedDescription
    }
  }

  private func rebuildHitRows() {
    guard let queue else {
      hitRows = []
      selectedHitCount = 0
      markableHitCount = 0
      return
    }
    hitRows = queue.hits.map { hit in
      HitRow(
        id: hit.id, pageLabel: hit.pageLabel, context: hit.context,
        source: hit.sourceLabel + (hit.isHidden ? " · hidden/OCR" : ""),
        hidden: hit.isHidden, refusal: hit.refusal,
        isSelected: queue.isSelected(hit.id), isEligible: hit.isEligible,
        note: hit.rasterNote)
    }
    selectedHitCount = queue.selectedCount
    markableHitCount = queue.eligibleCount
  }

  func toggleHit(_ row: HitRow) {
    queue?.toggle(hitID: row.id)
    rebuildHitRows()
  }

  func selectAllMarkableHits() {
    queue?.selectAllEligible()
    rebuildHitRows()
  }

  func clearHitSelection() {
    queue?.clearSelection()
    rebuildHitRows()
  }

  func markSelectedHits() {
    guard var queue else { return }
    var store = session.store
    do {
      let added = try queue.addSelectedHits(to: &store)
      session.store = store
      self.queue = queue
      rebuildHitRows()
      refreshAll()
      noteText = added > 0
        ? "Staged " + String(added) + " search match(es) as pending — nothing has been removed yet."
        : "Select at least one markable match first."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: Term sets

  func loadSavedTermSets() {
    guard let data = UserDefaults.standard.data(forKey: Self.termSetDefaultsKey),
      let library = try? RedactionTermSetLibrary.decoded(from: data)
    else {
      savedSetNames = session.termSets.sets.map(\.name)
      return
    }
    session.termSets = library
    savedSetNames = library.sets.map(\.name)
  }

  private func persistTermSets() {
    if let data = try? session.termSets.encodedJSON() {
      UserDefaults.standard.set(data, forKey: Self.termSetDefaultsKey)
    }
    savedSetNames = session.termSets.sets.map(\.name)
    activeSetNames = activeSetNames.filter { savedSetNames.contains($0) }
  }

  func saveCurrentTermSet() {
    let name = termSetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      errorMessage = "Give the term set a name before saving it."
      return
    }
    var terms: [String] = []
    for line in query.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { terms.append(trimmed) }
    }
    guard !terms.isEmpty else {
      errorMessage = "Type the words or phrases (one per line) before saving a term set."
      return
    }
    do {
      try session.termSets.upsert(
        RedactionTermSet(
          name: name, terms: terms, caseSensitive: matchCase, wholeWord: wholeWord))
      persistTermSets()
      noteText = "Saved the reusable term set “" + name + "”."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteSavedSet(_ name: String) {
    _ = session.termSets.remove(named: name)
    activeSetNames.remove(name)
    persistTermSets()
    noteText = "Removed the term set “" + name + "”."
  }

  func toggleActiveSet(_ name: String) {
    if activeSetNames.contains(name) {
      activeSetNames.remove(name)
    } else {
      activeSetNames.insert(name)
    }
  }

  // MARK: Apply

  func applyMarks() {
    guard let document else { return }
    let count = session.store.pendingCount
    guard count > 0 else { return }
    let alert = NSAlert()
    alert.messageText = "Apply " + String(count) + " redaction mark(s)?"
    var text =
      "Applying removes the marked content from this document and cannot show a preview afterwards. "
      + "The edit can be undone until the document is saved; saving writes a verified full rewrite "
      + "so earlier revisions do not retain the removed content."
    if refusedCount > 0 {
      text += " " + String(refusedCount)
        + " mark(s) cannot be applied; remove or fix them first."
    }
    alert.informativeText = text
    alert.addButton(withTitle: "Apply Redactions")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if document.applyPendingRedactionMarks() {
      errorMessage = nil
      refreshAll()
    } else {
      refreshAll()
    }
  }

  // MARK: Helpers

  static func number(_ value: Double) -> String {
    if value.rounded() == value { return String(Int(value)) }
    return String(format: "%.3f", value)
  }

  static func parseRect(
    _ x0: String, _ y0: String, _ x1: String, _ y1: String
  ) -> [Double]? {
    func parse(_ text: String) -> Double? {
      Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(
        of: ",", with: "."))
    }
    guard let a = parse(x0), let b = parse(y0), let c = parse(x1), let d = parse(y1),
      a.isFinite, b.isFinite, c.isFinite, d.isFinite, c > a, d > b
    else { return nil }
    return [a, b, c, d]
  }
}

// MARK: - Window controller

@MainActor
final class RedactionMarksPanelController: NSWindowController {
  let model: RedactionMarksPanelModel

  init(document: SPDFDocument, session: RedactionMarksSession) {
    let model = RedactionMarksPanelModel(document: document, session: session)
    self.model = model
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    panel.title = "Redaction Marks"
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 860, height: 560)
    panel.contentView = NSHostingView(rootView: RedactionMarksView(model: model))
    panel.center()
    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the redaction marks panel")
  }

  func refresh() {
    model.refreshAll()
  }

  func note(_ text: String) {
    model.note(text)
  }

  func prefillSearch(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    model.query = trimmed
    model.scope = .document
    model.runSearch()
  }
}

// MARK: - SwiftUI review panel

struct RedactionMarksView: View {
  @ObservedObject var model: RedactionMarksPanelModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        Divider()
        marksSection
        Divider()
        overlaySection
        Divider()
        applySection
        Divider()
        searchSection
      }
      .padding(18)
    }
    .frame(minWidth: 860, minHeight: 560)
    .accessibilityLabel("Redaction marks")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Redaction Marks").font(.title2.weight(.semibold))
        Spacer()
        Button("Close") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close redaction marks")
      }
      statusBanner
      Text(model.planStatus)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Redaction plan status")
      if let note = model.noteText {
        Label(note, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error = model.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Redaction error")
      }
    }
  }

  private var statusBanner: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: model.pendingCount > 0
        ? "exclamationmark.triangle.fill" : "checkmark.seal")
        .foregroundStyle(model.pendingCount > 0 ? Color.orange : Color.green)
      Text(model.statusDescription)
        .font(.callout.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      (model.pendingCount > 0 ? Color.orange : Color.green).opacity(0.12),
      in: RoundedRectangle(cornerRadius: 8))
    .accessibilityLabel("Redaction mark status")
  }

  private var marksSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Pending and applied marks").font(.headline)
      if model.markRows.isEmpty {
        Text("No marks yet. Select text, mark the current page, add a rectangle, or search below.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(model.markRows) { row in
        markRow(row)
        Divider()
      }
      HStack(spacing: 10) {
        Button("Mark Selection") { model.markCurrentSelection() }
          .help("Stage the current text selection as a pending redaction mark")
          .accessibilityLabel("Mark selection for redaction")
        Button("Mark Current Page") { model.markCurrentPage() }
          .accessibilityLabel("Mark current page for redaction")
        Spacer()
      }
      rectangleEditor
    }
  }

  private func markRow(_ row: RedactionMarksPanelModel.MarkRow) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(row.title).font(.callout.weight(.medium))
        Spacer()
        Text(row.status)
          .font(.caption2)
          .foregroundStyle(row.isPending ? Color.orange : Color.green)
      }
      Text(row.detail).font(.caption2).foregroundStyle(.secondary)
      if !row.overlayText.isEmpty {
        Text("Overlay: " + row.overlayText.joined(separator: " / "))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if !row.removalItems.isEmpty {
        Text(
          "Removes: " + row.removalItems.prefix(4).joined(separator: ", ")
            + (row.removalItems.count > 4 ? ", …" : ""))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let refusal = row.refusal {
        Text(refusal).font(.caption2).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if model.editingMarkID == row.id {
        editFields
      } else {
        HStack(spacing: 10) {
          Button("Show") { model.navigate(to: row.pageIndex) }
            .buttonStyle(.link)
          Button("Edit") { model.beginEditing(row) }
            .buttonStyle(.link)
            .disabled(!row.isEditable)
          Button("Remove") { model.removeMark(row) }
            .buttonStyle(.link)
          Spacer()
        }
        .font(.caption)
      }
    }
    .padding(.vertical, 2)
  }

  private var editFields: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        editField("x0", text: $model.editX0)
        editField("y0", text: $model.editY0)
        editField("x1", text: $model.editX1)
        editField("y1", text: $model.editY1)
      }
      TextField("Reason (optional)", text: $model.editReason)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
        .accessibilityLabel("Redaction mark reason")
      HStack {
        Button("Save") { model.commitEditing() }
          .buttonStyle(.borderedProminent)
        Button("Cancel") { model.cancelEditing() }
      }
      .font(.caption)
    }
    .padding(8)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
  }

  private func editField(_ label: String, text: Binding<String>) -> some View {
    HStack(spacing: 4) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      TextField(label, text: text)
        .textFieldStyle(.roundedBorder)
        .frame(width: 70)
        .accessibilityLabel("Redaction rectangle " + label)
    }
  }

  private var rectangleEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Add a rectangle region").font(.callout.weight(.medium))
      HStack(spacing: 8) {
        HStack(spacing: 4) {
          Text("page").font(.caption2).foregroundStyle(.secondary)
          TextField("1", text: $model.rectanglePage)
            .textFieldStyle(.roundedBorder)
            .frame(width: 46)
            .accessibilityLabel("Rectangle page number")
        }
        editField("x0", text: $model.rectangleX0)
        editField("y0", text: $model.rectangleY0)
        editField("x1", text: $model.rectangleX1)
        editField("y1", text: $model.rectangleY1)
        Button("Add Rectangle") { model.addRectangleMark() }
          .accessibilityLabel("Add rectangle redaction mark")
      }
      HStack(spacing: 8) {
        Text("Repeated pages:").font(.caption2).foregroundStyle(.secondary)
        TextField("1-3", text: $model.repeatedRegionPages)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
          .accessibilityLabel("Repeated region page range")
        Button("Add Repeated Region") { model.addRepeatedRegion() }
          .accessibilityLabel("Add repeated rectangle region")
      }
      Text("Coordinates are page space (points, origin bottom-left). The same rectangle is staged on every page in the range; one Apply covers them all.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var overlaySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Redaction overlay (paint only)").font(.headline)
      Text(
        "The marked content is removed whether or not an overlay is painted. The lines below are "
          + "exactly what Apply paints; the mark list shows the per-mark overlay text.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Toggle("Paint overlay", isOn: $model.overlayEnabled)
        Picker("Fill", selection: $model.overlayFillColor) {
          ForEach(Array(RedactionMarksPanelModel.overlayFillNames.enumerated()), id: \.offset) {
            index, name in
            Text(name).tag(index)
          }
        }
        .frame(width: 150)
        Picker("Text color", selection: $model.overlayTextColor) {
          ForEach(Array(RedactionMarksPanelModel.overlayTextNames.enumerated()), id: \.offset) {
            index, name in
            Text(name).tag(index)
          }
        }
        .frame(width: 150)
        HStack(spacing: 4) {
          Text("Size").font(.caption2).foregroundStyle(.secondary)
          TextField("9", text: $model.overlayFontSize)
            .textFieldStyle(.roundedBorder)
            .frame(width: 46)
            .accessibilityLabel("Overlay text size")
        }
      }
      HStack(spacing: 10) {
        TextField("Replacement text (optional)", text: $model.overlayReplacementText)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 240)
          .accessibilityLabel("Redaction replacement text")
        Picker("Reason code", selection: $model.overlayReasonChoice) {
          ForEach(
            Array(RedactionMarksPanelModel.overlayReasonChoices.enumerated()), id: \.offset
          ) { index, title in
            Text(title).tag(index)
          }
        }
        .frame(width: 190)
        if model.overlayReasonChoice == RedactionReasonCode.presets.count + 1 {
          TextField("Custom label", text: $model.overlayCustomReason)
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .accessibilityLabel("Custom reason code label")
        }
        Toggle("Paint reason label", isOn: $model.overlayShowsReasonCode)
      }
      HStack(spacing: 10) {
        Text(model.overlaySummary).font(.caption2).foregroundStyle(.secondary)
        Spacer()
        Button("Reset overlay to fill only") { model.resetOverlayToFillOnly() }
          .font(.caption)
      }
    }
  }

  private var applySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Apply").font(.headline)
      Text(model.planSummary).font(.caption.weight(.medium))
      Text(model.overlaySummary)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Picker("Hidden text policy", selection: $model.hiddenPolicy) {
        ForEach(RedactionHiddenTextPolicy.allCases, id: \.self) { policy in
          Text(policy.title).tag(policy)
        }
      }
      .frame(maxWidth: 460)
      .accessibilityLabel("Hidden text policy")
      ForEach(Array(model.disclosures.enumerated()), id: \.offset) { _, disclosure in
        Label(disclosure, systemImage: "info.circle")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button {
          model.applyMarks()
        } label: {
          Label(
            "Apply " + String(model.pendingCount) + " Pending Mark(s)",
            systemImage: "lock.doc")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(!model.canApply)
        .help(
          model.canApply
            ? "Remove the marked content as one undoable edit"
            : "No mark can be applied yet; review the refusals above.")
        .accessibilityLabel("Apply pending redaction marks")
        if model.refusedCount > 0 {
          Text(String(model.refusedCount) + " mark(s) refused — nothing will be applied until resolved.")
            .font(.caption2)
            .foregroundStyle(.red)
        }
        Spacer()
      }
    }
  }

  private var searchSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Search for text to redact").font(.headline)
      HStack(spacing: 10) {
        TextField("Words or phrases (one per line)", text: $model.query)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Redaction search words or phrases")
        Picker("Search scope", selection: $model.scope) {
          ForEach(RedactionSearchScope.allCases, id: \.self) { scope in
            Text(scope.title).tag(scope)
          }
        }
        .labelsHidden()
        .frame(width: 140)
        .accessibilityLabel("Redaction search scope")
        Button("Search") { model.runSearch() }
          .buttonStyle(.borderedProminent)
          .accessibilityLabel("Search for redaction matches")
      }
      HStack(spacing: 16) {
        Toggle("Match case", isOn: $model.matchCase)
        Toggle("Whole word", isOn: $model.wholeWord)
        Toggle("Include hidden/OCR text", isOn: $model.includeHiddenText)
        Spacer()
      }
      HStack(spacing: 8) {
        TextField("Pattern name", text: $model.patternName)
          .textFieldStyle(.roundedBorder)
          .frame(width: 170)
          .accessibilityLabel("Search pattern name")
        TextField("User-defined pattern (regular expression)", text: $model.patternExpression)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Redaction search pattern")
      }
      termSetEditor
      if let error = model.searchError {
        Text(error).font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Redaction search error")
      }
      if !model.searchSummary.isEmpty {
        Text(model.searchSummary).font(.caption.weight(.medium))
      }
      if !model.hitRows.isEmpty {
        HStack {
          Text("Review the actual matches, then select the ones to mark.")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Select All Markable") { model.selectAllMarkableHits() }
            .buttonStyle(.link)
          Button("Clear") { model.clearHitSelection() }
            .buttonStyle(.link)
          Button("Mark Selected Hits") { model.markSelectedHits() }
            .accessibilityLabel("Mark selected search matches")
        }
        .font(.caption)
        ForEach(model.hitRows) { row in
          hitRow(row)
        }
      }
    }
  }

  private func hitRow(_ row: RedactionMarksPanelModel.HitRow) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { row.isSelected },
          set: { _ in model.toggleHit(row) })) {
        EmptyView()
      }
      .labelsHidden()
      .disabled(!row.isEligible)
      .accessibilityLabel("Select match " + row.pageLabel)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(row.pageLabel).font(.caption2).foregroundStyle(.secondary)
          Text(row.context).font(.caption)
          if row.hidden {
            Text("hidden/OCR").font(.caption2)
              .padding(.horizontal, 4)
              .background(Color.purple.opacity(0.16), in: Capsule())
          }
        }
        Text(row.source).font(.caption2).foregroundStyle(.secondary)
        if let refusal = row.refusal {
          Text(refusal).font(.caption2).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
    }
    .padding(6)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  private var termSetEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        TextField("Term set name", text: $model.termSetName)
          .textFieldStyle(.roundedBorder)
          .frame(width: 190)
          .accessibilityLabel("Redaction term set name")
        Button("Save as Term Set") { model.saveCurrentTermSet() }
          .help("Save the words typed above as a reusable term set")
          .accessibilityLabel("Save redaction term set")
        Spacer()
      }
      if !model.savedSetNames.isEmpty {
        Text("Reusable term sets").font(.caption2).foregroundStyle(.secondary)
        ForEach(model.savedSetNames, id: \.self) { name in
          HStack(spacing: 8) {
            Toggle(
              name,
              isOn: Binding(
                get: { model.activeSetNames.contains(name) },
                set: { _ in model.toggleActiveSet(name) }))
              .accessibilityLabel("Use term set " + name)
            Spacer()
            Button("Delete") { model.deleteSavedSet(name) }
              .buttonStyle(.link)
              .accessibilityLabel("Delete term set " + name)
          }
          .font(.caption)
        }
      }
    }
  }
}
