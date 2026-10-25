import Foundation
import PDFCore

// MARK: - REV-07 portable comparison report

/// Rendered page images for one mapping pair of the comparison report.
public struct ComparisonReportPairImages: Sendable, Equatable {
  public let left: ReportRasterImage?
  public let right: ReportRasterImage?

  public init(left: ReportRasterImage?, right: ReportRasterImage?) {
    self.left = left
    self.right = right
  }
}

/// Report presentation options. The comparison options themselves live in
/// PDFComparisonOptions and are recorded verbatim in the report.
public struct ComparisonReportOptions: Sendable, Equatable {
  public var title: String
  public var subtitle: String?
  public var leftLabel: String
  public var rightLabel: String
  public var generatedOn: String?
  /// True when the page mapping was manually corrected before generating this
  /// report; recorded as a mapping-provenance record.
  public var mappingWasEdited: Bool
  public var includeUnchangedPairs: Bool
  public var includePageImages: Bool
  public var format: ReportPageFormat

  public init(
    title: String = "Comparison Report",
    subtitle: String? = nil,
    leftLabel: String = "Left document",
    rightLabel: String = "Right document",
    generatedOn: String? = nil,
    mappingWasEdited: Bool = false,
    includeUnchangedPairs: Bool = false,
    includePageImages: Bool = true,
    format: ReportPageFormat = .letter
  ) {
    self.title = title
    self.subtitle = subtitle
    self.leftLabel = leftLabel
    self.rightLabel = rightLabel
    self.generatedOn = generatedOn
    self.mappingWasEdited = mappingWasEdited
    self.includeUnchangedPairs = includeUnchangedPairs
    self.includePageImages = includePageImages
    self.format = format
  }
}

/// Everything the portable comparison report needs. Images are supplied by the
/// caller (the App renders them); the core builder stays deterministic.
public struct ComparisonReportRequest: Sendable, Equatable {
  public let result: PDFComparisonResult
  public let comparisonOptions: PDFComparisonOptions
  public let options: ComparisonReportOptions
  /// Rendered page images keyed by page-mapping index.
  public let pairImages: [Int: ComparisonReportPairImages]
  /// Rendered change-region crops keyed by index into result.changes.
  public let regionImages: [Int: ReportRasterImage]

  public init(
    result: PDFComparisonResult,
    comparisonOptions: PDFComparisonOptions = PDFComparisonOptions(),
    options: ComparisonReportOptions = ComparisonReportOptions(),
    pairImages: [Int: ComparisonReportPairImages] = [:],
    regionImages: [Int: ReportRasterImage] = [:]
  ) {
    self.result = result
    self.comparisonOptions = comparisonOptions
    self.options = options
    self.pairImages = pairImages
    self.regionImages = regionImages
  }
}

/// One change as recorded in the report manifest.
public struct ComparisonReportChangeRecord: Sendable, Equatable, Identifiable {
  public var id: Int { index }
  public let index: Int
  public let kind: String
  public let summary: String
  public let leftPageLabel: String?
  public let rightPageLabel: String?
  public let leftBounds: [Double]?
  public let rightBounds: [Double]?
  public let isOCRSourced: Bool
  public let isDocumentLevel: Bool
  public let hasRegionImage: Bool
}

/// One page-mapping record, including uncertainty.
public struct ComparisonReportMappingRecord: Sendable, Equatable, Identifiable {
  public var id: Int { pairIndex }
  public let pairIndex: Int
  public let leftPageLabel: String?
  public let rightPageLabel: String?
  public let status: String
  public let isUncertain: Bool
}

/// The generated comparison report plus its manifest.
public struct ComparisonReport: Sendable, Equatable {
  public let data: Data
  public let pageCount: Int
  public let changeRecords: [ComparisonReportChangeRecord]
  public let mappingRecords: [ComparisonReportMappingRecord]
  /// Explicit uncertainty records: uncertain pairs, uncertainty changes, OCR
  /// sourced evidence and tolerance/mapping-provenance notes.
  public let uncertaintyRecords: [String]
  public let optionLines: [String]
  public let changeCounts: [String: Int]

