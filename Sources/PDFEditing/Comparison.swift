import CryptoKit
import Foundation
import PDFCore

/// P32-020/P32-030: one reported difference between two document snapshots.
public struct PDFComparisonChange: Sendable, Equatable {
  public enum Kind: String, Sendable, CaseIterable, Equatable {
    case pageInserted
    case pageDeleted
    case pageReordered
    case pageBoxOrRotation
    case textAdded
    case textRemoved
    case textChanged
    case imageAdded
    case imageRemoved
    case imageMoved
    case imageResized
    case annotationAdded
    case annotationRemoved
    case annotationChanged
    case formValueChanged
    case metadataChanged
    case attachmentChanged
    case signatureStatus
    case encryptionStatus
    case uncertainty
  }

  public let kind: Kind
  public let leftPageIndex: Int?
  public let rightPageIndex: Int?
  public let summary: String
  public let leftBounds: [Double]?
  public let rightBounds: [Double]?
  /// P32-018: true when the evidence came from a generated OCR layer.
  public let isOCRSourced: Bool
}

/// P32-011/P32-018/P32-007: explicit comparison options.
public struct PDFComparisonOptions: Sendable, Equatable {
  public let ignoreWhitespace: Bool
  public let includeText: Bool
  public let includeImages: Bool
  public let includeAnnotations: Bool
  public let includeForms: Bool
  public let includeMetadata: Bool
  public let includeOCRText: Bool
  /// P32-007: per-channel tolerance for rendered comparisons (used by the
  /// rendering layer, recorded here so reports state the setting).
  public let visualTolerance: Int

  public init(
    ignoreWhitespace: Bool = true, includeText: Bool = true, includeImages: Bool = true,
    includeAnnotations: Bool = true, includeForms: Bool = true, includeMetadata: Bool = true,
    includeOCRText: Bool = true, visualTolerance: Int = 2
  ) {
    self.ignoreWhitespace = ignoreWhitespace
    self.includeText = includeText
    self.includeImages = includeImages
    self.includeAnnotations = includeAnnotations
    self.includeForms = includeForms
    self.includeMetadata = includeMetadata
    self.includeOCRText = includeOCRText
    self.visualTolerance = visualTolerance
  }
}

/// P32-001–P32-024: comparison of two immutable snapshots. Comparison never
/// merges documents (P32-023); it reports differences, page mapping, and
/// uncertainty, and it is cancellable at page-pair boundaries.
public struct PDFComparisonResult: Sendable, Equatable {
  public struct PagePair: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
      case matched
      case inserted
      case deleted
      case reordered
      case uncertain
    }
    public let leftIndex: Int?
    public let rightIndex: Int?
    public let status: Status

    public init(leftIndex: Int?, rightIndex: Int?, status: Status) {
      self.leftIndex = leftIndex
      self.rightIndex = rightIndex
      self.status = status
    }
  }

  public struct DocumentSummary: Sendable, Equatable {
    public let pageCount: Int
    public let isEncrypted: Bool
    public let signatureCount: Int
    public let signatureStatuses: [String]
    public let hasOCRLayers: Bool
  }

  public let pageMapping: [PagePair]
  public let changes: [PDFComparisonChange]
  public let left: DocumentSummary
  public let right: DocumentSummary
  /// P32-024: the next page-pair index to process, or nil when complete.
  public let nextPagePairIndex: Int?

  /// P32-020: filter by page and kind.
  public func changes(pageIndex: Int? = nil, kinds: Set<PDFComparisonChange.Kind>? = nil)
    -> [PDFComparisonChange]
  {
    changes.filter { change in
      if let pageIndex {
        let matchesPage = change.leftPageIndex == pageIndex || change.rightPageIndex == pageIndex
        if !matchesPage { return false }
      }
      if let kinds, !kinds.contains(change.kind) { return false }
      return true
    }
  }
}

