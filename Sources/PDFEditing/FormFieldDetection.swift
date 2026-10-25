import Foundation
import PDFCore

// FRM-01: automatic field detection with review.
//
// Detection is advisory. It reads only text that already exists in the PDF
// (digital page text, and recognized text where a generated OCR layer exists)
// plus simple painted box/circle geometry, and returns proposals carrying a
// confidence, the evidence used, warnings, and an explicit eligibility result.
// Nothing here creates a field: the caller must accept proposals explicitly and
// commit them through FormFieldDetectionReview.makePlan(in:).

/// FRM-01: where a detected text observation came from.
public enum FormDetectionTextSource: Sendable, Equatable {
  /// Text drawn by the document itself.
  case documentText
  /// Text drawn by an sPDF-generated searchable OCR layer. The confidence is
  /// the recognizer's own value when a caller supplies it; layer text written
  /// earlier does not store per-line confidence, so it may be nil.
  case recognizedText(confidence: Double?)

  public var isRecognized: Bool {
    if case .recognizedText = self { return true }
    return false
  }

  public var recognizedConfidence: Double? {
    if case .recognizedText(let confidence) = self { return confidence }
    return nil
  }

  public var label: String {
    switch self {
    case .documentText: return "Document text"
    case .recognizedText(let confidence):
      if let confidence {
        return "Recognized text (confidence " + String(format: "%.0f%%", confidence * 100) + ")"
      }
      return "Recognized text (no stored confidence)"
    }
  }
}

/// FRM-01: one positioned text line used as detection evidence.
public struct FormDetectionTextLine: Sendable, Equatable {
  public let text: String
  /// Page-space rectangle [x0, y0, x1, y1] (unrotated page coordinates).
  public let rect: [Double]
  public let source: FormDetectionTextSource

  public init(text: String, rect: [Double], source: FormDetectionTextSource) {
    self.text = text
    self.rect = rect
    self.source = source
  }
}

/// FRM-01: one simple painted shape used as field geometry evidence.
public struct FormDetectionShape: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case rectangle
    case ellipse
  }

  public let kind: Kind
  /// Page-space bounds [x0, y0, x1, y1].
  public let rect: [Double]

  public init(kind: Kind, rect: [Double]) {
    self.kind = kind
    self.rect = rect
  }

  public var width: Double { rect[2] - rect[0] }
  public var height: Double { rect[3] - rect[1] }
  public var isNearSquare: Bool {
    let side = min(width, height)
    guard side > 0 else { return false }
    return max(width, height) / side <= 1.7
  }
}

/// FRM-01: the field kinds detection can propose.
public enum FormDetectedFieldKind: String, Sendable, Equatable, Hashable, CaseIterable {
  case text
  case checkbox
  case radio

  public var label: String {
    switch self {
    case .text: return "Text field"
    case .checkbox: return "Checkbox"
    case .radio: return "Radio group"
    }
  }
}

/// FRM-01: detection policy. Thresholds are explicit so the review UI can show
/// exactly why a proposal is refused.
public struct FormDetectionOptions: Sendable, Equatable {
  /// Recognized text below this confidence is refused rather than proposed.
  public var minimumConfidence: Double = 0.6
  /// Smallest accepted widget edge in points.
  public var minimumWidgetSize: Double = 8
  /// Candidate labels longer than this are treated as prose, not field labels.
  public var maximumLabelLength: Int = 80
  /// OCR layer text without stored confidence is weighted as this value.
  public var unverifiedOCRLayerConfidence: Double = 0.75

  public init() {}
}

/// FRM-01: one reviewable proposal. A candidate is a proposal only: it is not a
/// field until the reviewer accepts it and the plan is committed.
public struct FormFieldCandidate: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let pageIndex: Int
  public let pageID: PDFObjectID?
  public let pageBounds: [Double]
  public let kind: FormDetectedFieldKind
  /// One rectangle for text/checkbox, one per radio option for radio groups.
  public let rects: [[Double]]
  public let suggestedName: String
  public let label: String?
  /// Radio group export values in widget order; empty for other kinds.
  public let exportValues: [String]
  public let confidence: Double
  public let source: FormDetectionTextSource?
  public let evidence: [String]
  public let warnings: [String]
  /// nil when the proposal is eligible; otherwise why it must not be committed.
  public let refusalReason: String?

  public init(
    id: UUID = UUID(), pageIndex: Int, pageID: PDFObjectID?, pageBounds: [Double],
    kind: FormDetectedFieldKind, rects: [[Double]], suggestedName: String, label: String?,
    exportValues: [String] = [], confidence: Double, source: FormDetectionTextSource?,
    evidence: [String], warnings: [String] = [], refusalReason: String? = nil
  ) {
    self.id = id
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.pageBounds = pageBounds
    self.kind = kind
    self.rects = rects
    self.suggestedName = suggestedName
    self.label = label
    self.exportValues = exportValues
    self.confidence = confidence
    self.source = source
    self.evidence = evidence
    self.warnings = warnings
    self.refusalReason = refusalReason
  }

  public var isEligible: Bool { refusalReason == nil }
  public var primaryRect: [Double] { rects.first ?? [0, 0, 0, 0] }

  public var confidenceLabel: String {
    String(format: "%.0f%%", confidence * 100)
  }
}

/// FRM-01: what detection found on one page, including why it could not read a
/// page at all.
public struct FormDetectionPageReport: Sendable, Equatable {
  public let pageIndex: Int
  public let pageID: PDFObjectID?
  public let textLineCount: Int
  public let recognizedLineCount: Int
  public let shapeCount: Int
  public let hasOCRTextLayer: Bool
  /// Non-nil when the page has no text evidence to detect from.
  public let refusalReason: String?

  public init(
    pageIndex: Int, pageID: PDFObjectID?, textLineCount: Int, recognizedLineCount: Int,
    shapeCount: Int, hasOCRTextLayer: Bool, refusalReason: String?
  ) {
    self.pageIndex = pageIndex
    self.pageID = pageID
    self.textLineCount = textLineCount
    self.recognizedLineCount = recognizedLineCount
    self.shapeCount = shapeCount
    self.hasOCRTextLayer = hasOCRTextLayer
    self.refusalReason = refusalReason
  }

  public var isDetectable: Bool { refusalReason == nil }
  public var hasDocumentText: Bool { textLineCount > recognizedLineCount }
  public var hasRecognizedText: Bool { recognizedLineCount > 0 }
}