  public var isEmpty: Bool { changeRecords.isEmpty }

  public var summary: String {
    if isEmpty {
      return "Comparison report PDF: no differences under the chosen options (\(pageCount) page(s))."
    }
    return
      "Comparison report PDF: \(changeRecords.count) change(s), "
      + "\(mappingRecords.count) page-mapping record(s), "
      + "\(uncertaintyRecords.count) uncertainty note(s); \(pageCount) report page(s)."
  }
}

public enum ComparisonReportBuilder {
  public static let maximumChanges = 2_000
  public static let maximumTextLength = 600

  /// Build the portable comparison report without mutating either document.
  public static func build(
    _ request: ComparisonReportRequest,
    limits: PDFLimits = PDFLimits()
  ) throws -> ComparisonReport {
    let result = request.result
    guard result.changes.count <= maximumChanges else {
      throw PDFError(
        .limitExceeded,
        "This comparison has \(result.changes.count) changes; the report profile supports up to \(maximumChanges)")
    }
    for (pairIndex, images) in request.pairImages {
      guard pairIndex >= 0, pairIndex < result.pageMapping.count else {
        throw PDFError(.malformed, "A comparison page image is keyed to a missing pair")
      }
      if let left = images.left, !left.isValid {
        throw PDFError(.malformed, "A comparison left page image is invalid")
      }
      if let right = images.right, !right.isValid {
        throw PDFError(.malformed, "A comparison right page image is invalid")
      }
    }
    for (changeIndex, image) in request.regionImages {
      guard changeIndex >= 0, changeIndex < result.changes.count else {
        throw PDFError(.malformed, "A comparison region image is keyed to a missing change")
      }
      guard image.isValid else {
        throw PDFError(.malformed, "A comparison region image is invalid")
      }
    }

    let pairIndexByRight: [Int: Int] = Dictionary(
      uniqueKeysWithValues: result.pageMapping.enumerated().compactMap {
        pairIndex, pair -> (Int, Int)? in
        guard let right = pair.rightIndex else { return nil }
        return (right, pairIndex)
      })
    let pairIndexByLeft: [Int: Int] = Dictionary(
      uniqueKeysWithValues: result.pageMapping.enumerated().compactMap {
        pairIndex, pair -> (Int, Int)? in
        guard let left = pair.leftIndex else { return nil }
        return (left, pairIndex)
      })
    func pairIndex(for change: PDFComparisonChange) -> Int? {
      if let right = change.rightPageIndex, let index = pairIndexByRight[right] {
        return index
      }
      if let left = change.leftPageIndex, let index = pairIndexByLeft[left] {
        return index
      }
      return nil
    }
    var changesByPair: [Int: [Int]] = [:]
    var documentLevelChanges: [Int] = []
    for (index, change) in result.changes.enumerated() {
      if let pair = pairIndex(for: change) {
        changesByPair[pair, default: []].append(index)
      } else {
        documentLevelChanges.append(index)
      }
    }

    let comparisonOptionLines = describe(comparisonOptions: request.comparisonOptions)
    var optionLines = comparisonOptionLines
    optionLines.append(
      "report.includeUnchangedPairs=\(request.options.includeUnchangedPairs)")
    optionLines.append(
      "report.mappingSource=\(request.options.mappingWasEdited ? "manually corrected" : "automatic")")
    optionLines.append(
      "report.pageImages=\(request.options.includePageImages ? "included when supplied" : "disabled")")
    optionLines.append("report.format=\(request.options.format.rawValue)")

    var uncertaintyRecords: [String] = []
    for (index, pair) in result.pageMapping.enumerated() where pair.status == .uncertain {
      uncertaintyRecords.append(
        "Pair \(index + 1): uncertain page mapping "
          + "\(label(left: pair.leftIndex)) <-> \(label(right: pair.rightIndex))")
    }
    for (index, change) in result.changes.enumerated() where change.kind == .uncertainty {
      uncertaintyRecords.append(
        "Change \(index + 1): uncertainty | \(ReportText.display(clip(change.summary)))"
          + (change.isOCRSourced ? " | OCR-sourced evidence" : ""))
    }
    if request.comparisonOptions.visualTolerance > 0 {
      uncertaintyRecords.append(
        "Rendered-difference tolerance: \(request.comparisonOptions.visualTolerance) per channel; "
          + "sub-tolerance visual differences are not reported.")
    }
    if request.options.mappingWasEdited {
      uncertaintyRecords.append(
        "Page mapping provenance: manually corrected before this report was generated.")
    }
    let ocrSourced = result.changes.filter(\.isOCRSourced).count
    if ocrSourced > 0 {
      uncertaintyRecords.append(
        "\(ocrSourced) change(s) rely on generated OCR text evidence and are marked [OCR].")
    }

    var changeRecords: [ComparisonReportChangeRecord] = []
    for (index, change) in result.changes.enumerated() {
      changeRecords.append(
        ComparisonReportChangeRecord(
          index: index,
          kind: change.kind.rawValue,
          summary: change.summary,
          leftPageLabel: change.leftPageIndex.map { "Left page \($0 + 1)" },
          rightPageLabel: change.rightPageIndex.map { "Right page \($0 + 1)" },
          leftBounds: change.leftBounds,
          rightBounds: change.rightBounds,
          isOCRSourced: change.isOCRSourced,
          isDocumentLevel: change.leftPageIndex == nil && change.rightPageIndex == nil,
          hasRegionImage: request.regionImages[index] != nil))
    }
    var mappingRecords: [ComparisonReportMappingRecord] = []
    for (index, pair) in result.pageMapping.enumerated() {
      mappingRecords.append(
        ComparisonReportMappingRecord(
          pairIndex: index,
          leftPageLabel: pair.leftIndex.map { "Left page \($0 + 1)" },
          rightPageLabel: pair.rightIndex.map { "Right page \($0 + 1)" },
          status: pair.status.rawValue,
          isUncertain: pair.status == .uncertain))
    }
    var changeCounts: [String: Int] = [:]
    for change in result.changes {
      changeCounts[change.kind.rawValue, default: 0] += 1
    }

    var composer = ReportComposer(
      format: request.options.format, title: request.options.title,
      subject: "Document comparison report")
    try composer.titleBlock(
      request.options.title,
      subtitles: [
        request.options.subtitle ?? "Portable document comparison",
        "Left: \(request.options.leftLabel) | Right: \(request.options.rightLabel)",
      ])
    if let generatedOn = request.options.generatedOn, !generatedOn.isEmpty {
      try composer.paragraph(
        "Generated: \(generatedOn)", size: ReportComposer.Typography.smallSize)
    }
    try composer.divider()
    try composer.paragraph(
      "Summary", size: ReportComposer.Typography.subheadingSize, bold: true)
    try composer.paragraph(
      "Pages: \(result.left.pageCount) -> \(result.right.pageCount)")
    try composer.paragraph(
      "Encrypted: \(result.left.isEncrypted ? "yes" : "no") -> "
        + "\(result.right.isEncrypted ? "yes" : "no")")
    try composer.paragraph(
      "Signatures: \(result.left.signatureCount) -> \(result.right.signatureCount)")
    try composer.paragraph(
      "Generated OCR layers: \(result.left.hasOCRLayers ? "yes" : "no") -> "
        + "\(result.right.hasOCRLayers ? "yes" : "no")")
    try composer.paragraph(
      "Changes: \(result.changes.count)"
        + (result.changes.isEmpty ? " (no differences detected under these options)" : ""))
    for kind in PDFComparisonChange.Kind.allCases {
      if let count = changeCounts[kind.rawValue] {
        try composer.paragraph("  \(kind.rawValue): \(count)", indent: 10, spacingAfter: 0.5)
      }
    }
    try composer.paragraph(
      "OCR-sourced changes: \(ocrSourced)")
    try composer.paragraph(
      "Page mapping: \(result.pageMapping.count) pair(s); "
        + "\(result.pageMapping.filter { $0.status == .uncertain }.count) uncertain; "
        + "source: \(request.options.mappingWasEdited ? "manually corrected" : "automatic")")
    try composer.paragraph(
      "Uncertainty records: \(uncertaintyRecords.count)")

    try composer.heading("Chosen options")
    for line in optionLines {
      try composer.paragraph(line, size: ReportComposer.Typography.smallSize, spacingAfter: 0.5)
    }

    try composer.heading("Page mapping")
    if result.pageMapping.isEmpty {
      try composer.paragraph("The comparison reported no page mapping records.")
    } else {
      for (index, pair) in result.pageMapping.enumerated() {
        var line = "Pair \(index + 1): \(label(left: pair.leftIndex)) <-> "
        line += label(right: pair.rightIndex) + " | \(pair.status.rawValue)"
        if pair.status == .uncertain { line += " | UNCERTAIN" }
        try composer.paragraph(line, size: ReportComposer.Typography.smallSize, spacingAfter: 0.5)
      }
    }

    try composer.heading("Differences")
    if result.changes.isEmpty {
      try composer.paragraph(
        "No differences were detected between the two documents under the chosen options. "
          + "The mapping above still records how the two documents were paired.")
    } else {
      var pairContextPages: [Int] = []
      for (pairIndex, _) in result.pageMapping.enumerated() {
        let hasChanges = !(changesByPair[pairIndex] ?? []).isEmpty
        if hasChanges || request.options.includeUnchangedPairs { pairContextPages.append(pairIndex) }
      }
      for pairIndex in pairContextPages {
        let pair = result.pageMapping[pairIndex]
        let pairImagesProvided = request.options.includePageImages
          && (request.pairImages[pairIndex]?.left != nil
            || request.pairImages[pairIndex]?.right != nil)
        composer.ensureSpace(pairImagesProvided ? 330 : 110)
        try composer.subheading(
          "\(label(left: pair.leftIndex)) <-> \(label(right: pair.rightIndex)) | "
            + pair.status.rawValue + (pair.status == .uncertain ? " | UNCERTAIN" : ""))
        if request.options.includePageImages,
          let images = request.pairImages[pairIndex],
          images.left != nil || images.right != nil
        {
          try composer.sideBySideImages(left: images.left, right: images.right)
        } else if request.options.includePageImages {
          try composer.paragraph(
            "(No page images were supplied for this pair.)",
            size: ReportComposer.Typography.smallSize)
        }
        let indexes = changesByPair[pairIndex] ?? []
        if indexes.isEmpty {
          try composer.paragraph(
            "No content differences reported for this pair.",
            size: ReportComposer.Typography.smallSize)
        }
        for changeIndex in indexes {
          try changeDetail(
            change: result.changes[changeIndex], index: changeIndex,
            regionImage: request.regionImages[changeIndex], composer: &composer)
        }
      }
      if !documentLevelChanges.isEmpty {
        try composer.heading("Document-level changes")
        for changeIndex in documentLevelChanges {
          try changeDetail(
            change: result.changes[changeIndex], index: changeIndex,
            regionImage: request.regionImages[changeIndex], composer: &composer)
        }
      }
    }

    try composer.heading("Uncertainty and mapping records")
    if uncertaintyRecords.isEmpty {
      try composer.paragraph(
        "No uncertainty records were reported by this comparison.")
    } else {
      for record in uncertaintyRecords {
        try composer.paragraph(
          record, size: ReportComposer.Typography.smallSize, spacingAfter: 0.5)
      }
    }
    try composer.divider()
    try composer.paragraph(
      "This report is self-contained: every reported change states its kind, page mapping and page-space "
        + "bounds, and marks OCR-sourced evidence. Another person can assess the differences without opening "
        + "the comparison session in sPDF Editor.",
      size: ReportComposer.Typography.smallSize)
    try composer.paragraph(
      "Generated locally by sPDF Editor. No document content left this machine.",
      size: ReportComposer.Typography.smallSize)

    if composer.pageCount > 300 {
      throw PDFError(
        .limitExceeded, "The comparison report would exceed the 300-page report limit")
    }
    let data = try composer.finish(limits: limits)
    return ComparisonReport(
      data: data,
      pageCount: composer.pageCount,
      changeRecords: changeRecords,
      mappingRecords: mappingRecords,
      uncertaintyRecords: uncertaintyRecords,
      optionLines: optionLines,
      changeCounts: changeCounts)
  }

