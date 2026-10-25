import Foundation
import PDFCore

// MARK: - RED-01 pending redaction marks

/// What one pending redaction mark targets. Marks are staged in a review
/// store: they never alter the document graph or its saved bytes until the
/// user explicitly applies them through RedactMarksCommand.
public enum RedactionMarkKind: String, Sendable, Equatable, CaseIterable {
  /// Page-space rectangles reviewed from a text selection or a search hit.
  case text
  /// A user-drawn rectangle that removes everything the conservative region
  /// policy covers inside it.
  case region
  /// The whole page: its content is replaced by the redaction fill and every
  /// page-level representation is removed.
  case page

  public var title: String {
    switch self {
    case .text: return "Text"
    case .region: return "Rectangle region"
    case .page: return "Whole page"
    }
  }
}

/// One editable, unapplied redaction mark. The rectangles are page-space
/// bounds in the page's unrotated coordinate system (the same space
/// RedactRegionsCommand consumes).
public struct RedactionMark: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let pageID: PDFObjectID
  /// Zero-based page position at staging time, used for display and
  /// navigation. Apply resolves the page by identity, never by this index.
  public let pageIndex: Int
  public let kind: RedactionMarkKind
  /// Review geometry. Whole-page marks carry exactly one rectangle: the page
  /// box captured when the mark was staged.
  public var rects: [[Double]]
  /// Free-form reviewer note; never written to the PDF.
  public var reason: String?
  /// The reviewed match text (or selection text) for text marks.
  public var matchedText: String?
  /// Where the mark came from, e.g. "Selection" or "Term set Clients".
  public var sources: [String]
  /// True for a hidden (invisible text / generated OCR layer) match. Hidden
  /// marks never paint the visible fill.
  public var isHiddenText: Bool
  /// PAG-adjacent RED-04: true for an OCR/text mark whose visible pixels live
  /// in a scanned image draw. Applying it removes the whole intersecting image
  /// draw (disclosed in the plan), because removing only the hidden text layer
  /// would leave the raster pixels behind.
  public var removesRasterPaint: Bool

  public init(
    id: UUID = UUID(), pageID: PDFObjectID, pageIndex: Int, kind: RedactionMarkKind,
    rects: [[Double]], reason: String? = nil, matchedText: String? = nil,
    sources: [String] = [], isHiddenText: Bool = false,
    removesRasterPaint: Bool = false
  ) {
    self.id = id
    self.pageID = pageID
    self.pageIndex = pageIndex
    self.kind = kind
    self.rects = rects
    self.reason = reason
    self.matchedText = matchedText
    self.sources = sources
    self.isHiddenText = isHiddenText
    self.removesRasterPaint = removesRasterPaint
  }

  /// Union of the review rectangles, or nil when the geometry is invalid.
  public var bounds: [Double]? {
    guard let first = rects.first, first.count == 4 else { return nil }
    var result = first
    for rect in rects.dropFirst() where rect.count == 4 {
      result = [
        min(result[0], rect[0]), min(result[1], rect[1]),
        max(result[2], rect[2]), max(result[3], rect[3]),
      ]
    }
    return result
  }

  /// One-line review label: page, kind, reviewed text and reason.
  public var summary: String {
    var parts: [String] = ["Page \(pageIndex + 1)", kind.title]
    if let matchedText, !matchedText.isEmpty {
      let clipped = matchedText.count > 60 ? String(matchedText.prefix(57)) + "…" : matchedText
      parts.append("“\(clipped)”")
    }
    if isHiddenText { parts.append("hidden text") }
    if removesRasterPaint { parts.append("removes underlying scan") }
    if let reason, !reason.isEmpty { parts.append(reason) }
    return parts.joined(separator: " · ")
  }

  /// A short source label for the review list.
  public var sourceLabel: String {
    sources.isEmpty ? "Manual mark" : sources.joined(separator: ", ")
  }
}

/// The per-document review store of pending and applied redaction marks.
/// Staging, editing and removing marks is pure model work: no PDF graph is
/// touched until RedactMarksCommand is committed, so a saved document cannot
/// look "redacted" before the user applies the marks.
public struct RedactionMarkStore: Sendable, Equatable {
  public private(set) var marks: [RedactionMark] = []
  public private(set) var appliedMarkIDs: Set<UUID> = []

