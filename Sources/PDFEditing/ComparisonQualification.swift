import Foundation
import PDFCore

// MARK: - REV-06 scan/layout comparison qualification

/// REV-06: raster evidence supplied by the caller (the App renders each page
/// pair locally). The core never guesses pixel differences; it qualifies the
/// structured comparison with this explicit evidence and preserves uncertainty.
public struct ComparisonRasterEvidence: Sendable, Equatable {
  public let leftPageIndex: Int
  public let rightPageIndex: Int
  /// Fraction of pixels whose channel difference exceeded the tolerance.
  public let changedPixelRatio: Double
  public let tolerance: Int
  public let width: Int
  public let height: Int

  public init(
    leftPageIndex: Int, rightPageIndex: Int, changedPixelRatio: Double, tolerance: Int,
    width: Int, height: Int
  ) {
    self.leftPageIndex = leftPageIndex
    self.rightPageIndex = rightPageIndex
    self.changedPixelRatio = changedPixelRatio
    self.tolerance = tolerance
    self.width = width
    self.height = height
  }
}

/// REV-06: thresholds that separate scan noise from meaningful visual changes.
public struct ComparisonQualificationOptions: Sendable, Equatable {
  /// Changed-pixel ratio at or below this is treated as scan/render noise.
  public let scanNoiseRatio: Double
  /// Changed-pixel ratio above this is treated as a meaningful visual change.
  public let meaningfulChangeRatio: Double
  /// Minimum non-whitespace characters before text evidence counts as available.
  public let minimumTextCharacters: Int

  public init(
    scanNoiseRatio: Double = 0.005, meaningfulChangeRatio: Double = 0.02,
    minimumTextCharacters: Int = 1
  ) {
    self.scanNoiseRatio = scanNoiseRatio
    self.meaningfulChangeRatio = meaningfulChangeRatio
    self.minimumTextCharacters = minimumTextCharacters
  }

  func validate() throws {
    guard scanNoiseRatio.isFinite, scanNoiseRatio >= 0, scanNoiseRatio <= 1 else {
      throw PDFError(.malformed, "The scan-noise threshold must be between 0 and 1")
    }
    guard meaningfulChangeRatio.isFinite, meaningfulChangeRatio > scanNoiseRatio,
      meaningfulChangeRatio <= 1
    else {
      throw PDFError(.malformed, "The meaningful-change threshold must be above the scan-noise threshold")
    }
    guard minimumTextCharacters >= 1 else {
      throw PDFError(.malformed, "At least one character is required as text evidence")
    }
  }

  public var summary: String {
    "scan-noise floor \(percent(scanNoiseRatio)); meaningful-change threshold \(percent(meaningfulChangeRatio))"
  }

  private func percent(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
  }
}

public enum ComparisonRasterStatus: String, Sendable, Equatable {
  case identical
  case withinNoise
  case changed
  case unavailable

  public var title: String {
    switch self {
    case .identical: return "identical"
    case .withinNoise: return "within scan noise"
    case .changed: return "meaningful raster change"
    case .unavailable: return "no raster evidence"
    }
  }
}

/// REV-06: what text evidence exists on one page. Generated OCR text is never
/// treated as equivalent to source text: it is an uncertain evidence source.
public enum ComparisonTextSource: String, Sendable, Equatable {
  case digital
  case generatedOCR
  case mixed
  case unavailable

  public var title: String {
    switch self {
    case .digital: return "digital text"
    case .generatedOCR: return "generated OCR text"
    case .mixed: return "digital + OCR text"
    case .unavailable: return "no extractable text"
    }
  }

  public var isUncertain: Bool { self == .generatedOCR || self == .mixed }
}

public struct ComparisonQualificationFinding: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case rasterChangeConfirmed
    case rasterNoiseOnly
    case textExtractionUnavailable
    case generatedOCRText
    case ocrDifferenceUnconfirmed
    case complexLayout
    case renderingOnlyDifference
    case contentChangeConfirmed
    case availableTextEvidence
    case noTextEvidence
    case unpairedPage
  }

  public let kind: Kind
  public let summary: String
  public let leftPageIndex: Int?
  public let rightPageIndex: Int?
  public let isOCRSourced: Bool

  public init(
    kind: Kind, summary: String, leftPageIndex: Int?, rightPageIndex: Int?,
    isOCRSourced: Bool
  ) {
    self.kind = kind
    self.summary = summary
    self.leftPageIndex = leftPageIndex
    self.rightPageIndex = rightPageIndex
    self.isOCRSourced = isOCRSourced
  }
}

