import Foundation
import PDFCore

/// OCR-03: word-level provenance and correction storage for the generated
/// searchable text layer. Review metadata is persisted inside the page as a
/// private JSON stream keyed by SPDFOCRReview; the corrected text itself lives
/// in the generated layer, so search and copy see it without app-specific
/// sidecars.
public struct OCRReviewWordRecord: Sendable, Equatable, Codable {
  public let lineIndex: Int
  public let wordIndex: Int
  public let text: String
  /// Page-space rectangle [x0, y0, x1, y1] of the word.
  public let rect: [Double]
  public let confidence: Double

  public init(
    lineIndex: Int, wordIndex: Int, text: String, rect: [Double], confidence: Double
  ) {
    self.lineIndex = lineIndex
    self.wordIndex = wordIndex
    self.text = text
    self.rect = rect
    self.confidence = confidence
  }
}

/// One committed layer line: its exact bounds and recognition confidence.
public struct OCRReviewLineRecord: Sendable, Equatable, Codable {
  public let rect: [Double]
  public let confidence: Double

  public init(rect: [Double], confidence: Double) {
    self.rect = rect
    self.confidence = confidence
  }
}

/// One word correction applied to the layer. The line text is rewritten by
/// replacing the word token at wordIndex; separators and line bounds stay.
public struct OCRWordCorrection: Sendable, Equatable, Codable {
  public let lineIndex: Int
  public let wordIndex: Int
  public let originalWord: String
  public let replacement: String

  public init(lineIndex: Int, wordIndex: Int, originalWord: String, replacement: String) {
    self.lineIndex = lineIndex
    self.wordIndex = wordIndex
    self.originalWord = originalWord
    self.replacement = replacement
  }
}

/// OCR-03: the persisted review record for one page. Only recognizer-produced
/// words that failed the confidence threshold are stored as suspects, plus the
/// full correction history. This bounds the metadata to the review surface.
public struct OCRReviewPageRecord: Sendable, Equatable, Codable {
  public static let maxLines = 2_000
  public static let maxSuspectWords = 5_000
  public static let maxCorrections = 2_000
  public static let maxBytes = 256 * 1_024
  public static let supportedQualities = ["accurate", "fast", "fastFallback"]

  public let threshold: Double
  /// "accurate", "fast" or "fastFallback" (OCR-01 disclosure persists).
  public let quality: String
  public let lines: [OCRReviewLineRecord]
  /// Remaining unreviewed suspect words, in page reading order.
  public let suspectWords: [OCRReviewWordRecord]
  /// Correction history, oldest first.
  public let corrections: [OCRWordCorrection]

  public init(
    threshold: Double, quality: String, lines: [OCRReviewLineRecord],
    suspectWords: [OCRReviewWordRecord], corrections: [OCRWordCorrection] = []
  ) {
    self.threshold = threshold
    self.quality = quality
    self.lines = lines
    self.suspectWords = suspectWords
    self.corrections = corrections
  }

  public func validated() throws -> OCRReviewPageRecord {
    guard threshold.isFinite, (0...1).contains(threshold) else {
      throw PDFError(.malformed, "The OCR review confidence threshold must be within 0...1")
    }
    guard Self.supportedQualities.contains(quality) else {
      throw PDFError(.malformed, "The OCR review quality marker is unsupported")
    }
    guard !lines.isEmpty, lines.count <= Self.maxLines else {
      throw PDFError(.malformed, "The OCR review record has an unsupported line count")
    }
    for line in lines {
      guard line.rect.count == 4, line.rect.allSatisfy(\.isFinite),
        line.rect[2] > line.rect[0], line.rect[3] > line.rect[1],
        line.confidence.isFinite, (0...1).contains(line.confidence)
      else {
        throw PDFError(.malformed, "The OCR review recorded a line with invalid geometry")
      }
    }
    guard suspectWords.count <= Self.maxSuspectWords else {
      throw PDFError(.limitExceeded, "The OCR review has too many suspect words")
    }
    var seenWords = Set<String>()
    for word in suspectWords {
      guard lines.indices.contains(word.lineIndex), word.wordIndex >= 0,
        word.text == word.text.trimmingCharacters(in: .whitespacesAndNewlines),
        !word.text.isEmpty, OCRReviewTokenizer.words(word.text).count == 1,
        word.rect.count == 4, word.rect.allSatisfy(\.isFinite),
        word.rect[2] > word.rect[0], word.rect[3] > word.rect[1],
        word.confidence.isFinite, (0...1).contains(word.confidence)
      else {
        throw PDFError(.malformed, "The OCR review recorded an invalid suspect word")
      }
      let key = "\(word.lineIndex):\(word.wordIndex)"
      guard seenWords.insert(key).inserted else {
        throw PDFError(.malformed, "The OCR review recorded a duplicate suspect word")
      }
    }
    guard corrections.count <= Self.maxCorrections else {
      throw PDFError(.limitExceeded, "The OCR review has too many corrections")
    }
    var seenCorrections = Set<String>()
    for correction in corrections {
      try OCRReviewTokenizer.validateCorrection(correction)
      let key = "\(correction.lineIndex):\(correction.wordIndex)"
      guard seenCorrections.insert(key).inserted else {
        throw PDFError(.malformed, "The OCR review recorded a duplicate word correction")
      }
    }
    guard let encoded = try? JSONEncoder().encode(self) else {
      throw PDFError(.malformed, "The OCR review record cannot be encoded")
    }
    guard encoded.count <= Self.maxBytes else {
      throw PDFError(.limitExceeded, "The OCR review record exceeds its stored size bound")
    }
    return self
  }

