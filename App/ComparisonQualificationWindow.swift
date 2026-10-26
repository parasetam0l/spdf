import AppKit
import PDFCore
import PDFEditing
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Local raster evidence (REV-06)

/// REV-06: page-pair raster evidence rendered locally through PDFKit. Each
/// side is rendered at its own page index (unlike a single-index overlay), so
/// different pairings are compared correctly, then normalized to one canvas.
enum ComparisonRasterEvidenceBuilder {
  static let defaultSize = NSSize(width: 400, height: 520)

  static func evidence(
    left: Data, right: Data, mapping: [PDFComparisonResult.PagePair], tolerance: Int,
    size: NSSize = defaultSize
  ) -> [ComparisonRasterEvidence] {
    guard let leftDocument = PDFDocument(data: left),
      let rightDocument = PDFDocument(data: right)
    else { return [] }
    var records: [ComparisonRasterEvidence] = []
    for pair in mapping {
      guard let leftIndex = pair.leftIndex, let rightIndex = pair.rightIndex,
        let leftBitmap = render(document: leftDocument, pageIndex: leftIndex, size: size),
        let rightBitmap = render(document: rightDocument, pageIndex: rightIndex, size: size),
        let ratio = changedRatio(left: leftBitmap, right: rightBitmap, tolerance: tolerance)
      else { continue }
      records.append(
        ComparisonRasterEvidence(
          leftPageIndex: leftIndex, rightPageIndex: rightIndex,
          changedPixelRatio: ratio, tolerance: tolerance,
          width: Int(size.width), height: Int(size.height)))
    }
    return records
  }

  static func render(
    document: PDFDocument, pageIndex: Int, size: NSSize
  ) -> NSBitmapImageRep? {
    guard let page = document.page(at: pageIndex) else { return nil }
    let width = max(1, Int(size.width))
    let height = max(1, Int(size.height))
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let thumbnail = page.thumbnail(of: size, for: .cropBox)
    let imageSize = thumbnail.size
    guard imageSize.width > 0, imageSize.height > 0 else {
      NSGraphicsContext.restoreGraphicsState()
      return nil
    }
    let scale = min(
      CGFloat(width) / imageSize.width, CGFloat(height) / imageSize.height)
    let drawWidth = imageSize.width * scale
    let drawHeight = imageSize.height * scale
    thumbnail.draw(
      in: NSRect(
        x: (CGFloat(width) - drawWidth) / 2,
        y: (CGFloat(height) - drawHeight) / 2,
        width: drawWidth, height: drawHeight))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  /// Fraction of pixels whose max channel difference exceeds the tolerance.
  static func changedRatio(
    left: NSBitmapImageRep, right: NSBitmapImageRep, tolerance: Int
  ) -> Double? {
    guard left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh,
      let leftData = left.bitmapData, let rightData = right.bitmapData,
      left.bytesPerRow == right.bytesPerRow
    else { return nil }
    let width = left.pixelsWide
    let height = left.pixelsHigh
    let samples = left.samplesPerPixel
    guard samples >= 3 else { return nil }
    var changed = 0
    for y in 0..<height {
      for x in 0..<width {
        let index = y * left.bytesPerRow + x * samples
        let red = abs(Int(leftData[index]) - Int(rightData[index]))
        let green = abs(Int(leftData[index + 1]) - Int(rightData[index + 1]))
        let blue = abs(Int(leftData[index + 2]) - Int(rightData[index + 2]))
        if max(red, max(green, blue)) > tolerance { changed += 1 }
      }
    }
    return Double(changed) / Double(width * height)
  }
}

// MARK: - REV-05/06 workspace model

@MainActor
final class ComparisonQualificationWorkspace: ObservableObject {
  enum CategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case content = "Content"
    case formatting = "Formatting"
    case rendering = "Rendering"
    case uncertainty = "Uncertainty"
    case documentStatus = "Document"

