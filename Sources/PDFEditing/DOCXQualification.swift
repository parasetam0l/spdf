import Foundation
import PDFCore

/// EXP-01: qualify the owned PDF-to-DOCX reconstruction by document class.
///
/// The four required dimensions are scored separately and never collapsed into
/// a single "pass":
///
/// * text completeness - normalized source characters present in the
///   reconstruction (order-independent; reading order is a structure check);
/// * editability - reconstructed characters that live in editable text runs
///   (paragraphs, headings, lists, table cells, header/footer) rather than
///   images/appearance blocks;
/// * structure - class-specific expectations (columns, lists, headers/footers,
///   text boxes, images, footnotes, complex tables) detected in the block model;
/// * rendered layout - a LOCAL PROXY from reconstruction geometry and the
///   bounded DOCX preview. The intended Office application is deliberately not
///   launched by this workstream, so the Office-rendering measurement is
///   reported as not executed and attached as a limitation instead of being
///   claimed as a pass.
public enum DOCXDocumentClass: String, Sendable, Equatable, CaseIterable {
  case baselineProse
  case columns
  case lists
  case headersFooters
  case textBoxes
  case images
  case footnotes
  case complexTables

  public var displayName: String {
    switch self {
    case .baselineProse: return "Baseline prose"
    case .columns: return "Columns"
    case .lists: return "Lists"
    case .headersFooters: return "Headers and footers"
    case .textBoxes: return "Text boxes"
    case .images: return "Images"
    case .footnotes: return "Footnotes"
    case .complexTables: return "Complex tables"
    }
  }
}

public enum DOCXQualificationDimension: String, Sendable, Equatable, CaseIterable {
  case textCompleteness
  case editability
  case structure
  case renderedLayout

  public var displayName: String {
    switch self {
    case .textCompleteness: return "Text completeness"
    case .editability: return "Editability"
    case .structure: return "Structure"
    case .renderedLayout: return "Rendered layout"
    }
  }
}

/// How a dimension was measured. The not-executed status is never a pass.
public enum DOCXMeasurementStatus: String, Sendable, Equatable {
  case measured
  /// Measured with a local proxy because the intended target application is not
  /// launched in this workstream.
  case measuredProxy
  case notExecuted

  public var displayName: String {
    switch self {
    case .measured: return "measured"
    case .measuredProxy: return "measured (local proxy)"
    case .notExecuted: return "not executed"
    }
  }
}

public struct DOCXDimensionScore: Sendable, Equatable {
  public let dimension: DOCXQualificationDimension
  /// 0...1 when measured; nil when not executed.
  public let score: Double?
  public let status: DOCXMeasurementStatus
  public let detail: String
  public let findings: [String]

  public init(
    dimension: DOCXQualificationDimension, score: Double?, status: DOCXMeasurementStatus,
    detail: String, findings: [String] = []
  ) {
    self.dimension = dimension
    self.score = score
    self.status = status
    self.detail = detail
    self.findings = findings
  }

  public var displayScore: String {
    guard let score else { return status.displayName }
    return String(format: "%.2f", score) + " (" + status.displayName + ")"
  }
}

/// What a document class must reconstruct. Tests and operators pass the text
/// fragments and shape expectations that class needs; defaults are conservative.
public struct DOCXQualificationExpectation: Sendable, Equatable {
  public var requiredTextFragments: [String]
  public var minimumColumns: Int?
  public var minimumListItems: Int?
  public var requireHeader: Bool
  public var requireFooter: Bool
  public var minimumTableRows: Int?
  public var minimumTableColumns: Int?
  public var requireFigure: Bool
  /// Text classes must not silently export their content as appearance images.
  public var maximumAppearanceImageBlocks: Int
  public var minimumTextCompleteness: Double