/// FRM-01: the full set of proposals for a document or page range.
public struct FormDetectionReport: Sendable, Equatable {
  public let pages: [FormDetectionPageReport]
  public let candidates: [FormFieldCandidate]

  public init(pages: [FormDetectionPageReport], candidates: [FormFieldCandidate]) {
    self.pages = pages
    self.candidates = candidates
  }

  public var eligibleCandidates: [FormFieldCandidate] { candidates.filter(\.isEligible) }
  public var refusedCandidates: [FormFieldCandidate] { candidates.filter { !$0.isEligible } }
  public var isEmpty: Bool { candidates.isEmpty }

  public func candidates(forPage pageIndex: Int) -> [FormFieldCandidate] {
    candidates.filter { $0.pageIndex == pageIndex }
  }

  public var summary: String {
    let eligible = eligibleCandidates.count
    let refused = refusedCandidates.count
    if candidates.isEmpty {
      let unreadable = pages.filter { !$0.isDetectable }.count
      if unreadable == pages.count, !pages.isEmpty {
        return "No page supplied text that field detection can read. No fields were created."
      }
      return "No likely fields were found. No fields were created."
    }
    var text = String(eligible) + " proposal" + (eligible == 1 ? "" : "s") + " ready for review"
    if refused > 0 { text += ", " + String(refused) + " refused" }
    return text + ". Nothing is created until you accept proposals and choose Create Fields."
  }
}

// MARK: - Detection

public enum FormFieldDetection {
  // MARK: Graph-backed entry points

  /// Detect on one page of a graph.
  public static func detect(
    pageIndex: Int, pageID: PDFObjectID, in graph: PDFGraph,
    existingFields: [FormField]? = nil, options: FormDetectionOptions = FormDetectionOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> (report: FormDetectionPageReport, candidates: [FormFieldCandidate]) {
    let lines = try extractTextLines(pageID: pageID, in: graph, limits: limits)
    let shapes = try extractShapes(pageID: pageID, in: graph, limits: limits)
    let bounds = pageBounds(pageID: pageID, in: graph)
    let hasLayer = OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID)
    if lines.isEmpty, !OCRLayer.pageShowsText(pageID, in: graph) {
      let page = FormDetectionPageReport(
        pageIndex: pageIndex, pageID: pageID, textLineCount: 0, recognizedLineCount: 0,
        shapeCount: shapes.count, hasOCRTextLayer: hasLayer,
        refusalReason:
          "This page has no text and no OCR text layer. Field detection reads only text that "
          + "already exists; run Recognize Text on the scan, then detect fields again.")
      return (page, [])
    }
    if lines.isEmpty {
      let page = FormDetectionPageReport(
        pageIndex: pageIndex, pageID: pageID, textLineCount: 0, recognizedLineCount: 0,
        shapeCount: shapes.count, hasOCRTextLayer: hasLayer,
        refusalReason:
          "Text on this page uses fonts or transforms outside the detection profile, so no "
          + "label evidence could be read. No proposals were made.")
      return (page, [])
    }
    let existing = existingFields ?? (try? FormInventory.fields(
      in: graph, pageIDs: PageTreeView(graph: graph).pages)) ?? []
    let outcome = pureDetection(
      pageIndex: pageIndex, pageID: pageID, pageBounds: bounds, textLines: lines,
      shapes: shapes, existingFields: existing, options: options, hasOCRTextLayer: hasLayer)
    return outcome
  }

  /// Detect across the document. Pages are processed in order; names stay
  /// unique across pages.
  public static func detectDocument(
    in graph: PDFGraph, pageIDs: [PDFObjectID], existingFields: [FormField]? = nil,
    options: FormDetectionOptions = FormDetectionOptions(), limits: PDFLimits = PDFLimits()
  ) throws -> FormDetectionReport {
    let existing = existingFields ?? ((try? FormInventory.fields(in: graph, pageIDs: pageIDs)) ?? [])
    var pages: [FormDetectionPageReport] = []
    var candidates: [FormFieldCandidate] = []
    for (index, pageID) in pageIDs.enumerated() {
      let outcome = try detect(
        pageIndex: index, pageID: pageID, in: graph, existingFields: existing, options: options,
        limits: limits)
      pages.append(outcome.report)
      candidates.append(contentsOf: outcome.candidates)
    }
    // Cross-page names: the per-page pass only knows the document's existing
    // names, so proposals on later pages can repeat an earlier proposal's name.
    var used = Set(existing.map(\.name))
    var renamed: [FormFieldCandidate] = []
    for candidate in candidates where candidate.isEligible {
      let unique = uniqueName(candidate.suggestedName, used: used)
      used.insert(unique)
      if unique == candidate.suggestedName {
        renamed.append(candidate)
      } else {
        renamed.append(
          FormFieldCandidate(
            id: candidate.id, pageIndex: candidate.pageIndex, pageID: candidate.pageID,
            pageBounds: candidate.pageBounds, kind: candidate.kind, rects: candidate.rects,
            suggestedName: unique, label: candidate.label,
            exportValues: candidate.exportValues, confidence: candidate.confidence,
            source: candidate.source, evidence: candidate.evidence,
            warnings: candidate.warnings
              + ["Another proposal already used this name; this name adds a suffix."],
            refusalReason: candidate.refusalReason))
      }
    }
    let refused = candidates.filter { !$0.isEligible }
    return FormDetectionReport(pages: pages, candidates: renamed + refused)
  }

  // MARK: Pure entry point (testable without a graph)

