import Foundation
import PDFCore

// MARK: - REV-05 comparison scopes and change categories

/// REV-05: user-selectable comparison scopes. A scope is a named bundle of the
/// existing per-channel options, so the report always states exactly which
/// channels were compared.
public enum ComparisonScopePreset: String, Sendable, CaseIterable {
  case content
  case formatting
  case full
  case scans

  public var title: String {
    switch self {
    case .content: return "Content"
    case .formatting: return "Content + formatting"
    case .full: return "Everything"
    case .scans: return "Scans + OCR"
    }
  }

  public var detail: String {
    switch self {
    case .content:
      return "Text (whitespace-insensitive) and images; page boxes, annotations, forms, metadata and attachments are ignored."
    case .formatting:
      return "Text (whitespace-sensitive), images and page box/rotation; annotations, forms, metadata and attachments are ignored."
    case .full:
      return "Every supported channel: text, images, annotations, form values, page boxes, metadata, attachments, signatures and encryption."
    case .scans:
      return "Images plus any available generated OCR text; whole-document metadata/forms are ignored and raster evidence qualifies the result."
    }
  }

  public var options: PDFComparisonOptions {
    switch self {
    case .content:
      return PDFComparisonOptions(
        ignoreWhitespace: true, includeText: true, includeImages: true,
        includeAnnotations: false, includeForms: false, includeMetadata: false,
        includeOCRText: true)
    case .formatting:
      return PDFComparisonOptions(
        ignoreWhitespace: false, includeText: true, includeImages: true,
        includeAnnotations: false, includeForms: false, includeMetadata: false,
        includeOCRText: true)
    case .full:
      return PDFComparisonOptions(
        ignoreWhitespace: true, includeText: true, includeImages: true,
        includeAnnotations: true, includeForms: true, includeMetadata: true,
        includeOCRText: true)
    case .scans:
      return PDFComparisonOptions(
        ignoreWhitespace: true, includeText: true, includeImages: true,
        includeAnnotations: false, includeForms: false, includeMetadata: false,
        includeOCRText: true)
    }
  }

  public static func matching(_ options: PDFComparisonOptions) -> ComparisonScopePreset? {
    allCases.first { $0.options == options }
  }
}

extension PDFComparisonOptions {
  public init(scopePreset: ComparisonScopePreset) {
    self = scopePreset.options
  }

  /// One-line disclosure for reports: which channels the comparison covered.
  public var scopeSummary: String {
    var channels: [String] = []
    if includeText { channels.append(ignoreWhitespace ? "text" : "text (exact whitespace)") }
    if includeImages { channels.append("images") }
    if includeAnnotations { channels.append("annotations") }
    if includeForms { channels.append("forms") }
    if includeMetadata { channels.append("metadata") }
    if includeOCRText { channels.append("generated OCR text") }
    let scope = ComparisonScopePreset.matching(self)?.title ?? "Custom"
    return scope + ": " + channels.joined(separator: ", ")
  }
}

/// REV-05: what a reported difference actually is. Content changes alter the
/// document; formatting differences alter layout/appearance; rendering and
/// scan-noise findings are produced by evidence qualification (REV-06).
public enum ComparisonChangeCategory: String, Sendable, CaseIterable {
  case pageStructure
  case content
  case formatting
  case rendering
  case documentStatus
  case uncertainty

  public var title: String {
    switch self {
    case .pageStructure: return "Page structure"
    case .content: return "Content"
    case .formatting: return "Formatting"
    case .rendering: return "Rendering / scan"
    case .documentStatus: return "Document status"
    case .uncertainty: return "Uncertainty"
    }
  }
}

public enum ComparisonClassification {
  public static func category(of kind: PDFComparisonChange.Kind) -> ComparisonChangeCategory {
    switch kind {
    case .pageInserted, .pageDeleted, .pageReordered:
      return .pageStructure
    case .pageBoxOrRotation, .imageMoved, .imageResized:
      return .formatting
    case .textAdded, .textRemoved, .textChanged, .imageAdded, .imageRemoved,
      .annotationAdded, .annotationRemoved, .annotationChanged, .formValueChanged:
      return .content
    case .metadataChanged, .attachmentChanged, .signatureStatus, .encryptionStatus:
      return .documentStatus
    case .uncertainty:
      return .uncertainty
    }
  }