  public init(
    requiredTextFragments: [String] = [], minimumColumns: Int? = nil,
    minimumListItems: Int? = nil, requireHeader: Bool = false, requireFooter: Bool = false,
    minimumTableRows: Int? = nil, minimumTableColumns: Int? = nil,
    requireFigure: Bool = false, maximumAppearanceImageBlocks: Int = 0,
    minimumTextCompleteness: Double = 0.8
  ) {
    self.requiredTextFragments = requiredTextFragments
    self.minimumColumns = minimumColumns
    self.minimumListItems = minimumListItems
    self.requireHeader = requireHeader
    self.requireFooter = requireFooter
    self.minimumTableRows = minimumTableRows
    self.minimumTableColumns = minimumTableColumns
    self.requireFigure = requireFigure
    self.maximumAppearanceImageBlocks = maximumAppearanceImageBlocks
    self.minimumTextCompleteness = minimumTextCompleteness
  }

  /// Class defaults; callers add their fixture's required text fragments.
  public static func `default`(
    for documentClass: DOCXDocumentClass, requiredTextFragments: [String] = []
  ) -> DOCXQualificationExpectation {
    switch documentClass {
    case .baselineProse:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, minimumTextCompleteness: 0.9)
    case .columns:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, minimumColumns: 2,
        minimumTextCompleteness: 0.85)
    case .lists:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, minimumListItems: 2,
        minimumTextCompleteness: 0.85)
    case .headersFooters:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, requireHeader: true,
        requireFooter: true, minimumTextCompleteness: 0.85)
    case .textBoxes:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, maximumAppearanceImageBlocks: 0,
        minimumTextCompleteness: 0.8)
    case .images:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, requireFigure: true,
        maximumAppearanceImageBlocks: 100, minimumTextCompleteness: 0.5)
    case .footnotes:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, maximumAppearanceImageBlocks: 0,
        minimumTextCompleteness: 0.85)
    case .complexTables:
      return DOCXQualificationExpectation(
        requiredTextFragments: requiredTextFragments, minimumTableRows: 2,
        minimumTableColumns: 2, minimumTextCompleteness: 0.8)
    }
  }
}

/// One class's qualification result. Limitations stay attached to the result
/// so a downstream report/conversion cannot present a score without them.
public struct DOCXQualificationResult: Sendable, Equatable {
  public let documentClass: DOCXDocumentClass
  public let dimensionScores: [DOCXDimensionScore]
  public let findings: [String]
  public let reconstructionLimitations: [String]
  public let attachedLimitations: [String]
  public let pageCount: Int
  public let blockCount: Int
  public let tableCount: Int
  public let listItemCount: Int
  public let imageBlockCount: Int
  public let appearanceImageCount: Int
  public let headingCount: Int

  public init(
    documentClass: DOCXDocumentClass, dimensionScores: [DOCXDimensionScore],
    findings: [String], reconstructionLimitations: [String], attachedLimitations: [String],
    pageCount: Int, blockCount: Int, tableCount: Int, listItemCount: Int,
    imageBlockCount: Int, appearanceImageCount: Int, headingCount: Int
  ) {
    self.documentClass = documentClass
    self.dimensionScores = dimensionScores
    self.findings = findings
    self.reconstructionLimitations = reconstructionLimitations
    self.attachedLimitations = attachedLimitations
    self.pageCount = pageCount
    self.blockCount = blockCount
    self.tableCount = tableCount
    self.listItemCount = listItemCount
    self.imageBlockCount = imageBlockCount
    self.appearanceImageCount = appearanceImageCount
    self.headingCount = headingCount
  }

  public func dimension(_ dimension: DOCXQualificationDimension) -> DOCXDimensionScore? {
    dimensionScores.first { $0.dimension == dimension }
  }

  /// Average over dimensions that were actually measured. The Office-rendering
  /// dimension is intentionally excluded when not executed.
  public var overallMeasuredScore: Double? {
    let scores = dimensionScores.compactMap(\.score)
    guard !scores.isEmpty else { return nil }
    return scores.reduce(0, +) / Double(scores.count)
  }

  public var officeApplicationStatus: DOCXMeasurementStatus {
    dimension(.renderedLayout)?.status ?? .notExecuted
  }