  /// Pure detection over already-extracted evidence.
  public static func pureDetection(
    pageIndex: Int, pageID: PDFObjectID?, pageBounds: [Double],
    textLines: [FormDetectionTextLine], shapes: [FormDetectionShape],
    existingFields: [FormField], options: FormDetectionOptions = FormDetectionOptions(),
    hasOCRTextLayer: Bool = false
  ) -> (report: FormDetectionPageReport, candidates: [FormFieldCandidate]) {
    let existingNames = Set(existingFields.map(\.name))
    var usedNames = existingNames
    let existingWidgets = existingFields.flatMap { field -> [(name: String, rect: [Double])] in
      field.widgets.compactMap { widget in
        guard let rect = widget.rect else { return nil }
        return (field.name, rect)
      }
    }
    var candidates: [FormFieldCandidate] = []

    func makeCandidate(
      kind: FormDetectedFieldKind, rects: [[Double]], label: String?,
      exportValues: [String] = [], confidence: Double, source: FormDetectionTextSource?,
      evidence: [String], warnings: [String]
    ) -> FormFieldCandidate {
      let cleanRects = rects.map(normalize)
      let labelTrimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
      let labelValue = (labelTrimmed?.isEmpty ?? true) ? nil : labelTrimmed
      var notes = warnings
      let base = suggestedName(label: labelValue, kind: kind, index: candidates.count + 1)
      let unique = uniqueName(base, used: usedNames)
      if unique != base {
        notes.append("Field name " + base + " is already used; proposing " + unique + ".")
      }
      usedNames.insert(unique)
      var refusal = refusalReason(
        kind: kind, rects: cleanRects, pageBounds: pageBounds, options: options,
        source: source, label: labelValue)
      if refusal == nil,
        let overlap = overlappingExistingField(rects: cleanRects, existing: existingWidgets)
      {
        refusal = "This area overlaps the existing field " + overlap + "."
      }
      if refusal == nil, labelValue == nil, kind == .text {
        notes.append("No on-page label was found; the field tooltip will be empty until you add one.")
      }
      if refusal == nil, kind == .text, cleanRects.first.map({ $0[2] - $0[0] }) ?? 0 < 24 {
        refusal = "The proposed text area is narrower than 24 points; draw it manually instead."
      }
      if case .recognizedText(let confidence)? = source, let confidence,
        confidence < options.minimumConfidence
      {
        refusal = "Recognized text confidence "
          + String(format: "%.0f%%", confidence * 100)
          + " is below the " + String(format: "%.0f%%", options.minimumConfidence * 100)
          + " threshold; verify the wording with OCR review first."
      }
      return FormFieldCandidate(
        pageIndex: pageIndex, pageID: pageID, pageBounds: pageBounds, kind: kind,
        rects: cleanRects, suggestedName: unique, label: labelValue,
        exportValues: exportValues, confidence: min(max(confidence, 0.05), 0.99),
        source: source, evidence: evidence, warnings: notes, refusalReason: refusal)
    }

    // 1. Text-field proposals from label and placeholder patterns.
    for line in textLines {
      for proposal in textFieldProposals(in: line, allLines: textLines, options: options) {
        candidates.append(
          makeCandidate(
            kind: .text, rects: [proposal.rect], label: proposal.label,
            confidence: proposal.confidence, source: line.source,
            evidence: proposal.evidence, warnings: proposal.warnings))
      }
    }

    // 2. Checkbox/radio proposals from painted box or circle geometry.
    for group in groupShapes(shapes, options: options) {
      if group.kind == .ellipse, group.shapes.count >= 2 {
        let labels = group.shapes.map { nearestLabel(to: $0.rect, lines: textLines) }
        let groupLabel = groupLabel(lines: textLines, shapes: group.shapes, options: options)
        let exportValues = labels.enumerated().map { index, label in
          exportValue(from: label?.text, fallbackIndex: index + 1)
        }
        var notes: [String] = []
        if labels.allSatisfy({ $0 == nil }) {
          notes.append("No option labels were found; export values default to Option1 to OptionN.")
        }
        candidates.append(
          makeCandidate(
            kind: .radio, rects: group.shapes.map(\.rect), label: groupLabel,
            exportValues: uniqueExportValues(exportValues),
            confidence: min(0.95, 0.74 + Double(min(group.shapes.count, 3)) * 0.04),
            source: labels.compactMap(\.self).first?.source,
            evidence: ["painted circle", String(group.shapes.count) + " option(s) in a row"]
              + evidenceLabels(labels),
            warnings: notes))
      } else {
        for shape in group.shapes {
          let label = nearestLabel(to: shape.rect, lines: textLines)
          var notes: [String] = []
          if label == nil {
            notes.append("No adjacent label was found; confirm what this box means before accepting.")
          }
          candidates.append(
            makeCandidate(
              kind: .checkbox, rects: [shape.rect], label: label?.text,
              confidence: shape.kind == .rectangle ? 0.8 : 0.74,
              source: label?.source,
              evidence: [
                shape.kind == .rectangle ? "painted rectangle" : "painted circle",
                "small near-square shape",
              ] + evidenceLabels([label]),
              warnings: notes))
        }
      }
    }

    // 3. Bracket markers in text ("[ ]", box glyph) are checkbox candidates,
    //    useful on OCR pages where the box is raster paint.
    for line in textLines {
      for marker in boxMarkerProposals(in: line, options: options) {
        candidates.append(
          makeCandidate(
            kind: .checkbox, rects: [marker.rect], label: marker.label, confidence: 0.6,
            source: line.source, evidence: ["typed checkbox marker"], warnings: []))
      }
    }

    // 4. Remove text proposals that overlap a higher-confidence non-text
    //    proposal (label text used as a checkbox label must not become a field).
    candidates = suppressOverlapping(candidates)
    candidates.sort { lhs, rhs in
      if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
      if abs(lhs.primaryRect[3] - rhs.primaryRect[3]) > 2 {
        return lhs.primaryRect[3] > rhs.primaryRect[3]
      }
      return lhs.primaryRect[0] < rhs.primaryRect[0]
    }
    let recognizedCount = textLines.filter(\.source.isRecognized).count
    let report = FormDetectionPageReport(
      pageIndex: pageIndex, pageID: pageID, textLineCount: textLines.count,
      recognizedLineCount: recognizedCount, shapeCount: shapes.count,
      hasOCRTextLayer: hasOCRTextLayer, refusalReason: nil)
    return (report, candidates)
  }

  // MARK: Evidence extraction