  public init() {}

  public var pendingMarks: [RedactionMark] {
    marks.filter { !appliedMarkIDs.contains($0.id) }
  }

  public var appliedMarks: [RedactionMark] {
    marks.filter { appliedMarkIDs.contains($0.id) }
  }

  public var pendingCount: Int { pendingMarks.count }
  public var appliedCount: Int { appliedMarks.count }
  public var hasUnappliedMarks: Bool { !pendingMarks.isEmpty }
  public var isEmpty: Bool { marks.isEmpty }

  /// True only while every staged mark has been applied and no later edit
  /// invalidated that record. Callers still disclose that saving is what makes
  /// the removal durable.
  public var reportsComplete: Bool { !marks.isEmpty && pendingMarks.isEmpty }

  /// The status string the review panel shows. It never claims secure removal
  /// while marks are unapplied.
  public var statusDescription: String {
    if marks.isEmpty { return "No redaction marks. Nothing has been removed." }
    if reportsComplete {
      return "Redaction applied (\(appliedMarks.count) mark(s)). Saving writes a verified full rewrite."
    }
    return
      "\(pendingMarks.count) pending redaction mark(s) — NOT applied. Nothing has been removed yet."
  }

  public func mark(withID id: UUID) -> RedactionMark? {
    marks.first { $0.id == id }
  }

  public func isApplied(_ id: UUID) -> Bool { appliedMarkIDs.contains(id) }

  public func pageIDs() -> [PDFObjectID] {
    var seen = Set<PDFObjectID>()
    var result: [PDFObjectID] = []
    for mark in marks where seen.insert(mark.pageID).inserted {
      result.append(mark.pageID)
    }
    return result
  }

  // MARK: Staging

  @discardableResult
  public mutating func add(
    kind: RedactionMarkKind, pageID: PDFObjectID, pageIndex: Int, rects: [[Double]],
    reason: String? = nil, matchedText: String? = nil, sources: [String] = [],
    isHiddenText: Bool = false, removesRasterPaint: Bool = false
  ) throws -> RedactionMark {
    guard pageIndex >= 0 else {
      throw PDFError(.malformed, "A redaction mark needs a non-negative page index")
    }
    try Self.validateRects(rects, kind: kind)
    let mark = RedactionMark(
      pageID: pageID, pageIndex: pageIndex, kind: kind, rects: rects, reason: reason,
      matchedText: matchedText, sources: sources, isHiddenText: isHiddenText,
      removesRasterPaint: removesRasterPaint)
    marks.append(mark)
    return mark
  }

  /// Edit a pending mark's geometry. Whole-page marks keep their page box;
  /// editing an applied mark makes it pending again so the panel cannot claim
  /// the new geometry is already removed.
  public mutating func updateGeometry(id: UUID, rects: [[Double]]) throws {
    guard let index = marks.firstIndex(where: { $0.id == id }) else {
      throw PDFError(.malformed, "The redaction mark is no longer staged")
    }
    guard marks[index].kind != .page else {
      throw PDFError(
        .unsupported,
        "A whole-page redaction mark covers the page box; remove it and stage a region instead")
    }
    try Self.validateRects(rects, kind: marks[index].kind)
    marks[index].rects = rects
    appliedMarkIDs.remove(id)
  }

  /// Edit the free-form reason/note. Does not change what is removed.
  public mutating func updateReason(id: UUID, reason: String?) {
    guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
    marks[index].reason = reason
  }

  public mutating func remove(id: UUID) {
    marks.removeAll { $0.id == id }
    appliedMarkIDs.remove(id)
  }

  public mutating func removeAll() {
    marks.removeAll()
    appliedMarkIDs.removeAll()
  }

  // MARK: Applied bookkeeping

  public mutating func noteApplied(_ ids: Set<UUID>) {
    let staged = Set(marks.map(\.id))
    appliedMarkIDs.formUnion(ids.intersection(staged))
  }