  public func markdown() -> String {
    var lines = [
      "## \(documentClass.displayName)",
      "",
      "| Dimension | Score | Status | Detail |",
      "| --- | --- | --- | --- |",
    ]
    for score in dimensionScores {
      lines.append(
        "| \(score.dimension.displayName) | \(score.displayScore) | \(score.status.displayName) | \(score.detail) |")
    }
    lines.append("")
    lines.append("Blocks: \(blockCount) (\(headingCount) headings, \(listItemCount) list items, \(tableCount) tables, \(imageBlockCount) images); pages: \(pageCount).")
    if let overall = overallMeasuredScore {
      lines.append("Overall measured score (excluding not-executed dimensions): \(String(format: "%.2f", overall)).")
    }
    if !findings.isEmpty {
      lines.append("")
      lines.append("Findings:")
      for finding in findings { lines.append("- " + finding) }
    }
    lines.append("")
    lines.append("Limitations attached to this output:")
    for limitation in attachedLimitations { lines.append("- " + limitation) }
    return lines.joined(separator: "\n")
  }

  public func json() -> String {
    var object: [String: Any] = [
      "documentClass": documentClass.rawValue,
      "pageCount": pageCount,
      "blockCount": blockCount,
      "tableCount": tableCount,
      "listItemCount": listItemCount,
      "imageBlockCount": imageBlockCount,
      "appearanceImageCount": appearanceImageCount,
      "headingCount": headingCount,
      "officeApplicationStatus": officeApplicationStatus.rawValue,
      "findings": findings,
      "reconstructionLimitations": reconstructionLimitations,
      "attachedLimitations": attachedLimitations,
      "dimensions": dimensionScores.map { score -> [String: Any] in
        [
          "dimension": score.dimension.rawValue,
          "score": score.score as Any? ?? NSNull(),
          "status": score.status.rawValue,
          "detail": score.detail,
          "findings": score.findings,
        ]
      },
    ]
    if let overall = overallMeasuredScore { object["overallMeasuredScore"] = overall }
    guard let data = try? JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}

/// EXP-01: run the qualification for one document class. The source graph is
/// only read; the reconstruction is in-memory and never written.
public enum DOCXQualification {
  public static let officeApplicationLimitation =
    "Rendered layout in the intended Office applications (Microsoft Word, Pages, LibreOffice) was NOT executed by this workstream because launching applications is outside its permission scope. The rendered-layout score is a local reconstruction/preview proxy; repeat it in Word with the exported .docx before claiming EXP-01 as qualified in Office."

  public static let reconstructionOnlyLimitation =
    "A PDF does not contain the original Office document: scores qualify reconstruction quality, not a perfect round trip."