  public static func categories(in changes: [PDFComparisonChange]) -> [ComparisonChangeCategory] {
    var seen: Set<ComparisonChangeCategory> = []
    var result: [ComparisonChangeCategory] = []
    for change in changes {
      let category = change.category
      if seen.insert(category).inserted { result.append(category) }
    }
    return result
  }
}

extension PDFComparisonChange {
  public var category: ComparisonChangeCategory {
    ComparisonClassification.category(of: kind)
  }
}

// MARK: - REV-05 alignment audit

public struct ComparisonAlignmentWarning: Sendable, Equatable {
  public enum Severity: String, Sendable, Equatable {
    case info
    case warning
  }

  public let severity: Severity
  public let summary: String
  public let leftPageIndices: [Int]
  public let rightPageIndices: [Int]

  public init(
    severity: Severity, summary: String, leftPageIndices: [Int] = [],
    rightPageIndices: [Int] = []
  ) {
    self.severity = severity
    self.summary = summary
    self.leftPageIndices = leftPageIndices
    self.rightPageIndices = rightPageIndices
  }
}

/// REV-05: an explainable alignment report. The mapping is the one that will
/// be used (automatic, or the user's override); suggestedMapping is a
/// repeated-page-aware alternative that avoids cascades, and warnings state
/// where repeated content makes the automatic pairing ambiguous.
public struct ComparisonAlignmentAudit: Sendable, Equatable {
  public let mapping: [PDFComparisonResult.PagePair]
  public let suggestedMapping: [PDFComparisonResult.PagePair]
  public let warnings: [ComparisonAlignmentWarning]
  public let leftRepeatedGroups: [[Int]]
  public let rightRepeatedGroups: [[Int]]
  public let ambiguousPageCount: Int
  public let manualOverride: Bool

  public var isAmbiguous: Bool { ambiguousPageCount > 0 }

  public var summaryLines: [String] {
    var lines: [String] = []
    lines.append(
      "Page pairs: \(mapping.count); repeated left pages: \(leftRepeatedGroups.count) group(s); "
        + "repeated right pages: \(rightRepeatedGroups.count) group(s).")
    if manualOverride { lines.append("A manual page-pairing override is active.") }
    if mapping != suggestedMapping {
      lines.append("A repeated-page-aware suggestion differs from the current pairing.")
    }
    for warning in warnings {
      lines.append((warning.severity == .warning ? "Warning: " : "") + warning.summary)
    }
    return lines
  }
}