  /// An undo (or reload) invalidates the applied record: the marks are pending
  /// again and the panel must never report completion from stale bookkeeping.
  public mutating func noteUndone() {
    appliedMarkIDs.removeAll()
  }

  public mutating func noteAllPending() {
    appliedMarkIDs.removeAll()
  }

  static func validateRects(_ rects: [[Double]], kind: RedactionMarkKind) throws {
    guard !rects.isEmpty else {
      throw PDFError(.malformed, "A redaction mark needs at least one rectangle")
    }
    guard kind != .page || rects.count == 1 else {
      throw PDFError(.malformed, "A whole-page redaction mark needs exactly one page rectangle")
    }
    for rect in rects {
      guard rect.count == 4, rect.allSatisfy({ $0.isFinite }),
        rect[2] > rect[0], rect[3] > rect[1]
      else {
        throw PDFError(.malformed, "Redaction mark rectangles must be finite and non-empty")
      }
      guard rect.allSatisfy({ abs($0) <= 1e9 }) else {
        throw PDFError(
          .limitExceeded,
          "A redaction mark rectangle is outside the supported coordinate range")
      }
    }
  }
}

// MARK: - Application options

/// How hidden text on a page that carries redaction marks is handled. There is
/// deliberately no "retain" option: leaving a hidden copy behind would make a
/// redacted output unsafe.
public enum RedactionHiddenTextPolicy: String, Sendable, Equatable, CaseIterable {
  /// Remove the generated OCR layer and every invisible text run on each
  /// affected page. Disclosed in the plan before applying.
  case removeFromAffectedPages
  /// Refuse to apply on an affected page that carries hidden text, so the
  /// user can choose a different strategy instead of leaving a silent copy.
  case refuseWhenPresent

  public var title: String {
    switch self {
    case .removeFromAffectedPages: return "Remove hidden and OCR text on affected pages"
    case .refuseWhenPresent: return "Refuse when hidden or OCR text is present"
    }
  }

  public var disclosure: String {
    switch self {
    case .removeFromAffectedPages:
      return
        "Hidden text and generated OCR layers on affected pages are removed entirely, not only under the marks."
    case .refuseWhenPresent:
      return
        "Pages that carry hidden text or a generated OCR layer are refused instead of being applied partially."
    }
  }
}

/// What an apply run is allowed to do beyond removing the marked content.
public struct RedactionApplicationOptions: Sendable, Equatable {
  public var hiddenTextPolicy: RedactionHiddenTextPolicy
  public var fillColor: [Double]
  public var paintsFill: Bool

  public init(
    hiddenTextPolicy: RedactionHiddenTextPolicy = .removeFromAffectedPages,
    fillColor: [Double] = [0, 0, 0], paintsFill: Bool = true
  ) {
    self.hiddenTextPolicy = hiddenTextPolicy
    self.fillColor = fillColor
    self.paintsFill = paintsFill
  }
}

// MARK: - RED-01 review plan

/// One review entry in the pre-apply plan. The plan is computed without
/// mutating the graph; it tells the user what each pending mark will remove
/// and why a mark cannot be applied.
public struct RedactionMarkPlanEntry: Identifiable, Sendable, Equatable {
  public enum Status: Sendable, Equatable {
    case pending
    case applied
    /// The mark is on a page that also carries a whole-page mark; the page
    /// mark already removes everything this mark targets.
    case coveredByPageMark
    case refused(String)

    public var isReady: Bool {
      switch self {
      case .pending, .coveredByPageMark: return true
      case .applied, .refused: return false
      }
    }

    public var refusal: String? {
      if case .refused(let reason) = self { return reason }
      return nil
    }
  }

  public let id: UUID
  public let pageIndex: Int
  public let kind: RedactionMarkKind
  public let summary: String
  public let status: Status
  /// Approximate removal inventory, computed against the current graph.
  public let textRuns: Int
  public let hiddenTextRuns: Int
  public let annotations: Int
  public let formFields: Int
  public let images: Int
  public let paintsFill: Bool
  /// Extra review notes (for example "images and vector paint are retained").
  public let notes: [String]
  /// RED-03: exact overlay lines painted for this mark (empty when the overlay
  /// paints no text). The apply command paints exactly these lines.
  public let overlayText: [String]
  /// RED-04: short descriptions of the paint units this mark removes.
  public let removalItems: [String]