  /// FRM-01: positioned text lines with provenance. Digital text and text from
  /// an sPDF-generated OCR layer are both read; invisible glyphs from the layer
  /// are included so scans with existing OCR data can be detected.
  public static func extractTextLines(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> [FormDetectionTextLine] {
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    let runs = try TextRunIndexer.runs(
      in: content, graph: graph, limits: limits, allowStandard14MetricFallback: true)
    let layout = try PageTextLayout.build(
      in: content, graph: graph, limits: limits, allowStandard14MetricFallback: true)
    let recognizedRuns = TextProvenance.recognizedRunIndices(pageID: pageID, in: graph, limits: limits)
    var lines: [FormDetectionTextLine] = []
    for range in layout.lines {
      let clusters = range.compactMap { layout.clusters.indices.contains($0) ? layout.clusters[$0] : nil }
      guard !clusters.isEmpty else { continue }
      // Recognized layer text is deliberately invisible (3 Tr) in the page
      // paint; it is included as evidence. Invisible document text is hidden
      // content and is not used for detection.
      let visible = clusters.filter { cluster in
        guard runs.indices.contains(cluster.runIndex) else { return false }
        if recognizedRuns.contains(cluster.runIndex) { return true }
        return TextCanvasSupport.renderingMode(
          at: runs[cluster.runIndex].instructionIndex, in: content) != 3
      }
      guard !visible.isEmpty else { continue }
      let text = visible.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.count <= 400 else { continue }
      let rects = visible.map(\.bounds).filter { $0.count == 4 && $0.allSatisfy(\.isFinite) }
      guard rects.count == visible.count, let rect = union(rects) else { continue }
      let sizes = visible.map(\.fontSize).filter { $0.isFinite && $0 > 0 }
      guard let fontSize = sizes.sorted()[safe: sizes.count / 2] else { continue }
      // Horizontal text lines only: a line's height must be near one em.
      guard rect[3] - rect[1] <= max(6, fontSize * 2.4) else { continue }
      let runIndices = Set(visible.map(\.runIndex))
      let recognized = !runIndices.isEmpty && runIndices.isSubset(of: recognizedRuns)
      let source: FormDetectionTextSource = recognized
        ? .recognizedText(confidence: nil) : .documentText
      lines.append(FormDetectionTextLine(text: text, rect: rect, source: source))
    }
    return lines
  }

  /// FRM-01: small painted rectangles and circles that may be checkbox or radio
  /// widgets. Only axis-aligned paint on the page itself is measured; nested
  /// form transforms are outside this profile.
  public static func extractShapes(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) throws -> [FormDetectionShape] {
    let content = try PageContent.load(pageID: pageID, in: graph, limits: limits)
    var ctm: [Double] = [1, 0, 0, 1, 0, 0]
    var stack: [[Double]] = []
    var subpaths: [ShapeSubpath] = []
    var current: ShapeSubpath?
    var shapes: [FormDetectionShape] = []
    var instructionBudget = 0

    func flush() {
      if let current, !current.points.isEmpty { subpaths.append(current) }
      current = nil
    }

    for instruction in content.instructions {
      instructionBudget += 1
      if instructionBudget > 500_000 { break }
      let numbers = instruction.operands.compactMap { operand -> Double? in
        switch operand.value {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
      }
      switch instruction.operatorName {
      case "q":
        stack.append(ctm)
      case "Q":
        if let previous = stack.popLast() { ctm = previous }
      case "cm":
        if numbers.count == 6 { ctm = FormDetectionGeometry.concatenate(ctm, numbers) }
      case "m":
        flush()
        if numbers.count == 2 {
          current = ShapeSubpath(points: [FormDetectionGeometry.apply(ctm, numbers[0], numbers[1])])
        }
      case "l":
        if numbers.count == 2, current != nil {
          current?.points.append(FormDetectionGeometry.apply(ctm, numbers[0], numbers[1]))
        }
      case "c":
        if numbers.count == 6, current != nil {
          current?.hasCurve = true
          current?.points.append(FormDetectionGeometry.apply(ctm, numbers[4], numbers[5]))
        }
      case "v", "y":
        if numbers.count == 4, current != nil {
          current?.hasCurve = true
          current?.points.append(FormDetectionGeometry.apply(ctm, numbers[2], numbers[3]))
        }
      case "re":
        flush()
        if numbers.count == 4 {
          let corners = [
            [numbers[0], numbers[1]], [numbers[0] + numbers[2], numbers[1]],
            [numbers[0] + numbers[2], numbers[1] + numbers[3]],
            [numbers[0], numbers[1] + numbers[3]],
          ].map { FormDetectionGeometry.apply(ctm, $0[0], $0[1]) }
          subpaths.append(ShapeSubpath(points: corners, isRectangle: true))
        }
      case "h":
        break
      case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*":
        flush()
        for subpath in subpaths {
          guard let bounds = union(subpath.points.map { [$0[0], $0[1], $0[0], $0[1]] })
          else { continue }
          let width = bounds[2] - bounds[0]
          let height = bounds[3] - bounds[1]
          let side = min(width, height)
          // Checkbox/radio sized marks only, and only near-square ones.
          guard side >= 4, side <= 40,
            max(width, height) / max(side, 0.001) <= 1.7
          else { continue }
          let kind: FormDetectionShape.Kind =
            subpath.isRectangle && !subpath.hasCurve ? .rectangle : .ellipse
          shapes.append(FormDetectionShape(kind: kind, rect: normalize(bounds)))
        }
        subpaths = []
      case "n":
        subpaths = []
        current = nil
      default:
        break
      }
    }
    return shapes
  }

  // MARK: Helpers

  struct ShapeSubpath {
    var points: [[Double]]
    var hasCurve = false
    var isRectangle = false
  }

  struct TextFieldProposal {
    let rect: [Double]
    let label: String?
    let confidence: Double
    let evidence: [String]
    let warnings: [String]
  }

  struct LabeledText {
    let text: String
    let rect: [Double]
    let source: FormDetectionTextSource
  }

  static func textFieldProposals(
    in line: FormDetectionTextLine, allLines: [FormDetectionTextLine],
    options: FormDetectionOptions
  ) -> [TextFieldProposal] {
    var proposals: [TextFieldProposal] = []
    let rect = line.rect
    let text = line.text
    let characterWidth = max(1, (rect[2] - rect[0]) / Double(max(text.count, 1)))

    // A run of underscores or dot leaders is the classic typed "fill here" mark.
    if let marker = leaderRun(in: text) {
      let prefix = String(text.prefix(marker.lowerBound))
      let suffix = String(text.dropFirst(marker.upperBound))
      let startX = rect[0] + Double(marker.lowerBound) * characterWidth
      let endX = rect[0] + Double(marker.upperBound) * characterWidth
      let fieldRect = normalize([startX, rect[1] - 1, endX, rect[3] + 1])
      let label = cleanLabel(prefix.isEmpty ? suffix : prefix)
      proposals.append(
        TextFieldProposal(
          rect: fieldRect, label: label, confidence: 0.9,
          evidence: ["typed fill-in leader"], warnings: []))
    }

    // "Label:" followed by empty space on the same visual row.
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix(":"), trimmed.count <= options.maximumLabelLength,
      !trimmed.hasPrefix("http")
    {
      let label = cleanLabel(String(trimmed.dropLast()))
      if let label, !label.isEmpty {
        // The reported line bounds already exclude the trimmed trailing space,
        // so the label ends at the line's right edge.
        let labelEndX = rect[2]
        if let neighbor = rightNeighbor(of: line, in: allLines) {
          let gapStart = labelEndX + 4
          let gapEnd = min(neighbor.rect[0] - 4, labelEndX + 220)
          if gapEnd - gapStart >= 18 {
            proposals.append(
              TextFieldProposal(
                rect: normalize([gapStart, rect[1] - 1, gapEnd, rect[3] + 1]), label: label,
                confidence: 0.8,
                evidence: ["label ending with a colon", "empty space before the next text"],
                warnings: []))
          }
        } else {
          let pageLimit = rect[2] + 200
          let gapStart = labelEndX + 4
          let gapEnd = min(gapStart + 160, pageLimit)
          if gapEnd - gapStart >= 24 {
            proposals.append(
              TextFieldProposal(
                rect: normalize([gapStart, rect[1] - 1, gapEnd, rect[3] + 1]), label: label,
                confidence: 0.72,
                evidence: ["label ending with a colon", "empty space to the page margin"],
                warnings: [
                  "No following text bounded this row; confirm the field width before accepting."
                ]))
          }
        }
      }
    }
    return proposals
  }

  /// A run of at least four underscores, or at least five dots used as a leader.
  static func leaderRun(in text: String) -> Range<Int>? {
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "_" {
        var end = index
        while end < characters.count, characters[end] == "_" { end += 1 }
        if end - index >= 4 { return index..<end }
        index = end
      } else if character == "." {
        var end = index
        while end < characters.count, characters[end] == "." { end += 1 }
        if end - index >= 5 { return index..<end }
        index = end
      } else {
        index += 1
      }
    }
    return nil
  }

  static func rightNeighbor(
    of line: FormDetectionTextLine, in lines: [FormDetectionTextLine]
  ) -> FormDetectionTextLine? {
    let row = line.rect
    let height = row[3] - row[1]
    var best: FormDetectionTextLine?
    var bestGap = Double.infinity
    for other in lines {
      guard other.text != line.text else { continue }
      let otherRect = other.rect
      let verticalOverlap = min(row[3], otherRect[3]) - max(row[1], otherRect[1])
      guard verticalOverlap >= height * 0.5, otherRect[0] >= row[2] else { continue }
      let gap = otherRect[0] - row[2]
      if gap >= 4, gap <= 240, gap < bestGap {
        best = other
        bestGap = gap
      }
    }
    return best
  }

  static func boxMarkerProposals(
    in line: FormDetectionTextLine, options: FormDetectionOptions
  ) -> [TextFieldProposal] {
    let markers = ["[ ]", "[]"]
    let text = line.text
    let characterWidth = max(1, (line.rect[2] - line.rect[0]) / Double(max(text.count, 1)))
    var found: [TextFieldProposal] = []
    for marker in markers {
      guard let range = text.range(of: marker) else { continue }
      let offset = text.distance(from: text.startIndex, to: range.lowerBound)
      let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
      let startX = line.rect[0] + Double(offset) * characterWidth
      let endX = line.rect[0] + Double(endOffset) * characterWidth
      let side = max(options.minimumWidgetSize, min(18, line.rect[3] - line.rect[1]))
      let centerY = (line.rect[1] + line.rect[3]) / 2
      let labelText = text.replacingCharacters(in: range, with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      found.append(
        TextFieldProposal(
          rect: normalize([
            startX, centerY - side / 2, startX + max(side, endX - startX), centerY + side / 2,
          ]),
          label: labelText.isEmpty ? nil : cleanLabel(labelText), confidence: 0.6,
          evidence: ["typed checkbox marker"], warnings: []))
    }
    return found
  }

  enum ShapeGroup {
    case radios([FormDetectionShape])
    case boxes([FormDetectionShape])
    var kind: FormDetectionShape.Kind {
      if case .radios = self { return .ellipse }
      return .rectangle
    }
    var shapes: [FormDetectionShape] {
      switch self {
      case .radios(let shapes): return shapes
      case .boxes(let shapes): return shapes
      }
    }
  }

  /// Group small ellipses into radio rows; keep rectangles as individual
  /// checkboxes. Rows require matching size, a shared baseline band, and tight
  /// spacing, which is how authored radio groups read.
  static func groupShapes(
    _ shapes: [FormDetectionShape], options: FormDetectionOptions
  ) -> [ShapeGroup] {
    var groups: [ShapeGroup] = []
    var remaining = shapes.filter {
      $0.isNearSquare && min($0.width, $0.height) >= options.minimumWidgetSize
    }
    remaining.sort { lhs, rhs in
      if abs(lhs.rect[1] - rhs.rect[1]) > 2 { return lhs.rect[1] > rhs.rect[1] }
      return lhs.rect[0] < rhs.rect[0]
    }
    var index = 0
    while index < remaining.count {
      let shape = remaining[index]
      if shape.kind == .ellipse {
        var row = [shape]
        remaining.remove(at: index)
        var cursor = index
        while cursor < remaining.count {
          let candidate = remaining[cursor]
          let last = row[row.count - 1]
          let sameSize = abs(candidate.width - last.width) <= max(2, last.width * 0.3)
            && abs(candidate.height - last.height) <= max(2, last.height * 0.3)
          let sameBand = abs(
            (candidate.rect[1] + candidate.rect[3]) / 2 - (last.rect[1] + last.rect[3]) / 2) <= 4
          let gap = candidate.rect[0] - last.rect[2]
          if candidate.kind == .ellipse, sameSize, sameBand, gap >= 2, gap <= 90 {
            row.append(candidate)
            remaining.remove(at: cursor)
          } else if candidate.rect[0] <= last.rect[2] + 90 {
            cursor += 1
          } else {
            break
          }
        }
        groups.append(.radios(row))
      } else {
        groups.append(.boxes([shape]))
        remaining.remove(at: index)
      }
    }
    return groups
  }

  static func nearestLabel(
    to rect: [Double], lines: [FormDetectionTextLine]
  ) -> LabeledText? {
    let centerY = (rect[1] + rect[3]) / 2
    let height = max(rect[3] - rect[1], 8)
    var best: LabeledText?
    var bestScore = Double.infinity
    for line in lines {
      let lineCenter = (line.rect[1] + line.rect[3]) / 2
      let verticalDistance = abs(lineCenter - centerY)
      guard verticalDistance <= height * 1.7 else { continue }
      let gapRight = line.rect[0] - rect[2]
      let gapLeft = rect[0] - line.rect[2]
      let gap: Double
      if gapRight >= -2 {
        gap = max(0, gapRight)
      } else if gapLeft >= -2 {
        gap = max(0, gapLeft) * 1.4
      } else {
        continue
      }
      guard gap <= 140 else { continue }
      let score = gap + verticalDistance * 2
      guard score < bestScore else { continue }
      let text = cleanLabel(line.text) ?? ""
      guard !text.isEmpty, text.count <= 80 else { continue }
      best = LabeledText(text: text, rect: line.rect, source: line.source)
      bestScore = score
    }
    return best
  }

  static func groupLabel(
    lines: [FormDetectionTextLine], shapes: [FormDetectionShape], options: FormDetectionOptions
  ) -> String? {
    guard let first = shapes.first else { return nil }
    for line in lines {
      let vertical = line.rect[3] >= first.rect[1] - 12 && line.rect[1] <= first.rect[3] + 12
      guard vertical, line.rect[0] < first.rect[0] + 40, line.rect[2] <= first.rect[0] + 40
      else { continue }
      if let label = cleanLabel(line.text) { return label }
    }
    return nil
  }

  static func evidenceLabels(_ labels: [LabeledText?]) -> [String] {
    var evidence: [String] = []
    for (index, label) in labels.enumerated() {
      guard let label else { continue }
      evidence.append("option " + String(index + 1) + " label " + label.text)
    }
    return evidence
  }

  static func exportValue(from label: String?, fallbackIndex: Int) -> String {
    guard let label else { return "Option" + String(fallbackIndex) }
    let sanitized = sanitizedName(label)
    return sanitized.isEmpty ? "Option" + String(fallbackIndex) : sanitized
  }

  static func uniqueExportValues(_ values: [String]) -> [String] {
    var used = Set<String>()
    var result: [String] = []
    for (index, value) in values.enumerated() {
      var candidate = value == "Off" ? "Option" + String(index + 1) : value
      if candidate.isEmpty { candidate = "Option" + String(index + 1) }
      var unique = candidate
      var suffix = 2
      while used.contains(unique) {
        unique = candidate + String(suffix)
        suffix += 1
      }
      used.insert(unique)
      result.append(unique)
    }
    return result
  }

  /// Text proposals that overlap a higher-confidence non-text proposal are
  /// dropped: the label belongs to the box it names.
  static func suppressOverlapping(_ candidates: [FormFieldCandidate]) -> [FormFieldCandidate] {
    var kept: [FormFieldCandidate] = []
    for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
      let overlaps = kept.contains { other in
        guard other.kind != candidate.kind else { return false }
        guard let a = candidate.rects.first, let b = other.rects.first else { return false }
        return FormDetectionGeometry.intersectionArea(a, b) > 1
      }
      if !overlaps { kept.append(candidate) }
    }
    return kept
  }

  static func refusalReason(
    kind: FormDetectedFieldKind, rects: [[Double]], pageBounds: [Double],
    options: FormDetectionOptions, source: FormDetectionTextSource?, label: String?
  ) -> String? {
    _ = source
    guard !rects.isEmpty else { return "The proposal has no geometry." }
    for rect in rects {
      guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > rect[0], rect[3] > rect[1]
      else { return "The proposal has invalid geometry." }
      let width = rect[2] - rect[0]
      let height = rect[3] - rect[1]
      guard min(width, height) >= options.minimumWidgetSize else {
        return "The proposal is smaller than the "
          + String(format: "%.0f", options.minimumWidgetSize) + " pt minimum field size."
      }
      guard FormDetectionGeometry.contains(inner: rect, outer: pageBounds, tolerance: 1.5) else {
        return "The proposal lies outside the page box; move it inside the page before accepting."
      }
    }
    if kind == .text, let label, label.count > options.maximumLabelLength {
      return "The detected label is too long to be a field label."
    }
    return nil
  }

  static func overlappingExistingField(
    rects: [[Double]], existing: [(name: String, rect: [Double])]
  ) -> String? {
    for rect in rects {
      for entry in existing {
        if FormDetectionGeometry.intersectionArea(rect, entry.rect) > 1 {
          return entry.name
        }
      }
    }
    return nil
  }

  /// FRM-01/FRM-02: the page's display box used for eligibility and canvas
  /// clamping.
  public static func pageBounds(pageID: PDFObjectID, in graph: PDFGraph) -> [Double] {
    if let attributes = PDFDocumentInventory.pageAttributes(pageIDs: [pageID], in: graph).first {
      let box = attributes.displayBox
      if box.count == 4, box[2] > box[0], box[3] > box[1] { return box }
    }
    return [0, 0, 612, 792]
  }

  static func suggestedName(label: String?, kind: FormDetectedFieldKind, index: Int) -> String {
    let base = sanitizedName(label ?? "")
    if !base.isEmpty { return base }
    switch kind {
    case .text: return "Text" + String(index)
    case .checkbox: return "Checkbox" + String(index)
    case .radio: return "RadioGroup" + String(index)
    }
  }

  /// A readable ASCII PDF field name. Non-ASCII letters are dropped because
  /// this profile writes field names the standard appearance path can show.
  static func sanitizedName(_ label: String) -> String {
    let scalars = label.unicodeScalars.filter { scalar in
      (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        || (scalar.value >= 48 && scalar.value <= 57)
    }
    var result = String(String.UnicodeScalarView(scalars))
    if result.count > 40 { result = String(result.prefix(40)) }
    if let first = result.first, first.isNumber { result = "Field" + result }
    return result
  }

  static func uniqueName(_ base: String, used: Set<String>) -> String {
    guard used.contains(base) else { return base }
    var counter = 2
    while used.contains(base + String(counter)) { counter += 1 }
    return base + String(counter)
  }

  static func cleanLabel(_ text: String) -> String? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix(":") || trimmed.hasSuffix("-") || trimmed.hasSuffix("_")
      || trimmed.hasSuffix(".")
    {
      trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
    return trimmed
  }

  static func normalize(_ rect: [Double]) -> [Double] {
    guard rect.count == 4 else { return rect }
    return [
      min(rect[0], rect[2]), min(rect[1], rect[3]), max(rect[0], rect[2]),
      max(rect[1], rect[3]),
    ]
  }

  static func union(_ rects: [[Double]]) -> [Double]? {
    let valid = rects.filter { $0.count == 4 && $0.allSatisfy(\.isFinite) }
    guard var result = valid.first else { return nil }
    for rect in valid.dropFirst() {
      result = [
        min(result[0], rect[0]), min(result[1], rect[1]), max(result[2], rect[2]),
        max(result[3], rect[3]),
      ]
    }
    return result
  }
}

// MARK: - Review decisions

/// FRM-01: the reviewer's decisions over one detection report. Accepting a
/// candidate never touches the document; only makePlan(in:) builds the single
/// transaction that creates the accepted fields.
public struct FormFieldDetectionReview: Sendable {
  public enum Decision: String, Sendable, Equatable {
    case pending
    case accepted
    case rejected
  }

  /// Reviewer edits to a proposal. Nil fields keep the detected value.
  public struct Edits: Sendable, Equatable {
    public var name: String?
    public var label: String?
    public var kind: FormDetectedFieldKind?
    public var rects: [[Double]]?
    public var exportValues: [String]?

    public init() {}
  }

  public let report: FormDetectionReport
  public private(set) var decisions: [UUID: Decision] = [:]
  public private(set) var edits: [UUID: Edits] = [:]

  public init(report: FormDetectionReport) {
    self.report = report
    for candidate in report.candidates {
      decisions[candidate.id] = .pending
    }
  }

  public func decision(for id: UUID) -> Decision { decisions[id] ?? .pending }
  public func edits(for id: UUID) -> Edits { edits[id] ?? Edits() }

  public mutating func accept(_ id: UUID) {
    guard report.candidates.contains(where: { $0.id == id }) else { return }
    decisions[id] = .accepted
  }

  public mutating func reject(_ id: UUID) {
    guard report.candidates.contains(where: { $0.id == id }) else { return }
    decisions[id] = .rejected
  }

  public mutating func reset(_ id: UUID) {
    decisions[id] = .pending
  }

  public mutating func update(_ id: UUID, _ change: (inout Edits) -> Void) {
    var current = edits[id] ?? Edits()
    change(&current)
    edits[id] = current
  }

  /// Accept every eligible proposal (the reviewer still sees the list first).
  public mutating func acceptAllEligible() {
    for candidate in report.candidates where candidate.isEligible {
      decisions[candidate.id] = .accepted
    }
  }

  public mutating func rejectAll() {
    for candidate in report.candidates {
      decisions[candidate.id] = .rejected
    }
  }

  /// The proposal with reviewer edits applied. Edits are not validated here;
  /// makePlan(in:) validates before anything is created.
  public func effectiveCandidate(_ id: UUID) -> FormFieldCandidate? {
    guard let candidate = report.candidates.first(where: { $0.id == id }) else { return nil }
    let edit = edits[id] ?? Edits()
    return FormFieldCandidate(
      id: candidate.id, pageIndex: candidate.pageIndex, pageID: candidate.pageID,
      pageBounds: candidate.pageBounds, kind: edit.kind ?? candidate.kind,
      rects: edit.rects ?? candidate.rects,
      suggestedName: edit.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? candidate.suggestedName,
      label: edit.label ?? candidate.label,
      exportValues: edit.exportValues ?? candidate.exportValues,
      confidence: candidate.confidence, source: candidate.source,
      evidence: candidate.evidence, warnings: candidate.warnings,
      refusalReason: candidate.refusalReason)
  }

  public var acceptedCandidates: [FormFieldCandidate] {
    report.candidates.compactMap { candidate in
      decision(for: candidate.id) == .accepted ? effectiveCandidate(candidate.id) : nil
    }
  }

  public var pendingCount: Int { decisions.values.filter { $0 == .pending }.count }
  public var acceptedCount: Int { decisions.values.filter { $0 == .accepted }.count }
  public var rejectedCount: Int { decisions.values.filter { $0 == .rejected }.count }
  public var canCommit: Bool { acceptedCount > 0 }
}

/// FRM-01: the validated output of a review. The transaction creates every
/// accepted field in one undoable step.
public struct FormDetectionCommitPlan: Sendable {
  public let candidates: [FormFieldCandidate]
  public let transaction: PDFTransaction
  public let fieldNames: [String]

  public init(candidates: [FormFieldCandidate], transaction: PDFTransaction, fieldNames: [String]) {
    self.candidates = candidates
    self.transaction = transaction
    self.fieldNames = fieldNames
  }

  public var summary: String {
    let count = candidates.count
    return "Create " + String(count) + " field" + (count == 1 ? "" : "s")
      + " from detected proposals"
  }
}

extension FormFieldDetectionReview {
  /// Build and validate the one transaction that creates the accepted
  /// proposals. Duplicate names, unusable geometry and ineligible proposals are
  /// refused with an actionable message; nothing is silently renamed.
  public func makePlan(in graph: PDFGraph, limits: PDFLimits = PDFLimits()) throws
    -> FormDetectionCommitPlan
  {
    let accepted = acceptedCandidates
    guard !accepted.isEmpty else {
      throw PDFError(.malformed, "Accept at least one detected field before creating fields")
    }
    let pageIDs = try PageTreeView(graph: graph).pages
    let existing = try FormInventory.fields(in: graph, pageIDs: pageIDs)
    var existingNames = Set(existing.map(\.name))
    var commands: [any PDFEditCommand] = []
    var names: [String] = []
    var planned: [FormFieldCandidate] = []
    for candidate in accepted {
      guard candidate.isEligible else {
        throw PDFError(
          .unsupported,
          candidate.suggestedName + " cannot be created: "
            + (candidate.refusalReason ?? "the proposal was refused"))
      }
      guard pageIDs.indices.contains(candidate.pageIndex) else {
        throw PDFError(.malformed, "A proposal targets a page that no longer exists")
      }
      let pageID = candidate.pageID ?? pageIDs[candidate.pageIndex]
      let name = candidate.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        throw PDFError(.malformed, "Every accepted field needs a name")
      }
      guard !existingNames.contains(name) else {
        throw PDFError(
          .malformed,
          "A field named " + name + " already exists. Review the proposal name before creating "
            + "the field; nothing was renamed automatically.")
      }
      let bounds = FormFieldDetection.pageBounds(pageID: pageID, in: graph)
      for rect in candidate.rects {
        guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] - rect[0] >= 4,
          rect[3] - rect[1] >= 4
        else {
          throw PDFError(.malformed, "The proposal rectangle for " + name + " is not usable")
        }
        guard FormDetectionGeometry.contains(inner: rect, outer: bounds, tolerance: 1.5) else {
          throw PDFError(
            .malformed,
            "The proposal rectangle for " + name + " lies outside page "
              + String(candidate.pageIndex + 1))
        }
      }
      let command = AddDetectedFormFieldCommand(
        pageID: pageID, baseName: name, rects: candidate.rects, kind: commandKind(for: candidate),
        label: candidate.label)
      try command.validate(in: graph)
      commands.append(command)
      existingNames.insert(name)
      names.append(name)
      planned.append(candidate)
    }
    guard !commands.isEmpty else {
      throw PDFError(.malformed, "No accepted proposals could be created")
    }
    _ = limits
    return FormDetectionCommitPlan(
      candidates: planned, transaction: PDFTransaction(commands), fieldNames: names)
  }