  /// Build a record from committed layer lines. When explicit per-line word
  /// boxes are supplied (word-level Vision results) they set the suspect-word
  /// bounds; otherwise words are split proportionally across the line box.
  public static func build(
    lines: [SearchableTextLine], threshold: Double, quality: String,
    wordBoxes: [[[Double]]]? = nil
  ) -> OCRReviewPageRecord {
    var lineRecords: [OCRReviewLineRecord] = []
    var suspects: [OCRReviewWordRecord] = []
    for (lineIndex, line) in lines.enumerated() {
      let confidence = line.confidence ?? 0
      lineRecords.append(
        OCRReviewLineRecord(rect: line.rect, confidence: max(0, min(1, confidence))))
      let words = OCRReviewTokenizer.words(line.text)
      let boxes: [[Double]]
      if let wordBoxes, wordBoxes.indices.contains(lineIndex),
        wordBoxes[lineIndex].count == words.count
      {
        boxes = wordBoxes[lineIndex]
      } else {
        boxes = OCRReviewTokenizer.proportionalWordRects(
          lineText: line.text, rect: line.rect)
      }
      for (wordIndex, word) in words.enumerated() {
        guard boxes.indices.contains(wordIndex) else { continue }
        let box = boxes[wordIndex]
        guard box.count == 4, box.allSatisfy(\.isFinite),
          box[2] > box[0], box[3] > box[1]
        else { continue }
        if confidence < threshold {
          suspects.append(
            OCRReviewWordRecord(
              lineIndex: lineIndex, wordIndex: wordIndex, text: word, rect: box,
              confidence: max(0, min(1, confidence))))
        }
      }
    }
    return OCRReviewPageRecord(
      threshold: threshold, quality: quality, lines: lineRecords,
      suspectWords: suspects)
  }

  public func replacingSuspects(_ words: [OCRReviewWordRecord]) -> OCRReviewPageRecord {
    OCRReviewPageRecord(
      threshold: threshold, quality: quality, lines: lines, suspectWords: words,
      corrections: corrections)
  }
}

/// OCR-03: the generated layer's own line text, decoded from its Tj operands.
/// Only the generated (marked) layer streams are read.
public struct OCRLayerTextLine: Sendable, Equatable {
  public let text: String
  public let x: Double
  public let y: Double
  public let fontSize: Double
}

public enum OCRLayerTextReader {
  public static func lines(
    pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()
  ) -> [OCRLayerTextLine]? {
    let streamIDs = Set(OCRLayer.layerStreamIDs(in: graph, pageID: pageID))
    guard !streamIDs.isEmpty,
      let content = try? PageContent.load(pageID: pageID, in: graph, limits: limits)
    else { return nil }
    var result: [OCRLayerTextLine] = []
    for segment in content.segments where streamIDs.contains(segment.objectID) {
      guard let instructions = try? ContentParser.instructions(
        in: segment.decoded, limits: limits)
      else { continue }
      var fontSize = 0.0
      var lineX = 0.0
      var lineY = 0.0
      for instruction in instructions {
        switch instruction.operatorName {
        case "Tf":
          if instruction.operands.count >= 2,
            let value = OCRLayerTextReader.number(instruction.operands[1].value)
          {
            fontSize = value
          }
        case "Tm":
          if instruction.operands.count >= 6,
            let x = OCRLayerTextReader.number(instruction.operands[4].value),
            let y = OCRLayerTextReader.number(instruction.operands[5].value)
          {
            lineX = x
            lineY = y
          }
        case "Tj":
          guard let text = OCRLayerTextReader.text(instruction.operands.first?.value),
            !text.isEmpty
          else { continue }
          result.append(
            OCRLayerTextLine(text: text, x: lineX, y: lineY, fontSize: fontSize))
        default:
          continue
        }
      }
    }
    return result.isEmpty ? nil : result
  }