    var id: String { rawValue }
    var category: ComparisonChangeCategory? {
      switch self {
      case .all: return nil
      case .content: return .content
      case .formatting: return .formatting
      case .rendering: return .rendering
      case .uncertainty: return .uncertainty
      case .documentStatus: return .documentStatus
      }
    }
  }

  @Published private(set) var result: PDFComparisonResult
  @Published private(set) var qualification: ComparisonQualificationResult?
  @Published private(set) var audit: ComparisonAlignmentAudit?
  @Published private(set) var mapping: [PDFComparisonResult.PagePair]
  @Published private(set) var options: PDFComparisonOptions
  @Published var scopePreset: ComparisonScopePreset = .content
  @Published var categoryFilter: CategoryFilter = .all
  @Published var visualTolerance: Int
  @Published var selectedChangeIndex: Int?
  @Published var leftPageIndex = 0
  @Published var rightPageIndex = 0
  @Published var statusText: String?
  @Published var errorText: String?
  @Published private(set) var isWorking = false

  let leftDocument: PDFDocument
  let rightDocument: PDFDocument
  let leftName: String
  let rightName: String
  private let left: (graph: PDFGraph, source: Data)
  private let right: (graph: PDFGraph, source: Data)
  private let limits: PDFLimits
  private var mappingOverride: [PDFComparisonResult.PagePair]?

  init(
    left: (graph: PDFGraph, source: Data), right: (graph: PDFGraph, source: Data),
    leftName: String, rightName: String,
    options: PDFComparisonOptions = ComparisonScopePreset.content.options,
    limits: PDFLimits = PDFLimits()
  ) throws {
    self.left = left
    self.right = right
    self.leftName = leftName
    self.rightName = rightName
    self.options = options
    self.visualTolerance = options.visualTolerance
    self.limits = limits
    guard let leftDocument = PDFDocument(data: left.source),
      let rightDocument = PDFDocument(data: right.source)
    else {
      throw PDFError(.malformed, "The comparison documents could not be rendered")
    }
    self.leftDocument = leftDocument
    self.rightDocument = rightDocument
    let comparison = try PDFComparison.compare(
      left: left, right: right, options: options, limits: limits)
    self.result = comparison
    self.mapping = comparison.pageMapping
    if let preset = ComparisonScopePreset.matching(options) { scopePreset = preset }
    recomputeEvidenceAndAudit()
  }

  var documentSummary: String {
    "L: \(leftName) (\(leftDocument.pageCount) pages) / R: \(rightName) "
      + "(\(rightDocument.pageCount) pages)"
  }

  var changes: [PDFComparisonChange] {
    let source = qualification?.qualifiedChanges ?? result.changes
    guard let category = categoryFilter.category else { return source }
    return source.filter { $0.category == category }
  }

  var selectedChange: PDFComparisonChange? {
    guard let index = selectedChangeIndex, changes.indices.contains(index) else { return nil }
    return changes[index]
  }

  var auditWarnings: [String] { audit?.summaryLines ?? [] }

  var qualificationSummary: [String] { qualification?.summaryLines ?? [] }

  var pageEvidence: [ComparisonPageQualification] { qualification?.pages ?? [] }

  var unverifiedPairCount: Int { qualification?.pagesWithoutTextEvidence.count ?? 0 }

  var pageCountsAndRasterNote: String {
    var parts: [String] = []
    parts.append("\(mapping.count) page pair(s)")
    if unverifiedPairCount > 0 {
      parts.append("\(unverifiedPairCount) pair(s) without text evidence")
    }
    parts.append("raster tolerance \(visualTolerance)")
    return parts.joined(separator: " · ")
  }

  // MARK: Recompute

  func applyScopePreset(_ preset: ComparisonScopePreset) {
    scopePreset = preset
    options = preset.options
    recompare(resetMapping: true)
  }