  private func commandKind(for candidate: FormFieldCandidate) -> AddDetectedFormFieldCommand.Kind {
    switch candidate.kind {
    case .text:
      return .text(multiline: false, defaultValue: nil, fontSize: 12)
    case .checkbox:
      return .checkbox(checkedByDefault: false)
    case .radio:
      var values = candidate.exportValues
      while values.count < candidate.rects.count {
        values.append("Option" + String(values.count + 1))
      }
      return .radioGroup(
        exportValues: Array(values.prefix(candidate.rects.count)), selectedIndex: nil)
    }
  }
}

// MARK: - Authoring command with an accessible label

/// FRM-01/FRM-02: create one detected field and set its tooltip (/TU) in the
/// same command, so a detected label stays attached after save and reopen.
public struct AddDetectedFormFieldCommand: PDFEditCommand {
  public enum Kind: Sendable, Equatable {
    case text(multiline: Bool, defaultValue: String?, fontSize: Double)
    case checkbox(checkedByDefault: Bool)
    case radioGroup(exportValues: [String], selectedIndex: Int?)
  }

  public let pageID: PDFObjectID
  public let baseName: String
  /// One rectangle for text/checkbox; one per option for radio groups.
  public let rects: [[Double]]
  public let kind: Kind
  public let label: String?