  // MARK: Details

  private static func changeDetail(
    change: PDFComparisonChange, index: Int, regionImage: ReportRasterImage?,
    composer: inout ReportComposer
  ) throws {
    try composer.paragraph(
      "\(index + 1). \(change.kind.rawValue) | \(ReportText.display(clip(change.summary)))",
      size: 9.5, bold: true, spacingAfter: 1)
    var line = "Pages: \(label(left: change.leftPageIndex)) <-> "
      + label(right: change.rightPageIndex)
    if change.isOCRSourced { line += " | [OCR] generated OCR text evidence" }
    try composer.paragraph(
      line, size: ReportComposer.Typography.smallSize, indent: 10, spacingAfter: 0.5)
    if let leftBounds = change.leftBounds {
      try composer.paragraph(
        "Left bounds (page space): " + formatBounds(leftBounds),
        size: ReportComposer.Typography.smallSize, indent: 10, spacingAfter: 0.5)
    }
    if let rightBounds = change.rightBounds {
      try composer.paragraph(
        "Right bounds (page space): " + formatBounds(rightBounds),
        size: ReportComposer.Typography.smallSize, indent: 10, spacingAfter: 0.5)
    }
    if let regionImage, regionImage.isValid {
      try composer.image(regionImage, maxWidth: 300, maxHeight: 170)
    }
    try composer.spacer(5)
  }