  func toggleChannel(_ channel: ComparisonChannel) {
    var includeText = options.includeText
    var includeImages = options.includeImages
    var includeAnnotations = options.includeAnnotations
    var includeForms = options.includeForms
    var includeMetadata = options.includeMetadata
    var includeOCRText = options.includeOCRText
    var ignoreWhitespace = options.ignoreWhitespace
    switch channel {
    case .text: includeText.toggle()
    case .images: includeImages.toggle()
    case .annotations: includeAnnotations.toggle()
    case .forms: includeForms.toggle()
    case .metadata: includeMetadata.toggle()
    case .ocrText: includeOCRText.toggle()
    case .exactWhitespace: ignoreWhitespace.toggle()
    }
    options = PDFComparisonOptions(
      ignoreWhitespace: ignoreWhitespace, includeText: includeText,
      includeImages: includeImages, includeAnnotations: includeAnnotations,
      includeForms: includeForms, includeMetadata: includeMetadata,
      includeOCRText: includeOCRText, visualTolerance: visualTolerance)
    recompare(resetMapping: true)
  }

  func setVisualTolerance(_ tolerance: Int) {
    visualTolerance = min(32, max(0, tolerance))
    options = PDFComparisonOptions(
      ignoreWhitespace: options.ignoreWhitespace, includeText: options.includeText,
      includeImages: options.includeImages, includeAnnotations: options.includeAnnotations,
      includeForms: options.includeForms, includeMetadata: options.includeMetadata,
      includeOCRText: options.includeOCRText, visualTolerance: visualTolerance)
    requalify()
  }

  func recompare(resetMapping: Bool) {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      if resetMapping { mappingOverride = nil }
      let result = try PDFComparison.compare(
        left: left, right: right, options: options,
        mappingOverride: mappingOverride, limits: limits)
      self.result = result
      mapping = result.pageMapping
      if mappingOverride == nil { mappingOverride = nil }
      recomputeEvidenceAndAudit()
      clampSelection()
      statusText = nil
      errorText = nil
    } catch {
      errorText = error.localizedDescription
    }
  }

  func requalify() {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }
    recomputeEvidenceAndAudit()
    statusText = nil
    errorText = nil
  }

  private func recomputeEvidenceAndAudit() {
    let records = ComparisonRasterEvidenceBuilder.evidence(
      left: left.source, right: right.source, mapping: mapping,
      tolerance: 2)
    do {
      qualification = try PDFComparisonQualification.qualify(
        result: result, left: left, right: right, rasterEvidence: records,
        limits: limits)
    } catch {
      qualification = nil
      errorText = error.localizedDescription
    }
    do {
      audit = try PDFComparisonAlignment.audit(
        left: left, right: right, options: options, mappingOverride: mappingOverride,
        limits: limits)
    } catch {
      audit = nil
      errorText = error.localizedDescription
    }
  }

  // MARK: Mapping correction

  func correctMapping(leftIndex: Int, toRightIndex: Int?) {
    let corrected = PDFComparisonAlignment.correctedMapping(
      mapping, leftIndex: leftIndex, toRightIndex: toRightIndex)
    do {
      try PDFComparisonAlignment.validate(
        mapping: corrected, leftPageCount: leftDocument.pageCount,
        rightPageCount: rightDocument.pageCount)
      mappingOverride = corrected
      recompare(resetMapping: false)
    } catch {
      errorText = error.localizedDescription
    }
  }

  func resetMapping() {
    mappingOverride = nil
    recompare(resetMapping: true)
  }

  func useSuggestedMapping() {
    guard let suggested = audit?.suggestedMapping else { return }
    do {
      try PDFComparisonAlignment.validate(
        mapping: suggested, leftPageCount: leftDocument.pageCount,
        rightPageCount: rightDocument.pageCount)
      mappingOverride = suggested
      recompare(resetMapping: false)
    } catch {
      errorText = error.localizedDescription
    }
  }

  func rightIndex(forLeft index: Int) -> Int? {
    mapping.first { $0.leftIndex == index }?.rightIndex
  }

  func leftPageChanged(to index: Int) {
    leftPageIndex = index
    if let right = rightIndex(forLeft: index) { rightPageIndex = right }
  }

  func rightPageChanged(to index: Int) {
    rightPageIndex = index
    if let left = mapping.first(where: { $0.rightIndex == index })?.leftIndex {
      leftPageIndex = left
    }
  }

  // MARK: Change navigation

  func selectNextChange() {
    guard !changes.isEmpty else { return }
    selectedChangeIndex = min((selectedChangeIndex ?? -1) + 1, changes.count - 1)
    applySelectedChange()
  }

  func selectPreviousChange() {
    guard !changes.isEmpty else { return }
    selectedChangeIndex = max((selectedChangeIndex ?? changes.count) - 1, 0)
    applySelectedChange()
  }

  func selectChange(_ index: Int) {
    guard changes.indices.contains(index) else { return }
    selectedChangeIndex = index
    applySelectedChange()
  }

  private func applySelectedChange() {
    guard let change = selectedChange else { return }
    if let right = change.rightPageIndex { rightPageIndex = right }
    if let left = change.leftPageIndex { leftPageIndex = left }
  }

  private func clampSelection() {
    if let selected = selectedChangeIndex, selected >= changes.count {
      selectedChangeIndex = changes.isEmpty ? nil : changes.count - 1
    }
    leftPageIndex = min(max(0, leftPageIndex), max(0, leftDocument.pageCount - 1))
    rightPageIndex = min(max(0, rightPageIndex), max(0, rightDocument.pageCount - 1))
  }

  // MARK: Report

  func reportText() -> String {
    var text = PDFComparisonReport.text(result, options: options)
    text += "\nScope: " + options.scopeSummary + "\n"
    text += "\nAlignment audit:\n"
    text += (audit?.summaryLines ?? ["unavailable"]).map { "  " + $0 }.joined(separator: "\n")
    text += "\n\n"
    if let qualification {
      text += qualification.report
    } else {
      text += "Qualification unavailable.\n"
    }
    text += "\nCategories: "
      + ComparisonClassification.categories(in: result.changes)
        .map(\.title).joined(separator: ", ") + "\n"
    return text
  }
}