  public init(
    pageID: PDFObjectID, baseName: String, rects: [[Double]], kind: Kind, label: String?
  ) {
    self.pageID = pageID
    self.baseName = baseName
    self.rects = rects
    self.kind = kind
    self.label = label
  }

  public var name: String { "Add Detected Form Field" }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }

  public func validate(in graph: PDFGraph) throws {
    guard case .dictionary? = graph.objects[pageID] else {
      throw PDFError(.malformed, "The page is missing")
    }
    guard !baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PDFError(.malformed, "The field needs a name")
    }
    guard !rects.isEmpty else {
      throw PDFError(.malformed, "The field needs a rectangle")
    }
    for rect in rects {
      guard rect.count == 4, rect[2] > rect[0], rect[3] > rect[1] else {
        throw PDFError(.malformed, "The field needs a non-empty rectangle")
      }
    }
    if let label, label.count > 512 {
      throw PDFError(.malformed, "The field label is longer than the supported profile")
    }
    let inner = try makeInnerCommand()
    try inner.validate(in: graph)
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    var graph = graph
    // Resolve the name this command will produce so the label lands on the
    // same field even when a numeric suffix is required.
    let uniqueFull = try FormAuthoringSupport.uniqueName(baseName, in: graph)
    let inner = try makeInnerCommand()
    try inner.validate(in: graph)
    graph = try inner.apply(to: graph)
    if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let fieldID = FormAuthoringSupport.findFieldObject(named: uniqueFull, in: graph),
      case .dictionary(var field)? = graph.objects[fieldID]
    {
      field[PDFName("TU")] = .string(AnnotationText.encode(label))
      graph.objects[fieldID] = .dictionary(field)
    }
    return graph
  }

  private func makeInnerCommand() throws -> any PDFEditCommand {
    switch kind {
    case .text(let multiline, let defaultValue, let fontSize):
      guard rects.count == 1 else {
        throw PDFError(.malformed, "A text field needs one rectangle")
      }
      return AddTextFieldCommand(
        pageID: pageID, rect: rects[0], name: baseName, multiline: multiline,
        defaultValue: defaultValue, fontSize: fontSize)
    case .checkbox(let checkedByDefault):
      guard rects.count == 1 else {
        throw PDFError(.malformed, "A checkbox needs one rectangle")
      }
      return AddCheckboxCommand(
        pageID: pageID, rect: rects[0], name: baseName, checkedByDefault: checkedByDefault)
    case .radioGroup(let exportValues, let selectedIndex):
      guard rects.count == exportValues.count, !exportValues.isEmpty else {
        throw PDFError(.malformed, "Each radio widget needs an export value")
      }
      return AddRadioGroupCommand(
        pageID: pageID, rects: rects, name: baseName, exportValues: exportValues,
        selectedIndex: selectedIndex)
    }
  }
}

// MARK: - Geometry used by detection (shared with the design canvas)

public enum FormDetectionGeometry {
  public static func concatenate(_ a: [Double], _ b: [Double]) -> [Double] {
    [
      a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
      a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
      a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5],
    ]
  }

  public static func apply(_ matrix: [Double], _ x: Double, _ y: Double) -> [Double] {
    [matrix[0] * x + matrix[2] * y + matrix[4], matrix[1] * x + matrix[3] * y + matrix[5]]
  }

  public static func intersectionArea(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == 4, b.count == 4 else { return 0 }
    let width = min(a[2], b[2]) - max(a[0], b[0])
    let height = min(a[3], b[3]) - max(a[1], b[1])
    guard width > 0, height > 0 else { return 0 }
    return width * height
  }

  public static func contains(inner: [Double], outer: [Double], tolerance: Double) -> Bool {
    guard inner.count == 4, outer.count == 4 else { return false }
    return inner[0] >= outer[0] - tolerance && inner[1] >= outer[1] - tolerance
      && inner[2] <= outer[2] + tolerance && inner[3] <= outer[3] + tolerance
  }
}

