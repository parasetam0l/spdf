import Foundation
import PDFCore

/// One decoded content stream of a page plus its slice of the concatenated
/// execution sequence.
struct PageContentSegment {
  let objectID: PDFObjectID
  let dictionary: [PDFName: PDFValue]
  let decoded: [UInt8]
  let filters: [PDFName]
  let range: Range<Int>

  /// This profile edits streams whose filter chain is either absent or plain
  /// FlateDecode so re-encoding stays exact and predictable.
  var isEditable: Bool {
    filters.isEmpty || filters == [PDFName("FlateDecode")]
  }
}

/// P13-002: one page's contents as an ordered execution sequence. Multiple
/// /Contents entries are concatenated for parsing while each run keeps the
/// stream it came from, so edits can rewrite exactly one stream.
struct PageContent {
  let pageID: PDFObjectID
  let segments: [PageContentSegment]
  let bytes: [UInt8]
  let instructions: [ContentInstruction]

  func segmentIndex(for span: Range<Int>) -> Int? {
    segments.firstIndex {
      $0.range.lowerBound <= span.lowerBound && span.upperBound <= $0.range.upperBound
    }
  }

  /// Return every content-stream segment containing bytes from a range. PDF
  /// `/Contents` arrays execute as one concatenated stream, so a token or text
  /// instruction may legitimately straddle adjacent stream boundaries.
  func segmentIndices(for span: Range<Int>) -> [Int]? {
    guard span.lowerBound >= 0, span.upperBound >= span.lowerBound,
      span.upperBound <= bytes.count else { return nil }
    if span.isEmpty {
      guard let index = segmentIndex(for: span) else { return nil }
      return [index]
    }
    guard let first = segments.indices.first(where: { segments[$0].range.overlaps(span) }),
      let last = segments.indices.last(where: { segments[$0].range.overlaps(span) }),
      segments[first].range.lowerBound <= span.lowerBound,
      segments[last].range.upperBound >= span.upperBound
    else { return nil }
    return Array(first...last)
  }

  static func load(pageID: PDFObjectID, in graph: PDFGraph, limits: PDFLimits = PDFLimits()) throws
    -> PageContent
  {
    guard case .dictionary(let page)? = graph.objects[pageID] else {
      throw PDFError(.malformed, "Page is missing")
    }
    var references: [PDFObjectID] = []
    switch page[PDFName("Contents")] {
    case .reference(let id)?:
      references = [id]
    case .array(let values)?:
      for value in values {
        guard case .reference(let id) = value else {
          throw PDFError(.malformed, "Page content array member is not a reference")
        }
        references.append(id)
      }
    case nil:
      references = []
    default:
      throw PDFError(.malformed, "Page contents entry is not a stream reference")
    }
    var segments: [PageContentSegment] = []
    var combined: [UInt8] = []
    for id in references {
      guard case .stream(let stream)? = graph.objects[id] else {
        throw PDFError(.malformed, "Page content stream is missing")
      }
      let decoded = [UInt8](try PDFFilters.decoded(stream, limits: limits))
      let start = combined.count
      combined.append(contentsOf: decoded)
      let filters = try PDFFilters.filterNames(in: stream.dictionary)
      segments.append(
        PageContentSegment(
          objectID: id, dictionary: stream.dictionary, decoded: decoded, filters: filters,
          range: start..<combined.count))
    }
    let instructions = try ContentParser.instructions(in: combined, limits: limits)
    return PageContent(
      pageID: pageID, segments: segments, bytes: combined, instructions: instructions)
  }

  /// Rewrite one decoded byte range inside a single editable segment,
  /// re-encoding that stream with its original filter. Every other object is
  /// left untouched, including streams that share the page.
  func replacing(
    range: Range<Int>, with replacement: [UInt8], in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    try replacing(ranges: [(range, replacement)], in: graph, limits: limits)
  }