public enum PDFComparison {
  /// P32-001: compare two immutable snapshots.
  public static func compare(
    left: (graph: PDFGraph, source: Data), right: (graph: PDFGraph, source: Data),
    options: PDFComparisonOptions = PDFComparisonOptions(),
    resumingAt startPagePair: Int = 0,
    /// P32-005: a manually corrected mapping replaces the automatic one.
    mappingOverride: [PDFComparisonResult.PagePair]? = nil,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFComparisonResult {
    let leftPages = try PDFPageTree.pageIDs(in: left.graph)
    let rightPages = try PDFPageTree.pageIDs(in: right.graph)
    let leftSummaries = try pageSummaries(graph: left.graph, pageIDs: leftPages, limits: limits)
    let rightSummaries = try pageSummaries(graph: right.graph, pageIDs: rightPages, limits: limits)
    let mapping = mappingOverride ?? align(left: leftSummaries, right: rightSummaries)

    var changes: [PDFComparisonChange] = []
    for pair in mapping where pair.status == .inserted {
      changes.append(
        PDFComparisonChange(
          kind: .pageInserted, leftPageIndex: nil, rightPageIndex: pair.rightIndex,
          summary: "page inserted", leftBounds: nil, rightBounds: nil, isOCRSourced: false))
    }
    for pair in mapping where pair.status == .deleted {
      changes.append(
        PDFComparisonChange(
          kind: .pageDeleted, leftPageIndex: pair.leftIndex, rightPageIndex: nil,
          summary: "page deleted", leftBounds: nil, rightBounds: nil, isOCRSourced: false))
    }
    for pair in mapping where pair.status == .reordered {
      changes.append(
        PDFComparisonChange(
          kind: .pageReordered, leftPageIndex: pair.leftIndex, rightPageIndex: pair.rightIndex,
          summary: "page moved", leftBounds: nil, rightBounds: nil, isOCRSourced: false))
    }

    // P32-024: page-pair work is cancellable and resumable.
    var nextPair: Int? = nil
    for (pairIndex, pair) in mapping.enumerated() {
      guard pair.status == .matched || pair.status == .reordered || pair.status == .uncertain,
        let leftIndex = pair.leftIndex, let rightIndex = pair.rightIndex
      else { continue }
      if pairIndex < startPagePair { continue }
      try Task.checkCancellation()
      defer { nextPair = pairIndex + 1 < mapping.count ? pairIndex + 1 : nil }
      try comparePage(
        leftIndex: leftIndex, rightIndex: rightIndex,
        leftPageID: leftPages[leftIndex], rightPageID: rightPages[rightIndex],
        left: (left.graph, left.source), right: (right.graph, right.source),
        options: options, limits: limits, into: &changes)
      if pairIndex + 1 >= mapping.count { nextPair = nil }
    }

    // P32-014: form values are document-global, so they are compared once.
    if options.includeForms {
      try Task.checkCancellation()
      changes.append(
        contentsOf: formChanges(
          leftGraph: left.graph, leftPageIDs: leftPages,
          rightGraph: right.graph, rightPageIDs: rightPages))
    }

    // P32-016: document-level metadata and attachments.
    if options.includeMetadata {
      try Task.checkCancellation()
      changes.append(
        contentsOf: metadataChanges(left: left.graph, right: right.graph, limits: limits))
    }
    // P32-017: signature and encryption status stay visible.
    changes.append(
      contentsOf: statusChanges(
        left: left.graph, leftSource: left.source, right: right.graph, rightSource: right.source,
        limits: limits))

    return PDFComparisonResult(
      pageMapping: mapping, changes: changes,
      left: try documentSummary(graph: left.graph, pageIDs: leftPages, source: left.source),
      right: try documentSummary(graph: right.graph, pageIDs: rightPages, source: right.source),
      nextPagePairIndex: nextPair)
  }

  // MARK: Page alignment (P32-003/P32-004/P32-026)

  struct PageSummary {
    let index: Int
    let signature: String
    let text: String
    let lineTexts: [String]
    let lineBounds: [[Double]]
    let mediaBox: [Double]
    let rotation: Int
    let imageCount: Int
    let hasOCRLayer: Bool
  }

  static func pageSummaries(graph: PDFGraph, pageIDs: [PDFObjectID], limits: PDFLimits) throws
    -> [PageSummary]
  {
    var summaries: [PageSummary] = []
    for (index, pageID) in pageIDs.enumerated() {
      let layout = try PageTextLayout.build(pageID: pageID, in: graph, limits: limits)
      let lineTexts = layout.lines.map { layout.text(in: $0) }
      let lineBounds = layout.lines.map { line -> [Double] in
        unionBounds(line.compactMap { layout.clusters[$0].bounds })
      }
      var mediaBox: [Double] = [0, 0, 612, 792]
      var rotation = 0
      if case .dictionary(let page)? = graph.objects[pageID] {
        if case .array(let values)? = page[PDFName("MediaBox")] {
          let numbers = values.compactMap { value -> Double? in
            if case .integer(let raw) = value { return Double(raw) }
            if case .real(let raw) = value { return raw }
            return nil
          }
          if numbers.count == 4 { mediaBox = numbers }
        }
        if case .integer(let raw)? = page[PDFName("Rotate")] { rotation = Int(raw) }
      }
      let images = (try? ImageInventory.placements(in: graph, pageID: pageID)) ?? []
      let normalizedText = normalize(lineTexts.joined(separator: "\n"), collapse: true)
      // P32-015: rotation and box changes must still match pages, so the
      // alignment signature uses text, or rotation-independent dimensions for
      // textless pages.
      let width = Int(abs(mediaBox[2] - mediaBox[0]))
      let height = Int(abs(mediaBox[3] - mediaBox[1]))
      let signatureSource: String
      if normalizedText.isEmpty {
        signatureSource = "image:\(images.count)|dims:\(min(width, height))x\(max(width, height))"
      } else {
        signatureSource = normalizedText
      }
      let signature = SHA256.hash(data: Data(signatureSource.utf8))
        .map { String(format: "%02x", $0) }.joined()
      summaries.append(
        PageSummary(
          index: index, signature: signature, text: normalizedText, lineTexts: lineTexts,
          lineBounds: lineBounds, mediaBox: mediaBox, rotation: rotation,
          imageCount: images.count,
          hasOCRLayer: OCRLayer.hasGeneratedLayer(in: graph, pageID: pageID)))
    }
    return summaries
  }

  static func align(left: [PageSummary], right: [PageSummary])
    -> [PDFComparisonResult.PagePair]
  {
    // Longest common subsequence over signatures: in-order pages match first.
    let leftSignatures = left.map(\.signature)
    let rightSignatures = right.map(\.signature)
    var lcs = Array(
      repeating: Array(repeating: 0, count: rightSignatures.count + 1),
      count: leftSignatures.count + 1)
    for i in stride(from: leftSignatures.count - 1, through: 0, by: -1) {
      for j in stride(from: rightSignatures.count - 1, through: 0, by: -1) {
        lcs[i][j] =
          leftSignatures[i] == rightSignatures[j]
          ? lcs[i + 1][j + 1] + 1
          : max(lcs[i + 1][j], lcs[i][j + 1])
      }
    }
    var pairs: [PDFComparisonResult.PagePair] = []
    var i = 0
    var j = 0
    while i < left.count, j < right.count {
      if leftSignatures[i] == rightSignatures[j] {
        pairs.append(
          PDFComparisonResult.PagePair(leftIndex: i, rightIndex: j, status: .matched))
        i += 1
        j += 1
      } else if lcs[i + 1][j] >= lcs[i][j + 1] {
        pairs.append(PDFComparisonResult.PagePair(leftIndex: i, rightIndex: nil, status: .deleted))
        i += 1
      } else {
        pairs.append(PDFComparisonResult.PagePair(leftIndex: nil, rightIndex: j, status: .inserted))
        j += 1
      }
    }
    while i < left.count {
      pairs.append(PDFComparisonResult.PagePair(leftIndex: i, rightIndex: nil, status: .deleted))
      i += 1
    }
    while j < right.count {
      pairs.append(PDFComparisonResult.PagePair(leftIndex: nil, rightIndex: j, status: .inserted))
      j += 1
    }

    // P32-004/P32-026: a deleted page whose signature reappears as an inserted
    // page is a move, not an all-page change.
    var result: [PDFComparisonResult.PagePair] = []
    var consumedInsertions: Set<Int> = []
    for pair in pairs {
      if pair.status == .deleted, let leftIndex = pair.leftIndex {
        let signature = left[leftIndex].signature
        if let inserted = pairs.first(where: { candidate in
          candidate.status == .inserted
            && candidate.rightIndex.map { rightSignatures[$0] == signature } == true
            && consumedInsertions.contains(candidate.rightIndex ?? -1) == false
        }), let rightIndex = inserted.rightIndex {
          consumedInsertions.insert(rightIndex)
          result.append(
            PDFComparisonResult.PagePair(
              leftIndex: leftIndex, rightIndex: rightIndex, status: .reordered))
          continue
        }
      }
      if pair.status == .inserted, let rightIndex = pair.rightIndex,
        consumedInsertions.contains(rightIndex)
      {
        continue
      }
      result.append(pair)
    }

    // Pages whose content changed still correspond: pair leftover deletions
    // and insertions in order when the pages are similar, so per-page
    // comparison reports the actual text/image differences instead of an
    // unrelated delete + insert.
    var paired: [PDFComparisonResult.PagePair] = []
    var usedInsertions: Set<Int> = []
    for pair in result {
      if pair.status == .deleted, let leftIndex = pair.leftIndex {
        if let candidate = result.first(where: { other in
          other.status == .inserted
            && other.rightIndex.map { usedInsertions.contains($0) == false } == true
            && other.rightIndex.map { pagesSimilar(left[leftIndex], right[$0]) } == true
        }), let rightIndex = candidate.rightIndex {
          usedInsertions.insert(rightIndex)
          paired.append(
            PDFComparisonResult.PagePair(
              leftIndex: leftIndex, rightIndex: rightIndex, status: .matched))
          continue
        }
      }
      if pair.status == .inserted, let rightIndex = pair.rightIndex,
        usedInsertions.contains(rightIndex)
      {
        continue
      }
      paired.append(pair)
    }
    return paired
  }

  /// Whether two pages correspond despite changed content: shared words in
  /// their text, or equal dimensions for textless pages.
  static func pagesSimilar(_ left: PageSummary, _ right: PageSummary) -> Bool {
    if left.text.isEmpty, right.text.isEmpty {
      let leftDims = [Int(abs(left.mediaBox[2] - left.mediaBox[0])), Int(abs(left.mediaBox[3] - left.mediaBox[1]))].sorted()
      let rightDims = [Int(abs(right.mediaBox[2] - right.mediaBox[0])), Int(abs(right.mediaBox[3] - right.mediaBox[1]))].sorted()
      return leftDims == rightDims
    }
    let leftWords = Set(left.text.split(separator: " "))
    let rightWords = Set(right.text.split(separator: " "))
    guard !leftWords.isEmpty, !rightWords.isEmpty else { return false }
    let shared = leftWords.intersection(rightWords).count
    return Double(shared) / Double(min(leftWords.count, rightWords.count)) >= 0.4
  }

  // MARK: Per-page comparison

  static func comparePage(
    leftIndex: Int, rightIndex: Int, leftPageID: PDFObjectID, rightPageID: PDFObjectID,
    left: (graph: PDFGraph, source: Data), right: (graph: PDFGraph, source: Data),
    options: PDFComparisonOptions, limits: PDFLimits, into changes: inout [PDFComparisonChange]
  ) throws {
    // P32-015: page box and rotation differences.
    if case .dictionary(let leftPage)? = left.graph.objects[leftPageID],
      case .dictionary(let rightPage)? = right.graph.objects[rightPageID]
    {
      let leftBox = numberArray(leftPage[PDFName("MediaBox")])
      let rightBox = numberArray(rightPage[PDFName("MediaBox")])
      let leftRotation = integerValue(leftPage[PDFName("Rotate")]) ?? 0
      let rightRotation = integerValue(rightPage[PDFName("Rotate")]) ?? 0
      if leftBox != rightBox || leftRotation != rightRotation {
        changes.append(
          PDFComparisonChange(
            kind: .pageBoxOrRotation, leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            summary: "page box or rotation changed (\(leftBox ?? [])/\(leftRotation) → "
              + "\(rightBox ?? [])/\(rightRotation))",
            leftBounds: nil, rightBounds: nil, isOCRSourced: false))
      }
    }

    // P32-009/P32-010/P32-011: text in reading order with geometry.
    if options.includeText {
      let leftLayout = try PageTextLayout.build(pageID: leftPageID, in: left.graph, limits: limits)
      let rightLayout = try PageTextLayout.build(
        pageID: rightPageID, in: right.graph, limits: limits)
      let leftLines = lineTexts(leftLayout, options: options)
      let rightLines = lineTexts(rightLayout, options: options)
      changes.append(
        contentsOf: textChanges(
          left: leftLines, right: rightLines, leftPageIndex: leftIndex,
          rightPageIndex: rightIndex, options: options))
      // P32-019: multi-column pages are reported as uncertain for matching.
      if isMultiColumn(leftLayout) || isMultiColumn(rightLayout) {
        changes.append(
          PDFComparisonChange(
            kind: .uncertainty, leftPageIndex: leftIndex, rightPageIndex: rightIndex,
            summary: "multi-column layout detected; line matching may be unreliable",
            leftBounds: nil, rightBounds: nil, isOCRSourced: false))
      }
    }

    // P32-018: generated OCR layers are labeled as an explicit text source.
    let leftHasLayer = OCRLayer.hasGeneratedLayer(in: left.graph, pageID: leftPageID)
    let rightHasLayer = OCRLayer.hasGeneratedLayer(in: right.graph, pageID: rightPageID)
    if options.includeOCRText, leftHasLayer != rightHasLayer {
      changes.append(
        PDFComparisonChange(
          kind: .uncertainty, leftPageIndex: leftIndex, rightPageIndex: rightIndex,
          summary: "generated OCR text layer "
            + (rightHasLayer ? "added" : "removed") + " (text source: OCR)",
          leftBounds: nil, rightBounds: nil, isOCRSourced: true))
    }

    // P32-012: image placement differences.
    if options.includeImages {
      let leftImages = try ImageInventory.placements(in: left.graph, pageID: leftPageID)
      let rightImages = try ImageInventory.placements(in: right.graph, pageID: rightPageID)
      changes.append(
        contentsOf: imageChanges(
          left: leftImages, right: rightImages, leftPageIndex: leftIndex,
          rightPageIndex: rightIndex))
    }

    // P32-013: annotation differences.
    if options.includeAnnotations {
      let leftAnnotations = try AnnotationInventory.annotations(
        in: left.graph, pageID: leftPageID)
      let rightAnnotations = try AnnotationInventory.annotations(
        in: right.graph, pageID: rightPageID)
      changes.append(
        contentsOf: annotationChanges(
          left: leftAnnotations, right: rightAnnotations, leftPageIndex: leftIndex,
          rightPageIndex: rightIndex))
    }

  }

  struct LineText {
    let text: String
    let bounds: [Double]
  }

  static func lineTexts(_ layout: PageTextLayout, options: PDFComparisonOptions) -> [LineText] {
    layout.lines.map { range in
      let text = layout.text(in: range)
      let bounds = unionBounds(range.compactMap { layout.clusters[$0].bounds })
      return LineText(
        text: options.ignoreWhitespace ? normalize(text, collapse: true) : text, bounds: bounds)
    }
  }

  static func textChanges(
    left: [LineText], right: [LineText], leftPageIndex: Int, rightPageIndex: Int,
    options: PDFComparisonOptions
  ) -> [PDFComparisonChange] {
    var changes: [PDFComparisonChange] = []
    let leftTexts = left.map(\.text)
    let rightTexts = right.map(\.text)
    // LCS over line texts.
    var lcs = Array(
      repeating: Array(repeating: 0, count: rightTexts.count + 1),
      count: leftTexts.count + 1)
    for i in stride(from: leftTexts.count - 1, through: 0, by: -1) {
      for j in stride(from: rightTexts.count - 1, through: 0, by: -1) {
        lcs[i][j] =
          leftTexts[i] == rightTexts[j]
          ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
      }
    }
    var removed: [Int] = []
    var added: [Int] = []
    var i = 0
    var j = 0
    while i < left.count, j < right.count {
      if leftTexts[i] == rightTexts[j] {
        i += 1
        j += 1
      } else if lcs[i + 1][j] >= lcs[i][j + 1] {
        removed.append(i)
        i += 1
      } else {
        added.append(j)
        j += 1
      }
    }
    while i < left.count {
      removed.append(i)
      i += 1
    }
    while j < right.count {
      added.append(j)
      j += 1
    }
    // Pair similar lines as changes instead of unrelated add/remove.
    var usedAdded: Set<Int> = []
    for leftIndexInList in removed {
      let leftLine = left[leftIndexInList]
      if let match = added.first(where: { candidate in
        !usedAdded.contains(candidate) && similar(leftLine.text, right[candidate].text)
      }) {
        usedAdded.insert(match)
        changes.append(
          PDFComparisonChange(
            kind: .textChanged, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
            summary: "text changed: \"\(snippet(leftLine.text))\" → "
              + "\"\(snippet(right[match].text))\"",
            leftBounds: leftLine.bounds, rightBounds: right[match].bounds, isOCRSourced: false))
      } else {
        changes.append(
          PDFComparisonChange(
            kind: .textRemoved, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
            summary: "text removed: \"\(snippet(leftLine.text))\"",
            leftBounds: leftLine.bounds, rightBounds: nil, isOCRSourced: false))
      }
    }
    for candidate in added where !usedAdded.contains(candidate) {
      changes.append(
        PDFComparisonChange(
          kind: .textAdded, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
          summary: "text added: \"\(snippet(right[candidate].text))\"",
          leftBounds: nil, rightBounds: right[candidate].bounds, isOCRSourced: false))
    }
    return changes
  }

  static func imageChanges(
    left: [ImagePlacement], right: [ImagePlacement], leftPageIndex: Int, rightPageIndex: Int
  ) -> [PDFComparisonChange] {
    var changes: [PDFComparisonChange] = []
    if left.count != right.count {
      if right.count > left.count {
        changes.append(
          PDFComparisonChange(
            kind: .imageAdded, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
            summary: "\(right.count - left.count) image placement(s) added",
            leftBounds: nil, rightBounds: nil, isOCRSourced: false))
      } else {
        changes.append(
          PDFComparisonChange(
            kind: .imageRemoved, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
            summary: "\(left.count - right.count) image placement(s) removed",
            leftBounds: nil, rightBounds: nil, isOCRSourced: false))
      }
    }
    for index in 0..<min(left.count, right.count) {
      let leftBounds = left[index].bounds
      let rightBounds = right[index].bounds
      guard leftBounds.count == 4, rightBounds.count == 4 else { continue }
      let leftSize = [leftBounds[2] - leftBounds[0], leftBounds[3] - leftBounds[1]]
      let rightSize = [rightBounds[2] - rightBounds[0], rightBounds[3] - rightBounds[1]]
      if abs(leftSize[0] - rightSize[0]) > 1 || abs(leftSize[1] - rightSize[1]) > 1 {
        changes.append(
          PDFComparisonChange(
            kind: .imageResized, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
            summary: "image resized",
            leftBounds: leftBounds, rightBounds: rightBounds, isOCRSourced: false))
      } else if abs(leftBounds[0] - rightBounds[0]) > 1 || abs(leftBounds[1] - rightBounds[1]) > 1 {
        changes.append(
          PDFComparisonChange(
            kind: .imageMoved, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
            summary: "image moved",
            leftBounds: leftBounds, rightBounds: rightBounds, isOCRSourced: false))
      }
    }
    return changes
  }

  static func annotationChanges(
    left: [Annotation], right: [Annotation], leftPageIndex: Int, rightPageIndex: Int
  ) -> [PDFComparisonChange] {
    var changes: [PDFComparisonChange] = []
    func key(_ annotation: Annotation) -> String {
      let subtype = annotation.subtype.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "?"
      let rect = (annotation.rect ?? []).map { Int($0) }.map(String.init).joined(separator: ",")
      let contents = annotation.dictionary[PDFName("Contents")].flatMap { value -> String? in
        guard case .string(let data) = value else { return nil }
        return String(decoding: data, as: UTF8.self)
      } ?? ""
      return "\(subtype)|\(rect)|\(contents)"
    }
    let leftKeys = left.map(key)
    let rightKeys = right.map(key)
    for (index, leftKey) in leftKeys.enumerated() where !rightKeys.contains(leftKey) {
      changes.append(
        PDFComparisonChange(
          kind: .annotationRemoved, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
          summary: "annotation removed (\(left[index].subtype.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "?"))",
          leftBounds: left[index].rect, rightBounds: nil, isOCRSourced: false))
    }
    for (index, rightKey) in rightKeys.enumerated() where !leftKeys.contains(rightKey) {
      changes.append(
        PDFComparisonChange(
          kind: .annotationAdded, leftPageIndex: leftPageIndex, rightPageIndex: rightPageIndex,
          summary: "annotation added (\(right[index].subtype.map { String(decoding: $0.bytes, as: UTF8.self) } ?? "?"))",
          leftBounds: nil, rightBounds: right[index].rect, isOCRSourced: false))
    }
    // Same subtype and count but different geometry/contents.
    if left.count == right.count, leftKeys != rightKeys {
      for index in 0..<left.count {
        if left[index].subtype != right[index].subtype { continue }
        if leftKeys[index] != rightKeys[index] {
          changes.append(
            PDFComparisonChange(
              kind: .annotationChanged, leftPageIndex: leftPageIndex,
              rightPageIndex: rightPageIndex, summary: "annotation changed",
              leftBounds: left[index].rect, rightBounds: right[index].rect, isOCRSourced: false))
        }
      }
    }
    return changes
  }

  static func formChanges(
    leftGraph: PDFGraph, leftPageIDs: [PDFObjectID], rightGraph: PDFGraph,
    rightPageIDs: [PDFObjectID]
  ) -> [PDFComparisonChange] {
    func value(of field: FormField) -> String {
      if let text = field.stringValue { return text }
      if let state = field.buttonState { return String(decoding: state.bytes, as: UTF8.self) }
      return ""
    }
    let leftFields = (try? FormInventory.fields(in: leftGraph, pageIDs: leftPageIDs)) ?? []
    let rightFields = (try? FormInventory.fields(in: rightGraph, pageIDs: rightPageIDs)) ?? []
    let rightByName = Dictionary(
      rightFields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var changes: [PDFComparisonChange] = []
    for field in leftFields {
      guard let other = rightByName[field.name] else { continue }
      let leftValue = value(of: field)
      let rightValue = value(of: other)
      guard leftValue != rightValue else { continue }
      changes.append(
        PDFComparisonChange(
          kind: .formValueChanged,
          leftPageIndex: field.widgets.first?.pageIndex,
          rightPageIndex: other.widgets.first?.pageIndex,
          summary: "form value changed (\(field.name)): \"\(snippet(leftValue))\" → "
            + "\"\(snippet(rightValue))\"",
          leftBounds: field.widgets.first?.rect, rightBounds: other.widgets.first?.rect,
          isOCRSourced: false))
    }
    return changes
  }

  // MARK: Document-level differences

  static func metadataChanges(left: PDFGraph, right: PDFGraph, limits: PDFLimits)
    -> [PDFComparisonChange]
  {
    var changes: [PDFComparisonChange] = []
    let keys: [PDFName] = [
      PDFName("Title"), PDFName("Author"), PDFName("Subject"), PDFName("Keywords"),
      PDFName("Creator"), PDFName("Producer"),
    ]
    func info(_ graph: PDFGraph) -> [PDFName: PDFValue] {
      guard case .reference(let id)? = graph.trailer[PDFName("Info")],
        case .dictionary(let dictionary)? = graph.objects[id]
      else { return [:] }
      return dictionary
    }
    let leftInfo = info(left)
    let rightInfo = info(right)
    for key in keys where leftInfo[key] != rightInfo[key] {
      let name = String(decoding: key.bytes, as: UTF8.self)
      changes.append(
        PDFComparisonChange(
          kind: .metadataChanged, leftPageIndex: nil, rightPageIndex: nil,
          summary: "document metadata changed (/\(name))", leftBounds: nil, rightBounds: nil,
          isOCRSourced: false))
    }
    func metadataStreams(_ graph: PDFGraph) -> Int {
      graph.objects.values.filter { value in
        let dictionary: [PDFName: PDFValue]?
        if case .stream(let stream) = value { dictionary = stream.dictionary } else if case .dictionary(let direct) = value { dictionary = direct } else { dictionary = nil }
        return dictionary?[PDFName("Type")] == .name(PDFName("Metadata"))
      }.count
    }
    if metadataStreams(left) != metadataStreams(right) {
      changes.append(
        PDFComparisonChange(
          kind: .metadataChanged, leftPageIndex: nil, rightPageIndex: nil,
          summary: "XMP metadata stream count changed", leftBounds: nil, rightBounds: nil,
          isOCRSourced: false))
    }
    func attachments(_ graph: PDFGraph) -> [String] {
      graph.objects.values.compactMap { value -> String? in
        guard case .stream(let stream) = value,
          stream.dictionary[PDFName("Type")] == .name(PDFName("EmbeddedFile"))
        else { return nil }
        if case .string(let data)? = stream.dictionary[PDFName("F")] {
          return String(decoding: data, as: UTF8.self)
        }
        return "unnamed"
      }.sorted()
    }
    if attachments(left) != attachments(right) {
      changes.append(
        PDFComparisonChange(
          kind: .attachmentChanged, leftPageIndex: nil, rightPageIndex: nil,
          summary: "attachments changed", leftBounds: nil, rightBounds: nil,
          isOCRSourced: false))
    }
    _ = limits
    return changes
  }

  static func statusChanges(
    left: PDFGraph, leftSource: Data, right: PDFGraph, rightSource: Data, limits: PDFLimits
  ) -> [PDFComparisonChange] {
    var changes: [PDFComparisonChange] = []
    let leftEncrypted = left.trailer[PDFName("Encrypt")] != nil
    let rightEncrypted = right.trailer[PDFName("Encrypt")] != nil
    if leftEncrypted != rightEncrypted {
      changes.append(
        PDFComparisonChange(
          kind: .encryptionStatus, leftPageIndex: nil, rightPageIndex: nil,
          summary: "encryption status changed (\(leftEncrypted ? "encrypted" : "plain") → "
            + "\(rightEncrypted ? "encrypted" : "plain"))",
          leftBounds: nil, rightBounds: nil, isOCRSourced: false))
    }
    func signatures(_ graph: PDFGraph, _ source: Data) -> [String] {
      let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
      return signatures.map { signature in
        let validation = PDFSignatureValidator.validate(
          signature, source: source, finalGraph: graph, limits: limits)
        return "\(signature.subFilter ?? "?")|\(validation.crypto.rawValue)|"
          + "\(validation.trust.rawValue)|\(validation.unsignedChanges)"
      }
    }
    let leftSignatures = signatures(left, leftSource)
    let rightSignatures = signatures(right, rightSource)
    if leftSignatures != rightSignatures {
      changes.append(
        PDFComparisonChange(
          kind: .signatureStatus, leftPageIndex: nil, rightPageIndex: nil,
          summary: "signature status changed (\(leftSignatures.count) → \(rightSignatures.count) "
            + "signature(s))",
          leftBounds: nil, rightBounds: nil, isOCRSourced: false))
    }
    return changes
  }

  static func documentSummary(graph: PDFGraph, pageIDs: [PDFObjectID], source: Data) throws
    -> PDFComparisonResult.DocumentSummary
  {
    let signatures = (try? PDFSignatureInventory.signatures(in: graph)) ?? []
    let statuses = signatures.map { signature in
      let validation = PDFSignatureValidator.validate(
        signature, source: source, finalGraph: graph)
      return "\(signature.subFilter ?? "?"): \(validation.crypto.rawValue)/"
        + "\(validation.trust.rawValue)"
    }
    let hasOCR = pageIDs.contains { OCRLayer.hasGeneratedLayer(in: graph, pageID: $0) }
    return PDFComparisonResult.DocumentSummary(
      pageCount: pageIDs.count, isEncrypted: graph.trailer[PDFName("Encrypt")] != nil,
      signatureCount: signatures.count, signatureStatuses: statuses, hasOCRLayers: hasOCR)
  }

  // MARK: Helpers

  static func normalize(_ text: String, collapse: Bool) -> String {
    guard collapse else { return text }
    return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  static func similar(_ left: String, _ right: String) -> Bool {
    let leftPrefix = left.prefix(12)
    let rightPrefix = right.prefix(12)
    if leftPrefix == rightPrefix, !leftPrefix.isEmpty { return true }
    let leftWords = Set(left.split(separator: " "))
    let rightWords = Set(right.split(separator: " "))
    guard !leftWords.isEmpty, !rightWords.isEmpty else { return false }
    let shared = leftWords.intersection(rightWords).count
    return Double(shared) / Double(min(leftWords.count, rightWords.count)) >= 0.5
  }

  static func snippet(_ text: String, limit: Int = 60) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "…"
  }

  static func unionBounds(_ bounds: [[Double]]) -> [Double] {
    guard !bounds.isEmpty else { return [0, 0, 0, 0] }
    var result = bounds[0]
    for bounds in bounds.dropFirst() {
      result = [
        min(result[0], bounds[0]), min(result[1], bounds[1]), max(result[2], bounds[2]),
        max(result[3], bounds[3]),
      ]
    }
    return result
  }

  /// P32-019: a conservative multi-column heuristic: two lines share a
  /// vertical band but their horizontal ranges do not overlap.
  static func isMultiColumn(_ layout: PageTextLayout) -> Bool {
    let lines = layout.lines.map { range -> [Double] in
      unionBounds(range.compactMap { layout.clusters[$0].bounds })
    }
    guard lines.count >= 2 else { return false }
    for first in 0..<lines.count {
      for second in (first + 1)..<lines.count {
        let a = lines[first]
        let b = lines[second]
        let verticalOverlap = min(a[3], b[3]) - max(a[1], b[1])
        let horizontalOverlap = min(a[2], b[2]) - max(a[0], b[0])
        if verticalOverlap > 1, horizontalOverlap < -20 { return true }
      }
    }
    return false
  }

  static func numberArray(_ value: PDFValue?) -> [Double]? {
    guard case .array(let values)? = value else { return nil }
    let numbers = values.compactMap { entry -> Double? in
      if case .integer(let raw) = entry { return Double(raw) }
      if case .real(let raw) = entry { return raw }
      return nil
    }
    return numbers.count == values.count ? numbers : nil
  }

  static func integerValue(_ value: PDFValue?) -> Int? {
    guard case .integer(let raw)? = value else { return nil }
    return Int(raw)
  }
}

/// P32-022/P32-028: a local comparison report with selected evidence only —
/// changed snippets and geometry, never full document dumps.
public enum PDFComparisonReport {
  public static func text(
    _ result: PDFComparisonResult, options: PDFComparisonOptions = PDFComparisonOptions()
  ) -> String {
    var lines: [String] = []
    lines.append("sPDF Editor comparison report")
    lines.append(
      "Pages: \(result.left.pageCount) → \(result.right.pageCount); "
        + "signatures: \(result.left.signatureCount) → \(result.right.signatureCount); "
        + "encrypted: \(result.left.isEncrypted)/\(result.right.isEncrypted)")
    lines.append("Visual tolerance: \(options.visualTolerance) per channel")
    lines.append("")
    lines.append("Page mapping:")
    for pair in result.pageMapping {
      let left = pair.leftIndex.map { "L\($0 + 1)" } ?? "—"
      let right = pair.rightIndex.map { "R\($0 + 1)" } ?? "—"
      lines.append("  \(left) ↔ \(right) [\(pair.status.rawValue)]")
    }
    lines.append("")
    lines.append("Changes (\(result.changes.count)):")
    for change in result.changes {
      let page = change.rightPageIndex.map { "R\($0 + 1)" }
        ?? change.leftPageIndex.map { "L\($0 + 1)" } ?? "document"
      let source = change.isOCRSourced ? " [OCR]" : ""
      lines.append("  \(page) \(change.kind.rawValue): \(change.summary)\(source)")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