  public static func qualify(
    documentClass: DOCXDocumentClass, expectation: DOCXQualificationExpectation? = nil,
    in graph: PDFGraph, pageIDs: [PDFObjectID],
    limits: DOCXReconstructionBuilder.Limits = DOCXReconstructionBuilder.Limits()
  ) throws -> DOCXQualificationResult {
    let expectation = expectation ?? DOCXQualificationExpectation.default(for: documentClass)
    let reconstruction = try DOCXReconstructionBuilder.reconstruct(
      pageIDs: pageIDs, in: graph, limits: limits)
    let preview = DOCXPreview.build(reconstruction: reconstruction)

    let sourceText = try sourcePlainText(in: graph, pageIDs: pageIDs)
    let reconstructedText = reconstructionText(reconstruction)
    let completeness = textCompleteness(source: sourceText, reconstructed: reconstructedText)

    let blockKinds = blockStatistics(reconstruction)
    let editableCharacters = editableTextCharacters(reconstruction)
    let totalCharacters = max(1, reconstructedText.count)
    let editability = min(1, Double(editableCharacters) / Double(totalCharacters))

    // Structure: class-specific, evidence-based checks on the block model.
    var structureFindings: [String] = []
    var structureChecks: [(String, Bool)] = []
    let normalizedReconstructed = normalize(reconstructedText)
    func requireStructure(_ name: String, _ condition: Bool) {
      structureChecks.append((name, condition))
      if !condition { structureFindings.append("missing structure: " + name) }
    }
    requireStructure("readable block output", blockKinds.totalBlocks > 0)
    for fragment in expectation.requiredTextFragments {
      requireStructure(
        "text fragment \(fragment)",
        normalizedReconstructed.contains(normalize(fragment)))
    }
    if let minimumColumns = expectation.minimumColumns {
      let detected = reconstruction.columns >= minimumColumns
        || reconstruction.blocks.contains { block in
          if case .sectionBreak(let columns) = block.kind {
            return columns >= minimumColumns
          }
          return false
        }
      requireStructure("at least \(minimumColumns) columns", detected)
    }
    if let minimumListItems = expectation.minimumListItems {
      requireStructure(
        "at least \(minimumListItems) list items", blockKinds.listItems >= minimumListItems)
    }
    if expectation.requireHeader {
      requireStructure(
        "reconstructed header band", !(reconstruction.headerFooter.header ?? []).isEmpty)
    }
    if expectation.requireFooter {
      requireStructure(
        "reconstructed footer band", !(reconstruction.headerFooter.footer ?? []).isEmpty)
    }
    if let rows = expectation.minimumTableRows, let columns = expectation.minimumTableColumns {
      let largest = blockKinds.tables.map { $0.0 }.max() ?? 0
      let widest = blockKinds.tables.map { $0.1 }.max() ?? 0
      requireStructure(
        "table of at least \(rows)x\(columns)",
        blockKinds.tables.contains { $0.0 >= rows && $0.1 >= columns })
      structureFindings.append("largest reconstructed table: \(largest)x\(widest)")
    }
    if expectation.requireFigure {
      requireStructure("an image block", blockKinds.images >= 1)
    }
    requireStructure(
      "no unexpected appearance images",
      blockKinds.appearanceImages <= expectation.maximumAppearanceImageBlocks)
    let structureScore = structureChecks.isEmpty
      ? 0 : Double(structureChecks.filter(\.1).count) / Double(structureChecks.count)

    // Rendered layout: local proxy (page mapping + reconstruction geometry).
    var layoutFindings: [String] = []
    var layoutChecks: [(String, Bool)] = []
    func requireLayout(_ name: String, _ condition: Bool) {
      layoutChecks.append((name, condition))
      if !condition { layoutFindings.append("layout proxy missing: " + name) }
    }
    let sourcePages = try sourcePageGeometry(in: graph, pageIDs: pageIDs)
    if let first = sourcePages.first {
      let widthMatches = abs(reconstruction.pageWidth - first.width) <= 2
      let heightMatches = abs(reconstruction.pageHeight - first.height) <= 2
      requireLayout("page width/height from source geometry", widthMatches && heightMatches)
      if !(widthMatches && heightMatches) {
        layoutFindings.append(
          "reconstruction page \(Int(reconstruction.pageWidth))x\(Int(reconstruction.pageHeight)) vs source \(Int(first.width))x\(Int(first.height)).")
      }
    }
    let previewPages = preview.entries.map(\.pageNumber).max() ?? 1
    requireLayout(
      "preview page mapping matches source pages", previewPages == max(1, pageIDs.count))
    requireLayout(
      "deliberate page breaks for multi-page documents",
      pageIDs.count <= 1
        || blockKinds.pageBreaks == max(0, pageIDs.count - 1)
        || previewPages == pageIDs.count)
    let trimmedSourceText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    requireLayout(
      "reconstruction contains source text",
      trimmedSourceText.isEmpty || !reconstructedText.isEmpty)
    if documentClass == .images {
      let sourceImages = pageIDs.reduce(0) { count, pageID in
        count + ((try? ImageInventory.placements(in: graph, pageID: pageID).count) ?? 0)
      }
      requireLayout("image block per source placement", blockKinds.images >= min(1, sourceImages))
    }
    let layoutScore = layoutChecks.isEmpty
      ? 0 : Double(layoutChecks.filter(\.1).count) / Double(layoutChecks.count)

    var findings: [String] = []
    if completeness < expectation.minimumTextCompleteness {
      findings.append(
        "text completeness \(String(format: "%.2f", completeness)) is below the class minimum \(String(format: "%.2f", expectation.minimumTextCompleteness)).")
    }
    if editability < 0.8 {
      findings.append(
        "only \(String(format: "%.0f%%", editability * 100)) of reconstructed characters are in editable text runs.")
    }
    findings.append(contentsOf: structureFindings)
    findings.append(contentsOf: layoutFindings)

    var attached = [
      officeApplicationLimitation,
      reconstructionOnlyLimitation,
    ]
    attached.append(
      "The \(documentClass.displayName.lowercased()) class is scored on this fixture only; it is not a corpus-wide fidelity claim.")
    if documentClass == .footnotes {
      attached.append(
        "Footnote references are reconstructed as ordinary paragraphs; Word footnote/endnote anchors are not authored.")
    }
    if documentClass == .textBoxes {
      attached.append(
        "PDF text boxes become ordinary editable paragraphs; floating text-box shapes are not authored.")
    }
    if documentClass == .complexTables {
      attached.append(
        "Merged cells are limited to the spans the owned table reconstruction detected; header scopes and nested tables are not authored.")
    }
    attached.append(contentsOf: reconstruction.limitations.map { "reconstruction: " + $0 })

    let dimensions: [DOCXDimensionScore] = [
      DOCXDimensionScore(
        dimension: .textCompleteness, score: completeness, status: .measured,
        detail:
          "Normalized source characters present in the reconstruction (order-independent; reading order is a structure check).",
        findings: completeness < expectation.minimumTextCompleteness
          ? ["below class minimum"] : []),
      DOCXDimensionScore(
        dimension: .editability, score: editability, status: .measured,
        detail:
          "\(editableCharacters)/\(totalCharacters) reconstructed characters are editable text runs; "
          + "\(blockKinds.images) image block(s), \(blockKinds.appearanceImages) appearance image(s).",
        findings: editability < 0.8 ? ["image/appearance-heavy output"] : []),
      DOCXDimensionScore(
        dimension: .structure, score: structureScore, status: .measured,
        detail: "\(structureChecks.filter(\.1).count)/\(structureChecks.count) class structure checks passed.",
        findings: structureFindings),
      DOCXDimensionScore(
        dimension: .renderedLayout, score: layoutScore, status: .measuredProxy,
        detail:
          "\(layoutChecks.filter(\.1).count)/\(layoutChecks.count) local layout-proxy checks passed; "
          + "intended Office application rendering not executed.",
        findings: layoutFindings),
    ]
    return DOCXQualificationResult(
      documentClass: documentClass, dimensionScores: dimensions, findings: findings,
      reconstructionLimitations: reconstruction.limitations,
      attachedLimitations: attached, pageCount: pageIDs.count,
      blockCount: blockKinds.totalBlocks, tableCount: blockKinds.tables.count,
      listItemCount: blockKinds.listItems, imageBlockCount: blockKinds.images,
      appearanceImageCount: blockKinds.appearanceImages, headingCount: blockKinds.headings)
  }