public enum PDFComparisonAlignment {
  /// REV-05: audit automatic/manual pairing for repeated pages and offer a
  /// suggestion that pairs identical repeated content in document order.
  public static func audit(
    left: (graph: PDFGraph, source: Data), right: (graph: PDFGraph, source: Data),
    options: PDFComparisonOptions = PDFComparisonOptions(),
    mappingOverride: [PDFComparisonResult.PagePair]? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> ComparisonAlignmentAudit {
    let leftPages = try PDFPageTree.pageIDs(in: left.graph)
    let rightPages = try PDFPageTree.pageIDs(in: right.graph)
    let leftSummaries = try PDFComparison.pageSummaries(
      graph: left.graph, pageIDs: leftPages, limits: limits)
    let rightSummaries = try PDFComparison.pageSummaries(
      graph: right.graph, pageIDs: rightPages, limits: limits)
    let automatic = PDFComparison.align(left: leftSummaries, right: rightSummaries)
    if let mappingOverride {
      try validate(
        mapping: mappingOverride, leftPageCount: leftPages.count,
        rightPageCount: rightPages.count)
    }
    let mapping = mappingOverride ?? automatic
    let leftGroups = repeatedGroups(leftSummaries)
    let rightGroups = repeatedGroups(rightSummaries)
    var warnings: [ComparisonAlignmentWarning] = []
    if !leftGroups.isEmpty || !rightGroups.isEmpty {
      let leftIndices = leftGroups.flatMap { $0 }.sorted()
      let rightIndices = rightGroups.flatMap { $0 }.sorted()
      var summary =
        "Repeated page content can make the automatic pairing ambiguous: "
        + "\(leftGroups.count) repeated group(s) on the left, "
        + "\(rightGroups.count) on the right."
      if mappingOverride != nil {
        summary += " Review the manual pairing of those pages."
      } else {
        summary += " Review the pairing of the listed pages before trusting inserted/deleted counts."
      }
      warnings.append(
        ComparisonAlignmentWarning(
          severity: .warning, summary: summary, leftPageIndices: leftIndices,
          rightPageIndices: rightIndices))
    }
    let reorderedCount = mapping.filter { $0.status == .reordered }.count
    if reorderedCount > 1 {
      warnings.append(
        ComparisonAlignmentWarning(
          severity: .info,
          summary: "\(reorderedCount) pages are paired out of order; repeated content may make a single block move look like several moves."))
    }
    if mappingOverride == nil {
      let inserted = mapping.filter { $0.status == .inserted }.count
      let deleted = mapping.filter { $0.status == .deleted }.count
      if inserted > 0, deleted > 0, !leftGroups.isEmpty || !rightGroups.isEmpty {
        warnings.append(
          ComparisonAlignmentWarning(
            severity: .warning,
            summary: "Both insertions and deletions are reported while repeated pages exist; verify the pairing instead of relying on the cascade."))
      }
    } else {
      warnings.append(
        ComparisonAlignmentWarning(
          severity: .info, summary: "Manual pairing override is active."))
    }
    let suggested = suggest(
      automatic: automatic, left: leftSummaries, right: rightSummaries,
      leftGroups: leftGroups, rightGroups: rightGroups)
    var ambiguous = 0
    for pair in mapping {
      guard let leftIndex = pair.leftIndex, let rightIndex = pair.rightIndex else { continue }
      if leftGroups.contains(where: { $0.contains(leftIndex) })
        || rightGroups.contains(where: { $0.contains(rightIndex) })
      {
        ambiguous += 1
      }
    }
    return ComparisonAlignmentAudit(
      mapping: mapping, suggestedMapping: suggested, warnings: warnings,
      leftRepeatedGroups: leftGroups, rightRepeatedGroups: rightGroups,
      ambiguousPageCount: ambiguous, manualOverride: mappingOverride != nil)
  }

  /// REV-05: validate a user-supplied pairing before using it as an override.
  public static func validate(
    mapping: [PDFComparisonResult.PagePair], leftPageCount: Int, rightPageCount: Int
  ) throws {
    var usedLeft: Set<Int> = []
    var usedRight: Set<Int> = []
    for pair in mapping {
      if let leftIndex = pair.leftIndex {
        guard leftIndex >= 0, leftIndex < leftPageCount else {
          throw PDFError(.malformed, "The pairing refers to a left page that does not exist")
        }
        guard usedLeft.insert(leftIndex).inserted else {
          throw PDFError(.malformed, "The pairing uses the same left page twice")
        }
      }
      if let rightIndex = pair.rightIndex {
        guard rightIndex >= 0, rightIndex < rightPageCount else {
          throw PDFError(.malformed, "The pairing refers to a right page that does not exist")
        }
        guard usedRight.insert(rightIndex).inserted else {
          throw PDFError(.malformed, "The pairing uses the same right page twice")
        }
      }
      guard pair.leftIndex != nil || pair.rightIndex != nil else {
        throw PDFError(.malformed, "The pairing contains an empty pair")
      }
    }
  }

  /// REV-05: corrected mapping with one left page paired to a chosen right page
  /// (or unpaired). The previously paired right page is released.
  public static func correctedMapping(
    _ mapping: [PDFComparisonResult.PagePair], leftIndex: Int, toRightIndex: Int?
  ) -> [PDFComparisonResult.PagePair] {
    var corrected: [PDFComparisonResult.PagePair] = []
    for pair in mapping {
      if pair.leftIndex == leftIndex {
        corrected.append(
          PDFComparisonResult.PagePair(
            leftIndex: leftIndex, rightIndex: toRightIndex,
            status: toRightIndex == nil ? .deleted : .matched))
      } else if let right = pair.rightIndex, right == toRightIndex {
        corrected.append(
          PDFComparisonResult.PagePair(
            leftIndex: pair.leftIndex, rightIndex: nil, status: .deleted))
      } else {
        corrected.append(pair)
      }
    }
    return corrected
  }

  // MARK: Internals

  static func repeatedGroups(_ summaries: [PDFComparison.PageSummary]) -> [[Int]] {
    var groups: [String: [Int]] = [:]
    for summary in summaries {
      groups[summary.signature, default: []].append(summary.index)
    }
    return groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted {
      ($0.first ?? 0) < ($1.first ?? 0)
    }
  }

  static func suggest(
    automatic: [PDFComparisonResult.PagePair],
    left: [PDFComparison.PageSummary], right: [PDFComparison.PageSummary],
    leftGroups: [[Int]], rightGroups: [[Int]]
  ) -> [PDFComparisonResult.PagePair] {
    guard !leftGroups.isEmpty || !rightGroups.isEmpty else { return automatic }
    var leftToRight: [Int: Int] = [:]
    var usedRight: Set<Int> = []
    for pair in automatic {
      guard let leftIndex = pair.leftIndex, let rightIndex = pair.rightIndex else { continue }
      leftToRight[leftIndex] = rightIndex
      usedRight.insert(rightIndex)
    }
    let repeatedLeftIndices = leftGroups.flatMap { $0 }
    for signature in Set(left.map(\.signature)) {
      let leftIndices = repeatedLeftIndices.filter { left[$0].signature == signature }.sorted()
      guard !leftIndices.isEmpty else { continue }
      let rightIndices = right.indices.filter { right[$0].signature == signature }.sorted()
      guard !rightIndices.isEmpty else { continue }
      for (offset, leftIndex) in leftIndices.enumerated() {
        if offset < rightIndices.count {
          if let previous = leftToRight[leftIndex] { usedRight.remove(previous) }
          leftToRight[leftIndex] = rightIndices[offset]
          usedRight.insert(rightIndices[offset])
        } else {
          leftToRight[leftIndex] = nil
        }
      }
    }
    let automaticLeft = Set(automatic.compactMap(\.leftIndex))
    let unpairedLeft = left.indices.filter {
      leftToRight[$0] == nil && !automaticLeft.contains($0)
    }
    let unpairedRight = right.indices.filter { !usedRight.contains($0) }
    for leftIndex in unpairedLeft {
      if let match = unpairedRight.first(where: {
        !usedRight.contains($0) && right[$0].signature == left[leftIndex].signature
      }) {
        leftToRight[leftIndex] = match
        usedRight.insert(match)
      }
    }
    var pairs: [PDFComparisonResult.PagePair] = []
    for leftIndex in left.indices {
      if let rightIndex = leftToRight[leftIndex] {
        pairs.append(
          PDFComparisonResult.PagePair(
            leftIndex: leftIndex, rightIndex: rightIndex, status: .matched))
      } else if !automaticLeft.contains(leftIndex) {
        pairs.append(
          PDFComparisonResult.PagePair(
            leftIndex: leftIndex, rightIndex: nil, status: .deleted))
      }
    }
    let coveredRight = Set(pairs.compactMap(\.rightIndex))
    for pair in automatic {
      if pair.leftIndex == nil, let rightIndex = pair.rightIndex,
        !coveredRight.contains(rightIndex)
      {
        pairs.append(
          PDFComparisonResult.PagePair(
            leftIndex: nil, rightIndex: rightIndex, status: .inserted))
      }
    }
    if pairs.isEmpty { return automatic }
    return pairs
  }
}