  public var refusal: String? { status.refusal }
  public var isReady: Bool { status.isReady }

  public init(
    id: UUID, pageIndex: Int, kind: RedactionMarkKind, summary: String, status: Status,
    textRuns: Int, hiddenTextRuns: Int, annotations: Int, formFields: Int, images: Int,
    paintsFill: Bool, notes: [String], overlayText: [String] = [],
    removalItems: [String] = []
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.kind = kind
    self.summary = summary
    self.status = status
    self.textRuns = textRuns
    self.hiddenTextRuns = hiddenTextRuns
    self.annotations = annotations
    self.formFields = formFields
    self.images = images
    self.paintsFill = paintsFill
    self.notes = notes
    self.overlayText = overlayText
    self.removalItems = removalItems
  }
}

/// A complete, non-mutating review of every staged mark.
public struct RedactionMarkPlan: Sendable, Equatable {
  public let entries: [RedactionMarkPlanEntry]
  public let options: RedactionApplicationOptions
  /// Pages whose hidden text/OCR layers the apply run will clear entirely.
  public let hiddenTextPageIndexes: [Int]
  public let disclosures: [String]
  /// RED-03: exactly what the apply run paints. Distinct from the removal: the
  /// overlay is paint only, and the marked content is removed regardless.
  public let overlay: RedactionOverlayOptions

  public var pendingCount: Int { entries.filter { $0.status == .pending }.count }
  public var appliedCount: Int { entries.filter { $0.status == .applied }.count }
  public var refusedCount: Int { entries.filter { $0.status.refusal != nil }.count }
  public var readyCount: Int { entries.filter(\.isReady).count }

  /// True when at least one pending mark can be applied and no staged mark is
  /// refused. Applied or page-covered marks alone are not something to apply.
  public var canApply: Bool { pendingCount > 0 && refusedCount == 0 }

  public var statusDescription: String {
    if entries.isEmpty { return "No redaction marks. Nothing has been removed." }
    if refusedCount > 0 {
      return
        "\(refusedCount) mark(s) cannot be applied — nothing has been removed by this plan. Resolve the refusals first."
    }
    if pendingCount == 0 && readyCount == 0 {
      return "Redaction applied. Saving writes a verified full rewrite."
    }
    return
      "\(pendingCount) pending redaction mark(s) — NOT applied. Nothing has been removed yet."
  }

  public var summary: String {
    if entries.isEmpty { return "No marks." }
    var parts: [String] = []
    parts.append("\(entries.count) mark(s)")
    if refusedCount > 0 { parts.append("\(refusedCount) refused") }
    if pendingCount > 0 { parts.append("\(pendingCount) pending") }
    if appliedCount > 0 { parts.append("\(appliedCount) applied") }
    return parts.joined(separator: ", ") + "."
  }

  public init(
    entries: [RedactionMarkPlanEntry], options: RedactionApplicationOptions,
    hiddenTextPageIndexes: [Int], disclosures: [String],
    overlay: RedactionOverlayOptions? = nil
  ) {
    self.entries = entries
    self.options = options
    self.hiddenTextPageIndexes = hiddenTextPageIndexes
    self.disclosures = disclosures
    self.overlay = overlay ?? RedactionOverlayOptions(applicationOptions: options)
  }

  /// The exact command the panel applies when the user confirms. Nil unless
  /// the plan can be applied.
  public func command(marks: [RedactionMark]) -> RedactMarksCommand? {
    guard canApply else { return nil }
    let pending = marks.filter { mark in
      entries.contains { $0.id == mark.id && $0.status == .pending }
    }
    guard !pending.isEmpty else { return nil }
    return RedactMarksCommand(marks: pending, options: options, overlay: overlay)
  }
}

