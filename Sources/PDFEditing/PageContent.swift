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

  /// Rewrite several non-overlapping decoded ranges inside one editable
  /// segment in a single pass. Used by coordinate edits that must change
  /// more than one operand of the same instruction.
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
    guard let index = segmentIndex(for: sorted[0].range) else {
      throw PDFError(.unsupported, "The edited span is outside the page content streams")
    }
    for entry in sorted {
      guard segmentIndex(for: entry.range) == index else {
        throw PDFError(.unsupported, "The edited text spans multiple content streams")
      }
    }
    let segment = segments[index]
    guard segment.isEditable else {
      throw PDFError(.unsupported, "This content stream uses unsupported filters for editing")
    }
    let base = segment.range.lowerBound
    var decoded = segment.decoded
    for entry in sorted.reversed() {
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

    var graph = graph
    graph.objects[segment.objectID] = .stream(PDFStream(dictionary: dictionary, bytes: bytes))
    return graph
  }
}