/// REV-06: the qualification verdict for one page pair.
public struct ComparisonPageQualification: Sendable, Equatable {
  public enum Verdict: String, Sendable, Equatable {
    /// Meaningful change with reliable text/raster evidence.
    case confirmedContentChange
    /// Rendered page differs while extractable text is equal: layout/rendering
    /// difference, not a content change.
    case confirmedRenderingDifference
    /// OCR text differs but the rendered page does not; OCR noise cannot be
    /// ruled out.
    case unconfirmedOCRChange
    /// Only sub-threshold raster differences were detected.
    case scanNoise
    /// Text extraction is unavailable; equality cannot be proven from text.
    case textUnavailable
    /// Complex layout (for example multiple columns) makes line matching
    /// unreliable.
    case complexLayoutUncertain
    /// Text available on both sides, text equal, raster within tolerance.
    case noDifferenceWithTextEvidence
    /// Raster change on pages without extractable text: the visual change is
    /// real but its content nature cannot be confirmed.
    case visualChangeUnverified
    /// Inserted/deleted page without a counterpart.
    case unpaired
  }

  public let leftPageIndex: Int?
  public let rightPageIndex: Int?
  public let leftTextSource: ComparisonTextSource
  public let rightTextSource: ComparisonTextSource
  public let rasterStatus: ComparisonRasterStatus
  public let changedPixelRatio: Double?
  public let verdict: Verdict
  public let findings: [ComparisonQualificationFinding]

  public init(
    leftPageIndex: Int?, rightPageIndex: Int?,
    leftTextSource: ComparisonTextSource, rightTextSource: ComparisonTextSource,
    rasterStatus: ComparisonRasterStatus, changedPixelRatio: Double?,
    verdict: Verdict, findings: [ComparisonQualificationFinding]
  ) {
    self.leftPageIndex = leftPageIndex
    self.rightPageIndex = rightPageIndex
    self.leftTextSource = leftTextSource
    self.rightTextSource = rightTextSource
    self.rasterStatus = rasterStatus
    self.changedPixelRatio = changedPixelRatio
    self.verdict = verdict
    self.findings = findings
  }

  public var isOCRSourced: Bool {
    leftTextSource.isUncertain || rightTextSource.isUncertain
  }

  public var insufficientTextEvidence: Bool {
    verdict == .textUnavailable || verdict == .visualChangeUnverified
      || verdict == .complexLayoutUncertain
  }

  public var summaryLines: [String] {
    let left = leftPageIndex.map { "L\($0 + 1)" } ?? "—"
    let right = rightPageIndex.map { "R\($0 + 1)" } ?? "—"
    var lines: [String] = []
    lines.append(
      "\(left) / \(right): \(verdict.rawValue); text: \(leftTextSource.title) / "
        + "\(rightTextSource.title); raster: \(rasterStatus.title)"
        + (changedPixelRatio.map { String(format: " (%.3f%% pixels)", $0 * 100) } ?? ""))
    lines.append(contentsOf: findings.map { "  - " + $0.summary })
    return lines
  }
}

public struct ComparisonQualificationResult: Sendable, Equatable {
  public let pages: [ComparisonPageQualification]
  public let findings: [ComparisonQualificationFinding]
  /// The structured comparison's changes plus explicit uncertainty statements
  /// for evidence-limited pairs. Nothing here claims equality for pages whose
  /// text could not be extracted.
  public let qualifiedChanges: [PDFComparisonChange]
  public let summaryLines: [String]
  public let options: ComparisonQualificationOptions

  public var pagesWithoutTextEvidence: [ComparisonPageQualification] {
    pages.filter(\.insufficientTextEvidence)
  }

  public var pageForLeft: [Int: ComparisonPageQualification] {
    var result: [Int: ComparisonPageQualification] = [:]
    for page in pages {
      if let index = page.leftPageIndex { result[index] = page }
    }
    return result
  }