  static func number(_ value: PDFValue?) -> Double? {
    switch value {
    case .integer(let raw)?: return Double(raw)
    case .real(let raw)?: return raw.isFinite ? raw : nil
    default: return nil
    }
  }

  static func text(_ value: PDFValue?) -> String? {
    var bytes: [UInt8] = []
    switch value {
    case .string(let data)?:
      bytes = [UInt8](data)
    case .array(let members)?:
      for member in members {
        if case .string(let data) = member { bytes.append(contentsOf: [UInt8](data)) }
      }
    default:
      return nil
    }
    guard bytes.count % 2 == 0 else { return nil }
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var index = 0
    while index < bytes.count {
      units.append(UInt16(bytes[index]) * 256 + UInt16(bytes[index + 1]))
      index += 2
    }
    let text = String(decoding: units, as: UTF16.self)
    return text.isEmpty ? nil : text
  }
}

/// OCR-03: persisted review records. The record is a private JSON stream
/// referenced from the page dictionary key SPDFOCRReview; readers that do not
/// understand OCR simply ignore it.
public enum OCRReviewStore {
  static let pageKey = PDFName("SPDFOCRReview")
  static let markerKey = PDFName("SPDFOCRReviewMarker")
  static let maxStreamBytes = OCRReviewPageRecord.maxBytes + 64 * 1_024

  public static func read(
    pageID: PDFObjectID, in graph: PDFGraph
  ) -> OCRReviewPageRecord? {
    guard let stream = recordStream(pageID: pageID, in: graph),
      stream.dictionary[markerKey] == .boolean(true),
      stream.bytes.count <= maxStreamBytes,
      let record = try? JSONDecoder().decode(OCRReviewPageRecord.self, from: stream.bytes)
    else { return nil }
    return try? record.validated()
  }

  public static func hasRecord(pageID: PDFObjectID, in graph: PDFGraph) -> Bool {
    read(pageID: pageID, in: graph) != nil
  }

  static func recordStream(pageID: PDFObjectID, in graph: PDFGraph) -> PDFStream? {
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .reference(let id)? = page[pageKey],
      case .stream(let stream)? = graph.objects[id]
    else { return nil }
    return stream
  }

  static func recordStreamID(pageID: PDFObjectID, in graph: PDFGraph) -> PDFObjectID? {
    guard case .dictionary(let page)? = graph.objects[pageID],
      case .reference(let id)? = page[pageKey]
    else { return nil }
    return id
  }

  static func write(
    _ record: OCRReviewPageRecord, pageID: PDFObjectID, in graph: inout PDFGraph
  ) throws {
    let validated = try record.validated()
    let data = try JSONEncoder().encode(validated)
    guard data.count <= OCRReviewPageRecord.maxBytes else {
      throw PDFError(.limitExceeded, "The OCR review record exceeds its stored size bound")
    }
    if let oldID = recordStreamID(pageID: pageID, in: graph),
      case .stream(let old)? = graph.objects[oldID],
      old.dictionary[markerKey] == .boolean(true)
    {
      graph.objects[oldID] = nil
    }
    guard case .dictionary(var page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    let next = (graph.objects.keys.map(\.number).max() ?? 0) + 1
    let streamID = PDFObjectID(next)
    graph.objects[streamID] = .stream(
      PDFStream(
        dictionary: [
          PDFName("Length"): .integer(Int64(data.count)),
          markerKey: .boolean(true),
        ], bytes: data))
    page[pageKey] = .reference(streamID)
    graph.objects[pageID] = .dictionary(page)
    let size = Int64(next + 1)
    if case .integer(let current)? = graph.trailer[PDFName("Size")], current >= size {
      // Keep the larger existing size.
    } else {
      graph.trailer[PDFName("Size")] = .integer(size)
    }
  }
}

/// OCR-03: word tokenization shared by metadata building, correction
/// validation and layer rewriting. Whitespace is preserved verbatim; only word
/// tokens can be replaced, so word indices stay stable across corrections.
public enum OCRReviewTokenizer {
  public static func segments(_ text: String) -> [(text: String, isWord: Bool)] {
    var result: [(text: String, isWord: Bool)] = []
    var current = ""
    var currentIsWord: Bool?
    for character in text {
      let isWord = !character.isWhitespace
      if currentIsWord == isWord {
        current.append(character)
      } else {
        if !current.isEmpty, let flag = currentIsWord {
          result.append((current, flag))
        }
        current = String(character)
        currentIsWord = isWord
      }
    }
    if !current.isEmpty, let flag = currentIsWord {
      result.append((current, flag))
    }
    return result
  }