/// Builds review plans by inventorying the current graph. Nothing here mutates
/// the document.
public enum RedactionMarkPlanner {
  public static func plan(
    store: RedactionMarkStore, graph: PDFGraph, pageIDs: [PDFObjectID],
    options: RedactionApplicationOptions = RedactionApplicationOptions(),
    overlay: RedactionOverlayOptions? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> RedactionMarkPlan {
    let overlay = overlay ?? RedactionOverlayOptions(applicationOptions: options)
    try overlay.validate()
    let resolver = try RedactionPageResolver(pageIDs: pageIDs, graph: graph)
    var entries: [RedactionMarkPlanEntry] = []
    var hiddenPages: Set<Int> = []
    for mark in store.marks {
      let applied = store.isApplied(mark.id)
      guard let pageIndex = resolver.index(of: mark.pageID) else {
        entries.append(
          RedactionMarkPlanEntry(
            id: mark.id, pageIndex: mark.pageIndex, kind: mark.kind, summary: mark.summary,
            status: .refused("The marked page is no longer in the document."),
            textRuns: 0, hiddenTextRuns: 0, annotations: 0, formFields: 0, images: 0,
            paintsFill: false, notes: []))
        continue
      }
      let hidden = try RedactionHiddenText.inventory(
        pageID: mark.pageID, in: graph, limits: limits)
      if hidden.hasHiddenText { hiddenPages.insert(pageIndex) }
      if applied {
        entries.append(
          RedactionMarkPlanEntry(
            id: mark.id, pageIndex: pageIndex, kind: mark.kind, summary: mark.summary,
            status: .applied, textRuns: 0, hiddenTextRuns: 0, annotations: 0, formFields: 0,
            images: 0, paintsFill: false, notes: []))
        continue
      }
      let pageMarks = store.marks.filter {
        $0.pageID == mark.pageID && $0.kind == .page && !store.isApplied($0.id)
      }
      if mark.kind != .page, !pageMarks.isEmpty {
        entries.append(
          RedactionMarkPlanEntry(
            id: mark.id, pageIndex: pageIndex, kind: mark.kind, summary: mark.summary,
            status: .coveredByPageMark, textRuns: 0, hiddenTextRuns: 0, annotations: 0,
            formFields: 0, images: 0, paintsFill: false,
            notes: ["Covered by the whole-page mark on this page."]))
        continue
      }
      entries.append(
        try entry(
          for: mark, pageIndex: pageIndex, graph: graph, options: options, overlay: overlay,
          limits: limits, hidden: hidden))
    }
    var disclosures: [String] = []
    disclosures.append("Nothing has been removed or saved until you apply these marks.")
    if options.paintsFill {
      disclosures.append(
        "Applying paints the redaction fill over visible review geometry; text marks remove only the reviewed glyphs.")
    }
    disclosures.append(options.hiddenTextPolicy.disclosure)
    if !hiddenPages.isEmpty, options.hiddenTextPolicy == .removeFromAffectedPages {
      let labels = hiddenPages.sorted().map { "page \($0 + 1)" }.joined(separator: ", ")
      disclosures.append("Hidden or OCR text layers will be removed entirely on \(labels).")
    }
    if options.hiddenTextPolicy == .refuseWhenPresent, !hiddenPages.isEmpty {
      let labels = hiddenPages.sorted().map { "page \($0 + 1)" }.joined(separator: ", ")
      disclosures.append("Apply is refused because hidden text is present on \(labels).")
    }
    disclosures.append(
      "Region marks use the broadened RED-04 paint profile: whole intersecting image draws "
        + "(including scanned and masked images), whole reusable-form invocations covered by one "
        + "region and fully covered vector paint are removed; partial form/vector intersections, "
        + "inline images, gradient shading and tiling patterns refuse instead of leaving partial "
        + "paint. Text marks remove only the reviewed glyphs and leave unrelated paint untouched "
        + "unless the mark explicitly removes an underlying scan.")
    disclosures.append(
      "Removal and overlay paint are separate operations: the marked content is removed whether "
        + "or not an overlay is painted, and the overlay lines listed for each mark are exactly "
        + "what apply paints.")
    disclosures.append(overlay.summary)
    if overlay.paintsText {
      let lines = overlay.reviewLines
      if !lines.isEmpty {
        disclosures.append("Overlay text: \"" + lines.joined(separator: "\" / \"") + "\".")
      }
    }
    disclosures.append(
      "Saving writes a verified full rewrite with no earlier revisions; removed image and form "
        + "objects become unreachable and are pruned.")
    return RedactionMarkPlan(
      entries: entries, options: options, hiddenTextPageIndexes: hiddenPages.sorted(),
      disclosures: disclosures, overlay: overlay)
  }

  private static func entry(
    for mark: RedactionMark, pageIndex: Int, graph: PDFGraph,
    options: RedactionApplicationOptions, overlay: RedactionOverlayOptions,
    limits: PDFLimits, hidden: RedactionHiddenTextInventory
  ) throws -> RedactionMarkPlanEntry {
    var notes: [String] = []
    var textRuns = 0
    var hiddenRuns = 0
    var annotations = 0
    var formFields = 0
    var images = 0
    var paintsFill = false
    var removalItems: [String] = []
    var status: RedactionMarkPlanEntry.Status = .pending
    switch mark.kind {
    case .page:
      do {
        try RedactionWholePage.validate(
          pageID: mark.pageID, rect: mark.rects[0], in: graph, limits: limits)
        if options.hiddenTextPolicy == .refuseWhenPresent, hidden.hasHiddenText {
          throw PDFError(
            .unsupported,
            "This page carries hidden or OCR text and the policy refuses to apply without removing it")
        }
        let layout = try PageTextLayout.build(pageID: mark.pageID, in: graph, limits: limits)
        textRuns = Set(layout.clusters.map(\.runIndex)).count
        hiddenRuns = hidden.hiddenRunCount
        annotations = try AnnotationInventory.annotations(in: graph, pageID: mark.pageID).count
        formFields = try pageFieldCount(pageID: mark.pageID, in: graph)
        let placements = try ImageInventory.placements(in: graph, pageID: mark.pageID)
        images = placements.count
        paintsFill = overlay.paintsOverlay
        notes.append(
          "The whole page is replaced by the redaction paint; page annotations and widgets are removed.")
        if !placements.isEmpty {
          notes.append("Page images and vector paint are removed with the page content.")
        }
      } catch {
        status = .refused(error.localizedDescription)
      }
    case .region:
      do {
        // RED-04: the broadened paint profile (whole image draws incl. masks and
        // scans, whole covered form invocations, fully covered vector paths).
        let command = RedactPaintRegionsCommand(pageID: mark.pageID, regions: mark.rects)
        try command.validate(in: graph)
        if options.hiddenTextPolicy == .refuseWhenPresent, hidden.hasHiddenText {
          throw PDFError(
            .unsupported,
            "This page carries hidden or OCR text and the policy refuses to apply without removing it")
        }
        let analysis = try RedactionPaintAnalyzer.analyze(
          pageID: mark.pageID, regions: mark.rects, graph: graph, limits: limits)
        textRuns = analysis.textRunIndices.count
        hiddenRuns = hidden.hiddenRunCount
        annotations = try AnnotationInventory.annotations(in: graph, pageID: mark.pageID)
          .filter { annotation in
            annotation.subtype != PDFName("Widget")
              && (annotation.bounds.map {
                RedactRegionsCommand.intersects($0, anyRegion: mark.rects)
              } ?? false)
          }.count
        formFields = try pageFieldCount(
          pageID: mark.pageID, in: graph, regions: mark.rects)
        images = analysis.imageCount + analysis.formCount
        paintsFill = overlay.paintsOverlay
        removalItems = analysis.items.filter(\.isRemovable).map(\.description)
        notes.append("Region policy: " + analysis.summary)
        if !analysis.disclosures.isEmpty {
          notes.append(contentsOf: analysis.disclosures.prefix(2))
        }
      } catch {
        status = .refused(error.localizedDescription)
      }
    case .text:
      do {
        let analysis = try RedactionTextPrecision.analyze(
          pageID: mark.pageID, rects: mark.rects, hiddenOnly: mark.isHiddenText,
          in: graph, limits: limits)
        if mark.isHiddenText, analysis.removedClusterCount == 0 {
          throw PDFError(
            .unsupported,
            "No hidden text was found under the reviewed geometry; re-run the search review.")
        }
        if options.hiddenTextPolicy == .refuseWhenPresent, hidden.hasHiddenText {
          throw PDFError(
            .unsupported,
            "This page carries hidden or OCR text and the policy refuses to apply without removing it")
        }
        textRuns = analysis.runCount
        hiddenRuns = hidden.hiddenRunCount
        annotations = try AnnotationInventory.annotations(in: graph, pageID: mark.pageID)
          .filter { annotation in
            annotation.subtype != PDFName("Widget")
              && (annotation.bounds.map {
                RedactRegionsCommand.intersects($0, anyRegion: mark.rects)
              } ?? false)
          }.count
        formFields = try pageFieldCount(
          pageID: mark.pageID, in: graph, regions: mark.rects)
        paintsFill = overlay.paintsOverlay && !mark.isHiddenText
        notes.append("Only the reviewed glyphs are removed; surrounding text keeps its position.")
        notes.append("Unrelated images and vector paint are retained.")
        if mark.removesRasterPaint {
          // RED-04: OCR/text over a scan removes the whole intersecting image
          // draw, because removing only the hidden text layer leaves the
          // visible pixels. Disclosed before apply.
          let raster = try RedactionPaintAnalyzer.imageDraws(
            pageID: mark.pageID, regions: mark.rects, graph: graph, limits: limits)
          if !raster.refusals.isEmpty {
            throw PDFError(.unsupported, raster.refusals.joined(separator: " "))
          }
          if raster.imageCount > 0 {
            images += raster.imageCount
            removalItems.append(
              contentsOf: raster.items.filter(\.isRemovable).map(\.description))
            notes.append(
              "The reviewed text sits over a scan: the whole intersecting image draw is removed "
                + "so the raster pixels do not retain the text.")
          } else {
            notes.append("No intersecting scanned image was found; only the text layer is removed.")
          }
        }
      } catch {
        status = .refused(error.localizedDescription)
      }
    }
    if status.refusal != nil { paintsFill = false }
    // RED-03: the reviewed overlay must be exactly paintable before apply.
    let overlayText = (status == .pending && !mark.isHiddenText)
      ? overlay.lines(for: mark) : []
    if status == .pending, !mark.isHiddenText, paintsFill, overlay.paintsText {
      do {
        try RedactionOverlayPainter.validate(
          mark: mark, options: overlay, pageID: mark.pageID, in: graph, limits: limits)
      } catch {
        status = .refused(error.localizedDescription)
        paintsFill = false
      }
    }
    if status.refusal != nil { paintsFill = false }
    return RedactionMarkPlanEntry(
      id: mark.id, pageIndex: pageIndex, kind: mark.kind, summary: mark.summary,
      status: status, textRuns: textRuns, hiddenTextRuns: hiddenRuns,
      annotations: annotations, formFields: formFields, images: images,
      paintsFill: paintsFill, notes: notes, overlayText: overlayText,
      removalItems: removalItems)
  }

  private static func pageFieldCount(
    pageID: PDFObjectID, in graph: PDFGraph, regions: [[Double]]? = nil
  ) throws -> Int {
    let pageIDs = try PageTreeView(graph: graph).pages
    guard let pageIndex = pageIDs.firstIndex(of: pageID) else { return 0 }
    let fields = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    return fields.filter { field in
      field.widgets.contains { widget in
        guard widget.pageIndex == pageIndex else { return false }
        guard let regions else { return true }
        return widget.rect.map { RedactRegionsCommand.intersects($0, anyRegion: regions) } ?? false
      }
    }.count
  }
}

// MARK: - Page resolution

/// Resolves page identities against the current graph. Apply resolves pages by
/// identity, so a mark never silently lands on a different page after a page
/// reorder/delete.
struct RedactionPageResolver {
  private let indexes: [PDFObjectID: Int]

  init(pageIDs: [PDFObjectID], graph: PDFGraph) throws {
    let current = try PageTreeView(graph: graph).pages
    var indexes: [PDFObjectID: Int] = [:]
    for (index, id) in current.enumerated() { indexes[id] = index }
    self.indexes = indexes
  }

  func index(of pageID: PDFObjectID) -> Int? { indexes[pageID] }
}