  // MARK: Helpers

  static func label(left: Int?) -> String {
    guard let left else { return "no page" }
    return "Left page \(left + 1)"
  }

  static func label(right: Int?) -> String {
    guard let right else { return "no page" }
    return "Right page \(right + 1)"
  }

  static func label(left: Int?, right: Int?) -> String {
    "\(label(left: left)) <-> \(label(right: right))"
  }

  static func clip(_ text: String) -> String {
    ReportText.clipped(ReportText.normalized(text), maximum: maximumTextLength).text
  }

  static func formatBounds(_ bounds: [Double]) -> String {
    bounds.map { value in
      let rounded = (value * 100).rounded() / 100
      if rounded == rounded.rounded() { return String(Int(rounded)) }
      return String(rounded)
    }.joined(separator: ", ")
  }

  /// Human-readable chosen comparison options (also stored in the manifest).
  public static func describe(comparisonOptions: PDFComparisonOptions) -> [String] {
    var lines: [String] = []
    lines.append("ignoreWhitespace=\(comparisonOptions.ignoreWhitespace)")
    lines.append("includeText=\(comparisonOptions.includeText)")
    lines.append("includeImages=\(comparisonOptions.includeImages)")
    lines.append("includeAnnotations=\(comparisonOptions.includeAnnotations)")
    lines.append("includeForms=\(comparisonOptions.includeForms)")
    lines.append("includeMetadata=\(comparisonOptions.includeMetadata)")
    lines.append("includeOCRText=\(comparisonOptions.includeOCRText)")
    lines.append("visualTolerance=\(comparisonOptions.visualTolerance)")
    return lines
  }
}