  /// Markdown qualification report for one or more classes.
  public static func markdownReport(_ results: [DOCXQualificationResult]) -> String {
    var lines = [
      "# DOCX reconstruction qualification (EXP-01)",
      "",
      "Scores are separated by dimension; rendered layout is a local proxy and intentionally not a claim about any Office application.",
      "",
    ]
    for result in results {
      lines.append(result.markdown())
      lines.append("")
    }
    lines.append("## Attached limitations (all outputs)")
    lines.append("- " + officeApplicationLimitation)
    lines.append("- " + reconstructionOnlyLimitation)
    lines.append(
      "- Scores qualify the fixtures used in this workstream; they are not a corpus-wide Office-fidelity claim.")
    return lines.joined(separator: "\n")
  }

  // MARK: - Text and block helpers

  private static func sourcePlainText(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> String
  {
    let data = try PDFTextExport.plainText(
      pageIDs: pageIDs, in: graph,
      options: PDFTextExportOptions(pageSeparator: .blankLine))
    return String(decoding: data, as: UTF8.self)
  }

  private static func reconstructionText(_ reconstruction: DOCXReconstruction) -> String {
    var parts: [String] = []
    parts.append(contentsOf: (reconstruction.headerFooter.header ?? []).map { $0.text })
    for block in reconstruction.blocks {
      switch block.kind {
      case .paragraph, .heading, .listItem:
        parts.append(block.text)
      case .table(let rows):
        for row in rows {
          parts.append(row.map { $0.map(\.text).joined() }.joined(separator: "\t"))
        }
      case .image, .pageBreak, .sectionBreak:
        continue
      }
    }
    parts.append(contentsOf: (reconstruction.headerFooter.footer ?? []).map { $0.text })
    return parts.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func editableTextCharacters(_ reconstruction: DOCXReconstruction) -> Int {
    var count = 0
    for run in reconstruction.headerFooter.header ?? [] { count += run.text.count }
    for run in reconstruction.headerFooter.footer ?? [] { count += run.text.count }
    for block in reconstruction.blocks {
      switch block.kind {
      case .paragraph, .heading, .listItem:
        count += block.text.count
      case .table(let rows):
        for row in rows {
          for cell in row {
            for run in cell { count += run.text.count }
          }
        }
      case .image, .pageBreak, .sectionBreak:
        continue
      }
    }
    return count
  }

  private struct BlockStatistics {
    var headings = 0
    var paragraphs = 0
    var listItems = 0
    var pageBreaks = 0
    var sectionBreaks = 0
    var images = 0
    var appearanceImages = 0
    var tables: [(Int, Int)] = []
    var totalBlocks: Int {
      headings + paragraphs + listItems + pageBreaks + sectionBreaks + images + tables.count
    }
  }

  private static func blockStatistics(_ reconstruction: DOCXReconstruction) -> BlockStatistics {
    var stats = BlockStatistics()
    for block in reconstruction.blocks {
      switch block.kind {
      case .paragraph: stats.paragraphs += 1
      case .heading: stats.headings += 1
      case .listItem: stats.listItems += 1
      case .pageBreak: stats.pageBreaks += 1
      case .sectionBreak: stats.sectionBreaks += 1
      case .image(let request):
        stats.images += 1
        if request.isAppearance { stats.appearanceImages += 1 }
      case .table(let rows):
        stats.tables.append((rows.count, rows.map(\.count).max() ?? 0))
      }
    }
    return stats
  }

  /// Text completeness is intentionally order-independent: every normalized
  /// source character (whitespace removed) must have a counterpart in the
  /// reconstruction, counting duplicates. Table cell and column order is
  /// qualified by the structure dimension instead, so a legitimate reordering
  /// does not read as lost text. Character-count coverage is bounded and easy
  /// to reason about; it is not a semantic equivalence claim.
  private static func textCompleteness(source: String, reconstructed: String) -> Double {
    let sourceChars = normalize(source).filter { !$0.isWhitespace }
    let reconstructedChars = normalize(reconstructed).filter { !$0.isWhitespace }
    guard !sourceChars.isEmpty else { return 1 }
    var reconstructedCounts: [Character: Int] = [:]
    for character in reconstructedChars {
      reconstructedCounts[character, default: 0] += 1
    }
    var matched = 0
    for character in sourceChars {
      guard let available = reconstructedCounts[character], available > 0 else { continue }
      reconstructedCounts[character] = available - 1
      matched += 1
    }
    return Double(matched) / Double(sourceChars.count)
  }

  private static func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private struct PageGeometry {
    let width: Double
    let height: Double
  }

  private static func sourcePageGeometry(in graph: PDFGraph, pageIDs: [PDFObjectID]) throws
    -> [PageGeometry]
  {
    try pageIDs.map { pageID in
      guard case .dictionary(let page)? = graph.objects[pageID],
        case .array(let box)? = page[PDFName("MediaBox")], box.count == 4
      else {
        return PageGeometry(width: 612, height: 792)
      }
      let values = box.compactMap { value -> Double? in
        switch value {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        default: return nil
        }
      }
      guard values.count == 4 else { return PageGeometry(width: 612, height: 792) }
      return PageGeometry(width: values[2] - values[0], height: values[3] - values[1])
    }
  }
}