  public var report: String {
    var lines: [String] = []
    lines.append("sPDF Editor comparison qualification")
    lines.append("Evidence thresholds: " + options.summary)
    lines.append("")
    lines.append(contentsOf: summaryLines)
    lines.append("")
    lines.append("Page evidence:")
    for page in pages {
      lines.append(contentsOf: page.summaryLines.map { "  " + $0 })
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - Qualification engine

public enum PDFComparisonQualification {
  struct TextProfile {
    let source: ComparisonTextSource
    let nonWhitespaceCharacters: Int
    let multiColumn: Bool
  }

  /// REV-06: combine the structured comparison with explicit raster evidence
  /// and available OCR layers. Pages whose text cannot be extracted are never
  /// reported as unchanged: they are qualified as evidence-limited pairs.
  public static func qualify(
    result: PDFComparisonResult,
    left: (graph: PDFGraph, source: Data), right: (graph: PDFGraph, source: Data),
    rasterEvidence: [ComparisonRasterEvidence] = [],
    options: ComparisonQualificationOptions = ComparisonQualificationOptions(),
    limits: PDFLimits = PDFLimits()
  ) throws -> ComparisonQualificationResult {
    try options.validate()
    var rasterByPair: [String: ComparisonRasterEvidence] = [:]
    for evidence in rasterEvidence {
      guard evidence.changedPixelRatio.isFinite, evidence.changedPixelRatio >= 0,
        evidence.changedPixelRatio <= 1
      else { continue }
      rasterByPair[pairKey(evidence.leftPageIndex, evidence.rightPageIndex)] = evidence
    }
    var profiles: [String: TextProfile] = [:]
    let leftPages = try PDFPageTree.pageIDs(in: left.graph)
    let rightPages = try PDFPageTree.pageIDs(in: right.graph)

    func profile(graph: PDFGraph, pageIDs: [PDFObjectID], index: Int, side: String) -> TextProfile {
      guard index >= 0, index < pageIDs.count else {
        return TextProfile(
          source: .unavailable, nonWhitespaceCharacters: 0, multiColumn: false)
      }
      let key = "\(side):\(index)"
      if let cached = profiles[key] { return cached }
      let computed: TextProfile
      if let layout = try? PageTextLayout.build(
        pageID: pageIDs[index], in: graph, limits: limits)
      {
        let ocrRuns = (try? PDFComparison.ocrRunIndices(
          pageID: pageIDs[index], in: graph)) ?? []
        let hasLayer = OCRLayer.hasGeneratedLayer(in: graph, pageID: pageIDs[index])
        var digital = 0
        var generated = 0
        for cluster in layout.clusters
        where !cluster.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          if ocrRuns.contains(cluster.runIndex) {
            generated += 1
          } else if hasLayer, generated > 0 || ocrRuns.isEmpty {
            // A generated layer whose fonts were not indexed still counts as
            // uncertain OCR evidence, never as source text.
            generated += 1
          } else {
            digital += 1
          }
        }
        let source: ComparisonTextSource
        if digital > 0, hasLayer || generated > 0 {
          source = .mixed
        } else if digital > 0 {
          source = .digital
        } else if hasLayer || generated > 0 {
          source = .generatedOCR
        } else {
          source = .unavailable
        }
        computed = TextProfile(
          source: source, nonWhitespaceCharacters: digital + generated,
          multiColumn: PDFComparison.isMultiColumn(layout))
      } else {
        computed = TextProfile(
          source: .unavailable, nonWhitespaceCharacters: 0, multiColumn: false)
      }
      profiles[key] = computed
      return computed
    }

    let textKinds: Set<PDFComparisonChange.Kind> = [.textAdded, .textRemoved, .textChanged]
    var pages: [ComparisonPageQualification] = []
    var findings: [ComparisonQualificationFinding] = []
    var qualifiedChanges = result.changes
    var verdictCounts: [ComparisonPageQualification.Verdict: Int] = [:]
    var unpairedCount = 0
    var complexLayoutPairs = 0
    var ocrPairs = 0
    var limitedPairs = 0

    func addFinding(
      _ kind: ComparisonQualificationFinding.Kind, summary: String,
      leftIndex: Int?, rightIndex: Int?, isOCR: Bool
    ) {
      let finding = ComparisonQualificationFinding(
        kind: kind, summary: summary, leftPageIndex: leftIndex,
        rightPageIndex: rightIndex, isOCRSourced: isOCR)
      findings.append(finding)
    }

    func addUncertainty(_ summary: String, leftIndex: Int?, rightIndex: Int?, isOCR: Bool) {
      if qualifiedChanges.contains(where: {
        $0.kind == .uncertainty && $0.summary == summary
      }) {
        return
      }
      qualifiedChanges.append(
        PDFComparisonChange(
          kind: .uncertainty, leftPageIndex: leftIndex, rightPageIndex: rightIndex,
          summary: summary, leftBounds: nil, rightBounds: nil, isOCRSourced: isOCR))
    }

    for pair in result.pageMapping {
      let leftIndex = pair.leftIndex
      let rightIndex = pair.rightIndex
      guard leftIndex != nil || rightIndex != nil else { continue }
      if leftIndex == nil || rightIndex == nil {
        // Inserted/deleted page: no counterpart to qualify. Record it so the
        // report never hides unpaired pages behind a summary count.
        unpairedCount += 1
        let prof = leftIndex.map {
          profile(graph: left.graph, pageIDs: leftPages, index: $0, side: "L")
        } ?? TextProfile(source: .unavailable, nonWhitespaceCharacters: 0, multiColumn: false)
        let page = ComparisonPageQualification(
          leftPageIndex: leftIndex, rightPageIndex: rightIndex,
          leftTextSource: leftIndex != nil ? prof.source : .unavailable,
          rightTextSource: .unavailable, rasterStatus: .unavailable,
          changedPixelRatio: nil, verdict: .unpaired, findings: [])
        pages.append(page)
        verdictCounts[.unpaired, default: 0] += 1
        addFinding(
          .unpairedPage,
          summary: "Unpaired page (inserted or deleted); no comparison evidence.",
          leftIndex: leftIndex, rightIndex: rightIndex, isOCR: false)
        continue
      }
      guard let leftIndex, let rightIndex else { continue }
      let leftProfile = profile(
        graph: left.graph, pageIDs: leftPages, index: leftIndex, side: "L")
      let rightProfile = profile(
        graph: right.graph, pageIDs: rightPages, index: rightIndex, side: "R")
      let leftAvailable = leftProfile.source != .unavailable
        && leftProfile.nonWhitespaceCharacters >= options.minimumTextCharacters
      let rightAvailable = rightProfile.source != .unavailable
        && rightProfile.nonWhitespaceCharacters >= options.minimumTextCharacters
      let evidence = rasterByPair[pairKey(leftIndex, rightIndex)]
      let ratio = evidence?.changedPixelRatio
      let rasterStatus: ComparisonRasterStatus
      if let ratio {
        if ratio == 0 {
          rasterStatus = .identical
        } else if ratio <= options.scanNoiseRatio {
          rasterStatus = .withinNoise
        } else {
          rasterStatus = .changed
        }
      } else {
        rasterStatus = .unavailable
      }
      let meaningfulRasterChange = ratio.map {
        $0 >= options.meaningfulChangeRatio
      } ?? false
      let anyRasterChange = ratio.map { $0 > options.scanNoiseRatio } ?? false
      let pairChanges = result.changes.filter { change in
        textKinds.contains(change.kind)
          && (change.leftPageIndex == leftIndex || change.rightPageIndex == rightIndex)
      }
      let hasTextChanges = !pairChanges.isEmpty
      let allOCRChanges = !pairChanges.isEmpty && pairChanges.allSatisfy(\.isOCRSourced)
      // Both pages carrying only generated OCR text makes their text
      // differences OCR evidence even when the change records themselves are
      // not flagged (the comparison only flags mixed-layer pairs).
      let bothGeneratedOCRText =
        leftProfile.source == .generatedOCR && rightProfile.source == .generatedOCR
      let textEvidenceIsUncertainOCR = allOCRChanges || bothGeneratedOCRText
      let uncertainText = leftProfile.source.isUncertain || rightProfile.source.isUncertain
      var pairFindings: [ComparisonQualificationFinding] = []
      var verdict: ComparisonPageQualification.Verdict

      if uncertainText {
        ocrPairs += 1
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .generatedOCRText,
            summary: "Generated OCR text is present; OCR text is uncertain evidence, not source text.",
            leftPageIndex: leftIndex, rightPageIndex: rightIndex, isOCRSourced: true))
      }
      if leftProfile.multiColumn || rightProfile.multiColumn {
        complexLayoutPairs += 1
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .complexLayout,
            summary: "Complex multi-column layout detected; line matching is unreliable, verify visually.",
            leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            isOCRSourced: uncertainText))
      }
      if let ratio, ratio > 0, ratio <= options.scanNoiseRatio {
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .rasterNoiseOnly,
            summary: String(
              format: "Rendered differences are within the scan-noise floor (%.3f%% <= %.2f%%); treated as scan/render noise.",
              ratio * 100, options.scanNoiseRatio * 100),
            leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            isOCRSourced: uncertainText))
      } else if let ratio, ratio > options.scanNoiseRatio {
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .rasterChangeConfirmed,
            summary: String(
              format: "Rendered page changed above the scan-noise floor (%.3f%% pixels; meaningful threshold %.2f%%).",
              ratio * 100, options.meaningfulChangeRatio * 100),
            leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            isOCRSourced: uncertainText))
      }

      if !leftAvailable || !rightAvailable {
        limitedPairs += 1
        let missingSide =
          !leftAvailable && !rightAvailable
          ? "both pages" : (!leftAvailable ? "the left page" : "the right page")
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .textExtractionUnavailable,
            summary: "No extractable text on \(missingSide); text equality cannot be established.",
            leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            isOCRSourced: uncertainText))
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .noTextEvidence,
            summary: "Text changes are not evidence of equality for this pair.",
            leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            isOCRSourced: uncertainText))
        if anyRasterChange {
          verdict = .visualChangeUnverified
          pairFindings.append(
            ComparisonQualificationFinding(
              kind: .rasterChangeConfirmed,
              summary: meaningfulRasterChange
                ? "A visual change is confirmed, but without extractable text its content nature is unverified."
                : "A small visual change is above scan noise but below the meaningful threshold; content nature is unverified.",
              leftPageIndex: leftIndex, rightPageIndex: rightIndex,
              isOCRSourced: uncertainText))
        } else {
          verdict = .textUnavailable
        }
      } else if hasTextChanges {
        if textEvidenceIsUncertainOCR {
          if meaningfulRasterChange {
            verdict = .confirmedContentChange
            pairFindings.append(
              ComparisonQualificationFinding(
                kind: .contentChangeConfirmed,
                summary: "OCR text difference is corroborated by a meaningful rendered-page change.",
                leftPageIndex: leftIndex, rightPageIndex: rightIndex, isOCRSourced: true))
          } else {
            verdict = .unconfirmedOCRChange
            pairFindings.append(
              ComparisonQualificationFinding(
                kind: .ocrDifferenceUnconfirmed,
                summary: "OCR text differs while the rendered page does not change meaningfully; OCR noise cannot be ruled out.",
                leftPageIndex: leftIndex, rightPageIndex: rightIndex, isOCRSourced: true))
          }
        } else {
          verdict = .confirmedContentChange
          pairFindings.append(
            ComparisonQualificationFinding(
              kind: .contentChangeConfirmed,
              summary: "Text changes are present and extractable on both pages.",
              leftPageIndex: leftIndex, rightPageIndex: rightIndex,
              isOCRSourced: uncertainText))
        }
      } else if meaningfulRasterChange {
        verdict = .confirmedRenderingDifference
        pairFindings.append(
          ComparisonQualificationFinding(
            kind: .renderingOnlyDifference,
            summary: "Rendered page differs while extractable text is equal; classify as rendering/formatting, not a content change.",
            leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            isOCRSourced: uncertainText))
      } else if anyRasterChange {
        verdict = .visualChangeUnverified
      } else {
        if leftProfile.multiColumn || rightProfile.multiColumn {
          verdict = .complexLayoutUncertain
        } else {
          verdict = .noDifferenceWithTextEvidence
          pairFindings.append(
            ComparisonQualificationFinding(
              kind: .availableTextEvidence,
              summary: "Extractable text is available on both pages and matches the comparison options.",
              leftPageIndex: leftIndex, rightPageIndex: rightIndex,
              isOCRSourced: uncertainText))
        }
      }

      findings.append(contentsOf: pairFindings)
      verdictCounts[verdict, default: 0] += 1
      let isOCR = uncertainText
      switch verdict {
      case .textUnavailable:
        addUncertainty(
          "Text extraction unavailable on page pair; absence of text changes is not proof of equality. Raster evidence: \(rasterStatus.title).",
          leftIndex: leftIndex, rightIndex: rightIndex, isOCR: isOCR)
      case .visualChangeUnverified:
        addUncertainty(
          "Rendered page change detected but text evidence is unavailable; the change cannot be confirmed from text. Raster evidence: \(rasterStatus.title).",
          leftIndex: leftIndex, rightIndex: rightIndex, isOCR: isOCR)
      case .unconfirmedOCRChange:
        addUncertainty(
          "OCR text differs while the rendered page does not change meaningfully; OCR noise cannot be ruled out.",
          leftIndex: leftIndex, rightIndex: rightIndex, isOCR: true)
      case .confirmedRenderingDifference:
        addUncertainty(
          "Rendered page differs while extractable text is equal; reported as a rendering/formatting difference, not a content change.",
          leftIndex: leftIndex, rightIndex: rightIndex, isOCR: false)
      case .complexLayoutUncertain:
        addUncertainty(
          "Complex multi-column layout makes text alignment uncertain; verify this page pair visually.",
          leftIndex: leftIndex, rightIndex: rightIndex, isOCR: isOCR)
      default:
        break
      }
      pages.append(
        ComparisonPageQualification(
          leftPageIndex: leftIndex, rightPageIndex: rightIndex,
          leftTextSource: leftProfile.source, rightTextSource: rightProfile.source,
          rasterStatus: rasterStatus, changedPixelRatio: ratio, verdict: verdict,
          findings: pairFindings))
    }

    var summaryLines: [String] = []
    summaryLines.append(
      "Qualified \(pages.count) page pair(s); \(limitedPairs) pair(s) have insufficient text evidence; "
        + "\(unpairedCount) unpaired page(s).")
    let verdictOrder: [ComparisonPageQualification.Verdict] = [
      .confirmedContentChange, .confirmedRenderingDifference, .unconfirmedOCRChange,
      .noDifferenceWithTextEvidence, .scanNoise, .textUnavailable,
      .visualChangeUnverified, .complexLayoutUncertain, .unpaired,
    ]
    let verdictSummary = verdictOrder.compactMap { verdict -> String? in
      guard let count = verdictCounts[verdict], count > 0 else { return nil }
      return "\(verdict.rawValue): \(count)"
    }.joined(separator: ", ")
    summaryLines.append("Verdicts: " + (verdictSummary.isEmpty ? "none" : verdictSummary) + ".")
    summaryLines.append("Evidence thresholds: " + options.summary + ".")
    summaryLines.append(
      "Raster evidence supplied for \(rasterByPair.count) pair(s); "
        + "unmatched evidence records are ignored.")
    if limitedPairs > 0 {
      summaryLines.append(
        "Text extraction is unavailable or insufficient on \(limitedPairs) pair(s). No-change results for those pages are NOT reported as proof of equality.")
    } else {
      summaryLines.append(
        "Every compared page pair had extractable text evidence; no pair relies on missing text extraction.")
    }
    if ocrPairs > 0 {
      summaryLines.append(
        "\(ocrPairs) pair(s) involve generated OCR text; OCR-only differences are treated as uncertain and require raster corroboration.")
    }
    if complexLayoutPairs > 0 {
      summaryLines.append(
        "\(complexLayoutPairs) pair(s) have complex multi-column layout; line matching may be unreliable.")
    }
    if unpairedCount > 0 {
      summaryLines.append(
        "\(unpairedCount) inserted/deleted page(s) have no counterpart and are listed as unpaired.")
    }
    return ComparisonQualificationResult(
      pages: pages, findings: findings, qualifiedChanges: qualifiedChanges,
      summaryLines: summaryLines, options: options)
  }

  static func pairKey(_ leftIndex: Int, _ rightIndex: Int) -> String {
    "\(leftIndex):\(rightIndex)"
  }
}