  public static func words(_ text: String) -> [String] {
    segments(text).filter(\.isWord).map(\.text)
  }

  /// Replace words by token index, preserving every separator character.
  public static func replacingWords(
    in lineText: String, replacements: [Int: String]
  ) throws -> String {
    guard !replacements.isEmpty else { return lineText }
    var wordIndex = 0
    var output = ""
    for segment in segments(lineText) {
      if !segment.isWord {
        output += segment.text
        continue
      }
      if let replacement = replacements[wordIndex] {
        output += replacement
      } else {
        output += segment.text
      }
      wordIndex += 1
    }
    return output
  }

  /// Word boxes estimated proportionally across the recognized line box. This
  /// is the bounded fallback when the recognizer supplies no word-level boxes.
  public static func proportionalWordRects(
    lineText: String, rect: [Double]
  ) -> [[Double]] {
    let words = words(lineText)
    guard !words.isEmpty, rect.count == 4, rect[2] > rect[0] else { return [] }
    let totalUnits = lineText.utf16.count
    guard totalUnits > 0 else { return [] }
    let perUnit = (rect[2] - rect[0]) / Double(totalUnits)
    let height = rect[3] - rect[1]
    var utf16Offset = 0
    var result: [[Double]] = []
    for segment in segments(lineText) {
      let length = segment.text.utf16.count
      if segment.isWord {
        let x0 = rect[0] + perUnit * Double(utf16Offset)
        let x1 = rect[0] + perUnit * Double(utf16Offset + length)
        result.append([x0, rect[1], x1, rect[1] + height])
      }
      utf16Offset += length
    }
    return result
  }

  public static func validateCorrection(_ correction: OCRWordCorrection) throws {
    guard correction.lineIndex >= 0, correction.wordIndex >= 0,
      !correction.originalWord.isEmpty,
      words(correction.originalWord).count == 1,
      correction.originalWord == correction.originalWord.trimmingCharacters(
        in: .whitespacesAndNewlines)
    else {
      throw PDFError(.malformed, "The OCR correction does not address one word")
    }
    guard !correction.replacement.isEmpty,
      words(correction.replacement).count == 1,
      correction.replacement == correction.replacement.trimmingCharacters(
        in: .whitespacesAndNewlines),
      correction.replacement.unicodeScalars.allSatisfy({ scalar in
        scalar.value < 0x10000 && !CharacterSet.controlCharacters.contains(scalar)
      })
    else {
      throw PDFError(.unsupported, "An OCR word correction must be one supported word")
    }
  }
}

/// OCR-03: apply reviewed word corrections to a page's generated layer as one
/// transaction change. Text and ToUnicode are rewritten, line bounds are taken
/// from the persisted review record, and the page image and original content
/// streams are untouched because only the marked layer stream is replaced.
public struct ApplyOCRCorrectionsCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let corrections: [OCRWordCorrection]
  /// The updated review record (remaining suspect words after these
  /// corrections). The command merges the persisted correction history.
  public let record: OCRReviewPageRecord