enum ComparisonChannel: String, CaseIterable, Identifiable {
  case text = "Text"
  case exactWhitespace = "Exact whitespace"
  case images = "Images"
  case annotations = "Annotations"
  case forms = "Form values"
  case metadata = "Metadata"
  case ocrText = "OCR text"

  var id: String { rawValue }
}

// MARK: - Channel helpers and view

extension ComparisonQualificationWorkspace {
  func channelIsOn(_ channel: ComparisonChannel) -> Bool {
    switch channel {
    case .text: return options.includeText
    case .exactWhitespace: return !options.ignoreWhitespace
    case .images: return options.includeImages
    case .annotations: return options.includeAnnotations
    case .forms: return options.includeForms
    case .metadata: return options.includeMetadata
    case .ocrText: return options.includeOCRText
    }
  }

  var scopeDetail: String { options.scopeSummary }
}

/// REV-05/REV-06: the comparison workspace window. Scope presets and channel
/// toggles re-run the comparison; the alignment audit exposes repeated-page
/// ambiguity with a suggested pairing; page evidence states text sources,
/// raster verdicts and preserved uncertainty.
struct ComparisonQualificationView: View {
  @ObservedObject var workspace: ComparisonQualificationWorkspace
  var onSaveReport: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let error = workspace.errorText {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
      }
      HSplitView {
        sidebar
          .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
        panes
          .frame(minWidth: 520)
      }
    }
    .frame(minWidth: 980, minHeight: 640)
    .accessibilityLabel("Comparison alignment and qualification")
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Picker(
        "Scope",
        selection: Binding(
          get: { workspace.scopePreset },
          set: { workspace.applyScopePreset($0) })
      ) {
        ForEach(ComparisonScopePreset.allCases, id: \.self) { preset in
          Text(preset.title).tag(preset)
        }
      }
      .frame(width: 220)
      .accessibilityLabel("Comparison scope preset")
      Menu("Channels") {
        ForEach(ComparisonChannel.allCases) { channel in
          Button {
            workspace.toggleChannel(channel)
          } label: {
            Text((workspace.channelIsOn(channel) ? "✓ " : "  ") + channel.rawValue)
          }
        }
      }
      .frame(width: 110)
      .accessibilityLabel("Comparison channels")
      Picker(
        "Show",
        selection: $workspace.categoryFilter
      ) {
        ForEach(ComparisonQualificationWorkspace.CategoryFilter.allCases) { filter in
          Text(filter.rawValue).tag(filter)
        }
      }
      .frame(width: 170)
      .accessibilityLabel("Change category filter")
      Divider().frame(height: 18)
      Button { workspace.selectPreviousChange() } label: {
        Label("Previous", systemImage: "chevron.left")
      }
      .disabled(workspace.changes.isEmpty)
      Button { workspace.selectNextChange() } label: {
        Label("Next", systemImage: "chevron.right")
      }
      .disabled(workspace.changes.isEmpty)
      Text(changeLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Text(workspace.pageCountsAndRasterNote)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Button("Reset Mapping") { workspace.resetMapping() }
        .font(.caption)
      Button("Use Suggested") { workspace.useSuggestedMapping() }
        .font(.caption)
      Button("Save Report…", action: onSaveReport)
        .font(.caption)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var changeLabel: String {
    if let index = workspace.selectedChangeIndex, let change = workspace.selectedChange {
      return "\(index + 1)/\(workspace.changes.count): \(change.kind.rawValue)"
    }
    return "\(workspace.changes.count) change(s)"
  }

  private var sidebar: some View {
    List {
      Section("Alignment") {
        if workspace.auditWarnings.isEmpty {
          Text("Automatic pairing only; no repeated-page ambiguity detected.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(workspace.auditWarnings.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.caption)
              .foregroundStyle(line.hasPrefix("Warning:") ? .orange : .secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        if workspace.audit?.isAmbiguous == true {
          Text(
            "Repeated page content is ambiguous. Pick the right page for a left page below, "
              + "or use the suggested pairing.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      Section("Page Mapping") {
        ForEach(Array(workspace.mapping.enumerated()), id: \.offset) { _, pair in
          if let leftIndex = pair.leftIndex {
            HStack {
              Text("L\(leftIndex + 1)")
                .font(.caption.monospaced())
              Picker(
                "maps to",
                selection: Binding(
                  get: { pair.rightIndex ?? -1 },
                  set: { newValue in
                    workspace.correctMapping(
                      leftIndex: leftIndex, toRightIndex: newValue < 0 ? nil : newValue)
                  })
              ) {
                Text("none").tag(-1)
                ForEach(0..<workspace.rightDocument.pageCount, id: \.self) { right in
                  Text("R\(right + 1)").tag(right)
                }
              }
              .labelsHidden()
              .font(.caption2)
              Text(pair.status.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          } else if let rightIndex = pair.rightIndex {
            Text("— maps to R\(rightIndex + 1) [inserted]")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      Section("Qualification") {
        ForEach(Array(workspace.qualificationSummary.enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(workspace.pageEvidence.enumerated()), id: \.offset) { _, page in
          Button {
            if let left = page.leftPageIndex { workspace.leftPageChanged(to: left) }
            if let right = page.rightPageIndex { workspace.rightPageChanged(to: right) }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(pageLabel(page))
                  .font(.caption2.monospaced())
                Text(page.verdict.rawValue)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(verdictColor(page.verdict))
                Spacer()
                if let ratio = page.changedPixelRatio {
                  Text(String(format: "%.2f%% px", ratio * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              Text(
                "text: \(page.leftTextSource.title) / \(page.rightTextSource.title); "
                  + "raster: \(page.rasterStatus.title)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .buttonStyle(.plain)
        }
      }
      Section("Changes") {
        ForEach(Array(workspace.changes.enumerated()), id: \.offset) { index, change in
          Button {
            workspace.selectChange(index)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(changeTitle(change))
                .font(.caption.weight(index == workspace.selectedChangeIndex ? .semibold : .regular))
              Text(change.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .buttonStyle(.plain)
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func pageLabel(_ page: ComparisonPageQualification) -> String {
    let left = page.leftPageIndex.map { "L\($0 + 1)" } ?? "—"
    let right = page.rightPageIndex.map { "R\($0 + 1)" } ?? "—"
    return "\(left)/\(right)"
  }

  private func verdictColor(_ verdict: ComparisonPageQualification.Verdict) -> Color {
    switch verdict {
    case .confirmedContentChange: return .red
    case .confirmedRenderingDifference: return .orange
    case .unconfirmedOCRChange, .visualChangeUnverified, .complexLayoutUncertain,
      .textUnavailable:
      return .yellow
    case .scanNoise, .noDifferenceWithTextEvidence, .unpaired: return .secondary
    }
  }

  private func changeTitle(_ change: PDFComparisonChange) -> String {
    let page = change.rightPageIndex.map { "R\($0 + 1)" }
      ?? change.leftPageIndex.map { "L\($0 + 1)" } ?? "document"
    return "\(page) · \(change.kind.rawValue) · \(change.category.title)"
      + (change.isOCRSourced ? " [OCR]" : "")
  }

  private var panes: some View {
    HStack(spacing: 1) {
      ComparisonPane(
        document: workspace.leftDocument, pageIndex: workspace.leftPageIndex,
        onPageChanged: { workspace.leftPageChanged(to: $0) })
      ComparisonPane(
        document: workspace.rightDocument, pageIndex: workspace.rightPageIndex,
        onPageChanged: { workspace.rightPageChanged(to: $0) })
    }
  }
}

// MARK: - Window controller and document route

@MainActor
final class ComparisonQualificationWindowController: NSWindowController {
  let workspace: ComparisonQualificationWorkspace

  init(window: NSWindow, workspace: ComparisonQualificationWorkspace) {
    self.workspace = workspace
    super.init(window: window)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for the comparison qualification window")
  }
}

extension SPDFDocument {
  var canOpenComparisonQualification: Bool { viewer != nil }

  /// REV-05/REV-06: open the qualified comparison workspace against another
  /// file. Comparison never merges or modifies either snapshot.
  @discardableResult
  func openComparisonQualificationWindow(with url: URL) throws -> ComparisonQualificationWorkspace {
    guard let source = sourceStore.snapshot(), let graph = editSession.currentGraph else {
      throw PDFError(.malformed, "The document has no editable graph")
    }
    let otherData = try SPDFDocumentResourcePolicy.readPDFData(at: url)
    let other = try PDFParser.parse(
      otherData, limits: SPDFDocumentResourcePolicy.parsingLimits)
    let workspace = try ComparisonQualificationWorkspace(
      left: (graph, source.data), right: (other.graph, otherData),
      leftName: fileURL?.lastPathComponent ?? "document",
      rightName: url.lastPathComponent,
      limits: SPDFDocumentResourcePolicy.parsingLimits)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = "Comparison Qualification — \(workspace.leftName) vs \(workspace.rightName)"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: ComparisonQualificationView(
        workspace: workspace,
        onSaveReport: { [weak self] in self?.saveComparisonQualificationReport() }))
    let controller = ComparisonQualificationWindowController(
      window: window, workspace: workspace)
    addWindowController(controller)
    window.center()
    controller.showWindow(nil)
    return workspace
  }

  func presentComparisonQualification() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.message = "Choose the PDF to compare against this document."
    panel.prompt = "Compare"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try openComparisonQualificationWindow(with: url)
    } catch {
      presentError(error)
    }
  }

  func saveComparisonQualificationReport() {
    guard
      let workspace = windowControllers
        .compactMap({ $0 as? ComparisonQualificationWindowController })
        .first?.workspace
    else { return }
    let panel = NSSavePanel()
    let base = fileURL?.deletingPathExtension().lastPathComponent ?? "document"
    panel.nameFieldStringValue = base + "-comparison-qualification.txt"
    panel.allowedContentTypes = [.plainText]
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try workspace.reportText().write(to: url, atomically: true, encoding: .utf8)
      } catch {
        self?.presentError(error)
      }
    }
  }
}