  /// Rewrite several non-overlapping decoded ranges in their original
  /// editable segments. Ranges may cross `/Contents` boundaries because the
  /// page streams are parsed and executed as one concatenated sequence.
  func replacing(
    ranges: [(range: Range<Int>, replacement: [UInt8])], in graph: PDFGraph,
    limits: PDFLimits = PDFLimits()
  ) throws -> PDFGraph {
    guard !ranges.isEmpty else { return graph }
    let sorted = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
    for (previous, next) in zip(sorted, sorted.dropFirst()) {
      guard previous.range.upperBound <= next.range.lowerBound else {
        throw PDFError(.malformed, "Edited ranges overlap inside the content stream")
      }
    }

    var rangesBySegment: [Int: [(range: Range<Int>, replacement: [UInt8])]] = [:]
    var spansAcrossSegments = false
    var touchedSegments: Set<Int> = []
    for entry in sorted {
      guard let indices = segmentIndices(for: entry.range) else {
        throw PDFError(.unsupported, "The edited span cannot be mapped to the page's content streams")
      }
      touchedSegments.formUnion(indices)
      if indices.count > 1 { spansAcrossSegments = true }
      if indices.count == 1 {
        rangesBySegment[indices[0], default: []].append(entry)
      }
    }
    for index in touchedSegments.sorted() {
      let segment = segments[index]
      guard segment.isEditable else {
        throw PDFError(.unsupported, "This content stream uses unsupported filters for editing")
      }
      // The same stream object can appear more than once in one /Contents
      // array. Rewriting its object would change every occurrence, so refuse
      // instead of applying the replacement to an unselected occurrence.
      guard segments.filter({ $0.objectID == segment.objectID }).count == 1 else {
        throw PDFError(.unsupported, "A repeated page content stream cannot be edited selectively")
      }
    }

    if spansAcrossSegments {
      return try replacingAcrossSegments(
        sorted, touchedSegments: touchedSegments, in: graph, limits: limits)
    }

    var result = graph
    for index in rangesBySegment.keys.sorted() {
      let segment = segments[index]
      let base = segment.range.lowerBound
      var decoded = segment.decoded
      for entry in (rangesBySegment[index] ?? []).reversed() {
        decoded.replaceSubrange(
          (entry.range.lowerBound - base)..<(entry.range.upperBound - base),
          with: entry.replacement)
      }

      var dictionary = segment.dictionary
      let bytes: Data
      if segment.filters == [PDFName("FlateDecode")] {
        bytes = try PDFFilters.encodeFlate(Data(decoded), limits: limits)
        dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
        dictionary.removeValue(forKey: PDFName("DecodeParms"))
        dictionary.removeValue(forKey: PDFName("DP"))
      } else {
        bytes = Data(decoded)
        dictionary.removeValue(forKey: PDFName("Filter"))
        dictionary.removeValue(forKey: PDFName("DecodeParms"))
        dictionary.removeValue(forKey: PDFName("DP"))
      }
      dictionary[PDFName("Length")] = .integer(Int64(bytes.count))
      if segment.dictionary[PDFName("DL")] != nil {
        dictionary[PDFName("DL")] = .integer(Int64(decoded.count))
      }
      result.objects[segment.objectID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))
    }
    return result
  }

  private func replacingAcrossSegments(
    _ ranges: [(range: Range<Int>, replacement: [UInt8])],
    touchedSegments: Set<Int>, in graph: PDFGraph, limits: PDFLimits
  ) throws -> PDFGraph {
    // Multiple insertions at the same point or an insertion adjacent to a
    // replacement have ambiguous stream-boundary ownership. Existing callers
    // use distinct page-start/page-end insertions; refuse other combinations.
    let insertions = ranges.filter { $0.range.isEmpty }
    for insertion in insertions {
      let point = insertion.range.lowerBound
      let overlapsReplacement = ranges.contains { entry in
        !entry.range.isEmpty
          && entry.range.lowerBound <= point && point <= entry.range.upperBound
      }
      let insertionCount = insertions.filter { $0.range.lowerBound == point }.count
      guard !overlapsReplacement, insertionCount == 1
      else {
        throw PDFError(.unsupported, "Overlapping content-stream insertions cannot be assigned safely")
      }
    }

    var rewritten = bytes
    for entry in ranges.reversed() {
      rewritten.replaceSubrange(entry.range, with: entry.replacement)
    }

    func translatedBoundary(
      _ offset: Int, containingSegmentIndex: Int, isSegmentStart: Bool
    ) -> Int {
      var delta = 0
      for entry in ranges {
        let lower = entry.range.lowerBound
        let upper = entry.range.upperBound
        if lower == upper {
          if offset < lower { break }
          if offset == lower {
            // An insertion at a stream boundary belongs to the first segment
            // that contains that boundary, matching `segmentIndex(for:)`.
            let owner = self.segmentIndex(for: lower..<lower)
            if !isSegmentStart || owner != containingSegmentIndex {
              delta += entry.replacement.count
            }
            continue
          }
          delta += entry.replacement.count
          continue
        }
        if offset < lower { break }
        if offset < upper {
          if offset == lower {
            // A range beginning at a segment boundary belongs to the segment
            // that contains its first byte. Keep the preceding stream's end
            // at the start of the replacement.
            return lower + delta
          }
          // Keep every original stream boundary inside the replaced span on
          // one side of the replacement. Proportional remapping can place a
          // boundary in the middle of a newly serialized PDF token, making
          // the saved /Contents array unparsable.
          return lower + delta + entry.replacement.count
        }
        delta += entry.replacement.count - (upper - lower)
      }
      return offset + delta
    }

    var result = graph
    for index in segments.indices {
      let segment = segments[index]
      let lower = translatedBoundary(
        segment.range.lowerBound, containingSegmentIndex: index, isSegmentStart: true)
      let upper = translatedBoundary(
        segment.range.upperBound, containingSegmentIndex: index, isSegmentStart: false)
      guard lower >= 0, upper >= lower, upper <= rewritten.count else {
        throw PDFError(.malformed, "Rewritten content-stream boundaries are invalid")
      }
      let decoded = Array(rewritten[lower..<upper])
      guard decoded != segment.decoded else { continue }
      // A segment can only change when selected bytes reach it. The explicit
      // touched-set guard keeps boundary remapping from rewriting neighbors.
      guard touchedSegments.contains(index) else {
        throw PDFError(.malformed, "A content-stream rewrite crossed an unselected segment")
      }

      var dictionary = segment.dictionary
      let encoded: Data
      if segment.filters == [PDFName("FlateDecode")] {
        encoded = try PDFFilters.encodeFlate(Data(decoded), limits: limits)
        dictionary[PDFName("Filter")] = .name(PDFName("FlateDecode"))
        dictionary.removeValue(forKey: PDFName("DecodeParms"))
        dictionary.removeValue(forKey: PDFName("DP"))
      } else {
        encoded = Data(decoded)
        dictionary.removeValue(forKey: PDFName("Filter"))
        dictionary.removeValue(forKey: PDFName("DecodeParms"))
        dictionary.removeValue(forKey: PDFName("DP"))
      }
      dictionary[PDFName("Length")] = .integer(Int64(encoded.count))
      if segment.dictionary[PDFName("DL")] != nil {
        dictionary[PDFName("DL")] = .integer(Int64(decoded.count))
      }
      result.objects[segment.objectID] = .stream(
        PDFStream(dictionary: dictionary, bytes: encoded))
    }
    return result
  }
}