  public init(
    pageID: PDFObjectID, corrections: [OCRWordCorrection], record: OCRReviewPageRecord
  ) {
    self.pageID = pageID
    self.corrections = corrections
    self.record = record
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Correct OCR Text" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    let layerLines = try OCRLayerTextReader.lines(pageID: pageID, in: graph)
    guard let layerLines else {
      throw PDFError(.unsupported, "This page has no generated searchable text layer to review")
    }
    guard !corrections.isEmpty else {
      throw PDFError(.malformed, "No OCR corrections were supplied")
    }
    let merged = try Self.mergedRecord(
      existing: OCRReviewStore.read(pageID: pageID, in: graph), updated: record,
      applied: corrections)
    guard merged.lines.count == layerLines.count else {
      throw PDFError(
        .unsupported,
        "The OCR layer changed since this review was loaded. Reopen the review and try again.")
    }
    for (index, line) in layerLines.enumerated() {
      let rect = merged.lines[index].rect
      guard abs(line.y - rect[1]) <= 0.01,
        abs(line.fontSize - (rect[3] - rect[1])) <= 0.01
      else {
        throw PDFError(
          .unsupported,
          "The OCR layer bounds changed since this review was loaded. Reopen the review.")
      }
    }
    var keys = Set<String>()
    for correction in corrections {
      try OCRReviewTokenizer.validateCorrection(correction)
      guard layerLines.indices.contains(correction.lineIndex) else {
        throw PDFError(.malformed, "The OCR correction addresses a missing line")
      }
      let words = OCRReviewTokenizer.words(layerLines[correction.lineIndex].text)
      guard words.indices.contains(correction.wordIndex),
        words[correction.wordIndex] == correction.originalWord
      else {
        throw PDFError(
          .unsupported,
          "The corrected OCR word no longer matches the layer. Reopen the review.")
      }
      let key = "\(correction.lineIndex):\(correction.wordIndex)"
      guard keys.insert(key).inserted else {
        throw PDFError(.malformed, "Two corrections address the same OCR word")
      }
    }
    _ = try merged.validated()
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    guard let layerLines = try OCRLayerTextReader.lines(pageID: pageID, in: graph) else {
      throw PDFError(.unsupported, "This page has no generated searchable text layer")
    }
    let existing = OCRReviewStore.read(pageID: pageID, in: graph)
    let merged = try Self.mergedRecord(
      existing: existing, updated: record, applied: corrections)
    var perLine: [Int: [Int: String]] = [:]
    for correction in corrections {
      perLine[correction.lineIndex, default: [:]][correction.wordIndex] = correction.replacement
    }
    var rewritten: [SearchableTextLine] = []
    rewritten.reserveCapacity(layerLines.count)
    for (index, line) in layerLines.enumerated() {
      let text = try OCRReviewTokenizer.replacingWords(
        in: line.text, replacements: perLine[index] ?? [:])
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PDFError(.unsupported, "An OCR correction produced an empty line")
      }
      let record = merged.lines[index]
      rewritten.append(
        SearchableTextLine(
          text: text, rect: record.rect, confidence: record.confidence))
    }
    let layered = try AddSearchableTextLayerCommand(
      pageID: pageID, lines: rewritten, replacingExistingLayer: true
    ).apply(to: graph)
    var result = layered
    try OCRReviewStore.write(merged, pageID: pageID, in: &result)
    return result
  }

  static func mergedRecord(
    existing: OCRReviewPageRecord?, updated: OCRReviewPageRecord,
    applied: [OCRWordCorrection]
  ) throws -> OCRReviewPageRecord {
    var history: [OCRWordCorrection] = []
    var keys = Set<String>()
    for correction in (existing?.corrections ?? []) + updated.corrections + applied {
      let key = "\(correction.lineIndex):\(correction.wordIndex)"
      if keys.insert(key).inserted {
        history.append(correction)
      } else if let index = history.firstIndex(where: {
        $0.lineIndex == correction.lineIndex && $0.wordIndex == correction.wordIndex
      }) {
        history[index] = correction
      }
    }
    return OCRReviewPageRecord(
      threshold: updated.threshold, quality: updated.quality, lines: updated.lines,
      suspectWords: updated.suspectWords, corrections: history)
  }
}

/// OCR-03/OCR-07: persist a review record for a page that already has a
/// generated layer. Recognition uses this to attach confidence/provenance and
/// the initial suspect-word queue; the multi-file OCR queue uses it so a batch
/// output can be reviewed later too.
public struct RecordOCRReviewCommand: PDFEditCommand, Equatable, Sendable {
  public let pageID: PDFObjectID
  public let record: OCRReviewPageRecord

  public init(pageID: PDFObjectID, record: OCRReviewPageRecord) {
    self.pageID = pageID
    self.record = record
  }

  public func affectedPageIDs(in graph: PDFGraph) -> [PDFObjectID] { [pageID] }
  public var name: String { "Record OCR Review" }

  public func validate(in graph: PDFGraph) throws {
    try AnnotationSupport.validatePage(pageID, in: graph)
    guard let layerLines = try OCRLayerTextReader.lines(pageID: pageID, in: graph) else {
      throw PDFError(.unsupported, "This page has no generated searchable text layer")
    }
    let validated = try record.validated()
    guard validated.lines.count == layerLines.count else {
      throw PDFError(.malformed, "The OCR review record does not match the layer line count")
    }
    for (index, line) in layerLines.enumerated() {
      let rect = validated.lines[index].rect
      guard abs(line.y - rect[1]) <= 0.01,
        abs(line.fontSize - (rect[3] - rect[1])) <= 0.01
      else {
        throw PDFError(.malformed, "The OCR review record does not match the layer bounds")
      }
    }
  }

  public func apply(to graph: PDFGraph) throws -> PDFGraph {
    try validate(in: graph)
    var result = graph
    try OCRReviewStore.write(record, pageID: pageID, in: &result)
    return result
  }
}

